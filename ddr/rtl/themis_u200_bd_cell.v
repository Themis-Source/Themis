`timescale 1ns/1ps

module themis_u200_bd_cell (
  input  wire         clk,
  input  wire         resetn,
  input  wire         calib_done,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWID" *)
  output wire [3:0]   m_axi_awid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWADDR" *)
  output wire [33:0]  m_axi_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLEN" *)
  output wire [7:0]   m_axi_awlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWSIZE" *)
  output wire [2:0]   m_axi_awsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWBURST" *)
  output wire [1:0]   m_axi_awburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLOCK" *)
  output wire         m_axi_awlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWCACHE" *)
  output wire [3:0]   m_axi_awcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWPROT" *)
  output wire [2:0]   m_axi_awprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWQOS" *)
  output wire [3:0]   m_axi_awqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWVALID" *)
  output wire         m_axi_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWREADY" *)
  input  wire         m_axi_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WDATA" *)
  output wire [511:0] m_axi_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WSTRB" *)
  output wire [63:0]  m_axi_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WLAST" *)
  output wire         m_axi_wlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WVALID" *)
  output wire         m_axi_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WREADY" *)
  input  wire         m_axi_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BID" *)
  input  wire [3:0]   m_axi_bid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BRESP" *)
  input  wire [1:0]   m_axi_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BVALID" *)
  input  wire         m_axi_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BREADY" *)
  output wire         m_axi_bready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARID" *)
  output wire [3:0]   m_axi_arid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARADDR" *)
  output wire [33:0]  m_axi_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLEN" *)
  output wire [7:0]   m_axi_arlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARSIZE" *)
  output wire [2:0]   m_axi_arsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARBURST" *)
  output wire [1:0]   m_axi_arburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLOCK" *)
  output wire         m_axi_arlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARCACHE" *)
  output wire [3:0]   m_axi_arcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARPROT" *)
  output wire [2:0]   m_axi_arprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARQOS" *)
  output wire [3:0]   m_axi_arqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARVALID" *)
  output wire         m_axi_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARREADY" *)
  input  wire         m_axi_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RID" *)
  input  wire [3:0]   m_axi_rid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RDATA" *)
  input  wire [511:0] m_axi_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RRESP" *)
  input  wire [1:0]   m_axi_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RLAST" *)
  input  wire         m_axi_rlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RVALID" *)
  input  wire         m_axi_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RREADY" *)
  (* X_INTERFACE_PARAMETER = "PROTOCOL AXI4, DATA_WIDTH 512, ADDR_WIDTH 34, ID_WIDTH 4, HAS_BURST 1, HAS_LOCK 1, HAS_PROT 1, HAS_CACHE 1, HAS_QOS 1, SUPPORTS_NARROW_BURST 0, MAX_BURST_LENGTH 256" *)
  output wire         m_axi_rready,

  output wire [31:0]  dbg_generated,
  output wire [31:0]  dbg_dequeued,
  output wire [31:0]  dbg_sram_admit,
  output wire [31:0]  dbg_ddr_admit,
  output wire [31:0]  dbg_swap_out,
  output wire [31:0]  dbg_swap_in,
  output wire [31:0]  dbg_drop,
  output wire [31:0]  dbg_onchip_dequeue_hit,
  output wire [31:0]  dbg_direct_sram_dequeued,
  output wire [31:0]  dbg_ddr_sourced_dequeued,
  output wire [31:0]  dbg_dequeue_stall_cycles,
  output wire [31:0]  dbg_ddr_write_beats,
  output wire [31:0]  dbg_ddr_read_beats,
  output wire [31:0]  dbg_ddr_write_batches,
  output wire [31:0]  dbg_ddr_read_batches,
  output wire [31:0]  dbg_occupancy,
  output wire [15:0]  dbg_offchip_min_rank,
  output wire [7:0]   dbg_state,
  output wire [767:0] dbg_bus,
  output wire         done
);
  wire core_resetn;
  wire [31:0] dbg_run_cycles;
  wire [31:0] dbg_output_fire_cycles;
  wire [31:0] dbg_drain_ready_cycles;
  wire [31:0] dbg_rank_order_errors;
  wire [15:0] dbg_last_out_rank;
  wire [15:0] dbg_current_out_rank;
  wire        dbg_out_valid;
  wire        dbg_drain_ready;
  wire        dbg_rank_order_prev_valid;

  assign core_resetn = resetn & calib_done;

  themis_u200_top #(
    .AXI_ADDR_WIDTH(34)
  ) themis_top_i (
    .clk(clk),
    .resetn(core_resetn),
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
    .dbg_generated(dbg_generated),
    .dbg_dequeued(dbg_dequeued),
    .dbg_sram_admit(dbg_sram_admit),
    .dbg_ddr_admit(dbg_ddr_admit),
    .dbg_swap_out(dbg_swap_out),
    .dbg_swap_in(dbg_swap_in),
    .dbg_drop(dbg_drop),
    .dbg_onchip_dequeue_hit(dbg_onchip_dequeue_hit),
    .dbg_direct_sram_dequeued(dbg_direct_sram_dequeued),
    .dbg_ddr_sourced_dequeued(dbg_ddr_sourced_dequeued),
    .dbg_dequeue_stall_cycles(dbg_dequeue_stall_cycles),
    .dbg_ddr_write_beats(dbg_ddr_write_beats),
    .dbg_ddr_read_beats(dbg_ddr_read_beats),
    .dbg_ddr_write_batches(dbg_ddr_write_batches),
    .dbg_ddr_read_batches(dbg_ddr_read_batches),
    .dbg_occupancy(dbg_occupancy),
    .dbg_offchip_min_rank(dbg_offchip_min_rank),
    .dbg_state(dbg_state),
    .dbg_run_cycles(dbg_run_cycles),
    .dbg_output_fire_cycles(dbg_output_fire_cycles),
    .dbg_drain_ready_cycles(dbg_drain_ready_cycles),
    .dbg_rank_order_errors(dbg_rank_order_errors),
    .dbg_last_out_rank(dbg_last_out_rank),
    .dbg_current_out_rank(dbg_current_out_rank),
    .dbg_out_valid(dbg_out_valid),
    .dbg_drain_ready(dbg_drain_ready),
    .dbg_rank_order_prev_valid(dbg_rank_order_prev_valid),
    .done(done)
  );

  assign dbg_bus = {
    60'd0,
    dbg_onchip_dequeue_hit,
    core_resetn,
    dbg_drain_ready,
    dbg_out_valid,
    dbg_rank_order_prev_valid,
    dbg_current_out_rank,
    dbg_last_out_rank,
    dbg_rank_order_errors,
    dbg_drain_ready_cycles,
    dbg_output_fire_cycles,
    dbg_run_cycles,
    7'd0,
    done,
    dbg_state,
    dbg_offchip_min_rank,
    dbg_occupancy,
    dbg_ddr_read_batches,
    dbg_ddr_write_batches,
    dbg_ddr_read_beats,
    dbg_ddr_write_beats,
    dbg_dequeue_stall_cycles,
    dbg_ddr_sourced_dequeued,
    dbg_direct_sram_dequeued,
    dbg_drop,
    dbg_swap_in,
    dbg_swap_out,
    dbg_ddr_admit,
    dbg_sram_admit,
    dbg_dequeued,
    dbg_generated
  };
endmodule
