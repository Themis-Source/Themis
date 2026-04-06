<h1 align="center">
  <br>
  Themis
  <br>
</h1>

<p align="center">
  Scheduling-Aware Buffer Management for HBM-Based Hybrid Buffers
</p>

<p align="center">
  <a href="#key-features">Key Features</a> •
  <a href="#publication">Publication</a> •
  <a href="#get-started">Get Started</a> •
  <a href="#requirements">Requirements</a> •
  <a href="#license">License</a>
</p>

<a id="key-features"></a>

## ✨ Key Features

- Scheduling-aware buffer management for SRAM/HBM hybrid buffers.
- Rank-guided placement that keeps earlier-departing packets in low-latency storage whenever possible.
- Proactive migration across memory tiers instead of waiting for congestion to drain naturally.
- Contiguous organization of consecutively departing packets to improve effective HBM access efficiency.
- A BM-SCH unified model built around BBQ and linked-cell buffer organization.

![Themis Architecture](docs/themis-architecture.png)

<a id="publication"></a>

## 📄 Publication

**Themis: Scheduling-Aware Buffer Management for HBM-Based Hybrid Buffers**

> Packet buffers are critical for absorbing congestion and sustaining throughput in high-speed routers. As link rates escalate, on-chip SRAM alone can no longer provide sufficient capacity. To address this, modern routers widely adopt hybrid buffer architectures that augment limited on-chip SRAM with large off-chip DRAM.

> Despite this architectural promise, existing hybrid Buffer Management (BM) schemes severely undermine router performance. They simply redirect packets that would otherwise be dropped into DRAM, which leads to priority inversion and head-of-line blocking: as packets buffered in DRAM age into the highest-priority packets, SRAM must stall until they are retrieved, wasting bandwidth and degrading throughput. Worse still, existing BM schemes ignore DRAM’s access characteristics, further constraining its limited bandwidth and reducing overall performance dramatically.

> We present Themis, a hybrid buffer management scheme that fully exploits SRAM’s high bandwidth and DRAM’s large capacity. Its core principle is scheduling-aware packet placement, which ensures packets with the earliest departure time are preferentially stored in SRAM to maximize its bandwidth utilization.
>
> To achieve this, Themis proactively migrates buffered packets between SRAM and DRAM, reserving SRAM space for imminent, high-priority traffic. Themis is compatible with diverse scheduling algorithms and supports dynamic changes to the scheduling policy. It also organizes DRAM storage according to scheduling order, mapping consecutively departing packets to contiguous addresses.

<a id="get-started"></a>

## 🚀 Get Started

### Relevant Files

- `rtl/core/bbq.sv` - resource-evaluation queue core used by the public build flow.
- `rtl/core/themis_linked_buffer_manager.sv` - linked-cell buffer manager connected to the queue core.
- `rtl/common/heap_ops.sv` - heap operation definitions used by the queue path.
- `rtl/common/ffs.sv` - priority-bitmap helper logic.
- `rtl/common/themis_memory_primitives.sv` - generic memory primitives for public compilation.
- `rtl/top/themis_resource_eval_top.sv` - top-level resource-evaluation wrapper.
- `rtl/ip/*` - Vivado IP configuration files for memory blocks, clocking, FIFO, HBM, and on-chip debug infrastructure retained with the public repository snapshot.

### Example Compilation

```bash
iverilog -g2012 \
  -s themis_resource_eval_top \
  rtl/common/heap_ops.sv \
  rtl/common/ffs.sv \
  rtl/common/themis_memory_primitives.sv \
  rtl/core/bbq.sv \
  rtl/core/themis_linked_buffer_manager.sv \
  rtl/top/themis_resource_eval_top.sv
```

<a id="requirements"></a>

## ⚙️ Requirements

**Hardware Requirements**

- The preserved Vivado IP configuration references the Xilinx Alveo U280 platform (`xilinx.com:au280:part0:1.1`) and compatible board files.

**Software Requirements**

- `iverilog`: SystemVerilog 2012 support for public compilation sanity checks.
- [Vivado Design Suite](https://www.xilinx.com/support/download/index.html/content/xilinx/en/downloadNav/vivado-design-tools/archive.html) >= `2020.2`.

<a id="license"></a>

## 📜 License

- `BSD-2-Clause-Views`
