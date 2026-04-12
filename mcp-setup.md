# Honcho MCP Setup (Local)

This guide covers running the Honcho MCP server locally and wiring it into OpenCode. It assumes you have already run `./deploy.sh up` and Honcho is running at `http://localhost:8000`.

## Background

The hosted Honcho MCP server at `https://mcp.honcho.dev` is a Cloudflare Worker that proxies requests to `https://api.honcho.dev`. There is no way to point it at a local Honcho instance — the maintainers closed a PR proposing exactly that with the explanation:

> *"The MCP server is a thin stateless proxy, so if you're self-hosting Honcho, the natural path is to run the MCP server locally alongside it and point it at your instance via environment variables. Routing through the hosted Cloudflare Worker to reach a local backend doesn't make architectural sense from a latency or security standpoint."*

— [plastic-labs/honcho#540](https://github.com/plastic-labs/honcho/pull/540)

The Honcho repo ships a purpose-built local entrypoint for this: `mcp/src/local.ts`. It uses stdio transport and reads config from environment variables instead of request headers.

## Prerequisites

- Honcho running locally (`./deploy.sh up`)
- `bun` installed (`curl -fsSL https://bun.sh/install | bash`)

## How it works

`mcp/src/local.ts` is already present in the Honcho repo that `deploy.sh` clones to `~/honcho`. No extra installation needed — `bun install` in `~/honcho/mcp` is the only step.

```bash
cd ~/honcho/mcp
bun install
```

You can verify it starts correctly:

```bash
HONCHO_API_URL=http://localhost:8000/v3 \
HONCHO_API_KEY=local-dev-key \
HONCHO_USER_NAME=yourname \
HONCHO_WORKSPACE_ID=default \
bun run src/local.ts
```

Expected output on stderr (does not interfere with the MCP stdio protocol):

```
Honcho MCP Server (local) started
  API URL: http://localhost:8000/v3
  User: yourname
  Workspace: default
```

Press `Ctrl+C` to stop. OpenCode starts and stops the process automatically.

## OpenCode configuration

Add the following to your `opencode.json` (global config is at `~/.config/opencode/opencode.json`):

```json
{
  "mcp": {
    "honcho": {
      "type": "local",
      "command": [
        "bun",
        "run",
        "/home/youruser/honcho/mcp/src/local.ts"
      ],
      "environment": {
        "HONCHO_API_URL": "http://localhost:8000/v3",
        "HONCHO_API_KEY": "local-dev-key",
        "HONCHO_USER_NAME": "yourname",
        "HONCHO_WORKSPACE_ID": "default"
      },
      "enabled": true
    }
  }
}
```

Replace `/home/youruser` with your actual home directory and set `HONCHO_USER_NAME` to your name.

### Environment variables

| Variable | Value | Notes |
|---|---|---|
| `HONCHO_API_URL` | `http://localhost:8000/v3` | Must include `/v3` — all Honcho routes are mounted there |
| `HONCHO_API_KEY` | `local-dev-key` | Auth is disabled in the default local setup (`AUTH_USE_AUTH=false` in `.env`) — any non-empty string works |
| `HONCHO_USER_NAME` | your name | Used to scope memory to a peer |
| `HONCHO_WORKSPACE_ID` | `default` | Logical namespace for data; change if you want separate workspaces |

## Order of operations

Honcho must be running before OpenCode starts the MCP server, otherwise tool calls will fail with connection errors. Always run:

```bash
./deploy.sh up
```

before starting OpenCode. To check Honcho is healthy:

```bash
./deploy.sh status
curl -s http://localhost:8000/v3/workspaces | head -c 100
```

## Updating

When Honcho ships a new version, `./deploy.sh up` pulls it and re-runs migrations. The MCP server picks up changes automatically on the next OpenCode restart — no separate update step needed.
