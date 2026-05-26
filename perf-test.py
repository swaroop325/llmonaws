#!/usr/bin/env python3
"""
vLLM Performance Test Suite

Runs comprehensive benchmarks covering:
- Baseline latency (single request, no contention)
- Throughput test (sustained load, measure tok/s)
- Concurrency ramp (find saturation point)
- Peak load test (find breaking point)
- Streaming latency (TTFT under load)

Usage:
    python perftest.py http://your-alb-dns
    python perftest.py http://your-alb-dns --concurrency 200 --duration 60
    python perftest.py http://your-alb-dns --output report.json
"""

import argparse
import asyncio
import json
import statistics
import sys
import time
from dataclasses import dataclass, field, asdict
from typing import Optional

try:
    import aiohttp
except ImportError:
    print("ERROR: aiohttp required. Install with: pip install aiohttp")
    sys.exit(1)


@dataclass
class RequestResult:
    latency_ms: float
    ttft_ms: Optional[float]
    tokens_in: int
    tokens_out: int
    status: int
    error: Optional[str] = None


@dataclass
class BenchmarkResult:
    name: str
    concurrency: int
    total_requests: int
    successful_requests: int
    failed_requests: int
    duration_s: float
    avg_latency_ms: float = 0
    p50_latency_ms: float = 0
    p90_latency_ms: float = 0
    p95_latency_ms: float = 0
    p99_latency_ms: float = 0
    max_latency_ms: float = 0
    min_latency_ms: float = 0
    avg_ttft_ms: float = 0
    p95_ttft_ms: float = 0
    tokens_per_second: float = 0
    requests_per_second: float = 0
    error_rate: float = 0


@dataclass
class PerfReport:
    endpoint: str
    model: str
    timestamp: str
    instance_info: dict = field(default_factory=dict)
    baseline: Optional[BenchmarkResult] = None
    throughput: Optional[BenchmarkResult] = None
    concurrency_ramp: list = field(default_factory=list)
    peak: Optional[BenchmarkResult] = None
    streaming: Optional[BenchmarkResult] = None
    summary: dict = field(default_factory=dict)


PROMPTS = [
    {"role": "user", "content": "Explain the concept of attention mechanisms in transformers in 3 sentences."},
    {"role": "user", "content": "Write a Python function that implements binary search. Include type hints."},
    {"role": "user", "content": "What are the key differences between TCP and UDP? Be concise."},
    {"role": "user", "content": "Describe the CAP theorem and its implications for distributed databases in 4 sentences."},
    {"role": "user", "content": "Write a haiku about machine learning inference optimization."},
    {"role": "user", "content": "Explain how KV-cache works in autoregressive language models. Keep it under 100 words."},
    {"role": "user", "content": "List 5 best practices for deploying ML models in production."},
    {"role": "user", "content": "What is quantization in the context of neural networks? Explain AWQ specifically."},
]


async def send_request(
    session: aiohttp.ClientSession,
    base_url: str,
    model: str,
    prompt_idx: int,
    max_tokens: int = 150,
    stream: bool = False,
) -> RequestResult:
    prompt = PROMPTS[prompt_idx % len(PROMPTS)]
    payload = {
        "model": model,
        "messages": [prompt],
        "max_tokens": max_tokens,
        "temperature": 0.7,
        "stream": stream,
    }

    start = time.perf_counter()
    ttft = None

    try:
        async with session.post(
            f"{base_url}/v1/chat/completions",
            json=payload,
            timeout=aiohttp.ClientTimeout(total=120),
        ) as resp:
            if stream and resp.status == 200:
                first_chunk = True
                async for line in resp.content:
                    decoded = line.decode("utf-8").strip()
                    if decoded.startswith("data:") and first_chunk:
                        chunk_data = decoded[5:].strip()
                        if chunk_data and chunk_data != "[DONE]":
                            ttft = (time.perf_counter() - start) * 1000
                            first_chunk = False
                # For streaming, we can't easily get token counts
                end = time.perf_counter()
                return RequestResult(
                    latency_ms=(end - start) * 1000,
                    ttft_ms=ttft,
                    tokens_in=len(prompt["content"].split()),
                    tokens_out=max_tokens,  # approximate
                    status=resp.status,
                )
            else:
                body = await resp.json()
                end = time.perf_counter()

                if resp.status != 200:
                    return RequestResult(
                        latency_ms=(end - start) * 1000,
                        ttft_ms=None,
                        tokens_in=0,
                        tokens_out=0,
                        status=resp.status,
                        error=body.get("error", {}).get("message", str(body)),
                    )

                usage = body.get("usage", {})
                return RequestResult(
                    latency_ms=(end - start) * 1000,
                    ttft_ms=None,
                    tokens_in=usage.get("prompt_tokens", 0),
                    tokens_out=usage.get("completion_tokens", 0),
                    status=resp.status,
                )

    except asyncio.TimeoutError:
        return RequestResult(
            latency_ms=(time.perf_counter() - start) * 1000,
            ttft_ms=None, tokens_in=0, tokens_out=0,
            status=0, error="timeout",
        )
    except Exception as e:
        return RequestResult(
            latency_ms=(time.perf_counter() - start) * 1000,
            ttft_ms=None, tokens_in=0, tokens_out=0,
            status=0, error=str(e),
        )


