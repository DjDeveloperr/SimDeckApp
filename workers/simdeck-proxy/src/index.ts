import { DurableObject } from "cloudflare:workers";
import { toString as qrToString } from "qrcode";

type RunnerState = "idle" | "starting" | "ready" | "failed";

interface Env {
  SIMDECK_SESSION: DurableObjectNamespace<SimDeckSession>;
  GITHUB_OWNER: string;
  GITHUB_REPO: string;
  GITHUB_REF: string;
  GITHUB_WORKFLOW: string;
  RUNNER_IDLE_TIMEOUT_SECONDS: string;
  RUNNER_PORT: string;
  SIMDECK_ACCESS_TOKEN: string;
  GITHUB_TOKEN: string;
  CREDENTIALS_PASSWORD: string;
  RUNNER_CALLBACK_TOKEN?: string;
}

interface SessionState {
  state: RunnerState;
  message: string;
  runnerBaseUrl?: string;
  runnerToken?: string;
  runId?: string;
  runUrl?: string;
  requestedAt?: number;
  registeredAt?: number;
  lastActivityAt?: number;
  lastHeartbeatAt?: number;
  failure?: string;
}

interface StatusResponse extends SessionState {
  idleTimeoutSeconds: number;
}

const SESSION_NAME = "default";
const HEARTBEAT_STALE_MILLISECONDS = 75_000;
const STARTING_STALE_MILLISECONDS = 10 * 60_000;
const JSON_HEADERS = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store"
};

interface GitHubWorkflowRun {
  id: number;
  html_url: string;
  status?: string;
  conclusion?: string | null;
  created_at?: string;
  updated_at?: string;
}

