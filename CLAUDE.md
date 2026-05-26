# CLAUDE.md

## Project Overview

Production deployment for vLLM inference on AWS. Deploys Qwen2.5-32B-Instruct-AWQ on EC2 GPU instances (g4dn.12xlarge, 4x T4) behind an ALB.

## Repository Structure

- `setup.sh` — Automated setup (finds AMI, creates key pair, checks quotas, generates tfvars)
- `user-data.sh` — EC2 bootstrap (moves Docker to NVMe, pulls vLLM, starts container)
- `perf-test.py` — Performance benchmark suite (baseline, throughput, ramp, peak, streaming)
- `healthcheck.sh` — Smoke test for deployed endpoint
- `docker-compose.yml` — vLLM container config (reference copy)
- `terraform/` — AWS infrastructure (ALB, ASG, scaling, CloudWatch)
- `monitoring/` — Prometheus, Grafana, Alertmanager stack

## Key Decisions

- **Instance**: `g4dn.12xlarge` (4x T4 16GB each) in ap-southeast-1
- **Image**: `vllm/vllm-openai:latest` — entrypoint is `vllm serve`, pass args via `command:`
- **Quantization**: AWQ (not Marlin — T4 compute capability 7.5 doesn't support it)
- **Tensor parallelism**: 4, context: 4096 tokens
- **Storage**: Docker/containerd symlinked to NVMe instance store (root vol only 30GB)
- **Health grace**: 900s (model download + torch.compile ~5 min)

## Deployment

```bash
./setup.sh
cd terraform && terraform init && terraform apply
# Wait ~5 min for model load
./healthcheck.sh
python3 perf-test.py http://<alb-dns> --output perf-report.json
```

## SSH & Debugging

```bash
ssh -i ~/.ssh/vllm-deploy-ap-southeast-1.pem ubuntu@<ip>
sudo cat /var/log/vllm-setup.log    # user-data output
sudo docker logs vllm-vllm-1        # vLLM server logs
```

## Critical Gotchas (DL AMI + vLLM v0.21+)

1. DL AMI has Docker pre-installed — do NOT `apt install docker.io` (conflicts with containerd.io)
2. Root volume is 30GB — must move Docker to NVMe (`/opt/dlami/nvme`) before pulling images
3. vLLM entrypoint is `vllm serve` — do NOT add `serve` in compose command
4. `--disable-log-requests` removed in v0.21 — omit it
5. ALB requires subnets in 2+ AZs — setup.sh creates them if needed
6. g5 instances NOT available in ap-southeast-1 — use g4dn.12xlarge

## Style

- Shell scripts: bash, `set -euo pipefail`
- Terraform: standard HCL formatting
- Python: minimal dependencies (only aiohttp for perf-test)
