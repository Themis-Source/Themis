`timescale 1ns / 1ps

module themis_resource_eval_top #(
    parameter int DATA_WIDTH = 512,
    parameter int KEEP_WIDTH = (DATA_WIDTH / 8),
    parameter int CELL_PTR_WIDTH = 6,
    parameter int HEAP_BITMAP_WIDTH = 32,
    localparam int HEAP_NUM_LEVELS = 2,
    localparam int HEAP_NUM_PRIORITIES = (HEAP_BITMAP_WIDTH ** HEAP_NUM_LEVELS),
    localparam int HEAP_PRIORITY_WIDTH = $clog2(HEAP_NUM_PRIORITIES)
) (
    input  logic        clk,
    input  logic        rst,
    output logic [31:0] activity
);

logic [DATA_WIDTH-1:0] s_axis_pkt_tdata;
logic s_axis_pkt_tvalid;
logic s_axis_pkt_tlast;
logic [KEEP_WIDTH-1:0] s_axis_pkt_tkeep;
logic [HEAP_PRIORITY_WIDTH-1:0] s_axis_pkt_rank;
logic s_axis_pkt_tready;

logic [DATA_WIDTH-1:0] m_axis_pkt_tdata;
logic m_axis_pkt_tvalid;
logic m_axis_pkt_tlast;
logic [KEEP_WIDTH-1:0] m_axis_pkt_tkeep;

logic bbq_ready;
logic [31:0] dbg_free_cells;
logic [31:0] dbg_queued_packets;
logic [31:0] dbg_completed_packets;

logic packet_open;
logic [1:0] beats_left;
logic [63:0] packet_counter;
logic [63:0] beat_counter;
logic [HEAP_PRIORITY_WIDTH-1:0] current_rank;

always_ff @(posedge clk) begin
    logic [1:0] new_packet_len;

    new_packet_len = 2'd1 + packet_counter[1:0];

    if (rst) begin
        packet_open <= 1'b0;
        beats_left <= '0;
        packet_counter <= '0;
        beat_counter <= '0;

        s_axis_pkt_tvalid <= 1'b0;
        s_axis_pkt_tdata <= '0;
        s_axis_pkt_tlast <= 1'b0;
        s_axis_pkt_tkeep <= '0;
        s_axis_pkt_rank <= '0;
        current_rank <= '0;
        activity <= '0;
    end
    else begin
        s_axis_pkt_tvalid <= 1'b0;
        s_axis_pkt_tlast <= 1'b0;
        s_axis_pkt_tkeep <= '0;

        if (s_axis_pkt_tready) begin
            s_axis_pkt_tvalid <= 1'b1;
            s_axis_pkt_tkeep <= {KEEP_WIDTH{1'b1}};
            s_axis_pkt_tdata <= beat_counter;

            if (!packet_open) begin
                current_rank <= packet_counter[HEAP_PRIORITY_WIDTH-1:0];
                s_axis_pkt_rank <= packet_counter[HEAP_PRIORITY_WIDTH-1:0];
                s_axis_pkt_tlast <= (new_packet_len == 1);

                if (new_packet_len == 1) begin
                    packet_counter <= packet_counter + 1'b1;
                end
                else begin
                    packet_open <= 1'b1;
                    beats_left <= new_packet_len - 1'b1;
                end
            end
            else begin
                s_axis_pkt_rank <= current_rank;
                s_axis_pkt_tlast <= (beats_left == 1);

                if (beats_left == 1) begin
                    packet_open <= 1'b0;
                    packet_counter <= packet_counter + 1'b1;
                    beats_left <= '0;
                end
                else begin
                    beats_left <= beats_left - 1'b1;
                end
            end

            beat_counter <= beat_counter + 1'b1;
        end

        activity[0] <= bbq_ready;
        activity[1] <= s_axis_pkt_tready;
        activity[2] <= m_axis_pkt_tvalid;
        activity[3] <= m_axis_pkt_tlast;
        activity[15:4] <= dbg_free_cells[11:0];
        activity[23:16] <= dbg_queued_packets[7:0];
        activity[31:24] <= dbg_completed_packets[7:0];
    end
end

themis_linked_buffer_manager #(
    .DATA_WIDTH(DATA_WIDTH),
    .KEEP_WIDTH(KEEP_WIDTH),
    .CELL_PTR_WIDTH(CELL_PTR_WIDTH),
    .HEAP_BITMAP_WIDTH(HEAP_BITMAP_WIDTH),
    .HEAP_MAX_NUM_ENTRIES((1 << CELL_PTR_WIDTH) - 1)
) linked_buffer_mgr (
    .clk(clk),
    .rst(rst),
    .s_axis_pkt_tdata(s_axis_pkt_tdata),
    .s_axis_pkt_tvalid(s_axis_pkt_tvalid),
    .s_axis_pkt_tlast(s_axis_pkt_tlast),
    .s_axis_pkt_tkeep(s_axis_pkt_tkeep),
    .s_axis_pkt_rank(s_axis_pkt_rank),
    .s_axis_pkt_tready(s_axis_pkt_tready),
    .m_axis_pkt_tdata(m_axis_pkt_tdata),
    .m_axis_pkt_tvalid(m_axis_pkt_tvalid),
    .m_axis_pkt_tlast(m_axis_pkt_tlast),
    .m_axis_pkt_tkeep(m_axis_pkt_tkeep),
    .m_axis_pkt_tready(1'b1),
    .bbq_ready(bbq_ready),
    .dbg_free_cells(dbg_free_cells),
    .dbg_queued_packets(dbg_queued_packets),
    .dbg_completed_packets(dbg_completed_packets)
);

endmodule
