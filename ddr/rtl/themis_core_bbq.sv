`timescale 1ns/1ps

import heap_ops::*;

module themis_core_bbq #(
  parameter int RANK_WIDTH = 10,
  parameter int SEQ_WIDTH = 32,
  parameter int AXI_ADDR_WIDTH = 64,
  parameter int AXI_DATA_WIDTH = 512,
  parameter int AXI_ID_WIDTH = 4,
  parameter int SRAM_DEPTH = 32,
  parameter int DDR_BATCH_SIZE = 4,
  parameter int DDR_BATCH_SLOTS = 16,
  parameter int BBQ_BITMAP_WIDTH = 32,
  parameter logic [AXI_ADDR_WIDTH-1:0] DDR_BASE_ADDR = 64'h0,
  parameter logic [AXI_ADDR_WIDTH-1:0] DDR_ADDR_LIMIT = 64'h0000_0000_0100_0000,
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
  output logic                         m_axi_rready,

  output logic [31:0]                  stat_generated,
  output logic [31:0]                  stat_sram_admit,
  output logic [31:0]                  stat_ddr_admit,
  output logic [31:0]                  stat_swap_out,
  output logic [31:0]                  stat_swap_in,
  output logic [31:0]                  stat_dequeued,
  output logic [31:0]                  stat_drop,
  output logic [31:0]                  stat_onchip_dequeue_hit,
  output logic [31:0]                  stat_direct_sram_dequeued,
  output logic [31:0]                  stat_ddr_sourced_dequeued,
  output logic [31:0]                  stat_dequeue_stall_cycles,
  output logic [31:0]                  stat_ddr_write_beats,
  output logic [31:0]                  stat_ddr_read_beats,
  output logic [31:0]                  stat_ddr_write_batches,
  output logic [31:0]                  stat_ddr_read_batches,
  output logic [15:0]                  dbg_sram_count,
  output logic [15:0]                  dbg_ddr_batch_count,
  output logic [RANK_WIDTH-1:0]        dbg_offchip_min_rank,
  output logic [7:0]                   dbg_state
);
  localparam int BBQ_PRIORITY_WIDTH = 2 * $clog2(BBQ_BITMAP_WIDTH);
  localparam int SRAM_PTR_W = (SRAM_DEPTH <= 2) ? 1 : $clog2(SRAM_DEPTH);
  localparam int SRAM_MEM_DEPTH = (1 << SRAM_PTR_W);
  localparam int SRAM_USABLE = (1 << SRAM_PTR_W) - 1;
  localparam int BATCH_SLOT_W = (DDR_BATCH_SLOTS <= 2) ? 1 : $clog2(DDR_BATCH_SLOTS);
  localparam int BATCH_USABLE = (1 << BATCH_SLOT_W) - 1;
  localparam int BM_DATA_WIDTH = (SRAM_PTR_W > BATCH_SLOT_W) ? SRAM_PTR_W : BATCH_SLOT_W;
  localparam int BATCH_CNT_W = (DDR_BATCH_SIZE <= 1) ? 1 : $clog2(DDR_BATCH_SIZE + 1);
  localparam int SRAM_CELL_WIDTH = AXI_DATA_WIDTH + 1;
  localparam logic [RANK_WIDTH-1:0] MAX_RANK = {RANK_WIDTH{1'b1}};
  localparam logic BM_TIER_SRAM = 1'b0;
  localparam logic BM_TIER_OFFCHIP = 1'b1;
  localparam logic [BATCH_CNT_W-1:0] BATCH_SIZE_COUNT = DDR_BATCH_SIZE;
  localparam logic [AXI_ADDR_WIDTH-1:0] BATCH_BYTES = DDR_BATCH_SIZE * AXI_KEEP_WIDTH;
  localparam logic [15:0] SRAM_USABLE_U16 = SRAM_USABLE;
  localparam logic [15:0] BATCH_USABLE_U16 = BATCH_USABLE;
  localparam logic [15:0] DDR_BATCH_SIZE_U16 = DDR_BATCH_SIZE;
  localparam logic [15:0] SWAP_IN_WATERMARK_U16 = SWAP_IN_WATERMARK;
  localparam logic [15:0] SWAP_OUT_WATERMARK_U16 = SWAP_OUT_WATERMARK;

  if (RANK_WIDTH != BBQ_PRIORITY_WIDTH) begin : rank_width_guard
    initial $error("RANK_WIDTH must match the BBQ priority tree width");
  end

  typedef enum logic [1:0] {WR_IDLE, WR_ADDR, WR_DATA, WR_RESP} wr_state_t;
  typedef enum logic [1:0] {RD_IDLE, RD_ADDR, RD_DATA} rd_state_t;
  typedef enum logic [2:0] {
    SRAM_REQ_NONE,
    SRAM_REQ_ENQ,
    SRAM_REQ_DEQ_MIN,
    SRAM_REQ_DEQ_MAX_INGRESS,
    SRAM_REQ_DEQ_MAX_WATERMARK,
    SRAM_REQ_ENQ_SWAPIN
  } sram_req_t;
  typedef enum logic [2:0] {
    DDR_REQ_NONE,
    DDR_REQ_ENQ,
    DDR_REQ_DEQ_MIN,
    DDR_REQ_ENQ_WAIT,
    DDR_REQ_DEQ_MIN_WAIT
  } ddr_req_t;

  logic sram_cell_wr_en_q;
  logic [SRAM_PTR_W-1:0] sram_cell_wr_addr_q;
  logic [SRAM_CELL_WIDTH-1:0] sram_cell_wr_data_q;
  logic sram_cell_rd_en;
  logic [SRAM_PTR_W-1:0] sram_cell_rd_addr;
  logic [SRAM_CELL_WIDTH-1:0] sram_cell_rd_data;
  logic [SRAM_PTR_W-1:0] sram_free_list [0:SRAM_USABLE-1];
  logic [SRAM_PTR_W-1:0] sram_free_rd_q;
  logic [SRAM_PTR_W-1:0] sram_free_wr_q;
  logic [15:0] sram_free_count_q;
  logic [15:0] sram_count_q;
  logic sram_resp_valid_q;
  sram_req_t sram_resp_req_q;
  logic [SRAM_PTR_W-1:0] sram_resp_slot_q;
  logic [RANK_WIDTH-1:0] sram_resp_rank_q;

  logic [RANK_WIDTH-1:0] wr_buf_rank [0:DDR_BATCH_SIZE-1];
  logic [SEQ_WIDTH-1:0] wr_buf_seq [0:DDR_BATCH_SIZE-1];
  logic [PAYLOAD_WIDTH-1:0] wr_buf_payload [0:DDR_BATCH_SIZE-1];
  logic [BATCH_CNT_W-1:0] wr_buf_count_q;
  logic [RANK_WIDTH-1:0] wr_buf_min_rank_q;

  logic [AXI_ADDR_WIDTH-1:0] batch_addr [0:BATCH_USABLE-1];
  logic [RANK_WIDTH-1:0] batch_min_rank [0:BATCH_USABLE-1];
  logic [BATCH_CNT_W-1:0] batch_count [0:BATCH_USABLE-1];
  logic [BATCH_SLOT_W-1:0] batch_free_list [0:BATCH_USABLE-1];
  logic [BATCH_SLOT_W-1:0] batch_free_rd_q;
  logic [BATCH_SLOT_W-1:0] batch_free_wr_q;
  logic [15:0] batch_free_count_q;
  logic [15:0] ddr_batch_count_q;
  logic [AXI_ADDR_WIDTH-1:0] next_ddr_addr_q;
  logic [RANK_WIDTH-1:0] offchip_min_rank_q;
  logic min_rebuild_active_q;
  logic [BATCH_SLOT_W-1:0] min_rebuild_idx_q;
  logic [RANK_WIDTH-1:0] min_rebuild_value_q;

  wr_state_t wr_state_q;
  rd_state_t rd_state_q;
  logic [BATCH_SLOT_W-1:0] wr_slot_q;
  logic [BATCH_SLOT_W-1:0] rd_slot_q;
  logic [BATCH_CNT_W-1:0] wr_beat_q;
  logic [BATCH_CNT_W-1:0] rd_beat_q;
  logic [BATCH_CNT_W-1:0] wr_active_count_q;
  logic [BATCH_CNT_W-1:0] rd_active_count_q;
  logic [AXI_ADDR_WIDTH-1:0] wr_addr_q;
  logic [AXI_ADDR_WIDTH-1:0] rd_addr_q;
  logic wr_error_q;
  logic rd_error_q;

  logic ingress_hold_valid_q;
  logic [RANK_WIDTH-1:0] ingress_hold_rank_q;
  logic [SEQ_WIDTH-1:0] ingress_hold_seq_q;
  logic [PAYLOAD_WIDTH-1:0] ingress_hold_payload_q;

  logic bm_q_ready;
  logic bm_q_in_valid;
  logic bm_q_in_tier;
  heap_op_t bm_q_in_op_type;
  logic [BM_DATA_WIDTH-1:0] bm_q_in_he_data;
  logic [RANK_WIDTH-1:0] bm_q_in_he_priority;
  logic bm_q_out_valid;
  logic bm_q_out_tier;
  heap_op_t bm_q_out_op_type;
  logic [BM_DATA_WIDTH-1:0] bm_q_out_he_data;
  logic [RANK_WIDTH-1:0] bm_q_out_he_priority;
  logic bm_sram_min_valid;
  logic [RANK_WIDTH-1:0] bm_sram_min_priority;
  logic bm_sram_max_valid;
  logic [RANK_WIDTH-1:0] bm_sram_max_priority;
  logic bm_offchip_min_valid;
  logic [RANK_WIDTH-1:0] bm_offchip_min_priority;
  logic [15:0] bm_dbg_sram_occupancy;
  logic [15:0] bm_dbg_offchip_occupancy;
  sram_req_t sram_req_q;
  logic [15:0] sram_logical_free;

  ddr_req_t ddr_req_q;
  logic [BATCH_SLOT_W-1:0] ddr_enq_slot_q;
  logic [RANK_WIDTH-1:0] ddr_enq_rank_q;
  logic wr_resp_fire;
  logic wr_buf_append_ready;

  function automatic logic [AXI_DATA_WIDTH-1:0] pack_cell(
    input logic [RANK_WIDTH-1:0] rank_i,
    input logic [SEQ_WIDTH-1:0] seq_i,
    input logic [PAYLOAD_WIDTH-1:0] payload_i
  );
    begin
      pack_cell = {rank_i, seq_i, payload_i};
    end
  endfunction

  function automatic logic [SRAM_CELL_WIDTH-1:0] pack_sram_cell(
    input logic from_ddr_i,
    input logic [RANK_WIDTH-1:0] rank_i,
    input logic [SEQ_WIDTH-1:0] seq_i,
    input logic [PAYLOAD_WIDTH-1:0] payload_i
  );
    begin
      pack_sram_cell = {from_ddr_i, pack_cell(rank_i, seq_i, payload_i)};
    end
  endfunction

  function automatic logic sram_cell_from_ddr(input logic [SRAM_CELL_WIDTH-1:0] word);
    begin
      sram_cell_from_ddr = word[AXI_DATA_WIDTH];
    end
  endfunction

  function automatic logic [AXI_DATA_WIDTH-1:0] sram_cell_payload_word(
    input logic [SRAM_CELL_WIDTH-1:0] word
  );
    begin
      sram_cell_payload_word = word[AXI_DATA_WIDTH-1:0];
    end
  endfunction

  function automatic logic [RANK_WIDTH-1:0] unpack_rank(input logic [AXI_DATA_WIDTH-1:0] word);
    begin
      unpack_rank = word[AXI_DATA_WIDTH-1 -: RANK_WIDTH];
    end
  endfunction

  function automatic logic [SEQ_WIDTH-1:0] unpack_seq(input logic [AXI_DATA_WIDTH-1:0] word);
    begin
      unpack_seq = word[PAYLOAD_WIDTH +: SEQ_WIDTH];
    end
  endfunction

  function automatic logic [PAYLOAD_WIDTH-1:0] unpack_payload(input logic [AXI_DATA_WIDTH-1:0] word);
    begin
      unpack_payload = word[PAYLOAD_WIDTH-1:0];
    end
  endfunction

  function automatic logic [SRAM_PTR_W-1:0] sram_free_head;
    begin
      sram_free_head = sram_free_list[sram_free_rd_q];
    end
  endfunction

  function automatic logic [BATCH_SLOT_W-1:0] batch_free_head;
    begin
      batch_free_head = batch_free_list[batch_free_rd_q];
    end
  endfunction

  themis_bmsch_queue #(
    .PRIORITY_WIDTH(RANK_WIDTH),
    .DATA_WIDTH(BM_DATA_WIDTH),
    .SRAM_MAX_ENTRIES(SRAM_USABLE),
    .OFFCHIP_MAX_ENTRIES(BATCH_USABLE),
    .BITMAP_GROUP_WIDTH(BBQ_BITMAP_WIDTH)
  ) bmsch_q_i (
    .clk(clk),
    .rst(!resetn),
    .ready(bm_q_ready),
    .in_valid(bm_q_in_valid),
    .in_tier(bm_q_in_tier),
    .in_op_type(bm_q_in_op_type),
    .in_he_data(bm_q_in_he_data),
    .in_he_priority(bm_q_in_he_priority),
    .out_valid(bm_q_out_valid),
    .out_tier(bm_q_out_tier),
    .out_op_type(bm_q_out_op_type),
    .out_he_data(bm_q_out_he_data),
    .out_he_priority(bm_q_out_he_priority),
    .sram_min_valid(bm_sram_min_valid),
    .sram_min_priority(bm_sram_min_priority),
    .sram_max_valid(bm_sram_max_valid),
    .sram_max_priority(bm_sram_max_priority),
    .offchip_min_valid(bm_offchip_min_valid),
    .offchip_min_priority(bm_offchip_min_priority),
    .dbg_sram_occupancy(bm_dbg_sram_occupancy),
    .dbg_offchip_occupancy(bm_dbg_offchip_occupancy)
  );

  assign sram_cell_rd_en = bm_q_out_valid && (bm_q_out_tier == BM_TIER_SRAM) &&
                           ((sram_req_q == SRAM_REQ_DEQ_MIN) ||
                            (sram_req_q == SRAM_REQ_DEQ_MAX_INGRESS) ||
                            (sram_req_q == SRAM_REQ_DEQ_MAX_WATERMARK));
  assign sram_cell_rd_addr = bm_q_out_he_data[SRAM_PTR_W-1:0];

  themis_sram_cell_store #(
    .ADDR_WIDTH(SRAM_PTR_W),
    .DATA_WIDTH(SRAM_CELL_WIDTH),
    .DEPTH(SRAM_MEM_DEPTH)
  ) sram_cell_store_i (
    .clk(clk),
    .wr_en(sram_cell_wr_en_q),
    .wr_addr(sram_cell_wr_addr_q),
    .wr_data(sram_cell_wr_data_q),
    .rd_en(sram_cell_rd_en),
    .rd_addr(sram_cell_rd_addr),
    .rd_data(sram_cell_rd_data)
  );

  assign sram_logical_free = (sram_count_q >= SRAM_USABLE_U16) ?
                             16'd0 : (SRAM_USABLE_U16 - sram_count_q);
  assign s_pkt_ready = enable && !min_rebuild_active_q && !wr_resp_fire &&
                       bm_q_ready && (sram_req_q == SRAM_REQ_NONE) && (ddr_req_q == DDR_REQ_NONE) &&
                       !ingress_hold_valid_q && (rd_state_q == RD_IDLE) &&
                       ((sram_free_count_q != 16'd0) || (sram_count_q != 16'd0));
  assign m_axi_awid = '0;
  assign m_axi_awaddr = wr_addr_q;
  assign m_axi_awlen = {{(8-BATCH_CNT_W){1'b0}}, wr_active_count_q} - 8'd1;
  assign m_axi_awsize = 3'd6;
  assign m_axi_awburst = 2'b01;
  assign m_axi_awlock = 1'b0;
  assign m_axi_awcache = 4'b0011;
  assign m_axi_awprot = 3'b000;
  assign m_axi_awqos = 4'b0000;
  assign m_axi_wstrb = {AXI_KEEP_WIDTH{1'b1}};
  assign m_axi_wlast = (wr_beat_q + {{(BATCH_CNT_W-1){1'b0}}, 1'b1}) == wr_active_count_q;
  assign m_axi_bready = (wr_state_q == WR_RESP) && bm_q_ready &&
                        (sram_req_q == SRAM_REQ_NONE) && (ddr_req_q == DDR_REQ_NONE);
  assign wr_resp_fire = (wr_state_q == WR_RESP) && m_axi_bvalid && m_axi_bready;
  assign wr_buf_append_ready = (wr_state_q == WR_IDLE) && (wr_buf_count_q < BATCH_SIZE_COUNT);
  assign m_axi_arid = '0;
  assign m_axi_araddr = rd_addr_q;
  assign m_axi_arlen = {{(8-BATCH_CNT_W){1'b0}}, rd_active_count_q} - 8'd1;
  assign m_axi_arsize = 3'd6;
  assign m_axi_arburst = 2'b01;
  assign m_axi_arlock = 1'b0;
  assign m_axi_arcache = 4'b0011;
  assign m_axi_arprot = 3'b000;
  assign m_axi_arqos = 4'b0000;
  assign m_axi_rready = (rd_state_q == RD_DATA) && !sram_resp_valid_q && bm_q_ready &&
                         (sram_req_q == SRAM_REQ_NONE) && (ddr_req_q == DDR_REQ_NONE) &&
                         (sram_free_count_q != 16'd0) && (sram_logical_free != 16'd0) &&
                         (!m_pkt_valid || m_pkt_ready);

  assign dbg_sram_count = sram_count_q;
  assign dbg_ddr_batch_count = ddr_batch_count_q;
  assign dbg_offchip_min_rank = offchip_min_rank_q;
  assign dbg_state = {
    wr_error_q,
    rd_error_q,
    min_rebuild_active_q,
    sram_req_q[2:0],
    (ddr_req_q != DDR_REQ_NONE),
    ((ddr_req_q == DDR_REQ_DEQ_MIN) || (ddr_req_q == DDR_REQ_DEQ_MIN_WAIT))
  };

  task automatic append_ddr_cell(
    input logic [RANK_WIDTH-1:0] rank_i,
    input logic [SEQ_WIDTH-1:0] seq_i,
    input logic [PAYLOAD_WIDTH-1:0] payload_i
  );
    begin
      wr_buf_rank[wr_buf_count_q] <= rank_i;
      wr_buf_seq[wr_buf_count_q] <= seq_i;
      wr_buf_payload[wr_buf_count_q] <= payload_i;
      wr_buf_count_q <= wr_buf_count_q + {{(BATCH_CNT_W-1){1'b0}}, 1'b1};
      if (wr_buf_count_q == '0 || rank_i < wr_buf_min_rank_q) begin
        wr_buf_min_rank_q <= rank_i;
      end
      if (rank_i < offchip_min_rank_q) begin
        offchip_min_rank_q <= rank_i;
      end
    end
  endtask

  task automatic issue_sram_enq(
    input logic [SRAM_PTR_W-1:0] slot_i,
    input logic [RANK_WIDTH-1:0] rank_i,
    input sram_req_t req_i
  );
    begin
      bm_q_in_valid <= 1'b1;
      bm_q_in_tier <= BM_TIER_SRAM;
      bm_q_in_op_type <= HEAP_OP_ENQUE;
      bm_q_in_he_data <= {{(BM_DATA_WIDTH-SRAM_PTR_W){1'b0}}, slot_i};
      bm_q_in_he_priority <= rank_i;
      sram_req_q <= req_i;
    end
  endtask

  task automatic free_sram_slot(input logic [SRAM_PTR_W-1:0] slot_i);
    begin
      sram_free_list[sram_free_wr_q] <= slot_i;
      sram_free_wr_q <= (sram_free_wr_q == SRAM_USABLE-1) ? '0 : (sram_free_wr_q + 1'b1);
      sram_free_count_q <= sram_free_count_q + 16'd1;
    end
  endtask

  task automatic alloc_sram_slot(output logic [SRAM_PTR_W-1:0] slot_o);
    begin
      slot_o = sram_free_head();
      sram_free_rd_q <= (sram_free_rd_q == SRAM_USABLE-1) ? '0 : (sram_free_rd_q + 1'b1);
      sram_free_count_q <= sram_free_count_q - 16'd1;
    end
  endtask

  task automatic free_batch_slot(input logic [BATCH_SLOT_W-1:0] slot_i);
    begin
      batch_addr[slot_i] <= '0;
      batch_min_rank[slot_i] <= MAX_RANK;
      batch_count[slot_i] <= '0;
      batch_free_list[batch_free_wr_q] <= slot_i;
      batch_free_wr_q <= (batch_free_wr_q == BATCH_USABLE-1) ? '0 : (batch_free_wr_q + 1'b1);
      batch_free_count_q <= batch_free_count_q + 16'd1;
    end
  endtask

  task automatic start_offchip_min_rebuild;
    begin
      min_rebuild_active_q <= 1'b1;
      min_rebuild_idx_q <= '0;
      min_rebuild_value_q <= (wr_buf_count_q != '0) ? wr_buf_min_rank_q : MAX_RANK;
      offchip_min_rank_q <= MAX_RANK;
    end
  endtask

  task automatic alloc_batch_slot(output logic [BATCH_SLOT_W-1:0] slot_o);
    begin
      slot_o = batch_free_head();
      batch_free_rd_q <= (batch_free_rd_q == BATCH_USABLE-1) ? '0 : (batch_free_rd_q + 1'b1);
      batch_free_count_q <= batch_free_count_q - 16'd1;
    end
  endtask

  integer init_i;
  always_ff @(posedge clk) begin
    logic [SRAM_PTR_W-1:0] alloc_slot_v;
    logic [BATCH_SLOT_W-1:0] alloc_batch_v;
    logic [RANK_WIDTH-1:0] rd_rank_v;
    logic [SEQ_WIDTH-1:0] rd_seq_v;
    logic [PAYLOAD_WIDTH-1:0] rd_payload_v;
    logic ingress_to_offchip_v;
    logic dequeued_from_ddr_v;
    logic [RANK_WIDTH-1:0] min_scan_value_v;

    bm_q_in_valid <= 1'b0;
    bm_q_in_tier <= BM_TIER_SRAM;
    bm_q_in_op_type <= HEAP_OP_ENQUE;
    bm_q_in_he_data <= '0;
    bm_q_in_he_priority <= '0;
    sram_cell_wr_en_q <= 1'b0;
    sram_cell_wr_addr_q <= '0;
    sram_cell_wr_data_q <= '0;

    if (!resetn) begin
      for (init_i = 0; init_i < SRAM_USABLE; init_i = init_i + 1) begin
        sram_free_list[init_i] <= init_i[SRAM_PTR_W-1:0];
      end
      for (init_i = 0; init_i < BATCH_USABLE; init_i = init_i + 1) begin
        batch_free_list[init_i] <= init_i[BATCH_SLOT_W-1:0];
        batch_addr[init_i] <= '0;
        batch_min_rank[init_i] <= MAX_RANK;
        batch_count[init_i] <= '0;
      end
      sram_free_rd_q <= '0;
      sram_free_wr_q <= '0;
      sram_free_count_q <= SRAM_USABLE_U16;
      sram_count_q <= '0;
      batch_free_rd_q <= '0;
      batch_free_wr_q <= '0;
      batch_free_count_q <= BATCH_USABLE_U16;
      ddr_batch_count_q <= '0;
      wr_buf_count_q <= '0;
      wr_buf_min_rank_q <= MAX_RANK;
      offchip_min_rank_q <= MAX_RANK;
      min_rebuild_active_q <= 1'b0;
      min_rebuild_idx_q <= '0;
      min_rebuild_value_q <= MAX_RANK;
      next_ddr_addr_q <= DDR_BASE_ADDR;
      wr_state_q <= WR_IDLE;
      rd_state_q <= RD_IDLE;
      wr_slot_q <= '0;
      rd_slot_q <= '0;
      wr_beat_q <= '0;
      rd_beat_q <= '0;
      wr_active_count_q <= '0;
      rd_active_count_q <= '0;
      wr_addr_q <= '0;
      rd_addr_q <= '0;
      wr_error_q <= 1'b0;
      rd_error_q <= 1'b0;
      m_axi_awvalid <= 1'b0;
      m_axi_wvalid <= 1'b0;
      m_axi_wdata <= '0;
      m_axi_arvalid <= 1'b0;
      m_pkt_valid <= 1'b0;
      m_pkt_rank <= '0;
      m_pkt_seq <= '0;
      m_pkt_payload <= '0;
      sram_req_q <= SRAM_REQ_NONE;
      sram_resp_valid_q <= 1'b0;
      sram_resp_req_q <= SRAM_REQ_NONE;
      sram_resp_slot_q <= '0;
      sram_resp_rank_q <= '0;
      sram_cell_wr_en_q <= 1'b0;
      sram_cell_wr_addr_q <= '0;
      sram_cell_wr_data_q <= '0;
      ddr_req_q <= DDR_REQ_NONE;
      ddr_enq_slot_q <= '0;
      ddr_enq_rank_q <= MAX_RANK;
      ingress_hold_valid_q <= 1'b0;
      ingress_hold_rank_q <= '0;
      ingress_hold_seq_q <= '0;
      ingress_hold_payload_q <= '0;
      stat_generated <= '0;
      stat_sram_admit <= '0;
      stat_ddr_admit <= '0;
      stat_swap_out <= '0;
      stat_swap_in <= '0;
      stat_dequeued <= '0;
      stat_drop <= '0;
      stat_onchip_dequeue_hit <= '0;
      stat_direct_sram_dequeued <= '0;
      stat_ddr_sourced_dequeued <= '0;
      stat_dequeue_stall_cycles <= '0;
      stat_ddr_write_beats <= '0;
      stat_ddr_read_beats <= '0;
      stat_ddr_write_batches <= '0;
      stat_ddr_read_batches <= '0;
    end else begin
      if (min_rebuild_active_q) begin
        min_scan_value_v = min_rebuild_value_q;
        if ((batch_count[min_rebuild_idx_q] != '0) &&
            (batch_min_rank[min_rebuild_idx_q] < min_scan_value_v)) begin
          min_scan_value_v = batch_min_rank[min_rebuild_idx_q];
        end
        min_rebuild_value_q <= min_scan_value_v;
        if (min_rebuild_idx_q == BATCH_USABLE-1) begin
          offchip_min_rank_q <= min_scan_value_v;
          min_rebuild_active_q <= 1'b0;
          min_rebuild_idx_q <= '0;
        end else begin
          min_rebuild_idx_q <= min_rebuild_idx_q + 1'b1;
        end
      end

      if (m_pkt_valid && m_pkt_ready) begin
        m_pkt_valid <= 1'b0;
      end

      if (enable && dequeue_enable && m_pkt_ready && !m_pkt_valid &&
          (sram_count_q == 16'd0) &&
          ((wr_buf_count_q != '0) || (ddr_batch_count_q != 16'd0) ||
           (rd_state_q != RD_IDLE) || (wr_state_q != WR_IDLE))) begin
        stat_dequeue_stall_cycles <= stat_dequeue_stall_cycles + 32'd1;
      end

      if (sram_resp_valid_q) begin
        unique case (sram_resp_req_q)
          SRAM_REQ_DEQ_MIN: begin
            if (!m_pkt_valid || m_pkt_ready) begin
              dequeued_from_ddr_v = sram_cell_from_ddr(sram_cell_rd_data);
              m_pkt_valid <= 1'b1;
              m_pkt_rank <= sram_resp_rank_q;
              m_pkt_seq <= unpack_seq(sram_cell_payload_word(sram_cell_rd_data));
              m_pkt_payload <= unpack_payload(sram_cell_payload_word(sram_cell_rd_data));
              free_sram_slot(sram_resp_slot_q);
              sram_count_q <= sram_count_q - 16'd1;
              stat_dequeued <= stat_dequeued + 32'd1;
              stat_onchip_dequeue_hit <= stat_onchip_dequeue_hit + 32'd1;
              if (dequeued_from_ddr_v) begin
                stat_ddr_sourced_dequeued <= stat_ddr_sourced_dequeued + 32'd1;
              end else begin
                stat_direct_sram_dequeued <= stat_direct_sram_dequeued + 32'd1;
              end
              sram_resp_valid_q <= 1'b0;
              sram_req_q <= SRAM_REQ_NONE;
            end
          end
          SRAM_REQ_DEQ_MAX_WATERMARK: begin
            if (wr_buf_append_ready) begin
              append_ddr_cell(sram_resp_rank_q, unpack_seq(sram_cell_payload_word(sram_cell_rd_data)),
                              unpack_payload(sram_cell_payload_word(sram_cell_rd_data)));
              free_sram_slot(sram_resp_slot_q);
              sram_count_q <= sram_count_q - 16'd1;
              stat_swap_out <= stat_swap_out + 32'd1;
              sram_resp_valid_q <= 1'b0;
              sram_req_q <= SRAM_REQ_NONE;
            end else begin
              issue_sram_enq(sram_resp_slot_q, sram_resp_rank_q, SRAM_REQ_ENQ);
              sram_resp_valid_q <= 1'b0;
            end
          end
          SRAM_REQ_DEQ_MAX_INGRESS: begin
            if (ingress_hold_valid_q) begin
              if (ingress_hold_rank_q < sram_resp_rank_q) begin
                if (wr_buf_append_ready) begin
                  append_ddr_cell(sram_resp_rank_q, unpack_seq(sram_cell_payload_word(sram_cell_rd_data)),
                                  unpack_payload(sram_cell_payload_word(sram_cell_rd_data)));
                  stat_swap_out <= stat_swap_out + 32'd1;
                end else begin
                  stat_drop <= stat_drop + 32'd1;
                end
                sram_cell_wr_en_q <= 1'b1;
                sram_cell_wr_addr_q <= sram_resp_slot_q;
                sram_cell_wr_data_q <= pack_sram_cell(1'b0, ingress_hold_rank_q, ingress_hold_seq_q,
                                                      ingress_hold_payload_q);
                issue_sram_enq(sram_resp_slot_q, ingress_hold_rank_q, SRAM_REQ_ENQ);
                stat_sram_admit <= stat_sram_admit + 32'd1;
              end else begin
                if (wr_buf_append_ready) begin
                  append_ddr_cell(ingress_hold_rank_q, ingress_hold_seq_q, ingress_hold_payload_q);
                  stat_ddr_admit <= stat_ddr_admit + 32'd1;
                end else begin
                  stat_drop <= stat_drop + 32'd1;
                end
                issue_sram_enq(sram_resp_slot_q, sram_resp_rank_q, SRAM_REQ_ENQ);
              end
              ingress_hold_valid_q <= 1'b0;
              sram_resp_valid_q <= 1'b0;
            end else begin
              issue_sram_enq(sram_resp_slot_q, sram_resp_rank_q, SRAM_REQ_ENQ);
              sram_resp_valid_q <= 1'b0;
            end
          end
          default: begin
            sram_resp_valid_q <= 1'b0;
            sram_req_q <= SRAM_REQ_NONE;
          end
        endcase
      end

      if (bm_q_out_valid && (bm_q_out_tier == BM_TIER_SRAM)) begin
        unique case (sram_req_q)
          SRAM_REQ_ENQ, SRAM_REQ_ENQ_SWAPIN: begin
            sram_req_q <= SRAM_REQ_NONE;
          end
          SRAM_REQ_DEQ_MIN, SRAM_REQ_DEQ_MAX_INGRESS, SRAM_REQ_DEQ_MAX_WATERMARK: begin
            sram_resp_valid_q <= 1'b1;
            sram_resp_req_q <= sram_req_q;
            sram_resp_slot_q <= bm_q_out_he_data[SRAM_PTR_W-1:0];
            sram_resp_rank_q <= bm_q_out_he_priority;
          end
          default: begin
            sram_req_q <= SRAM_REQ_NONE;
          end
        endcase
      end

      if (bm_q_out_valid && (bm_q_out_tier == BM_TIER_OFFCHIP)) begin
        unique case (ddr_req_q)
          DDR_REQ_ENQ, DDR_REQ_ENQ_WAIT: begin
            ddr_req_q <= DDR_REQ_NONE;
          end
          DDR_REQ_DEQ_MIN_WAIT: begin
            rd_slot_q <= bm_q_out_he_data[BATCH_SLOT_W-1:0];
            rd_addr_q <= batch_addr[bm_q_out_he_data[BATCH_SLOT_W-1:0]];
            rd_active_count_q <= batch_count[bm_q_out_he_data[BATCH_SLOT_W-1:0]];
            m_axi_arvalid <= 1'b1;
            rd_beat_q <= '0;
            rd_state_q <= RD_ADDR;
            ddr_batch_count_q <= ddr_batch_count_q - 16'd1;
            stat_ddr_read_batches <= stat_ddr_read_batches + 32'd1;
            free_batch_slot(bm_q_out_he_data[BATCH_SLOT_W-1:0]);
            start_offchip_min_rebuild();
            ddr_req_q <= DDR_REQ_NONE;
          end
          DDR_REQ_DEQ_MIN: begin
            ddr_req_q <= DDR_REQ_DEQ_MIN;
          end
          default: begin
            ddr_req_q <= DDR_REQ_NONE;
          end
        endcase
      end

      case (wr_state_q)
        WR_IDLE: begin
          if (enable && (wr_buf_count_q == BATCH_SIZE_COUNT ||
              (flush && wr_buf_count_q != '0)) && (batch_free_count_q != 16'd0)) begin
            alloc_batch_slot(alloc_batch_v);
            wr_slot_q <= alloc_batch_v;
            wr_addr_q <= next_ddr_addr_q;
            wr_active_count_q <= wr_buf_count_q;
            m_axi_awvalid <= 1'b1;
            wr_beat_q <= '0;
            wr_state_q <= WR_ADDR;
          end
        end
        WR_ADDR: begin
          if (m_axi_awvalid && m_axi_awready) begin
            m_axi_awvalid <= 1'b0;
            m_axi_wvalid <= 1'b1;
            m_axi_wdata <= pack_cell(wr_buf_rank[0], wr_buf_seq[0], wr_buf_payload[0]);
            wr_state_q <= WR_DATA;
          end
        end
        WR_DATA: begin
          if (m_axi_wvalid && m_axi_wready) begin
            stat_ddr_write_beats <= stat_ddr_write_beats + 32'd1;
            if ((wr_beat_q + {{(BATCH_CNT_W-1){1'b0}}, 1'b1}) == wr_active_count_q) begin
              m_axi_wvalid <= 1'b0;
              wr_state_q <= WR_RESP;
            end else begin
              wr_beat_q <= wr_beat_q + {{(BATCH_CNT_W-1){1'b0}}, 1'b1};
              m_axi_wdata <= pack_cell(
                wr_buf_rank[wr_beat_q + {{(BATCH_CNT_W-1){1'b0}}, 1'b1}],
                wr_buf_seq[wr_beat_q + {{(BATCH_CNT_W-1){1'b0}}, 1'b1}],
                wr_buf_payload[wr_beat_q + {{(BATCH_CNT_W-1){1'b0}}, 1'b1}]
              );
            end
          end
        end
        WR_RESP: begin
          if (wr_resp_fire) begin
            wr_error_q <= wr_error_q | (m_axi_bresp != 2'b00);
            batch_addr[wr_slot_q] <= wr_addr_q;
            batch_min_rank[wr_slot_q] <= wr_buf_min_rank_q;
            batch_count[wr_slot_q] <= wr_active_count_q;
            ddr_enq_slot_q <= wr_slot_q;
            ddr_enq_rank_q <= wr_buf_min_rank_q;
            ddr_req_q <= DDR_REQ_ENQ;
            ddr_batch_count_q <= ddr_batch_count_q + 16'd1;
            stat_ddr_write_batches <= stat_ddr_write_batches + 32'd1;
            wr_buf_count_q <= '0;
            wr_buf_min_rank_q <= MAX_RANK;
            next_ddr_addr_q <= (next_ddr_addr_q + BATCH_BYTES >= DDR_ADDR_LIMIT) ?
                               DDR_BASE_ADDR : (next_ddr_addr_q + BATCH_BYTES);
            wr_state_q <= WR_IDLE;
          end
        end
        default: wr_state_q <= WR_IDLE;
      endcase

      case (rd_state_q)
        RD_IDLE: begin
          if (enable && !min_rebuild_active_q &&
              !wr_resp_fire && bm_q_ready && (ddr_req_q == DDR_REQ_NONE) &&
              (sram_req_q == SRAM_REQ_NONE) && !sram_resp_valid_q &&
              (ddr_batch_count_q != 16'd0) && (sram_free_count_q > DDR_BATCH_SIZE_U16) &&
              (sram_logical_free > DDR_BATCH_SIZE_U16) &&
              ((sram_count_q <= SWAP_IN_WATERMARK_U16) ||
               (bm_sram_min_valid && (offchip_min_rank_q < bm_sram_min_priority)))) begin
            ddr_req_q <= DDR_REQ_DEQ_MIN;
          end
        end
        RD_ADDR: begin
          if (m_axi_arvalid && m_axi_arready) begin
            m_axi_arvalid <= 1'b0;
            rd_state_q <= RD_DATA;
          end
        end
        RD_DATA: begin
          if (m_axi_rvalid && m_axi_rready) begin
            stat_ddr_read_beats <= stat_ddr_read_beats + 32'd1;
            rd_error_q <= rd_error_q | (m_axi_rresp != 2'b00) |
                          (m_axi_rlast != ((rd_beat_q + {{(BATCH_CNT_W-1){1'b0}}, 1'b1}) == rd_active_count_q));
            rd_rank_v = unpack_rank(m_axi_rdata);
            rd_seq_v = unpack_seq(m_axi_rdata);
            rd_payload_v = unpack_payload(m_axi_rdata);
            alloc_sram_slot(alloc_slot_v);
            sram_cell_wr_en_q <= 1'b1;
            sram_cell_wr_addr_q <= alloc_slot_v;
            sram_cell_wr_data_q <= pack_sram_cell(1'b1, rd_rank_v, rd_seq_v, rd_payload_v);
            issue_sram_enq(alloc_slot_v, rd_rank_v, SRAM_REQ_ENQ_SWAPIN);
            sram_count_q <= sram_count_q + 16'd1;
            stat_swap_in <= stat_swap_in + 32'd1;
            if ((rd_beat_q + {{(BATCH_CNT_W-1){1'b0}}, 1'b1}) == rd_active_count_q) begin
              rd_state_q <= RD_IDLE;
            end else begin
              rd_beat_q <= rd_beat_q + {{(BATCH_CNT_W-1){1'b0}}, 1'b1};
            end
          end
        end
        default: rd_state_q <= RD_IDLE;
      endcase

      if (enable && (ddr_req_q == DDR_REQ_ENQ) && bm_q_ready &&
          (sram_req_q == SRAM_REQ_NONE) && !sram_resp_valid_q) begin
        bm_q_in_valid <= 1'b1;
        bm_q_in_tier <= BM_TIER_OFFCHIP;
        bm_q_in_op_type <= HEAP_OP_ENQUE;
        bm_q_in_he_data <= {{(BM_DATA_WIDTH-BATCH_SLOT_W){1'b0}}, ddr_enq_slot_q};
        bm_q_in_he_priority <= ddr_enq_rank_q;
        ddr_req_q <= DDR_REQ_ENQ_WAIT;
      end else if (enable && (ddr_req_q == DDR_REQ_DEQ_MIN) && bm_q_ready &&
                   (sram_req_q == SRAM_REQ_NONE) && !sram_resp_valid_q) begin
        bm_q_in_valid <= 1'b1;
        bm_q_in_tier <= BM_TIER_OFFCHIP;
        bm_q_in_op_type <= HEAP_OP_DEQUE_MIN;
        bm_q_in_he_data <= '0;
        bm_q_in_he_priority <= '0;
        ddr_req_q <= DDR_REQ_DEQ_MIN_WAIT;
      end else if (enable && s_pkt_valid && s_pkt_ready && !wr_resp_fire) begin
        stat_generated <= stat_generated + 32'd1;
        ingress_to_offchip_v = (offchip_min_rank_q != MAX_RANK) &&
                               (s_pkt_rank > offchip_min_rank_q);
        if (ingress_to_offchip_v) begin
          if (wr_buf_append_ready) begin
            append_ddr_cell(s_pkt_rank, s_pkt_seq, s_pkt_payload);
            stat_ddr_admit <= stat_ddr_admit + 32'd1;
          end else begin
            stat_drop <= stat_drop + 32'd1;
          end
        end else if ((sram_free_count_q != 16'd0) && (sram_logical_free != 16'd0)) begin
          alloc_sram_slot(alloc_slot_v);
          sram_cell_wr_en_q <= 1'b1;
          sram_cell_wr_addr_q <= alloc_slot_v;
          sram_cell_wr_data_q <= pack_sram_cell(1'b0, s_pkt_rank, s_pkt_seq, s_pkt_payload);
          issue_sram_enq(alloc_slot_v, s_pkt_rank, SRAM_REQ_ENQ);
          sram_count_q <= sram_count_q + 16'd1;
          stat_sram_admit <= stat_sram_admit + 32'd1;
        end else begin
          ingress_hold_valid_q <= 1'b1;
          ingress_hold_rank_q <= s_pkt_rank;
          ingress_hold_seq_q <= s_pkt_seq;
          ingress_hold_payload_q <= s_pkt_payload;
          bm_q_in_valid <= 1'b1;
          bm_q_in_tier <= BM_TIER_SRAM;
          bm_q_in_op_type <= HEAP_OP_DEQUE_MAX;
          bm_q_in_he_data <= '0;
          bm_q_in_he_priority <= '0;
          sram_req_q <= SRAM_REQ_DEQ_MAX_INGRESS;
        end
      end else if (enable && dequeue_enable && !wr_resp_fire && !min_rebuild_active_q &&
                   bm_q_ready && (sram_req_q == SRAM_REQ_NONE) &&
                   (ddr_req_q == DDR_REQ_NONE) &&
                   (rd_state_q == RD_IDLE) && !m_pkt_valid && m_pkt_ready &&
                   (sram_count_q != 16'd0) &&
                   ((offchip_min_rank_q == MAX_RANK) ||
                    !bm_sram_min_valid ||
                    (bm_sram_min_priority <= offchip_min_rank_q))) begin
        bm_q_in_valid <= 1'b1;
        bm_q_in_tier <= BM_TIER_SRAM;
        bm_q_in_op_type <= HEAP_OP_DEQUE_MIN;
        bm_q_in_he_data <= '0;
        bm_q_in_he_priority <= '0;
        sram_req_q <= SRAM_REQ_DEQ_MIN;
      end else if (enable && !wr_resp_fire && !min_rebuild_active_q &&
                   bm_q_ready && (sram_req_q == SRAM_REQ_NONE) && (ddr_req_q == DDR_REQ_NONE) &&
                   (rd_state_q == RD_IDLE) &&
                   (((!flush) && (sram_count_q >= SWAP_OUT_WATERMARK_U16)) ||
                    (bm_sram_min_valid && (offchip_min_rank_q < bm_sram_min_priority) &&
                     ((sram_free_count_q <= DDR_BATCH_SIZE_U16) ||
                      (sram_logical_free <= DDR_BATCH_SIZE_U16)))) &&
                   wr_buf_append_ready) begin
        bm_q_in_valid <= 1'b1;
        bm_q_in_tier <= BM_TIER_SRAM;
        bm_q_in_op_type <= HEAP_OP_DEQUE_MAX;
        bm_q_in_he_data <= '0;
        bm_q_in_he_priority <= '0;
        sram_req_q <= SRAM_REQ_DEQ_MAX_WATERMARK;
      end
    end
  end

  logic unused_axi_ids;
  assign unused_axi_ids = ^m_axi_bid ^ ^m_axi_rid;
endmodule

module themis_sram_cell_store #(
  parameter int ADDR_WIDTH = 5,
  parameter int DATA_WIDTH = 512,
  parameter int DEPTH = 32
) (
  input  logic                        clk,
  input  logic                        wr_en,
  input  logic [ADDR_WIDTH-1:0]       wr_addr,
  input  logic [DATA_WIDTH-1:0]       wr_data,
  input  logic                        rd_en,
  input  logic [ADDR_WIDTH-1:0]       rd_addr,
  output logic [DATA_WIDTH-1:0]       rd_data
);
  (* ram_style = "block" *) logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

  always_ff @(posedge clk) begin
    if (wr_en) begin
      mem[wr_addr] <= wr_data;
    end
    if (rd_en) begin
      rd_data <= mem[rd_addr];
    end
  end
endmodule
