`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/15/2025 01:56:40 PM
// Design Name: 
// Module Name: bbq
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description:            
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


import heap_ops::*;
// `define DEBUG

/**
 * Implements an integer priority queue in hardware using a configurable
 * Hierarchical Find First Set (HFFS) Queue. The implementation is fully
 * pipelined, capable of performing one operation (enqueue, dequeue-*,
 * or peek) every cycle.
 */
module bbq #(
    parameter HEAP_BITMAP_WIDTH = 32,
    parameter HEAP_ENTRY_DWIDTH = 17,
    parameter HEAP_MAX_NUM_ENTRIES = ((1 << 17) - 1),
    parameter HEAP_CELL_BITS = 15,
    localparam HEAP_ENTRY_AWIDTH = ($clog2(HEAP_MAX_NUM_ENTRIES)),
    localparam HEAP_NUM_LEVELS = 2, // Number of bitmap tree levels
    localparam HEAP_NUM_PRIORITIES = (HEAP_BITMAP_WIDTH ** HEAP_NUM_LEVELS),
    localparam HEAP_PRIORITY_BUCKETS_AWIDTH = ($clog2(HEAP_NUM_PRIORITIES))
) (
    // General I/O
    input   logic                                       clk,
    input   logic                                       rst,
    input   logic                                       axi_clk,
    input   logic                                       hbm_ref,
    input   logic                                       apb_clk,
    input   logic                                       locked,
    output  logic                                       ready,

    // Operation input
    input   logic                                       in_valid,
    input   heap_op_t                                   in_op_type,
    input   logic [HEAP_ENTRY_DWIDTH-1:0]               in_he_data,
    input   logic [HEAP_PRIORITY_BUCKETS_AWIDTH-1:0]    in_he_priority,

    // Operation output
    output  logic                                       out_valid,
    output  heap_op_t                                   out_op_type,
    output  logic [HEAP_ENTRY_DWIDTH-1:0]               out_he_data,
    output  logic [HEAP_PRIORITY_BUCKETS_AWIDTH-1:0]    out_he_priority
);

// Optimization: Subtree occupancy counters (StOCs) must represent
// values in the range [0, HEAP_MAX_NUM_ENTRIES]. Consequently, to
// support 2^k entries, every StOC must be (k + 1)-bits wide; this
// is wasteful because the MSb is only ever used to encode maximum
// occupancy (2^k). Instead, by supporting one less entry (2^k - 1)
// we can reduce memory usage by using 1 fewer bit per StOC.
localparam ROUNDED_MAX_NUM_ENTRIES = (1 << HEAP_ENTRY_AWIDTH);
if (HEAP_MAX_NUM_ENTRIES != (ROUNDED_MAX_NUM_ENTRIES - 1)) begin
    $error("HEAP_MAX_NUM_ENTRIES must be of the form (2^k - 1)");
end

integer i;
integer j;

/**
 * Derived parameters.
 */
localparam NUM_PIPELINE_STAGES          = 11;

localparam NUM_BITMAPS_L1               = 1;
localparam NUM_BITMAPS_L2               = (HEAP_BITMAP_WIDTH ** 1);
localparam BITMAP_L2_AWIDTH             = ($clog2(NUM_BITMAPS_L2));

localparam NUM_COUNTERS_L1              = (NUM_BITMAPS_L2);
localparam NUM_COUNTERS_L2              = (HEAP_NUM_PRIORITIES);
localparam COUNTER_T_WIDTH              = (HEAP_ENTRY_AWIDTH + 1);
localparam COUNTER_L1_AWIDTH            = ($clog2(NUM_COUNTERS_L1));
localparam COUNTER_L2_AWIDTH            = ($clog2(NUM_COUNTERS_L2));

localparam WATERLEVEL_IDX               = (COUNTER_T_WIDTH - 1);
localparam LIST_T_WIDTH                 = (HEAP_ENTRY_AWIDTH * 2);
localparam BITMAP_IDX_MASK              = (HEAP_BITMAP_WIDTH - 1);
localparam HEAP_LOG_BITMAP_WIDTH        = ($clog2(HEAP_BITMAP_WIDTH));

/**
 * Local typedefs.
 */
typedef logic [COUNTER_T_WIDTH-1:0] counter_t;
typedef logic [HEAP_BITMAP_WIDTH-1:0] bitmap_t;
typedef logic [HEAP_ENTRY_AWIDTH-1:0] heap_entry_ptr_t;
typedef logic [HEAP_ENTRY_DWIDTH-1:0] heap_entry_data_t;
typedef logic [HEAP_PRIORITY_BUCKETS_AWIDTH-1:0] heap_priority_t;
typedef struct packed { heap_entry_ptr_t head; heap_entry_ptr_t tail; } list_t;

typedef enum logic [1:0] {
    FSM_STATE_IDLE,
    FSM_STATE_INIT,
    FSM_STATE_READY
} fsm_state_t;

typedef enum logic {
    OP_COLOR_BLUE,
    OP_COLOR_RED
} op_color_t;

typedef enum logic {
    HBM_OP_COLOR_BLUE,
    HBM_OP_COLOR_RED
} hbm_op_color_t;

typedef enum logic [1:0] {
    READ_CARRY_RIGHT,
    READ_CARRY_DOWN,
    READ_CARRY_UP
} read_carry_direction_t;

typedef enum logic [1:0] {
    HBM_READ_CARRY_RIGHT,
    HBM_READ_CARRY_DOWN,
    HBM_READ_CARRY_UP
} hbm_read_carry_direction_t;

// SRAM_Heap state
(* keep = "true" *)bitmap_t l1_bitmap; // L1 bitmap
(* keep = "true" *)bitmap_t l2_bitmaps[NUM_BITMAPS_L2-1:0]; // L2 bitmaps
(* keep = "true" *)counter_t l1_counters[NUM_COUNTERS_L1-1:0]; // L1 counters

// Free list
(* keep = "true" *)logic fl_empty;
(* keep = "true" *)logic fl_rdreq;
(* keep = "true" *)logic fl_wrreq;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] fl_q;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] fl_data;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] fl_q_r[7:0];
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] fl_wraddress_counter_r;

// Heap entries
(* keep = "true" *)logic he_rden;
(* keep = "true" *)logic he_wren;
(* keep = "true" *)logic he_rden_r;
(* keep = "true" *)logic he_wren_r;
(* keep = "true" *)logic [HEAP_ENTRY_DWIDTH-1:0] he_q;
(* keep = "true" *)logic [HEAP_ENTRY_DWIDTH-1:0] he_data;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] he_rdaddress;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] he_wraddress;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] he_rdaddress_r;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] he_wraddress_r;

// Next pointers
(* keep = "true" *)logic np_rden;
(* keep = "true" *)logic np_wren;
(* keep = "true" *)logic np_rden_r;
(* keep = "true" *)logic np_wren_r;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] np_q;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] np_data;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] np_rdaddress;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] np_wraddress;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] np_rdaddress_r;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] np_wraddress_r;

// Previous pointers
(* keep = "true" *)logic pp_rden;
(* keep = "true" *)logic pp_wren;
(* keep = "true" *)logic pp_rden_r;
(* keep = "true" *)logic pp_wren_r;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] pp_q;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] pp_data;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] pp_rdaddress;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] pp_wraddress;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] pp_rdaddress_r;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] pp_wraddress_r;

// Priority buckets
(* keep = "true" *)logic pb_rden;
(* keep = "true" *)logic pb_wren;
(* keep = "true" *)logic pb_rdwr_conflict;
(* keep = "true" *)logic reg_pb_rdwr_conflict_r1;
(* keep = "true" *)logic reg_pb_rdwr_conflict_r2;
(* keep = "true" *)logic [LIST_T_WIDTH-1:0] pb_q;
(* keep = "true" *)logic [LIST_T_WIDTH-1:0] pb_q_r;
(* keep = "true" *)logic [LIST_T_WIDTH-1:0] pb_data;
(* keep = "true" *)logic [HEAP_PRIORITY_BUCKETS_AWIDTH-1:0] pb_rdaddress;
(* keep = "true" *)logic [HEAP_PRIORITY_BUCKETS_AWIDTH-1:0] pb_wraddress;

// L2 counters
(* keep = "true" *)logic counter_l2_rden;
(* keep = "true" *)logic counter_l2_wren;
(* keep = "true" *)logic [COUNTER_T_WIDTH-1:0] counter_l2_q;
(* keep = "true" *)logic [COUNTER_T_WIDTH-1:0] counter_l2_data;
(* keep = "true" *)logic [COUNTER_L2_AWIDTH-1:0] counter_l2_rdaddress;
(* keep = "true" *)logic [COUNTER_L2_AWIDTH-1:0] counter_l2_wraddress;
(* keep = "true" *)logic [COUNTER_L2_AWIDTH-1:0] counter_l2_wraddress_counter_r;

// Heap occupancy
(* keep = "true" *)counter_t occupancy;

// HBM_Heap state
(* keep = "true" *)bitmap_t hbm_l1_bitmap; // L1 bitmap
(* keep = "true" *)bitmap_t hbm_l2_bitmaps[NUM_BITMAPS_L2-1:0]; // L2 bitmaps
(* keep = "true" *)counter_t hbm_l1_counters[NUM_COUNTERS_L1-1:0]; // L1 counters

// Free list
(* keep = "true" *)logic hbm_fl_empty;
(* keep = "true" *)logic hbm_fl_rdreq;
(* keep = "true" *)logic hbm_fl_wrreq;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] hbm_fl_q;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] hbm_fl_data;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] hbm_fl_q_r[7:0];
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] hbm_fl_wraddress_counter_r;

// Heap entries
(* keep = "true" *)logic hbm_he_rden;
(* keep = "true" *)logic hbm_he_wren;
(* keep = "true" *)logic hbm_he_rden_r;
(* keep = "true" *)logic hbm_he_wren_r;
(* keep = "true" *)logic [HEAP_ENTRY_DWIDTH-1:0] hbm_he_q;
(* keep = "true" *)logic [HEAP_ENTRY_DWIDTH-1:0] hbm_he_data;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] hbm_he_rdaddress;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] hbm_he_wraddress;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] hbm_he_rdaddress_r;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] hbm_he_wraddress_r;

// Next pointers
(* keep = "true" *)logic hbm_np_rden;
(* keep = "true" *)logic hbm_np_wren;
(* keep = "true" *)logic hbm_np_rden_r;
(* keep = "true" *)logic hbm_np_wren_r;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] hbm_np_q;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] hbm_np_data;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] hbm_np_rdaddress;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] hbm_np_wraddress;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] hbm_np_rdaddress_r;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] hbm_np_wraddress_r;

// Previous pointers
(* keep = "true" *)logic hbm_pp_rden;
(* keep = "true" *)logic hbm_pp_wren;
(* keep = "true" *)logic hbm_pp_rden_r;
(* keep = "true" *)logic hbm_pp_wren_r;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] hbm_pp_q;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] hbm_pp_data;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] hbm_pp_rdaddress;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] hbm_pp_wraddress;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] hbm_pp_rdaddress_r;
(* keep = "true" *)logic [HEAP_ENTRY_AWIDTH-1:0] hbm_pp_wraddress_r;

// Priority buckets
(* keep = "true" *)logic hbm_pb_rden;
(* keep = "true" *)logic hbm_pb_wren;
(* keep = "true" *)logic hbm_pb_rdwr_conflict;
(* keep = "true" *)logic hbm_reg_pb_rdwr_conflict_r1;
(* keep = "true" *)logic hbm_reg_pb_rdwr_conflict_r2;
(* keep = "true" *)logic [LIST_T_WIDTH-1:0] hbm_pb_q;
(* keep = "true" *)logic [LIST_T_WIDTH-1:0] hbm_pb_q_r;
(* keep = "true" *)logic [LIST_T_WIDTH-1:0] hbm_pb_data;
(* keep = "true" *)logic [HEAP_PRIORITY_BUCKETS_AWIDTH-1:0] hbm_pb_rdaddress;
(* keep = "true" *)logic [HEAP_PRIORITY_BUCKETS_AWIDTH-1:0] hbm_pb_wraddress;

// L2 counters
(* keep = "true" *)logic hbm_counter_l2_rden;
(* keep = "true" *)logic hbm_counter_l2_wren;
(* keep = "true" *)logic [COUNTER_T_WIDTH-1:0] hbm_counter_l2_q;
(* keep = "true" *)logic [COUNTER_T_WIDTH-1:0] hbm_counter_l2_data;
(* keep = "true" *)logic [COUNTER_L2_AWIDTH-1:0] hbm_counter_l2_rdaddress;
(* keep = "true" *)logic [COUNTER_L2_AWIDTH-1:0] hbm_counter_l2_wraddress;
(* keep = "true" *)logic [COUNTER_L2_AWIDTH-1:0] hbm_counter_l2_wraddress_counter_r;

// Heap occupancy
(* keep = "true" *)counter_t hbm_occupancy;

/**
 * Housekeeping.
 */
// Common pipeline metadata
(* keep = "true" *)logic                                   reg_valid_s[NUM_PIPELINE_STAGES:0];
(* keep = "true" *)heap_op_t                               reg_op_type_s[NUM_PIPELINE_STAGES:0];
(* keep = "true" *)heap_entry_data_t                       reg_he_data_s[NUM_PIPELINE_STAGES:0];
(* keep = "true" *)logic [BITMAP_L2_AWIDTH-1:0]            reg_l2_addr_s[NUM_PIPELINE_STAGES:0];
(* keep = "true" *)op_color_t                              reg_op_color_s[NUM_PIPELINE_STAGES:0];
(* keep = "true" *)logic                                   reg_is_enque_s[NUM_PIPELINE_STAGES:0];
(* keep = "true" *)heap_priority_t                         reg_priority_s[NUM_PIPELINE_STAGES:0];
(* keep = "true" *)bitmap_t                                reg_l2_bitmap_s[NUM_PIPELINE_STAGES:0];
(* keep = "true" *)logic                                   reg_is_deque_min_s[NUM_PIPELINE_STAGES:0];
(* keep = "true" *)logic                                   reg_is_deque_max_s[NUM_PIPELINE_STAGES:0];
(* keep = "true" *)logic                                   reg_is_swap_in[NUM_PIPELINE_STAGES:0];
(* keep = "true" *)logic                                   reg_is_swap_out[NUM_PIPELINE_STAGES:0];

// Stage 1 metadata
(* keep = "true" *)logic                                   valid_s1;
(* keep = "true" *)counter_t                               old_occupancy_s1;
(* keep = "true" *)counter_t                               new_occupancy_s1;
(* keep = "true" *)counter_t                               reg_old_occupancy_s1;
(* keep = "true" *)counter_t                               reg_new_occupancy_s1;

// Stage 2 metadata
(* keep = "true" *)read_carry_direction_t                  rcd_s2;
(* keep = "true" *)logic [HEAP_LOG_BITMAP_WIDTH-1:0]       l1_bitmap_idx_s2;
(* keep = "true" *)logic                                   l1_bitmap_empty_s2; 
(* keep = "true" *)bitmap_t                                l1_bitmap_postop_s2;
(* keep = "true" *)bitmap_t                                l1_bitmap_idx_onehot_s2;
(* keep = "true" *)logic                                   l1_bitmap_changes_s3_s2;
(* keep = "true" *)counter_t                               reg_l1_counter_s2;
(* keep = "true" *)logic [HEAP_LOG_BITMAP_WIDTH-1:0]       reg_l1_bitmap_idx_s2;
(* keep = "true" *)logic                                   reg_l1_bitmap_empty_s2;
(* keep = "true" *)bitmap_t                                reg_l1_bitmap_postop_s2;
(* keep = "true" *)bitmap_t                                reg_l1_bitmap_idx_onehot_s2;

// Stage 3 metadata
(* keep = "true" *)bitmap_t                                l1_bitmap_s3;
(* keep = "true" *)counter_t                               l1_counter_s3;
(* keep = "true" *)logic                                   l1_counter_non_zero_s3;
(* keep = "true" *)logic                                   l2_addr_conflict_s4_s3;
(* keep = "true" *)logic                                   l2_addr_conflict_s5_s3;
(* keep = "true" *)logic                                   l2_addr_conflict_s6_s3;
(* keep = "true" *)logic                                   l2_addr_conflict_s7_s3;
(* keep = "true" *)counter_t                               reg_l1_counter_s3;
(* keep = "true" *)logic                                   reg_l2_addr_conflict_s4_s3;
(* keep = "true" *)logic                                   reg_l2_addr_conflict_s5_s3;
(* keep = "true" *)logic                                   reg_l2_addr_conflict_s6_s3;
(* keep = "true" *)logic                                   reg_l2_addr_conflict_s7_s3;

// Stage 4 metadata
(* keep = "true" *)read_carry_direction_t                  rcd_s4;
(* keep = "true" *)logic [HEAP_LOG_BITMAP_WIDTH-1:0]       l2_bitmap_idx_s4;
(* keep = "true" *)logic                                   l2_bitmap_empty_s4;
(* keep = "true" *)bitmap_t                                l2_bitmap_postop_s4;
(* keep = "true" *)bitmap_t                                l2_bitmap_idx_onehot_s4;
(* keep = "true" *)logic                                   l2_bitmap_changes_s6_s4;
(* keep = "true" *)logic [HEAP_LOG_BITMAP_WIDTH-1:0]       reg_l2_bitmap_idx_s4;
(* keep = "true" *)logic                                   reg_l2_bitmap_empty_s4;
(* keep = "true" *)bitmap_t                                reg_l2_bitmap_postop_s4;
(* keep = "true" *)bitmap_t                                reg_l2_bitmap_idx_onehot_s4;
(* keep = "true" *)logic                                   reg_l2_counter_rdvalid_r1_s4;
(* keep = "true" *)logic                                   reg_l2_addr_conflict_s5_s4;
(* keep = "true" *)logic                                   reg_l2_addr_conflict_s6_s4;
(* keep = "true" *)logic                                   reg_l2_addr_conflict_s7_s4;
(* keep = "true" *)logic                                   reg_l2_addr_conflict_s8_s4;

