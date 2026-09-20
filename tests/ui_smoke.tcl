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

# ---------------------------------------------------------------------------
# The model download dialog
#
# The catalogue is fed in directly rather than fetched: the test must not need
# a network, and what matters here is the filtering, the ordering and where a
# downloaded model ends up being used.
# ---------------------------------------------------------------------------

set ::fakeCatalogue [list \
    [dict create lang fr lang_text French name vosk-model-fr-0.22 obsolete false \
        size 1500000000 size_text 1.4GiB type big url https://example/fr-big.zip] \
    [dict create lang fr lang_text French name vosk-model-small-fr-0.22 obsolete false \
        size 41202580 size_text 39.3MiB type small url https://example/fr-small.zip] \
    [dict create lang en-us lang_text {US English} name vosk-model-small-en-us-0.15 \
        obsolete false size 39000000 size_text 37.2MiB type small url https://example/en.zip] \
    [dict create lang all lang_text All name vosk-model-spk-0.4 obsolete false \
        size 13869103 size_text 13.2MiB type spk url https://example/spk.zip] \
    [dict create lang fr lang_text French name vosk-model-fr-replaced obsolete true \
        size 10 size_text 10B type big url https://example/old.zip] \
    [dict create lang fr lang_text French name vosk-model-tts-fr obsolete false \
        size 20 size_text 20B type tts url https://example/tts.zip]]

# A models directory of the test's own, so the "installed" column does not
# depend on what the machine happens to have downloaded.
set ::fakeModelsDir [file join $::testDir ui_smoke_models]
file mkdir [file join $::fakeModelsDir vosk-model-small-fr-0.22]
proc ::va::ui::modelSearchPath {} {
    return [list $::fakeModelsDir]
}

check "the catalogue drops what cannot be used" {
    set usable [::va::ui::usableModels $::fakeCatalogue]
    expectEqual "obsolete and text-to-speech entries removed" [llength $usable] 4
    foreach entry $usable {
        if {[dict get $entry name] eq "vosk-model-fr-replaced"} {
            fail "an obsolete model is still listed"
        }
        if {[dict get $entry type] eq "tts"} {
            fail "a text-to-speech model is still listed"
        }
    }
}

check "the dialog lists the catalogue" {
    ::va::ui::buildCatalogueDialog
    ::va::ui::showCatalogue [::va::ui::usableModels $::fakeCatalogue]

    expectEqual "languages offered" [.catalogue.top.lang cget -values] \
        [list "All languages" "French" "US English"]
    # Smallest first: a full model is a long download to start by accident.
    expectEqual "listed smallest first" [.catalogue.list.tree children {}] \
        [list vosk-model-spk-0.4 vosk-model-small-en-us-0.15 \
              vosk-model-small-fr-0.22 vosk-model-fr-0.22]
    expectEqual "what is already on disk is marked" \
        [lindex [.catalogue.list.tree item vosk-model-small-fr-0.22 -values] 3] "installed"
    expectEqual "what is not is left blank" \
        [lindex [.catalogue.list.tree item vosk-model-fr-0.22 -values] 3] ""
}

check "filtering by language keeps the speaker model in reach" {
    set ::va::ui::S(catalogueLang) "French"
    ::va::ui::populateCatalogue
    set rows [.catalogue.list.tree children {}]
    expectEqual "French models and the speaker model" $rows \
        [list vosk-model-spk-0.4 vosk-model-small-fr-0.22 vosk-model-fr-0.22]

    set ::va::ui::S(catalogueLang) "US English"
    ::va::ui::populateCatalogue
    expectEqual "no French model left" [.catalogue.list.tree children {}] \
        [list vosk-model-spk-0.4 vosk-model-small-en-us-0.15]

    set ::va::ui::S(catalogueLang) "All languages"
    ::va::ui::populateCatalogue
}

check "a downloaded model is put to use" {
    set ::va::ui::S(model) ""
    set ::va::ui::S(spkmodel) ""

    ::va::ui::useModel [::va::ui::catalogueEntry vosk-model-small-fr-0.22] /tmp/fr
    expectEqual "a recognition model fills the recognition field" $::va::ui::S(model) /tmp/fr
    expectEqual "and leaves the speaker field alone" $::va::ui::S(spkmodel) ""

    ::va::ui::useModel [::va::ui::catalogueEntry vosk-model-spk-0.4] /tmp/spk
    expectEqual "a speaker model fills the speaker field" $::va::ui::S(spkmodel) /tmp/spk
    expectEqual "and leaves the recognition field alone" $::va::ui::S(model) /tmp/fr
}

check "selecting nothing is reported rather than acted on" {
    .catalogue.list.tree selection set {}
    ::va::ui::downloadSelected
    if {![string match "*Select a model*" $::va::ui::S(catalogueStatus)]} {
        fail "no prompt to select a model: $::va::ui::S(catalogueStatus)"
    }
}

check "an already downloaded model is used rather than fetched again" {
    .catalogue.list.tree selection set vosk-model-small-fr-0.22
    set ::va::ui::S(model) ""
    ::va::ui::downloadSelected
    expectEqual "used from where it already sits" $::va::ui::S(model) \
        [file join $::fakeModelsDir vosk-model-small-fr-0.22]
    if {[::va::ui::transferRunning]} {
        fail "a transfer was started for a model already on disk"
    }
}

check "closing the dialog" {
    ::va::ui::closeCatalogue
    if {[winfo exists .catalogue]} { fail "the dialog is still open" }
}

check "a split download covers every byte exactly once" {
    # A gap or an overlap here would come back as a corrupt archive, well after
    # the point where the cause is still visible.
    foreach {size count} {41202580 8 1913365522 8 1000 8 999 7 13869103 8 4194304 1} {
        set ranges [::va::ui::partRanges $size $count]
        expectEqual "one range per connection ($size/$count)" [llength $ranges] $count

        expectEqual "starts at the first byte ($size/$count)" \
            [lindex $ranges 0 0] 0
        expectEqual "ends on the last byte ($size/$count)" \
            [lindex $ranges end 1] [expr {$size - 1}]

        set covered 0
        set previous -1
        foreach range $ranges {
            lassign $range first last
            if {$first != $previous + 1} {
                fail "a gap or an overlap at $first ($size/$count)"
            }
            if {$last < $first} { fail "an empty range at $first ($size/$count)" }
            incr covered [expr {$last - $first + 1}]
            set previous $last
        }
        expectEqual "the ranges add up to the file ($size/$count)" $covered $size
    }
}

check "the connection count stays within what the server is asked for" {
    if {$::va::ui::Connections > 8} {
        fail "more than eight connections: $::va::ui::Connections"
    }
    expectEqual "a small file is not split" \
        [expr {$::va::ui::SplitThreshold > 0}] 1
}

check "a zip can be unpacked on this machine" {
    # Whatever the machine has, the command has to name both the archive and
    # where it goes, or a model would be unpacked somewhere else entirely.
    set command [::va::ui::unpackCommand /tmp/model.zip /tmp/models]
    set program [lindex $command 0]
    if {$program eq "" || \
        (![file exists $program] && [lindex [auto_execok $program] 0] eq "")} {
        fail "no unpacker on this machine: $command"
    }
    if {[lsearch -exact $command /tmp/model.zip] < 0} {
        fail "the archive is not in the command: $command"
    }
    if {[lsearch -exact $command /tmp/models] < 0} {
        fail "the destination is not in the command: $command"
    }
}

check "only a tar that reads zip is taken for one" {
    expectEqual "bsdtar" \
        [::va::ui::isBsdtar "bsdtar 3.8.8 - libarchive 3.8.8 zlib/1.2.13"] 1
    expectEqual "libarchive under another name" \
        [::va::ui::isBsdtar "tar (libarchive 3.6.2)"] 1
    # GNU tar cannot open a zip at all, and it is what "tar" is on most Linux
    # machines and in a Git installation on Windows.
    expectEqual "GNU tar" [::va::ui::isBsdtar "tar (GNU tar) 1.35"] 0
    expectEqual "nothing at all" [::va::ui::isBsdtar ""] 0
    expectEqual "a program that is not installed" \
        [::va::ui::readsZip nosuchtar-2f9c1] 0
}

check "the unpacker is only looked for once" {
    set first [::va::ui::unpackCommand /tmp/a.zip /tmp/d]
    set ::va::ui::Unpacker [list unzip /nowhere/unzip]
    expectEqual "the cached answer is used" \
        [lindex [::va::ui::unpackCommand /tmp/a.zip /tmp/d] 0] /nowhere/unzip
    set ::va::ui::Unpacker [lindex [::va::ui::unpackers] 0]
    expectEqual "and is what was found to begin with" \
        [::va::ui::unpackCommand /tmp/a.zip /tmp/d] $first
}

check "a machine with nothing to unpack with says so" {
    set saved $::va::ui::Unpacker
    set ::va::ui::Unpacker {}
    if {![catch {::va::ui::unpackCommand /tmp/a.zip /tmp/d} message]} {
        fail "an empty unpacker produced a command: $message"
    }
    if {![string match "*unzip*" $message]} {
        fail "the message does not say what to install: $message"
    }
    # And the failure reaches the caller as a callback, not as an exception:
    # everything downstream of a download reports itself that way.
    set ::reported {}
    ::va::ui::startUnpack /tmp/a.zip [file join $::fakeModelsDir unpack-probe] \
        [list apply {{args} {set ::reported $args}}]
    expectEqual "reported as a failure" [lindex $::reported 0] 0
    set ::va::ui::Unpacker $saved
}

check "byte counts read as sizes" {
    expectEqual "bytes" [::va::ui::humanBytes 512] "512 B"
    expectEqual "kibibytes" [::va::ui::humanBytes 2048] "2.0 KiB"
    expectEqual "mebibytes" [::va::ui::humanBytes 41202580] "39.3 MiB"
    expectEqual "gibibytes" [::va::ui::humanBytes 1500000000] "1.4 GiB"
}

file delete -force $::fakeModelsDir

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
