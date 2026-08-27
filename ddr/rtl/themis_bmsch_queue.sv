`timescale 1ns/1ps

import heap_ops::*;

module themis_bmsch_queue #(
  parameter int PRIORITY_WIDTH = 10,
  parameter int DATA_WIDTH = 5,
  parameter int SRAM_MAX_ENTRIES = 31,
  parameter int OFFCHIP_MAX_ENTRIES = 31,
  parameter int BITMAP_GROUP_WIDTH = 32,
  localparam int GROUP_BITS = $clog2(BITMAP_GROUP_WIDTH),
  localparam int NUM_PRIORITIES = (1 << PRIORITY_WIDTH),
  localparam int NUM_GROUPS = (NUM_PRIORITIES + BITMAP_GROUP_WIDTH - 1) / BITMAP_GROUP_WIDTH,
  localparam int GROUP_IDX_W = (NUM_GROUPS <= 2) ? 1 : $clog2(NUM_GROUPS),
  localparam int MAX_ENTRIES = (SRAM_MAX_ENTRIES > OFFCHIP_MAX_ENTRIES) ?
                               SRAM_MAX_ENTRIES : OFFCHIP_MAX_ENTRIES,
  localparam int ENTRY_PTR_W = $clog2(MAX_ENTRIES + 1),
  localparam int INIT_LIMIT = (MAX_ENTRIES > 2) ? MAX_ENTRIES : 2,
  localparam int INIT_IDX_W = $clog2(INIT_LIMIT + 1),
  localparam int PB_ADDR_W = PRIORITY_WIDTH + 1,
  localparam int PB_DEPTH = (1 << PB_ADDR_W)
) (
  input  logic                        clk,
  input  logic                        rst,
  output logic                        ready,

  input  logic                        in_valid,
  input  logic                        in_tier,
  input  heap_op_t                    in_op_type,
  input  logic [DATA_WIDTH-1:0]       in_he_data,
  input  logic [PRIORITY_WIDTH-1:0]   in_he_priority,

  output logic                        out_valid,
  output logic                        out_tier,
  output heap_op_t                    out_op_type,
  output logic [DATA_WIDTH-1:0]       out_he_data,
  output logic [PRIORITY_WIDTH-1:0]   out_he_priority,

  output logic                        sram_min_valid,
  output logic [PRIORITY_WIDTH-1:0]   sram_min_priority,
  output logic                        sram_max_valid,
  output logic [PRIORITY_WIDTH-1:0]   sram_max_priority,
  output logic                        offchip_min_valid,
  output logic [PRIORITY_WIDTH-1:0]   offchip_min_priority,
  output logic [15:0]                 dbg_sram_occupancy,
  output logic [15:0]                 dbg_offchip_occupancy
);
  localparam logic [ENTRY_PTR_W-1:0] INVALID_PTR = MAX_ENTRIES[ENTRY_PTR_W-1:0];
  localparam logic [INIT_IDX_W-1:0] MAX_ENTRIES_IDX = MAX_ENTRIES;
  localparam logic [ENTRY_PTR_W-1:0] SRAM_CAPACITY = SRAM_MAX_ENTRIES[ENTRY_PTR_W-1:0];
  localparam logic [ENTRY_PTR_W-1:0] OFFCHIP_CAPACITY = OFFCHIP_MAX_ENTRIES[ENTRY_PTR_W-1:0];

  typedef enum logic [3:0] {
    INIT_FILL_FREE,
    SUMMARY_UPDATE,
    READY,
    ENQ_ISSUE_PB,
    ENQ_READ_PB,
    DEQ_SELECT_BUCKET,
    DEQ_ISSUE_PB,
    DEQ_READ_PB,
    DEQ_COMMIT
  } state_t;

  state_t state_q;
  logic [INIT_IDX_W-1:0] init_idx_q;

  logic [ENTRY_PTR_W-1:0] free_stack [0:1][0:MAX_ENTRIES-1];
  logic [ENTRY_PTR_W-1:0] free_count_q [0:1];
  logic [ENTRY_PTR_W-1:0] occupancy_q [0:1];
  logic [ENTRY_PTR_W-1:0] next_ptr [0:1][0:MAX_ENTRIES-1];
  logic [ENTRY_PTR_W-1:0] prev_ptr [0:1][0:MAX_ENTRIES-1];
  logic [DATA_WIDTH-1:0] entry_data [0:1][0:MAX_ENTRIES-1];

  logic [NUM_GROUPS-1:0] l1_bitmap_q [0:1];
  logic [BITMAP_GROUP_WIDTH-1:0] l2_bitmap_q [0:1][0:NUM_GROUPS-1];

  logic pb_head_rd_en;
  logic [PB_ADDR_W-1:0] pb_head_rd_addr;
  logic [ENTRY_PTR_W-1:0] pb_head_rd_data;
  logic pb_head_wr_en;
  logic [PB_ADDR_W-1:0] pb_head_wr_addr;
  logic [ENTRY_PTR_W-1:0] pb_head_wr_data;

  logic pb_tail_rd_en;
  logic [PB_ADDR_W-1:0] pb_tail_rd_addr;
  logic [ENTRY_PTR_W-1:0] pb_tail_rd_data;
  logic pb_tail_wr_en;
  logic [PB_ADDR_W-1:0] pb_tail_wr_addr;
  logic [ENTRY_PTR_W-1:0] pb_tail_wr_data;

  logic pending_tier_q;
  heap_op_t pending_op_type_q;
  logic [DATA_WIDTH-1:0] pending_in_data_q;
  logic [GROUP_IDX_W-1:0] pending_group_q;
  logic [GROUP_BITS-1:0] pending_bucket_q;
  logic [PRIORITY_WIDTH-1:0] pending_priority_q;
  logic [ENTRY_PTR_W-1:0] pending_tail_q;
  logic [ENTRY_PTR_W-1:0] pending_prev_q;
  logic [DATA_WIDTH-1:0] pending_data_q;
  logic pending_bucket_nonempty_q;

  logic summary_sram_min_valid_c;
  logic [PRIORITY_WIDTH-1:0] summary_sram_min_priority_c;
  logic summary_sram_max_valid_c;
  logic [PRIORITY_WIDTH-1:0] summary_sram_max_priority_c;
  logic summary_offchip_min_valid_c;
  logic [PRIORITY_WIDTH-1:0] summary_offchip_min_priority_c;
  logic sram_min_valid_q;
  logic [PRIORITY_WIDTH-1:0] sram_min_priority_q;
  logic sram_max_valid_q;
  logic [PRIORITY_WIDTH-1:0] sram_max_priority_q;
  logic offchip_min_valid_q;
  logic [PRIORITY_WIDTH-1:0] offchip_min_priority_q;

  logic [GROUP_IDX_W-1:0] select_group_c;
  logic [GROUP_BITS-1:0] select_bucket_c;
  logic [PRIORITY_WIDTH-1:0] select_priority_c;
  logic [ENTRY_PTR_W-1:0] enq_entry_ptr_c;
  logic [ENTRY_PTR_W-1:0] enq_old_head_c;
  logic enq_bucket_nonempty_c;

  assign ready = (state_q == READY);
  assign dbg_sram_occupancy = {{(16-ENTRY_PTR_W){1'b0}}, occupancy_q[1'b0]};
  assign dbg_offchip_occupancy = {{(16-ENTRY_PTR_W){1'b0}}, occupancy_q[1'b1]};
  assign sram_min_valid = sram_min_valid_q;
  assign sram_min_priority = sram_min_priority_q;
  assign sram_max_valid = sram_max_valid_q;
  assign sram_max_priority = sram_max_priority_q;
  assign offchip_min_valid = offchip_min_valid_q;
  assign offchip_min_priority = offchip_min_priority_q;

  function automatic logic [PB_ADDR_W-1:0] pb_addr(
    input logic tier_i,
    input logic [PRIORITY_WIDTH-1:0] priority_i
  );
    begin
      pb_addr = {tier_i, priority_i};
    end
  endfunction

  function automatic logic [GROUP_IDX_W-1:0] find_lsb_group(input logic [NUM_GROUPS-1:0] bits);
    int idx;
    begin
      find_lsb_group = '0;
      for (idx = NUM_GROUPS - 1; idx >= 0; idx = idx - 1) begin
        if (bits[idx]) begin
          find_lsb_group = idx[GROUP_IDX_W-1:0];
        end
      end
    end
  endfunction

  function automatic logic [GROUP_IDX_W-1:0] find_msb_group(input logic [NUM_GROUPS-1:0] bits);
    int idx;
    begin
      find_msb_group = '0;
      for (idx = 0; idx < NUM_GROUPS; idx = idx + 1) begin
        if (bits[idx]) begin
          find_msb_group = idx[GROUP_IDX_W-1:0];
        end
      end
    end
  endfunction

  function automatic logic [GROUP_BITS-1:0] find_lsb_bucket(input logic [BITMAP_GROUP_WIDTH-1:0] bits);
    int idx;
    begin
      find_lsb_bucket = '0;
      for (idx = BITMAP_GROUP_WIDTH - 1; idx >= 0; idx = idx - 1) begin
        if (bits[idx]) begin
          find_lsb_bucket = idx[GROUP_BITS-1:0];
        end
      end
    end
  endfunction

  function automatic logic [GROUP_BITS-1:0] find_msb_bucket(input logic [BITMAP_GROUP_WIDTH-1:0] bits);
    int idx;
    begin
      find_msb_bucket = '0;
      for (idx = 0; idx < BITMAP_GROUP_WIDTH; idx = idx + 1) begin
        if (bits[idx]) begin
          find_msb_bucket = idx[GROUP_BITS-1:0];
        end
      end
    end
  endfunction

  always_comb begin
    logic [GROUP_IDX_W-1:0] group_v;
    logic [GROUP_BITS-1:0] bucket_v;

    summary_sram_min_valid_c = (occupancy_q[1'b0] != '0);
    summary_sram_min_priority_c = '0;
    summary_sram_max_valid_c = (occupancy_q[1'b0] != '0);
    summary_sram_max_priority_c = '0;
    summary_offchip_min_valid_c = (occupancy_q[1'b1] != '0);
    summary_offchip_min_priority_c = '1;

    if (summary_sram_min_valid_c) begin
      group_v = find_lsb_group(l1_bitmap_q[1'b0]);
      bucket_v = find_lsb_bucket(l2_bitmap_q[1'b0][group_v]);
      summary_sram_min_priority_c = {group_v, bucket_v};
    end
    if (summary_sram_max_valid_c) begin
      group_v = find_msb_group(l1_bitmap_q[1'b0]);
      bucket_v = find_msb_bucket(l2_bitmap_q[1'b0][group_v]);
      summary_sram_max_priority_c = {group_v, bucket_v};
    end
    if (summary_offchip_min_valid_c) begin
      group_v = find_lsb_group(l1_bitmap_q[1'b1]);
      bucket_v = find_lsb_bucket(l2_bitmap_q[1'b1][group_v]);
      summary_offchip_min_priority_c = {group_v, bucket_v};
    end
  end

  always_comb begin
    select_group_c = '0;
    select_bucket_c = '0;
    select_priority_c = '0;
    if ((state_q == READY) && (in_op_type == HEAP_OP_DEQUE_MIN)) begin
      select_group_c = find_lsb_group(l1_bitmap_q[in_tier]);
    end else if (state_q == READY) begin
      select_group_c = find_msb_group(l1_bitmap_q[in_tier]);
    end else if (pending_op_type_q == HEAP_OP_DEQUE_MIN) begin
      select_bucket_c = find_lsb_bucket(l2_bitmap_q[pending_tier_q][pending_group_q]);
    end else begin
      select_bucket_c = find_msb_bucket(l2_bitmap_q[pending_tier_q][pending_group_q]);
    end
    select_priority_c = {pending_group_q, select_bucket_c};
  end

  assign enq_entry_ptr_c = free_stack[pending_tier_q][free_count_q[pending_tier_q] - 1'b1];
  assign enq_old_head_c = pb_head_rd_data;
  assign enq_bucket_nonempty_c = l2_bitmap_q[pending_tier_q][pending_group_q][pending_bucket_q];

  always_comb begin
    pb_head_rd_en = 1'b0;
    pb_head_rd_addr = pb_addr(pending_tier_q, pending_priority_q);
    pb_tail_rd_en = 1'b0;
    pb_tail_rd_addr = pb_addr(pending_tier_q, pending_priority_q);

    if (state_q == ENQ_ISSUE_PB) begin
      pb_head_rd_en = 1'b1;
      pb_head_rd_addr = pb_addr(pending_tier_q, pending_priority_q);
    end

    if (state_q == DEQ_ISSUE_PB) begin
      pb_tail_rd_en = 1'b1;
      pb_tail_rd_addr = pb_addr(pending_tier_q, pending_priority_q);
    end
  end

  always_comb begin
    pb_head_wr_en = 1'b0;
    pb_head_wr_addr = pb_addr(pending_tier_q, pending_priority_q);
    pb_head_wr_data = INVALID_PTR;
    pb_tail_wr_en = 1'b0;
    pb_tail_wr_addr = pb_addr(pending_tier_q, pending_priority_q);
    pb_tail_wr_data = INVALID_PTR;

    if (state_q == ENQ_READ_PB) begin
      pb_head_wr_en = 1'b1;
      pb_head_wr_data = enq_entry_ptr_c;
      if (!pending_bucket_nonempty_q) begin
        pb_tail_wr_en = 1'b1;
        pb_tail_wr_data = enq_entry_ptr_c;
      end
    end else if (state_q == DEQ_COMMIT) begin
      if (pending_prev_q == INVALID_PTR) begin
        pb_head_wr_en = 1'b1;
        pb_head_wr_data = INVALID_PTR;
        pb_tail_wr_en = 1'b1;
        pb_tail_wr_data = INVALID_PTR;
      end else begin
        pb_tail_wr_en = 1'b1;
        pb_tail_wr_data = pending_prev_q;
      end
    end
  end

  themis_bmsch_sync_ram #(
    .DATA_WIDTH(ENTRY_PTR_W),
    .ADDR_WIDTH(PB_ADDR_W),
    .DEPTH(PB_DEPTH)
  ) pb_head_ram_i (
    .clk(clk),
    .wr_en(pb_head_wr_en),
    .wr_addr(pb_head_wr_addr),
    .wr_data(pb_head_wr_data),
    .rd_en(pb_head_rd_en),
    .rd_addr(pb_head_rd_addr),
    .rd_data(pb_head_rd_data)
  );

  themis_bmsch_sync_ram #(
    .DATA_WIDTH(ENTRY_PTR_W),
    .ADDR_WIDTH(PB_ADDR_W),
    .DEPTH(PB_DEPTH)
  ) pb_tail_ram_i (
    .clk(clk),
    .wr_en(pb_tail_wr_en),
    .wr_addr(pb_tail_wr_addr),
    .wr_data(pb_tail_wr_data),
    .rd_en(pb_tail_rd_en),
    .rd_addr(pb_tail_rd_addr),
    .rd_data(pb_tail_rd_data)
  );

  task automatic set_bucket_nonempty(
    input logic tier_i,
    input logic [GROUP_IDX_W-1:0] group_i,
    input logic [GROUP_BITS-1:0] bucket_i
  );
    begin
      l1_bitmap_q[tier_i][group_i] <= 1'b1;
      l2_bitmap_q[tier_i][group_i][bucket_i] <= 1'b1;
    end
  endtask

  task automatic clear_bucket_if_empty(
    input logic tier_i,
    input logic [GROUP_IDX_W-1:0] group_i,
    input logic [GROUP_BITS-1:0] bucket_i
  );
    logic [BITMAP_GROUP_WIDTH-1:0] bucket_mask_v;
    begin
      bucket_mask_v = {{(BITMAP_GROUP_WIDTH-1){1'b0}}, 1'b1} << bucket_i;
      l2_bitmap_q[tier_i][group_i][bucket_i] <= 1'b0;
      if ((l2_bitmap_q[tier_i][group_i] & ~bucket_mask_v) == '0) begin
        l1_bitmap_q[tier_i][group_i] <= 1'b0;
      end
    end
  endtask

  integer rst_i;
  always_ff @(posedge clk) begin
    logic is_enqueue_v;
    logic is_dequeue_min_v;
    logic is_dequeue_max_v;
    logic [ENTRY_PTR_W-1:0] tail_ptr_v;

    out_valid <= 1'b0;
    out_tier <= in_tier;
    out_op_type <= in_op_type;
    out_he_data <= '0;
    out_he_priority <= '0;

    if (rst) begin
      state_q <= INIT_FILL_FREE;
      init_idx_q <= '0;
      free_count_q[1'b0] <= '0;
      free_count_q[1'b1] <= '0;
      occupancy_q[1'b0] <= '0;
      occupancy_q[1'b1] <= '0;
      l1_bitmap_q[1'b0] <= '0;
      l1_bitmap_q[1'b1] <= '0;
      pending_tier_q <= 1'b0;
      pending_op_type_q <= HEAP_OP_DEQUE_MIN;
      pending_in_data_q <= '0;
      pending_group_q <= '0;
      pending_bucket_q <= '0;
      pending_priority_q <= '0;
      pending_tail_q <= INVALID_PTR;
      pending_prev_q <= INVALID_PTR;
      pending_data_q <= '0;
      pending_bucket_nonempty_q <= 1'b0;
      sram_min_valid_q <= 1'b0;
      sram_min_priority_q <= '0;
      sram_max_valid_q <= 1'b0;
      sram_max_priority_q <= '0;
      offchip_min_valid_q <= 1'b0;
      offchip_min_priority_q <= '1;
      for (rst_i = 0; rst_i < NUM_GROUPS; rst_i = rst_i + 1) begin
        l2_bitmap_q[1'b0][rst_i] <= '0;
        l2_bitmap_q[1'b1][rst_i] <= '0;
      end
    end else begin
      unique case (state_q)
        INIT_FILL_FREE: begin
          if (init_idx_q < MAX_ENTRIES_IDX) begin
            if (init_idx_q < SRAM_MAX_ENTRIES) begin
              free_stack[1'b0][init_idx_q[ENTRY_PTR_W-1:0]] <= init_idx_q[ENTRY_PTR_W-1:0];
            end
            if (init_idx_q < OFFCHIP_MAX_ENTRIES) begin
              free_stack[1'b1][init_idx_q[ENTRY_PTR_W-1:0]] <= init_idx_q[ENTRY_PTR_W-1:0];
            end
            next_ptr[1'b0][init_idx_q[ENTRY_PTR_W-1:0]] <= INVALID_PTR;
            prev_ptr[1'b0][init_idx_q[ENTRY_PTR_W-1:0]] <= INVALID_PTR;
            entry_data[1'b0][init_idx_q[ENTRY_PTR_W-1:0]] <= '0;
            next_ptr[1'b1][init_idx_q[ENTRY_PTR_W-1:0]] <= INVALID_PTR;
            prev_ptr[1'b1][init_idx_q[ENTRY_PTR_W-1:0]] <= INVALID_PTR;
            entry_data[1'b1][init_idx_q[ENTRY_PTR_W-1:0]] <= '0;
          end
          if (init_idx_q == INIT_LIMIT - 1) begin
            init_idx_q <= '0;
            free_count_q[1'b0] <= SRAM_CAPACITY;
            free_count_q[1'b1] <= OFFCHIP_CAPACITY;
            state_q <= SUMMARY_UPDATE;
          end else begin
            init_idx_q <= init_idx_q + 1'b1;
          end
        end
        SUMMARY_UPDATE: begin
          sram_min_valid_q <= summary_sram_min_valid_c;
          sram_min_priority_q <= summary_sram_min_priority_c;
          sram_max_valid_q <= summary_sram_max_valid_c;
          sram_max_priority_q <= summary_sram_max_priority_c;
          offchip_min_valid_q <= summary_offchip_min_valid_c;
          offchip_min_priority_q <= summary_offchip_min_priority_c;
          state_q <= READY;
        end
        READY: begin
          if (in_valid) begin
            is_enqueue_v = (in_op_type == HEAP_OP_ENQUE);
            is_dequeue_min_v = (in_op_type == HEAP_OP_DEQUE_MIN);
            is_dequeue_max_v = (in_op_type == HEAP_OP_DEQUE_MAX);

            if (is_enqueue_v && (free_count_q[in_tier] != '0)) begin
              pending_tier_q <= in_tier;
              pending_op_type_q <= in_op_type;
              pending_in_data_q <= in_he_data;
              pending_group_q <= in_he_priority[PRIORITY_WIDTH-1:GROUP_BITS];
              pending_bucket_q <= in_he_priority[GROUP_BITS-1:0];
              pending_priority_q <= in_he_priority;
              state_q <= ENQ_ISSUE_PB;
            end else if ((is_dequeue_min_v || is_dequeue_max_v) && (occupancy_q[in_tier] != '0)) begin
              pending_tier_q <= in_tier;
              pending_op_type_q <= in_op_type;
              pending_group_q <= select_group_c;
              state_q <= DEQ_SELECT_BUCKET;
            end
          end
        end
        ENQ_ISSUE_PB: begin
          pending_bucket_nonempty_q <= enq_bucket_nonempty_c;
          state_q <= ENQ_READ_PB;
        end
        ENQ_READ_PB: begin
          entry_data[pending_tier_q][enq_entry_ptr_c] <= pending_in_data_q;
          prev_ptr[pending_tier_q][enq_entry_ptr_c] <= INVALID_PTR;
          next_ptr[pending_tier_q][enq_entry_ptr_c] <=
            pending_bucket_nonempty_q ? enq_old_head_c : INVALID_PTR;
          if (pending_bucket_nonempty_q) begin
            prev_ptr[pending_tier_q][enq_old_head_c] <= enq_entry_ptr_c;
          end else begin
            set_bucket_nonempty(pending_tier_q, pending_group_q, pending_bucket_q);
          end

          free_count_q[pending_tier_q] <= free_count_q[pending_tier_q] - 1'b1;
          occupancy_q[pending_tier_q] <= occupancy_q[pending_tier_q] + 1'b1;

          out_valid <= 1'b1;
          out_tier <= pending_tier_q;
          out_op_type <= pending_op_type_q;
          out_he_data <= pending_in_data_q;
          out_he_priority <= pending_priority_q;
          state_q <= SUMMARY_UPDATE;
        end
        DEQ_SELECT_BUCKET: begin
          pending_bucket_q <= select_bucket_c;
          pending_priority_q <= select_priority_c;
          state_q <= DEQ_ISSUE_PB;
        end
        DEQ_ISSUE_PB: begin
          state_q <= DEQ_READ_PB;
        end
        DEQ_READ_PB: begin
          tail_ptr_v = pb_tail_rd_data;
          pending_tail_q <= tail_ptr_v;
          pending_prev_q <= prev_ptr[pending_tier_q][tail_ptr_v];
          pending_data_q <= entry_data[pending_tier_q][tail_ptr_v];
          state_q <= DEQ_COMMIT;
        end
        DEQ_COMMIT: begin
          if (pending_prev_q == INVALID_PTR) begin
            clear_bucket_if_empty(pending_tier_q, pending_group_q, pending_bucket_q);
          end else begin
            next_ptr[pending_tier_q][pending_prev_q] <= INVALID_PTR;
          end
          free_stack[pending_tier_q][free_count_q[pending_tier_q]] <= pending_tail_q;
          free_count_q[pending_tier_q] <= free_count_q[pending_tier_q] + 1'b1;
          occupancy_q[pending_tier_q] <= occupancy_q[pending_tier_q] - 1'b1;

          out_valid <= 1'b1;
          out_tier <= pending_tier_q;
          out_op_type <= pending_op_type_q;
          out_he_data <= pending_data_q;
          out_he_priority <= pending_priority_q;
          state_q <= SUMMARY_UPDATE;
        end
        default: state_q <= INIT_FILL_FREE;
      endcase
    end
  end
endmodule

module themis_bmsch_sync_ram #(
  parameter int DATA_WIDTH = 5,
  parameter int ADDR_WIDTH = 11,
  parameter int DEPTH = (1 << ADDR_WIDTH)
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