def compute_benchmark(
    name: str, concurrency: int, results: list[RequestResult], duration: float
) -> BenchmarkResult:
    successful = [r for r in results if r.status == 200]
    failed = [r for r in results if r.status != 200]

    if not successful:
        return BenchmarkResult(
            name=name, concurrency=concurrency,
            total_requests=len(results), successful_requests=0,
            failed_requests=len(failed), duration_s=duration,
            error_rate=1.0,
        )

    latencies = [r.latency_ms for r in successful]
    latencies.sort()
    total_tokens_out = sum(r.tokens_out for r in successful)
    ttfts = [r.ttft_ms for r in successful if r.ttft_ms is not None]

    def percentile(data, p):
        idx = int(len(data) * p / 100)
        return data[min(idx, len(data) - 1)]

    result = BenchmarkResult(
        name=name,
        concurrency=concurrency,
        total_requests=len(results),
        successful_requests=len(successful),
        failed_requests=len(failed),
        duration_s=duration,
        avg_latency_ms=statistics.mean(latencies),
        p50_latency_ms=percentile(latencies, 50),
        p90_latency_ms=percentile(latencies, 90),
        p95_latency_ms=percentile(latencies, 95),
        p99_latency_ms=percentile(latencies, 99),
        max_latency_ms=max(latencies),
        min_latency_ms=min(latencies),
        tokens_per_second=total_tokens_out / duration if duration > 0 else 0,
        requests_per_second=len(successful) / duration if duration > 0 else 0,
        error_rate=len(failed) / len(results) if results else 0,
    )

    if ttfts:
        ttfts.sort()
        result.avg_ttft_ms = statistics.mean(ttfts)
        result.p95_ttft_ms = percentile(ttfts, 95)

    return result


async def run_concurrent_batch(
    session: aiohttp.ClientSession,
    base_url: str,
    model: str,
    concurrency: int,
    num_requests: int,
    max_tokens: int = 150,
    stream: bool = False,
) -> list[RequestResult]:
    semaphore = asyncio.Semaphore(concurrency)
    results = []

    async def limited_request(idx):
        async with semaphore:
            return await send_request(session, base_url, model, idx, max_tokens, stream)

    tasks = [limited_request(i) for i in range(num_requests)]
    results = await asyncio.gather(*tasks)
    return list(results)


async def run_sustained_load(
    session: aiohttp.ClientSession,
    base_url: str,
    model: str,
    concurrency: int,
    duration_s: float,
    max_tokens: int = 150,
) -> list[RequestResult]:
    """Send requests continuously for a fixed duration."""
    results = []
    semaphore = asyncio.Semaphore(concurrency)
    stop_event = asyncio.Event()
    counter = 0

    async def worker():
        nonlocal counter
        while not stop_event.is_set():
            async with semaphore:
                if stop_event.is_set():
                    break
                counter += 1
                result = await send_request(
                    session, base_url, model, counter, max_tokens
                )
                results.append(result)

    workers = [asyncio.create_task(worker()) for _ in range(concurrency)]

    await asyncio.sleep(duration_s)
    stop_event.set()
    await asyncio.gather(*workers, return_exceptions=True)

    return results