export class SimDeckSession extends DurableObject<Env> {
  private state: SessionState = {
    state: "idle",
    message: "Ready. Mac runner is cold."
  };

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.state = (await this.ctx.storage.get<SessionState>("state")) ?? this.state;
    });
  }

  async status(): Promise<StatusResponse> {
    await this.reconcileStaleState();
    await this.refreshFromGitHubIfNeeded();
    return {
      ...this.state,
      idleTimeoutSeconds: this.idleTimeoutSeconds()
    };
  }

  async ensureRunner(reason: string, proxyUrl: string): Promise<StatusResponse> {
    await this.reconcileStaleState();
    await this.refreshFromGitHubIfNeeded();
    if (this.state.state === "ready" && this.state.runnerBaseUrl) {
      await this.recordActivity();
      return this.status();
    }
    if (this.state.state === "starting") {
      await this.recordActivity();
      return this.status();
    }

    const now = Date.now();
    await this.setState({
      state: "starting",
      message: "Starting Mac...",
      requestedAt: now,
      lastActivityAt: now,
      runnerBaseUrl: undefined,
      runnerToken: undefined,
      runId: undefined,
      runUrl: undefined,
      failure: undefined
    });

    try {
      await this.dispatchWorkflow(reason, proxyUrl);
    } catch (error) {
      await this.setState({
        state: "failed",
        message: "Failed to request GitHub Actions runner.",
        failure: error instanceof Error ? error.message : String(error)
      });
    }
    return this.status();
  }

  async tunnelDisconnected(): Promise<StatusResponse> {
    await this.reconcileStaleState(true);
    if (this.state.state === "idle" || this.state.state === "failed") {
      return this.status();
    }
    await this.setState({
      ...this.state,
      state: "starting",
      message: "Tunnel disconnected. Reopening...",
      runnerBaseUrl: undefined,
      runnerToken: undefined
    });
    return this.status();
  }

  async register(payload: unknown): Promise<StatusResponse> {
    const parsed = parseRunnerPayload(payload);
    await this.refreshFromGitHubIfNeeded(true);
    if (!this.shouldAcceptRunnerRun(parsed.runId)) {
      return this.status();
    }
    await this.setState({
      state: "ready",
      message: "Mac ready.",
      runnerBaseUrl: parsed.baseUrl.replace(/\/+$/, ""),
      runnerToken: parsed.simdeckToken,
      runId: parsed.runId,
      runUrl: parsed.runUrl,
      registeredAt: Date.now(),
      lastHeartbeatAt: Date.now(),
      lastActivityAt: this.state.lastActivityAt ?? Date.now(),
      failure: undefined
    });
    return this.status();
  }

  async heartbeat(payload: unknown): Promise<StatusResponse> {
    const message = readString(payload, "message");
    const reconnecting = readBoolean(payload, "reconnecting");
    const runId = readString(payload, "runId");
    const runUrl = readString(payload, "runUrl");
    await this.refreshFromGitHubIfNeeded(true);
    if (!this.shouldAcceptRunnerRun(runId)) {
      return this.status();
    }
    await this.setState({
      ...this.state,
      state: reconnecting || this.state.state === "idle" ? "starting" : this.state.state,
      message: message ?? this.state.message,
      runnerBaseUrl: reconnecting ? undefined : this.state.runnerBaseUrl,
      runId: runId ?? this.state.runId,
      runUrl: runUrl ?? this.state.runUrl,
      lastHeartbeatAt: Date.now()
    });
    return this.status();
  }

  async keepalive(payload: unknown): Promise<{ shouldStop: boolean; shouldReopenTunnel: boolean; idleForSeconds: number; status: StatusResponse }> {
    await this.refreshFromGitHubIfNeeded();
    const runId = readString(payload, "runId");
    if (!this.shouldAcceptRunnerRun(runId)) {
      return { shouldStop: true, shouldReopenTunnel: false, idleForSeconds: 0, status: await this.status() };
    }
    const tunnelHealthy = await this.isRunnerTunnelHealthy();
    if (!tunnelHealthy && this.state.state === "ready") {
      await this.setState({
        ...this.state,
        state: "starting",
        message: "Tunnel disconnected. Reopening...",
        runnerBaseUrl: undefined
      });
    }
    const lastActivityAt = this.state.lastActivityAt ?? this.state.requestedAt ?? Date.now();
    const idleForSeconds = Math.max(0, Math.floor((Date.now() - lastActivityAt) / 1000));
    const shouldStop = this.state.state === "ready" && idleForSeconds >= this.idleTimeoutSeconds();
    if (shouldStop) {
      await this.setState({
        state: "idle",
        message: "Ready. Mac runner is cold.",
        runnerBaseUrl: undefined,
        runnerToken: undefined,
        runId: undefined,
        runUrl: undefined,
        requestedAt: undefined,
        registeredAt: undefined,
        lastHeartbeatAt: undefined,
        failure: undefined
      });
    }
    return { shouldStop, shouldReopenTunnel: !tunnelHealthy, idleForSeconds, status: await this.status() };
  }

  async reset(): Promise<StatusResponse> {
    await this.setState({
      state: "idle",
      message: "Ready. Mac runner is cold.",
      runnerBaseUrl: undefined,
      runnerToken: undefined,
      runId: undefined,
      runUrl: undefined,
      requestedAt: undefined,
      registeredAt: undefined,
      lastActivityAt: undefined,
      lastHeartbeatAt: undefined,
      failure: undefined
    });
    return this.status();
  }

  async recordActivity(): Promise<void> {
    if (this.state.state === "ready" || this.state.state === "starting") {
      await this.setState({
        ...this.state,
        lastActivityAt: Date.now()
      });
    }
  }

  private async refreshFromGitHubIfNeeded(force = false): Promise<void> {
    if (this.state.state !== "starting" || (this.state.runId && !force) || !this.state.requestedAt) {
      return;
    }
    if (!force && Date.now() - this.state.requestedAt < 3500) {
      return;
    }
    const run = await this.findRecentWorkflowRun();
    if (!run) {
      return;
    }
    await this.setState({
      ...this.state,
      runId: String(run.id),
      runUrl: run.html_url
    });
  }

  private async reconcileStaleState(force = false): Promise<void> {
    if (this.state.state === "idle" || this.state.state === "failed") {
      return;
    }
    const now = Date.now();
    const heartbeatIsStale = this.state.lastHeartbeatAt !== undefined
      && now - this.state.lastHeartbeatAt > HEARTBEAT_STALE_MILLISECONDS;
    const startingIsStale = this.state.state === "starting"
      && this.state.requestedAt !== undefined
      && now - this.state.requestedAt > STARTING_STALE_MILLISECONDS;
    const shouldCheckRun = force || heartbeatIsStale || startingIsStale;

    if (this.state.runId && shouldCheckRun) {
      const run = await this.findWorkflowRunById(this.state.runId);
      if (run?.status === "completed") {
        await this.setState({
          state: "idle",
          message: "Ready. Mac runner is cold.",
          runnerBaseUrl: undefined,
          runnerToken: undefined,
          runId: undefined,
          runUrl: undefined,
          requestedAt: undefined,
          registeredAt: undefined,
          lastHeartbeatAt: undefined,
          failure: run.conclusion && run.conclusion !== "success"
            ? `Previous GitHub Actions runner completed with ${run.conclusion}.`
            : undefined
        });
        return;
      }
    }

    if (this.state.state === "ready" && heartbeatIsStale && this.state.runnerBaseUrl && this.state.runnerToken) {
      const tunnelHealthy = await this.isTunnelUrlHealthy(this.state.runnerBaseUrl, this.state.runnerToken);
      if (!tunnelHealthy) {
        await this.setState({
          ...this.state,
          state: "starting",
          message: "Tunnel disconnected. Reopening...",
          runnerBaseUrl: undefined,
          runnerToken: undefined
        });
      }
      return;
    }

    if (this.state.state === "starting" && startingIsStale) {
      await this.setState({
        state: "failed",
        message: "Mac runner did not become ready in time.",
        runnerBaseUrl: undefined,
        runnerToken: undefined,
        runId: this.state.runId,
        runUrl: this.state.runUrl,
        requestedAt: this.state.requestedAt,
        lastActivityAt: this.state.lastActivityAt,
        lastHeartbeatAt: this.state.lastHeartbeatAt,
        failure: "Timed out waiting for the GitHub Actions runner to register."
      });
    }
  }

  private async dispatchWorkflow(reason: string, proxyUrl: string): Promise<void> {
    const url = githubApiUrl(this.env, `/actions/workflows/${encodeURIComponent(this.env.GITHUB_WORKFLOW)}/dispatches`);
    const body = {
      ref: this.env.GITHUB_REF,
      inputs: {
        proxy_url: proxyUrl,
        reason,
        port: this.env.RUNNER_PORT
      }
    };
    const response = await fetch(url, {
      method: "POST",
      headers: this.githubHeaders(),
      body: JSON.stringify(body)
    });
    if (response.status !== 204) {
      throw new Error(`GitHub workflow_dispatch returned ${response.status}: ${await response.text()}`);
    }
  }

  private async findRecentWorkflowRun(): Promise<GitHubWorkflowRun | undefined> {
    const url = githubApiUrl(
      this.env,
      `/actions/workflows/${encodeURIComponent(this.env.GITHUB_WORKFLOW)}/runs?branch=${encodeURIComponent(this.env.GITHUB_REF)}&event=workflow_dispatch&per_page=5`
    );
    const response = await fetch(url, { headers: this.githubHeaders() });
    if (!response.ok) {
      return undefined;
    }
    const payload = await response.json<{ workflow_runs?: GitHubWorkflowRun[] }>();
    return payload.workflow_runs?.[0];
  }

  private async findWorkflowRunById(runId: string): Promise<GitHubWorkflowRun | undefined> {
    const url = githubApiUrl(this.env, `/actions/runs/${encodeURIComponent(runId)}`);
    const response = await fetch(url, { headers: this.githubHeaders() });
    if (!response.ok) {
      return undefined;
    }
    return response.json<GitHubWorkflowRun>();
  }

  private async setState(next: SessionState): Promise<void> {
    this.state = next;
    await this.ctx.storage.put("state", next);
  }

  private githubHeaders(): HeadersInit {
    return {
      "accept": "application/vnd.github+json",
      "authorization": `Bearer ${this.env.GITHUB_TOKEN}`,
      "content-type": "application/json",
      "user-agent": "simdeck-proxy-worker",
      "x-github-api-version": "2022-11-28"
    };
  }

  private idleTimeoutSeconds(): number {
    const parsed = Number(this.env.RUNNER_IDLE_TIMEOUT_SECONDS);
    return Number.isFinite(parsed) && parsed > 0 ? parsed : 300;
  }

  private shouldAcceptRunnerRun(runId: string | undefined): boolean {
    if (!runId || !this.state.runId) {
      return true;
    }
    const incoming = Number(runId);
    const current = Number(this.state.runId);
    if (Number.isFinite(incoming) && Number.isFinite(current)) {
      return incoming >= current;
    }
    return runId === this.state.runId;
  }

  private async isRunnerTunnelHealthy(): Promise<boolean> {
    if (this.state.state !== "ready" || !this.state.runnerBaseUrl || !this.state.runnerToken) {
      return true;
    }
    return this.isTunnelUrlHealthy(this.state.runnerBaseUrl, this.state.runnerToken);
  }

  private async isTunnelUrlHealthy(baseUrl: string, simdeckToken: string): Promise<boolean> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 5000);
    try {
      const response = await fetch(`${baseUrl.replace(/\/+$/, "")}/api/health`, {
        headers: {
          accept: "application/json",
          "x-simdeck-token": simdeckToken
        },
        signal: controller.signal
      });
      return response.ok;
    } catch {
      return false;
    } finally {
      clearTimeout(timeout);
    }
  }
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    const session = env.SIMDECK_SESSION.getByName(SESSION_NAME);

    if (url.pathname.startsWith("/api/runner/")) {
      return handleRunnerRequest(request, session, env);
    }

    if (url.pathname === "/api/proxy/reset" && request.method === "POST") {
      return handleResetRequest(request, session, env);
    }

    if (url.pathname === "/login" || url.pathname === "/login.svg" || url.pathname === "/api/login") {
      return handleLoginRequest(request, env);
    }

    if (!(await isAuthorized(request, env.SIMDECK_ACCESS_TOKEN))) {
      return json({ ok: false, error: "Unauthorized" }, 401);
    }

    if (url.pathname === "/api/health") {
      const status = await session.status();
      return json(simdeckHealth(url, status));
    }

    if (url.pathname === "/api/proxy/status") {
      return json(await session.status());
    }

    if (!url.pathname.startsWith("/api/")) {
      return json({ ok: false, error: "Not found" }, 404);
    }

    const status = await session.ensureRunner(`${request.method} ${url.pathname}`, url.origin);
    if (status.state !== "ready" || !status.runnerBaseUrl) {
      return coldResponse(url.pathname, status);
    }

    ctx.waitUntil(session.recordActivity());
    return proxyToRunner(request, status, session, url.pathname, url.origin);
  }
};

