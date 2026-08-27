set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir .. ..]]
set build_root [expr {[info exists ::env(THEMIS_BUILD_ROOT)] && $::env(THEMIS_BUILD_ROOT) ne "" ? [file normalize $::env(THEMIS_BUILD_ROOT)] : [file join $repo_dir build themis_u200_ddr]}]
set project_file [file join $build_root vivado themis_u200_ddr.xpr]

if {![file exists $project_file]} {
  puts "ERROR: project not found: $project_file"
  exit 1
}

open_project $project_file
set synth_status [get_property STATUS [get_runs synth_1]]
puts "Themis synthesis status: $synth_status"
if {[string first "synth_design Complete" $synth_status] < 0} {
  puts "ERROR: synth_1 is not complete"
  exit 1
}

set jobs 1
if {[info exists ::env(THEMIS_VIVADO_JOBS)] && $::env(THEMIS_VIVADO_JOBS) ne ""} {
  set jobs $::env(THEMIS_VIVADO_JOBS)
}

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
puts "Themis implementation status: $impl_status"
if {[string first "write_bitstream Complete" $impl_status] < 0} {
  exit 1
}
set bitfiles [glob -nocomplain [file join $build_root vivado themis_u200_ddr.runs impl_1 *.bit]]
if {[llength $bitfiles] > 0} {
  puts "Themis bitstream: [lindex $bitfiles 0]"
}
exit 0
