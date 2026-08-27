`timescale 1ns/1ps

module themis_core_stripped_top #(
  parameter int RANK_WIDTH = 10,
  parameter int SEQ_WIDTH = 32,
  parameter int AXI_ADDR_WIDTH = 64,
  parameter int AXI_DATA_WIDTH = 512,
  parameter int AXI_ID_WIDTH = 4,
  parameter int SRAM_DEPTH = 32,
  parameter int DDR_BATCH_SIZE = 4,
  parameter int DDR_BATCH_SLOTS = 16,
  parameter int BBQ_BITMAP_WIDTH = 32,
  parameter int SWAP_IN_WATERMARK = 8,
  parameter int SWAP_OUT_WATERMARK = 24,
  localparam int PAYLOAD_WIDTH = AXI_DATA_WIDTH - RANK_WIDTH - SEQ_WIDTH,
  localparam int AXI_KEEP_WIDTH = AXI_DATA_WIDTH / 8
) (
  input  logic                         clk,
  input  logic                         resetn,
  input  logic                         enable,
  input  logic                         flush,
  input  logic                         dequeue_enable,

  input  logic                         s_pkt_valid,
  output logic                         s_pkt_ready,
  input  logic [RANK_WIDTH-1:0]        s_pkt_rank,
  input  logic [SEQ_WIDTH-1:0]         s_pkt_seq,
  input  logic [PAYLOAD_WIDTH-1:0]     s_pkt_payload,

  output logic                         m_pkt_valid,
  input  logic                         m_pkt_ready,
  output logic [RANK_WIDTH-1:0]        m_pkt_rank,
  output logic [SEQ_WIDTH-1:0]         m_pkt_seq,
  output logic [PAYLOAD_WIDTH-1:0]     m_pkt_payload,

  output logic [AXI_ID_WIDTH-1:0]      m_axi_awid,
  output logic [AXI_ADDR_WIDTH-1:0]    m_axi_awaddr,
  output logic [7:0]                   m_axi_awlen,
  output logic [2:0]                   m_axi_awsize,
  output logic [1:0]                   m_axi_awburst,
  output logic                         m_axi_awlock,
  output logic [3:0]                   m_axi_awcache,
  output logic [2:0]                   m_axi_awprot,
  output logic [3:0]                   m_axi_awqos,
  output logic                         m_axi_awvalid,
  input  logic                         m_axi_awready,
  output logic [AXI_DATA_WIDTH-1:0]    m_axi_wdata,
  output logic [AXI_KEEP_WIDTH-1:0]    m_axi_wstrb,
  output logic                         m_axi_wlast,
  output logic                         m_axi_wvalid,
  input  logic                         m_axi_wready,
  input  logic [AXI_ID_WIDTH-1:0]      m_axi_bid,
  input  logic [1:0]                   m_axi_bresp,
  input  logic                         m_axi_bvalid,
  output logic                         m_axi_bready,
  output logic [AXI_ID_WIDTH-1:0]      m_axi_arid,
  output logic [AXI_ADDR_WIDTH-1:0]    m_axi_araddr,
  output logic [7:0]                   m_axi_arlen,
  output logic [2:0]                   m_axi_arsize,
  output logic [1:0]                   m_axi_arburst,
  output logic                         m_axi_arlock,
  output logic [3:0]                   m_axi_arcache,
  output logic [2:0]                   m_axi_arprot,
  output logic [3:0]                   m_axi_arqos,
  output logic                         m_axi_arvalid,
  input  logic                         m_axi_arready,
  input  logic [AXI_ID_WIDTH-1:0]      m_axi_rid,
  input  logic [AXI_DATA_WIDTH-1:0]    m_axi_rdata,
  input  logic [1:0]                   m_axi_rresp,
  input  logic                         m_axi_rlast,
  input  logic                         m_axi_rvalid,
  output logic                         m_axi_rready
);
  logic [31:0] stat_generated_unused;
  logic [31:0] stat_sram_admit_unused;
  logic [31:0] stat_ddr_admit_unused;
  logic [31:0] stat_swap_out_unused;
  logic [31:0] stat_swap_in_unused;
  logic [31:0] stat_dequeued_unused;
  logic [31:0] stat_drop_unused;
  logic [31:0] stat_onchip_dequeue_hit_unused;
  logic [31:0] stat_direct_sram_dequeued_unused;
  logic [31:0] stat_ddr_sourced_dequeued_unused;
  logic [31:0] stat_dequeue_stall_cycles_unused;
  logic [31:0] stat_ddr_write_beats_unused;
  logic [31:0] stat_ddr_read_beats_unused;
  logic [31:0] stat_ddr_write_batches_unused;
  logic [31:0] stat_ddr_read_batches_unused;
  logic [15:0] dbg_sram_count_unused;
  logic [15:0] dbg_ddr_batch_count_unused;
  logic [RANK_WIDTH-1:0] dbg_offchip_min_rank_unused;
  logic [7:0] dbg_state_unused;

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
    .enable(enable),
    .flush(flush),
    .dequeue_enable(dequeue_enable),
    .s_pkt_valid(s_pkt_valid),
    .s_pkt_ready(s_pkt_ready),
    .s_pkt_rank(s_pkt_rank),
    .s_pkt_seq(s_pkt_seq),
    .s_pkt_payload(s_pkt_payload),
    .m_pkt_valid(m_pkt_valid),
    .m_pkt_ready(m_pkt_ready),
    .m_pkt_rank(m_pkt_rank),
    .m_pkt_seq(m_pkt_seq),
    .m_pkt_payload(m_pkt_payload),
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
    .stat_generated(stat_generated_unused),
    .stat_sram_admit(stat_sram_admit_unused),
    .stat_ddr_admit(stat_ddr_admit_unused),
    .stat_swap_out(stat_swap_out_unused),
    .stat_swap_in(stat_swap_in_unused),
    .stat_dequeued(stat_dequeued_unused),
    .stat_drop(stat_drop_unused),
    .stat_onchip_dequeue_hit(stat_onchip_dequeue_hit_unused),
    .stat_direct_sram_dequeued(stat_direct_sram_dequeued_unused),
    .stat_ddr_sourced_dequeued(stat_ddr_sourced_dequeued_unused),
    .stat_dequeue_stall_cycles(stat_dequeue_stall_cycles_unused),
    .stat_ddr_write_beats(stat_ddr_write_beats_unused),
    .stat_ddr_read_beats(stat_ddr_read_beats_unused),
    .stat_ddr_write_batches(stat_ddr_write_batches_unused),
    .stat_ddr_read_batches(stat_ddr_read_batches_unused),
    .dbg_sram_count(dbg_sram_count_unused),
    .dbg_ddr_batch_count(dbg_ddr_batch_count_unused),
    .dbg_offchip_min_rank(dbg_offchip_min_rank_unused),
    .dbg_state(dbg_state_unused)
  );
endmodule
