#!/bin/bash
set -euo pipefail

# Local CPU-only setup for development and testing
# Runs vLLM with a small model on CPU (no GPU required)

echo "=== vLLM Local CPU Setup ==="

if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker is required. Install from https://docs.docker.com/get-docker/"
    exit 1
fi

if ! docker info &>/dev/null 2>&1; then
    echo "ERROR: Docker daemon is not running."
    exit 1
fi

echo "Starting vLLM with a small CPU-compatible model (facebook/opt-125m)..."
echo ""

docker run --rm -it \
    -p 8000:8000 \
    -v "${HOME}/.cache/huggingface:/root/.cache/huggingface" \
    vllm/vllm-openai:latest \
    --model=facebook/opt-125m \
    --host=0.0.0.0 \
    --port=8000 \
    --dtype=float32 \
    --device=cpu \
    --max-model-len=512 \
    --served-model-name=opt-125m

# Server runs in foreground. Test with:
# curl http://localhost:8000/v1/chat/completions \
#   -H "Content-Type: application/json" \
#   -d '{"model":"opt-125m","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}'
