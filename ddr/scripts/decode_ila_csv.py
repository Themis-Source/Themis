#!/usr/bin/env python3
"""Decode Themis U200 ILA CSV captures."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path


FIELDS = [
    ("generated", 0, 32, "dec"),
    ("dequeued", 32, 32, "dec"),
    ("sram_admit", 64, 32, "dec"),
    ("ddr_admit", 96, 32, "dec"),
    ("swap_out", 128, 32, "dec"),
    ("swap_in", 160, 32, "dec"),
    ("drop", 192, 32, "dec"),
    ("direct_sram_dequeued", 224, 32, "dec"),
    ("ddr_sourced_dequeued", 256, 32, "dec"),
    ("dequeue_stall_cycles", 288, 32, "dec"),
    ("ddr_write_beats", 320, 32, "dec"),
    ("ddr_read_beats", 352, 32, "dec"),
    ("ddr_write_batches", 384, 32, "dec"),
    ("ddr_read_batches", 416, 32, "dec"),
    ("occupancy", 448, 32, "hex"),
    ("offchip_min_rank", 480, 16, "hex"),
    ("state", 496, 8, "hex"),
    ("done", 504, 1, "dec"),
    ("run_cycles", 512, 32, "dec"),
    ("output_fire_cycles", 544, 32, "dec"),
    ("drain_ready_cycles", 576, 32, "dec"),
    ("rank_order_errors", 608, 32, "dec"),
    ("last_out_rank", 640, 16, "hex"),
    ("current_out_rank", 656, 16, "hex"),
    ("rank_order_prev_valid", 672, 1, "dec"),
    ("out_valid", 673, 1, "dec"),
    ("drain_ready", 674, 1, "dec"),
    ("core_resetn", 675, 1, "dec"),
    ("onchip_dequeue_hit", 676, 32, "dec"),
]


def find_column(header: list[str], patterns: tuple[str, ...]) -> int:
    for idx, name in enumerate(header):
        lowered = name.lower()
        if all(pattern in lowered for pattern in patterns):
            return idx
    raise SystemExit(f"missing CSV column matching: {patterns}")


def parse_bus(value: str) -> int:
    cleaned = value.strip()
    if cleaned.startswith(("0x", "0X")):
        return int(cleaned, 16)
    if all(ch in "01" for ch in cleaned) and len(cleaned) > 128:
        return int(cleaned, 2)
    return int(cleaned, 16)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", type=Path)
    parser.add_argument(
        "--clk-mhz",
        type=float,
        default=300.0,
        help="ILA/debug clock in MHz; U200 DDR4 UI clock is expected to be 300 MHz",
    )
    args = parser.parse_args()

    rows = list(csv.reader(args.csv.open(newline="")))
    if len(rows) < 3:
        raise SystemExit("CSV has no ILA samples")

    header = rows[0]
    data_rows = rows[2:]
    bus_col = find_column(header, ("dbg_bus",))
    trigger_col = find_column(header, ("trigger",))
    calib_cols = [
        idx
        for idx, name in enumerate(header)
        if name.lower().endswith("c0_init_calib_complete")
    ]
    calib_col = calib_cols[0] if calib_cols else None

    sample = None
    for row in data_rows:
        if len(row) > trigger_col and row[trigger_col].strip() == "1":
            sample = row
            break
    if sample is None:
        sample = next(row for row in data_rows if len(row) > bus_col and row[bus_col].strip())

    buses = [row[bus_col].strip() for row in data_rows if len(row) > bus_col and row[bus_col].strip()]
    triggers = [
        row[trigger_col].strip()
        for row in data_rows
        if len(row) > trigger_col and row[trigger_col].strip() == "1"
    ]
    calib_values = []
    if calib_col is not None:
        calib_values = [
            row[calib_col].strip()
            for row in data_rows
            if len(row) > calib_col and row[calib_col].strip()
        ]

    bus_value = parse_bus(sample[bus_col])
    decoded = {}
    for name, lo, width, radix in FIELDS:
        value = (bus_value >> lo) & ((1 << width) - 1)
        decoded[name] = value
        if radix == "hex":
            print(f"{name}=0x{value:0{(width + 3) // 4}x}")
        else:
            print(f"{name}={value}")

    occupancy = decoded["occupancy"]
    print(f"ddr_batch_count={occupancy >> 16}")
    print(f"sram_count={occupancy & 0xffff}")
    print(f"generated_eq_dequeued_plus_drop={decoded['generated'] == decoded['dequeued'] + decoded['drop']}")
    print(
        "dequeue_sources_sum="
        f"{decoded['dequeued'] == decoded['direct_sram_dequeued'] + decoded['ddr_sourced_dequeued']}"
    )
    dequeued = decoded["dequeued"]
    generated = decoded["generated"]
    run_cycles = decoded["run_cycles"]
    output_fire_cycles = decoded["output_fire_cycles"]
    drain_ready_cycles = decoded["drain_ready_cycles"]
    ddr_beats = decoded["ddr_write_beats"] + decoded["ddr_read_beats"]
    clk_hz = args.clk_mhz * 1_000_000.0

    def permille(num: int, den: int) -> int:
        return 0 if den == 0 else (num * 1000) // den

    print(f"rank_order_ok={decoded['rank_order_errors'] == 0}")
    print(f"packet_loss_per_mille={permille(decoded['drop'], generated)}")
    print(f"sram_hit_per_mille={permille(decoded['onchip_dequeue_hit'], dequeued)}")
    print(f"onchip_dequeue_hit_per_mille={permille(decoded['onchip_dequeue_hit'], dequeued)}")
    print(f"direct_sram_dequeue_per_mille={permille(decoded['direct_sram_dequeued'], dequeued)}")
    print(f"ddr_sourced_dequeue_per_mille={permille(decoded['ddr_sourced_dequeued'], dequeued)}")
    print(f"output_link_util_per_mille={permille(output_fire_cycles, drain_ready_cycles)}")
    print(f"ddr_beat_pressure_per_mille={permille(ddr_beats, run_cycles)}")
    if run_cycles:
        throughput_mpps = (output_fire_cycles * clk_hz) / run_cycles / 1_000_000.0
        ddr_gbps = (ddr_beats * 64.0 * clk_hz) / run_cycles / 1_000_000_000.0
        print(f"throughput_mpps={throughput_mpps:.6f}")
        print(f"throughput_packets_per_cycle={output_fire_cycles / run_cycles:.9f}")
        print(f"ddr_bandwidth_GBps={ddr_gbps:.6f}")
    print(f"csv_rows={len(data_rows)}")
    print(f"unique_dbg_bus_values={len(set(buses))}")
    print(f"trigger_rows={len(triggers)}")
    if calib_col is not None:
        print(f"calib_values={','.join(sorted(set(calib_values)))}")


if __name__ == "__main__":
    main()
