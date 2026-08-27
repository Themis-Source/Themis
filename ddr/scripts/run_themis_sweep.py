#!/usr/bin/env python3
"""Run Themis RTL simulation sweeps for paper-proxy metrics."""

from __future__ import annotations

import csv
import datetime as dt
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


KEY_VALUE_RE = re.compile(r"([A-Za-z0-9_]+)=([^ ]+)")


DEFAULTS = {
    "rank_width": 4,
    "bbq_bitmap_width": 4,
    "sram_depth": 32,
    "ddr_batch_size": 4,
    "ddr_batch_slots": 16,
    "max_packets": 512,
    "gen_period": 1,
    "drain_after_generation_only": 0,
    "drain_period": 1,
    "swap_in_watermark": 16,
    "swap_out_watermark": 25,
    "rank_dist": 0,
    "high_priority_per1024": 256,
    "strict_checks": 0,
    "check_output_rank_order": 1,
    "timeout_cycles": 200000,
}


DEFINE_MAP = {
    "rank_width": "THEMIS_SIM_RANK_WIDTH",
    "bbq_bitmap_width": "THEMIS_SIM_BBQ_BITMAP_WIDTH",
    "sram_depth": "THEMIS_SIM_SRAM_DEPTH",
    "ddr_batch_size": "THEMIS_SIM_DDR_BATCH_SIZE",
    "ddr_batch_slots": "THEMIS_SIM_DDR_BATCH_SLOTS",
    "max_packets": "THEMIS_SIM_MAX_PACKETS",
    "gen_period": "THEMIS_SIM_GEN_PERIOD_CYCLES",
    "drain_after_generation_only": "THEMIS_SIM_DRAIN_AFTER_GENERATION_ONLY",
    "drain_period": "THEMIS_SIM_DRAIN_PERIOD_CYCLES",
    "swap_in_watermark": "THEMIS_SIM_SWAP_IN_WATERMARK",
    "swap_out_watermark": "THEMIS_SIM_SWAP_OUT_WATERMARK",
    "rank_dist": "THEMIS_SIM_RANK_DIST",
    "high_priority_per1024": "THEMIS_SIM_HIGH_PRIORITY_PER1024",
    "strict_checks": "THEMIS_SIM_STRICT_CHECKS",
    "check_output_rank_order": "THEMIS_SIM_CHECK_OUTPUT_RANK_ORDER",
    "timeout_cycles": "THEMIS_SIM_TIMEOUT_CYCLES",
}


RANK_DIST_NAMES = {
    0: "skewed-default",
    1: "uniform",
    2: "bimodal-priority",
    3: "ascending",
    4: "descending",
}


def usable_depth(depth: int) -> int:
    ptr_width = 1 if depth <= 2 else (depth - 1).bit_length()
    return (1 << ptr_width) - 1


def wm(depth: int, ratio: float) -> int:
    return max(1, min(usable_depth(depth), round(usable_depth(depth) * ratio)))


def case(name: str, group: str, **overrides: int | str) -> dict[str, int | str]:
    values: dict[str, int | str] = dict(DEFAULTS)
    values.update(overrides)
    values["case"] = name
    values["group"] = group
    return values


def build_cases() -> list[dict[str, int | str]]:
    cases: list[dict[str, int | str]] = [
        case(
            "sanity_default_flush",
            "sanity",
            max_packets=192,
            drain_after_generation_only=1,
            swap_in_watermark=8,
            swap_out_watermark=24,
            strict_checks=1,
        ),
        case("paper_proxy_base", "baseline"),
    ]

    for depth in (16, 64):
        cases.append(
            case(
                f"sram_depth_{depth}",
                "sram_depth",
                sram_depth=depth,
                swap_in_watermark=wm(depth, 0.5),
                swap_out_watermark=wm(depth, 0.8),
            )
        )

    for batch_size in (2, 8, 16):
        cases.append(
            case(
                f"ddr_batch_{batch_size}",
                "ddr_batch_size",
                ddr_batch_size=batch_size,
                ddr_batch_slots=32,
            )
        )

    for ratio in (0.25, 0.50, 0.75):
        cases.append(
            case(
                f"swap_in_{int(ratio * 100)}pct_out_80pct",
                "watermark_swap_in",
                swap_in_watermark=wm(32, ratio),
                swap_out_watermark=wm(32, 0.80),
            )
        )

    for ratio in (0.60, 0.80, 0.95):
        cases.append(
            case(
                f"swap_out_{int(ratio * 100)}pct_in_50pct",
                "watermark_swap_out",
                swap_in_watermark=wm(32, 0.50),
                swap_out_watermark=wm(32, ratio),
            )
        )

    for in_ratio, out_ratio in ((0.25, 0.60), (0.75, 0.90)):
        cases.append(
            case(
                f"wm_cotune_in_{int(in_ratio * 100)}pct_out_{int(out_ratio * 100)}pct",
                "watermark_cotune",
                swap_in_watermark=wm(32, in_ratio),
                swap_out_watermark=wm(32, out_ratio),
            )
        )

    cases.extend(
        [
            case("rank_uniform", "rank_distribution", rank_dist=1),
            case("rank_ascending", "rank_distribution", rank_dist=3),
            case("rank_descending", "rank_distribution", rank_dist=4),
        ]
    )
    for per1024 in (102, 256, 512, 768):
        cases.append(
            case(
                f"rank_bimodal_hi_{round(per1024 * 100 / 1024)}pct",
                "rank_high_priority_ratio",
                rank_dist=2,
                high_priority_per1024=per1024,
            )
        )

    for drain_period in (2, 4, 8):
        cases.append(
            case(
                f"load_drain_period_{drain_period}",
                "load_strength",
                drain_period=drain_period,
                timeout_cycles=300000,
            )
        )

    return cases