// Stage 5 metadata
(* keep = "true" *)read_carry_direction_t                  rcd_s5;
(* keep = "true" *)counter_t                               l2_counter_s5;
(* keep = "true" *)counter_t                               l2_counter_q_s5;
(* keep = "true" *)counter_t                               reg_l2_counter_s5;
(* keep = "true" *)counter_t                               reg_l2_counter_rc_s5;
(* keep = "true" *)logic [HEAP_LOG_BITMAP_WIDTH-1:0]       reg_l2_bitmap_idx_s5;
(* keep = "true" *)bitmap_t                                reg_l2_bitmap_postop_s5;
(* keep = "true" *)bitmap_t                                reg_l2_bitmap_idx_onehot_s5;
(* keep = "true" *)logic                                   reg_l2_addr_conflict_s6_s5;
(* keep = "true" *)logic                                   reg_l2_addr_conflict_s7_s5;
(* keep = "true" *)logic                                   reg_l2_addr_conflict_s8_s5;
(* keep = "true" *)logic                                   reg_l2_addr_conflict_s9_s5;

// Stage 6 metadata
(* keep = "true" *)heap_priority_t                         priority_s6;
(* keep = "true" *)bitmap_t                                l2_bitmap_s6;
(* keep = "true" *)counter_t                               l2_counter_s6;
(* keep = "true" *)logic                                   l2_counter_non_zero_s6;
(* keep = "true" *)logic                                   pb_addr_conflict_s7_s6;
(* keep = "true" *)logic                                   pb_addr_conflict_s8_s6;
(* keep = "true" *)logic                                   pb_addr_conflict_s9_s6;
(* keep = "true" *)logic                                   pb_addr_conflict_s10_s6;
(* keep = "true" *)counter_t                               reg_l2_counter_s6;
(* keep = "true" *)logic [HEAP_LOG_BITMAP_WIDTH-1:0]       reg_l2_bitmap_idx_s6;
(* keep = "true" *)counter_t                               reg_old_l2_counter_s6;
(* keep = "true" *)logic                                   reg_l2_counter_non_zero_s6;
(* keep = "true" *)logic                                   reg_pb_addr_conflict_s7_s6;
(* keep = "true" *)logic                                   reg_pb_addr_conflict_s8_s6;
(* keep = "true" *)logic                                   reg_pb_addr_conflict_s9_s6;
(* keep = "true" *)logic                                   reg_pb_addr_conflict_s10_s6;

// Stage 7 metadata
(* keep = "true" *)op_color_t                              op_color_s7;
(* keep = "true" *)logic                                   reg_pb_update_s7;
(* keep = "true" *)logic                                   reg_pb_data_conflict_s7;
(* keep = "true" *)logic                                   reg_pb_state_changes_s7;
(* keep = "true" *)logic                                   reg_pb_tail_pp_changes_s7;
(* keep = "true" *)logic                                   reg_pb_addr_conflict_s8_s7;
(* keep = "true" *)logic                                   reg_pb_addr_conflict_s9_s7;

// Stage 8 metadata
(* keep = "true" *)logic                                   pp_changes_s9_s8;
(* keep = "true" *)logic                                   pp_changes_s10_s8;
(* keep = "true" *)list_t                                  reg_pb_q_s8;
(* keep = "true" *)heap_entry_ptr_t                        reg_pp_data_s8;
(* keep = "true" *)logic                                   reg_pp_data_valid_s8;
(* keep = "true" *)logic                                   reg_pb_data_conflict_s8;
(* keep = "true" *)logic                                   reg_pb_state_changes_s8;
(* keep = "true" *)logic                                   reg_pb_tail_pp_changes_s8;
(* keep = "true" *)logic                                   reg_pb_addr_conflict_s9_s8;
(* keep = "true" *)logic                                   reg_pb_addr_conflict_s10_s8;

// Stage 9 metadata
(* keep = "true" *)heap_entry_data_t                       he_q_s9;
(* keep = "true" *)heap_entry_ptr_t                        np_q_s9;
(* keep = "true" *)heap_entry_ptr_t                        pp_q_s9;
(* keep = "true" *)heap_entry_data_t                       reg_he_q_s9;
(* keep = "true" *)heap_entry_ptr_t                        reg_np_q_s9;
(* keep = "true" *)heap_entry_ptr_t                        reg_pp_q_s9;
(* keep = "true" *)list_t                                  reg_pb_q_s9;
(* keep = "true" *)list_t                                  reg_pb_new_s9;
(* keep = "true" *)logic                                   reg_pb_data_conflict_s9;
(* keep = "true" *)logic                                   reg_pb_state_changes_s9;
(* keep = "true" *)logic                                   reg_pb_tail_pp_changes_s9;

// Stage 10 metadata
(* keep = "true" *)heap_entry_data_t                       he_data_s10;
(* keep = "true" *)heap_entry_data_t                       reg_he_data_s10;
(* keep = "true" *)heap_entry_ptr_t                        reg_np_data_s10;
(* keep = "true" *)heap_entry_ptr_t                        reg_pp_data_s10;
(* keep = "true" *)list_t                                  reg_pb_data_s10;

// Stage 11 metadata
(* keep = "true" *)list_t                                  reg_pb_data_s11;

// Init signals
(* keep = "true" *)fsm_state_t                             state = FSM_STATE_IDLE;
(* keep = "true" *)logic                                   counter_l2_init_done_r;
(* keep = "true" *)logic                                   fl_init_done_r;
(* keep = "true" *)logic                                   counter_l2_init_done;
(* keep = "true" *)logic                                   fl_init_done;
(* keep = "true" *)fsm_state_t                             state_next;

// Intermediate signals
(* keep = "true" *)list_t                                  int_pb_data;
(* keep = "true" *)list_t                                  int_pb_q;

// Miscellaneous signals
(* keep = "true" *)logic [HEAP_LOG_BITMAP_WIDTH-1:0]       ffs_l1_inst_msb[1:0];
(* keep = "true" *)logic [HEAP_LOG_BITMAP_WIDTH-1:0]       ffs_l1_inst_lsb[1:0];
(* keep = "true" *)logic                                   ffs_l1_inst_zero[1:0];
(* keep = "true" *)bitmap_t                                ffs_l1_inst_msb_onehot[1:0];
(* keep = "true" *)bitmap_t                                ffs_l1_inst_lsb_onehot[1:0];

(* keep = "true" *)logic [HEAP_LOG_BITMAP_WIDTH-1:0]       ffs_l2_inst_msb[2:0];
(* keep = "true" *)logic [HEAP_LOG_BITMAP_WIDTH-1:0]       ffs_l2_inst_lsb[2:0];
(* keep = "true" *)logic                                   ffs_l2_inst_zero[2:0];
(* keep = "true" *)bitmap_t                                ffs_l2_inst_msb_onehot[2:0];
(* keep = "true" *)bitmap_t                                ffs_l2_inst_lsb_onehot[2:0];

// Common pipeline metadata
(* keep = "true" *)logic                                   hbm_reg_valid_s[NUM_PIPELINE_STAGES:0];
(* keep = "true" *)heap_op_t                               hbm_reg_op_type_s[NUM_PIPELINE_STAGES:0];
(* keep = "true" *)heap_entry_data_t                       hbm_reg_he_data_s[NUM_PIPELINE_STAGES:0];
(* keep = "true" *)logic [BITMAP_L2_AWIDTH-1:0]            hbm_reg_l2_addr_s[NUM_PIPELINE_STAGES:0];
(* keep = "true" *)hbm_op_color_t                              hbm_reg_op_color_s[NUM_PIPELINE_STAGES:0];
(* keep = "true" *)logic                                   hbm_reg_is_enque_s[NUM_PIPELINE_STAGES:0];
(* keep = "true" *)heap_priority_t                         hbm_reg_priority_s[NUM_PIPELINE_STAGES:0];
(* keep = "true" *)bitmap_t                                hbm_reg_l2_bitmap_s[NUM_PIPELINE_STAGES:0];
(* keep = "true" *)logic                                   hbm_reg_is_deque_min_s[NUM_PIPELINE_STAGES:0];
(* keep = "true" *)logic                                   hbm_reg_is_deque_max_s[NUM_PIPELINE_STAGES:0];

// Stage 1 metadata
(* keep = "true" *)logic                                   hbm_valid_s1;
(* keep = "true" *)counter_t                               hbm_old_occupancy_s1;
(* keep = "true" *)counter_t                               hbm_new_occupancy_s1;
(* keep = "true" *)counter_t                               hbm_reg_old_occupancy_s1;
(* keep = "true" *)counter_t                               hbm_reg_new_occupancy_s1;

// Stage 2 metadata
(* keep = "true" *)hbm_read_carry_direction_t                  hbm_rcd_s2;
(* keep = "true" *)logic [HEAP_LOG_BITMAP_WIDTH-1:0]       hbm_l1_bitmap_idx_s2;
(* keep = "true" *)logic                                   hbm_l1_bitmap_empty_s2; 
(* keep = "true" *)bitmap_t                                hbm_l1_bitmap_postop_s2;
(* keep = "true" *)bitmap_t                                hbm_l1_bitmap_idx_onehot_s2;
(* keep = "true" *)logic                                   hbm_l1_bitmap_changes_s3_s2;
(* keep = "true" *)counter_t                               hbm_reg_l1_counter_s2;
(* keep = "true" *)logic [HEAP_LOG_BITMAP_WIDTH-1:0]       hbm_reg_l1_bitmap_idx_s2;
(* keep = "true" *)logic                                   hbm_reg_l1_bitmap_empty_s2;
(* keep = "true" *)bitmap_t                                hbm_reg_l1_bitmap_postop_s2;
(* keep = "true" *)bitmap_t                                hbm_reg_l1_bitmap_idx_onehot_s2;

// Stage 3 metadata
(* keep = "true" *)bitmap_t                                hbm_l1_bitmap_s3;
(* keep = "true" *)counter_t                               hbm_l1_counter_s3;
(* keep = "true" *)logic                                   hbm_l1_counter_non_zero_s3;
(* keep = "true" *)logic                                   hbm_l2_addr_conflict_s4_s3;
(* keep = "true" *)logic                                   hbm_l2_addr_conflict_s5_s3;
(* keep = "true" *)logic                                   hbm_l2_addr_conflict_s6_s3;
(* keep = "true" *)logic                                   hbm_l2_addr_conflict_s7_s3;
(* keep = "true" *)counter_t                               hbm_reg_l1_counter_s3;
(* keep = "true" *)logic                                   hbm_reg_l2_addr_conflict_s4_s3;
(* keep = "true" *)logic                                   hbm_reg_l2_addr_conflict_s5_s3;
(* keep = "true" *)logic                                   hbm_reg_l2_addr_conflict_s6_s3;
(* keep = "true" *)logic                                   hbm_reg_l2_addr_conflict_s7_s3;

// Stage 4 metadata
(* keep = "true" *)hbm_read_carry_direction_t                  hbm_rcd_s4;
(* keep = "true" *)logic [HEAP_LOG_BITMAP_WIDTH-1:0]       hbm_l2_bitmap_idx_s4;
(* keep = "true" *)logic                                   hbm_l2_bitmap_empty_s4;
(* keep = "true" *)bitmap_t                                hbm_l2_bitmap_postop_s4;
(* keep = "true" *)bitmap_t                                hbm_l2_bitmap_idx_onehot_s4;
(* keep = "true" *)logic                                   hbm_l2_bitmap_changes_s6_s4;
(* keep = "true" *)logic [HEAP_LOG_BITMAP_WIDTH-1:0]       hbm_reg_l2_bitmap_idx_s4;
(* keep = "true" *)logic                                   hbm_reg_l2_bitmap_empty_s4;
(* keep = "true" *)bitmap_t                                hbm_reg_l2_bitmap_postop_s4;
(* keep = "true" *)bitmap_t                                hbm_reg_l2_bitmap_idx_onehot_s4;
(* keep = "true" *)logic                                   hbm_reg_l2_counter_rdvalid_r1_s4;
(* keep = "true" *)logic                                   hbm_reg_l2_addr_conflict_s5_s4;
(* keep = "true" *)logic                                   hbm_reg_l2_addr_conflict_s6_s4;
(* keep = "true" *)logic                                   hbm_reg_l2_addr_conflict_s7_s4;
(* keep = "true" *)logic                                   hbm_reg_l2_addr_conflict_s8_s4;

// Stage 5 metadata
(* keep = "true" *)hbm_read_carry_direction_t              hbm_rcd_s5;
(* keep = "true" *)counter_t                               hbm_l2_counter_s5;
(* keep = "true" *)counter_t                               hbm_l2_counter_q_s5;
(* keep = "true" *)counter_t                               hbm_reg_l2_counter_s5;
(* keep = "true" *)counter_t                               hbm_reg_l2_counter_rc_s5;
(* keep = "true" *)logic [HEAP_LOG_BITMAP_WIDTH-1:0]       hbm_reg_l2_bitmap_idx_s5;
(* keep = "true" *)bitmap_t                                hbm_reg_l2_bitmap_postop_s5;
(* keep = "true" *)bitmap_t                                hbm_reg_l2_bitmap_idx_onehot_s5;
(* keep = "true" *)logic                                   hbm_reg_l2_addr_conflict_s6_s5;
(* keep = "true" *)logic                                   hbm_reg_l2_addr_conflict_s7_s5;
(* keep = "true" *)logic                                   hbm_reg_l2_addr_conflict_s8_s5;
(* keep = "true" *)logic                                   hbm_reg_l2_addr_conflict_s9_s5;

// Stage 6 metadata
(* keep = "true" *)heap_priority_t                         hbm_priority_s6;
(* keep = "true" *)bitmap_t                                hbm_l2_bitmap_s6;
(* keep = "true" *)counter_t                               hbm_l2_counter_s6;
(* keep = "true" *)logic                                   hbm_l2_counter_non_zero_s6;
(* keep = "true" *)logic                                   hbm_pb_addr_conflict_s7_s6;
(* keep = "true" *)logic                                   hbm_pb_addr_conflict_s8_s6;
(* keep = "true" *)logic                                   hbm_pb_addr_conflict_s9_s6;
(* keep = "true" *)logic                                   hbm_pb_addr_conflict_s10_s6;
(* keep = "true" *)counter_t                               hbm_reg_l2_counter_s6;
(* keep = "true" *)logic [HEAP_LOG_BITMAP_WIDTH-1:0]       hbm_reg_l2_bitmap_idx_s6;
(* keep = "true" *)counter_t                               hbm_reg_old_l2_counter_s6;
(* keep = "true" *)logic                                   hbm_reg_l2_counter_non_zero_s6;
(* keep = "true" *)logic                                   hbm_reg_pb_addr_conflict_s7_s6;
(* keep = "true" *)logic                                   hbm_reg_pb_addr_conflict_s8_s6;
(* keep = "true" *)logic                                   hbm_reg_pb_addr_conflict_s9_s6;
(* keep = "true" *)logic                                   hbm_reg_pb_addr_conflict_s10_s6;

// Stage 7 metadata
(* keep = "true" *)hbm_op_color_t                              hbm_op_color_s7;
(* keep = "true" *)logic                                   hbm_reg_pb_update_s7;
(* keep = "true" *)logic                                   hbm_reg_pb_data_conflict_s7;
(* keep = "true" *)logic                                   hbm_reg_pb_state_changes_s7;
(* keep = "true" *)logic                                   hbm_reg_pb_tail_pp_changes_s7;
(* keep = "true" *)logic                                   hbm_reg_pb_addr_conflict_s8_s7;
(* keep = "true" *)logic                                   hbm_reg_pb_addr_conflict_s9_s7;

// Stage 8 metadata
(* keep = "true" *)logic                                   hbm_pp_changes_s9_s8;
(* keep = "true" *)logic                                   hbm_pp_changes_s10_s8;
(* keep = "true" *)list_t                                  hbm_reg_pb_q_s8;
(* keep = "true" *)heap_entry_ptr_t                        hbm_reg_pp_data_s8;
(* keep = "true" *)logic                                   hbm_reg_pp_data_valid_s8;
(* keep = "true" *)logic                                   hbm_reg_pb_data_conflict_s8;
(* keep = "true" *)logic                                   hbm_reg_pb_state_changes_s8;
(* keep = "true" *)logic                                   hbm_reg_pb_tail_pp_changes_s8;
(* keep = "true" *)logic                                   hbm_reg_pb_addr_conflict_s9_s8;
(* keep = "true" *)logic                                   hbm_reg_pb_addr_conflict_s10_s8;

// Stage 9 metadata
(* keep = "true" *)heap_entry_data_t                       hbm_he_q_s9;
(* keep = "true" *)heap_entry_ptr_t                        hbm_np_q_s9;
(* keep = "true" *)heap_entry_ptr_t                        hbm_pp_q_s9;
(* keep = "true" *)heap_entry_data_t                       hbm_reg_he_q_s9;
(* keep = "true" *)heap_entry_ptr_t                        hbm_reg_np_q_s9;
(* keep = "true" *)heap_entry_ptr_t                        hbm_reg_pp_q_s9;
(* keep = "true" *)list_t                                  hbm_reg_pb_q_s9;
(* keep = "true" *)list_t                                  hbm_reg_pb_new_s9;
(* keep = "true" *)logic                                   hbm_reg_pb_data_conflict_s9;
(* keep = "true" *)logic                                   hbm_reg_pb_state_changes_s9;
(* keep = "true" *)logic                                   hbm_reg_pb_tail_pp_changes_s9;

// Stage 10 metadata
(* keep = "true" *)heap_entry_data_t                       hbm_he_data_s10;
(* keep = "true" *)heap_entry_data_t                       hbm_reg_he_data_s10;
(* keep = "true" *)heap_entry_ptr_t                        hbm_reg_np_data_s10;
(* keep = "true" *)heap_entry_ptr_t                        hbm_reg_pp_data_s10;
(* keep = "true" *)list_t                                  hbm_reg_pb_data_s10;

// Stage 11 metadata
(* keep = "true" *)list_t                                  hbm_reg_pb_data_s11;

// Init signals
(* keep = "true" *)logic                                   hbm_counter_l2_init_done_r;
(* keep = "true" *)logic                                   hbm_fl_init_done_r;
(* keep = "true" *)logic                                   hbm_counter_l2_init_done;
(* keep = "true" *)logic                                   hbm_fl_init_done;

