#!/bin/bash
set -euo pipefail

exec > /var/log/vllm-setup.log 2>&1

echo "=== vLLM Setup Started at $(date) ==="

# Move Docker/containerd to NVMe instance store for space
# The DL AMI mounts ephemeral NVMe at /opt/dlami/nvme
NVME_PATH="/opt/dlami/nvme"
if [ -d "$NVME_PATH" ]; then
    echo "Moving Docker and containerd to NVMe instance store..."
    systemctl stop docker containerd

    mkdir -p "$NVME_PATH/docker" "$NVME_PATH/containerd"
    rsync -a /var/lib/docker/ "$NVME_PATH/docker/" || true
    rsync -a /var/lib/containerd/ "$NVME_PATH/containerd/" || true
    rm -rf /var/lib/docker /var/lib/containerd
    ln -s "$NVME_PATH/docker" /var/lib/docker
    ln -s "$NVME_PATH/containerd" /var/lib/containerd

    systemctl start containerd docker
    echo "Docker data moved to $NVME_PATH"
fi

echo "=== Setting up vLLM ==="
mkdir -p /opt/vllm

cat > /opt/vllm/.env <<ENVEOF
HF_TOKEN=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
ENVEOF

cat > /opt/vllm/docker-compose.yml <<'COMPOSEEOF'
services:
  vllm:
    image: vllm/vllm-openai:latest
    runtime: nvidia
    ports:
      - "8000:8000"
    volumes:
      - model-cache:/root/.cache/huggingface
    environment:
      - HUGGING_FACE_HUB_TOKEN=$${HF_TOKEN}
      - VLLM_USAGE_SOURCE=production
      - CUDA_VISIBLE_DEVICES=0,1,2,3
    command:
      - --model=Qwen/Qwen2.5-32B-Instruct-AWQ
      - --quantization=awq
      - --host=0.0.0.0
      - --port=8000
      - --tensor-parallel-size=4
      - --gpu-memory-utilization=0.90
      - --max-model-len=4096
      - --max-num-seqs=256
      - --max-num-batched-tokens=8192
      - --enable-prefix-caching
      - --served-model-name=qwen2.5-32b
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 300s
    restart: unless-stopped
    ulimits:
      memlock:
        soft: -1
        hard: -1
    shm_size: '4gb'

volumes:
  model-cache:
COMPOSEEOF

echo "=== Pulling vLLM image ==="
docker pull vllm/vllm-openai:latest

echo "=== Starting vLLM ==="
cd /opt/vllm
docker compose --env-file .env up -d

echo "=== Setup complete at $(date) ==="