async function handleLoginRequest(request: Request, env: Env): Promise<Response> {
  if (!env.CREDENTIALS_PASSWORD) {
    return json({ ok: false, error: "Credential password is not configured." }, 503);
  }
  if (!(await isPasswordAuthorized(request, env.CREDENTIALS_PASSWORD))) {
    return new Response(JSON.stringify({ ok: false, error: "Password required" }), {
      status: 401,
      headers: {
        ...JSON_HEADERS,
        "www-authenticate": 'Basic realm="SimDeck Cloud Credentials", charset="UTF-8"'
      }
    });
  }

  const url = new URL(request.url);
  const credentials = loginCredentials(url.origin, env.SIMDECK_ACCESS_TOKEN);
  if (url.pathname === "/api/login") {
    return json(credentials);
  }

  const svg = await qrToString(credentials.deepLink, {
    type: "svg",
    margin: 2,
    width: 320,
    color: {
      dark: "#101418",
      light: "#ffffff"
    }
  });

  if (url.pathname === "/login.svg") {
    return new Response(svg, {
      headers: {
        "content-type": "image/svg+xml; charset=utf-8",
        "cache-control": "no-store"
      }
    });
  }

  return new Response(loginHtml(credentials, svg), {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store"
    }
  });
}

async function handleResetRequest(
  request: Request,
  session: DurableObjectStub<SimDeckSession>,
  env: Env
): Promise<Response> {
  if (!env.CREDENTIALS_PASSWORD || !(await isPasswordAuthorized(request, env.CREDENTIALS_PASSWORD))) {
    return new Response(JSON.stringify({ ok: false, error: "Password required" }), {
      status: 401,
      headers: {
        ...JSON_HEADERS,
        "www-authenticate": 'Basic realm="SimDeck Cloud Credentials", charset="UTF-8"'
      }
    });
  }
  return json(await session.reset());
}

