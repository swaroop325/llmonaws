#!/usr/bin/env python3
"""Generate PDF performance report from perf-test results."""

import json
import os
from datetime import datetime

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.backends.backend_pdf import PdfPages
import numpy as np


def load_results(path="/tmp/perf-results.json"):
    with open(path) as f:
        return json.load(f)


def create_report(data, output_path):
    with PdfPages(output_path) as pdf:
        # Page 1: Title + Executive Summary
        fig, ax = plt.subplots(figsize=(11, 8.5))
        ax.axis('off')

        ax.text(0.5, 0.92, 'vLLM Performance Report', fontsize=28, fontweight='bold',
                ha='center', va='top', transform=ax.transAxes)
        ax.text(0.5, 0.86, 'Qwen2.5-32B-Instruct-AWQ on AWS g4dn.12xlarge',
                fontsize=14, ha='center', va='top', transform=ax.transAxes, color='#555')
        ax.text(0.5, 0.82, f'Test Date: {data["timestamp"]}',
                fontsize=11, ha='center', va='top', transform=ax.transAxes, color='#777')

        # Infrastructure box
        infra_text = (
            "INFRASTRUCTURE\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            "Instance:     g4dn.12xlarge (4x NVIDIA Tesla T4)\n"
            "GPU Memory:   4 × 16 GB = 64 GB total\n"
            "Model:        Qwen2.5-32B-Instruct-AWQ\n"
            "Quantization: AWQ with Marlin kernels\n"
            "Parallelism:  Tensor-parallel = 4\n"
            "Engine:       vLLM v0.21 (vllm-openai:latest)\n"
            "Max Seq Len:  4096 tokens\n"
            "Region:       ap-southeast-1 (Singapore)\n"
            "Endpoint:     ALB → single EC2 instance"
        )
        ax.text(0.08, 0.72, infra_text, fontsize=10, va='top', transform=ax.transAxes,
                fontfamily='monospace', bbox=dict(boxstyle='round,pad=0.5', facecolor='#f0f4ff', edgecolor='#ccc'))

        # Key metrics box
        summary = data.get("summary", {})
        metrics_text = (
            "KEY FINDINGS\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            f"Peak Throughput:       {summary.get('Peak throughput', 'N/A')}\n"
            f"Sustained RPS:         {summary.get('Sustained RPS', 'N/A')}\n"
            f"Baseline Latency:      {summary.get('Baseline latency', 'N/A')}\n"
            f"Saturation Point:      {summary.get('Saturation point', 'N/A')}\n"
            f"Max Safe Concurrency:  {summary.get('Max safe concurrency', 'N/A')}\n"
            f"Breaking Point:        c=750 (65.6% errors)\n"
            f"TTFT Under Load:       {summary.get('Avg TTFT (loaded)', 'N/A')}\n"
            f"Est. Interactive Users: {summary.get('Est. interactive users', 'N/A')}"
        )
        ax.text(0.08, 0.38, metrics_text, fontsize=10, va='top', transform=ax.transAxes,
                fontfamily='monospace', bbox=dict(boxstyle='round,pad=0.5', facecolor='#f0fff0', edgecolor='#ccc'))

        # GPU utilization note
        gpu_text = (
            "GPU UTILIZATION DURING LOAD\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            "GPU 0 (T4): 100% compute, 82% memory, 75W\n"
            "GPU 1 (T4): 100% compute, 80% memory, 73W\n"
            "GPU 2 (T4): 100% compute, 82% memory, 73W\n"
            "GPU 3 (T4): 100% compute, 83% memory, 58W\n"
            "\n"
            "Note: CPU utilization stays low (~11%) because\n"
            "all inference runs on GPUs. This is expected."
        )
        ax.text(0.52, 0.38, gpu_text, fontsize=10, va='top', transform=ax.transAxes,
                fontfamily='monospace', bbox=dict(boxstyle='round,pad=0.5', facecolor='#fff8f0', edgecolor='#ccc'))

        pdf.savefig(fig)
        plt.close()

        # Page 2: Concurrency Ramp Charts
        ramp = data.get("concurrency_ramp", [])
        if ramp:
            fig, axes = plt.subplots(2, 2, figsize=(11, 8.5))
            fig.suptitle('Concurrency Ramp Analysis', fontsize=16, fontweight='bold', y=0.96)

            concurrencies = [r["concurrency"] for r in ramp]
            avg_latencies = [r["avg_latency_ms"] / 1000 for r in ramp]
            p95_latencies = [r["p95_latency_ms"] / 1000 for r in ramp]
            p99_latencies = [r["p99_latency_ms"] / 1000 for r in ramp]
            tok_s = [r["tokens_per_second"] for r in ramp]
            error_rates = [r["error_rate"] * 100 for r in ramp]

            # Chart 1: Latency vs Concurrency
            ax1 = axes[0, 0]
            ax1.plot(concurrencies, avg_latencies, 'b-o', label='Avg', linewidth=2, markersize=6)
            ax1.plot(concurrencies, p95_latencies, 'r-s', label='P95', linewidth=2, markersize=6)
            ax1.plot(concurrencies, p99_latencies, 'g-^', label='P99', linewidth=1.5, markersize=5)
            ax1.set_xlabel('Concurrent Requests')
            ax1.set_ylabel('Latency (seconds)')
            ax1.set_title('Latency vs Concurrency')
            ax1.legend()
            ax1.grid(True, alpha=0.3)
            ax1.set_ylim(bottom=0)

            # Chart 2: Throughput vs Concurrency
            ax2 = axes[0, 1]
            ax2.bar(range(len(concurrencies)), tok_s, color='#4CAF50', alpha=0.8)
            ax2.set_xticks(range(len(concurrencies)))
            ax2.set_xticklabels([str(c) for c in concurrencies], rotation=45)
            ax2.set_xlabel('Concurrent Requests')
            ax2.set_ylabel('Tokens/second')
            ax2.set_title('Throughput vs Concurrency')
            ax2.grid(True, alpha=0.3, axis='y')
            # Add sustained throughput reference line
            if data.get("throughput"):
                sustained_tps = data["throughput"]["tokens_per_second"]
                ax2.axhline(y=sustained_tps, color='red', linestyle='--', alpha=0.7,
                           label=f'Sustained: {sustained_tps:.0f} tok/s')
                ax2.legend()

            # Chart 3: Error Rate vs Concurrency
            ax3 = axes[1, 0]
            colors = ['#4CAF50' if e < 5 else '#FF9800' if e < 20 else '#F44336' for e in error_rates]
            ax3.bar(range(len(concurrencies)), error_rates, color=colors, alpha=0.8)
            ax3.set_xticks(range(len(concurrencies)))
            ax3.set_xticklabels([str(c) for c in concurrencies], rotation=45)
            ax3.set_xlabel('Concurrent Requests')
            ax3.set_ylabel('Error Rate (%)')
            ax3.set_title('Error Rate vs Concurrency')
            ax3.axhline(y=5, color='green', linestyle='--', alpha=0.5, label='5% threshold')
            ax3.axhline(y=50, color='red', linestyle='--', alpha=0.5, label='50% breaking point')
            ax3.legend()
            ax3.grid(True, alpha=0.3, axis='y')

            # Chart 4: Combined view - Tokens/s and Error Rate
            ax4 = axes[1, 1]
            ax4_twin = ax4.twinx()
            line1 = ax4.plot(concurrencies, tok_s, 'b-o', label='Throughput (tok/s)', linewidth=2)
            line2 = ax4_twin.plot(concurrencies, error_rates, 'r-s', label='Error Rate (%)', linewidth=2)
            ax4.set_xlabel('Concurrent Requests')
            ax4.set_ylabel('Tokens/second', color='blue')
            ax4_twin.set_ylabel('Error Rate (%)', color='red')
            ax4.set_title('Throughput vs Error Rate Tradeoff')
            lines = line1 + line2
            labels = [l.get_label() for l in lines]
            ax4.legend(lines, labels, loc='center left')
            ax4.grid(True, alpha=0.3)

            plt.tight_layout(rect=[0, 0, 1, 0.94])
            pdf.savefig(fig)
            plt.close()

        # Page 3: Detailed Results + Recommendations
        fig, ax = plt.subplots(figsize=(11, 8.5))
        ax.axis('off')

        ax.text(0.5, 0.96, 'Detailed Results & Recommendations', fontsize=18, fontweight='bold',
                ha='center', va='top', transform=ax.transAxes)

        # Baseline section
        baseline = data.get("baseline")
        throughput = data.get("throughput")
        peak = data.get("peak")
        streaming = data.get("streaming")

        y = 0.88
        if baseline:
            section = (
                "BASELINE (Single Request, No Contention)\n"
                f"  Average Latency:  {baseline['avg_latency_ms']:.0f} ms ({baseline['avg_latency_ms']/1000:.1f}s)\n"
                f"  Min Latency:      {baseline['min_latency_ms']:.0f} ms\n"
                f"  Max Latency:      {baseline['max_latency_ms']:.0f} ms\n"
                f"  Tokens/sec:       {baseline['tokens_per_second']:.1f}\n"
            )
            ax.text(0.05, y, section, fontsize=9, va='top', transform=ax.transAxes, fontfamily='monospace')
            y -= 0.14

        if throughput:
            section = (
                f"THROUGHPUT (Sustained Load, concurrency={throughput['concurrency']})\n"
                f"  Duration:         {throughput['duration_s']:.0f}s\n"
                f"  Successful:       {throughput['successful_requests']} / {throughput['total_requests']} requests\n"
                f"  Tokens/sec:       {throughput['tokens_per_second']:.0f}\n"
                f"  Requests/sec:     {throughput['requests_per_second']:.1f}\n"
                f"  Avg Latency:      {throughput['avg_latency_ms']/1000:.1f}s\n"
                f"  P95 Latency:      {throughput['p95_latency_ms']/1000:.1f}s\n"
                f"  Error Rate:       {throughput['error_rate']*100:.1f}%\n"
            )
            ax.text(0.05, y, section, fontsize=9, va='top', transform=ax.transAxes, fontfamily='monospace')
            y -= 0.18

        if peak:
            section = (
                f"PEAK LOAD (concurrency={peak['concurrency']})\n"
                f"  Successful:       {peak['successful_requests']} / {peak['total_requests']} requests\n"
                f"  Tokens/sec:       {peak['tokens_per_second']:.0f}\n"
                f"  Avg Latency:      {peak['avg_latency_ms']/1000:.1f}s\n"
                f"  P95 Latency:      {peak['p95_latency_ms']/1000:.1f}s\n"
                f"  Error Rate:       {peak['error_rate']*100:.1f}%\n"
            )
            ax.text(0.05, y, section, fontsize=9, va='top', transform=ax.transAxes, fontfamily='monospace')
            y -= 0.15

        if streaming:
            section = (
                f"STREAMING (concurrency={streaming['concurrency']})\n"
                f"  Avg TTFT:         {streaming['avg_ttft_ms']:.0f} ms\n"
                f"  P95 TTFT:         {streaming['p95_ttft_ms']:.0f} ms\n"
                f"  Avg Total:        {streaming['avg_latency_ms']/1000:.1f}s\n"
            )
            ax.text(0.05, y, section, fontsize=9, va='top', transform=ax.transAxes, fontfamily='monospace')
            y -= 0.12

        # Recommendations
        recommendations = (
            "RECOMMENDATIONS\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            "• Max safe concurrency: 200 (0% errors, ~60s avg latency)\n"
            "• Optimal concurrency: 100-150 (best latency/throughput balance)\n"
            "• For interactive use: limit to 50 concurrent users (sub-50s response)\n"
            "• Breaking point: 500+ concurrent (>48% errors)\n"
            "• To increase capacity: add more instances (ASG min/max > 1) or upgrade to g5.12xlarge\n"
            "• Baseline latency is ~30s due to 256 max_tokens with 32B model on T4 GPUs\n"
            "• TTFT (Time To First Token) is excellent at ~2.1s even under 100 concurrent load\n"
            "• GPU utilization hits 100% during load — instance is fully utilized\n"
            "• CPU stays at ~11% — this is NORMAL for GPU inference workloads"
        )
        ax.text(0.05, y, recommendations, fontsize=9, va='top', transform=ax.transAxes,
                fontfamily='monospace', bbox=dict(boxstyle='round,pad=0.3', facecolor='#fffff0', edgecolor='#ccc'))

        pdf.savefig(fig)
        plt.close()

        # Page 4: Concurrency ramp table
        fig, ax = plt.subplots(figsize=(11, 8.5))
        ax.axis('off')

        ax.text(0.5, 0.96, 'Concurrency Ramp — Full Data Table', fontsize=16, fontweight='bold',
                ha='center', va='top', transform=ax.transAxes)

        if ramp:
            headers = ['Concurrency', 'Avg (s)', 'P50 (s)', 'P95 (s)', 'P99 (s)', 'Tok/s', 'Req/s', 'Errors', 'OK/Total']
            table_data = []
            for r in ramp:
                table_data.append([
                    str(r['concurrency']),
                    f"{r['avg_latency_ms']/1000:.1f}",
                    f"{r['p50_latency_ms']/1000:.1f}",
                    f"{r['p95_latency_ms']/1000:.1f}",
                    f"{r['p99_latency_ms']/1000:.1f}",
                    f"{r['tokens_per_second']:.0f}",
                    f"{r['requests_per_second']:.1f}",
                    f"{r['error_rate']*100:.1f}%",
                    f"{r['successful_requests']}/{r['total_requests']}",
                ])

            table = ax.table(cellText=table_data, colLabels=headers, loc='center',
                           cellLoc='center', colWidths=[0.1, 0.08, 0.08, 0.08, 0.08, 0.08, 0.08, 0.08, 0.1])
            table.auto_set_font_size(False)
            table.set_fontsize(9)
            table.scale(1.2, 1.8)

            # Color header
            for j in range(len(headers)):
                table[0, j].set_facecolor('#4472C4')
                table[0, j].set_text_props(color='white', fontweight='bold')

            # Color rows by error rate
            for i, r in enumerate(ramp):
                color = '#e8f5e9' if r['error_rate'] < 0.05 else '#fff3e0' if r['error_rate'] < 0.5 else '#ffebee'
                for j in range(len(headers)):
                    table[i+1, j].set_facecolor(color)

        # Legend
        legend_text = "Green: < 5% errors (safe) | Orange: 5-50% errors (degraded) | Red: > 50% errors (breaking)"
        ax.text(0.5, 0.15, legend_text, fontsize=9, ha='center', transform=ax.transAxes, style='italic')

        pdf.savefig(fig)
        plt.close()

    print(f"PDF report saved to: {output_path}")


if __name__ == "__main__":
    data = load_results("/tmp/perf-results.json")
    output_path = os.path.expanduser("~/Documents/PROJECTS/AI/llmonaws/vllm-performance-report.pdf")
    create_report(data, output_path)