// Intermediate signals
(* keep = "true" *)list_t                                  hbm_int_pb_data;
(* keep = "true" *)list_t                                  hbm_int_pb_q;

// Miscellaneous signals
(* keep = "true" *)logic [HEAP_LOG_BITMAP_WIDTH-1:0]       hbm_ffs_l1_inst_msb[1:0];
(* keep = "true" *)logic [HEAP_LOG_BITMAP_WIDTH-1:0]       hbm_ffs_l1_inst_lsb[1:0];
(* keep = "true" *)logic                                   hbm_ffs_l1_inst_zero[1:0];
(* keep = "true" *)bitmap_t                                hbm_ffs_l1_inst_msb_onehot[1:0];
(* keep = "true" *)bitmap_t                                hbm_ffs_l1_inst_lsb_onehot[1:0];

(* keep = "true" *)logic [HEAP_LOG_BITMAP_WIDTH-1:0]       hbm_ffs_l2_inst_msb[2:0];
(* keep = "true" *)logic [HEAP_LOG_BITMAP_WIDTH-1:0]       hbm_ffs_l2_inst_lsb[2:0];
(* keep = "true" *)logic                                   hbm_ffs_l2_inst_zero[2:0];
(* keep = "true" *)bitmap_t                                hbm_ffs_l2_inst_msb_onehot[2:0];
(* keep = "true" *)bitmap_t                                hbm_ffs_l2_inst_lsb_onehot[2:0];

`ifdef DEBUG
logic                                   debug_newline;
`endif

assign pb_data = int_pb_data;

// Output assignments
assign ready = !rst & (state== FSM_STATE_READY);
assign out_valid = hbm_reg_valid_s[NUM_PIPELINE_STAGES-1];  //TODO
assign out_op_type = hbm_reg_op_type_s[NUM_PIPELINE_STAGES-1];  //TODO
assign out_he_data = hbm_reg_he_data_s[NUM_PIPELINE_STAGES-1];  //TODO
assign out_he_priority = hbm_reg_priority_s[NUM_PIPELINE_STAGES-1];     //TODO

/**
 * State-dependent signals (data, wraddress, and wren) for the
 * FL, priority buckets and SRAM-based LX bitmaps and counters for SRAM or HBM.
 */
 
always_comb begin
    state_next = state;
    fl_init_done = fl_init_done_r;
    counter_l2_init_done = counter_l2_init_done_r;
    
    hbm_fl_init_done = hbm_fl_init_done_r;
    hbm_counter_l2_init_done = hbm_counter_l2_init_done_r;
    
    fl_wrreq = 0;
    counter_l2_wren = 0;

    hbm_fl_wrreq = 0;
    hbm_counter_l2_wren = 0;
    
    // Initialization state
    if (state == FSM_STATE_INIT) begin
        // SRAM BM
        // Free list
        fl_data = fl_wraddress_counter_r;
        if (!fl_init_done_r) begin
            fl_wrreq = 1;
            fl_init_done = (fl_wraddress_counter_r ==
                            (HEAP_MAX_NUM_ENTRIES - 1));
        end
        // L2 counters
        counter_l2_data = 0;
        counter_l2_wraddress = counter_l2_wraddress_counter_r;
        if (!counter_l2_init_done_r) begin
            counter_l2_wren = 1;
            counter_l2_init_done = (counter_l2_wraddress_counter_r ==
                                    (NUM_COUNTERS_L2 - 1));
        end

        // HBM BM
        // TODO
        hbm_fl_data = hbm_fl_wraddress_counter_r;
        if (!hbm_fl_init_done_r) begin
            hbm_fl_wrreq = 1;
            hbm_fl_init_done = (hbm_fl_wraddress_counter_r ==
                            (HEAP_MAX_NUM_ENTRIES - 1));
        end
        // L2 counters
        hbm_counter_l2_data = 0;
        hbm_counter_l2_wraddress = hbm_counter_l2_wraddress_counter_r;
        if (!hbm_counter_l2_init_done_r) begin
            hbm_counter_l2_wren = 1;
            hbm_counter_l2_init_done = (hbm_counter_l2_wraddress_counter_r ==
                                    (NUM_COUNTERS_L2 - 1));
        end
        // Finished initializing the queue (including priority buckets,
        // free list, and the LX bitmaps). Proceed to the ready state.
        if (hbm_counter_l2_init_done_r & hbm_fl_init_done_r & fl_init_done_r & counter_l2_init_done_r) begin
            state_next = FSM_STATE_READY;
        end
    end
    else begin
        /**
         * Stage 10: Perform writes: update the priority bucket,
         * the free list, heap entries, next and prev pointers.
         */
        fl_data = (
            (reg_op_color_s[9] == OP_COLOR_BLUE) ?
            reg_pb_q_s9.head : reg_pb_q_s9.tail);

        // Perform deque
        //TODO
        if (!reg_is_enque_s[9]) begin
            // Update the free list
            fl_wrreq = reg_valid_s[9];
        end
        /**
         * Stage 6: Write-back the L2 counter and bitmap,
         * and read the corresponding PB (head and tail).
         */
        // Write L2 counter
        counter_l2_wren = reg_valid_s[5];
        counter_l2_data = l2_counter_s6;
        counter_l2_wraddress = {reg_l2_addr_s[5],
                                reg_l2_bitmap_idx_s5};
                                
                                
        /**
         * Stage 10: HBM Perform writes: update the priority bucket,
         * the free list, heap entries, next and prev pointers.
         */
        hbm_fl_data = (
            (hbm_reg_op_color_s[9] == HBM_OP_COLOR_BLUE) ?
            hbm_reg_pb_q_s9.head : hbm_reg_pb_q_s9.tail);

        // Perform deque
        //TODO
        if (!hbm_reg_is_enque_s[9]) begin
            // Update the free list
            hbm_fl_wrreq = hbm_reg_valid_s[9];
        end
        /**
         * Stage 6: HBM Write-back the L2 counter and bitmap,
         * and read the corresponding PB (head and tail).
         */
        // Write L2 counter
        hbm_counter_l2_wren = hbm_reg_valid_s[5];
        hbm_counter_l2_data = hbm_l2_counter_s6;
        hbm_counter_l2_wraddress = {hbm_reg_l2_addr_s[5],
                                hbm_reg_l2_bitmap_idx_s5};
    end
end

/**
 * State-independent logic.
 */
