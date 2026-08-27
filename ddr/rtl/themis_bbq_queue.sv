`timescale 1ns/1ps

import heap_ops::*;

module themis_bbq_queue #(
  parameter int PRIORITY_WIDTH = 10,
  parameter int DATA_WIDTH = 5,
  parameter int MAX_ENTRIES = 31,
  parameter int BITMAP_GROUP_WIDTH = 32,
  localparam int GROUP_BITS = $clog2(BITMAP_GROUP_WIDTH),
  localparam int NUM_PRIORITIES = (1 << PRIORITY_WIDTH),
  localparam int NUM_GROUPS = (NUM_PRIORITIES + BITMAP_GROUP_WIDTH - 1) / BITMAP_GROUP_WIDTH,
  localparam int GROUP_IDX_W = (NUM_GROUPS <= 2) ? 1 : $clog2(NUM_GROUPS),
  localparam int ENTRY_PTR_W = $clog2(MAX_ENTRIES + 1),
  localparam int INIT_LIMIT = (NUM_PRIORITIES > MAX_ENTRIES) ? NUM_PRIORITIES : MAX_ENTRIES,
  localparam int INIT_IDX_W = $clog2(INIT_LIMIT + 1)
) (
  input  logic                        clk,
  input  logic                        rst,
  output logic                        ready,

  input  logic                        in_valid,
  input  heap_op_t                    in_op_type,
  input  logic [DATA_WIDTH-1:0]       in_he_data,
  input  logic [PRIORITY_WIDTH-1:0]   in_he_priority,

  output logic                        out_valid,
  output heap_op_t                    out_op_type,
  output logic [DATA_WIDTH-1:0]       out_he_data,
  output logic [PRIORITY_WIDTH-1:0]   out_he_priority
);
  localparam logic [ENTRY_PTR_W-1:0] MAX_ENTRIES_PTR = MAX_ENTRIES;
  localparam logic [ENTRY_PTR_W-1:0] INVALID_PTR = MAX_ENTRIES_PTR;
  localparam logic [INIT_IDX_W-1:0] NUM_PRIORITIES_IDX = NUM_PRIORITIES;
  localparam logic [INIT_IDX_W-1:0] MAX_ENTRIES_IDX = MAX_ENTRIES;
  localparam logic [INIT_IDX_W-1:0] INIT_LAST_IDX = INIT_LIMIT - 1;

  typedef enum logic [2:0] {
    INIT_CLEAR,
    INIT_FILL_FREE,
    READY,
    DEQ_SELECT_BUCKET,
    DEQ_READ_HEAD,
    DEQ_READ_ENTRY,
    DEQ_COMMIT
  } state_t;

  state_t state_q;
  logic [INIT_IDX_W-1:0] init_idx_q;
  logic [ENTRY_PTR_W-1:0] free_stack [0:MAX_ENTRIES-1];
  logic [ENTRY_PTR_W-1:0] free_count_q;
  logic [ENTRY_PTR_W-1:0] occupancy_q;
  logic [ENTRY_PTR_W-1:0] bucket_head [0:NUM_PRIORITIES-1];
  logic [ENTRY_PTR_W-1:0] bucket_tail [0:NUM_PRIORITIES-1];
  logic [ENTRY_PTR_W-1:0] next_ptr [0:MAX_ENTRIES-1];
  logic [DATA_WIDTH-1:0] entry_data [0:MAX_ENTRIES-1];
  logic [NUM_GROUPS-1:0] l1_bitmap_q;
  logic [BITMAP_GROUP_WIDTH-1:0] l2_bitmap_q [0:NUM_GROUPS-1];
  heap_op_t pending_op_type_q;
  logic pending_deq_min_q;
  logic [GROUP_IDX_W-1:0] pending_group_q;
  logic [GROUP_BITS-1:0] pending_bucket_q;
  logic [PRIORITY_WIDTH-1:0] pending_priority_q;
  logic [ENTRY_PTR_W-1:0] pending_head_q;
  logic [ENTRY_PTR_W-1:0] pending_next_q;
  logic [DATA_WIDTH-1:0] pending_data_q;

  assign ready = (state_q == READY);

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

  integer rst_i;
  always_ff @(posedge clk) begin
    logic is_enqueue_v;
    logic is_dequeue_min_v;
    logic is_dequeue_max_v;
    logic [ENTRY_PTR_W-1:0] entry_ptr_v;
    logic [ENTRY_PTR_W-1:0] head_ptr_v;
    logic [ENTRY_PTR_W-1:0] next_ptr_v;
    logic [GROUP_IDX_W-1:0] group_idx_v;
    logic [GROUP_BITS-1:0] bucket_idx_v;
    logic [PRIORITY_WIDTH-1:0] priority_v;
    logic [BITMAP_GROUP_WIDTH-1:0] bucket_mask_v;

    out_valid <= 1'b0;
    out_op_type <= in_op_type;
    out_he_data <= '0;
    out_he_priority <= '0;

    if (rst) begin
      state_q <= INIT_CLEAR;
      init_idx_q <= '0;
      free_count_q <= '0;
      occupancy_q <= '0;
      l1_bitmap_q <= '0;
      pending_op_type_q <= HEAP_OP_DEQUE_MIN;
      pending_deq_min_q <= 1'b0;
      pending_group_q <= '0;
      pending_bucket_q <= '0;
      pending_priority_q <= '0;
      pending_head_q <= INVALID_PTR;
      pending_next_q <= INVALID_PTR;
      pending_data_q <= '0;
      for (rst_i = 0; rst_i < NUM_GROUPS; rst_i = rst_i + 1) begin
        l2_bitmap_q[rst_i] <= '0;
      end
    end else begin
      unique case (state_q)
        INIT_CLEAR: begin
          if (init_idx_q < NUM_PRIORITIES_IDX) begin
            bucket_head[init_idx_q[PRIORITY_WIDTH-1:0]] <= INVALID_PTR;
            bucket_tail[init_idx_q[PRIORITY_WIDTH-1:0]] <= INVALID_PTR;
          end
          if (init_idx_q == INIT_LAST_IDX) begin
            init_idx_q <= '0;
            state_q <= INIT_FILL_FREE;
          end else begin
            init_idx_q <= init_idx_q + 1'b1;
          end
        end
        INIT_FILL_FREE: begin
          if (init_idx_q < MAX_ENTRIES_IDX) begin
            free_stack[init_idx_q[ENTRY_PTR_W-1:0]] <= init_idx_q[ENTRY_PTR_W-1:0];
            next_ptr[init_idx_q[ENTRY_PTR_W-1:0]] <= INVALID_PTR;
            entry_data[init_idx_q[ENTRY_PTR_W-1:0]] <= '0;
          end
          if (init_idx_q == INIT_LAST_IDX) begin
            init_idx_q <= '0;
            free_count_q <= MAX_ENTRIES_PTR;
            state_q <= READY;
          end else begin
            init_idx_q <= init_idx_q + 1'b1;
          end
        end
        READY: begin
          if (in_valid) begin
            is_enqueue_v = (in_op_type == HEAP_OP_ENQUE) || (in_op_type == HEAP_OP_SWAP_IN);
            is_dequeue_min_v = (in_op_type == HEAP_OP_DEQUE_MIN);
            is_dequeue_max_v = (in_op_type == HEAP_OP_DEQUE_MAX) || (in_op_type == HEAP_OP_SWAP_OUT);

            if (is_enqueue_v && (free_count_q != '0)) begin
              entry_ptr_v = free_stack[free_count_q - 1'b1];
              priority_v = in_he_priority;
              group_idx_v = priority_v[PRIORITY_WIDTH-1:GROUP_BITS];
              bucket_idx_v = priority_v[GROUP_BITS-1:0];

              entry_data[entry_ptr_v] <= in_he_data;
              next_ptr[entry_ptr_v] <= INVALID_PTR;
              if (bucket_head[priority_v] == INVALID_PTR) begin
                bucket_head[priority_v] <= entry_ptr_v;
                bucket_tail[priority_v] <= entry_ptr_v;
                l2_bitmap_q[group_idx_v][bucket_idx_v] <= 1'b1;
                l1_bitmap_q[group_idx_v] <= 1'b1;
              end else begin
                next_ptr[bucket_tail[priority_v]] <= entry_ptr_v;
                bucket_tail[priority_v] <= entry_ptr_v;
              end

              free_count_q <= free_count_q - 1'b1;
              occupancy_q <= occupancy_q + 1'b1;
              out_valid <= 1'b1;
              out_op_type <= in_op_type;
              out_he_data <= in_he_data;
              out_he_priority <= in_he_priority;
            end else if ((is_dequeue_min_v || is_dequeue_max_v) && (occupancy_q != '0)) begin
              if (is_dequeue_min_v) begin
                pending_group_q <= find_lsb_group(l1_bitmap_q);
              end else begin
                pending_group_q <= find_msb_group(l1_bitmap_q);
              end
              pending_op_type_q <= in_op_type;
              pending_deq_min_q <= is_dequeue_min_v;
              state_q <= DEQ_SELECT_BUCKET;
            end
          end
        end
        DEQ_SELECT_BUCKET: begin
          if (pending_deq_min_q) begin
            pending_bucket_q <= find_lsb_bucket(l2_bitmap_q[pending_group_q]);
          end else begin
            pending_bucket_q <= find_msb_bucket(l2_bitmap_q[pending_group_q]);
          end
          state_q <= DEQ_READ_HEAD;
        end
        DEQ_READ_HEAD: begin
          priority_v = {pending_group_q, pending_bucket_q};
          pending_priority_q <= priority_v;
          pending_head_q <= bucket_head[priority_v];
          state_q <= DEQ_READ_ENTRY;
        end
        DEQ_READ_ENTRY: begin
          pending_next_q <= next_ptr[pending_head_q];
          pending_data_q <= entry_data[pending_head_q];
          state_q <= DEQ_COMMIT;
        end
        DEQ_COMMIT: begin
          priority_v = pending_priority_q;
          head_ptr_v = pending_head_q;
          next_ptr_v = pending_next_q;

          bucket_head[priority_v] <= next_ptr_v;
          if (next_ptr_v == INVALID_PTR) begin
            bucket_tail[priority_v] <= INVALID_PTR;
            l2_bitmap_q[pending_group_q][pending_bucket_q] <= 1'b0;
            bucket_mask_v = {{(BITMAP_GROUP_WIDTH-1){1'b0}}, 1'b1} << pending_bucket_q;
            if ((l2_bitmap_q[pending_group_q] & ~bucket_mask_v) == '0) begin
              l1_bitmap_q[pending_group_q] <= 1'b0;
            end
          end
          free_stack[free_count_q] <= head_ptr_v;
          free_count_q <= free_count_q + 1'b1;
          occupancy_q <= occupancy_q - 1'b1;
          out_valid <= 1'b1;
          out_op_type <= pending_op_type_q;
          out_he_data <= pending_data_q;
          out_he_priority <= priority_v;
          state_q <= READY;
        end
        default: state_q <= INIT_CLEAR;
      endcase
    end
  end
endmodule
