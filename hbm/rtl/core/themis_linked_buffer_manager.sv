`timescale 1ns / 1ps

import heap_ops::*;

module themis_linked_buffer_manager #(
    parameter int DATA_WIDTH = 512,
    parameter int KEEP_WIDTH = (DATA_WIDTH / 8),
    parameter int CELL_PTR_WIDTH = 10,
    parameter int HEAP_BITMAP_WIDTH = 32,
    parameter int HEAP_MAX_NUM_ENTRIES = ((1 << 10) - 1),
    localparam int HEAP_NUM_LEVELS = 2,
    localparam int HEAP_NUM_PRIORITIES = (HEAP_BITMAP_WIDTH ** HEAP_NUM_LEVELS),
    localparam int HEAP_PRIORITY_WIDTH = $clog2(HEAP_NUM_PRIORITIES),
    localparam int CELL_COUNT = (1 << CELL_PTR_WIDTH),
    localparam int CELL_DESC_WIDTH = (1 + KEEP_WIDTH + DATA_WIDTH)
) (
    input  logic                           clk,
    input  logic                           rst,

    input  logic [DATA_WIDTH-1:0]          s_axis_pkt_tdata,
    input  logic                           s_axis_pkt_tvalid,
    input  logic                           s_axis_pkt_tlast,
    input  logic [KEEP_WIDTH-1:0]          s_axis_pkt_tkeep,
    input  logic [HEAP_PRIORITY_WIDTH-1:0] s_axis_pkt_rank,
    output logic                           s_axis_pkt_tready,

    output logic [DATA_WIDTH-1:0]          m_axis_pkt_tdata,
    output logic                           m_axis_pkt_tvalid,
    output logic                           m_axis_pkt_tlast,
    output logic [KEEP_WIDTH-1:0]          m_axis_pkt_tkeep,
    input  logic                           m_axis_pkt_tready,

    output logic                           bbq_ready,
    output logic [31:0]                    dbg_free_cells,
    output logic [31:0]                    dbg_queued_packets,
    output logic [31:0]                    dbg_completed_packets
);

typedef enum logic [1:0] {
    DRAIN_IDLE,
    DRAIN_READ_WAIT,
    DRAIN_SEND
} drain_state_t;

logic bbq_in_valid;
heap_op_t bbq_in_op_type;
logic [CELL_PTR_WIDTH-1:0] bbq_in_he_data;
logic [HEAP_PRIORITY_WIDTH-1:0] bbq_in_he_priority;

logic bbq_out_valid;
heap_op_t bbq_out_op_type;
logic [CELL_PTR_WIDTH-1:0] bbq_out_he_data;
logic [HEAP_PRIORITY_WIDTH-1:0] bbq_out_he_priority;

logic cell_data_we;
logic [CELL_PTR_WIDTH-1:0] cell_data_addra;
logic [CELL_PTR_WIDTH-1:0] cell_data_addrb;
logic [CELL_DESC_WIDTH-1:0] cell_data_dina;
logic [CELL_DESC_WIDTH-1:0] cell_data_doutb;

logic next_ptr_we;
logic [CELL_PTR_WIDTH-1:0] next_ptr_addra;
logic [CELL_PTR_WIDTH-1:0] next_ptr_addrb;
logic [CELL_PTR_WIDTH-1:0] next_ptr_dina;
logic [CELL_PTR_WIDTH-1:0] next_ptr_doutb;

logic [CELL_PTR_WIDTH-1:0] free_list_mem[0:CELL_COUNT-1];
logic [CELL_PTR_WIDTH:0] fl_rd_ptr;
logic [CELL_PTR_WIDTH:0] fl_wr_ptr;
logic [CELL_PTR_WIDTH:0] free_count;

logic ingress_packet_open;
logic [CELL_PTR_WIDTH-1:0] ingress_head_ptr;
logic [CELL_PTR_WIDTH-1:0] ingress_tail_ptr;
logic [HEAP_PRIORITY_WIDTH-1:0] ingress_rank;

logic pending_enqueue_valid;
logic [CELL_PTR_WIDTH-1:0] pending_enqueue_head;
logic [HEAP_PRIORITY_WIDTH-1:0] pending_enqueue_rank;

logic bbq_deq_inflight;
logic [31:0] queued_packet_count;
logic [31:0] completed_packet_count;

drain_state_t drain_state;
logic [CELL_PTR_WIDTH-1:0] drain_curr_ptr;
logic [CELL_PTR_WIDTH-1:0] drain_next_ptr;
logic [DATA_WIDTH-1:0] drain_data_reg;
logic [KEEP_WIDTH-1:0] drain_keep_reg;
logic drain_last_reg;

assign s_axis_pkt_tready = bbq_ready && (free_count != 0);
assign m_axis_pkt_tvalid = (drain_state == DRAIN_SEND);
assign m_axis_pkt_tdata = drain_data_reg;
assign m_axis_pkt_tkeep = drain_keep_reg;
assign m_axis_pkt_tlast = drain_last_reg;

assign dbg_free_cells = free_count;
assign dbg_queued_packets = queued_packet_count;
assign dbg_completed_packets = completed_packet_count;

themis_simple_tdp_ram #(
    .DATA_WIDTH(CELL_DESC_WIDTH),
    .ADDR_WIDTH(CELL_PTR_WIDTH)
) cell_data_mem (
    .clka(clk),
    .clkb(clk),
    .dina(cell_data_dina),
    .wea(cell_data_we),
    .addrb(cell_data_addrb),
    .addra(cell_data_addra),
    .doutb(cell_data_doutb)
);

themis_simple_tdp_ram #(
    .DATA_WIDTH(CELL_PTR_WIDTH),
    .ADDR_WIDTH(CELL_PTR_WIDTH)
) cell_next_mem (
    .clka(clk),
    .clkb(clk),
    .dina(next_ptr_dina),
    .wea(next_ptr_we),
    .addrb(next_ptr_addrb),
    .addra(next_ptr_addra),
    .doutb(next_ptr_doutb)
);

bbq #(
    .HEAP_BITMAP_WIDTH(HEAP_BITMAP_WIDTH),
    .HEAP_ENTRY_DWIDTH(CELL_PTR_WIDTH),
    .HEAP_MAX_NUM_ENTRIES(HEAP_MAX_NUM_ENTRIES)
) bbq_inst (
    .clk(clk),
    .rst(rst),
    .axi_clk(clk),
    .hbm_ref(clk),
    .apb_clk(clk),
    .locked(!rst),
    .ready(bbq_ready),
    .in_valid(bbq_in_valid),
    .in_op_type(bbq_in_op_type),
    .in_he_data(bbq_in_he_data),
    .in_he_priority(bbq_in_he_priority),
    .out_valid(bbq_out_valid),
    .out_op_type(bbq_out_op_type),
    .out_he_data(bbq_out_he_data),
    .out_he_priority(bbq_out_he_priority)
);

integer idx;
initial begin
    for (idx = 0; idx < CELL_COUNT; idx = idx + 1) begin
        free_list_mem[idx] = idx[CELL_PTR_WIDTH-1:0];
    end
end

always_ff @(posedge clk) begin
    logic alloc_fire;
    logic free_fire;
    logic issue_enqueue;
    logic issue_dequeue;
    logic [CELL_PTR_WIDTH-1:0] alloc_ptr;
    logic [CELL_PTR_WIDTH-1:0] free_ptr;
    logic [31:0] next_queued_packets;
    logic [31:0] next_completed_packets;

    alloc_fire = 1'b0;
    free_fire = 1'b0;
    issue_enqueue = 1'b0;
    issue_dequeue = 1'b0;
    alloc_ptr = free_list_mem[fl_rd_ptr[CELL_PTR_WIDTH-1:0]];
    free_ptr = '0;
    next_queued_packets = queued_packet_count;
    next_completed_packets = completed_packet_count;

    cell_data_we <= 1'b0;
    next_ptr_we <= 1'b0;
    bbq_in_valid <= 1'b0;
    bbq_in_op_type <= HEAP_OP_ENQUE;
    bbq_in_he_data <= '0;
    bbq_in_he_priority <= '0;

    if (rst) begin
        fl_rd_ptr <= '0;
        fl_wr_ptr <= '0;
        free_count <= CELL_COUNT;

        ingress_packet_open <= 1'b0;
        ingress_head_ptr <= '0;
        ingress_tail_ptr <= '0;
        ingress_rank <= '0;

        pending_enqueue_valid <= 1'b0;
        pending_enqueue_head <= '0;
        pending_enqueue_rank <= '0;

        queued_packet_count <= '0;
        completed_packet_count <= '0;
        bbq_deq_inflight <= 1'b0;

        drain_state <= DRAIN_IDLE;
        drain_curr_ptr <= '0;
        drain_next_ptr <= '0;
        drain_data_reg <= '0;
        drain_keep_reg <= '0;
        drain_last_reg <= 1'b0;

        cell_data_addra <= '0;
        cell_data_addrb <= '0;
        cell_data_dina <= '0;
        next_ptr_addra <= '0;
        next_ptr_addrb <= '0;
        next_ptr_dina <= '0;
    end
    else begin
        if (s_axis_pkt_tvalid && s_axis_pkt_tready) begin
            alloc_fire = 1'b1;

            cell_data_we <= 1'b1;
            cell_data_addra <= alloc_ptr;
            cell_data_dina <= {s_axis_pkt_tlast, s_axis_pkt_tkeep, s_axis_pkt_tdata};

            if (!ingress_packet_open) begin
                ingress_packet_open <= !s_axis_pkt_tlast;
                ingress_head_ptr <= alloc_ptr;
                ingress_tail_ptr <= alloc_ptr;
                ingress_rank <= s_axis_pkt_rank;

                if (s_axis_pkt_tlast) begin
                    pending_enqueue_valid <= 1'b1;
                    pending_enqueue_head <= alloc_ptr;
                    pending_enqueue_rank <= s_axis_pkt_rank;
                end
            end
            else begin
                next_ptr_we <= 1'b1;
                next_ptr_addra <= ingress_tail_ptr;
                next_ptr_dina <= alloc_ptr;
                ingress_tail_ptr <= alloc_ptr;

                if (s_axis_pkt_tlast) begin
                    ingress_packet_open <= 1'b0;
                    pending_enqueue_valid <= 1'b1;
                    pending_enqueue_head <= ingress_head_ptr;
                    pending_enqueue_rank <= ingress_rank;
                end
            end
        end

        if (bbq_out_valid && (bbq_out_op_type == HEAP_OP_DEQUE_MIN)) begin
            bbq_deq_inflight <= 1'b0;
            next_queued_packets = next_queued_packets - 1'b1;

            drain_curr_ptr <= bbq_out_he_data;
            cell_data_addrb <= bbq_out_he_data;
            next_ptr_addrb <= bbq_out_he_data;
            drain_state <= DRAIN_READ_WAIT;
        end

        case (drain_state)
            DRAIN_IDLE: begin
                if (pending_enqueue_valid && bbq_ready) begin
                    issue_enqueue = 1'b1;
                    bbq_in_valid <= 1'b1;
                    bbq_in_op_type <= HEAP_OP_ENQUE;
                    bbq_in_he_data <= pending_enqueue_head;
                    bbq_in_he_priority <= pending_enqueue_rank;
                    pending_enqueue_valid <= 1'b0;
                    next_queued_packets = next_queued_packets + 1'b1;
                end
                else if (bbq_ready && !bbq_deq_inflight && (next_queued_packets != 0)) begin
                    issue_dequeue = 1'b1;
                    bbq_in_valid <= 1'b1;
                    bbq_in_op_type <= HEAP_OP_DEQUE_MIN;
                    bbq_in_he_data <= '0;
                    bbq_in_he_priority <= '0;
                    bbq_deq_inflight <= 1'b1;
                end
            end

            DRAIN_READ_WAIT: begin
                drain_data_reg <= cell_data_doutb[DATA_WIDTH-1:0];
                drain_keep_reg <= cell_data_doutb[DATA_WIDTH + KEEP_WIDTH - 1:DATA_WIDTH];
                drain_last_reg <= cell_data_doutb[CELL_DESC_WIDTH - 1];
                drain_next_ptr <= next_ptr_doutb;
                drain_state <= DRAIN_SEND;
            end

            DRAIN_SEND: begin
                if (m_axis_pkt_tready) begin
                    free_fire = 1'b1;
                    free_ptr = drain_curr_ptr;
                    next_completed_packets = next_completed_packets + 1'b1;

                    if (drain_last_reg) begin
                        drain_state <= DRAIN_IDLE;
                    end
                    else begin
                        drain_curr_ptr <= drain_next_ptr;
                        cell_data_addrb <= drain_next_ptr;
                        next_ptr_addrb <= drain_next_ptr;
                        drain_state <= DRAIN_READ_WAIT;
                    end
                end
            end

            default: begin
                drain_state <= DRAIN_IDLE;
            end
        endcase

        if (free_fire) begin
            free_list_mem[fl_wr_ptr[CELL_PTR_WIDTH-1:0]] <= free_ptr;
            fl_wr_ptr <= fl_wr_ptr + 1'b1;
        end

        if (alloc_fire) begin
            fl_rd_ptr <= fl_rd_ptr + 1'b1;
        end

        case ({alloc_fire, free_fire})
            2'b10: free_count <= free_count - 1'b1;
            2'b01: free_count <= free_count + 1'b1;
            default: free_count <= free_count;
        endcase

        queued_packet_count <= next_queued_packets;
        completed_packet_count <= next_completed_packets;
    end
end

endmodule