async def test_baseline(session, base_url, model):
    """Single-request latency with no contention."""
    print("  Sending 5 sequential requests (no concurrency)...")
    results = []
    for i in range(5):
        r = await send_request(session, base_url, model, i, max_tokens=100)
        results.append(r)
    return compute_benchmark("baseline", 1, results, sum(r.latency_ms for r in results) / 1000)


async def test_throughput(session, base_url, model, duration):
    """Sustained load to measure peak throughput."""
    concurrency = 64
    print(f"  Sustained load at concurrency={concurrency} for {duration}s...")
    results = await run_sustained_load(session, base_url, model, concurrency, duration)
    return compute_benchmark("throughput", concurrency, results, duration)


async def test_concurrency_ramp(session, base_url, model):
    """Increase concurrency to find saturation point."""
    levels = [1, 5, 10, 25, 50, 75, 100, 150, 200]
    ramp_results = []

    for c in levels:
        num_requests = max(c * 2, 10)
        print(f"  Concurrency {c:>3} ({num_requests} requests)...", end="", flush=True)
        start = time.perf_counter()
        results = await run_concurrent_batch(session, base_url, model, c, num_requests)
        duration = time.perf_counter() - start
        bench = compute_benchmark(f"ramp_c{c}", c, results, duration)
        ramp_results.append(bench)
        print(
            f" avg={bench.avg_latency_ms:.0f}ms  p95={bench.p95_latency_ms:.0f}ms"
            f"  tok/s={bench.tokens_per_second:.0f}"
            f"  err={bench.error_rate:.1%}"
        )
        if bench.error_rate > 0.5:
            print("  [STOPPING - error rate > 50%]")
            break

    return ramp_results


async def test_peak(session, base_url, model):
    """Find breaking point - aggressive concurrency."""
    concurrency = 200
    num_requests = 400
    print(f"  Burst: {num_requests} requests at concurrency={concurrency}...")
    start = time.perf_counter()
    results = await run_concurrent_batch(session, base_url, model, concurrency, num_requests)
    duration = time.perf_counter() - start
    return compute_benchmark("peak", concurrency, results, duration)


async def test_streaming(session, base_url, model):
    """Measure TTFT under moderate load with streaming."""
    concurrency = 25
    num_requests = 50
    print(f"  Streaming: {num_requests} requests at concurrency={concurrency}...")
    start = time.perf_counter()
    results = await run_concurrent_batch(
        session, base_url, model, concurrency, num_requests, stream=True
    )
    duration = time.perf_counter() - start
    return compute_benchmark("streaming_ttft", concurrency, results, duration)


