#!/usr/bin/env python3
"""Run focused Themis stress simulations for order, congestion, and hit metrics."""

from __future__ import annotations

import csv
import datetime as dt
import os
import sys
from pathlib import Path

import run_themis_sweep as sweep


def stress_cases() -> list[dict[str, int | str]]:
    cases: list[dict[str, int | str]] = []

    order_base = dict(
        rank_width=4,
        bbq_bitmap_width=4,
        sram_depth=64,
        ddr_batch_size=8,
        ddr_batch_slots=64,
        max_packets=2048,
        gen_period=1,
        drain_after_generation_only=1,
        drain_period=1,
        swap_in_watermark=sweep.wm(64, 0.50),
        swap_out_watermark=sweep.wm(64, 0.80),
        strict_checks=1,
        check_output_rank_order=1,
        timeout_cycles=1000000,
    )
    cases.extend(
        [
            sweep.case("order_uniform_2k_flush", "packet_order", **order_base, rank_dist=1),
            sweep.case("order_ascending_2k_flush", "packet_order", **order_base, rank_dist=3),
            sweep.case("order_descending_2k_flush", "packet_order", **order_base, rank_dist=4),
            sweep.case(
                "order_bimodal_hi10_2k_flush",
                "packet_order",
                **order_base,
                rank_dist=2,
                high_priority_per1024=102,
            ),
            sweep.case(
                "order_bimodal_hi75_2k_flush",
                "packet_order",
                **order_base,
                rank_dist=2,
                high_priority_per1024=768,
            ),
        ]
    )

    congestion_base = dict(
        rank_width=4,
        bbq_bitmap_width=4,
        sram_depth=32,
        ddr_batch_size=8,
        ddr_batch_slots=64,
        max_packets=1024,
        gen_period=1,
        drain_after_generation_only=0,
        swap_in_watermark=sweep.wm(32, 0.50),
        swap_out_watermark=sweep.wm(32, 0.80),
        rank_dist=0,
        strict_checks=0,
        check_output_rank_order=0,
        timeout_cycles=1000000,
    )
    for drain_period in (2, 4, 8, 16, 32):
        cases.append(
            sweep.case(
                f"egress_congest_dp{drain_period}",
                "egress_congestion",
                **congestion_base,
                drain_period=drain_period,
            )
        )

    flush_congestion_base = dict(order_base)
    flush_congestion_base.update(max_packets=1024, strict_checks=0)
    flush_congestion_base.pop("drain_period", None)
    for drain_period in (8, 16, 32):
        cases.append(
            sweep.case(
                f"flush_drain_congest_dp{drain_period}",
                "flush_drain_congestion",
                **flush_congestion_base,
                drain_period=drain_period,
                rank_dist=0,
            )
        )

    ingress_base = dict(
        rank_width=4,
        bbq_bitmap_width=4,
        sram_depth=16,
        ddr_batch_size=4,
        ddr_batch_slots=32,
        max_packets=1024,
        drain_after_generation_only=0,
        drain_period=8,
        swap_in_watermark=sweep.wm(16, 0.50),
        swap_out_watermark=sweep.wm(16, 0.80),
        rank_dist=1,
        strict_checks=0,
        check_output_rank_order=0,
        timeout_cycles=1000000,
    )
    cases.extend(
        [
            sweep.case("small_sram_burst_ingress", "ingress_pressure", **ingress_base, gen_period=1),
            sweep.case("small_sram_slow_ingress", "ingress_pressure", **ingress_base, gen_period=4),
        ]
    )

    return cases


def write_stress_report(rows: list[dict[str, str]], path: Path, csv_path: Path) -> None:
    lines = [
        "# Themis Stress RTL Sweep",
        "",
        f"Generated: {dt.datetime.now().isoformat(timespec='seconds')}",
        f"CSV: `{csv_path}`",
        "",
        "| Case | Group | Status | Rank Dist | Generated | Dequeued | Drop | Loss pm | On-chip hit pm | Direct-SRAM pm | DDR-src pm | Out util pm | DDR pressure pm | Swap/kpkt | Stall cycles | Rank errors |",
        "| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in rows:
        fields = [
            row.get("case", ""),
            row.get("group", ""),
            row.get("status", ""),
            row.get("rank_dist_name", ""),
            row.get("generated", ""),
            row.get("dequeued", ""),
            row.get("drop", ""),
            row.get("packet_loss_per_mille", ""),
            row.get("onchip_dequeue_hit_per_mille", ""),
            row.get("direct_sram_dequeue_per_mille", ""),
            row.get("ddr_sourced_dequeue_per_mille", ""),
            row.get("output_link_util_per_mille", ""),
            row.get("ddr_beat_pressure_per_mille", ""),
            row.get("swap_ops_per_kpkt", ""),
            row.get("dequeue_stall_cycles", ""),
            row.get("rank_order_errors", ""),
        ]
        lines.append("| " + " | ".join(fields) + " |")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    script_dir = Path(__file__).resolve().parent
    repo_dir = script_dir.parents[1]
    timestamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    build_root = Path(os.environ.get("THEMIS_STRESS_ROOT", repo_dir / "build" / f"themis_stress_{timestamp}"))
    build_root.mkdir(parents=True, exist_ok=True)

    if "XILINX_VIVADO" not in os.environ:
        print("ERROR: source Vivado settings before running this script", file=sys.stderr)
        return 1

    cases = stress_cases()
    requested_cases = os.environ.get("THEMIS_STRESS_CASES", "").strip()
    if requested_cases:
        selected = {name.strip() for name in requested_cases.split(",") if name.strip()}
        known = {str(entry["case"]) for entry in cases}
        unknown = sorted(selected - known)
        if unknown:
            print("ERROR: unknown stress case(s): " + ", ".join(unknown), file=sys.stderr)
            return 1
        cases = [entry for entry in cases if str(entry["case"]) in selected]

    rows: list[dict[str, str]] = []
    for idx, entry in enumerate(cases, start=1):
        print(f"[{idx}/{len(cases)}] {entry['case']}")
        rows.append(sweep.run_case(repo_dir, build_root, entry))

    csv_path = build_root / "stress_results.csv"
    report_path = build_root / "stress_report.md"
    sweep.write_csv(rows, csv_path)
    write_stress_report(rows, report_path, csv_path)
    print(f"CSV: {csv_path}")
    print(f"Report: {report_path}")

    failed = [row["case"] for row in rows if row.get("status") != "pass"]
    if failed:
        print("Failed cases: " + ", ".join(failed), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
