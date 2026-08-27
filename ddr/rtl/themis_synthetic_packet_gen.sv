`timescale 1ns/1ps

module themis_synthetic_packet_gen #(
  parameter int RANK_WIDTH = 16,
  parameter int SEQ_WIDTH = 32,
  parameter int PAYLOAD_WIDTH = 464,
  parameter int PERIOD_CYCLES = 1,
  parameter int MAX_PACKETS = 256,
  parameter int RANK_DIST = 0,
  parameter int HIGH_PRIORITY_PER1024 = 256
) (
  input  logic                     clk,
  input  logic                     resetn,
  input  logic                     enable,
  input  logic                     ready,
  output logic                     valid,
  output logic [RANK_WIDTH-1:0]    rank,
  output logic [SEQ_WIDTH-1:0]     seq,
  output logic [PAYLOAD_WIDTH-1:0] payload,
  output logic                     done
);
  localparam int PERIOD_W = (PERIOD_CYCLES <= 1) ? 1 : $clog2(PERIOD_CYCLES);

  logic [PERIOD_W-1:0] period_cnt;
  logic [SEQ_WIDTH-1:0] seq_q;
  logic [31:0] lfsr_q;
  logic hold_valid;
  logic [RANK_WIDTH-1:0] hold_rank;
  logic [SEQ_WIDTH-1:0] hold_seq;
  logic [PAYLOAD_WIDTH-1:0] hold_payload;

  function automatic logic [31:0] lfsr_next(input logic [31:0] value);
    begin
      lfsr_next = {value[30:0], value[31] ^ value[21] ^ value[1] ^ value[0]};
    end
  endfunction

  function automatic logic [RANK_WIDTH-1:0] make_rank(
    input logic [SEQ_WIDTH-1:0] cur_seq,
    input logic [31:0] cur_lfsr
  );
    logic [RANK_WIDTH-1:0] mixed;
    logic high_priority_v;
    int bit_idx;
    begin
      mixed = cur_lfsr[RANK_WIDTH-1:0] ^ cur_seq[RANK_WIDTH-1:0] ^
              {cur_seq[RANK_WIDTH/2-1:0], cur_seq[RANK_WIDTH-1:RANK_WIDTH/2]};
      high_priority_v = (cur_lfsr[9:0] < HIGH_PRIORITY_PER1024);
      unique case (RANK_DIST)
        0: begin
          make_rank = mixed;
          if (cur_seq[5:0] < 6'd8) begin
            for (bit_idx = 0; bit_idx < RANK_WIDTH && bit_idx < 4; bit_idx = bit_idx + 1) begin
              make_rank[RANK_WIDTH - 1 - bit_idx] = 1'b0;
            end
          end else if (cur_seq[4:0] == 5'd0) begin
            for (bit_idx = 0; bit_idx < RANK_WIDTH && bit_idx < 3; bit_idx = bit_idx + 1) begin
              make_rank[RANK_WIDTH - 1 - bit_idx] = 1'b0;
            end
          end else begin
            make_rank[RANK_WIDTH-1] = 1'b1;
          end
        end
        1: begin
          make_rank = mixed;
        end
        2: begin
          make_rank = mixed;
          if (high_priority_v) begin
            for (bit_idx = 0; bit_idx < RANK_WIDTH && bit_idx < 2; bit_idx = bit_idx + 1) begin
              make_rank[RANK_WIDTH - 1 - bit_idx] = 1'b0;
            end
          end else begin
            make_rank[RANK_WIDTH-1] = 1'b1;
          end
        end
        3: begin
          make_rank = cur_seq[RANK_WIDTH-1:0];
        end
        4: begin
          make_rank = ~cur_seq[RANK_WIDTH-1:0];
        end
        default: begin
          make_rank = mixed;
        end
      endcase
    end
  endfunction

  assign valid = hold_valid;
  assign rank = hold_rank;
  assign seq = hold_seq;
  assign payload = hold_payload;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      period_cnt <= '0;
      seq_q <= '0;
      lfsr_q <= 32'h1ace_b00c;
      hold_valid <= 1'b0;
      hold_rank <= '0;
      hold_seq <= '0;
      hold_payload <= '0;
      done <= 1'b0;
    end else begin
      if (hold_valid && ready) begin
        hold_valid <= 1'b0;
      end

      if (!enable) begin
        period_cnt <= '0;
      end else if (!done && !hold_valid) begin
        if (PERIOD_CYCLES <= 1 || period_cnt == PERIOD_CYCLES - 1) begin
          period_cnt <= '0;
          hold_valid <= 1'b1;
          hold_rank <= make_rank(seq_q, lfsr_q);
          hold_seq <= seq_q;
          hold_payload <= {{(PAYLOAD_WIDTH-32){1'b0}}, lfsr_q} ^
                          {{(PAYLOAD_WIDTH-SEQ_WIDTH){1'b0}}, seq_q};
          seq_q <= seq_q + {{(SEQ_WIDTH-1){1'b0}}, 1'b1};
          lfsr_q <= lfsr_next(lfsr_q);
          if (MAX_PACKETS > 0 && seq_q == MAX_PACKETS - 1) begin
            done <= 1'b1;
          end
        end else begin
          period_cnt <= period_cnt + {{(PERIOD_W-1){1'b0}}, 1'b1};
        end
      end
    end
  end
endmodule
