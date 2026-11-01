# Runs the SDRAM self test of the bring-up over JTAG (In-System Sources and Probes) and
# prints the result.
#
#   quartus_stp -t jtag/sdram_bist.tcl <mode> [<timeout seconds>]
#
# mode: 0 quick (with byte masks), 1 patterns, 2 whole-chip sweep, 3 random addresses.
# The source is 8 bits: bit 0 starts a run, bits 2:1 are the mode, bit 7 makes the mode come
# from the source instead of the switches. The probe is 168 bits, most significant first:
# flags (16), words moved (32), wrong words (32), then the first wrong word: address (24),
# expected (32) and read (32). Flags: 0 PLL locked, 1 SDRAM initialized, 2 running, 3 done,
# 4 a word was wrong, 5 the controller did not answer, 10:6 phase.
package require ::quartus::insystem_source_probe

set mode 0
set limit 120
if {[llength $argv] >= 1} { set mode [lindex $argv 0] }
if {[llength $argv] >= 2} { set limit [lindex $argv 1] }

set hw ""
foreach h [get_hardware_names] { if {[string match "USB-Blaster*" $h]} { set hw $h; break } }
if {$hw eq ""} { puts "no USB-Blaster"; exit 1 }
set dev [lindex [get_device_names -hardware_name $hw] 0]
puts "cable: $hw, device: $dev"

start_insystem_source_probe -hardware_name $hw -device_name $dev

proc probe {} {
    set hex [read_probe_data -instance_index 0 -value_in_hex]
    set hex [string tolower [string trim $hex]]
    set hex [string repeat 0 [expr {42 - [string length $hex]}]]$hex
    return [list \
        [expr "0x[string range $hex 0 3]"]  \
        [expr "0x[string range $hex 4 11]"] \
        [expr "0x[string range $hex 12 19]"] \
        [string range $hex 20 25] \
        [string range $hex 26 33] \
        [string range $hex 34 41]]
}

lassign [probe] flags ops errs faddr fexp fgot
puts [format "before: locked=%d init_done=%d running=%d" [expr {$flags & 1}] [expr {($flags >> 1) & 1}] [expr {($flags >> 2) & 1}]]
if {!(($flags >> 1) & 1)} { puts "the SDRAM is not initialized"; end_insystem_source_probe; exit 2 }

set base [expr {0x80 | ($mode << 1)}]
write_source_data -instance_index 0 -value [format %02x $base] -value_in_hex
after 50
write_source_data -instance_index 0 -value [format %02x [expr {$base | 1}]] -value_in_hex
after 50
write_source_data -instance_index 0 -value [format %02x $base] -value_in_hex

set t0 [clock seconds]
while {1} {
    lassign [probe] flags ops errs faddr fexp fgot
    set done [expr {($flags >> 3) & 1}]
    set running [expr {($flags >> 2) & 1}]
    if {$done && !$running} { break }
    if {[clock seconds] - $t0 > $limit} { puts "timed out after $limit s (phase [expr {($flags >> 6) & 31}], $ops words)"; break }
    after 500
}
set secs [expr {[clock seconds] - $t0}]
puts [format "mode %d: %d words moved in about %d s, wrong words: %d, timeout flag: %d" $mode $ops $secs $errs [expr {($flags >> 5) & 1}]]
if {$errs > 0} {
    puts "first wrong word: address 0x$faddr, expected 0x$fexp, read 0x$fgot"
}
puts [expr {($errs == 0 && !(($flags >> 5) & 1) && $done) ? "RESULT: PASS" : "RESULT: FAIL"}]
end_insystem_source_probe
