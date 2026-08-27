`timescale 1ns/1ps

module themis_u200_top #(
  parameter int RANK_WIDTH = 10,
  parameter int SEQ_WIDTH = 32,
  parameter int AXI_ADDR_WIDTH = 64,
  parameter int AXI_DATA_WIDTH = 512,
  parameter int AXI_ID_WIDTH = 4,
  parameter int SRAM_DEPTH = 32,
  parameter int DDR_BATCH_SIZE = 4,
  parameter int DDR_BATCH_SLOTS = 16,
  parameter int BBQ_BITMAP_WIDTH = 32,
  parameter int MAX_PACKETS = 512,
  parameter int GEN_PERIOD_CYCLES = 1,
  parameter bit DRAIN_AFTER_GENERATION_ONLY = 1'b1,
  parameter int DRAIN_PERIOD_CYCLES = 1,
  parameter int SWAP_IN_WATERMARK = 8,
  parameter int SWAP_OUT_WATERMARK = 24,
  parameter int RANK_DIST = 0,
  parameter int HIGH_PRIORITY_PER1024 = 256,
  localparam int PAYLOAD_WIDTH = AXI_DATA_WIDTH - RANK_WIDTH - SEQ_WIDTH
) (
  input  logic                       clk,
  input  logic                       resetn,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWID" *)
  output logic [AXI_ID_WIDTH-1:0]    m_axi_awid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWADDR" *)
  output logic [AXI_ADDR_WIDTH-1:0]  m_axi_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLEN" *)
  output logic [7:0]                 m_axi_awlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWSIZE" *)
  output logic [2:0]                 m_axi_awsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWBURST" *)
  output logic [1:0]                 m_axi_awburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLOCK" *)
  output logic                       m_axi_awlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWCACHE" *)
  output logic [3:0]                 m_axi_awcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWPROT" *)
  output logic [2:0]                 m_axi_awprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWQOS" *)
  output logic [3:0]                 m_axi_awqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWVALID" *)
  output logic                       m_axi_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWREADY" *)
  input  logic                       m_axi_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WDATA" *)
  output logic [AXI_DATA_WIDTH-1:0]  m_axi_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WSTRB" *)
  output logic [AXI_DATA_WIDTH/8-1:0] m_axi_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WLAST" *)
  output logic                       m_axi_wlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WVALID" *)
  output logic                       m_axi_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WREADY" *)
  input  logic                       m_axi_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BID" *)
  input  logic [AXI_ID_WIDTH-1:0]    m_axi_bid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BRESP" *)
  input  logic [1:0]                 m_axi_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BVALID" *)
  input  logic                       m_axi_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BREADY" *)
  output logic                       m_axi_bready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARID" *)
  output logic [AXI_ID_WIDTH-1:0]    m_axi_arid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARADDR" *)
  output logic [AXI_ADDR_WIDTH-1:0]  m_axi_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLEN" *)
  output logic [7:0]                 m_axi_arlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARSIZE" *)
  output logic [2:0]                 m_axi_arsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARBURST" *)
  output logic [1:0]                 m_axi_arburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLOCK" *)
  output logic                       m_axi_arlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARCACHE" *)
  output logic [3:0]                 m_axi_arcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARPROT" *)
  output logic [2:0]                 m_axi_arprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARQOS" *)
  output logic [3:0]                 m_axi_arqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARVALID" *)
  output logic                       m_axi_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARREADY" *)
  input  logic                       m_axi_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RID" *)
  input  logic [AXI_ID_WIDTH-1:0]    m_axi_rid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RDATA" *)
  input  logic [AXI_DATA_WIDTH-1:0]  m_axi_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RRESP" *)
  input  logic [1:0]                 m_axi_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RLAST" *)
  input  logic                       m_axi_rlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RVALID" *)
  input  logic                       m_axi_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RREADY" *)
  (* X_INTERFACE_PARAMETER = "PROTOCOL AXI4, DATA_WIDTH 512, ADDR_WIDTH 64, ID_WIDTH 4, HAS_BURST 1, HAS_LOCK 1, HAS_PROT 1, HAS_CACHE 1, HAS_QOS 1, SUPPORTS_NARROW_BURST 0, MAX_BURST_LENGTH 256" *)
  output logic                       m_axi_rready,

  output logic [31:0]                dbg_generated,
  output logic [31:0]                dbg_dequeued,
  output logic [31:0]                dbg_sram_admit,
  output logic [31:0]                dbg_ddr_admit,
  output logic [31:0]                dbg_swap_out,
  output logic [31:0]                dbg_swap_in,
  output logic [31:0]                dbg_drop,
  output logic [31:0]                dbg_onchip_dequeue_hit,
  output logic [31:0]                dbg_direct_sram_dequeued,
  output logic [31:0]                dbg_ddr_sourced_dequeued,
  output logic [31:0]                dbg_dequeue_stall_cycles,
  output logic [31:0]                dbg_ddr_write_beats,
  output logic [31:0]                dbg_ddr_read_beats,
  output logic [31:0]                dbg_ddr_write_batches,
  output logic [31:0]                dbg_ddr_read_batches,
  output logic [31:0]                dbg_occupancy,
  output logic [15:0]                dbg_offchip_min_rank,
  output logic [7:0]                 dbg_state,
  output logic [31:0]                dbg_run_cycles,
  output logic [31:0]                dbg_output_fire_cycles,
  output logic [31:0]                dbg_drain_ready_cycles,
  output logic [31:0]                dbg_rank_order_errors,
  output logic [15:0]                dbg_last_out_rank,
  output logic [15:0]                dbg_current_out_rank,
  output logic                       dbg_out_valid,
  output logic                       dbg_drain_ready,
  output logic                       dbg_rank_order_prev_valid,
  output logic                       done
);
  logic gen_valid;
  logic gen_ready;
  logic [RANK_WIDTH-1:0] gen_rank;
  logic [SEQ_WIDTH-1:0] gen_seq;
  logic [PAYLOAD_WIDTH-1:0] gen_payload;
  logic gen_done;
  logic core_dequeue_enable;
  logic out_valid;
  logic drain_ready;
  logic drain_period_ready;
  logic [RANK_WIDTH-1:0] out_rank;
  logic [SEQ_WIDTH-1:0] out_seq;
  logic [PAYLOAD_WIDTH-1:0] out_payload;
  logic [31:0] stat_generated;
  logic [31:0] stat_sram_admit;
  logic [31:0] stat_ddr_admit;
  logic [31:0] stat_swap_out;
  logic [31:0] stat_swap_in;
  logic [31:0] stat_dequeued;
  logic [31:0] stat_drop;
  logic [31:0] stat_onchip_dequeue_hit;
  logic [31:0] stat_direct_sram_dequeued;
  logic [31:0] stat_ddr_sourced_dequeued;
  logic [31:0] stat_dequeue_stall_cycles;
  logic [31:0] stat_ddr_write_beats;
  logic [31:0] stat_ddr_read_beats;
  logic [31:0] stat_ddr_write_batches;
  logic [31:0] stat_ddr_read_batches;
  logic [15:0] sram_count;
  logic [15:0] ddr_batch_count;
  logic [RANK_WIDTH-1:0] core_offchip_min_rank;
  logic [31:0] stat_run_cycles;
  logic [31:0] stat_output_fire_cycles;
  logic [31:0] stat_drain_ready_cycles;
  logic [31:0] stat_rank_order_errors;
  logic rank_order_prev_valid_q;
  logic [RANK_WIDTH-1:0] last_out_rank_q;
  logic [RANK_WIDTH-1:0] current_out_rank_q;
  localparam int DRAIN_PERIOD_W = (DRAIN_PERIOD_CYCLES <= 1) ? 1 : $clog2(DRAIN_PERIOD_CYCLES);
  logic [DRAIN_PERIOD_W-1:0] drain_period_q;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      drain_period_q <= '0;
    end else if (DRAIN_PERIOD_CYCLES > 1) begin
      drain_period_q <= (drain_period_q == DRAIN_PERIOD_CYCLES-1) ? '0 : (drain_period_q + 1'b1);
    end else begin
      drain_period_q <= '0;
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      stat_run_cycles <= '0;
      stat_output_fire_cycles <= '0;
      stat_drain_ready_cycles <= '0;
      stat_rank_order_errors <= '0;
      rank_order_prev_valid_q <= 1'b0;
      last_out_rank_q <= '0;
      current_out_rank_q <= '0;
    end else if (!done) begin
      stat_run_cycles <= stat_run_cycles + 32'd1;
      if (drain_ready) begin
        stat_drain_ready_cycles <= stat_drain_ready_cycles + 32'd1;
      end
      if (out_valid && drain_ready) begin
        stat_output_fire_cycles <= stat_output_fire_cycles + 32'd1;
        current_out_rank_q <= out_rank;
        if (DRAIN_AFTER_GENERATION_ONLY && rank_order_prev_valid_q &&
            (out_rank < last_out_rank_q)) begin
          stat_rank_order_errors <= stat_rank_order_errors + 32'd1;
        end
        last_out_rank_q <= out_rank;
        rank_order_prev_valid_q <= 1'b1;
      end
    end
  end

  assign drain_period_ready = (DRAIN_PERIOD_CYCLES <= 1) ? 1'b1 : (drain_period_q == '0);
  assign drain_ready = DRAIN_AFTER_GENERATION_ONLY ?
                       (gen_done && !gen_valid && drain_period_ready) :
                       drain_period_ready;
  assign core_dequeue_enable = gen_done || !DRAIN_AFTER_GENERATION_ONLY;

  themis_synthetic_packet_gen #(
    .RANK_WIDTH(RANK_WIDTH),
    .SEQ_WIDTH(SEQ_WIDTH),
    .PAYLOAD_WIDTH(PAYLOAD_WIDTH),
    .PERIOD_CYCLES(GEN_PERIOD_CYCLES),
    .MAX_PACKETS(MAX_PACKETS),
    .RANK_DIST(RANK_DIST),
    .HIGH_PRIORITY_PER1024(HIGH_PRIORITY_PER1024)
  ) gen_i (
    .clk(clk),
    .resetn(resetn),
    .enable(1'b1),
    .ready(gen_ready),
    .valid(gen_valid),
    .rank(gen_rank),
    .seq(gen_seq),
    .payload(gen_payload),
    .done(gen_done)
  );

  themis_core_bbq #(
    .RANK_WIDTH(RANK_WIDTH),
    .SEQ_WIDTH(SEQ_WIDTH),
    .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
    .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
    .AXI_ID_WIDTH(AXI_ID_WIDTH),
    .SRAM_DEPTH(SRAM_DEPTH),
    .DDR_BATCH_SIZE(DDR_BATCH_SIZE),
    .DDR_BATCH_SLOTS(DDR_BATCH_SLOTS),
    .BBQ_BITMAP_WIDTH(BBQ_BITMAP_WIDTH),
    .SWAP_IN_WATERMARK(SWAP_IN_WATERMARK),
    .SWAP_OUT_WATERMARK(SWAP_OUT_WATERMARK)
  ) core_i (
    .clk(clk),
    .resetn(resetn),
    .enable(1'b1),
    .flush(gen_done),
    .dequeue_enable(core_dequeue_enable),
    .s_pkt_valid(gen_valid),
    .s_pkt_ready(gen_ready),
    .s_pkt_rank(gen_rank),
    .s_pkt_seq(gen_seq),
    .s_pkt_payload(gen_payload),
    .m_pkt_valid(out_valid),
    .m_pkt_ready(drain_ready),
    .m_pkt_rank(out_rank),
    .m_pkt_seq(out_seq),
    .m_pkt_payload(out_payload),
    .m_axi_awid(m_axi_awid),
    .m_axi_awaddr(m_axi_awaddr),
    .m_axi_awlen(m_axi_awlen),
    .m_axi_awsize(m_axi_awsize),
    .m_axi_awburst(m_axi_awburst),
    .m_axi_awlock(m_axi_awlock),
    .m_axi_awcache(m_axi_awcache),
    .m_axi_awprot(m_axi_awprot),
    .m_axi_awqos(m_axi_awqos),
    .m_axi_awvalid(m_axi_awvalid),
    .m_axi_awready(m_axi_awready),
    .m_axi_wdata(m_axi_wdata),
    .m_axi_wstrb(m_axi_wstrb),
    .m_axi_wlast(m_axi_wlast),
    .m_axi_wvalid(m_axi_wvalid),
    .m_axi_wready(m_axi_wready),
    .m_axi_bid(m_axi_bid),
    .m_axi_bresp(m_axi_bresp),
    .m_axi_bvalid(m_axi_bvalid),
    .m_axi_bready(m_axi_bready),
    .m_axi_arid(m_axi_arid),
    .m_axi_araddr(m_axi_araddr),
    .m_axi_arlen(m_axi_arlen),
    .m_axi_arsize(m_axi_arsize),
    .m_axi_arburst(m_axi_arburst),
    .m_axi_arlock(m_axi_arlock),
    .m_axi_arcache(m_axi_arcache),
    .m_axi_arprot(m_axi_arprot),
    .m_axi_arqos(m_axi_arqos),
    .m_axi_arvalid(m_axi_arvalid),
    .m_axi_arready(m_axi_arready),
    .m_axi_rid(m_axi_rid),
    .m_axi_rdata(m_axi_rdata),
    .m_axi_rresp(m_axi_rresp),
    .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(m_axi_rvalid),
    .m_axi_rready(m_axi_rready),
    .stat_generated(stat_generated),
    .stat_sram_admit(stat_sram_admit),
    .stat_ddr_admit(stat_ddr_admit),
    .stat_swap_out(stat_swap_out),
    .stat_swap_in(stat_swap_in),
    .stat_dequeued(stat_dequeued),
    .stat_drop(stat_drop),
    .stat_onchip_dequeue_hit(stat_onchip_dequeue_hit),
    .stat_direct_sram_dequeued(stat_direct_sram_dequeued),
    .stat_ddr_sourced_dequeued(stat_ddr_sourced_dequeued),
    .stat_dequeue_stall_cycles(stat_dequeue_stall_cycles),
    .stat_ddr_write_beats(stat_ddr_write_beats),
    .stat_ddr_read_beats(stat_ddr_read_beats),
    .stat_ddr_write_batches(stat_ddr_write_batches),
    .stat_ddr_read_batches(stat_ddr_read_batches),
    .dbg_sram_count(sram_count),
    .dbg_ddr_batch_count(ddr_batch_count),
    .dbg_offchip_min_rank(core_offchip_min_rank),
    .dbg_state(dbg_state)
  );

  assign dbg_generated = stat_generated;
  assign dbg_dequeued = stat_dequeued;
  assign dbg_sram_admit = stat_sram_admit;
  assign dbg_ddr_admit = stat_ddr_admit;
  assign dbg_swap_out = stat_swap_out;
  assign dbg_swap_in = stat_swap_in;
  assign dbg_drop = stat_drop;
  assign dbg_onchip_dequeue_hit = stat_onchip_dequeue_hit;
  assign dbg_direct_sram_dequeued = stat_direct_sram_dequeued;
  assign dbg_ddr_sourced_dequeued = stat_ddr_sourced_dequeued;
  assign dbg_dequeue_stall_cycles = stat_dequeue_stall_cycles;
  assign dbg_ddr_write_beats = stat_ddr_write_beats;
  assign dbg_ddr_read_beats = stat_ddr_read_beats;
  assign dbg_ddr_write_batches = stat_ddr_write_batches;
  assign dbg_ddr_read_batches = stat_ddr_read_batches;
  assign dbg_occupancy = {ddr_batch_count, sram_count};
  assign dbg_offchip_min_rank = {{(16-RANK_WIDTH){1'b0}}, core_offchip_min_rank};
  assign dbg_run_cycles = stat_run_cycles;
  assign dbg_output_fire_cycles = stat_output_fire_cycles;
  assign dbg_drain_ready_cycles = stat_drain_ready_cycles;
  assign dbg_rank_order_errors = stat_rank_order_errors;
  assign dbg_last_out_rank = {{(16-RANK_WIDTH){1'b0}}, last_out_rank_q};
  assign dbg_current_out_rank = {{(16-RANK_WIDTH){1'b0}}, current_out_rank_q};
  assign dbg_out_valid = out_valid;
  assign dbg_drain_ready = drain_ready;
  assign dbg_rank_order_prev_valid = rank_order_prev_valid_q;
  assign done = gen_done && !gen_valid && !out_valid && (dbg_state == 8'h00) &&
                (stat_dequeued + stat_drop == stat_generated) &&
                (sram_count == 16'd0) && (ddr_batch_count == 16'd0);

  logic unused_output;
  assign unused_output = out_valid ^ ^out_rank ^ ^out_seq ^ ^out_payload;
endmodule
