#!/bin/sh
# Idempotent GGUF fetcher. Runs once as the `model-init` sidecar before
# llama-server starts. Mirrors source repo structure: file lands flat in
# /models/<SERVER_MODEL_FILE>, then llama-server loads it via -m.
set -eu

: "${SERVER_MODEL_FILE:?required (local filename under /models)}"
: "${SERVER_MODEL_HF_REPO:?required, e.g. ggml-org/gemma-3n-E4B-it-GGUF}"
: "${SERVER_MODEL_HF_FILE:?required, e.g. gemma-3n-E4B-it-Q8_0.gguf}"

MODEL_PATH="/models/${SERVER_MODEL_FILE}"

if [ -f "${MODEL_PATH}" ]; then
  echo "[fetch-model] cache hit, skipping download: ${MODEL_PATH}" >&2
  exit 0
fi

URL="https://huggingface.co/${SERVER_MODEL_HF_REPO}/resolve/main/${SERVER_MODEL_HF_FILE}"
TMP="${MODEL_PATH}.part"
echo "[fetch-model] downloading ${URL}" >&2
echo "[fetch-model] target      ${MODEL_PATH}" >&2

# --progress-bar surfaces % done in `docker compose up` logs. Atomic .part -> mv
# guards against half-written files surviving a crash/restart.
if [ -n "${HF_TOKEN:-}" ]; then
  curl -fL --progress-bar --retry 3 --retry-delay 5 \
    -H "Authorization: Bearer ${HF_TOKEN}" \
    -o "${TMP}" "${URL}"
else
  curl -fL --progress-bar --retry 3 --retry-delay 5 \
    -o "${TMP}" "${URL}"
fi
mv "${TMP}" "${MODEL_PATH}"
echo "[fetch-model] done: ${MODEL_PATH}" >&2