always_comb begin
    valid_s1 = 0;
    old_occupancy_s1 = occupancy;
    rcd_s2 = READ_CARRY_DOWN;
    rcd_s4 = READ_CARRY_DOWN;
    rcd_s5 = READ_CARRY_DOWN;
    l2_counter_s5 = reg_l2_counter_s5;
    l2_counter_q_s5 = counter_l2_q;
    priority_s6 = {reg_l2_addr_s[5], reg_l2_bitmap_idx_s5};
    op_color_s7 = OP_COLOR_RED;
    if (reg_is_enque_s[6]) begin
        op_color_s7 = OP_COLOR_BLUE;
    end
    he_q_s9 = he_q;
    np_q_s9 = np_q;
    pp_q_s9 = pp_q;

    int_pb_q = pb_q_r;

    fl_rdreq = 0;

    he_rden = 0;
    he_wren = 0;
    he_data = reg_he_data_s[9];
    he_wraddress = fl_q_r[7];

    np_rden = 0;
    np_wren = 0;
    np_data = reg_pb_q_s9.head;
    np_wraddress = fl_q_r[7];

    pp_rden = 0;
    pp_wren = 0;
    pp_data = fl_q_r[7];
    pp_wraddress = reg_pb_q_s9.head;

    pb_rdwr_conflict = 0;
    pb_rdaddress = priority_s6;
    int_pb_data = reg_pb_new_s9;
    pb_wraddress = reg_priority_s[9];

    counter_l2_rden = 0;
    
    //hbm
    hbm_valid_s1 = 0;
    hbm_old_occupancy_s1 = hbm_occupancy;
    hbm_rcd_s2 = HBM_READ_CARRY_DOWN;
    hbm_rcd_s4 = HBM_READ_CARRY_DOWN;
    hbm_rcd_s5 = HBM_READ_CARRY_DOWN;
    hbm_l2_counter_s5 = hbm_reg_l2_counter_s5;
    hbm_l2_counter_q_s5 = hbm_counter_l2_q;
    hbm_priority_s6 = {hbm_reg_l2_addr_s[5], hbm_reg_l2_bitmap_idx_s5};
    hbm_op_color_s7 = HBM_OP_COLOR_RED;
    if (hbm_reg_is_enque_s[6]) begin
        hbm_op_color_s7 = HBM_OP_COLOR_BLUE;
    end
    hbm_he_q_s9 = hbm_he_q;
    hbm_np_q_s9 = hbm_np_q;
    hbm_pp_q_s9 = hbm_pp_q;

    hbm_int_pb_q = hbm_pb_q_r;

    hbm_fl_rdreq = 0;

    hbm_he_rden = 0;
    hbm_he_wren = 0;
    hbm_he_data = hbm_reg_he_data_s[9];
    hbm_he_wraddress = hbm_fl_q_r[7];

    hbm_np_rden = 0;
    hbm_np_wren = 0;
    hbm_np_data = hbm_reg_pb_q_s9.head;
    hbm_np_wraddress = hbm_fl_q_r[7];

    hbm_pp_rden = 0;
    hbm_pp_wren = 0;
    hbm_pp_data = hbm_fl_q_r[7];
    hbm_pp_wraddress = hbm_reg_pb_q_s9.head;

    hbm_pb_rdwr_conflict = 0;
    hbm_pb_rdaddress = hbm_priority_s6;
    hbm_int_pb_data = hbm_reg_pb_new_s9;
    hbm_pb_wraddress = hbm_reg_priority_s[9];

    hbm_counter_l2_rden = 0;

    /**
     * Stage 10: Perform writes: update the priority bucket,
     * the free list, heap entries, next and prev pointers.
     */
    pb_wren = reg_valid_s[9];

    // Perform enque
    if (reg_is_enque_s[9]) begin
        if (reg_valid_s[9]) begin
            he_wren = 1; // Update the heap entry
            np_wren = 1; // Update the next pointer

            // Update the entry's previous pointer. The
            // pointer address is only valid if the PB
            // was not previously empty, so write must
            // be predicated on no change of state.
            if (!reg_pb_state_changes_s9) begin
                pp_wren = 1;
            end
        end

        // Update the data
        he_data_s10 = reg_he_data_s[9];
    end
    // Perform deque
    else begin
        if (reg_op_color_s[9] == OP_COLOR_BLUE) begin
            // BLUE-colored dequeue (from HEAD)
            int_pb_data.head = reg_np_q_s9;
        end
        else begin
            // RED-colored dequeue (from TAIL)
            int_pb_data.tail = reg_pp_q_s9;
        end

        // Update the data
        he_data_s10 = (
            reg_pb_data_conflict_s9 ?
            reg_he_data_s[10] : reg_he_q_s9);
    end
    /**
     * Stage 10: HBM Perform writes: update the priority bucket,
     * the free list, heap entries, next and prev pointers.
     */
    hbm_pb_wren = hbm_reg_valid_s[9];

    // Perform enque
    if (hbm_reg_is_enque_s[9]) begin
        if (hbm_reg_valid_s[9]) begin
            hbm_he_wren = 1; // Update the heap entry
            hbm_np_wren = 1; // Update the next pointer

            // Update the entry's previous pointer. The
            // pointer address is only valid if the PB
            // was not previously empty, so write must
            // be predicated on no change of state.
            if (!hbm_reg_pb_state_changes_s9) begin
                hbm_pp_wren = 1;
            end
        end

        // Update the data
        hbm_he_data_s10 = hbm_reg_he_data_s[9];
    end
    // Perform deque
    else begin
        if (hbm_reg_op_color_s[9] == HBM_OP_COLOR_BLUE) begin
            // BLUE-colored dequeue (from HEAD)
            hbm_int_pb_data.head = hbm_reg_np_q_s9;
        end
        else begin
            // RED-colored dequeue (from TAIL)
            hbm_int_pb_data.tail = hbm_reg_pp_q_s9;
        end

        // Update the data
        hbm_he_data_s10 = (
            hbm_reg_pb_data_conflict_s9 ?
            hbm_reg_he_data_s[10] : hbm_reg_he_q_s9);
    end
    /**
     * Stage 9: Read delay for HE and pointers.
     */
    // This HE was updated on the last cycle, so the output is stale
    if (he_wren_r && (he_wraddress_r == he_rdaddress_r)) begin
        he_q_s9 = reg_he_data_s10;
    end
    // Fallthrough: default to he_q

    // This NP was updated on the last cycle, so the output is stale
    if (np_wren_r && (np_wraddress_r == np_rdaddress_r)) begin
        np_q_s9 = reg_np_data_s10;
    end
    // Fallthrough: default to np_q

    // This PP was updated in the last 2 cycles
    if (reg_pp_data_valid_s8) begin
        pp_q_s9 = reg_pp_data_s8;
    end
    // Fallthrough: default to pp_q

    /**
     * Stage 9: HBM Read delay for HE and pointers.
     */
    // This HE was updated on the last cycle, so the output is stale
    if (hbm_he_wren_r && (hbm_he_wraddress_r == hbm_he_rdaddress_r)) begin
        hbm_he_q_s9 = hbm_reg_he_data_s10;
    end
    // Fallthrough: default to he_q

    // This NP was updated on the last cycle, so the output is stale
    if (hbm_np_wren_r && (hbm_np_wraddress_r == hbm_np_rdaddress_r)) begin
        hbm_np_q_s9 = hbm_reg_np_data_s10;
    end
    // Fallthrough: default to np_q

    // This PP was updated in the last 2 cycles
    if (hbm_reg_pp_data_valid_s8) begin
        hbm_pp_q_s9 = hbm_reg_pp_data_s8;
    end
    // Fallthrough: default to pp_q

    /**
     * Stage 8: Read the heap entry and prev/next pointer
     * corresponding to the priority bucket to deque.
     */
    // The PB is being updated on this cycle
    if (reg_pb_addr_conflict_s9_s7) begin
        int_pb_q = int_pb_data;
    end
    // The PB was updated last cycle, so output is stale
    else if (reg_pb_update_s7) begin
        int_pb_q = reg_pb_data_s10;
    end
    // The PB was updated 2 cycles ago (and thus never read)
    else if (reg_pb_rdwr_conflict_r2) begin
        int_pb_q = reg_pb_data_s11;
    end
    // Fallthrough: default to pb_q_r

    // Read next and prev pointers
    np_rdaddress = int_pb_q.head;
    pp_rdaddress = int_pb_q.tail;

    // Compute tail PP updates
    pp_changes_s9_s8 = (reg_pb_tail_pp_changes_s8 &&
                        reg_pb_addr_conflict_s8_s7);

    pp_changes_s10_s8 = (reg_pb_tail_pp_changes_s9 &&
                         reg_pb_addr_conflict_s9_s7);

    // Read HE data
    he_rdaddress = (
        (reg_op_color_s[7] == OP_COLOR_BLUE) ?
        int_pb_q.head : int_pb_q.tail);

    if (reg_valid_s[7]) begin
        if (!reg_is_enque_s[7]) begin
            he_rden = 1; // Dequeing, read HE and PP/NP
            if (reg_op_color_s[7] == OP_COLOR_BLUE) begin
                np_rden = 1; // BLUE-colored dequeue (from HEAD)
            end
            else begin
                pp_rden = 1; // RED-colored dequeue (from TAIL)
            end
        end
    end
    
     /**
     * Stage 8: HBM Read the heap entry and prev/next pointer
     * corresponding to the priority bucket to deque.
     */
    // The PB is being updated on this cycle
    if (hbm_reg_pb_addr_conflict_s9_s7) begin
        hbm_int_pb_q = hbm_int_pb_data;
    end
    // The PB was updated last cycle, so output is stale
    else if (hbm_reg_pb_update_s7) begin
        hbm_int_pb_q = hbm_reg_pb_data_s10;
    end
    // The PB was updated 2 cycles ago (and thus never read)
    else if (hbm_reg_pb_rdwr_conflict_r2) begin
        hbm_int_pb_q = hbm_reg_pb_data_s11;
    end
    // Fallthrough: default to pb_q_r

    // Read next and prev pointers
    hbm_np_rdaddress = hbm_int_pb_q.head;
    hbm_pp_rdaddress = hbm_int_pb_q.tail;

    // Compute tail PP updates
    hbm_pp_changes_s9_s8 = (hbm_reg_pb_tail_pp_changes_s8 &&
                        hbm_reg_pb_addr_conflict_s8_s7);

    hbm_pp_changes_s10_s8 = (hbm_reg_pb_tail_pp_changes_s9 &&
                         hbm_reg_pb_addr_conflict_s9_s7);

    // Read HE data
    hbm_he_rdaddress = (
        (hbm_reg_op_color_s[7] == HBM_OP_COLOR_BLUE) ?
        hbm_int_pb_q.head : hbm_int_pb_q.tail);

    if (hbm_reg_valid_s[7]) begin
        if (!hbm_reg_is_enque_s[7]) begin
            hbm_he_rden = 1; // Dequeing, read HE and PP/NP
            if (hbm_reg_op_color_s[7] == HBM_OP_COLOR_BLUE) begin
                hbm_np_rden = 1; // BLUE-colored dequeue (from HEAD)
            end
            else begin
                hbm_pp_rden = 1; // RED-colored dequeue (from TAIL)
            end
        end
    end
    /**
     * Stage 7: Compute op color, read delay for PB.
     */
    if (!reg_is_enque_s[6]) begin
        // Dequeing, recolor this op if required
        if (reg_pb_addr_conflict_s7_s6) begin
            if (reg_op_color_s[7] == OP_COLOR_BLUE) begin
                op_color_s7 = OP_COLOR_RED;
            end
            else begin
                op_color_s7 = OP_COLOR_BLUE;
            end
        end
    end
 
     /**
     * Stage 7: HBM_Compute op color, read delay for PB.
     */
    if (!hbm_reg_is_enque_s[6]) begin
        // Dequeing, recolor this op if required
        if (hbm_reg_pb_addr_conflict_s7_s6) begin
            if (hbm_reg_op_color_s[7] == HBM_OP_COLOR_BLUE) begin
                hbm_op_color_s7 = HBM_OP_COLOR_RED;
            end
            else begin
                hbm_op_color_s7 = HBM_OP_COLOR_BLUE;
            end
        end
    end
 
    /**
     * Stage 6: Write-back the L2 counter and bitmap,
     * and read the corresponding PB (head and tail).
     */
    l2_counter_s6[WATERLEVEL_IDX-1:0] = (
        reg_is_enque_s[5] ? (reg_l2_counter_rc_s5[WATERLEVEL_IDX-1:0] + 1) :
                            (reg_l2_counter_rc_s5[WATERLEVEL_IDX-1:0] - 1));

    l2_counter_s6[WATERLEVEL_IDX] = (reg_is_enque_s[5] ?
        (reg_l2_counter_rc_s5[WATERLEVEL_IDX] | reg_l2_counter_rc_s5[0]) :
        ((|reg_l2_counter_rc_s5[WATERLEVEL_IDX-1:2]) | (&reg_l2_counter_rc_s5[1:0])));

    l2_counter_non_zero_s6 = (reg_is_enque_s[5] |
                              reg_l2_counter_rc_s5[WATERLEVEL_IDX]);
    // Write L2 bitmap
    if (reg_is_enque_s[5]) begin
        l2_bitmap_s6 = (reg_l2_bitmap_s[5] |
                        reg_l2_bitmap_idx_onehot_s5);
    end
    else begin
        l2_bitmap_s6 = (
            l2_counter_non_zero_s6 ? reg_l2_bitmap_s[5] :
            (reg_l2_bitmap_s[5] & ~reg_l2_bitmap_idx_onehot_s5));
    end
    // Read PB contents
    pb_rden = reg_valid_s[5];

    // Compute conflicts
    pb_addr_conflict_s7_s6 = (
        reg_l2_addr_conflict_s6_s5
            && (reg_l2_bitmap_idx_s5 ==
                reg_priority_s[6][HEAP_LOG_BITMAP_WIDTH-1:0]));

    pb_addr_conflict_s8_s6 = (
        reg_l2_addr_conflict_s7_s5
            && (reg_l2_bitmap_idx_s5 ==
                reg_priority_s[7][HEAP_LOG_BITMAP_WIDTH-1:0]));

    pb_addr_conflict_s9_s6 = (
        reg_l2_addr_conflict_s8_s5
            && (reg_l2_bitmap_idx_s5 ==
                reg_priority_s[8][HEAP_LOG_BITMAP_WIDTH-1:0]));

    pb_addr_conflict_s10_s6 = (
        reg_l2_addr_conflict_s9_s5
            && (reg_l2_bitmap_idx_s5 ==
                reg_priority_s[9][HEAP_LOG_BITMAP_WIDTH-1:0]));

    // Disable conflicting reads during writes
    if (pb_addr_conflict_s10_s6) begin
        pb_rdwr_conflict = 1;
        pb_rden = 0;
    end
   
    /**
     * Stage 6: HBM Write-back the L2 counter and bitmap,
     * and read the corresponding PB (head and tail).
     */
    hbm_l2_counter_s6[WATERLEVEL_IDX-1:0] = (
        hbm_reg_is_enque_s[5] ? (hbm_reg_l2_counter_rc_s5[WATERLEVEL_IDX-1:0] + 1) :
                            (hbm_reg_l2_counter_rc_s5[WATERLEVEL_IDX-1:0] - 1));

    hbm_l2_counter_s6[WATERLEVEL_IDX] = (hbm_reg_is_enque_s[5] ?
        (hbm_reg_l2_counter_rc_s5[WATERLEVEL_IDX] | hbm_reg_l2_counter_rc_s5[0]) :
        ((|hbm_reg_l2_counter_rc_s5[WATERLEVEL_IDX-1:2]) | (&hbm_reg_l2_counter_rc_s5[1:0])));

    hbm_l2_counter_non_zero_s6 = (hbm_reg_is_enque_s[5] |
                              hbm_reg_l2_counter_rc_s5[WATERLEVEL_IDX]);
    // Write L2 bitmap
    if (hbm_reg_is_enque_s[5]) begin
        hbm_l2_bitmap_s6 = (hbm_reg_l2_bitmap_s[5] |
                        hbm_reg_l2_bitmap_idx_onehot_s5);
    end
    else begin
        hbm_l2_bitmap_s6 = (
            hbm_l2_counter_non_zero_s6 ? hbm_reg_l2_bitmap_s[5] :
            (hbm_reg_l2_bitmap_s[5] & ~hbm_reg_l2_bitmap_idx_onehot_s5));
    end
    // Read PB contents
    hbm_pb_rden = hbm_reg_valid_s[5];

    // Compute conflicts
    hbm_pb_addr_conflict_s7_s6 = (
        hbm_reg_l2_addr_conflict_s6_s5
            && (hbm_reg_l2_bitmap_idx_s5 ==
                hbm_reg_priority_s[6][HEAP_LOG_BITMAP_WIDTH-1:0]));

    hbm_pb_addr_conflict_s8_s6 = (
        hbm_reg_l2_addr_conflict_s7_s5
            && (hbm_reg_l2_bitmap_idx_s5 ==
                hbm_reg_priority_s[7][HEAP_LOG_BITMAP_WIDTH-1:0]));

    hbm_pb_addr_conflict_s9_s6 = (
        hbm_reg_l2_addr_conflict_s8_s5
            && (hbm_reg_l2_bitmap_idx_s5 ==
                hbm_reg_priority_s[8][HEAP_LOG_BITMAP_WIDTH-1:0]));

    hbm_pb_addr_conflict_s10_s6 = (
        hbm_reg_l2_addr_conflict_s9_s5
            && (hbm_reg_l2_bitmap_idx_s5 ==
                hbm_reg_priority_s[9][HEAP_LOG_BITMAP_WIDTH-1:0]));

    // Disable conflicting reads during writes
    if (hbm_pb_addr_conflict_s10_s6) begin
        hbm_pb_rdwr_conflict = 1;
        hbm_pb_rden = 0;
    end
   
   
    /**
     * Stage 5: NOOP, read delay for L2 counter.
     */
    // Compute the read carry direction. If the
    // active op in Stage 6 is of the same type
    // or the bitmap is empty, carry right.
    if (!reg_is_enque_s[4] &&
        l2_counter_non_zero_s6 &&
        reg_l2_addr_conflict_s5_s4 &&
        (reg_l2_bitmap_empty_s4 || (reg_op_type_s[4] ==
                                    reg_op_type_s[5]))) begin
        rcd_s5 = READ_CARRY_RIGHT;
    end
    // Fallthrough: default to carry down

    // Counter is updating this cycle, so output is stale
    if ((reg_l2_bitmap_idx_s4 == reg_l2_bitmap_idx_s5)
        && reg_l2_addr_conflict_s5_s4) begin
        l2_counter_q_s5 = l2_counter_s6;
        l2_counter_s5 = l2_counter_s6;
    end
    // Counter was updated last cycle (there was R/W conflict)
    else if ((reg_l2_bitmap_idx_s4 == reg_l2_bitmap_idx_s6)
             && reg_l2_addr_conflict_s6_s4) begin
        l2_counter_q_s5 = reg_l2_counter_s6;
        l2_counter_s5 = reg_l2_counter_s6;
    end
    // Fallthrough, defaults to:
    // counter_l2_q for l2_counter_q_s5
    // reg_l2_counter_s5 for l2_counter_s5

    /**
     * Stage 5: HBM NOOP, read delay for L2 counter.
     */
    // Compute the read carry direction. If the
    // active op in Stage 6 is of the same type
    // or the bitmap is empty, carry right.
    if (!hbm_reg_is_enque_s[4] &&
        hbm_l2_counter_non_zero_s6 &&
        hbm_reg_l2_addr_conflict_s5_s4 &&
        (hbm_reg_l2_bitmap_empty_s4 || (hbm_reg_op_type_s[4] ==
                                    hbm_reg_op_type_s[5]))) begin
        hbm_rcd_s5 = HBM_READ_CARRY_RIGHT;
    end
    // Fallthrough: default to carry down

    // Counter is updating this cycle, so output is stale
    if ((hbm_reg_l2_bitmap_idx_s4 == hbm_reg_l2_bitmap_idx_s5)
        && hbm_reg_l2_addr_conflict_s5_s4) begin
        hbm_l2_counter_q_s5 = hbm_l2_counter_s6;
        hbm_l2_counter_s5 = hbm_l2_counter_s6;
    end
    // Counter was updated last cycle (there was R/W conflict)
    else if ((hbm_reg_l2_bitmap_idx_s4 == hbm_reg_l2_bitmap_idx_s6)
             && hbm_reg_l2_addr_conflict_s6_s4) begin
        hbm_l2_counter_q_s5 = hbm_reg_l2_counter_s6;
        hbm_l2_counter_s5 = hbm_reg_l2_counter_s6;
    end
    // Fallthrough, defaults to:
    // counter_l2_q for l2_counter_q_s5
    // reg_l2_counter_s5 for l2_counter_s5


    /**
     * Stage 4: Compute the L2 bitmap index and postop
     * bitmap, and read the corresponding L2 counter.
     */
    // L2 bitmap changes?
    l2_bitmap_changes_s6_s4 = (
        reg_l2_addr_conflict_s5_s3 &&
        (reg_is_enque_s[5] || !l2_counter_non_zero_s6));

    // Compute L2 bitmap idx and postop
    case (reg_op_type_s[3])
    HEAP_OP_DEQUE_MAX: begin
        l2_bitmap_idx_s4 = (
            reg_l2_addr_conflict_s4_s3 ? ffs_l2_inst_msb[1] :
               l2_bitmap_changes_s6_s4 ? ffs_l2_inst_msb[2] :
                                         ffs_l2_inst_msb[0]);

        l2_bitmap_empty_s4 = (
            reg_l2_addr_conflict_s4_s3 ? ffs_l2_inst_zero[1] :
               l2_bitmap_changes_s6_s4 ? ffs_l2_inst_zero[2] :
                                         ffs_l2_inst_zero[0]);

        l2_bitmap_idx_onehot_s4 = (
            reg_l2_addr_conflict_s4_s3 ? ffs_l2_inst_msb_onehot[1] :
               l2_bitmap_changes_s6_s4 ? ffs_l2_inst_msb_onehot[2] :
                                         ffs_l2_inst_msb_onehot[0]);

        l2_bitmap_postop_s4 = (
            reg_l2_addr_conflict_s4_s3 ? (l2_bitmap_idx_onehot_s4 ^
                                          reg_l2_bitmap_postop_s4) :
               l2_bitmap_changes_s6_s4 ? (l2_bitmap_idx_onehot_s4 ^
                                          reg_l2_bitmap_postop_s5) :
                                         (l2_bitmap_idx_onehot_s4 ^
                                          reg_l2_bitmap_s[3]));
    end
    HEAP_OP_DEQUE_MIN: begin
        l2_bitmap_idx_s4 = (
            reg_l2_addr_conflict_s4_s3 ? ffs_l2_inst_lsb[1] :
               l2_bitmap_changes_s6_s4 ? ffs_l2_inst_lsb[2] :
                                         ffs_l2_inst_lsb[0]);

        l2_bitmap_empty_s4 = (
            reg_l2_addr_conflict_s4_s3 ? ffs_l2_inst_zero[1] :
               l2_bitmap_changes_s6_s4 ? ffs_l2_inst_zero[2] :
                                         ffs_l2_inst_zero[0]);

        l2_bitmap_idx_onehot_s4 = (
            reg_l2_addr_conflict_s4_s3 ? ffs_l2_inst_lsb_onehot[1] :
               l2_bitmap_changes_s6_s4 ? ffs_l2_inst_lsb_onehot[2] :
                                         ffs_l2_inst_lsb_onehot[0]);

        l2_bitmap_postop_s4 = (
            reg_l2_addr_conflict_s4_s3 ? (l2_bitmap_idx_onehot_s4 ^
                                          reg_l2_bitmap_postop_s4) :
               l2_bitmap_changes_s6_s4 ? (l2_bitmap_idx_onehot_s4 ^
                                          reg_l2_bitmap_postop_s5) :
                                         (l2_bitmap_idx_onehot_s4 ^
                                          reg_l2_bitmap_s[3]));
    end
    // HEAP_OP_ENQUE
    default: begin
        l2_bitmap_empty_s4 = 0;
        l2_bitmap_idx_s4 = (reg_priority_s[3][(
                (1 * HEAP_LOG_BITMAP_WIDTH) - 1)
                : 0]);

        l2_bitmap_idx_onehot_s4 = (1 << l2_bitmap_idx_s4);
        l2_bitmap_postop_s4 = (
            reg_l2_addr_conflict_s4_s3 ? (l2_bitmap_idx_onehot_s4 |
                                          reg_l2_bitmap_postop_s4) :
               l2_bitmap_changes_s6_s4 ? (l2_bitmap_idx_onehot_s4 |
                                          reg_l2_bitmap_postop_s5) :
                                         (l2_bitmap_idx_onehot_s4 |
                                          reg_l2_bitmap_s[3]));
    end
    endcase
    // Compute the read carry direction. If the active
    // op in Stage 6 is of the same type, carry up.
    if (!reg_is_enque_s[3] &&
        l2_counter_non_zero_s6 &&
        reg_l2_addr_conflict_s5_s3 &&
        (reg_op_type_s[3] == reg_op_type_s[5])) begin
        rcd_s4 = READ_CARRY_UP;

        // Special case: The active op in Stage 5 is also
        // of the same type, which means that it's bound
        // to carry right; here, we do the same.
        if ((reg_op_type_s[3] == reg_op_type_s[4]) &&
            reg_l2_addr_conflict_s4_s3) begin
            rcd_s4 = READ_CARRY_RIGHT;
        end
    end
    // Fallthrough: default to carry down

    // Read the L2 counter
    counter_l2_rden = reg_valid_s[3];
    counter_l2_rdaddress = {reg_l2_addr_s[3],
                            l2_bitmap_idx_s4};
                       
    /**
     * Stage 4: HBM Compute the L2 bitmap index and postop
     * bitmap, and read the corresponding L2 counter.
     */
    // L2 bitmap changes?
    hbm_l2_bitmap_changes_s6_s4 = (
        hbm_reg_l2_addr_conflict_s5_s3 &&
        (hbm_reg_is_enque_s[5] || !hbm_l2_counter_non_zero_s6));

    // Compute L2 bitmap idx and postop
    case (hbm_reg_op_type_s[3])
    HEAP_OP_DEQUE_MAX: begin
        hbm_l2_bitmap_idx_s4 = (
            hbm_reg_l2_addr_conflict_s4_s3 ? hbm_ffs_l2_inst_msb[1] :
               hbm_l2_bitmap_changes_s6_s4 ? hbm_ffs_l2_inst_msb[2] :
                                         hbm_ffs_l2_inst_msb[0]);

        hbm_l2_bitmap_empty_s4 = (
            hbm_reg_l2_addr_conflict_s4_s3 ? hbm_ffs_l2_inst_zero[1] :
               hbm_l2_bitmap_changes_s6_s4 ? hbm_ffs_l2_inst_zero[2] :
                                         hbm_ffs_l2_inst_zero[0]);

        hbm_l2_bitmap_idx_onehot_s4 = (
            hbm_reg_l2_addr_conflict_s4_s3 ? hbm_ffs_l2_inst_msb_onehot[1] :
               hbm_l2_bitmap_changes_s6_s4 ? hbm_ffs_l2_inst_msb_onehot[2] :
                                         hbm_ffs_l2_inst_msb_onehot[0]);

        hbm_l2_bitmap_postop_s4 = (
            hbm_reg_l2_addr_conflict_s4_s3 ? (hbm_l2_bitmap_idx_onehot_s4 ^
                                          hbm_reg_l2_bitmap_postop_s4) :
               hbm_l2_bitmap_changes_s6_s4 ? (hbm_l2_bitmap_idx_onehot_s4 ^
                                          hbm_reg_l2_bitmap_postop_s5) :
                                         (hbm_l2_bitmap_idx_onehot_s4 ^
                                          hbm_reg_l2_bitmap_s[3]));
    end
    HEAP_OP_DEQUE_MIN: begin
        hbm_l2_bitmap_idx_s4 = (
            hbm_reg_l2_addr_conflict_s4_s3 ? hbm_ffs_l2_inst_lsb[1] :
               hbm_l2_bitmap_changes_s6_s4 ? hbm_ffs_l2_inst_lsb[2] :
                                         hbm_ffs_l2_inst_lsb[0]);

        hbm_l2_bitmap_empty_s4 = (
            hbm_reg_l2_addr_conflict_s4_s3 ? hbm_ffs_l2_inst_zero[1] :
               hbm_l2_bitmap_changes_s6_s4 ? hbm_ffs_l2_inst_zero[2] :
                                         hbm_ffs_l2_inst_zero[0]);

        hbm_l2_bitmap_idx_onehot_s4 = (
            hbm_reg_l2_addr_conflict_s4_s3 ? hbm_ffs_l2_inst_lsb_onehot[1] :
               hbm_l2_bitmap_changes_s6_s4 ? hbm_ffs_l2_inst_lsb_onehot[2] :
                                         hbm_ffs_l2_inst_lsb_onehot[0]);

        hbm_l2_bitmap_postop_s4 = (
            hbm_reg_l2_addr_conflict_s4_s3 ? (hbm_l2_bitmap_idx_onehot_s4 ^
                                          hbm_reg_l2_bitmap_postop_s4) :
               hbm_l2_bitmap_changes_s6_s4 ? (hbm_l2_bitmap_idx_onehot_s4 ^
                                          hbm_reg_l2_bitmap_postop_s5) :
                                         (hbm_l2_bitmap_idx_onehot_s4 ^
                                          hbm_reg_l2_bitmap_s[3]));
    end
    // HEAP_OP_ENQUE
    default: begin
        hbm_l2_bitmap_empty_s4 = 0;
        hbm_l2_bitmap_idx_s4 = (hbm_reg_priority_s[3][(
                (1 * HEAP_LOG_BITMAP_WIDTH) - 1)
                : 0]);

        hbm_l2_bitmap_idx_onehot_s4 = (1 << hbm_l2_bitmap_idx_s4);
        hbm_l2_bitmap_postop_s4 = (
            hbm_reg_l2_addr_conflict_s4_s3 ? (hbm_l2_bitmap_idx_onehot_s4 |
                                          hbm_reg_l2_bitmap_postop_s4) :
               hbm_l2_bitmap_changes_s6_s4 ? (hbm_l2_bitmap_idx_onehot_s4 |
                                          hbm_reg_l2_bitmap_postop_s5) :
                                         (hbm_l2_bitmap_idx_onehot_s4 |
                                          hbm_reg_l2_bitmap_s[3]));
    end
    endcase
    // Compute the read carry direction. If the active
    // op in Stage 6 is of the same type, carry up.
    if (!hbm_reg_is_enque_s[3] &&
        hbm_l2_counter_non_zero_s6 &&
        hbm_reg_l2_addr_conflict_s5_s3 &&
        (hbm_reg_op_type_s[3] == hbm_reg_op_type_s[5])) begin
        hbm_rcd_s4 = HBM_READ_CARRY_UP;

        // Special case: The active op in Stage 5 is also
        // of the same type, which means that it's bound
        // to carry right; here, we do the same.
        if ((hbm_reg_op_type_s[3] == hbm_reg_op_type_s[4]) &&
            hbm_reg_l2_addr_conflict_s4_s3) begin
            hbm_rcd_s4 = HBM_READ_CARRY_RIGHT;
        end
    end
    // Fallthrough: default to carry down

    // Read the L2 counter
    hbm_counter_l2_rden = hbm_reg_valid_s[3];
    hbm_counter_l2_rdaddress = {hbm_reg_l2_addr_s[3],
                            hbm_l2_bitmap_idx_s4};

    /**
     * Stage 3: Write-back the L1 counter and bitmap,
     * and read the corresponding L2 bitmap.
     */
    l1_counter_s3[WATERLEVEL_IDX-1:0] = (
        reg_is_enque_s[2] ? (reg_l1_counter_s2[WATERLEVEL_IDX-1:0] + 1) :
                            (reg_l1_counter_s2[WATERLEVEL_IDX-1:0] - 1));

    l1_counter_s3[WATERLEVEL_IDX] = (reg_is_enque_s[2] ?
        (reg_l1_counter_s2[WATERLEVEL_IDX] | reg_l1_counter_s2[0]) :
        ((|reg_l1_counter_s2[WATERLEVEL_IDX-1:2]) | (&reg_l1_counter_s2[1:0])));

    l1_counter_non_zero_s3 = (reg_is_enque_s[2] |
                              reg_l1_counter_s2[WATERLEVEL_IDX]);
    // Write L1 bitmap
    if (reg_is_enque_s[2]) begin
        l1_bitmap_s3 = (l1_bitmap |
                        reg_l1_bitmap_idx_onehot_s2);
    end
    else begin
        l1_bitmap_s3 = (
            l1_counter_non_zero_s3 ? l1_bitmap :
            (l1_bitmap & ~reg_l1_bitmap_idx_onehot_s2));
    end
    // Compute conflicts
    l2_addr_conflict_s4_s3 = (
        reg_valid_s[2] && reg_valid_s[3] &&
        (reg_l1_bitmap_idx_s2 == reg_l2_addr_s[3]));

    l2_addr_conflict_s5_s3 = (
        reg_valid_s[2] && reg_valid_s[4] &&
        (reg_l1_bitmap_idx_s2 == reg_l2_addr_s[4]));

    l2_addr_conflict_s6_s3 = (
        reg_valid_s[2] && reg_valid_s[5] &&
        (reg_l1_bitmap_idx_s2 == reg_l2_addr_s[5]));

    l2_addr_conflict_s7_s3 = (
        reg_valid_s[2] && reg_valid_s[6] &&
        (reg_l1_bitmap_idx_s2 == reg_l2_addr_s[6]));

    /**
     * Stage 3: HBM Write-back the L1 counter and bitmap,
     * and read the corresponding L2 bitmap.
     */
    hbm_l1_counter_s3[WATERLEVEL_IDX-1:0] = (
        hbm_reg_is_enque_s[2] ? (hbm_reg_l1_counter_s2[WATERLEVEL_IDX-1:0] + 1) :
                            (hbm_reg_l1_counter_s2[WATERLEVEL_IDX-1:0] - 1));

    hbm_l1_counter_s3[WATERLEVEL_IDX] = (hbm_reg_is_enque_s[2] ?
        (hbm_reg_l1_counter_s2[WATERLEVEL_IDX] | hbm_reg_l1_counter_s2[0]) :
        ((|hbm_reg_l1_counter_s2[WATERLEVEL_IDX-1:2]) | (&hbm_reg_l1_counter_s2[1:0])));

    hbm_l1_counter_non_zero_s3 = (hbm_reg_is_enque_s[2] |
                              hbm_reg_l1_counter_s2[WATERLEVEL_IDX]);
    // Write L1 bitmap
    if (hbm_reg_is_enque_s[2]) begin
        hbm_l1_bitmap_s3 = (hbm_l1_bitmap |
                        hbm_reg_l1_bitmap_idx_onehot_s2);
    end
    else begin
        hbm_l1_bitmap_s3 = (
            hbm_l1_counter_non_zero_s3 ? hbm_l1_bitmap :
            (hbm_l1_bitmap & ~hbm_reg_l1_bitmap_idx_onehot_s2));
    end
    // Compute conflicts
    hbm_l2_addr_conflict_s4_s3 = (
        hbm_reg_valid_s[2] && hbm_reg_valid_s[3] &&
        (hbm_reg_l1_bitmap_idx_s2 == hbm_reg_l2_addr_s[3]));

    hbm_l2_addr_conflict_s5_s3 = (
        hbm_reg_valid_s[2] && hbm_reg_valid_s[4] &&
        (hbm_reg_l1_bitmap_idx_s2 == hbm_reg_l2_addr_s[4]));

    hbm_l2_addr_conflict_s6_s3 = (
        hbm_reg_valid_s[2] && hbm_reg_valid_s[5] &&
        (hbm_reg_l1_bitmap_idx_s2 == hbm_reg_l2_addr_s[5]));

    hbm_l2_addr_conflict_s7_s3 = (
        hbm_reg_valid_s[2] && hbm_reg_valid_s[6] &&
        (hbm_reg_l1_bitmap_idx_s2 == hbm_reg_l2_addr_s[6]));


    /**
     * Stage 2: Compute the L1 bitmap index and postop
     * bitmap, and read the corresponding L1 counter.
     */
    // L1 bitmap changes?
    l1_bitmap_changes_s3_s2 = (
        reg_valid_s[2] && (reg_is_enque_s[2] ||
                           !l1_counter_non_zero_s3));

    // Compute L1 bitmap idx and postop
    case (reg_op_type_s[1])
    HEAP_OP_DEQUE_MAX: begin
        l1_bitmap_idx_s2 = (
            l1_bitmap_changes_s3_s2 ? ffs_l1_inst_msb[1] :
                                      ffs_l1_inst_msb[0]);

        l1_bitmap_empty_s2 = (
            l1_bitmap_changes_s3_s2 ? ffs_l1_inst_zero[1] :
                                      ffs_l1_inst_zero[0]);

        l1_bitmap_idx_onehot_s2 = (
            l1_bitmap_changes_s3_s2 ? ffs_l1_inst_msb_onehot[1] :
                                      ffs_l1_inst_msb_onehot[0]);

        l1_bitmap_postop_s2 = (
            l1_bitmap_changes_s3_s2 ? (l1_bitmap_idx_onehot_s2 ^
                                       reg_l1_bitmap_postop_s2) :
                                      (l1_bitmap_idx_onehot_s2 ^
                                       l1_bitmap));
    end
    HEAP_OP_DEQUE_MIN: begin
        l1_bitmap_idx_s2 = (
            l1_bitmap_changes_s3_s2 ? ffs_l1_inst_lsb[1] :
                                      ffs_l1_inst_lsb[0]);

        l1_bitmap_empty_s2 = (
            l1_bitmap_changes_s3_s2 ? ffs_l1_inst_zero[1] :
                                      ffs_l1_inst_zero[0]);

        l1_bitmap_idx_onehot_s2 = (
            l1_bitmap_changes_s3_s2 ? ffs_l1_inst_lsb_onehot[1] :
                                      ffs_l1_inst_lsb_onehot[0]);

        l1_bitmap_postop_s2 = (
            l1_bitmap_changes_s3_s2 ? (l1_bitmap_idx_onehot_s2 ^
                                       reg_l1_bitmap_postop_s2) :
                                      (l1_bitmap_idx_onehot_s2 ^
                                       l1_bitmap));
    end
    // HEAP_OP_ENQUE
    default: begin
        l1_bitmap_empty_s2 = 0;
        l1_bitmap_idx_s2 = (reg_priority_s[1][(
                (2 * HEAP_LOG_BITMAP_WIDTH) - 1)
                : (1 * HEAP_LOG_BITMAP_WIDTH)]);

        l1_bitmap_idx_onehot_s2 = (1 << l1_bitmap_idx_s2);
        l1_bitmap_postop_s2 = (
            l1_bitmap_changes_s3_s2 ? (l1_bitmap_idx_onehot_s2 |
                                       reg_l1_bitmap_postop_s2) :
                                      (l1_bitmap_idx_onehot_s2 |
                                       l1_bitmap));
    end
    endcase
    // Compute the read carry direction. If the
    // active op in Stage 3 is of the same type
    // or the bitmap is empty, carry right.
    if (!reg_is_enque_s[1] &&
        reg_valid_s[2] && l1_counter_non_zero_s3 &&
        (l1_bitmap_empty_s2 || (reg_op_type_s[1] ==
                                reg_op_type_s[2]))) begin
        rcd_s2 = READ_CARRY_RIGHT;
    end
    // Fallthrough: default to carry down

    /**
     * Stage 2: HBM Compute the L1 bitmap index and postop
     * bitmap, and read the corresponding L1 counter.
     */
    // L1 bitmap changes?
    hbm_l1_bitmap_changes_s3_s2 = (
        hbm_reg_valid_s[2] && (hbm_reg_is_enque_s[2] ||
                           !hbm_l1_counter_non_zero_s3));

    // Compute L1 bitmap idx and postop
    case (hbm_reg_op_type_s[1])
    HEAP_OP_DEQUE_MAX: begin
        hbm_l1_bitmap_idx_s2 = (
            hbm_l1_bitmap_changes_s3_s2 ? hbm_ffs_l1_inst_msb[1] :
                                      hbm_ffs_l1_inst_msb[0]);

        hbm_l1_bitmap_empty_s2 = (
            hbm_l1_bitmap_changes_s3_s2 ? hbm_ffs_l1_inst_zero[1] :
                                      hbm_ffs_l1_inst_zero[0]);

        hbm_l1_bitmap_idx_onehot_s2 = (
            hbm_l1_bitmap_changes_s3_s2 ? hbm_ffs_l1_inst_msb_onehot[1] :
                                      hbm_ffs_l1_inst_msb_onehot[0]);

        hbm_l1_bitmap_postop_s2 = (
            hbm_l1_bitmap_changes_s3_s2 ? (hbm_l1_bitmap_idx_onehot_s2 ^
                                       hbm_reg_l1_bitmap_postop_s2) :
                                      (hbm_l1_bitmap_idx_onehot_s2 ^
                                       hbm_l1_bitmap));
    end
    HEAP_OP_DEQUE_MIN: begin
        hbm_l1_bitmap_idx_s2 = (
            hbm_l1_bitmap_changes_s3_s2 ? hbm_ffs_l1_inst_lsb[1] :
                                      hbm_ffs_l1_inst_lsb[0]);

        hbm_l1_bitmap_empty_s2 = (
            hbm_l1_bitmap_changes_s3_s2 ? hbm_ffs_l1_inst_zero[1] :
                                      hbm_ffs_l1_inst_zero[0]);

        hbm_l1_bitmap_idx_onehot_s2 = (
            hbm_l1_bitmap_changes_s3_s2 ? hbm_ffs_l1_inst_lsb_onehot[1] :
                                      hbm_ffs_l1_inst_lsb_onehot[0]);

        hbm_l1_bitmap_postop_s2 = (
            hbm_l1_bitmap_changes_s3_s2 ? (hbm_l1_bitmap_idx_onehot_s2 ^
                                       hbm_reg_l1_bitmap_postop_s2) :
                                      (hbm_l1_bitmap_idx_onehot_s2 ^
                                       hbm_l1_bitmap));
    end
    // HEAP_OP_ENQUE
    default: begin
        hbm_l1_bitmap_empty_s2 = 0;
        hbm_l1_bitmap_idx_s2 = (hbm_reg_priority_s[1][(
                (2 * HEAP_LOG_BITMAP_WIDTH) - 1)
                : (1 * HEAP_LOG_BITMAP_WIDTH)]);

        hbm_l1_bitmap_idx_onehot_s2 = (1 << hbm_l1_bitmap_idx_s2);
        hbm_l1_bitmap_postop_s2 = (
            hbm_l1_bitmap_changes_s3_s2 ? (hbm_l1_bitmap_idx_onehot_s2 |
                                       hbm_reg_l1_bitmap_postop_s2) :
                                      (hbm_l1_bitmap_idx_onehot_s2 |
                                       hbm_l1_bitmap));
    end
    endcase
    // Compute the read carry direction. If the
    // active op in Stage 3 is of the same type
    // or the bitmap is empty, carry right.
    if (!hbm_reg_is_enque_s[1] &&
        hbm_reg_valid_s[2] && hbm_l1_counter_non_zero_s3 &&
        (hbm_l1_bitmap_empty_s2 || (hbm_reg_op_type_s[1] ==
                                hbm_reg_op_type_s[2]))) begin
        hbm_rcd_s2 = HBM_READ_CARRY_RIGHT;
    end
    // Fallthrough: default to carry down


    /**
     * Stage 1: HBM Determine operation validity. Disables the pipeline
     * stage if the BBQ is empty (deques), or FL is empty (enques).
     */
    if (hbm_reg_valid_s[0]) begin
        hbm_valid_s1 = (
            (hbm_reg_is_enque_s[0] && !hbm_fl_empty) ||
            (!hbm_reg_is_enque_s[0] && (hbm_old_occupancy_s1[0] |
                                    hbm_old_occupancy_s1[WATERLEVEL_IDX])));
    end
    // Update the occupancy counter
    hbm_new_occupancy_s1[WATERLEVEL_IDX-1:0] = (
        hbm_reg_is_enque_s[0] ? (hbm_old_occupancy_s1[WATERLEVEL_IDX-1:0] + 1) :
                            (hbm_old_occupancy_s1[WATERLEVEL_IDX-1:0] - 1));

    hbm_new_occupancy_s1[WATERLEVEL_IDX] = (hbm_reg_is_enque_s[0] ?
        (hbm_old_occupancy_s1[WATERLEVEL_IDX] | hbm_old_occupancy_s1[0]) :
        ((|hbm_old_occupancy_s1[WATERLEVEL_IDX-1:2]) | (&hbm_old_occupancy_s1[1:0])));

    // If enqueing, also deque the free list
    if (hbm_valid_s1 && hbm_reg_is_enque_s[0]) begin
        hbm_fl_rdreq = 1;
    end

    /**
     * Stage 1: Determine operation validity. Disables the pipeline
     * stage if the BBQ is empty (deques), or FL is empty (enques).
     */
    if (reg_valid_s[0]) begin
        valid_s1 = (
            (reg_is_enque_s[0] && !fl_empty) ||
            (!reg_is_enque_s[0] && (old_occupancy_s1[0] |
                                    old_occupancy_s1[WATERLEVEL_IDX])));
    end
    // Update the occupancy counter
    new_occupancy_s1[WATERLEVEL_IDX-1:0] = (
        reg_is_enque_s[0] ? (old_occupancy_s1[WATERLEVEL_IDX-1:0] + 1) :
                            (old_occupancy_s1[WATERLEVEL_IDX-1:0] - 1));

    new_occupancy_s1[WATERLEVEL_IDX] = (reg_is_enque_s[0] ?
        (old_occupancy_s1[WATERLEVEL_IDX] | old_occupancy_s1[0]) :
        ((|old_occupancy_s1[WATERLEVEL_IDX-1:2]) | (&old_occupancy_s1[1:0])));

    // If enqueing, also deque the free list
    if (valid_s1 && reg_is_enque_s[0]) begin
        fl_rdreq = 1;
    end

    `ifdef DEBUG
    /**
     * Print a newline between pipeline output across timesteps.
     */
    debug_newline = in_valid;
    for (j = 0; j < (NUM_PIPELINE_STAGES - 1); j = j + 1) begin
        debug_newline |= reg_valid_s[j];
    end
    `endif
