# SimDeck Cloud Proxy

Private Cloudflare Worker that looks like a SimDeck server, wakes a GitHub Actions macOS runner on demand, and proxies SimDeck API traffic to that runner.

## Secrets

Worker secrets:

```sh
cd workers/simdeck-proxy
npx wrangler secret put SIMDECK_ACCESS_TOKEN
npx wrangler secret put GITHUB_TOKEN
npx wrangler secret put CREDENTIALS_PASSWORD
npx wrangler secret put RUNNER_CALLBACK_TOKEN
```

GitHub repository secret:

```sh
gh secret set SIMDECK_PROXY_RUNNER_TOKEN
```

Use the same value for `RUNNER_CALLBACK_TOKEN` and `SIMDECK_PROXY_RUNNER_TOKEN`.

## Deploy

```sh
cd workers/simdeck-proxy
npm install
npm run check
npm run deploy
```

Connect from the iOS app with the Worker URL and the `SIMDECK_ACCESS_TOKEN`. The first `/api/simulators` request dispatches `.github/workflows/simdeck-on-demand-mac.yml`; the app will show the proxy status while GitHub starts the macOS runner.

Open `/login` in a browser to generate manual app credentials and a QR code. That page is protected by HTTP Basic Auth; use any username and the `CREDENTIALS_PASSWORD` value as the password.
