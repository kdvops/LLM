#!/bin/sh
set -eu

MODEL="${MODEL_PATH:-/models/qwen2.5-coder-3b-instruct-q4_k_m.gguf}"

if [ ! -s "${MODEL}" ]; then
  echo "ERROR: GGUF model not found: ${MODEL}" >&2
  exit 1
fi

exec /usr/local/bin/llama-server       --model "${MODEL}"       --host 0.0.0.0       --port 8080       --ctx-size "${CTX_SIZE:-4096}"       --threads "${THREADS:-4}"       --threads-batch "${THREADS_BATCH:-4}"       --batch-size "${BATCH_SIZE:-256}"       --ubatch-size "${UBATCH_SIZE:-128}"       --parallel "${PARALLEL:-1}"       --cache-type-k "${CACHE_TYPE_K:-q8_0}"       --cache-type-v "${CACHE_TYPE_V:-q8_0}"
