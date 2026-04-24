# Run Honcho Locally — One Script Setup

[Honcho](https://github.com/plastic-labs/honcho) is an open-source user-modeling memory layer for AI agents. This repository contains a single Bash script — `deploy.sh` — that bootstraps a complete Honcho development environment on your local machine with one command.

The script handles everything: cloning the Honcho source, installing Python dependencies, spinning up PostgreSQL and Redis via Docker, running database migrations, and starting the API server and background Deriver worker. It also gives you clean commands to stop, inspect, and fully reset the environment.

---

## What gets set up

| Component | How it runs | Default port |
|---|---|---|
| PostgreSQL 15 + pgvector | Docker container | `5433` |
| Redis 8 | Docker container | `6380` |
| Honcho API (FastAPI) | Native process via `uv` | `8000` |
| Deriver worker | Native process via `uv` | — |

Database data persists in a Docker named volume (`honcho-pgdata`) across restarts. The API and Deriver logs are written to `~/honcho/.honcho-local/logs/`.

---

## Prerequisites

You need the following installed before running the script:

- **Docker** — used to run PostgreSQL and Redis
- **Git** — used to clone the Honcho source repository
- **1Password CLI (`op`)** — used to inject API keys at runtime (see [API keys](#api-keys) below)

`uv` (the Python package manager) is required but the script installs it automatically if it is not found.

### Installing prerequisites on Arch Linux

```bash
sudo pacman -S docker git
sudo systemctl enable --now docker
# Install 1Password CLI:
yay -S 1password-cli
```

### Installing prerequisites on Ubuntu / Debian

```bash
sudo apt update && sudo apt install -y docker.io git
sudo systemctl enable --now docker
sudo usermod -aG docker $USER   # log out and back in after this
# Install 1Password CLI: https://developer.1password.com/docs/cli/get-started
```

### Installing prerequisites on macOS

```bash
brew install git 1password-cli
# Install Docker Desktop from https://www.docker.com/products/docker-desktop
```

Verify Docker is working before proceeding:

```bash
docker info
```

---

## Getting the script

Clone this repository and make the script executable:

```bash
git clone https://github.com/gtheys/setup-honcho.git
cd setup-honcho
chmod +x deploy.sh
```

Or download just the script directly:

```bash
curl -O https://raw.githubusercontent.com/gtheys/setup-honcho/main/deploy.sh
chmod +x deploy.sh
```

---

## API keys

API keys are stored in **1Password** and never written as plaintext to disk. The script uses the [1Password CLI](https://developer.1password.com/docs/cli) to resolve them at startup.

### Step 1 — Store keys in 1Password

Create a single item called **`Honcho`** in your **Personal** vault with the following fields:

| Field name | Value |
|---|---|
| `anthropic_key` | Your Anthropic API key (`sk-ant-...`) |
| `openai_key` | Your OpenAI API key (`sk-proj-...`) — optional, used for embeddings |

You can create it via the CLI:

```bash
op item create \
  --vault Personal \
  --category "API Credential" \
  --title "Honcho" \
  "anthropic_key[password]=sk-ant-..." \
  "openai_key[password]=sk-proj-..."
```

Or create it manually in the 1Password app with those exact field names.

### Step 2 — Make sure the 1Password app is running

The `op` CLI connects to the 1Password desktop app. Make sure it is open and unlocked before running `./deploy.sh up`.

### How it works

The `.env` file in `~/honcho/` stores `op://` references instead of plaintext keys:

```
LLM_ANTHROPIC_API_KEY=op://Personal/Honcho/anthropic_key
LLM_OPENAI_API_KEY=op://Personal/Honcho/openai_key
```

When you run `./deploy.sh up`, the script calls `op inject` to resolve these references into actual values and writes them into `.env` before starting the API and Deriver. When you run `./deploy.sh down`, the plaintext values are replaced back with `op://` references — so **keys are never left on disk at rest**.

| State | `.env` contains |
|---|---|
| Stopped (`down`) | `op://` references — no plaintext keys |
| Running (`up`) | Resolved plaintext keys (in memory / on disk only while running) |

---

## Quick start

```bash
./deploy.sh up
```

On the first run the script will:

1. Check that `docker`, `git`, and `op` are available (and install `uv` if missing)
2. Clone the Honcho repository into `~/honcho`
3. Install all Python dependencies
4. Write a `.env` file with `op://` key references
5. Resolve secrets from 1Password via `op inject`
6. Start PostgreSQL and Redis containers
7. Run Alembic database migrations
8. Start the Honcho API server and Deriver worker in the background

When everything is up you will see:

```
══════════════════════════════════════════════
  Honcho is running
══════════════════════════════════════════════

  API:       http://localhost:8000
  Docs:      http://localhost:8000/docs
  Postgres:  localhost:5433  (volume: honcho-pgdata)
  Redis:     localhost:6380
```

Open `http://localhost:8000/docs` in your browser to explore the interactive API documentation.

---

## Commands

| Command | Description |
|---|---|
| `./deploy.sh up` | Start everything (idempotent — safe to run again if already running) |
| `./deploy.sh down` | Stop the API, Deriver, and Docker containers. **Database data is preserved.** |
| `./deploy.sh status` | Show the running state of every component |
| `./deploy.sh logs` | Tail the live API and Deriver logs |
| `./deploy.sh psql` | Open an interactive `psql` shell connected to the Honcho database |
| `./deploy.sh nuke` | Stop everything **and permanently delete all database data** |

### `up` — start everything

```bash
./deploy.sh up
```

Idempotent: components that are already running are detected and skipped. Safe to re-run after a partial failure.

### `down` — stop gracefully

```bash
./deploy.sh down
```

Kills the API and Deriver processes and stops the Docker containers. The PostgreSQL data volume is left intact so your data survives. The `.env` file is restored to `op://` references — no plaintext keys remain on disk.

### `status` — inspect what's running

```bash
./deploy.sh status
```

Example output:

```
  Service          Status
  ───────────────  ─────────────
  PostgreSQL       running  :5433  vol=honcho-pgdata
  Redis            running  :6380
  Honcho API       running  :8000  PID=12345
  Deriver          running  PID=12346
```

### `logs` — tail live output

```bash
./deploy.sh logs
```

Streams both the API log and Deriver log to your terminal. Press `Ctrl+C` to stop tailing.

### `psql` — database shell

```bash
./deploy.sh psql
```

Drops you into a `psql` session as the `honcho` user in the `honcho` database. Useful for inspecting tables, running queries, or debugging migrations.

### `nuke` — full reset

```bash
./deploy.sh nuke
```

Stops all services, removes the Docker containers, **deletes the `honcho-pgdata` volume** (all database data), and removes the local state directory. You will be asked to confirm before anything is deleted. Use this to start completely fresh.

---

## Configuration

All configuration is done via environment variables. Set them in your shell before running the script to override defaults.

| Variable | Default | Description |
|---|---|---|
| `HONCHO_HOME` | `~/honcho` | Directory where the Honcho repo is cloned |
| `HONCHO_PG_PORT` | `5433` | Host port mapped to PostgreSQL |
| `HONCHO_REDIS_PORT` | `6380` | Host port mapped to Redis |
| `HONCHO_API_PORT` | `8000` | Host port the Honcho API listens on |

Example — run everything on non-default ports:

```bash
HONCHO_PG_PORT=5434 HONCHO_API_PORT=9000 ./deploy.sh up
```

---

## Directory layout

```
~/honcho/                        ← HONCHO_HOME (cloned Honcho source)
├── .env                         ← op:// references at rest, resolved keys while running
├── .honcho-local/
│   ├── pids/
│   │   ├── api.pid              ← PID of the running API process
│   │   └── deriver.pid          ← PID of the running Deriver process
│   └── logs/
│       ├── api.log              ← Honcho API stdout/stderr
│       └── deriver.log          ← Deriver worker stdout/stderr
└── ...                          ← Honcho source code
```

Docker resources:

| Resource | Name | Description |
|---|---|---|
| Container | `honcho-postgres` | PostgreSQL 15 + pgvector |
| Container | `honcho-redis` | Redis 8 |
| Volume | `honcho-pgdata` | Persistent PostgreSQL data |

---

## Data persistence

| Action | Database data | `.env` / API keys | Honcho source |
|---|---|---|---|
| `down` | **Preserved** | Preserved (`op://` refs restored) | Preserved |
| Reboot | **Preserved** | Preserved | Preserved |
| `nuke` | **Deleted** | Preserved | Preserved |

The database lives in the Docker named volume `honcho-pgdata`, which survives container removal. Only `./deploy.sh nuke` (or manually running `docker volume rm honcho-pgdata`) will delete it.

---

## Updating Honcho

The script pulls the latest Honcho source every time `up` is run:

```bash
./deploy.sh down
./deploy.sh up
```

`down` preserves the database, so `up` will apply any new migrations on top of your existing data automatically.

---

## Troubleshooting

### `Docker daemon not running`

```
[✗] Docker daemon not running. Start it: sudo systemctl start docker
```

Start Docker:

```bash
sudo systemctl start docker
```

Or to have it start automatically on boot:

```bash
sudo systemctl enable --now docker
```

### `Permission denied` when running Docker

If you see a permission error when the script tries to run Docker commands, your user is not in the `docker` group:

```bash
sudo usermod -aG docker $USER
```

Log out and back in for the group change to take effect, then re-run.

### `Failed to resolve secrets from 1Password`

```
[✗] Failed to resolve secrets from 1Password. Is the app running and unlocked?
```

Make sure the 1Password desktop app is open and unlocked, then re-run. The `op` CLI requires the app to be running to authenticate.

If the `Honcho` item doesn't exist yet, create it — see [API keys](#api-keys) above.

### Port already in use

If a service fails to start because the port is taken, run a different port:

```bash
HONCHO_API_PORT=9000 ./deploy.sh up
```

Or find and stop whatever is using the port:

```bash
ss -tlnp | grep 8000
```

### `.env` has wrong or missing keys

If you need to update the API keys stored in 1Password:

```bash
op item edit Honcho --vault Personal anthropic_key=sk-ant-...
```

Then restart:

```bash
./deploy.sh down
./deploy.sh up
```

### Viewing logs after a crash

```bash
./deploy.sh logs
# or read them directly:
cat ~/honcho/.honcho-local/logs/api.log
cat ~/honcho/.honcho-local/logs/deriver.log
```

### Starting completely fresh

```bash
./deploy.sh nuke
./deploy.sh up
```

---

## License

This setup script is released under the MIT License. Honcho itself is licensed separately — see the [Honcho repository](https://github.com/plastic-labs/honcho) for details.
