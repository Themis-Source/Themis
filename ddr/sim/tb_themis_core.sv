`timescale 1ns/1ps

`ifndef THEMIS_SIM_RANK_WIDTH
`define THEMIS_SIM_RANK_WIDTH 4
`endif
`ifndef THEMIS_SIM_BBQ_BITMAP_WIDTH
`define THEMIS_SIM_BBQ_BITMAP_WIDTH 4
`endif
`ifndef THEMIS_SIM_SRAM_DEPTH
`define THEMIS_SIM_SRAM_DEPTH 32
`endif
`ifndef THEMIS_SIM_DDR_BATCH_SIZE
`define THEMIS_SIM_DDR_BATCH_SIZE 4
`endif
`ifndef THEMIS_SIM_DDR_BATCH_SLOTS
`define THEMIS_SIM_DDR_BATCH_SLOTS 16
`endif
`ifndef THEMIS_SIM_MAX_PACKETS
`define THEMIS_SIM_MAX_PACKETS 192
`endif
`ifndef THEMIS_SIM_GEN_PERIOD_CYCLES
`define THEMIS_SIM_GEN_PERIOD_CYCLES 1
`endif
`ifndef THEMIS_SIM_DRAIN_AFTER_GENERATION_ONLY
`define THEMIS_SIM_DRAIN_AFTER_GENERATION_ONLY 1
`endif
`ifndef THEMIS_SIM_DRAIN_PERIOD_CYCLES
`define THEMIS_SIM_DRAIN_PERIOD_CYCLES 1
`endif
`ifndef THEMIS_SIM_SWAP_IN_WATERMARK
`define THEMIS_SIM_SWAP_IN_WATERMARK 8
`endif
`ifndef THEMIS_SIM_SWAP_OUT_WATERMARK
`define THEMIS_SIM_SWAP_OUT_WATERMARK 24
`endif
`ifndef THEMIS_SIM_RANK_DIST
`define THEMIS_SIM_RANK_DIST 0
`endif
`ifndef THEMIS_SIM_HIGH_PRIORITY_PER1024
`define THEMIS_SIM_HIGH_PRIORITY_PER1024 256
`endif
`ifndef THEMIS_SIM_STRICT_CHECKS
`define THEMIS_SIM_STRICT_CHECKS 1
`endif
`ifndef THEMIS_SIM_CHECK_OUTPUT_RANK_ORDER
`define THEMIS_SIM_CHECK_OUTPUT_RANK_ORDER 1
`endif
`ifndef THEMIS_SIM_TIMEOUT_CYCLES
`define THEMIS_SIM_TIMEOUT_CYCLES 20000
`endif

module tb_themis_core;
  localparam int AXI_ADDR_WIDTH = 64;
  localparam int AXI_DATA_WIDTH = 512;
  localparam int AXI_ID_WIDTH = 4;
  localparam int KEEP_WIDTH = AXI_DATA_WIDTH / 8;
  localparam int MEM_BEATS = 4096;
  localparam int SIM_RANK_WIDTH = `THEMIS_SIM_RANK_WIDTH;
  localparam int SIM_BBQ_BITMAP_WIDTH = `THEMIS_SIM_BBQ_BITMAP_WIDTH;
  localparam int SIM_SRAM_DEPTH = `THEMIS_SIM_SRAM_DEPTH;
  localparam int SIM_DDR_BATCH_SIZE = `THEMIS_SIM_DDR_BATCH_SIZE;
  localparam int SIM_DDR_BATCH_SLOTS = `THEMIS_SIM_DDR_BATCH_SLOTS;
  localparam int SIM_MAX_PACKETS = `THEMIS_SIM_MAX_PACKETS;
  localparam int SIM_GEN_PERIOD_CYCLES = `THEMIS_SIM_GEN_PERIOD_CYCLES;
  localparam bit SIM_DRAIN_AFTER_GENERATION_ONLY = `THEMIS_SIM_DRAIN_AFTER_GENERATION_ONLY;
  localparam int SIM_DRAIN_PERIOD_CYCLES = `THEMIS_SIM_DRAIN_PERIOD_CYCLES;
  localparam int SIM_SWAP_IN_WATERMARK = `THEMIS_SIM_SWAP_IN_WATERMARK;
  localparam int SIM_SWAP_OUT_WATERMARK = `THEMIS_SIM_SWAP_OUT_WATERMARK;
  localparam int SIM_RANK_DIST = `THEMIS_SIM_RANK_DIST;
  localparam int SIM_HIGH_PRIORITY_PER1024 = `THEMIS_SIM_HIGH_PRIORITY_PER1024;
  localparam int SIM_STRICT_CHECKS = `THEMIS_SIM_STRICT_CHECKS;
  localparam int SIM_CHECK_OUTPUT_RANK_ORDER = `THEMIS_SIM_CHECK_OUTPUT_RANK_ORDER;
  localparam int SIM_TIMEOUT_CYCLES = `THEMIS_SIM_TIMEOUT_CYCLES;

  logic clk = 1'b0;
  logic resetn = 1'b0;
  always #1.667 clk = ~clk;

  logic [AXI_ID_WIDTH-1:0] awid;
  logic [AXI_ADDR_WIDTH-1:0] awaddr;
  logic [7:0] awlen;
  logic [2:0] awsize;
  logic [1:0] awburst;
  logic awlock;
  logic [3:0] awcache;
  logic [2:0] awprot;
  logic [3:0] awqos;
  logic awvalid;
  logic awready;
  logic [AXI_DATA_WIDTH-1:0] wdata;
  logic [KEEP_WIDTH-1:0] wstrb;
  logic wlast;
  logic wvalid;
  logic wready;
  logic [AXI_ID_WIDTH-1:0] bid;
  logic [1:0] bresp;
  logic bvalid;
  logic bready;
  logic [AXI_ID_WIDTH-1:0] arid;
  logic [AXI_ADDR_WIDTH-1:0] araddr;
  logic [7:0] arlen;
  logic [2:0] arsize;
  logic [1:0] arburst;
  logic arlock;
  logic [3:0] arcache;
  logic [2:0] arprot;
  logic [3:0] arqos;
  logic arvalid;
  logic arready;
  logic [AXI_ID_WIDTH-1:0] rid;
  logic [AXI_DATA_WIDTH-1:0] rdata;
  logic [1:0] rresp;
  logic rlast;
  logic rvalid;
  logic rready;

  logic [31:0] dbg_generated;
  logic [31:0] dbg_dequeued;
  logic [31:0] dbg_sram_admit;
  logic [31:0] dbg_ddr_admit;
  logic [31:0] dbg_swap_out;
  logic [31:0] dbg_swap_in;
  logic [31:0] dbg_drop;
  logic [31:0] dbg_onchip_dequeue_hit;
  logic [31:0] dbg_direct_sram_dequeued;
  logic [31:0] dbg_ddr_sourced_dequeued;
  logic [31:0] dbg_dequeue_stall_cycles;
  logic [31:0] dbg_ddr_write_beats;
  logic [31:0] dbg_ddr_read_beats;
  logic [31:0] dbg_ddr_write_batches;
  logic [31:0] dbg_ddr_read_batches;
  logic [31:0] dbg_occupancy;
  logic [15:0] dbg_offchip_min_rank;
  logic [7:0] dbg_state;
  logic done;

  logic [AXI_DATA_WIDTH-1:0] mem [0:MEM_BEATS-1];
  logic write_active;
  logic [AXI_ADDR_WIDTH-1:0] write_base;
  logic [8:0] write_idx;
  logic [8:0] write_len;
  logic read_active;
  logic [AXI_ADDR_WIDTH-1:0] read_base;
  logic [8:0] read_idx;
  logic [8:0] read_len;
  logic [31:0] drain_ready_cycles;
  logic [31:0] output_fire_cycles;
  logic [31:0] rank_order_errors;
  logic rank_order_prev_valid;
  logic [SIM_RANK_WIDTH-1:0] last_output_rank;

  themis_u200_top #(
    .RANK_WIDTH(SIM_RANK_WIDTH),
    .BBQ_BITMAP_WIDTH(SIM_BBQ_BITMAP_WIDTH),
    .SRAM_DEPTH(SIM_SRAM_DEPTH),
    .DDR_BATCH_SIZE(SIM_DDR_BATCH_SIZE),
    .DDR_BATCH_SLOTS(SIM_DDR_BATCH_SLOTS),
    .MAX_PACKETS(SIM_MAX_PACKETS),
    .GEN_PERIOD_CYCLES(SIM_GEN_PERIOD_CYCLES),
    .DRAIN_AFTER_GENERATION_ONLY(SIM_DRAIN_AFTER_GENERATION_ONLY),
    .DRAIN_PERIOD_CYCLES(SIM_DRAIN_PERIOD_CYCLES),
    .SWAP_IN_WATERMARK(SIM_SWAP_IN_WATERMARK),
    .SWAP_OUT_WATERMARK(SIM_SWAP_OUT_WATERMARK),
    .RANK_DIST(SIM_RANK_DIST),
    .HIGH_PRIORITY_PER1024(SIM_HIGH_PRIORITY_PER1024)
  ) dut (
    .clk(clk),
    .resetn(resetn),
    .m_axi_awid(awid),
    .m_axi_awaddr(awaddr),
    .m_axi_awlen(awlen),
    .m_axi_awsize(awsize),
    .m_axi_awburst(awburst),
    .m_axi_awlock(awlock),
    .m_axi_awcache(awcache),
    .m_axi_awprot(awprot),
    .m_axi_awqos(awqos),
    .m_axi_awvalid(awvalid),
    .m_axi_awready(awready),
    .m_axi_wdata(wdata),
    .m_axi_wstrb(wstrb),
    .m_axi_wlast(wlast),
    .m_axi_wvalid(wvalid),
    .m_axi_wready(wready),
    .m_axi_bid(bid),
    .m_axi_bresp(bresp),
    .m_axi_bvalid(bvalid),
    .m_axi_bready(bready),
    .m_axi_arid(arid),
    .m_axi_araddr(araddr),
    .m_axi_arlen(arlen),
    .m_axi_arsize(arsize),
    .m_axi_arburst(arburst),
    .m_axi_arlock(arlock),
    .m_axi_arcache(arcache),
    .m_axi_arprot(arprot),
    .m_axi_arqos(arqos),
    .m_axi_arvalid(arvalid),
    .m_axi_arready(arready),
    .m_axi_rid(rid),
    .m_axi_rdata(rdata),
    .m_axi_rresp(rresp),
    .m_axi_rlast(rlast),
    .m_axi_rvalid(rvalid),
    .m_axi_rready(rready),
    .dbg_generated(dbg_generated),
    .dbg_dequeued(dbg_dequeued),
    .dbg_sram_admit(dbg_sram_admit),
    .dbg_ddr_admit(dbg_ddr_admit),
    .dbg_swap_out(dbg_swap_out),
    .dbg_swap_in(dbg_swap_in),
    .dbg_drop(dbg_drop),
    .dbg_onchip_dequeue_hit(dbg_onchip_dequeue_hit),
    .dbg_direct_sram_dequeued(dbg_direct_sram_dequeued),
    .dbg_ddr_sourced_dequeued(dbg_ddr_sourced_dequeued),
    .dbg_dequeue_stall_cycles(dbg_dequeue_stall_cycles),
    .dbg_ddr_write_beats(dbg_ddr_write_beats),
    .dbg_ddr_read_beats(dbg_ddr_read_beats),
    .dbg_ddr_write_batches(dbg_ddr_write_batches),
    .dbg_ddr_read_batches(dbg_ddr_read_batches),
    .dbg_occupancy(dbg_occupancy),
    .dbg_offchip_min_rank(dbg_offchip_min_rank),
    .dbg_state(dbg_state),
    .done(done)
  );

  assign awready = 1'b1;
  assign wready = 1'b1;
  assign arready = !read_active;
  assign bid = '0;
  assign bresp = 2'b00;
  assign rid = '0;
  assign rresp = 2'b00;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      write_active <= 1'b0;
      write_base <= '0;
      write_idx <= '0;
      write_len <= '0;
      bvalid <= 1'b0;
      read_active <= 1'b0;
      read_base <= '0;
      read_idx <= '0;
      read_len <= '0;
      rvalid <= 1'b0;
      rdata <= '0;
      rlast <= 1'b0;
    end else begin
      if (awvalid && awready) begin
        write_active <= 1'b1;
        write_base <= awaddr[AXI_ADDR_WIDTH-1:6];
        write_idx <= '0;
        write_len <= {1'b0, awlen} + 9'd1;
      end
      if (wvalid && wready && write_active) begin
        mem[write_base + write_idx] <= wdata;
        if (wlast) begin
          write_active <= 1'b0;
          bvalid <= 1'b1;
        end else begin
          write_idx <= write_idx + 9'd1;
        end
      end
      if (bvalid && bready) begin
        bvalid <= 1'b0;
      end

      if (arvalid && arready) begin
        read_active <= 1'b1;
        read_base <= araddr[AXI_ADDR_WIDTH-1:6];
        read_idx <= '0;
        read_len <= {1'b0, arlen} + 9'd1;
        rvalid <= 1'b1;
        rdata <= mem[araddr[AXI_ADDR_WIDTH-1:6]];
        rlast <= (arlen == 8'd0);
      end else if (rvalid && rready) begin
        if (read_idx + 9'd1 == read_len) begin
          rvalid <= 1'b0;
          rlast <= 1'b0;
          read_active <= 1'b0;
        end else begin
          read_idx <= read_idx + 9'd1;
          rdata <= mem[read_base + read_idx + 9'd1];
          rlast <= (read_idx + 9'd2 == read_len);
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      drain_ready_cycles <= '0;
      output_fire_cycles <= '0;
      rank_order_errors <= '0;
      rank_order_prev_valid <= 1'b0;
      last_output_rank <= '0;
    end else begin
      if (dut.drain_ready) begin
        drain_ready_cycles <= drain_ready_cycles + 32'd1;
      end
      if (dut.out_valid && dut.drain_ready) begin
        output_fire_cycles <= output_fire_cycles + 32'd1;
        if ((SIM_CHECK_OUTPUT_RANK_ORDER != 0) && SIM_DRAIN_AFTER_GENERATION_ONLY &&
            rank_order_prev_valid && (dut.out_rank < last_output_rank)) begin
          rank_order_errors <= rank_order_errors + 32'd1;
          $display("RANK_ORDER_ERROR prev_rank=0x%0h curr_rank=0x%0h curr_seq=0x%0h",
                   last_output_rank, dut.out_rank, dut.out_seq);
        end
        rank_order_prev_valid <= 1'b1;
        last_output_rank <= dut.out_rank;
      end
    end
  end

  initial begin
    int cycle_count;
    logic [31:0] prev_ddr_admit;
    logic rank_record_admit_seen;
    repeat (20) @(posedge clk);
    resetn = 1'b1;
    cycle_count = 0;
    prev_ddr_admit = '0;
    rank_record_admit_seen = 1'b0;
    $display("PARAM rank_width=%0d bbq_bitmap_width=%0d sram_depth=%0d ddr_batch_size=%0d ddr_batch_slots=%0d max_packets=%0d gen_period=%0d drain_after_generation_only=%0d drain_period=%0d swap_in_watermark=%0d swap_out_watermark=%0d rank_dist=%0d high_priority_per1024=%0d strict_checks=%0d check_output_rank_order=%0d timeout_cycles=%0d",
             SIM_RANK_WIDTH, SIM_BBQ_BITMAP_WIDTH, SIM_SRAM_DEPTH,
             SIM_DDR_BATCH_SIZE, SIM_DDR_BATCH_SLOTS, SIM_MAX_PACKETS,
             SIM_GEN_PERIOD_CYCLES, SIM_DRAIN_AFTER_GENERATION_ONLY,
             SIM_DRAIN_PERIOD_CYCLES, SIM_SWAP_IN_WATERMARK,
             SIM_SWAP_OUT_WATERMARK, SIM_RANK_DIST,
             SIM_HIGH_PRIORITY_PER1024, SIM_STRICT_CHECKS,
             SIM_CHECK_OUTPUT_RANK_ORDER,
             SIM_TIMEOUT_CYCLES);
    repeat (SIM_TIMEOUT_CYCLES) begin
      @(posedge clk);
      cycle_count++;
      if ((dbg_ddr_admit > prev_ddr_admit) && (dut.core_i.sram_free_count_q != 16'd0)) begin
        rank_record_admit_seen = 1'b1;
      end
      prev_ddr_admit = dbg_ddr_admit;
      if ((cycle_count % 1000) == 0) begin
        $display("progress cycle=%0d generated=%0d sram=%0d ddr=%0d swap_out=%0d swap_in=%0d dequeued=%0d direct=%0d ddr_src=%0d drop=%0d wr_beats=%0d rd_beats=%0d stall=%0d occ=0x%08x min_rank=0x%04x state=0x%02x",
                 cycle_count, dbg_generated, dbg_sram_admit, dbg_ddr_admit,
                 dbg_swap_out, dbg_swap_in, dbg_dequeued, dbg_direct_sram_dequeued,
                 dbg_ddr_sourced_dequeued, dbg_drop, dbg_ddr_write_beats,
                 dbg_ddr_read_beats, dbg_dequeue_stall_cycles,
                 dbg_occupancy, dbg_offchip_min_rank, dbg_state);
        $display("          core_sram_count=%0d sram_free=%0d logical_free=%0d bmsch_sram_occ=%0d bmsch_offchip_occ=%0d sram_min=0x%0h offchip_min=0x%0h sram_req=%0d bm_out_valid=%0b ddr_req=%0d rd_state=%0d rd_beat=%0d rd_active=%0d wr_state=%0d",
                 dut.core_i.sram_count_q, dut.core_i.sram_free_count_q,
                 dut.core_i.sram_logical_free, dut.core_i.bm_dbg_sram_occupancy,
                 dut.core_i.bm_dbg_offchip_occupancy, dut.core_i.bm_sram_min_priority,
                 dut.core_i.bm_offchip_min_priority, dut.core_i.sram_req_q,
                 dut.core_i.bm_q_out_valid, dut.core_i.ddr_req_q,
                 dut.core_i.rd_state_q, dut.core_i.rd_beat_q,
                 dut.core_i.rd_active_count_q, dut.core_i.wr_state_q);
      end
      if (done) begin
        $display("RESULT generated=%0d sram=%0d ddr=%0d swap_out=%0d swap_in=%0d dequeued=%0d onchip_hit=%0d direct=%0d ddr_src=%0d drop=%0d wr_beats=%0d rd_beats=%0d wr_batches=%0d rd_batches=%0d stall=%0d drain_ready_cycles=%0d output_fire_cycles=%0d rank_order_errors=%0d rank_record_admit_seen=%0d occ=0x%08x min_rank=0x%04x state=0x%02x",
                 dbg_generated, dbg_sram_admit, dbg_ddr_admit, dbg_swap_out,
                 dbg_swap_in, dbg_dequeued, dbg_onchip_dequeue_hit,
                 dbg_direct_sram_dequeued, dbg_ddr_sourced_dequeued, dbg_drop,
                 dbg_ddr_write_beats, dbg_ddr_read_beats, dbg_ddr_write_batches,
                 dbg_ddr_read_batches, dbg_dequeue_stall_cycles, drain_ready_cycles,
                 output_fire_cycles, rank_order_errors, rank_record_admit_seen,
                 dbg_occupancy, dbg_offchip_min_rank, dbg_state);
        if (dbg_generated != SIM_MAX_PACKETS) $fatal(1, "wrong generated count");
        if (dbg_dequeued == 0) $fatal(1, "no dequeues observed");
        if (dbg_direct_sram_dequeued + dbg_ddr_sourced_dequeued != dbg_dequeued) begin
          $fatal(1, "dequeue source counters do not sum to dequeued count");
        end
        if (SIM_STRICT_CHECKS != 0) begin
          if (dbg_ddr_admit == 0) $fatal(1, "no DDR admissions observed");
          if (dbg_swap_out == 0) $fatal(1, "no swap-out observed");
          if (dbg_swap_in == 0) $fatal(1, "no swap-in observed");
          if (dbg_ddr_sourced_dequeued == 0) $fatal(1, "no DDR-sourced dequeues observed");
          if (dbg_ddr_write_beats == 0 || dbg_ddr_read_beats == 0) begin
            $fatal(1, "DDR beat counters did not advance");
          end
          if (dbg_ddr_write_batches == 0 || dbg_ddr_read_batches == 0) begin
            $fatal(1, "DDR batch counters did not advance");
          end
          if (!rank_record_admit_seen) begin
            $fatal(1, "no rank-record DDR admission observed while SRAM still had free slots");
          end
        end
        if ((SIM_CHECK_OUTPUT_RANK_ORDER != 0) && SIM_DRAIN_AFTER_GENERATION_ONLY &&
            (rank_order_errors != 0)) begin
          $fatal(1, "output ranks are not nondecreasing in drain-only mode");
        end
        $display("METRIC packet_loss_per_mille=%0d onchip_dequeue_hit_per_mille=%0d direct_sram_dequeue_per_mille=%0d ddr_sourced_dequeue_per_mille=%0d output_link_util_per_mille=%0d ddr_beat_pressure_per_mille=%0d swap_ops_per_kpkt=%0d ddr_write_beats=%0d ddr_read_beats=%0d ddr_write_batches=%0d ddr_read_batches=%0d dequeue_stall_cycles=%0d rank_order_errors=%0d",
                 (dbg_generated == 0) ? 0 : (dbg_drop * 32'd1000) / dbg_generated,
                 (dbg_dequeued == 0) ? 0 : (dbg_onchip_dequeue_hit * 32'd1000) / dbg_dequeued,
                 (dbg_dequeued == 0) ? 0 : (dbg_direct_sram_dequeued * 32'd1000) / dbg_dequeued,
                 (dbg_dequeued == 0) ? 0 : (dbg_ddr_sourced_dequeued * 32'd1000) / dbg_dequeued,
                 (drain_ready_cycles == 0) ? 0 : (output_fire_cycles * 32'd1000) / drain_ready_cycles,
                 (cycle_count == 0) ? 0 : ((dbg_ddr_write_beats + dbg_ddr_read_beats) * 32'd1000) / cycle_count,
                 (dbg_generated == 0) ? 0 : ((dbg_swap_out + dbg_swap_in) * 32'd1000) / dbg_generated,
                 dbg_ddr_write_beats, dbg_ddr_read_beats,
                 dbg_ddr_write_batches, dbg_ddr_read_batches,
                 dbg_dequeue_stall_cycles, rank_order_errors);
        $display("PASS: Themis subsystem admitted to SRAM/DDR, swapped, and drained");
        $finish;
      end
    end
    $display("TIMEOUT generated=%0d sram=%0d ddr=%0d swap_out=%0d swap_in=%0d dequeued=%0d direct=%0d ddr_src=%0d drop=%0d occ=0x%08x min_rank=0x%04x state=0x%02x",
             dbg_generated, dbg_sram_admit, dbg_ddr_admit, dbg_swap_out,
             dbg_swap_in, dbg_dequeued, dbg_direct_sram_dequeued,
             dbg_ddr_sourced_dequeued, dbg_drop, dbg_occupancy,
             dbg_offchip_min_rank, dbg_state);
    $fatal(1, "timeout waiting for Themis subsystem to drain");
  end
endmodule
