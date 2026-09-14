# Smoke test for the interface.
#
# It replaces the C++ ::va::* commands with stubs, sources app.tcl, then plays
# a whole transcription through it: progress events, segments, completion,
# regrouping, renaming, reassignment, saving beside the audio, and export. Any
# Tcl error surfaces as a failure.
#
# Run with wish:      wish tests/ui_smoke.tcl
# or via the Makefile: make check-ui
#
# A real display is needed; on a headless machine run it under Xvfb.

package require Tk

set ::failures 0
set ::testDir [file dirname [file normalize [info script]]]

proc fail {message} {
    puts stderr "FAIL: $message"
    incr ::failures
}

proc check {label script} {
    if {[catch {uplevel 1 $script} result options]} {
        fail "$label -> $result"
        puts stderr [dict get $options -errorinfo]
        return 0
    }
    return 1
}

proc expectEqual {label actual expected} {
    if {$actual ne $expected} {
        fail "$label: expected '$expected', got '$actual'"
        return 0
    }
    return 1
}

# ---------------------------------------------------------------------------
# Stubs for the C++ layer
# ---------------------------------------------------------------------------

namespace eval ::va {
    variable Events {}
    variable Segments {}
    variable Names
    variable Running 0
    variable Exported {}
    array set Names {}
}

set ::va::argv {}
set ::va::scriptDir [file join $::testDir .. tcl]

proc ::va::timecode {seconds {subtitle 0}} {
    set milliseconds [expr {int(round($seconds * 1000))}]
    set ms [expr {$milliseconds % 1000}]
    set total [expr {$milliseconds / 1000}]
    set separator [expr {$subtitle ? "," : "."}]
    return [format "%02d:%02d:%02d%s%03d" \
        [expr {$total / 3600}] [expr {($total / 60) % 60}] [expr {$total % 60}] \
        $separator $ms]
}

proc ::va::labels {prefix unknown} {
    set ::va::prefix $prefix
    set ::va::unknown $unknown
}

proc ::va::speakerName {id} {
    variable Names
    if {[info exists Names($id)] && $Names($id) ne ""} { return $Names($id) }
    if {$id < 0} { return $::va::unknown }
    return "$::va::prefix [expr {$id + 1}]"
}

proc ::va::speakername {id args} {
    variable Names
    if {[llength $args] == 1} { set Names($id) [lindex $args 0] }
    return [::va::speakerName $id]
}

proc ::va::start {args} {
    variable Running
    set Running 1
    return ""
}

proc ::va::cancel {} {
    variable Running
    set Running 0
}

proc ::va::running {} {
    return $::va::Running
}

proc ::va::poll {} {
    variable Events
    set pending $Events
    set Events {}
    return $pending
}

proc ::va::segments {args} {
    variable Segments
    set out {}
    foreach segment $Segments {
        dict set segment name [::va::speakerName [dict get $segment speaker]]
        lappend out $segment
    }
    return $out
}

proc ::va::speakers {} {
    variable Segments
    set times {}
    set counts {}
    foreach segment $Segments {
        set id [dict get $segment speaker]
        if {$id < 0} { continue }
        dict incr counts $id 1
        dict set times $id [expr {([dict exists $times $id] ? [dict get $times $id] : 0) \
            + [dict get $segment duration]}]
    }
    set out {}
    foreach id [lsort -integer [dict keys $counts]] {
        lappend out [dict create id $id name [::va::speakerName $id] \
            time [dict get $times $id] segments [dict get $counts $id]]
    }
    return $out
}

proc ::va::recluster {args} {
    variable Segments
    # A plausible regrouping: everyone lands in the same voice.
    set updated {}
    foreach segment $Segments {
        dict set segment speaker 0
        lappend updated $segment
    }
    set Segments $updated
    array unset ::va::Names
    array set ::va::Names {}
    return 1
}

proc ::va::assign {index speaker} {
    variable Segments
    if {$index < 0 || $index >= [llength $Segments]} {
        return -code error "segment index out of range"
    }
    set segment [lindex $Segments $index]
    dict set segment speaker $speaker
    lset Segments $index $segment
    return ""
}

# Records every write so the test can assert what was saved and how often.
proc ::va::export {path {format txt}} {
    variable Exported
    lappend Exported [list $path $format]
    return ""
}

proc ::va::render {format} { return "rendered-$format" }

proc ::va::summary {} {
    return [dict create source "" model "" spkmodel "" duration 0 \
        samplerate 16000 channels 1 segments 0 speakers 0]
}