end

always @(posedge clk) begin
    if (rst) begin
        // SRAM
        // Reset occupancy
        occupancy <= 0;
        // Reset bitmaps
        l1_bitmap <= 0;
        for (i = 0; i < NUM_COUNTERS_L1; i = i + 1) begin
            l1_counters[i] <= 0;
        end
        for (i = 0; i < NUM_BITMAPS_L2; i = i + 1) begin
            l2_bitmaps[i] <= 0;
        end

        // Reset pipeline stages
        for (i = 0; i <= NUM_PIPELINE_STAGES; i = i + 1) begin
            reg_valid_s[i] <= 0;
        end

        // Reset init signals
        fl_init_done_r <= 0;
        fl_wraddress_counter_r <= 0;
        counter_l2_init_done_r <= 0;
        counter_l2_wraddress_counter_r <= 0;
        
        // HBM
        // Reset occupancy
        hbm_occupancy <= 0;
        // Reset bitmaps
        hbm_l1_bitmap <= 0;
        for (i = 0; i < NUM_COUNTERS_L1; i = i + 1) begin
            hbm_l1_counters[i] <= 0;
        end
        for (i = 0; i < NUM_BITMAPS_L2; i = i + 1) begin
            hbm_l2_bitmaps[i] <= 0;
        end

        // Reset pipeline stages
        for (i = 0; i <= NUM_PIPELINE_STAGES; i = i + 1) begin
            hbm_reg_valid_s[i] <= 0;
        end

        // Reset init signals
        hbm_fl_init_done_r <= 0;
        hbm_fl_wraddress_counter_r <= 0;
        hbm_counter_l2_init_done_r <= 0;
        hbm_counter_l2_wraddress_counter_r <= 0;

        // Reset FSM state
        state <= FSM_STATE_INIT;
    end
    else begin
        /**
         * Stage 11: Spillover stage.
         */
        reg_valid_s[11] <= reg_valid_s[10];
        reg_he_data_s[11] <= reg_he_data_s[10];
        reg_op_type_s[11] <= reg_op_type_s[10];
        reg_is_enque_s[11] <= reg_is_enque_s[10];
        reg_priority_s[11] <= reg_priority_s[10];
        reg_is_deque_max_s[11] <= reg_is_deque_max_s[10];
        reg_is_deque_min_s[11] <= reg_is_deque_min_s[10];

        reg_pb_data_s11 <= reg_pb_data_s10;
        reg_l2_addr_s[11] <= reg_l2_addr_s[10];
        reg_op_color_s[11] <= reg_op_color_s[10];
        reg_l2_bitmap_s[11] <= reg_l2_bitmap_s[10];

        /**
         * Stage 10: Perform writes: update the priority bucket,
         * the free list, heap entries, next and prev pointers.
         */
        reg_valid_s[10] <= reg_valid_s[9];
        reg_he_data_s[10] <= he_data_s10;
        reg_op_type_s[10] <= reg_op_type_s[9];
        reg_is_enque_s[10] <= reg_is_enque_s[9];
        reg_priority_s[10] <= reg_priority_s[9];
        reg_is_deque_max_s[10] <= reg_is_deque_max_s[9];
        reg_is_deque_min_s[10] <= reg_is_deque_min_s[9];

        reg_he_data_s10 <= he_data;
        reg_np_data_s10 <= np_data;
        reg_pp_data_s10 <= pp_data;
        reg_pb_data_s10 <= int_pb_data;
        reg_l2_addr_s[10] <= reg_l2_addr_s[9];
        reg_op_color_s[10] <= reg_op_color_s[9];
        reg_l2_bitmap_s[10] <= reg_l2_bitmap_s[9];

        /**
         * Stage 9: Read delay for HE and pointers.
         */
        reg_valid_s[9] <= reg_valid_s[8];
        reg_he_data_s[9] <= reg_he_data_s[8];
        reg_op_type_s[9] <= reg_op_type_s[8];
        reg_is_enque_s[9] <= reg_is_enque_s[8];
        reg_priority_s[9] <= reg_priority_s[8];
        reg_is_deque_max_s[9] <= reg_is_deque_max_s[8];
        reg_is_deque_min_s[9] <= reg_is_deque_min_s[8];

        reg_l2_addr_s[9] <= reg_l2_addr_s[8];
        reg_op_color_s[9] <= reg_op_color_s[8];
        reg_l2_bitmap_s[9] <= reg_l2_bitmap_s[8];
        reg_pb_data_conflict_s9 <= reg_pb_data_conflict_s8;
        reg_pb_state_changes_s9 <= reg_pb_state_changes_s8;
        reg_pb_tail_pp_changes_s9 <= reg_pb_tail_pp_changes_s8;

        reg_he_q_s9 <= he_q_s9;
        reg_np_q_s9 <= np_q_s9;
        reg_pp_q_s9 <= pp_q_s9;

        reg_pb_q_s9 <= (
            reg_pb_addr_conflict_s9_s8 ?
               int_pb_data : reg_pb_q_s8);

        reg_pb_new_s9 <= (
            reg_pb_addr_conflict_s9_s8 ?
               int_pb_data : reg_pb_q_s8);

        if (reg_is_enque_s[8]) begin
            // PB becomes non-empty, update tail
            if (reg_pb_state_changes_s8) begin
                reg_pb_new_s9.tail <= fl_q_r[6];
            end
            reg_pb_new_s9.head <= fl_q_r[6];
        end

        /**
         * Stage 8: Read the heap entry and prev/next pointer
         * corresponding to the priority bucket to deque.
         */
        reg_valid_s[8] <= reg_valid_s[7];
        reg_he_data_s[8] <= reg_he_data_s[7];
        reg_op_type_s[8] <= reg_op_type_s[7];
        reg_is_enque_s[8] <= reg_is_enque_s[7];
        reg_priority_s[8] <= reg_priority_s[7];
        reg_is_deque_max_s[8] <= reg_is_deque_max_s[7];
        reg_is_deque_min_s[8] <= reg_is_deque_min_s[7];

        reg_pb_q_s8 <= int_pb_q;
        reg_l2_addr_s[8] <= reg_l2_addr_s[7];
        reg_op_color_s[8] <= reg_op_color_s[7];
        reg_l2_bitmap_s[8] <= reg_l2_bitmap_s[7];
        reg_pb_data_conflict_s8 <= reg_pb_data_conflict_s7;
        reg_pb_state_changes_s8 <= reg_pb_state_changes_s7;
        reg_pb_tail_pp_changes_s8 <= reg_pb_tail_pp_changes_s7;
        reg_pb_addr_conflict_s9_s8 <= reg_pb_addr_conflict_s8_s7;
        reg_pb_addr_conflict_s10_s8 <= reg_pb_addr_conflict_s9_s7;

        reg_pp_data_s8 <= pp_changes_s9_s8 ? fl_q_r[5] : fl_q_r[6];
        reg_pp_data_valid_s8 <= (pp_changes_s9_s8 || pp_changes_s10_s8);

        /**
         * Stage 7: Compute op color, read delay for PB.
         */
        reg_valid_s[7] <= reg_valid_s[6];
        reg_he_data_s[7] <= reg_he_data_s[6];
        reg_op_type_s[7] <= reg_op_type_s[6];
        reg_is_enque_s[7] <= reg_is_enque_s[6];
        reg_priority_s[7] <= reg_priority_s[6];
        reg_is_deque_max_s[7] <= reg_is_deque_max_s[6];
        reg_is_deque_min_s[7] <= reg_is_deque_min_s[6];

        reg_op_color_s[7] <= op_color_s7;
        reg_l2_addr_s[7] <= reg_l2_addr_s[6];
        reg_l2_bitmap_s[7] <= reg_l2_bitmap_s[6];
        reg_pb_update_s7 <= reg_pb_addr_conflict_s9_s6;
        reg_pb_addr_conflict_s8_s7 <= reg_pb_addr_conflict_s7_s6;
        reg_pb_addr_conflict_s9_s7 <= reg_pb_addr_conflict_s8_s6;

        // Determine if this op is going to result in PB data
        // conflict (dequeing a PB immediately after an enque
        // operation that causes it to become non-empty).
        reg_pb_data_conflict_s7 <= (reg_is_enque_s[7] &&
            !reg_l2_counter_non_zero_s6 && reg_pb_addr_conflict_s7_s6);

        // Determine if this op causes the PB state to change.
        // Change of state is defined differently based on op:
        // for enques, corresponds to a PB becoming non-empty,
        // and for deques, corresponds to a PB becoming empty.
        reg_pb_state_changes_s7 <= (reg_is_enque_s[6] ?
            (!reg_l2_counter_s6[WATERLEVEL_IDX] && reg_l2_counter_s6[0]) :
            (!reg_l2_counter_s6[WATERLEVEL_IDX] && !reg_l2_counter_s6[0]));

        // Determine if this op causes the previous pointer
        // corresponding to the PB tail to change. High iff
        // enqueing into a PB containing a single element.
        reg_pb_tail_pp_changes_s7 <= (reg_is_enque_s[6] &&
            !reg_old_l2_counter_s6[WATERLEVEL_IDX]
            && reg_old_l2_counter_s6[0]);

        /**
         * Stage 6: Write-back the L2 counter and bitmap,
         * and read the corresponding PB (head and tail).
         */
        reg_valid_s[6] <= reg_valid_s[5];
        reg_he_data_s[6] <= reg_he_data_s[5];
        reg_op_type_s[6] <= reg_op_type_s[5];
        reg_is_enque_s[6] <= reg_is_enque_s[5];
        reg_priority_s[6] <= priority_s6;
        reg_is_deque_max_s[6] <= reg_is_deque_max_s[5];
        reg_is_deque_min_s[6] <= reg_is_deque_min_s[5];

        reg_l2_bitmap_s[6] <= l2_bitmap_s6;
        reg_l2_addr_s[6] <= reg_l2_addr_s[5];

        reg_l2_counter_s6 <= l2_counter_s6;
        reg_l2_bitmap_idx_s6 <= reg_l2_bitmap_idx_s5;
        reg_old_l2_counter_s6 <= reg_l2_counter_rc_s5;
        reg_l2_counter_non_zero_s6 <= l2_counter_non_zero_s6;

        reg_pb_addr_conflict_s7_s6 <= pb_addr_conflict_s7_s6;
        reg_pb_addr_conflict_s8_s6 <= pb_addr_conflict_s8_s6;
        reg_pb_addr_conflict_s9_s6 <= pb_addr_conflict_s9_s6;
        reg_pb_addr_conflict_s10_s6 <= pb_addr_conflict_s10_s6;

        // Write-back L2 bitmap
        if (reg_valid_s[5]) begin
            l2_bitmaps[reg_l2_addr_s[5]] <= l2_bitmap_s6;
        end

        /**
         * Stage 5: NOOP, read delay for L2 counter.
         */
        reg_valid_s[5] <= reg_valid_s[4];
        reg_he_data_s[5] <= reg_he_data_s[4];
        reg_op_type_s[5] <= reg_op_type_s[4];
        reg_is_enque_s[5] <= reg_is_enque_s[4];
        reg_priority_s[5] <= reg_priority_s[4];
        reg_is_deque_max_s[5] <= reg_is_deque_max_s[4];
        reg_is_deque_min_s[5] <= reg_is_deque_min_s[4];

        reg_l2_addr_s[5] <= reg_l2_addr_s[4];
        reg_l2_addr_conflict_s6_s5 <= reg_l2_addr_conflict_s5_s4;
        reg_l2_addr_conflict_s7_s5 <= reg_l2_addr_conflict_s6_s4;
        reg_l2_addr_conflict_s8_s5 <= reg_l2_addr_conflict_s7_s4;
        reg_l2_addr_conflict_s9_s5 <= reg_l2_addr_conflict_s8_s4;

        reg_l2_counter_s5 <= (reg_l2_counter_rdvalid_r1_s4 ?
                              l2_counter_q_s5 : l2_counter_s5);
        case (rcd_s5)
        READ_CARRY_DOWN: begin
            reg_l2_bitmap_idx_s5 <= reg_l2_bitmap_idx_s4;
            reg_l2_bitmap_postop_s5 <= reg_l2_bitmap_postop_s4;
            reg_l2_bitmap_idx_onehot_s5 <= reg_l2_bitmap_idx_onehot_s4;

            reg_l2_counter_rc_s5 <= (reg_l2_counter_rdvalid_r1_s4 ?
                                     l2_counter_q_s5 : l2_counter_s5);
        end
        READ_CARRY_RIGHT: begin
            reg_l2_counter_rc_s5 <= l2_counter_s6;
        end
        default: ;
        endcase

        // Forward L2 bitmap updates
        reg_l2_bitmap_s[5] <= (
            reg_l2_addr_conflict_s5_s4 ?
            l2_bitmap_s6 : reg_l2_bitmap_s[4]);

        /**
         * Stage 4: Compute the L2 bitmap index and postop
         * bitmap, and read the corresponding L2 counter.
         */
        reg_valid_s[4] <= reg_valid_s[3];
        reg_he_data_s[4] <= reg_he_data_s[3];
        reg_op_type_s[4] <= reg_op_type_s[3];
        reg_is_enque_s[4] <= reg_is_enque_s[3];
        reg_priority_s[4] <= reg_priority_s[3];
        reg_is_deque_max_s[4] <= reg_is_deque_max_s[3];
        reg_is_deque_min_s[4] <= reg_is_deque_min_s[3];

        reg_l2_addr_s[4] <= reg_l2_addr_s[3];
        reg_l2_addr_conflict_s5_s4 <= reg_l2_addr_conflict_s4_s3;
        reg_l2_addr_conflict_s6_s4 <= reg_l2_addr_conflict_s5_s3;
        reg_l2_addr_conflict_s7_s4 <= reg_l2_addr_conflict_s6_s3;
        reg_l2_addr_conflict_s8_s4 <= reg_l2_addr_conflict_s7_s3;

        reg_l2_counter_rdvalid_r1_s4 <= 0;

        case (rcd_s4)
        READ_CARRY_DOWN: begin
            reg_l2_bitmap_idx_s4 <= l2_bitmap_idx_s4;
            reg_l2_bitmap_empty_s4 <= l2_bitmap_empty_s4;
            reg_l2_bitmap_postop_s4 <= l2_bitmap_postop_s4;
            reg_l2_bitmap_idx_onehot_s4 <= l2_bitmap_idx_onehot_s4;

            reg_l2_counter_rdvalid_r1_s4 <= (!l2_bitmap_empty_s4);
        end
        READ_CARRY_UP: begin
            reg_l2_bitmap_empty_s4 <= 0;
            reg_l2_bitmap_idx_s4 <= reg_l2_bitmap_idx_s5;
            reg_l2_bitmap_idx_onehot_s4 <= reg_l2_bitmap_idx_onehot_s5;

            if (!reg_l2_addr_conflict_s4_s3) begin
                reg_l2_bitmap_postop_s4 <= (
                    reg_l2_bitmap_postop_s5);
            end
        end
        default: ;
        endcase

        // Forward L2 bitmap updates
        reg_l2_bitmap_s[4] <= (
            reg_l2_addr_conflict_s5_s3 ?
            l2_bitmap_s6 : reg_l2_bitmap_s[3]);

        /**
         * Stage 3: Write-back the L1 counter and bitmap,
         * and read the corresponding L2 bitmap.
         */
        reg_valid_s[3] <= reg_valid_s[2];
        reg_he_data_s[3] <= reg_he_data_s[2];
        reg_op_type_s[3] <= reg_op_type_s[2];
        reg_is_enque_s[3] <= reg_is_enque_s[2];
        reg_priority_s[3] <= reg_priority_s[2];
        reg_is_deque_max_s[3] <= reg_is_deque_max_s[2];
        reg_is_deque_min_s[3] <= reg_is_deque_min_s[2];

        reg_l2_addr_s[3] <= reg_l1_bitmap_idx_s2;

        reg_l1_counter_s3 <= l1_counter_s3;
        reg_l2_addr_conflict_s4_s3 <= l2_addr_conflict_s4_s3;
        reg_l2_addr_conflict_s5_s3 <= l2_addr_conflict_s5_s3;
        reg_l2_addr_conflict_s6_s3 <= l2_addr_conflict_s6_s3;
        reg_l2_addr_conflict_s7_s3 <= l2_addr_conflict_s7_s3;

        // Write-back L1 bitmap and counter
        if (reg_valid_s[2]) begin
            l1_bitmap <= l1_bitmap_s3;
            l1_counters[reg_l1_bitmap_idx_s2] <= l1_counter_s3;
        end

        // Forward L2 bitmap updates
        reg_l2_bitmap_s[3] <= (
            l2_addr_conflict_s6_s3 ?
            l2_bitmap_s6 : l2_bitmaps[reg_l1_bitmap_idx_s2]);

        /**
         * Stage 2: Compute the L1 bitmap index and postop
         * bitmap, and read the corresponding L1 counter.
         */
        reg_valid_s[2] <= reg_valid_s[1];
        reg_he_data_s[2] <= reg_he_data_s[1];
        reg_op_type_s[2] <= reg_op_type_s[1];
        reg_is_enque_s[2] <= reg_is_enque_s[1];
        reg_priority_s[2] <= reg_priority_s[1];
        reg_is_deque_max_s[2] <= reg_is_deque_max_s[1];
        reg_is_deque_min_s[2] <= reg_is_deque_min_s[1];

        reg_l1_bitmap_empty_s2 <= 0;

        case (rcd_s2)
        READ_CARRY_DOWN: begin
            reg_l1_bitmap_idx_s2 <= l1_bitmap_idx_s2;
            reg_l1_bitmap_empty_s2 <= l1_bitmap_empty_s2;
            reg_l1_bitmap_postop_s2 <= l1_bitmap_postop_s2;
            reg_l1_bitmap_idx_onehot_s2 <= l1_bitmap_idx_onehot_s2;

            reg_l1_counter_s2 <= (
                (reg_valid_s[2] &&
                    (l1_bitmap_idx_s2 == reg_l1_bitmap_idx_s2)) ?
                    l1_counter_s3 : l1_counters[l1_bitmap_idx_s2]);
        end
        READ_CARRY_RIGHT: begin
            reg_l1_counter_s2 <= l1_counter_s3;
        end
        default: ;
        endcase

        /**
         * Stage 1: Determine operation validity. Disables the pipeline
         * stage if the BBQ is empty (deques) or FL is empty (enqueues).
         */
        reg_valid_s[1] <= valid_s1;
        reg_he_data_s[1] <= reg_he_data_s[0];
        reg_op_type_s[1] <= reg_op_type_s[0];
        reg_is_enque_s[1] <= reg_is_enque_s[0];
        reg_priority_s[1] <= reg_priority_s[0];
        reg_is_deque_max_s[1] <= reg_is_deque_max_s[0];
        reg_is_deque_min_s[1] <= reg_is_deque_min_s[0];

        reg_old_occupancy_s1 <= old_occupancy_s1;
        reg_new_occupancy_s1 <= new_occupancy_s1;

        if (valid_s1) begin
            occupancy <= new_occupancy_s1;
        end

        /**
         * Stage 0: Register inputs.
         */
        reg_op_type_s[0] <= in_op_type;
        reg_he_data_s[0] <= in_he_data;
        reg_priority_s[0] <= in_he_priority;
        reg_valid_s[0] <= (ready & in_valid);
        reg_is_enque_s[0] <= (in_op_type == HEAP_OP_ENQUE || in_op_type == HEAP_OP_SWAP_IN);
        reg_is_deque_max_s[0] <= (in_op_type == HEAP_OP_DEQUE_MAX);
        reg_is_deque_min_s[0] <= (in_op_type == HEAP_OP_DEQUE_MIN);

        hbm_reg_op_type_s[0] <= in_op_type;
        hbm_reg_he_data_s[0] <= in_he_data;
        hbm_reg_priority_s[0] <= in_he_priority;
        hbm_reg_valid_s[0] <= (ready & in_valid);
        hbm_reg_is_enque_s[0] <= (in_op_type == HEAP_OP_ENQUE || in_op_type == HEAP_OP_SWAP_IN);
        hbm_reg_is_deque_max_s[0] <= (in_op_type == HEAP_OP_DEQUE_MAX);
        hbm_reg_is_deque_min_s[0] <= (in_op_type == HEAP_OP_DEQUE_MIN);

        // Register init signals
        fl_init_done_r <= fl_init_done;
        counter_l2_init_done_r <= counter_l2_init_done;
        
        fl_wraddress_counter_r <= fl_wraddress_counter_r + 1;
        counter_l2_wraddress_counter_r <= counter_l2_wraddress_counter_r + 1;

        // Register read signals
        pb_q_r <= pb_q;
        he_rden_r <= he_rden;
        np_rden_r <= np_rden;
        pp_rden_r <= pp_rden;
        he_rdaddress_r <= he_rdaddress;
        np_rdaddress_r <= np_rdaddress;
        pp_rdaddress_r <= pp_rdaddress;

        // Register write signals
        he_wren_r <= he_wren;
        np_wren_r <= np_wren;
        pp_wren_r <= pp_wren;
        he_wraddress_r <= he_wraddress;
        np_wraddress_r <= np_wraddress;
        pp_wraddress_r <= pp_wraddress;

        fl_q_r[0] <= fl_q;
        for (i = 0; i < 7; i = i + 1) begin
            fl_q_r[i + 1] <= fl_q_r[i];
        end

        // Register R/W conflict signals
        reg_pb_rdwr_conflict_r1 <= pb_rdwr_conflict;
        reg_pb_rdwr_conflict_r2 <= reg_pb_rdwr_conflict_r1;

        // Update FSM state
        state <= state_next;
        
        // HBM TODO LIST:
        
        /**
         * Stage 11: Spillover stage.
         */
        hbm_reg_valid_s[11] <= hbm_reg_valid_s[10];
        hbm_reg_he_data_s[11] <= hbm_reg_he_data_s[10];
        hbm_reg_op_type_s[11] <= hbm_reg_op_type_s[10];
        hbm_reg_is_enque_s[11] <= hbm_reg_is_enque_s[10];
        hbm_reg_priority_s[11] <= hbm_reg_priority_s[10];
        hbm_reg_is_deque_max_s[11] <= hbm_reg_is_deque_max_s[10];
        hbm_reg_is_deque_min_s[11] <= hbm_reg_is_deque_min_s[10];

        hbm_reg_pb_data_s11 <= hbm_reg_pb_data_s10;
        hbm_reg_l2_addr_s[11] <= hbm_reg_l2_addr_s[10];
        hbm_reg_op_color_s[11] <= hbm_reg_op_color_s[10];
        hbm_reg_l2_bitmap_s[11] <= hbm_reg_l2_bitmap_s[10];

        /**
         * Stage 10: Perform writes: update the priority bucket,
         * the free list, heap entries, next and prev pointers.
         */
        hbm_reg_valid_s[10] <= hbm_reg_valid_s[9];
        hbm_reg_he_data_s[10] <= hbm_he_data_s10;
        hbm_reg_op_type_s[10] <= hbm_reg_op_type_s[9];
        hbm_reg_is_enque_s[10] <= hbm_reg_is_enque_s[9];
        hbm_reg_priority_s[10] <= hbm_reg_priority_s[9];
        hbm_reg_is_deque_max_s[10] <= hbm_reg_is_deque_max_s[9];
        hbm_reg_is_deque_min_s[10] <= hbm_reg_is_deque_min_s[9];

        hbm_reg_he_data_s10 <= hbm_he_data;
        hbm_reg_np_data_s10 <= hbm_np_data;
        hbm_reg_pp_data_s10 <= hbm_pp_data;
        hbm_reg_pb_data_s10 <= hbm_int_pb_data;
        hbm_reg_l2_addr_s[10] <= hbm_reg_l2_addr_s[9];
        hbm_reg_op_color_s[10] <= hbm_reg_op_color_s[9];
        hbm_reg_l2_bitmap_s[10] <= hbm_reg_l2_bitmap_s[9];

        /**
         * Stage 9: Read delay for HE and pointers.
         */
        hbm_reg_valid_s[9] <= hbm_reg_valid_s[8];
        hbm_reg_he_data_s[9] <= hbm_reg_he_data_s[8];
        hbm_reg_op_type_s[9] <= hbm_reg_op_type_s[8];
        hbm_reg_is_enque_s[9] <= hbm_reg_is_enque_s[8];
        hbm_reg_priority_s[9] <= hbm_reg_priority_s[8];
        hbm_reg_is_deque_max_s[9] <= hbm_reg_is_deque_max_s[8];
        hbm_reg_is_deque_min_s[9] <= hbm_reg_is_deque_min_s[8];

        hbm_reg_l2_addr_s[9] <= hbm_reg_l2_addr_s[8];
        hbm_reg_op_color_s[9] <= hbm_reg_op_color_s[8];
        hbm_reg_l2_bitmap_s[9] <= hbm_reg_l2_bitmap_s[8];
        hbm_reg_pb_data_conflict_s9 <= hbm_reg_pb_data_conflict_s8;
        hbm_reg_pb_state_changes_s9 <= hbm_reg_pb_state_changes_s8;
        hbm_reg_pb_tail_pp_changes_s9 <= hbm_reg_pb_tail_pp_changes_s8;

        hbm_reg_he_q_s9 <= hbm_he_q_s9;
        hbm_reg_np_q_s9 <= hbm_np_q_s9;
        hbm_reg_pp_q_s9 <= hbm_pp_q_s9;

        hbm_reg_pb_q_s9 <= (
            hbm_reg_pb_addr_conflict_s9_s8 ?
               hbm_int_pb_data : hbm_reg_pb_q_s8);

        hbm_reg_pb_new_s9 <= (
            hbm_reg_pb_addr_conflict_s9_s8 ?
               hbm_int_pb_data : hbm_reg_pb_q_s8);

        if (hbm_reg_is_enque_s[8]) begin
            // PB becomes non-empty, update tail
            if (hbm_reg_pb_state_changes_s8) begin
                hbm_reg_pb_new_s9.tail <= hbm_fl_q_r[6];
            end
            hbm_reg_pb_new_s9.head <= hbm_fl_q_r[6];
        end

        /**
         * Stage 8: Read the heap entry and prev/next pointer
         * corresponding to the priority bucket to deque.
         */
        hbm_reg_valid_s[8] <= hbm_reg_valid_s[7];
        hbm_reg_he_data_s[8] <= hbm_reg_he_data_s[7];
        hbm_reg_op_type_s[8] <= hbm_reg_op_type_s[7];
        hbm_reg_is_enque_s[8] <= hbm_reg_is_enque_s[7];
        hbm_reg_priority_s[8] <= hbm_reg_priority_s[7];
        hbm_reg_is_deque_max_s[8] <= hbm_reg_is_deque_max_s[7];
        hbm_reg_is_deque_min_s[8] <= hbm_reg_is_deque_min_s[7];

        hbm_reg_pb_q_s8 <= hbm_int_pb_q;
        hbm_reg_l2_addr_s[8] <= hbm_reg_l2_addr_s[7];
        hbm_reg_op_color_s[8] <= hbm_reg_op_color_s[7];
        hbm_reg_l2_bitmap_s[8] <= hbm_reg_l2_bitmap_s[7];
        hbm_reg_pb_data_conflict_s8 <= hbm_reg_pb_data_conflict_s7;
        hbm_reg_pb_state_changes_s8 <= hbm_reg_pb_state_changes_s7;
        hbm_reg_pb_tail_pp_changes_s8 <= hbm_reg_pb_tail_pp_changes_s7;
        hbm_reg_pb_addr_conflict_s9_s8 <= hbm_reg_pb_addr_conflict_s8_s7;
        hbm_reg_pb_addr_conflict_s10_s8 <= hbm_reg_pb_addr_conflict_s9_s7;

        hbm_reg_pp_data_s8 <= hbm_pp_changes_s9_s8 ? hbm_fl_q_r[5] : hbm_fl_q_r[6];
        hbm_reg_pp_data_valid_s8 <= (hbm_pp_changes_s9_s8 || hbm_pp_changes_s10_s8);

        /**
         * Stage 7: Compute op color, read delay for PB.
         */
        hbm_reg_valid_s[7] <= hbm_reg_valid_s[6];
        hbm_reg_he_data_s[7] <= hbm_reg_he_data_s[6];
        hbm_reg_op_type_s[7] <= hbm_reg_op_type_s[6];
        hbm_reg_is_enque_s[7] <= hbm_reg_is_enque_s[6];
        hbm_reg_priority_s[7] <= hbm_reg_priority_s[6];
        hbm_reg_is_deque_max_s[7] <= hbm_reg_is_deque_max_s[6];
        hbm_reg_is_deque_min_s[7] <= hbm_reg_is_deque_min_s[6];

        hbm_reg_op_color_s[7] <= hbm_op_color_s7;
        hbm_reg_l2_addr_s[7] <= hbm_reg_l2_addr_s[6];
        hbm_reg_l2_bitmap_s[7] <= hbm_reg_l2_bitmap_s[6];
        hbm_reg_pb_update_s7 <= hbm_reg_pb_addr_conflict_s9_s6;
        hbm_reg_pb_addr_conflict_s8_s7 <= hbm_reg_pb_addr_conflict_s7_s6;
        hbm_reg_pb_addr_conflict_s9_s7 <= hbm_reg_pb_addr_conflict_s8_s6;

        // Determine if this op is going to result in PB data
        // conflict (dequeing a PB immediately after an enque
        // operation that causes it to become non-empty).
        hbm_reg_pb_data_conflict_s7 <= (hbm_reg_is_enque_s[7] &&
            !hbm_reg_l2_counter_non_zero_s6 && hbm_reg_pb_addr_conflict_s7_s6);

        // Determine if this op causes the PB state to change.
        // Change of state is defined differently based on op:
        // for enques, corresponds to a PB becoming non-empty,
        // and for deques, corresponds to a PB becoming empty.
        hbm_reg_pb_state_changes_s7 <= (hbm_reg_is_enque_s[6] ?
            (!hbm_reg_l2_counter_s6[WATERLEVEL_IDX] && hbm_reg_l2_counter_s6[0]) :
            (!hbm_reg_l2_counter_s6[WATERLEVEL_IDX] && !hbm_reg_l2_counter_s6[0]));

        // Determine if this op causes the previous pointer
        // corresponding to the PB tail to change. High iff
        // enqueing into a PB containing a single element.
        hbm_reg_pb_tail_pp_changes_s7 <= (hbm_reg_is_enque_s[6] &&
            !hbm_reg_old_l2_counter_s6[WATERLEVEL_IDX]
            && hbm_reg_old_l2_counter_s6[0]);

        /**
         * Stage 6: Write-back the L2 counter and bitmap,
         * and read the corresponding PB (head and tail).
         */
        hbm_reg_valid_s[6] <= hbm_reg_valid_s[5];
        hbm_reg_he_data_s[6] <= hbm_reg_he_data_s[5];
        hbm_reg_op_type_s[6] <= hbm_reg_op_type_s[5];
        hbm_reg_is_enque_s[6] <= hbm_reg_is_enque_s[5];
        hbm_reg_priority_s[6] <= hbm_priority_s6;
        hbm_reg_is_deque_max_s[6] <= hbm_reg_is_deque_max_s[5];
        hbm_reg_is_deque_min_s[6] <= hbm_reg_is_deque_min_s[5];

        hbm_reg_l2_bitmap_s[6] <= hbm_l2_bitmap_s6;
        hbm_reg_l2_addr_s[6] <= hbm_reg_l2_addr_s[5];

        hbm_reg_l2_counter_s6 <= hbm_l2_counter_s6;
        hbm_reg_l2_bitmap_idx_s6 <= hbm_reg_l2_bitmap_idx_s5;
        hbm_reg_old_l2_counter_s6 <= hbm_reg_l2_counter_rc_s5;
        hbm_reg_l2_counter_non_zero_s6 <= hbm_l2_counter_non_zero_s6;

        hbm_reg_pb_addr_conflict_s7_s6 <= hbm_pb_addr_conflict_s7_s6;
        hbm_reg_pb_addr_conflict_s8_s6 <= hbm_pb_addr_conflict_s8_s6;
        hbm_reg_pb_addr_conflict_s9_s6 <= hbm_pb_addr_conflict_s9_s6;
        hbm_reg_pb_addr_conflict_s10_s6 <= hbm_pb_addr_conflict_s10_s6;

        // Write-back L2 bitmap
        if (hbm_reg_valid_s[5]) begin
            hbm_l2_bitmaps[hbm_reg_l2_addr_s[5]] <= hbm_l2_bitmap_s6;
        end

        /**
         * Stage 5: NOOP, read delay for L2 counter.
         */
        hbm_reg_valid_s[5] <= hbm_reg_valid_s[4];
        hbm_reg_he_data_s[5] <= hbm_reg_he_data_s[4];
        hbm_reg_op_type_s[5] <= hbm_reg_op_type_s[4];
        hbm_reg_is_enque_s[5] <= hbm_reg_is_enque_s[4];
        hbm_reg_priority_s[5] <= hbm_reg_priority_s[4];
        hbm_reg_is_deque_max_s[5] <= hbm_reg_is_deque_max_s[4];
        hbm_reg_is_deque_min_s[5] <= hbm_reg_is_deque_min_s[4];

        hbm_reg_l2_addr_s[5] <= hbm_reg_l2_addr_s[4];
        hbm_reg_l2_addr_conflict_s6_s5 <= hbm_reg_l2_addr_conflict_s5_s4;
        hbm_reg_l2_addr_conflict_s7_s5 <= hbm_reg_l2_addr_conflict_s6_s4;
        hbm_reg_l2_addr_conflict_s8_s5 <= hbm_reg_l2_addr_conflict_s7_s4;
        hbm_reg_l2_addr_conflict_s9_s5 <= hbm_reg_l2_addr_conflict_s8_s4;

        hbm_reg_l2_counter_s5 <= (hbm_reg_l2_counter_rdvalid_r1_s4 ?
                              hbm_l2_counter_q_s5 : hbm_l2_counter_s5);
        case (hbm_rcd_s5)
        HBM_READ_CARRY_DOWN: begin
            hbm_reg_l2_bitmap_idx_s5 <= hbm_reg_l2_bitmap_idx_s4;
            hbm_reg_l2_bitmap_postop_s5 <= hbm_reg_l2_bitmap_postop_s4;
            hbm_reg_l2_bitmap_idx_onehot_s5 <= hbm_reg_l2_bitmap_idx_onehot_s4;

            hbm_reg_l2_counter_rc_s5 <= (hbm_reg_l2_counter_rdvalid_r1_s4 ?
                                     hbm_l2_counter_q_s5 : hbm_l2_counter_s5);
        end
        HBM_READ_CARRY_RIGHT: begin
            hbm_reg_l2_counter_rc_s5 <= hbm_l2_counter_s6;
        end
        default: ;
        endcase

        // Forward L2 bitmap updates
        hbm_reg_l2_bitmap_s[5] <= (
            hbm_reg_l2_addr_conflict_s5_s4 ?
            hbm_l2_bitmap_s6 : hbm_reg_l2_bitmap_s[4]);

        /**
         * Stage 4: Compute the L2 bitmap index and postop
         * bitmap, and read the corresponding L2 counter.
         */
        hbm_reg_valid_s[4] <= hbm_reg_valid_s[3];
        hbm_reg_he_data_s[4] <= hbm_reg_he_data_s[3];
        hbm_reg_op_type_s[4] <= hbm_reg_op_type_s[3];
        hbm_reg_is_enque_s[4] <= hbm_reg_is_enque_s[3];
        hbm_reg_priority_s[4] <= hbm_reg_priority_s[3];
        hbm_reg_is_deque_max_s[4] <= hbm_reg_is_deque_max_s[3];
        hbm_reg_is_deque_min_s[4] <= hbm_reg_is_deque_min_s[3];

        hbm_reg_l2_addr_s[4] <= hbm_reg_l2_addr_s[3];
        hbm_reg_l2_addr_conflict_s5_s4 <= hbm_reg_l2_addr_conflict_s4_s3;
        hbm_reg_l2_addr_conflict_s6_s4 <= hbm_reg_l2_addr_conflict_s5_s3;
        hbm_reg_l2_addr_conflict_s7_s4 <= hbm_reg_l2_addr_conflict_s6_s3;
        hbm_reg_l2_addr_conflict_s8_s4 <= hbm_reg_l2_addr_conflict_s7_s3;

        hbm_reg_l2_counter_rdvalid_r1_s4 <= 0;

        case (hbm_rcd_s4)
        HBM_READ_CARRY_DOWN: begin
            hbm_reg_l2_bitmap_idx_s4 <= hbm_l2_bitmap_idx_s4;
            hbm_reg_l2_bitmap_empty_s4 <= hbm_l2_bitmap_empty_s4;
            hbm_reg_l2_bitmap_postop_s4 <= hbm_l2_bitmap_postop_s4;
            hbm_reg_l2_bitmap_idx_onehot_s4 <= hbm_l2_bitmap_idx_onehot_s4;

            hbm_reg_l2_counter_rdvalid_r1_s4 <= (!hbm_l2_bitmap_empty_s4);
        end
        HBM_READ_CARRY_UP: begin
            hbm_reg_l2_bitmap_empty_s4 <= 0;
            hbm_reg_l2_bitmap_idx_s4 <= hbm_reg_l2_bitmap_idx_s5;
            hbm_reg_l2_bitmap_idx_onehot_s4 <= hbm_reg_l2_bitmap_idx_onehot_s5;

            if (!hbm_reg_l2_addr_conflict_s4_s3) begin
                hbm_reg_l2_bitmap_postop_s4 <= (
                    hbm_reg_l2_bitmap_postop_s5);
            end
        end
        default: ;
        endcase

        // Forward L2 bitmap updates
        hbm_reg_l2_bitmap_s[4] <= (
            hbm_reg_l2_addr_conflict_s5_s3 ?
            hbm_l2_bitmap_s6 : hbm_reg_l2_bitmap_s[3]);

        /**
         * Stage 3: Write-back the L1 counter and bitmap,
         * and read the corresponding L2 bitmap.
         */
        hbm_reg_valid_s[3] <= hbm_reg_valid_s[2];
        hbm_reg_he_data_s[3] <= hbm_reg_he_data_s[2];
        hbm_reg_op_type_s[3] <= hbm_reg_op_type_s[2];
        hbm_reg_is_enque_s[3] <= hbm_reg_is_enque_s[2];
        hbm_reg_priority_s[3] <= hbm_reg_priority_s[2];
        hbm_reg_is_deque_max_s[3] <= hbm_reg_is_deque_max_s[2];
        hbm_reg_is_deque_min_s[3] <= hbm_reg_is_deque_min_s[2];

        hbm_reg_l2_addr_s[3] <= hbm_reg_l1_bitmap_idx_s2;

        hbm_reg_l1_counter_s3 <= hbm_l1_counter_s3;
        hbm_reg_l2_addr_conflict_s4_s3 <= hbm_l2_addr_conflict_s4_s3;
        hbm_reg_l2_addr_conflict_s5_s3 <= hbm_l2_addr_conflict_s5_s3;
        hbm_reg_l2_addr_conflict_s6_s3 <= hbm_l2_addr_conflict_s6_s3;
        hbm_reg_l2_addr_conflict_s7_s3 <= hbm_l2_addr_conflict_s7_s3;

        // Write-back L1 bitmap and counter
        if (hbm_reg_valid_s[2]) begin
            hbm_l1_bitmap <= hbm_l1_bitmap_s3;
            hbm_l1_counters[hbm_reg_l1_bitmap_idx_s2] <= hbm_l1_counter_s3;
        end

        // Forward L2 bitmap updates
        hbm_reg_l2_bitmap_s[3] <= (
            hbm_l2_addr_conflict_s6_s3 ?
            hbm_l2_bitmap_s6 : hbm_l2_bitmaps[hbm_reg_l1_bitmap_idx_s2]);

        /**
         * Stage 2: Compute the L1 bitmap index and postop
         * bitmap, and read the corresponding L1 counter.
         */
        hbm_reg_valid_s[2] <= hbm_reg_valid_s[1];
        hbm_reg_he_data_s[2] <= hbm_reg_he_data_s[1];
        hbm_reg_op_type_s[2] <= hbm_reg_op_type_s[1];
        hbm_reg_is_enque_s[2] <= hbm_reg_is_enque_s[1];
        hbm_reg_priority_s[2] <= hbm_reg_priority_s[1];
        hbm_reg_is_deque_max_s[2] <= hbm_reg_is_deque_max_s[1];
        hbm_reg_is_deque_min_s[2] <= hbm_reg_is_deque_min_s[1];

        hbm_reg_l1_bitmap_empty_s2 <= 0;

        case (hbm_rcd_s2)
        HBM_READ_CARRY_DOWN: begin
            hbm_reg_l1_bitmap_idx_s2 <= hbm_l1_bitmap_idx_s2;
            hbm_reg_l1_bitmap_empty_s2 <= hbm_l1_bitmap_empty_s2;
            hbm_reg_l1_bitmap_postop_s2 <= hbm_l1_bitmap_postop_s2;
            hbm_reg_l1_bitmap_idx_onehot_s2 <= hbm_l1_bitmap_idx_onehot_s2;

            hbm_reg_l1_counter_s2 <= (
                (hbm_reg_valid_s[2] &&
                    (hbm_l1_bitmap_idx_s2 == hbm_reg_l1_bitmap_idx_s2)) ?
                    hbm_l1_counter_s3 : hbm_l1_counters[hbm_l1_bitmap_idx_s2]);
        end
        HBM_READ_CARRY_RIGHT: begin
            hbm_reg_l1_counter_s2 <= hbm_l1_counter_s3;
        end
        default: ;
        endcase

        /**
         * Stage 1: Determine operation validity. Disables the pipeline
         * stage if the BBQ is empty (deques) or FL is empty (enqueues).
         */
        hbm_reg_valid_s[1] <= hbm_valid_s1;
        hbm_reg_he_data_s[1] <= hbm_reg_he_data_s[0];
        hbm_reg_op_type_s[1] <= hbm_reg_op_type_s[0];
        hbm_reg_is_enque_s[1] <= hbm_reg_is_enque_s[0];
        hbm_reg_priority_s[1] <= hbm_reg_priority_s[0];
        hbm_reg_is_deque_max_s[1] <= hbm_reg_is_deque_max_s[0];
        hbm_reg_is_deque_min_s[1] <= hbm_reg_is_deque_min_s[0];

        hbm_reg_old_occupancy_s1 <= hbm_old_occupancy_s1;
        hbm_reg_new_occupancy_s1 <= hbm_new_occupancy_s1;

        if (hbm_valid_s1) begin
            hbm_occupancy <= hbm_new_occupancy_s1;
        end

        // Register init signals
        hbm_fl_init_done_r <= hbm_fl_init_done;
        hbm_counter_l2_init_done_r <= hbm_counter_l2_init_done;
        
        hbm_fl_wraddress_counter_r <= hbm_fl_wraddress_counter_r + 1;
        hbm_counter_l2_wraddress_counter_r <= hbm_counter_l2_wraddress_counter_r + 1;

        // Register read signals
        hbm_pb_q_r <= hbm_pb_q;
        hbm_he_rden_r <= hbm_he_rden;
        hbm_np_rden_r <= hbm_np_rden;
        hbm_pp_rden_r <= hbm_pp_rden;
        hbm_he_rdaddress_r <= hbm_he_rdaddress;
        hbm_np_rdaddress_r <= hbm_np_rdaddress;
        hbm_pp_rdaddress_r <= hbm_pp_rdaddress;

        // Register write signals
        hbm_he_wren_r <= hbm_he_wren;
        hbm_np_wren_r <= hbm_np_wren;
        hbm_pp_wren_r <= hbm_pp_wren;
        hbm_he_wraddress_r <= hbm_he_wraddress;
        hbm_np_wraddress_r <= hbm_np_wraddress;
        hbm_pp_wraddress_r <= hbm_pp_wraddress;

        hbm_fl_q_r[0] <= hbm_fl_q;
        for (i = 0; i < 7; i = i + 1) begin
            hbm_fl_q_r[i + 1] <= hbm_fl_q_r[i];
        end

        // Register R/W conflict signals
        hbm_reg_pb_rdwr_conflict_r1 <= hbm_pb_rdwr_conflict;
        hbm_reg_pb_rdwr_conflict_r2 <= hbm_reg_pb_rdwr_conflict_r1;

    end
