set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir .. ..]]
set build_root [expr {[info exists ::env(THEMIS_BUILD_ROOT)] && $::env(THEMIS_BUILD_ROOT) ne "" ? [file normalize $::env(THEMIS_BUILD_ROOT)] : [file join $repo_dir build themis_u200_ddr]}]
set build_dir [file join $build_root vivado]
file mkdir $build_dir

set project_name themis_u200_ddr
set bd_name themis_u200_bd
create_project -force $project_name $build_dir -part xcu200-fsgd2104-2-e
set_property board_part xilinx.com:au200:part0:1.3 [current_project]
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set sv_files [list \
  [file join $repo_dir ddr rtl bbq heap_ops.sv] \
  [file join $repo_dir ddr rtl themis_bbq_queue.sv] \
  [file join $repo_dir ddr rtl themis_bmsch_queue.sv] \
  [file join $repo_dir ddr rtl themis_synthetic_packet_gen.sv] \
  [file join $repo_dir ddr rtl themis_core_bbq.sv] \
  [file join $repo_dir ddr rtl themis_u200_top.sv] \
]
set v_files [list \
  [file join $repo_dir ddr rtl themis_u200_bd_cell.v] \
]
add_files -fileset sources_1 $sv_files
add_files -fileset sources_1 $v_files
set_property file_type SystemVerilog [get_files $sv_files]

create_bd_design $bd_name
current_bd_design $bd_name

create_bd_cell -type module -reference themis_u200_bd_cell themis_top
create_bd_cell -type ip -vlnv xilinx.com:ip:ddr4 ddr4_0
set_property -dict [list \
  CONFIG.C0_DDR4_BOARD_INTERFACE ddr4_sdram_c0 \
  CONFIG.C0_CLOCK_BOARD_INTERFACE default_300mhz_clk0 \
  CONFIG.C0.DDR4_AxiAddressWidth {34} \
  CONFIG.C0.DDR4_AxiDataWidth {512} \
  CONFIG.C0.DDR4_AxiIDWidth {4} \
  CONFIG.C0.DDR4_CLKOUT0_DIVIDE {5} \
  CONFIG.C0.DDR4_DataWidth {72} \
  CONFIG.C0.DDR4_Ecc {true} \
  CONFIG.C0.DDR4_InputClockPeriod {3332} \
  CONFIG.C0.DDR4_MemoryPart {MTA18ASF2G72PZ-2G3} \
  CONFIG.C0.DDR4_MemoryType {RDIMMs} \
  CONFIG.C0.DDR4_TimePeriod {833} \
  CONFIG.C0.DDR4_AUTO_AP_COL_A3 {true} \
  CONFIG.C0.DDR4_Mem_Add_Map {ROW_COLUMN_BANK_INTLV} \
] [get_bd_cells ddr4_0]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice axi_reg
set_property -dict [list CONFIG.ADDR_WIDTH {34} CONFIG.DATA_WIDTH {512} CONFIG.ID_WIDTH {4}] [get_bd_cells axi_reg]
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_ddr
create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi ctrl_jtag_axi
set_property -dict [list CONFIG.PROTOCOL {2} CONFIG.M_AXI_ADDR_WIDTH {32} CONFIG.M_AXI_DATA_WIDTH {32}] [get_bd_cells ctrl_jtag_axi]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant sys_rst_const
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells sys_rst_const]

apply_bd_automation -rule xilinx.com:bd_rule:board -config {Board_Interface "ddr4_sdram_c0"} [get_bd_intf_pins ddr4_0/C0_DDR4]
apply_bd_automation -rule xilinx.com:bd_rule:board -config {Board_Interface "default_300mhz_clk0"} [get_bd_intf_pins ddr4_0/C0_SYS_CLK]

connect_bd_net [get_bd_pins ddr4_0/c0_ddr4_ui_clk] [get_bd_pins themis_top/clk] [get_bd_pins axi_reg/aclk] [get_bd_pins rst_ddr/slowest_sync_clk] [get_bd_pins ctrl_jtag_axi/aclk]
connect_bd_net [get_bd_pins ddr4_0/c0_ddr4_ui_clk_sync_rst] [get_bd_pins rst_ddr/ext_reset_in]
connect_bd_net [get_bd_pins sys_rst_const/dout] [get_bd_pins ddr4_0/sys_rst]
connect_bd_net [get_bd_pins rst_ddr/peripheral_aresetn] [get_bd_pins themis_top/resetn] [get_bd_pins axi_reg/aresetn] [get_bd_pins ddr4_0/c0_ddr4_aresetn] [get_bd_pins ctrl_jtag_axi/aresetn]
connect_bd_net [get_bd_pins ddr4_0/c0_init_calib_complete] [get_bd_pins themis_top/calib_done]
connect_bd_intf_net [get_bd_intf_pins themis_top/M_AXI] [get_bd_intf_pins axi_reg/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_reg/M_AXI] [get_bd_intf_pins ddr4_0/C0_DDR4_S_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl_jtag_axi/M_AXI] [get_bd_intf_pins ddr4_0/C0_DDR4_S_AXI_CTRL]

set enable_ila 0
if {[info exists ::env(THEMIS_ENABLE_ILA)] && $::env(THEMIS_ENABLE_ILA) ne ""} {
  set enable_ila $::env(THEMIS_ENABLE_ILA)
}
if {$enable_ila} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:ila themis_ila
  set_property -dict [list CONFIG.C_NUM_OF_PROBES {2} CONFIG.C_DATA_DEPTH {1024} \
    CONFIG.C_PROBE0_WIDTH {768} CONFIG.C_PROBE1_WIDTH {1}] [get_bd_cells themis_ila]
  connect_bd_net [get_bd_pins ddr4_0/c0_ddr4_ui_clk] [get_bd_pins themis_ila/clk]
  connect_bd_net [get_bd_pins themis_top/dbg_bus] [get_bd_pins themis_ila/probe0]
  connect_bd_net [get_bd_pins ddr4_0/c0_init_calib_complete] [get_bd_pins themis_ila/probe1]
}

assign_bd_address
validate_bd_design
save_bd_design
make_wrapper -files [get_files [file join $build_dir $project_name.srcs sources_1 bd $bd_name ${bd_name}.bd]] -top
add_files -norecurse [file join $build_dir $project_name.gen sources_1 bd $bd_name hdl ${bd_name}_wrapper.v]
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

set jobs 1
if {[info exists ::env(THEMIS_VIVADO_JOBS)] && $::env(THEMIS_VIVADO_JOBS) ne ""} {
  set jobs $::env(THEMIS_VIVADO_JOBS)
}
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
puts "Themis synthesis status: $synth_status"
if {[string first "synth_design Complete" $synth_status] < 0} {
  exit 1
}
if {[info exists ::env(THEMIS_STOP_AFTER_SYNTH)] && $::env(THEMIS_STOP_AFTER_SYNTH) ne "" && $::env(THEMIS_STOP_AFTER_SYNTH)} {
  exit 0
}
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
puts "Themis implementation status: $impl_status"
if {[string first "write_bitstream Complete" $impl_status] < 0} {
  exit 1
}
set bitfiles [glob -nocomplain [file join $build_dir $project_name.runs impl_1 *.bit]]
if {[llength $bitfiles] > 0} {
  puts "Themis bitstream: [lindex $bitfiles 0]"
}
exit 0