def print_report(report: PerfReport):
    print("\n")
    print("=" * 72)
    print("  vLLM PERFORMANCE TEST REPORT")
    print("=" * 72)
    print(f"  Endpoint : {report.endpoint}")
    print(f"  Model    : {report.model}")
    print(f"  Time     : {report.timestamp}")
    print("=" * 72)

    # Baseline
    if report.baseline:
        b = report.baseline
        print("\n--- BASELINE (single request, no contention) ---")
        print(f"  Avg latency     : {b.avg_latency_ms:.0f} ms")
        print(f"  Min latency     : {b.min_latency_ms:.0f} ms")
        print(f"  Max latency     : {b.max_latency_ms:.0f} ms")
        print(f"  Tokens/sec      : {b.tokens_per_second:.1f}")

    # Throughput
    if report.throughput:
        t = report.throughput
        print(f"\n--- THROUGHPUT (sustained, concurrency={t.concurrency}) ---")
        print(f"  Duration        : {t.duration_s:.1f}s")
        print(f"  Requests        : {t.successful_requests} ok / {t.failed_requests} failed")
        print(f"  Tokens/sec      : {t.tokens_per_second:.0f}")
        print(f"  Requests/sec    : {t.requests_per_second:.1f}")
        print(f"  Avg latency     : {t.avg_latency_ms:.0f} ms")
        print(f"  P95 latency     : {t.p95_latency_ms:.0f} ms")
        print(f"  Error rate      : {t.error_rate:.1%}")

    # Concurrency ramp
    if report.concurrency_ramp:
        print("\n--- CONCURRENCY RAMP ---")
        print(f"  {'Conc':>5} | {'Avg(ms)':>8} | {'P50(ms)':>8} | {'P95(ms)':>8} | {'P99(ms)':>8} | {'Tok/s':>7} | {'Err%':>5}")
        print(f"  {'─'*5} | {'─'*8} | {'─'*8} | {'─'*8} | {'─'*8} | {'─'*7} | {'─'*5}")
        for r in report.concurrency_ramp:
            print(
                f"  {r.concurrency:>5} | {r.avg_latency_ms:>8.0f} | {r.p50_latency_ms:>8.0f} "
                f"| {r.p95_latency_ms:>8.0f} | {r.p99_latency_ms:>8.0f} "
                f"| {r.tokens_per_second:>7.0f} | {r.error_rate:>5.1%}"
            )

    # Peak
    if report.peak:
        p = report.peak
        print(f"\n--- PEAK LOAD (concurrency={p.concurrency}) ---")
        print(f"  Requests        : {p.successful_requests} ok / {p.failed_requests} failed")
        print(f"  Tokens/sec      : {p.tokens_per_second:.0f}")
        print(f"  Avg latency     : {p.avg_latency_ms:.0f} ms")
        print(f"  P95 latency     : {p.p95_latency_ms:.0f} ms")
        print(f"  P99 latency     : {p.p99_latency_ms:.0f} ms")
        print(f"  Max latency     : {p.max_latency_ms:.0f} ms")
        print(f"  Error rate      : {p.error_rate:.1%}")

    # Streaming TTFT
    if report.streaming:
        s = report.streaming
        print(f"\n--- STREAMING TTFT (concurrency={s.concurrency}) ---")
        print(f"  Avg TTFT        : {s.avg_ttft_ms:.0f} ms")
        print(f"  P95 TTFT        : {s.p95_ttft_ms:.0f} ms")
        print(f"  Avg total       : {s.avg_latency_ms:.0f} ms")

    # Summary
    print("\n--- SUMMARY ---")
    if report.summary:
        for key, value in report.summary.items():
            print(f"  {key:20}: {value}")

    print("\n" + "=" * 72)


def compute_summary(report: PerfReport) -> dict:
    summary = {}

    if report.baseline:
        summary["Baseline latency"] = f"{report.baseline.avg_latency_ms:.0f} ms"

    if report.throughput:
        summary["Peak throughput"] = f"{report.throughput.tokens_per_second:.0f} tok/s"
        summary["Sustained RPS"] = f"{report.throughput.requests_per_second:.1f} req/s"

    # Find saturation point (where p95 > 2x baseline)
    if report.concurrency_ramp and report.baseline:
        baseline_lat = report.baseline.avg_latency_ms
        saturation_conc = None
        for r in report.concurrency_ramp:
            if r.p95_latency_ms > baseline_lat * 3:
                saturation_conc = r.concurrency
                break
        if saturation_conc:
            summary["Saturation point"] = f"~{saturation_conc} concurrent (p95 > 3x baseline)"
        else:
            last = report.concurrency_ramp[-1]
            summary["Saturation point"] = f"> {last.concurrency} concurrent (not reached)"

    # Max safe concurrency (error rate < 5%)
    if report.concurrency_ramp:
        max_safe = 0
        for r in report.concurrency_ramp:
            if r.error_rate < 0.05:
                max_safe = r.concurrency
        summary["Max safe concurrency"] = f"{max_safe} (< 5% errors)"

    if report.peak:
        summary["Peak error rate"] = f"{report.peak.error_rate:.1%} at c={report.peak.concurrency}"

    if report.streaming and report.streaming.avg_ttft_ms > 0:
        summary["Avg TTFT (loaded)"] = f"{report.streaming.avg_ttft_ms:.0f} ms"

    # Recommendation
    if report.throughput:
        tps = report.throughput.tokens_per_second
        if tps > 0:
            users_estimate = tps / 30  # ~30 tok/s per interactive user
            summary["Est. interactive users"] = f"~{int(users_estimate)} (at 30 tok/s each)"

    return summary