def parse_key_values(line: str) -> dict[str, str]:
    return {match.group(1): match.group(2) for match in KEY_VALUE_RE.finditer(line)}


def run_command(cmd: list[str], cwd: Path, log_path: Path) -> int:
    with log_path.open("a", encoding="utf-8", errors="ignore") as log:
        log.write("$ " + " ".join(cmd) + "\n")
        proc = subprocess.run(
            cmd,
            cwd=cwd,
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        log.write(f"[exit {proc.returncode}]\n")
        return proc.returncode


def run_case(repo_dir: Path, build_root: Path, entry: dict[str, int | str]) -> dict[str, str]:
    case_dir = build_root / str(entry["case"])
    if case_dir.exists():
        shutil.rmtree(case_dir)
    case_dir.mkdir(parents=True)

    rtl_files = [
        repo_dir / "ddr" / "rtl" / "bbq" / "heap_ops.sv",
        repo_dir / "ddr" / "rtl" / "themis_bbq_queue.sv",
        repo_dir / "ddr" / "rtl" / "themis_bmsch_queue.sv",
        repo_dir / "ddr" / "rtl" / "themis_synthetic_packet_gen.sv",
        repo_dir / "ddr" / "rtl" / "themis_core_bbq.sv",
        repo_dir / "ddr" / "rtl" / "themis_u200_top.sv",
        repo_dir / "ddr" / "sim" / "tb_themis_core.sv",
    ]
    glbl_file = Path(os.environ["XILINX_VIVADO"]) / "data" / "verilog" / "src" / "glbl.v"
    log_path = case_dir / "run.log"

    defines: list[str] = []
    for key, define in DEFINE_MAP.items():
        defines += ["-d", f"{define}={entry[key]}"]

    xvlog_cmd = ["xvlog", "--sv", "--relax", "-L", "uvm", *defines, *map(str, rtl_files)]
    xvlog_glbl_cmd = ["xvlog", "--relax", str(glbl_file)]
    xelab_cmd = [
        "xelab",
        "--debug",
        "off",
        "--relax",
        "--mt",
        "8",
        "-L",
        "work",
        "-L",
        "uvm",
        "-L",
        "unisims_ver",
        "-L",
        "unimacro_ver",
        "-L",
        "secureip",
        "-s",
        "tb_themis_core_behav",
        "work.tb_themis_core",
        "work.glbl",
    ]
    run_tcl = case_dir / "xsim_run.tcl"
    run_tcl.write_text("run -all\nquit\n", encoding="ascii")
    xsim_cmd = [
        "xsim",
        "tb_themis_core_behav",
        "-wdb",
        "/dev/null",
        "-tclbatch",
        str(run_tcl),
        "-log",
        "simulate.log",
    ]

    row = {key: str(value) for key, value in entry.items()}
    row["rank_dist_name"] = RANK_DIST_NAMES.get(int(entry["rank_dist"]), "unknown")
    row["status"] = "pass"
    for cmd in (xvlog_cmd, xvlog_glbl_cmd, xelab_cmd, xsim_cmd):
        if run_command(cmd, case_dir, log_path) != 0:
            row["status"] = "fail"
            break

    sim_log = case_dir / "simulate.log"
    if sim_log.exists():
        text = sim_log.read_text(encoding="utf-8", errors="ignore")
        row["pass_marker"] = str("PASS: Themis subsystem admitted to SRAM/DDR, swapped, and drained" in text)
        for line in text.splitlines():
            if line.startswith("PARAM "):
                row.update({f"param_{key}": value for key, value in parse_key_values(line).items()})
            elif line.startswith("RESULT "):
                row.update(parse_key_values(line))
            elif line.startswith("METRIC "):
                row.update(parse_key_values(line))
        if row.get("pass_marker") != "True":
            row["status"] = "fail"
    else:
        row["pass_marker"] = "False"
        row["status"] = "fail"

    return row


def write_csv(rows: list[dict[str, str]], path: Path) -> None:
    fieldnames: list[str] = []
    for row in rows:
        for key in row:
            if key not in fieldnames:
                fieldnames.append(key)
    with path.open("w", newline="", encoding="utf-8") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def table_row(row: dict[str, str]) -> str:
    fields = [
        row.get("case", ""),
        row.get("group", ""),
        row.get("status", ""),
        row.get("sram_depth", ""),
        row.get("swap_in_watermark", ""),
        row.get("swap_out_watermark", ""),
        row.get("ddr_batch_size", ""),
        row.get("rank_dist_name", ""),
        row.get("drain_period", ""),
        row.get("packet_loss_per_mille", ""),
        row.get("onchip_dequeue_hit_per_mille", row.get("direct_sram_dequeue_per_mille", "")),
        row.get("output_link_util_per_mille", ""),
        row.get("ddr_beat_pressure_per_mille", ""),
        row.get("swap_ops_per_kpkt", ""),
    ]
    return "| " + " | ".join(fields) + " |"


def write_report(rows: list[dict[str, str]], path: Path, csv_path: Path) -> None:
    lines = [
        "# Themis Paper-Proxy RTL Sweep",
        "",
        f"Generated: {dt.datetime.now().isoformat(timespec='seconds')}",
        f"CSV: `{csv_path}`",
        "",
        "This sweep maps the paper's micro-level metrics onto the current RTL model:",
        "",
        "- packet loss rate: `drop / generated`",
        "- on-chip dequeue hit rate: `onchip_dequeue_hit / dequeued`",
        "- direct-SRAM residency rate: `direct_sram_dequeued / dequeued`",
        "- DDR/HBM throughput pressure proxy: `(ddr_write_beats + ddr_read_beats) / simulation_cycles`",
        "- output link utilization proxy: accepted output packets divided by output-ready cycles",
        "- swap activity: `(swap_out + swap_in) / generated`",
        "",
        "The current U200 target uses DDR4 instead of HBM, so batch-size and throughput results are a DDR proxy for the paper's HBM experiments.",
        "",
        "| Case | Group | Status | SRAM | WMin | WMout | Batch | Rank Dist | Drain Period | Loss permille | SRAM Hit permille | Output Util permille | DDR Beat Pressure permille | Swap Ops/kpkt |",
        "| --- | --- | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    lines.extend(table_row(row) for row in rows)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    script_dir = Path(__file__).resolve().parent
    repo_dir = script_dir.parents[1]
    timestamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    build_root = Path(os.environ.get("THEMIS_SWEEP_ROOT", repo_dir / "build" / f"themis_sweep_{timestamp}"))
    build_root.mkdir(parents=True, exist_ok=True)

    if "XILINX_VIVADO" not in os.environ:
        print("ERROR: source Vivado settings before running this script", file=sys.stderr)
        return 1

    rows = []
    cases = build_cases()
    requested_cases = os.environ.get("THEMIS_SWEEP_CASES", "").strip()
    if requested_cases:
        selected = {name.strip() for name in requested_cases.split(",") if name.strip()}
        known = {str(entry["case"]) for entry in cases}
        unknown = sorted(selected - known)
        if unknown:
            print("ERROR: unknown case(s): " + ", ".join(unknown), file=sys.stderr)
            return 1
        cases = [entry for entry in cases if str(entry["case"]) in selected]
    for idx, entry in enumerate(cases, start=1):
        print(f"[{idx}/{len(cases)}] {entry['case']}")
        rows.append(run_case(repo_dir, build_root, entry))

    csv_path = build_root / "sweep_results.csv"
    report_path = build_root / "sweep_report.md"
    write_csv(rows, csv_path)
    write_report(rows, report_path, csv_path)
    print(f"CSV: {csv_path}")
    print(f"Report: {report_path}")
    failed = [row["case"] for row in rows if row.get("status") != "pass"]
    if failed:
        print("Failed cases: " + ", ".join(failed), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
