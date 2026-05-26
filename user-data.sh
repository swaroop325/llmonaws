#!/bin/bash
set -euo pipefail

# EC2 User Data script for vLLM on GPU instances (g5.4xlarge / g5.12xlarge)
# Run as root on Amazon Linux 2023 or Ubuntu 22.04

echo "=== Installing NVIDIA drivers and Docker ==="

# For Amazon Linux 2023
if command -v dnf &>/dev/null; then
    dnf install -y docker nvidia-driver nvidia-fabric-manager
    systemctl enable --now docker
    systemctl enable --now nvidia-fabricmanager

    # Install nvidia-container-toolkit
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
        | tee /etc/yum.repos.d/nvidia-container-toolkit.repo
    dnf install -y nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
fi

# For Ubuntu 22.04
if command -v apt-get &>/dev/null; then
    apt-get update
    apt-get install -y docker.io nvidia-driver-550 nvidia-utils-550

    # Install nvidia-container-toolkit
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update
    apt-get install -y nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
fi

# Install docker-compose
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

echo "=== Pulling vLLM image ==="
docker pull vllm/vllm-openai:latest

echo "=== Starting vLLM service ==="
cd /opt/vllm
docker-compose up -d

echo "=== Setup complete ==="