async function handleRunnerRequest(
  request: Request,
  session: DurableObjectStub<SimDeckSession>,
  env: Env
): Promise<Response> {
  if (!(await isAuthorized(request, env.RUNNER_CALLBACK_TOKEN ?? env.SIMDECK_ACCESS_TOKEN))) {
    return json({ ok: false, error: "Unauthorized" }, 401);
  }
  const url = new URL(request.url);
  if (url.pathname === "/api/runner/register" && request.method === "POST") {
    return json(await session.register(await request.json()));
  }
  if (url.pathname === "/api/runner/heartbeat" && request.method === "POST") {
    return json(await session.heartbeat(await request.json()));
  }
  if (url.pathname === "/api/runner/keepalive" && request.method === "POST") {
    return json(await session.keepalive(await request.json()));
  }
  return json({ ok: false, error: "Not found" }, 404);
}

function simdeckHealth(url: URL, status: StatusResponse): Record<string, unknown> {
  return {
    ok: true,
    serverId: "simdeck-cloud-proxy",
    hostId: "simdeck-cloud-proxy",
    hostName: "SimDeck Cloud",
    httpPort: url.port ? Number(url.port) : url.protocol === "https:" ? 443 : 80,
    serverKind: "cloudflare-proxy",
    realtimeStream: status.state === "ready",
    proxyStatus: status.state,
    statusMessage: status.message,
    runId: status.runId,
    runUrl: status.runUrl
  };
}

