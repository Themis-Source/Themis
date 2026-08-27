set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir .. ..]]
if {[llength $argv] > 0} {
  set build_root [file normalize [lindex $argv 0]]
} elseif {[info exists ::env(THEMIS_BUILD_ROOT)] && $::env(THEMIS_BUILD_ROOT) ne ""} {
  set build_root [file normalize $::env(THEMIS_BUILD_ROOT)]
} else {
  set build_root [file join $repo_dir build themis_stripped_core]
}
set build_dir [file join $build_root vivado]
file mkdir $build_dir

set project_name themis_stripped_core
create_project -force $project_name $build_dir -part xcu200-fsgd2104-2-e
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set sv_files [list \
  [file join $repo_dir ddr rtl bbq heap_ops.sv] \
  [file join $repo_dir ddr rtl themis_bmsch_queue.sv] \
  [file join $repo_dir ddr rtl themis_core_bbq.sv] \
  [file join $repo_dir ddr rtl themis_core_stripped_top.sv] \
]
add_files -fileset sources_1 $sv_files
set_property file_type SystemVerilog [get_files $sv_files]
set_property top themis_core_stripped_top [current_fileset]
update_compile_order -fileset sources_1

set jobs 1
if {[info exists ::env(THEMIS_VIVADO_JOBS)] && $::env(THEMIS_VIVADO_JOBS) ne ""} {
  set jobs $::env(THEMIS_VIVADO_JOBS)
}

launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
puts "Themis stripped synthesis status: $synth_status"
if {[string first "synth_design Complete" $synth_status] < 0} {
  exit 1
}

open_run synth_1 -name synth_1
report_utilization -file [file join $build_root stripped_utilization_synth.rpt]
report_utilization -hierarchical -file [file join $build_root stripped_utilization_hier_synth.rpt]
report_timing_summary -max_paths 10 -file [file join $build_root stripped_timing_summary_synth.rpt]

puts "Themis stripped utilization: [file join $build_root stripped_utilization_synth.rpt]"
puts "Themis stripped hierarchical utilization: [file join $build_root stripped_utilization_hier_synth.rpt]"
puts "Themis stripped timing summary: [file join $build_root stripped_timing_summary_synth.rpt]"
exit 0