end

// SRAM buffer-management structures
themis_simple_sync_fifo #(
    .DATA_WIDTH(HEAP_ENTRY_AWIDTH),
    .DEPTH(HEAP_MAX_NUM_ENTRIES)
)
free_list (
    .clk(clk),
    .din(fl_data),
    .rd_en(fl_rdreq),
    .wr_en(fl_wrreq),
    .empty(fl_empty),
    .full(),
    .dout(fl_q)
);

// Heap entries
themis_simple_tdp_ram #(
    .DATA_WIDTH(HEAP_ENTRY_DWIDTH),
    .ADDR_WIDTH(HEAP_ENTRY_AWIDTH)
)
heap_entries (
    .clka(clk),
    .clkb(clk),
    .dina(he_data),
    .wea(he_wren),
    .addrb(he_rdaddress),
    .addra(he_wraddress),
    .doutb(he_q)
);

// Next pointers
themis_simple_tdp_ram #(
    .DATA_WIDTH(HEAP_ENTRY_AWIDTH),
    .ADDR_WIDTH(HEAP_ENTRY_AWIDTH)
)
next_pointers (
    .clka(clk),
    .clkb(clk),
    .dina(np_data),
    .wea(np_wren),
    .addrb(np_rdaddress),
    .addra(np_wraddress),
    .doutb(np_q)
);