function coldResponse(pathname: string, status: StatusResponse): Response {
  if (pathname === "/api/simulators") {
    return json({
      simulators: [],
      proxyStatus: status.state,
      statusMessage: status.message,
      runId: status.runId,
      runUrl: status.runUrl
    });
  }
  if (pathname === "/api/simulators/create-options") {
    return json({
      deviceTypes: [],
      runtimes: [],
      android: null,
      proxyStatus: status.state,
      statusMessage: status.message
    });
  }
  return json({
    ok: false,
    error: "Mac runner is not ready yet.",
    proxyStatus: status.state,
    statusMessage: status.message,
    runId: status.runId,
    runUrl: status.runUrl
  }, 503);
}

async function proxyToRunner(
  request: Request,
  status: StatusResponse,
  session: DurableObjectStub<SimDeckSession>,
  pathname: string,
  proxyUrl: string
): Promise<Response> {
  const upstream = new URL(request.url);
  upstream.protocol = "https:";
  const base = new URL(status.runnerBaseUrl ?? "");
  upstream.protocol = base.protocol;
  upstream.host = base.host;
  upstream.pathname = `${base.pathname.replace(/\/+$/, "")}${upstream.pathname}`;

  const headers = new Headers(request.headers);
  if (status.runnerToken) {
    headers.set("x-simdeck-token", status.runnerToken);
  }

  const response = await fetch(upstream, {
    method: request.method,
    headers,
    body: request.body,
    redirect: "manual"
  });
  if (response.status === 502 || response.status === 530) {
    await session.tunnelDisconnected();
    const reconnectingStatus = await session.ensureRunner(`${request.method} ${pathname}`, proxyUrl);
    if (pathname === "/api/simulators" || pathname === "/api/simulators/create-options") {
      return coldResponse(pathname, reconnectingStatus);
    }
    return json({
      ok: false,
      error: "Runner tunnel is reconnecting.",
      proxyStatus: reconnectingStatus.state,
      statusMessage: reconnectingStatus.message,
      runId: reconnectingStatus.runId,
      runUrl: reconnectingStatus.runUrl
    }, 503);
  }
  if (pathname === "/api/simulators" && response.ok) {
    return normalizedSimulatorsResponse(response);
  }
  return response;
}

