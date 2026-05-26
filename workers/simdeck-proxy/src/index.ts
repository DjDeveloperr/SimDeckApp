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
const JSON_HEADERS = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store"
};

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
    await this.refreshFromGitHubIfNeeded();
    return {
      ...this.state,
      idleTimeoutSeconds: this.idleTimeoutSeconds()
    };
  }

  async ensureRunner(reason: string, proxyUrl: string): Promise<StatusResponse> {
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

  async register(payload: unknown): Promise<StatusResponse> {
    const parsed = parseRunnerPayload(payload);
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
    await this.setState({
      ...this.state,
      state: this.state.state === "idle" ? "starting" : this.state.state,
      message: message ?? this.state.message,
      lastHeartbeatAt: Date.now()
    });
    return this.status();
  }

  async keepalive(): Promise<{ shouldStop: boolean; idleForSeconds: number; status: StatusResponse }> {
    await this.refreshFromGitHubIfNeeded();
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
    return { shouldStop, idleForSeconds, status: await this.status() };
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

  private async refreshFromGitHubIfNeeded(): Promise<void> {
    if (this.state.state !== "starting" || this.state.runId || !this.state.requestedAt) {
      return;
    }
    if (Date.now() - this.state.requestedAt < 3500) {
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

  private async findRecentWorkflowRun(): Promise<{ id: number; html_url: string } | undefined> {
    const url = githubApiUrl(
      this.env,
      `/actions/workflows/${encodeURIComponent(this.env.GITHUB_WORKFLOW)}/runs?branch=${encodeURIComponent(this.env.GITHUB_REF)}&event=workflow_dispatch&per_page=5`
    );
    const response = await fetch(url, { headers: this.githubHeaders() });
    if (!response.ok) {
      return undefined;
    }
    const payload = await response.json<{ workflow_runs?: Array<{ id: number; html_url: string; created_at: string }> }>();
    return payload.workflow_runs?.[0];
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
    return proxyToRunner(request, status, url.pathname);
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
    return json(await session.keepalive());
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

async function proxyToRunner(request: Request, status: StatusResponse, pathname: string): Promise<Response> {
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