// Previous pointers
themis_simple_tdp_ram #(
    .DATA_WIDTH(HEAP_ENTRY_AWIDTH),
    .ADDR_WIDTH(HEAP_ENTRY_AWIDTH)
)
previous_pointers (
    .clka(clk),
    .clkb(clk),
    .dina(pp_data),
    .wea(pp_wren),
    .addrb(pp_rdaddress),
    .addra(pp_wraddress),
    .doutb(pp_q)
);

// Priority buckets
themis_simple_tdp_ram #(
    .DATA_WIDTH(LIST_T_WIDTH),
    .ADDR_WIDTH(HEAP_PRIORITY_BUCKETS_AWIDTH)
)
priority_buckets (
    .clka(clk),
    .clkb(clk),
    .dina(pb_data),
    .wea(pb_wren),
    .addrb(pb_rdaddress),
    .addra(pb_wraddress),
    .doutb(pb_q)
);

// L2 counters
themis_simple_tdp_ram #(
    .DATA_WIDTH(COUNTER_T_WIDTH),
    .ADDR_WIDTH(COUNTER_L2_AWIDTH)
)
counters_l2 (
    .clka(clk),
    .clkb(clk),
    .dina(counter_l2_data),
    .wea(counter_l2_wren),
    .addrb(counter_l2_rdaddress),
    .addra(counter_l2_wraddress),
    .doutb(counter_l2_q)
);

