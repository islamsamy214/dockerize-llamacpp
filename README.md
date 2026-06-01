# dockerize-llamacpp

Dockerized [llama.cpp](https://github.com/ggml-org/llama.cpp) — OpenAI-compatible
HTTP server + interactive CLI playground, with **on-demand model download** from
Hugging Face baked into the compose stack.

Based on [marcel-dempers/docker-development-youtube-series — `ai/models/llama-cpp`](https://github.com/marcel-dempers/docker-development-youtube-series/tree/master/ai/models/llama-cpp).
Tutorial's manual `wget`-the-GGUF step is replaced with an idempotent init
sidecar; everything else mirrors the source structure.

---

## Layout

```
.
├── docker-compose.server.yml   # HTTP inference server (+ model-init sidecar)
├── docker-compose.dev.yml      # interactive llama-cli playground
├── scripts/
│   └── fetch-model.sh          # one-shot HF downloader, runs as `model-init`
├── data/
│   ├── models/                 # GGUF files, bind-mounted /models
│   └── hf-cache/               # HF cache, bind-mounted /root/.cache/huggingface
├── .env                        # config (gitignored)
└── .env.example                # template
```

## Architecture — `docker-compose.server.yml`

Two services, single-responsibility:

| Service        | Role                                                                                             | Lifecycle                                |
| -------------- | ------------------------------------------------------------------------------------------------ | ---------------------------------------- |
| `model-init`   | Downloads `${SERVER_MODEL_HF_FILE}` from `${SERVER_MODEL_HF_REPO}` into `/models/${SERVER_MODEL_FILE}` if absent. Idempotent — re-runs are a no-op on cache hit. | One-shot, exits 0.                       |
| `llama-server` | Loads the local GGUF with `-m /models/...` and serves the OpenAI-compatible HTTP API on `:8080`. | Long-running, restarts unless explicitly stopped. |

`llama-server` declares `depends_on: model-init { condition: service_completed_successfully }`,
so it never starts before the file exists. `/models` is read-only on the server
(no need to mutate it post-download).

Download flow:

```text
docker compose up
        │
        ▼
┌────────────────┐
│  model-init    │  curl -fL --progress-bar  https://huggingface.co/<repo>/resolve/main/<file>
│  (writes /models)│  → /models/<file>.gguf.part → mv to <file>.gguf
└────────┬───────┘  Exits 0 on success or cache hit. Exits ≠0 on 404/network err.
         │
         ▼ (gated by service_completed_successfully)
┌────────────────┐
│  llama-server  │  /app/llama-server -m /models/<file>.gguf -ngl … -c … --metrics …
│  (reads /models)│  /health → 200 once the model is fully loaded.
└────────────────┘
```

`docker-compose.dev.yml` is unchanged from the source repo's pattern —
`llama-cli -hf <repo>:<quant>`, downloads into `/root/.cache/huggingface/`
(shared bind mount with the server compose, so cache is reused).

---

## Quick start

```bash
# 1. Copy .env template and tweak.
cp .env.example .env
$EDITOR .env

# 2. Boot the server. First run pulls the GGUF (~5 GB for Q4_K_M) into data/models/.
docker compose -f docker-compose.server.yml up -d

# 3. Watch the download + load.
docker compose -f docker-compose.server.yml logs -f

# 4. Sanity-check.
curl -fsS http://localhost:${HOST_PORT}/health
curl -fsS http://localhost:${HOST_PORT}/v1/models | jq
```

Web UI: `http://localhost:${HOST_PORT}`
Prometheus: `http://localhost:${HOST_PORT}/metrics`

Interactive CLI playground (separate compose, shares the HF cache):

```bash
docker compose -f docker-compose.dev.yml run --rm playground
# or drop straight to a shell:
docker compose -f docker-compose.dev.yml run --rm --entrypoint bash playground
```

---

## Configuration (`.env`)

| Var                     | Required | Default (from compose)                | Notes                                                                 |
| ----------------------- | -------- | ------------------------------------- | --------------------------------------------------------------------- |
| `LLAMA_IMAGE`           | ✅       | —                                     | e.g. `ghcr.io/ggml-org/llama.cpp:full-intel`                          |
| `HOST_PORT`             | ✅       | —                                     | Published port for the HTTP server.                                   |
| `MODELS_DIR`            | ✅       | —                                     | Host path → `/models`. Use `./data/models`.                           |
| `HF_CACHE_DIR`          | ✅       | —                                     | Host path → `/root/.cache/huggingface`. Use `./data/hf-cache`.        |
| `SERVER_MODEL_FILE`     | ⚠       | `gemma-4-E4B-it-Q4_K_M.gguf`          | **Flat filename** under `/models/`. Also the default HF filename.     |
| `SERVER_MODEL_HF_REPO`  | ⚠       | `ggml-org/gemma-4-E4B-it-GGUF`        | Hugging Face repo (`<user>/<model>`). No `:quant` suffix.             |
| `SERVER_MODEL_HF_FILE`  | ⚠       | = `SERVER_MODEL_FILE`                 | Only set if the filename inside the HF repo differs from your local. |
| `HF_TOKEN`              | optional | —                                     | Bearer token for gated repos.                                         |
| `NGL`                   | ✅       | —                                     | GPU layers offload. `0` CPU-only, `99` full offload.                  |
| `SERVER_CTX`            | ✅       | —                                     | Context length, tokens.                                                |
| `PARALLEL`              | ✅       | —                                     | Parallel request slots.                                                |
| `TEMP` / `TOP_P` / `TOP_K` | ✅    | —                                     | Sampling defaults.                                                     |
| `DEV_MODEL_HF`          | ✅       | —                                     | Used by `docker-compose.dev.yml`. Format: `<repo>:<quant>`.            |
| `DEV_CTX`               | ✅       | —                                     | Context length for the dev playground.                                 |
| `CPU_LIMIT`             | ✅       | —                                     | `deploy.resources.limits.cpus`.                                        |
| `MEM_LIMIT`             | ✅       | —                                     | `deploy.resources.limits.memory`.                                      |
| `MEM_RESERVATION`       | ✅       | —                                     | `deploy.resources.reservations.memory`.                                |

⚠ = strictly optional thanks to compose defaults, but you'll almost always set
`SERVER_MODEL_FILE` (and the matching repo if you change models).

### Swapping models

For most ggml-org GGUF repos the local + remote filenames match, so just:

```dotenv
SERVER_MODEL_FILE=qwen3-0.5b-q8_0.gguf
SERVER_MODEL_HF_REPO=ggml-org/Qwen3-0.5B-GGUF
```

If the file you want is named differently in the HF repo:

```dotenv
SERVER_MODEL_FILE=my-local-name.gguf
SERVER_MODEL_HF_REPO=<user>/<repo>
SERVER_MODEL_HF_FILE=actual-name-in-repo.gguf
```

Then:

```bash
docker compose -f docker-compose.server.yml up -d --force-recreate
```

`model-init` will fetch the new file if absent. Old GGUFs stay in `data/models/`
until you remove them.

### GPU access

Compose mounts `/dev/dri` into both containers and sets `ZES_ENABLE_SYSMAN=1`
for the Intel Arc / iGPU SYCL backend. For NVIDIA, swap to the CUDA llama.cpp
image and add the standard `deploy.resources.reservations.devices` GPU block;
remove the `/dev/dri` device mount.

---

## API

OpenAI-compatible. Common endpoints:

| Endpoint                    | Purpose                                  |
| --------------------------- | ---------------------------------------- |
| `GET  /health`              | Liveness — 200 once the model is loaded. |
| `GET  /v1/models`           | List loaded model(s).                    |
| `POST /v1/chat/completions` | Chat completions.                        |
| `POST /v1/completions`      | Raw completions.                         |
| `POST /v1/embeddings`       | Only if the model supports it.           |
| `GET  /metrics`             | Prometheus exposition format.            |
| `GET  /props`               | Loaded model props / server build info.  |

Smoke test:

```bash
curl -fsS http://localhost:${HOST_PORT}/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"messages":[{"role":"user","content":"say hi in 3 words"}]}' \
  | jq -r '.choices[0].message.content'
```

---

## Operations

### Observability

`--metrics` is on. Scrape `http://${HOST}:${HOST_PORT}/metrics` from Prometheus.
RED-style metrics (request rate, errors, latency) plus llama.cpp-specific
counters (tokens generated, prompt/eval timings, slot occupancy).

### Healthcheck

`curl -fsS http://localhost:8080/health` inside the container, every 30 s.
`start_period` is 120 s to absorb GPU init on first boot (download is no
longer in the critical path — `model-init` owns it).

### Idempotency

- Re-running `docker compose up` after a successful first boot: `model-init`
  logs `cache hit, skipping download` and exits 0 immediately; `llama-server`
  is up in seconds.
- Partial download crash: `.part` file survives the cleanup, never gets `mv`'d
  to the final name. Next run resumes by re-fetching the whole blob — HF
  doesn't currently support range resume through this script. (See follow-ups.)

### Cache layout

```
data/
├── models/
│   └── gemma-4-E4B-it-Q4_K_M.gguf         # what llama-server -m loads
└── hf-cache/
    └── hub/models--<repo>/snapshots/...   # populated by dev compose `-hf` calls
```

Server's cache (`data/models/`) and dev's HF cache (`data/hf-cache/`) are
independent — they hold separate copies. The dev compose's `-hf` flow lands in
`hf-cache/`; the server compose's sidecar lands in `models/`. If disk is tight,
delete whichever you don't use.

---

## Troubleshooting

| Symptom                                                   | Likely cause                                                                              |
| --------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `curl: (22) The requested URL returned error: 404`        | `SERVER_MODEL_HF_REPO` or `SERVER_MODEL_HF_FILE` doesn't match an actual file on HF. Check the repo's `Files` tab. |
| `model-init` 401/403                                      | Gated repo. Set `HF_TOKEN` in `.env` to a read token.                                     |
| `llama-server` boots into "router mode, no model"         | `-m` got an empty arg → `SERVER_MODEL_FILE` is unset. Check `docker compose config`.      |
| `failed to open GGUF file '/models/...'`                  | `SERVER_MODEL_FILE` in `.env` doesn't match what `model-init` actually downloaded. They must agree. |
| Bind-mount perms: `Operation not permitted` writing models | `data/models/` got created by docker as root. `sudo chown -R $USER:$USER data/`.          |
| SYCL warning spam about free memory on Arc iGPU           | Expected before `ZES_ENABLE_SYSMAN=1` takes effect; harmless otherwise.                   |

Inspect resolved compose config (vars + defaults applied):

```bash
docker compose -f docker-compose.server.yml config
```

---

## What's different from the source tutorial

| Aspect                  | Source                                       | Here                                                                                       |
| ----------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Server model acquisition | Manual `wget` into `./models/`               | `model-init` sidecar — curl + `--progress-bar`, atomic `.part → mv`, idempotent.            |
| Compose file count      | 1                                            | 2 — `dev` (playground) and `server` (HTTP).                                                 |
| `/models` mount         | rw, manual files                             | ro on the server; only `model-init` (rw) ever writes.                                       |
| Healthcheck             | none                                         | `/health` + generous `start_period`.                                                       |
| Resource limits / probes | not set                                      | `deploy.resources` limits + reservations, `security_opt: no-new-privileges`.                |
| Metrics                 | not enabled                                  | `--metrics` on, Prometheus at `/metrics`.                                                   |
| Env vars                | hard-coded                                   | All knobs in `.env`, validated by compose interpolation defaults.                           |

---

## Follow-ups / known gaps

- `fetch-model.sh` doesn't resume interrupted downloads. Switch to
  `curl -C - --retry 5` or `huggingface-cli download` if this bites.
- No image-pull-by-digest pin on `${LLAMA_IMAGE}` — pin in production.
- `data/` ends up owned by root after first `docker compose up`. Acceptable for
  a single-user dev box; `chown -R $USER:$USER data/` if it gets in your way.
- The `LLAMA_ARG_HOST environment variable is set, but will be overwritten by
  command line argument --host` log warning is benign — `--host 0.0.0.0` wins.
- Trivy/Grype scan on `${LLAMA_IMAGE}` in CI before promoting to prod.
