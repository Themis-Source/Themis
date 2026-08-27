set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir .. ..]]
set build_root [expr {[info exists ::env(THEMIS_BUILD_ROOT)] && $::env(THEMIS_BUILD_ROOT) ne "" ? [file normalize $::env(THEMIS_BUILD_ROOT)] : [file join $repo_dir build themis_core_sim]}]
file mkdir $build_root

set rtl_files [list \
  [file join $repo_dir ddr rtl bbq heap_ops.sv] \
  [file join $repo_dir ddr rtl themis_bbq_queue.sv] \
  [file join $repo_dir ddr rtl themis_bmsch_queue.sv] \
  [file join $repo_dir ddr rtl themis_synthetic_packet_gen.sv] \
  [file join $repo_dir ddr rtl themis_core_bbq.sv] \
  [file join $repo_dir ddr rtl themis_u200_top.sv] \
]
set sim_files [list [file join $repo_dir ddr sim tb_themis_core.sv]]
set glbl_file [file join $::env(XILINX_VIVADO) data verilog src glbl.v]

set old_dir [pwd]
cd $build_root
file delete -force xsim.dir xvlog.log xelab.log simulate.log webtalk.log

set xvlog_sv_cmd [concat [list xvlog --sv --relax -L uvm] $rtl_files $sim_files]
puts "Running: $xvlog_sv_cmd"
if {[catch {exec {*}$xvlog_sv_cmd >@ stdout 2>@ stderr} result]} {
  puts "ERROR: xvlog SystemVerilog compile failed: $result"
  cd $old_dir
  exit 1
}

set xvlog_glbl_cmd [list xvlog --relax $glbl_file]
puts "Running: $xvlog_glbl_cmd"
if {[catch {exec {*}$xvlog_glbl_cmd >@ stdout 2>@ stderr} result]} {
  puts "ERROR: xvlog glbl compile failed: $result"
  cd $old_dir
  exit 1
}

set xelab_cmd [list xelab --debug off --relax --mt 8 -L work -L uvm -L unisims_ver -L unimacro_ver -L secureip -s tb_themis_core_behav work.tb_themis_core work.glbl]
puts "Running: $xelab_cmd"
if {[catch {exec {*}$xelab_cmd >@ stdout 2>@ stderr} result]} {
  puts "ERROR: xelab failed: $result"
  cd $old_dir
  exit 1
}

set run_fh [open [file join $build_root xsim_run.tcl] w]
puts $run_fh "run -all"
puts $run_fh "quit"
close $run_fh

set xsim_cmd [list xsim tb_themis_core_behav -wdb /dev/null -tclbatch [file join $build_root xsim_run.tcl] -log simulate.log]
puts "Running: $xsim_cmd"
if {[catch {exec {*}$xsim_cmd >@ stdout 2>@ stderr} result]} {
  puts "ERROR: xsim failed: $result"
  cd $old_dir
  exit 1
}

set sim_log [file join $build_root simulate.log]
if {![file exists $sim_log]} {
  puts "ERROR: Themis simulation log was not generated"
  cd $old_dir
  exit 1
}
set fh [open $sim_log r]
set sim_text [read $fh]
close $fh
if {[string first "PASS: Themis subsystem admitted to SRAM/DDR, swapped, and drained" $sim_text] < 0 ||
    [string first "Fatal:" $sim_text] >= 0} {
  puts "ERROR: Themis simulation did not reach a clean PASS marker"
  cd $old_dir
  exit 1
}
cd $old_dir
exit 0
