# vLLM Production Deployment

Deploy Qwen2.5-32B-Instruct with AWQ quantization + Marlin kernels on AWS EC2 GPU instances behind an ALB. Optimized for 50-200 concurrent users with low latency.

## Architecture

```
Users → ALB (port 80/443) → ASG [2-8 g5.12xlarge] → vLLM (TP=4, Marlin-AWQ)
                                                        ↓
                                                  4x A10G per instance
                                                  ~700+ tok/s each
```

## Quick Start

```bash
# 1. Setup (finds AMI, checks quota, generates terraform config)
./setup.sh --region us-east-1

# 2. Deploy
cd terraform && terraform init && terraform apply

# 3. Verify
./healthcheck.sh

# 4. Benchmark
python3 perf-test.py http://<ALB_DNS>
```

## Files

| File | Purpose |
|------|---------|
| `setup.sh` | Interactive AWS setup (AMI lookup, key pair, quota check, tfvars generation) |
| `setup-cpu.sh` | Local CPU-only setup for development/testing |
| `perf-test.py` | Full performance benchmark (baseline, throughput, concurrency ramp, peak, TTFT) |
| `healthcheck.sh` | Smoke test: health, models, inference, metrics |
| `docker-compose.yml` | vLLM service config (AWQ + Marlin, TP=4, tuned for throughput) |
| `user-data.sh` | EC2 bootstrap (NVIDIA drivers + Docker + container toolkit) |
| `env.example` | Template for HuggingFace token |
| `terraform/` | Infrastructure: ALB, ASG, scaling policies, CloudWatch alarms |
| `monitoring/` | Prometheus + Grafana + Alertmanager with auto-provisioned dashboards |

## Key Configuration

| Parameter | Value | Why |
|-----------|-------|-----|
| `--tensor-parallel-size=4` | Use all 4 A10G GPUs per instance | 4x throughput vs single GPU |
| `--quantization=marlin` | Optimized CUDA kernels for AWQ | 1.6x faster than vanilla AWQ |
| `--max-num-seqs=512` | High concurrent batch size | Handles many users via continuous batching |
| `--num-scheduler-steps=8` | Multi-step scheduling | Reduces overhead between decode steps |
| `--enable-prefix-caching` | Reuse KV cache for common prefixes | Faster responses for repeated patterns |
| `--enable-chunked-prefill` | Overlap prefill with decode | Lower TTFT under load |

## Scaling

| Concurrent Users | Replicas | Expected Throughput |
|-----------------|----------|---------------------|
| 10-50 | 1-2 | ~700-1400 tok/s |
| 50-100 | 2-3 | ~1400-2100 tok/s |
| 100-200 | 3-4 | ~2100-2800 tok/s |
| 200+ | 4-8 | ~2800-5600 tok/s |

## Monitoring

```bash
cd monitoring && docker-compose up -d
```

- Prometheus: http://localhost:9090 (auto-discovers EC2 instances by tag)
- Grafana: http://localhost:3000 (admin/admin, dashboard pre-loaded)
- Alerts: latency spikes, queue backlog, cache exhaustion, instance down

## Cost Estimate (us-east-1, on-demand)

| Config | Monthly |
|--------|---------|
| 2x g5.12xlarge | ~$8,164 |
| 3x g5.12xlarge | ~$12,247 |
| Spot instances | 60-70% savings |

## Requirements

- AWS CLI configured (`aws configure`)
- Terraform >= 1.5
- Python 3.9+ with `aiohttp` (for perf-test)
- HuggingFace token (for gated models)