async function normalizedSimulatorsResponse(response: Response): Promise<Response> {
  const payload = await response.json<{ simulators?: unknown[] }>();
  const simulators = Array.isArray(payload.simulators)
    ? payload.simulators.map((simulator) => normalizeSimulator(simulator))
    : [];
  return json({
    ...payload,
    simulators,
    proxyStatus: "ready",
    statusMessage: `Mac ready. ${simulators.length} simulator${simulators.length === 1 ? "" : "s"}.`
  });
}

function normalizeSimulator(simulator: unknown): unknown {
  if (!simulator || typeof simulator !== "object") {
    return simulator;
  }
  const record = simulator as Record<string, unknown>;
  if (typeof record.platform === "string" && record.platform.trim()) {
    return record;
  }
  const metadata = [
    record.runtimeIdentifier,
    record.runtimeName,
    record.deviceTypeIdentifier,
    record.deviceTypeName,
    record.name
  ]
    .filter((value): value is string => typeof value === "string")
    .join(" ")
    .toLowerCase();
  let platform = "iOS";
  if (metadata.includes("watchos") || metadata.includes("apple-watch") || metadata.includes("apple watch")) {
    platform = "watchOS";
  } else if (metadata.includes("tvos") || metadata.includes("apple-tv") || metadata.includes("apple tv")) {
    platform = "tvOS";
  } else if (metadata.includes("vision") || metadata.includes("xros")) {
    platform = "visionOS";
  } else if (metadata.includes("android") || metadata.includes("pixel")) {
    platform = "Android";
  }
  return {
    ...record,
    platform
  };
}

async function isAuthorized(
  request: Request,
  expected: string,
  options: { allowQueryToken?: boolean } = {}
): Promise<boolean> {
  const url = new URL(request.url);
  const supplied = request.headers.get("x-simdeck-token")
    ?? bearerToken(request.headers.get("authorization"))
    ?? (options.allowQueryToken ? url.searchParams.get("token") : undefined)
    ?? "";
  return timingSafeEqual(supplied, expected);
}

async function isPasswordAuthorized(request: Request, expected: string): Promise<boolean> {
  const supplied = request.headers.get("x-simdeck-credentials-password")
    ?? basicPassword(request.headers.get("authorization"))
    ?? "";
  return timingSafeEqual(supplied, expected);
}

async function timingSafeEqual(left: string, right: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const leftBytes = encoder.encode(left);
  const rightBytes = encoder.encode(right);
  if (leftBytes.length !== rightBytes.length) {
    await crypto.subtle.digest("SHA-256", leftBytes);
    return false;
  }
  let diff = 0;
  for (let index = 0; index < leftBytes.length; index += 1) {
    diff |= leftBytes[index] ^ rightBytes[index];
  }
  return diff === 0;
}

function bearerToken(value: string | null): string | undefined {
  if (!value) {
    return undefined;
  }
  const match = /^Bearer\s+(.+)$/i.exec(value);
  return match?.[1];
}

function basicPassword(value: string | null): string | undefined {
  if (!value) {
    return undefined;
  }
  const match = /^Basic\s+(.+)$/i.exec(value);
  if (!match) {
    return undefined;
  }
  try {
    const decoded = atob(match[1]);
    const separatorIndex = decoded.indexOf(":");
    return separatorIndex >= 0 ? decoded.slice(separatorIndex + 1) : decoded;
  } catch {
    return undefined;
  }
}