# Adds a segment to the fake transcript and queues an event for it.
proc queueSegment {index start end speaker text} {
    set segment [dict create index $index start $start end $end \
        duration [expr {$end - $start}] speaker $speaker \
        name [::va::speakerName $speaker] text $text words 4 spkframes 120]
    lappend ::va::Segments $segment
    lappend ::va::Events [dict create type segment segment $segment]
}

proc lastExport {} {
    return [lindex $::va::Exported end]
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

# A dialog would block an automated test, so any unexpected one is a failure.
proc tk_messageBox {args} {
    puts stderr "unexpected dialog: $args"
    incr ::failures
    return "yes"
}

set scriptFile [file join $::testDir .. tcl app.tcl]
if {![file readable $scriptFile]} {
    fail "app.tcl not found: $scriptFile"
    exit 1
}

check "building the interface" {
    source $scriptFile
}

# The interface writes a configuration into the home directory; neutralise it
# so the test leaves the user's settings alone.
proc ::va::ui::configPath {} {
    return [file join $::testDir .ui_smoke_unused]
}
# The real one is kept aside: the versioning test round-trips through it.
rename ::va::ui::saveConfig ::va::ui::saveConfigReal
proc ::va::ui::saveConfig {} { return }

# A source file that does not exist, so saving beside it never collides with
# anything real on disk.
set ::sampleAudio [file join $::testDir ui_smoke_sample.mp3]
set ::sampleText [file join $::testDir ui_smoke_sample.txt]
set ::va::ui::S(audio) $::sampleAudio

check "initial state" {
    expectEqual "segment count" $::va::ui::S(segments) 0
    expectEqual "window title" [wm title .] "voiceannotate"
}

check "save target derivation" {
    expectEqual "same directory, same stem, .txt extension" \
        [::va::ui::autosaveTarget] $::sampleText
    # A path with dots in a directory name must not confuse the rule.
    set ::va::ui::S(audio) [file join $::testDir v1.2 recording.final.mp3]
    expectEqual "only the last extension is replaced" \
        [::va::ui::autosaveTarget] [file join $::testDir v1.2 recording.final.txt]
    set ::va::ui::S(audio) $::sampleAudio
}

check "nothing is saved before there is a transcript" {
    expectEqual "no write" [::va::ui::saveBesideAudio] 0
    expectEqual "nothing exported" [llength $::va::Exported] 0
}

check "segments arriving" {
    lappend ::va::Events [dict create type status message "Transcribing..."]
    queueSegment 0 0.5 3.2 0 "hello everyone"
    queueSegment 1 3.4 6.0 1 "hello, shall we start"
    queueSegment 2 6.2 9.9 0 "yes let us go"
    lappend ::va::Events [dict create type progress fraction 0.5 position 9.9 \
        duration 20.0 elapsed 2.0 speed 4.95]
    ::va::ui::poll
    expectEqual "rows shown" [llength [.panes.main.book.table.tree children {}]] 3
}

check "completion" {
    set ::va::Running 0
    set ::va::ui::S(running) 0
    lappend ::va::Events [dict create type finished cancelled 0 relabelled 1 \
        elapsed 2.5 duration 20.0 speed 8.0]
    ::va::ui::poll
    expectEqual "speakers listed" [llength [.panes.side.speakers.tree children {}]] 2
}

check "transcript saved beside the audio" {
    expectEqual "written once" [llength $::va::Exported] 1
    expectEqual "written next to the source" [lindex [lastExport] 0] $::sampleText
    expectEqual "written as text" [lindex [lastExport] 1] "txt"
    if {![string match "*[file tail $::sampleText]*" $::va::ui::S(status)]} {
        fail "the status line does not mention the saved file: $::va::ui::S(status)"
    }
}

check "text view" {
    ::va::ui::refreshTextView
    set content [.panes.main.book.textview.text get 1.0 end]
    if {![string match "*hello everyone*" $content]} {
        fail "the text view is missing the first segment"
    }
    if {![string match "*Speaker 1*" $content]} {
        fail "the text view does not name the speakers"
    }
}

check "renaming a speaker" {
    set before [llength $::va::Exported]
    .panes.side.speakers.tree selection set spk1
    set ::va::ui::S(renameEntry) "Mary"
    ::va::ui::renameSpeaker
    expectEqual "name applied" [::va::speakerName 1] "Mary"
    expectEqual "name shown in the list" \
        [lindex [.panes.side.speakers.tree item spk1 -values] 0] "Mary"
    # The saved file must not go stale behind an edit.
    expectEqual "saved file refreshed" [llength $::va::Exported] [expr {$before + 1}]
    expectEqual "refreshed in place" [lindex [lastExport] 0] $::sampleText
}

check "reassigning a segment" {
    ::va::ui::assignSegment 2 1
    expectEqual "segment speaker" \
        [lindex [.panes.main.book.table.tree item seg2 -values] 3] "Mary"
}

check "regrouping" {
    set ::va::ui::S(threshold) 0.42
    ::va::ui::onThresholdChange 0.42
    expectEqual "displayed value" $::va::ui::S(thresholdText) "0.42"
    ::va::ui::recluster
    expectEqual "single speaker" [llength [.panes.side.speakers.tree children {}]] 1
}

check "an existing file is not overwritten without consent" {
    # Pretend the user picked a different source whose .txt already exists.
    set guard [file join $::testDir ui_smoke_guard.txt]
    set channel [open $guard w]
    puts $channel "notes the user wrote by hand"
    close $channel

    set ::va::ui::S(audio) [file join $::testDir ui_smoke_guard.mp3]
    set ::va::ui::S(autosavePath) ""
    set ::va::ui::S(autosaveOk) 0
    set before [llength $::va::Exported]

    # A refusal must leave the file alone.
    proc tk_messageBox {args} { return "no" }
    set saved [::va::ui::saveBesideAudio]
    expectEqual "refusal reported" $saved 0
    expectEqual "nothing written" [llength $::va::Exported] $before

    # Consent lets it through, once.
    proc tk_messageBox {args} { return "yes" }
    set saved [::va::ui::saveBesideAudio]
    expectEqual "acceptance reported" $saved 1
    expectEqual "written after consent" [llength $::va::Exported] [expr {$before + 1}]

    proc tk_messageBox {args} {
        puts stderr "unexpected dialog: $args"
        incr ::failures
        return "yes"
    }
    # Asked only once: a second save must not prompt again.
    set saved [::va::ui::saveBesideAudio]
    expectEqual "second save is silent" $saved 1

    file delete -force $guard
    set ::va::ui::S(audio) $::sampleAudio
}

check "export" {
    # tk_getSaveFile would open a window; short-circuit the choice.
    proc tk_getSaveFile {args} { return [file join $::testDir ui_smoke_export.srt] }
    ::va::ui::exportAs srt
    expectEqual "exported path" [lindex [lastExport] 0] \
        [file join $::testDir ui_smoke_export.srt]
    expectEqual "exported format" [lindex [lastExport] 1] "srt"
}

check "settings from an older format are ignored" {
    set configFile [file join $::testDir ui_smoke_config.conf]
    proc ::va::ui::configPath {} {
        return [file join $::testDir ui_smoke_config.conf]
    }

    # A file with no version: written before the sensitivity changed meaning,
    # so applying its threshold would quietly wreck the grouping.
    set channel [open $configFile w]
    puts $channel "threshold = 0.55"
    puts $channel "minframes = 999"
    close $channel

    set ::va::ui::S(threshold) 0.05
    set ::va::ui::S(minframes) 40
    ::va::ui::loadConfig
    expectEqual "stale threshold ignored" $::va::ui::S(threshold) 0.05
    expectEqual "stale minframes ignored" $::va::ui::S(minframes) 40

    # A file in the current format is honoured.
    set channel [open $configFile w]
    puts $channel "version = $::va::ui::ConfigVersion"
    puts $channel "threshold = 0.12"
    puts $channel "minframes = 75"
    close $channel

    ::va::ui::loadConfig
    expectEqual "current threshold applied" $::va::ui::S(threshold) 0.12
    expectEqual "current minframes applied" $::va::ui::S(minframes) 75

    # What saveConfig writes must be what loadConfig accepts.
    set ::va::ui::S(threshold) 0.31
    rename ::va::ui::saveConfig ::va::ui::saveConfigStub
    rename ::va::ui::saveConfigReal ::va::ui::saveConfig
    ::va::ui::saveConfig
    set ::va::ui::S(threshold) 0.99
    ::va::ui::loadConfig
    expectEqual "a file we wrote reads back" $::va::ui::S(threshold) 0.31
    rename ::va::ui::saveConfig ::va::ui::saveConfigReal
    rename ::va::ui::saveConfigStub ::va::ui::saveConfig

    file delete -force $configFile
}

check "readable durations" {
    expectEqual "seconds" [::va::ui::humanDuration 42] "42 s"
    expectEqual "minutes" [::va::ui::humanDuration 192] "3 min 12 s"
    expectEqual "hours" [::va::ui::humanDuration 7260] "2 h 1 min"
}

if {$::failures == 0} {
    puts "ui_smoke: all checks passed"
    exit 0
}
puts stderr "ui_smoke: $::failures failure(s)"
exit 1
