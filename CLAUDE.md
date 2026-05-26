# CLAUDE.md

## Project Overview

This is a production deployment repo for vLLM inference on AWS. It deploys Qwen2.5-32B-Instruct-AWQ with Marlin quantization on EC2 GPU instances (g5.12xlarge, 4x A10G) behind an ALB with autoscaling.

## Repository Structure

- Root scripts: `setup.sh`, `setup-cpu.sh`, `perf-test.py`, `healthcheck.sh`
- `terraform/` — AWS infrastructure (ALB, ASG, scaling, CloudWatch)
- `monitoring/` — Prometheus, Grafana, Alertmanager stack
- `docker-compose.yml` — vLLM container config with tuned flags

## Key Decisions

- Uses `vllm/vllm-openai:latest` Docker image (no source build)
- AWQ quantization with Marlin kernels for best speed/quality tradeoff
- Tensor parallelism = 4 (uses all GPUs on g5.12xlarge)
- Target: 50-200 concurrent users, sub-10s p95 latency
- Autoscaling based on ALB request count + p95 latency

## Running Locally (CPU mode)

```bash
./setup-cpu.sh
```

## Common Commands

```bash
# Deploy
cd terraform && terraform apply

# Test
./healthcheck.sh
python3 perf-test.py http://<endpoint>

# Monitor
cd monitoring && docker-compose up -d
```

## Style

- Shell scripts: bash, `set -euo pipefail`
- Terraform: standard HCL formatting
- Python: minimal dependencies (only aiohttp for perf-test)
