`timescale 1ns / 1ps

module themis_simple_sync_fifo #(
    parameter int DATA_WIDTH = 17,
    parameter int DEPTH = 1024,
    localparam int ADDR_WIDTH = (DEPTH <= 2) ? 1 : $clog2(DEPTH)
) (
    input  logic                  clk,
    input  logic [DATA_WIDTH-1:0] din,
    input  logic                  rd_en,
    input  logic                  wr_en,
    output logic                  empty,
    output logic                  full,
    output logic [DATA_WIDTH-1:0] dout
);

(* ram_style = "block" *) logic [DATA_WIDTH-1:0] mem[0:DEPTH-1];
logic [ADDR_WIDTH-1:0] rd_ptr;
logic [ADDR_WIDTH-1:0] wr_ptr;
logic [ADDR_WIDTH:0] used;

assign empty = (used == 0);
assign full = (used == DEPTH);

initial begin
    rd_ptr = '0;
    wr_ptr = '0;
    used = '0;
    dout = '0;
end

always_ff @(posedge clk) begin
    if (wr_en && !full) begin
        mem[wr_ptr] <= din;
        wr_ptr <= (wr_ptr == DEPTH - 1) ? '0 : (wr_ptr + 1'b1);
    end

    if (rd_en && !empty) begin
        dout <= mem[rd_ptr];
        rd_ptr <= (rd_ptr == DEPTH - 1) ? '0 : (rd_ptr + 1'b1);
    end

    case ({wr_en && !full, rd_en && !empty})
        2'b10: used <= used + 1'b1;
        2'b01: used <= used - 1'b1;
        default: used <= used;
    endcase
end

endmodule

module themis_simple_tdp_ram #(
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = 10,
    localparam int DEPTH = (1 << ADDR_WIDTH)
) (
    input  logic                  clka,
    input  logic                  clkb,
    input  logic [DATA_WIDTH-1:0] dina,
    input  logic                  wea,
    input  logic [ADDR_WIDTH-1:0] addrb,
    input  logic [ADDR_WIDTH-1:0] addra,
    output logic [DATA_WIDTH-1:0] doutb
);

(* ram_style = "block" *) logic [DATA_WIDTH-1:0] mem[0:DEPTH-1];

initial begin
    doutb = '0;
end

always_ff @(posedge clka) begin
    if (wea) begin
        mem[addra] <= dina;
    end
end

always_ff @(posedge clkb) begin
    doutb <= mem[addrb];
end

endmodule