async def main():
    parser = argparse.ArgumentParser(description="vLLM Performance Test Suite")
    parser.add_argument("endpoint", help="Base URL (e.g., http://alb-dns-name)")
    parser.add_argument("--duration", type=int, default=30, help="Throughput test duration in seconds (default: 30)")
    parser.add_argument("--max-concurrency", type=int, default=200, help="Max concurrency for ramp test (default: 200)")
    parser.add_argument("--max-tokens", type=int, default=150, help="Max tokens per request (default: 150)")
    parser.add_argument("--output", type=str, help="Save JSON report to file")
    parser.add_argument("--skip", type=str, nargs="*", default=[], choices=["baseline", "throughput", "ramp", "peak", "streaming"], help="Skip specific tests")
    args = parser.parse_args()

    base_url = args.endpoint.rstrip("/")

    print(f"Connecting to {base_url}...")

    async with aiohttp.ClientSession() as session:
        # Discover model
        try:
            async with session.get(f"{base_url}/v1/models", timeout=aiohttp.ClientTimeout(total=10)) as resp:
                if resp.status != 200:
                    print(f"ERROR: /v1/models returned {resp.status}")
                    sys.exit(1)
                models = await resp.json()
                model = models["data"][0]["id"]
        except Exception as e:
            print(f"ERROR: Cannot reach endpoint: {e}")
            sys.exit(1)

        print(f"Model: {model}")
        print(f"Config: duration={args.duration}s, max_concurrency={args.max_concurrency}, max_tokens={args.max_tokens}")
        print("")

        report = PerfReport(
            endpoint=base_url,
            model=model,
            timestamp=time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime()),
        )

        # 1. Baseline
        if "baseline" not in args.skip:
            print("[1/5] BASELINE TEST")
            report.baseline = await test_baseline(session, base_url, model)
            print(f"       → {report.baseline.avg_latency_ms:.0f} ms avg latency\n")

        # 2. Throughput
        if "throughput" not in args.skip:
            print("[2/5] THROUGHPUT TEST")
            report.throughput = await test_throughput(session, base_url, model, args.duration)
            print(f"       → {report.throughput.tokens_per_second:.0f} tok/s, {report.throughput.requests_per_second:.1f} req/s\n")

        # 3. Concurrency ramp
        if "ramp" not in args.skip:
            print("[3/5] CONCURRENCY RAMP")
            report.concurrency_ramp = await test_concurrency_ramp(session, base_url, model)
            print("")

        # 4. Peak
        if "peak" not in args.skip:
            print("[4/5] PEAK LOAD TEST")
            report.peak = await test_peak(session, base_url, model)
            print(f"       → {report.peak.tokens_per_second:.0f} tok/s, {report.peak.error_rate:.1%} errors\n")

        # 5. Streaming TTFT
        if "streaming" not in args.skip:
            print("[5/5] STREAMING TTFT TEST")
            report.streaming = await test_streaming(session, base_url, model)
            if report.streaming.avg_ttft_ms > 0:
                print(f"       → {report.streaming.avg_ttft_ms:.0f} ms avg TTFT\n")
            else:
                print("       → TTFT not measurable (streaming may not be supported)\n")

    # Compute summary
    report.summary = compute_summary(report)

    # Print report
    print_report(report)

    # Save JSON
    if args.output:
        output_data = {
            "endpoint": report.endpoint,
            "model": report.model,
            "timestamp": report.timestamp,
            "baseline": asdict(report.baseline) if report.baseline else None,
            "throughput": asdict(report.throughput) if report.throughput else None,
            "concurrency_ramp": [asdict(r) for r in report.concurrency_ramp],
            "peak": asdict(report.peak) if report.peak else None,
            "streaming": asdict(report.streaming) if report.streaming else None,
            "summary": report.summary,
        }
        with open(args.output, "w") as f:
            json.dump(output_data, f, indent=2)
        print(f"\nJSON report saved to: {args.output}")


if __name__ == "__main__":
    asyncio.run(main())
