set build_root [expr {[info exists ::env(THEMIS_BUILD_ROOT)] && $::env(THEMIS_BUILD_ROOT) ne "" ? [file normalize $::env(THEMIS_BUILD_ROOT)] : ""}]
if {$build_root eq ""} {
  puts "ERROR: THEMIS_BUILD_ROOT is required"
  exit 1
}

set bit_file [expr {[info exists ::env(THEMIS_BIT_FILE)] && $::env(THEMIS_BIT_FILE) ne "" ? [file normalize $::env(THEMIS_BIT_FILE)] : [file join $build_root vivado themis_u200_ddr.runs impl_1 themis_u200_bd_wrapper.bit]}]
set ltx_file [expr {[info exists ::env(THEMIS_LTX_FILE)] && $::env(THEMIS_LTX_FILE) ne "" ? [file normalize $::env(THEMIS_LTX_FILE)] : [file join $build_root vivado themis_u200_ddr.runs impl_1 themis_u200_bd_wrapper.ltx]}]
set csv_file [expr {[info exists ::env(THEMIS_ILA_CSV)] && $::env(THEMIS_ILA_CSV) ne "" ? [file normalize $::env(THEMIS_ILA_CSV)] : [file join $build_root hw_ila_capture.csv]}]
set wdb_file [expr {[info exists ::env(THEMIS_ILA_WDB)] && $::env(THEMIS_ILA_WDB) ne "" ? [file normalize $::env(THEMIS_ILA_WDB)] : [file join $build_root hw_ila_capture.wdb]}]
set server_url [expr {[info exists ::env(THEMIS_HW_SERVER)] && $::env(THEMIS_HW_SERVER) ne "" ? $::env(THEMIS_HW_SERVER) : "localhost:3121"}]
set do_program [expr {[info exists ::env(THEMIS_PROGRAM)] && $::env(THEMIS_PROGRAM) ne "" ? $::env(THEMIS_PROGRAM) : 0}]

if {![file exists $bit_file]} {
  puts "ERROR: bitstream not found: $bit_file"
  exit 1
}
if {![file exists $ltx_file]} {
  puts "ERROR: probes file not found: $ltx_file"
  exit 1
}

open_hw_manager
connect_hw_server -url $server_url

set targets [get_hw_targets *]
puts "Themis HW targets: $targets"
if {[llength $targets] == 0} {
  puts "ERROR: no hardware targets"
  exit 1
}

current_hw_target [lindex $targets 0]
open_hw_target

set devices [get_hw_devices *]
puts "Themis HW devices: $devices"
if {[llength $devices] == 0} {
  puts "ERROR: no hardware devices"
  exit 1
}

set dev [lindex $devices 0]
current_hw_device $dev
set_property PROBES.FILE $ltx_file $dev

if {$do_program} {
  set_property PROGRAM.FILE $bit_file $dev
  puts "Themis programming device $dev"
  program_hw_devices $dev
}

refresh_hw_device $dev

set ilas [get_hw_ilas *]
puts "Themis ILAs: $ilas"
if {[llength $ilas] == 0} {
  puts "ERROR: no ILA cores found"
  exit 1
}

set ila [lindex $ilas 0]
set dbg_probe [lindex [get_hw_probes *themis_top_dbg_bus -of_objects $ila] 0]
if {$dbg_probe eq ""} {
  puts "ERROR: Themis debug bus probe not found"
  exit 1
}

set dbg_width 768
set done_bit 504
set cmp_bits ""
for {set bit [expr {$dbg_width - 1}]} {$bit >= 0} {incr bit -1} {
  if {$bit == $done_bit} {
    append cmp_bits "1"
  } else {
    append cmp_bits "X"
  }
}
set_property TRIGGER_COMPARE_VALUE "eq${dbg_width}'b$cmp_bits" $dbg_probe

puts "Themis ILA probe: $dbg_probe"
puts "Themis ILA trigger: dbg_bus[$done_bit] == 1"
catch {set_property CONTROL.TRIGGER_POSITION 0 $ila}

run_hw_ila $ila
wait_on_hw_ila $ila
if {[catch {get_property STATUS $ila} ila_status]} {
  set ila_status "completed"
}
puts "Themis ILA status: $ila_status"

set data [upload_hw_ila_data $ila]
write_hw_ila_data -force -csv_file $csv_file $data
write_hw_ila_data -force $wdb_file $data

puts "Themis ILA CSV: $csv_file"
puts "Themis ILA WDB: $wdb_file"
exit 0