function parseRunnerPayload(payload: unknown): { baseUrl: string; simdeckToken?: string; runId?: string; runUrl?: string } {
  const baseUrl = readString(payload, "baseUrl");
  if (!baseUrl || !/^https?:\/\//.test(baseUrl)) {
    throw new Error("baseUrl is required");
  }
  return {
    baseUrl,
    simdeckToken: readString(payload, "simdeckToken"),
    runId: readString(payload, "runId"),
    runUrl: readString(payload, "runUrl")
  };
}

function readString(payload: unknown, key: string): string | undefined {
  if (!payload || typeof payload !== "object") {
    return undefined;
  }
  const value = (payload as Record<string, unknown>)[key];
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function readBoolean(payload: unknown, key: string): boolean {
  if (!payload || typeof payload !== "object") {
    return false;
  }
  return (payload as Record<string, unknown>)[key] === true;
}

function githubApiUrl(env: Env, path: string): string {
  return `https://api.github.com/repos/${env.GITHUB_OWNER}/${env.GITHUB_REPO}${path}`;
}

function loginCredentials(baseUrl: string, token: string): Record<string, string> {
  const deepLink = new URL("simdeck://connect");
  deepLink.searchParams.set("url", baseUrl);
  deepLink.searchParams.set("token", token);
  deepLink.searchParams.set("hostName", "SimDeck Cloud");
  deepLink.searchParams.set("serverKind", "cloudflare-proxy");

  return {
    serverUrl: baseUrl,
    token,
    header: "X-SimDeck-Token",
    deepLink: deepLink.toString(),
    qrUrl: `${baseUrl}/login.svg`
  };
}

function loginHtml(credentials: Record<string, string>, svg: string): string {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SimDeck Cloud Login</title>
  <style>
    :root {
      color-scheme: light dark;
      font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: #f7f9fb;
      color: #101418;
    }
    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      padding: 32px;
    }
    main {
      width: min(100%, 680px);
      display: grid;
      gap: 22px;
    }
    h1 {
      margin: 0;
      font-size: 28px;
      line-height: 1.15;
    }
    p {
      margin: 0;
      color: #52606d;
    }
    dl {
      display: grid;
      gap: 12px;
      margin: 0;
    }
    dt {
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      color: #66727f;
      font-weight: 700;
    }
    dd {
      margin: 0;
      overflow-wrap: anywhere;
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      background: #ffffff;
      border: 1px solid #d9e1e8;
      border-radius: 8px;
      padding: 12px;
    }
    .qr {
      width: 320px;
      max-width: 100%;
      background: white;
      border: 1px solid #d9e1e8;
      border-radius: 8px;
      padding: 16px;
    }
    .qr svg {
      display: block;
      width: 100%;
      height: auto;
    }
    a {
      color: #0b66d8;
      font-weight: 700;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        background: #101418;
        color: #f7f9fb;
      }
      p, dt {
        color: #aeb8c2;
      }
      dd {
        background: #171d24;
        border-color: #303a45;
      }
    }
  </style>
</head>
<body>
  <main>
    <div>
      <h1>SimDeck Cloud Login</h1>
      <p>Scan the QR code with the SimDeck app, or paste the server URL and token manually.</p>
    </div>
    <div class="qr" aria-label="SimDeck app login QR code">${svg}</div>
    <p><a href="${escapeHtml(credentials.deepLink)}">Open in SimDeck</a></p>
    <dl>
      <div>
        <dt>Server URL</dt>
        <dd>${escapeHtml(credentials.serverUrl)}</dd>
      </div>
      <div>
        <dt>Token</dt>
        <dd>${escapeHtml(credentials.token)}</dd>
      </div>
      <div>
        <dt>Deep Link</dt>
        <dd>${escapeHtml(credentials.deepLink)}</dd>
      </div>
    </dl>
  </main>
</body>
</html>`;
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: JSON_HEADERS
  });
}