// HBM buffer-management structures
themis_simple_sync_fifo #(
    .DATA_WIDTH(HEAP_ENTRY_AWIDTH),
    .DEPTH(HEAP_MAX_NUM_ENTRIES)
)
hbm_free_list (
    .clk(clk),
    .din(hbm_fl_data),
    .rd_en(hbm_fl_rdreq),
    .wr_en(hbm_fl_wrreq),
    .empty(hbm_fl_empty),
    .full(),
    .dout(hbm_fl_q)
);

// Heap entries. The public resource-evaluation release uses a generic
// storage model here so the core can be elaborated without board IP.
themis_simple_tdp_ram #(
    .DATA_WIDTH(HEAP_ENTRY_DWIDTH),
    .ADDR_WIDTH(HEAP_ENTRY_AWIDTH)
)
hbm_heap_entries (
    .clka(clk),
    .clkb(clk),
    .dina(hbm_he_data),
    .wea(hbm_he_wren),
    .addrb(hbm_he_rdaddress),
    .addra(hbm_he_wraddress),
    .doutb(hbm_he_q)
);

// Next pointers
themis_simple_tdp_ram #(
    .DATA_WIDTH(HEAP_ENTRY_AWIDTH),
    .ADDR_WIDTH(HEAP_ENTRY_AWIDTH)
)
hbm_next_pointers (
    .clka(clk),
    .clkb(clk),
    .dina(hbm_np_data),
    .wea(hbm_np_wren),
    .addrb(hbm_np_rdaddress),
    .addra(hbm_np_wraddress),
    .doutb(hbm_np_q)
);

// Previous pointers
themis_simple_tdp_ram #(
    .DATA_WIDTH(HEAP_ENTRY_AWIDTH),
    .ADDR_WIDTH(HEAP_ENTRY_AWIDTH)
)
hbm_previous_pointers (
    .clka(clk),
    .clkb(clk),
    .dina(hbm_pp_data),
    .wea(hbm_pp_wren),
    .addrb(hbm_pp_rdaddress),
    .addra(hbm_pp_wraddress),
    .doutb(hbm_pp_q)
);

// Priority buckets
themis_simple_tdp_ram #(
    .DATA_WIDTH(LIST_T_WIDTH),
    .ADDR_WIDTH(HEAP_PRIORITY_BUCKETS_AWIDTH)
)
hbm_priority_buckets (
    .clka(clk),
    .clkb(clk),
    .dina(hbm_pb_data),
    .wea(hbm_pb_wren),
    .addrb(hbm_pb_rdaddress),
    .addra(hbm_pb_wraddress),
    .doutb(hbm_pb_q)
);

// L2 counters
themis_simple_tdp_ram #(
    .DATA_WIDTH(COUNTER_T_WIDTH),
    .ADDR_WIDTH(COUNTER_L2_AWIDTH)
)
hbm_counters_l2 (
    .clka(clk),
    .clkb(clk),
    .dina(hbm_counter_l2_data),
    .wea(hbm_counter_l2_wren),
    .addrb(hbm_counter_l2_rdaddress),
    .addra(hbm_counter_l2_wraddress),
    .doutb(hbm_counter_l2_q)
);

//SRAM FFSs
// L1 FFSs
ffs #(
    .WIDTH_LOG(HEAP_LOG_BITMAP_WIDTH)
)
ffs_l1_inst0 (
    .x(l1_bitmap),
    .msb(ffs_l1_inst_msb[0]),
    .lsb(ffs_l1_inst_lsb[0]),
    .msb_onehot(ffs_l1_inst_msb_onehot[0]),
    .lsb_onehot(ffs_l1_inst_lsb_onehot[0]),
    .zero(ffs_l1_inst_zero[0])
);

ffs #(
    .WIDTH_LOG(HEAP_LOG_BITMAP_WIDTH)
)
ffs_l1_inst1 (
    .x(reg_l1_bitmap_postop_s2),
    .msb(ffs_l1_inst_msb[1]),
    .lsb(ffs_l1_inst_lsb[1]),
    .msb_onehot(ffs_l1_inst_msb_onehot[1]),
    .lsb_onehot(ffs_l1_inst_lsb_onehot[1]),
    .zero(ffs_l1_inst_zero[1])
);

// L2 FFSs
ffs #(
    .WIDTH_LOG(HEAP_LOG_BITMAP_WIDTH)
)
ffs_l2_inst0 (
    .x(reg_l2_bitmap_s[3]),
    .msb(ffs_l2_inst_msb[0]),
    .lsb(ffs_l2_inst_lsb[0]),
    .msb_onehot(ffs_l2_inst_msb_onehot[0]),
    .lsb_onehot(ffs_l2_inst_lsb_onehot[0]),
    .zero(ffs_l2_inst_zero[0])
);

ffs #(
    .WIDTH_LOG(HEAP_LOG_BITMAP_WIDTH)
)
ffs_l2_inst1 (
    .x(reg_l2_bitmap_postop_s4),
    .msb(ffs_l2_inst_msb[1]),
    .lsb(ffs_l2_inst_lsb[1]),
    .msb_onehot(ffs_l2_inst_msb_onehot[1]),
    .lsb_onehot(ffs_l2_inst_lsb_onehot[1]),
    .zero(ffs_l2_inst_zero[1])
);

ffs #(
    .WIDTH_LOG(HEAP_LOG_BITMAP_WIDTH)
)
ffs_l2_inst2 (
    .x(reg_l2_bitmap_postop_s5),
    .msb(ffs_l2_inst_msb[2]),
    .lsb(ffs_l2_inst_lsb[2]),
    .msb_onehot(ffs_l2_inst_msb_onehot[2]),
    .lsb_onehot(ffs_l2_inst_lsb_onehot[2]),
    .zero(ffs_l2_inst_zero[2])
);

//HBM FFSs
// L1 FFSs
ffs #(
    .WIDTH_LOG(HEAP_LOG_BITMAP_WIDTH)
)
hbm_ffs_l1_inst0 (
    .x(hbm_l1_bitmap),
    .msb(hbm_ffs_l1_inst_msb[0]),
    .lsb(hbm_ffs_l1_inst_lsb[0]),
    .msb_onehot(hbm_ffs_l1_inst_msb_onehot[0]),
    .lsb_onehot(hbm_ffs_l1_inst_lsb_onehot[0]),
    .zero(hbm_ffs_l1_inst_zero[0])
);

ffs #(
    .WIDTH_LOG(HEAP_LOG_BITMAP_WIDTH)
)
hbm_ffs_l1_inst1 (
    .x(hbm_reg_l1_bitmap_postop_s2),
    .msb(hbm_ffs_l1_inst_msb[1]),
    .lsb(hbm_ffs_l1_inst_lsb[1]),
    .msb_onehot(hbm_ffs_l1_inst_msb_onehot[1]),
    .lsb_onehot(hbm_ffs_l1_inst_lsb_onehot[1]),
    .zero(hbm_ffs_l1_inst_zero[1])
);

// L2 FFSs
ffs #(
    .WIDTH_LOG(HEAP_LOG_BITMAP_WIDTH)
)
hbm_ffs_l2_inst0 (
    .x(hbm_reg_l2_bitmap_s[3]),
    .msb(hbm_ffs_l2_inst_msb[0]),
    .lsb(hbm_ffs_l2_inst_lsb[0]),
    .msb_onehot(hbm_ffs_l2_inst_msb_onehot[0]),
    .lsb_onehot(hbm_ffs_l2_inst_lsb_onehot[0]),
    .zero(hbm_ffs_l2_inst_zero[0])
);

ffs #(
    .WIDTH_LOG(HEAP_LOG_BITMAP_WIDTH)
)
hbm_ffs_l2_inst1 (
    .x(hbm_reg_l2_bitmap_postop_s4),
    .msb(hbm_ffs_l2_inst_msb[1]),
    .lsb(hbm_ffs_l2_inst_lsb[1]),
    .msb_onehot(hbm_ffs_l2_inst_msb_onehot[1]),
    .lsb_onehot(hbm_ffs_l2_inst_lsb_onehot[1]),
    .zero(hbm_ffs_l2_inst_zero[1])
);

ffs #(
    .WIDTH_LOG(HEAP_LOG_BITMAP_WIDTH)
)
hbm_ffs_l2_inst2 (
    .x(hbm_reg_l2_bitmap_postop_s5),
    .msb(hbm_ffs_l2_inst_msb[2]),
    .lsb(hbm_ffs_l2_inst_lsb[2]),
    .msb_onehot(hbm_ffs_l2_inst_msb_onehot[2]),
    .lsb_onehot(hbm_ffs_l2_inst_lsb_onehot[2]),
    .zero(hbm_ffs_l2_inst_zero[2])
);

endmodule
