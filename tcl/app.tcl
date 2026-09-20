# voiceannotate -- Tk interface.
#
# Everything visible lives here; everything computed lives in C++, behind the
# ::va::* commands (see src/tcl/tcl_app.cpp). The only link between the two is
# ::va::poll, driven by a timer: the worker thread never enters the Tcl
# interpreter, which is what keeps thread safety a non-issue.
#
# Nothing here is platform specific apart from the keyboard accelerators, which
# follow each system's convention.

package require Tk

namespace eval ::va::ui {
    variable S
    variable Palette
    variable PollId ""

    # Application state. Entry widgets bind to it through -textvariable, which
    # saves reading values back out of widgets all over the place.
    array set S {
        audio          ""
        model          ""
        spkmodel       ""
        threshold      0.05
        minframes      40
        maxspeakers    0
        running        0
        status         "Ready."
        progress       0
        stats          ""
        segments       0
        speakers       0
        selected       -1
        renameEntry    ""
        autosavePath   ""
        autosaveOk     0
        catalogueLang  "All languages"
        catalogueStatus ""
        catalogueProgress 0
    }

    # Speaker colours. Chosen to stay legible on a light background and to
    # remain distinguishable to dichromatic vision.
    set Palette {
        #1f6feb #d1242f #1a7f37 #9a6700 #8250df
        #0f6c8c #bc4c00 #57606a #a40e26 #2da44e
    }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc ::va::ui::speakerColor {id} {
    variable Palette
    if {$id < 0} { return "#6e7781" }
    return [lindex $Palette [expr {$id % [llength $Palette]}]]
}

proc ::va::ui::isMac {} {
    return [expr {[tk windowingsystem] eq "aqua"}]
}

# "Command" on macOS, "Control" everywhere else.
proc ::va::ui::modifier {} {
    return [expr {[isMac] ? "Command" : "Control"}]
}

proc ::va::ui::accel {key} {
    return [expr {[isMac] ? "Cmd+$key" : "Ctrl+$key"}]
}

# Readable duration: "3 min 12 s" rather than "192.4".
proc ::va::ui::humanDuration {seconds} {
    set seconds [expr {int(round($seconds))}]
    if {$seconds < 60} { return "${seconds} s" }
    set minutes [expr {$seconds / 60}]
    set rest [expr {$seconds % 60}]
    if {$minutes < 60} { return "${minutes} min ${rest} s" }
    set hours [expr {$minutes / 60}]
    set minutes [expr {$minutes % 60}]
    return "${hours} h ${minutes} min"
}

proc ::va::ui::say {message} {
    variable S
    set S(status) $message
}

proc ::va::ui::warn {title message} {
    tk_messageBox -parent . -icon warning -title $title -message $message
}

proc ::va::ui::oops {title message} {
    tk_messageBox -parent . -icon error -title $title -message $message
}

# ---------------------------------------------------------------------------
# Persistent configuration
#
# Model paths are tedious to retype every launch. The file lives in the home
# directory, which Tcl resolves on all three platforms.
# ---------------------------------------------------------------------------

# Bump this whenever a stored setting changes meaning, so a file written by an
# older build is discarded rather than silently misapplied. Version 2 is the
# first where the sensitivity is measured after the recording's mean has been
# removed: a value saved under version 1 sits on a different scale entirely and
# would quietly wreck the speaker grouping.
set ::va::ui::ConfigVersion 2

proc ::va::ui::configPath {} {
    return [file join [file normalize ~] .voiceannotate.conf]
}

proc ::va::ui::loadConfig {} {
    variable S
    variable ConfigVersion

    set path [configPath]
    if {![file readable $path]} { return }
    if {[catch {open $path r} channel]} { return }

    set stored [dict create]
    while {[gets $channel line] >= 0} {
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#"} { continue }
        set equals [string first "=" $line]
        if {$equals < 1} { continue }
        set key [string trim [string range $line 0 [expr {$equals - 1}]]]
        set value [string trim [string range $line [expr {$equals + 1}] end]]
        dict set stored $key $value
    }
    close $channel

    if {![dict exists $stored version] || [dict get $stored version] ne $ConfigVersion} {
        # Nothing is read back, and the next save rewrites the file in the
        # current format.
        return
    }

    # Only known keys are applied: a hand-edited file must not be able to
    # inject arbitrary entries into the state array.
    foreach key {model spkmodel threshold minframes maxspeakers} {
        if {[dict exists $stored $key]} { set S($key) [dict get $stored $key] }
    }
}

proc ::va::ui::saveConfig {} {
    variable S
    variable ConfigVersion
    if {[catch {open [configPath] w} channel]} { return }
    puts $channel "# voiceannotate"
    puts $channel "version = $ConfigVersion"
    foreach key {model spkmodel threshold minframes maxspeakers} {
        puts $channel "$key = $S($key)"
    }
    close $channel
}

# The directory the application lives in -- the one holding bin/ and models/.
# app.tcl sits at tcl/ in the source tree but at share/voiceannotate/ once
# installed, so the root is one or two levels up depending on which; the
# installer's bundled models were invisible until this told the two apart.
proc ::va::ui::appRoot {} {
    set dir [file normalize $::va::scriptDir]
    if {[file tail $dir] eq "voiceannotate" && [file tail [file dirname $dir]] eq "share"} {
        return [file dirname [file dirname $dir]]
    }
    return [file dirname $dir]
}

# Every directory a model may sit in: beside the application, where "make
# models" and the installer put them, and the home directory the download
# dialog falls back to when the tree itself cannot be written to.
proc ::va::ui::modelSearchPath {} {
    return [list \
        [file join [appRoot] models] \
        [file join $::va::scriptDir models] \
        [file join [file normalize ~] .voiceannotate models] \
        models]
}

# Looks for models in ./models beside the application, so a first launch after
# "make models" works with nothing to configure.
proc ::va::ui::autodetectModels {} {
    variable S

    foreach directory [modelSearchPath] {
        if {![file isdirectory $directory]} { continue }
        foreach entry [lsort [glob -nocomplain -directory $directory -type d *]] {
            set name [file tail $entry]
            if {[string match -nocase "*spk*" $name]} {
                if {$S(spkmodel) eq ""} { set S(spkmodel) $entry }
            } elseif {[file isdirectory [file join $entry am]] ||
                      [file isdirectory [file join $entry conf]]} {
                if {$S(model) eq ""} { set S(model) $entry }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Building the interface
# ---------------------------------------------------------------------------

proc ::va::ui::chooseTheme {} {
    # Native theme first; clam is the best fallback on X11, where the default
    # one looks dated.
    set preferred [list]
    switch -- [tk windowingsystem] {
        aqua  { set preferred {aqua} }
        win32 { set preferred {vista xpnative winnative} }
        default { set preferred {clam} }
    }
    foreach theme $preferred {
        if {[lsearch -exact [ttk::style theme names] $theme] >= 0} {
            catch {ttk::style theme use $theme}
            return
        }
    }
}

proc ::va::ui::buildMenu {} {
    set mod [modifier]
    menu .menubar -tearoff 0
    . configure -menu .menubar

    menu .menubar.file -tearoff 0
    .menubar add cascade -label "File" -menu .menubar.file -underline 0
    .menubar.file add command -label "Open audio file..." \
        -accelerator [accel O] -command ::va::ui::browseAudio
    .menubar.file add separator
    .menubar.file add command -label "Save transcript beside the audio" \
        -accelerator [accel S] -command {::va::ui::saveBesideAudio 1}
    .menubar.file add separator

    menu .menubar.file.export -tearoff 0
    .menubar.file add cascade -label "Export as" -menu .menubar.file.export
    foreach {label format} {
        "Annotated text (.txt)" txt
        "Subtitles (.srt)"      srt
        "WebVTT (.vtt)"         vtt
        "Full JSON (.json)"     json
        "Spreadsheet (.csv)"    csv
    } {
        .menubar.file.export add command -label $label \
            -command [list ::va::ui::exportAs $format]
    }

    if {![isMac]} {
        .menubar.file add separator
        .menubar.file add command -label "Quit" -accelerator [accel Q] \
            -command ::va::ui::quit
    }

    menu .menubar.run -tearoff 0
    .menubar add cascade -label "Transcription" -menu .menubar.run -underline 0
    .menubar.run add command -label "Start" -accelerator [accel R] \
        -command ::va::ui::start
    .menubar.run add command -label "Cancel" -command ::va::ui::cancel
    .menubar.run add separator
    .menubar.run add command -label "Regroup speakers" -command ::va::ui::recluster

    menu .menubar.help -tearoff 0
    .menubar add cascade -label "Help" -menu .menubar.help -underline 0
    .menubar.help add command -label "About" -command ::va::ui::about

    bind . <$mod-o> {::va::ui::browseAudio; break}
    bind . <$mod-r> {::va::ui::start; break}
    bind . <$mod-s> {::va::ui::saveBesideAudio 1; break}
    bind . <$mod-q> {::va::ui::quit; break}
}

proc ::va::ui::buildToolbar {} {
    variable S
    # A direct child of the main window, so ".bar" rather than "..bar".
    set bar .bar
    ttk::frame $bar -padding {8 8 8 4}

    ttk::label $bar.label -text "Audio file:"
    ttk::entry $bar.path -textvariable ::va::ui::S(audio)
    ttk::button $bar.browse -text "Browse..." -command ::va::ui::browseAudio
    ttk::button $bar.start -text "Transcribe" -command ::va::ui::start -default active
    ttk::button $bar.cancel -text "Cancel" -command ::va::ui::cancel -state disabled

    grid $bar.label $bar.path $bar.browse $bar.start $bar.cancel \
        -sticky ew -padx {0 6}
    grid configure $bar.label -padx {0 6}
    grid columnconfigure $bar 1 -weight 1
    pack $bar -side top -fill x
}

proc ::va::ui::buildTable {parent} {
    ttk::frame $parent.table
    set frame $parent.table

    set columns {start end duration speaker text}
    ttk::treeview $frame.tree -columns $columns -show headings \
        -yscrollcommand [list $frame.vs set] -xscrollcommand [list $frame.hs set] \
        -selectmode browse
    ttk::scrollbar $frame.vs -orient vertical -command [list $frame.tree yview]
    ttk::scrollbar $frame.hs -orient horizontal -command [list $frame.tree xview]

    $frame.tree heading start -text "Start"
    $frame.tree heading end -text "End"
    $frame.tree heading duration -text "Length"
    $frame.tree heading speaker -text "Speaker"
    $frame.tree heading text -text "Transcript"

    $frame.tree column start -width 90 -minwidth 80 -stretch 0 -anchor center
    $frame.tree column end -width 90 -minwidth 80 -stretch 0 -anchor center
    $frame.tree column duration -width 70 -minwidth 60 -stretch 0 -anchor e
    $frame.tree column speaker -width 150 -minwidth 100 -stretch 0
    $frame.tree column text -width 560 -minwidth 200 -stretch 1

    grid $frame.tree $frame.vs -sticky nsew
    grid $frame.hs -sticky ew
    grid columnconfigure $frame 0 -weight 1
    grid rowconfigure $frame 0 -weight 1

    bind $frame.tree <<TreeviewSelect>> ::va::ui::onSegmentSelect
    bind $frame.tree <Button-3> {::va::ui::segmentMenu %x %y %X %Y}
    # On macOS a right click usually arrives as Control-click.
    bind $frame.tree <Control-Button-1> {::va::ui::segmentMenu %x %y %X %Y}

    menu $frame.tree.popup -tearoff 0
    return $frame
}

proc ::va::ui::buildTextView {parent} {
    ttk::frame $parent.textview
    set frame $parent.textview

    text $frame.text -wrap word -yscrollcommand [list $frame.vs set] \
        -padx 12 -pady 10 -borderwidth 0 -highlightthickness 0 \
        -state disabled -takefocus 0
    ttk::scrollbar $frame.vs -orient vertical -command [list $frame.text yview]

    grid $frame.text $frame.vs -sticky nsew
    grid columnconfigure $frame 0 -weight 1
    grid rowconfigure $frame 0 -weight 1

    $frame.text tag configure timecode -foreground "#6e7781"
    $frame.text tag configure body -lmargin1 0 -lmargin2 16 -spacing3 6
    return $frame
}

proc ::va::ui::buildSidebar {parent} {
    variable S
    ttk::frame $parent.side -padding {8 4 8 8}
    set side $parent.side

    # --- speakers ----------------------------------------------------------
    ttk::labelframe $side.speakers -text "Speakers" -padding 6
    set sp $side.speakers
    ttk::treeview $sp.tree -columns {name time count} -show headings -height 7 \
        -selectmode browse -yscrollcommand [list $sp.vs set]
    ttk::scrollbar $sp.vs -orient vertical -command [list $sp.tree yview]
    $sp.tree heading name -text "Name"
    $sp.tree heading time -text "Speech"
    $sp.tree heading count -text "Seg."
    $sp.tree column name -width 130 -minwidth 80 -stretch 1
    $sp.tree column time -width 70 -minwidth 60 -stretch 0 -anchor e
    $sp.tree column count -width 45 -minwidth 40 -stretch 0 -anchor e

    ttk::entry $sp.name -textvariable ::va::ui::S(renameEntry)
    ttk::button $sp.rename -text "Rename" -command ::va::ui::renameSpeaker

    grid $sp.tree $sp.vs -sticky nsew
    grid $sp.name -row 1 -column 0 -sticky ew -pady {6 0}
    grid $sp.rename -row 1 -column 1 -sticky ew -pady {6 0} -padx {4 0}
    grid columnconfigure $sp 0 -weight 1
    grid rowconfigure $sp 0 -weight 1

    bind $sp.tree <<TreeviewSelect>> ::va::ui::onSpeakerSelect
    bind $sp.name <Return> {::va::ui::renameSpeaker; break}

    # --- grouping ----------------------------------------------------------
    ttk::labelframe $side.group -text "Voice grouping" -padding 6
    set gr $side.group

    ttk::label $gr.thresholdLabel -text "Sensitivity"
    ttk::label $gr.thresholdValue -textvariable ::va::ui::S(thresholdText) -width 5 -anchor e
    # The range is centred on zero because similarities are measured after the
    # recording's mean has been removed: they spread around 0, not near 1.
    ttk::scale $gr.threshold -from -0.20 -to 0.60 -orient horizontal \
        -variable ::va::ui::S(threshold) -command ::va::ui::onThresholdChange
    ttk::label $gr.hint -text "Towards the right: splits voices apart." \
        -foreground "#57606a" -wraplength 220 -justify left

    ttk::label $gr.maxLabel -text "Number of speakers"
    ttk::spinbox $gr.max -from 0 -to 20 -width 5 \
        -textvariable ::va::ui::S(maxspeakers) -state readonly
    ttk::label $gr.maxHint -text "0 = let the tool decide." -foreground "#57606a"

    ttk::label $gr.minLabel -text "Minimum length (x10 ms)"
    ttk::spinbox $gr.min -from 5 -to 300 -increment 5 -width 5 \
        -textvariable ::va::ui::S(minframes)

    ttk::button $gr.apply -text "Regroup" -command ::va::ui::recluster

    grid $gr.thresholdLabel $gr.thresholdValue -sticky w
    grid $gr.threshold - -sticky ew -pady {2 0}
    grid $gr.hint - -sticky w -pady {2 6}
    grid $gr.maxLabel $gr.max -sticky w -pady 2
    grid $gr.maxHint - -sticky w -pady {0 6}
    grid $gr.minLabel $gr.min -sticky w -pady 2
    grid $gr.apply - -sticky ew -pady {8 0}
    grid columnconfigure $gr 0 -weight 1

    # --- models ------------------------------------------------------------
    ttk::labelframe $side.models -text "Vosk models" -padding 6
    set md $side.models
    ttk::label $md.modelLabel -text "Recognition"
    ttk::entry $md.model -textvariable ::va::ui::S(model)
    ttk::button $md.modelBrowse -text "..." -width 3 \
        -command [list ::va::ui::browseModel model "Recognition model"]
    ttk::label $md.spkLabel -text "Speakers (optional)"
    ttk::entry $md.spk -textvariable ::va::ui::S(spkmodel)
    ttk::button $md.spkBrowse -text "..." -width 3 \
        -command [list ::va::ui::browseModel spkmodel "Speaker model"]

    ttk::button $md.download -text "Download a model..." \
        -command ::va::ui::openCatalogue

    grid $md.modelLabel - -sticky w
    grid $md.model $md.modelBrowse -sticky ew -pady {2 6}
    grid $md.spkLabel - -sticky w
    grid $md.spk $md.spkBrowse -sticky ew -pady {2 0}
    grid $md.download - -sticky ew -pady {8 0}
    grid columnconfigure $md 0 -weight 1

    pack $sp -side top -fill both -expand 1
    pack $gr -side top -fill x -pady {8 0}
    pack $md -side top -fill x -pady {8 0}
    return $side
}

proc ::va::ui::buildStatusbar {} {
    set st .status
    ttk::frame $st -padding {8 4 8 6}
    ttk::progressbar $st.bar -mode determinate -maximum 100 \
        -variable ::va::ui::S(progress) -length 180
    ttk::label $st.text -textvariable ::va::ui::S(status) -anchor w
    ttk::label $st.stats -textvariable ::va::ui::S(stats) -anchor e -foreground "#57606a"

    pack $st.bar -side left -padx {0 10}
    pack $st.text -side left -fill x -expand 1
    pack $st.stats -side right
    pack $st -side bottom -fill x
}

# Puts a window in the middle of the screen. Left to itself, Tk opens at
# whatever corner the window manager picks, which on a wide screen can be a long
# way from where the user is looking.
proc ::va::ui::centreWindow {window} {
    # Sizes are only known once the geometry manager has run.
    update idletasks

    # The requested size ignores "wm minsize", so a window whose contents ask
    # for less than its minimum would be placed off centre by the difference.
    lassign [wm minsize $window] minWidth minHeight
    set width [expr {max([winfo reqwidth $window], $minWidth)}]
    set height [expr {max([winfo reqheight $window], $minHeight)}]

    # Never negative: on a screen shorter than the window that would push the
    # title bar out of reach, and with it any way to move the window back.
    set x [expr {max(([winfo screenwidth $window] - $width) / 2, 0)}]
    set y [expr {max(([winfo screenheight $window] - $height) / 2, 0)}]
    wm geometry $window "+$x+$y"
}

proc ::va::ui::build {} {
    wm title . "voiceannotate"
    wm minsize . 900 560
    # Hidden until it has been placed, otherwise it shows up in the corner and
    # visibly jumps to the middle.
    wm withdraw .
    chooseTheme
    buildMenu
    buildToolbar

    ttk::panedwindow .panes -orient horizontal
    ttk::frame .panes.main

    ttk::notebook .panes.main.book
    set table [buildTable .panes.main.book]
    set textview [buildTextView .panes.main.book]
    .panes.main.book add $table -text "Segments"
    .panes.main.book add $textview -text "Running text"
    pack .panes.main.book -fill both -expand 1 -padx {8 4} -pady 4
    bind .panes.main.book <<NotebookTabChanged>> ::va::ui::onTabChange

    set side [buildSidebar .panes]
    .panes add .panes.main -weight 3
    .panes add $side -weight 1
    pack .panes -side top -fill both -expand 1

    buildStatusbar

    wm protocol . WM_DELETE_WINDOW ::va::ui::quit
    onThresholdChange [set ::va::ui::S(threshold)]

    centreWindow .
    wm deiconify .
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc ::va::ui::browseAudio {} {
    variable S
    set types {
        {"Audio (MP3, WAV)"  {.mp3 .wav .wave}}
        {"MP3"               {.mp3}}
        {"WAV"               {.wav .wave}}
        {"All files"         *}
    }
    set initial [expr {$S(audio) ne "" ? [file dirname $S(audio)] : [pwd]}]
    set path [tk_getOpenFile -parent . -title "Choose an audio file" \
        -filetypes $types -initialdir $initial]
    if {$path ne ""} {
        set S(audio) $path
        # A new file means a new target: nothing is confirmed for it yet.
        set S(autosavePath) ""
        set S(autosaveOk) 0
        say "Selected: [file tail $path]"
    }
}

proc ::va::ui::browseModel {key title} {
    variable S
    set initial [expr {$S($key) ne "" ? $S($key) : [pwd]}]
    set path [tk_chooseDirectory -parent . -title $title -initialdir $initial -mustexist 1]
    if {$path ne ""} {
        set S($key) $path
        saveConfig
    }
}

proc ::va::ui::start {} {
    variable S
    if {$S(running)} { return }

    if {$S(audio) eq ""} {
        warn "No file" "Choose an audio file first."
        return
    }
    if {![file readable $S(audio)]} {
        oops "Cannot read file" "Unable to read:\n$S(audio)"
        return
    }
    if {$S(model) eq "" || ![file isdirectory $S(model)]} {
        oops "No model" \
            "Point to the directory of a Vosk recognition model.\n\n\"make models\" downloads one into ./models."
        return
    }
    if {$S(spkmodel) ne "" && ![file isdirectory $S(spkmodel)]} {
        oops "No model" "The speaker model cannot be found:\n$S(spkmodel)"
        return
    }
    if {$S(spkmodel) eq ""} {
        set answer [tk_messageBox -parent . -icon question -type yesno \
            -title "No speaker model" \
            -message "Without a speaker model the audio is still transcribed, but every passage is attributed to a single voice.\n\nContinue anyway?"]
        if {$answer ne "yes"} { return }
    }

    clearResults
    saveConfig

    if {[catch {
        ::va::start -audio $S(audio) -model $S(model) -spkmodel $S(spkmodel) \
            -threshold $S(threshold) -minframes $S(minframes) \
            -maxspeakers $S(maxspeakers)
    } message]} {
        oops "Cannot start" $message
        return
    }

    set S(running) 1
    set S(progress) 0
    setBusy 1
    say "Loading models..."
    schedulePoll
}

proc ::va::ui::cancel {} {
    variable S
    if {!$S(running)} { return }
    ::va::cancel
    say "Cancelling..."
}

proc ::va::ui::setBusy {busy} {
    set state [expr {$busy ? "disabled" : "normal"}]
    .bar.start configure -state $state
    .bar.browse configure -state $state
    .bar.path configure -state [expr {$busy ? "readonly" : "normal"}]
    .bar.cancel configure -state [expr {$busy ? "normal" : "disabled"}]
    .panes.side.group.apply configure -state $state
    .panes.side.speakers.rename configure -state $state
    .menubar.run entryconfigure "Start" -state $state
    .menubar.run entryconfigure "Cancel" -state [expr {$busy ? "normal" : "disabled"}]
}

proc ::va::ui::clearResults {} {
    variable S
    .panes.main.book.table.tree delete [.panes.main.book.table.tree children {}]
    .panes.side.speakers.tree delete [.panes.side.speakers.tree children {}]
    set widget .panes.main.book.textview.text
    $widget configure -state normal
    $widget delete 1.0 end
    $widget configure -state disabled
    set S(segments) 0
    set S(speakers) 0
    set S(selected) -1
    set S(stats) ""
}

# ---------------------------------------------------------------------------
# Saving beside the audio
#
# The transcript is written next to its source with the same base name and a
# .txt extension, so the two stay together without anyone having to pick a
# location. It is rewritten whenever the text on screen changes, so the file is
# never a stale copy of what the user is looking at.
# ---------------------------------------------------------------------------

proc ::va::ui::autosaveTarget {} {
    variable S
    if {$S(audio) eq ""} { return "" }
    # "file rootname" strips the extension and keeps the directory, which is
    # exactly the naming rule we want.
    return "[file rootname $S(audio)].txt"
}

# Writes the transcript beside the audio. `explicit` marks a request that came
# from the menu, which reports success out loud and asks about an existing file
# even when an automatic save has already been declined.
proc ::va::ui::saveBesideAudio {{explicit 0}} {
    variable S

    if {$S(segments) == 0} {
        if {$explicit} { warn "Nothing to save" "Transcribe a file first." }
        return 0
    }

    set target [autosaveTarget]
    if {$target eq ""} { return 0 }

    # An existing file is only overwritten once the user has said so. Without
    # this, a stray notes file sitting next to the audio would be destroyed by
    # a transcription the user never connected to it.
    if {$target ne $S(autosavePath)} {
        set S(autosavePath) $target
        set S(autosaveOk) 0
    }
    if {!$S(autosaveOk) && [file exists $target]} {
        set answer [tk_messageBox -parent . -icon question -type yesno \
            -title "File already exists" \
            -message "[file tail $target] already exists in [file dirname $target].\n\nOverwrite it with the transcript?"]
        if {$answer ne "yes"} {
            say "Not saved. Use File > Export as to choose another name."
            return 0
        }
    }
    set S(autosaveOk) 1

    if {[catch {::va::export $target txt} message]} {
        oops "Cannot save" $message
        set S(autosaveOk) 0
        return 0
    }
    if {$explicit} { say "Saved: $target" }
    return 1
}

# Called after any edit that changes the text, so the saved file keeps up.
# Silent when no file has been written yet: an edit should not be what creates
# the file for the first time.
proc ::va::ui::refreshSavedFile {} {
    variable S
    if {!$S(autosaveOk)} { return }
    if {[autosaveTarget] ne $S(autosavePath)} { return }
    catch {::va::export $S(autosavePath) txt}
}

# ---------------------------------------------------------------------------
# Downloading models
#
# Vosk publishes its catalogue as JSON, one entry per model carrying a download
# URL and a byte count. The dialog below fetches that list, filters it by
# language, and unpacks the chosen archive into the models directory, so a
# first run needs nothing from the command line.
#
# The transfer is done by borrowed programs rather than by an HTTP stack and a
# zip reader of our own: curl to fetch, and whatever can open a zip to unpack
# (see unpackCommand). They run through the event loop rather than [exec]: a
# full model is well over a gigabyte, and a blocking call would freeze the
# window for the whole download.
# ---------------------------------------------------------------------------

namespace eval ::va::ui {
    variable CatalogueUrl "https://alphacephei.com/vosk/models/model-list.json"
    variable Catalogue {}
    variable Transfer
    array set Transfer {pipe "" output "" target "" expected 0 timer ""}

    # The server gives out about 0.7 MB/s per connection whatever else is
    # happening, so asking for a model in several pieces at once adds up almost
    # linearly: measured on one 48 MB slice, a single connection took 61 s and
    # eight took 9. The curve flattens past that, and eight is as much as a
    # freely hosted service should be asked for at one time.
    variable Connections 8
    # Under this, splitting costs more in requests than it saves.
    variable SplitThreshold 4194304
    variable Parts
    # Which program opens the archive, worked out on first use. See unpackers.
    variable Unpacker
}

proc ::va::ui::resetParts {} {
    variable Parts
    array set Parts {pending 0 failed 0 output "" files {} pipes {} target "" expected 0 done ""}
}
::va::ui::resetParts

# One transfer at a time, whether it is running as one process or as several.
proc ::va::ui::transferRunning {} {
    variable Transfer
    variable Parts
    return [expr {$Transfer(pipe) ne "" || $Parts(pending) > 0}]
}

proc ::va::ui::humanBytes {bytes} {
    if {$bytes < 1024} { return "$bytes B" }
    set units {KiB MiB GiB}
    set value [expr {double($bytes) / 1024}]
    set index 0
    while {$value >= 1024 && $index < 2} {
        set value [expr {$value / 1024}]
        incr index
    }
    return [format "%.1f %s" $value [lindex $units $index]]
}

# Missing keys are normal here: the catalogue is someone else's file, and a
# field that disappears upstream must not take the dialog down with it.
proc ::va::ui::field {entry key {fallback ""}} {
    if {[dict exists $entry $key]} { return [dict get $entry $key] }
    return $fallback
}

proc ::va::ui::catalogueStatus {message} {
    variable S
    set S(catalogueStatus) $message
}

proc ::va::ui::installedModelPath {name} {
    foreach directory [modelSearchPath] {
        set path [file join $directory $name]
        if {[file isdirectory $path]} { return $path }
    }
    return ""
}

# Where a download is unpacked: the tree's own models directory when it can be
# written to, since that is where "make models" puts them, and the home
# directory when the application has been installed somewhere read-only.
proc ::va::ui::modelsDir {} {
    set preferred [file join [appRoot] models]
    # Never inside a macOS application bundle, even a writable one in
    # ~/Applications: a bundle is sealed by its signature, and what it carries
    # belongs to the installer, not to the user.
    if {![string match "*.app/*" $preferred] &&
        ![catch {file mkdir $preferred}] && [file writable $preferred]} {
        return $preferred
    }
    set fallback [file join [file normalize ~] .voiceannotate models]
    file mkdir $fallback
    return $fallback
}

# Keeps what this application can load. Text-to-speech entries share the
# catalogue but have no use here, and an obsolete entry is one upstream has
# already replaced.
proc ::va::ui::usableModels {entries} {
    set out {}
    foreach entry $entries {
        if {[field $entry name] eq "" || [field $entry url] eq ""} { continue }
        if {[string tolower [field $entry obsolete]] eq "true"} { continue }
        if {[field $entry type] eq "tts"} { continue }
        lappend out $entry
    }
    return $out
}

proc ::va::ui::modelKind {entry} {
    switch -- [field $entry type] {
        spk        { return "speakers" }
        small      { return "light" }
        big        { return "full" }
        big-lgraph { return "full, lgraph" }
    }
    return [field $entry type]
}

# Smallest first: the light models are what most people want, and a full one is
# a long download to start by accident.
proc ::va::ui::compareModels {a b} {
    set left [field $a size 0]
    set right [field $b size 0]
    if {$left < $right} { return -1 }
    if {$left > $right} { return 1 }
    return [string compare [field $a name] [field $b name]]
}

# ---------------------------------------------------------------------------
# The dialog
# ---------------------------------------------------------------------------

proc ::va::ui::openCatalogue {} {
    variable Catalogue
    if {[winfo exists .catalogue]} {
        raise .catalogue
        focus .catalogue
        return
    }
    buildCatalogueDialog
    if {[llength $Catalogue] > 0} {
        showCatalogue $Catalogue
    } else {
        fetchCatalogue
    }
}

proc ::va::ui::buildCatalogueDialog {} {
    variable S
    toplevel .catalogue
    wm title .catalogue "Download a model"
    wm transient .catalogue .
    wm minsize .catalogue 640 400
    wm protocol .catalogue WM_DELETE_WINDOW ::va::ui::closeCatalogue

    ttk::frame .catalogue.top -padding {10 10 10 4}
    ttk::label .catalogue.top.label -text "Language:"
    ttk::combobox .catalogue.top.lang -state readonly -width 30 \
        -textvariable ::va::ui::S(catalogueLang)
    bind .catalogue.top.lang <<ComboboxSelected>> ::va::ui::populateCatalogue
    pack .catalogue.top.label -side left
    pack .catalogue.top.lang -side left -padx {6 0}
    pack .catalogue.top -side top -fill x

    ttk::frame .catalogue.list -padding {10 4 10 4}
    ttk::treeview .catalogue.list.tree -columns {name size kind state} -show headings \
        -selectmode browse -yscrollcommand {.catalogue.list.vs set}
    ttk::scrollbar .catalogue.list.vs -orient vertical \
        -command {.catalogue.list.tree yview}
    .catalogue.list.tree heading name -text "Model"
    .catalogue.list.tree heading size -text "Size"
    .catalogue.list.tree heading kind -text "Kind"
    .catalogue.list.tree heading state -text "State"
    .catalogue.list.tree column name -width 320 -minwidth 200 -stretch 1
    .catalogue.list.tree column size -width 80 -minwidth 70 -stretch 0 -anchor e
    .catalogue.list.tree column kind -width 100 -minwidth 80 -stretch 0
    .catalogue.list.tree column state -width 90 -minwidth 70 -stretch 0
    grid .catalogue.list.tree .catalogue.list.vs -sticky nsew
    grid columnconfigure .catalogue.list 0 -weight 1
    grid rowconfigure .catalogue.list 0 -weight 1
    pack .catalogue.list -side top -fill both -expand 1
    bind .catalogue.list.tree <Double-1> ::va::ui::downloadSelected

    ttk::label .catalogue.hint -padding {10 0 10 0} -foreground "#57606a" \
        -wraplength 600 -justify left -text \
        "A light model is enough to try the tool out. The speakers model is what\
         makes voice grouping possible, and goes with any language."
    pack .catalogue.hint -side top -fill x

    ttk::frame .catalogue.foot -padding {10 6 10 10}
    ttk::progressbar .catalogue.foot.bar -mode determinate -maximum 100 \
        -variable ::va::ui::S(catalogueProgress) -length 170
    ttk::label .catalogue.foot.text -textvariable ::va::ui::S(catalogueStatus) -anchor w
    ttk::button .catalogue.foot.download -text "Download" -command ::va::ui::downloadSelected
    ttk::button .catalogue.foot.close -text "Close" -command ::va::ui::closeCatalogue
    pack .catalogue.foot.bar -side left -padx {0 10}
    pack .catalogue.foot.text -side left -fill x -expand 1
    pack .catalogue.foot.close -side right
    pack .catalogue.foot.download -side right -padx {0 6}
    pack .catalogue.foot -side bottom -fill x

    set S(catalogueProgress) 0
    catalogueStatus ""
}

proc ::va::ui::fetchCatalogue {} {
    variable CatalogueUrl
    set channel [file tempfile path]
    close $channel
    catalogueStatus "Fetching the list of models..."
    startDownload $CatalogueUrl $path 0 [list ::va::ui::onCatalogueFetched $path]
}

proc ::va::ui::onCatalogueFetched {path ok message} {
    variable Catalogue

    if {$ok} {
        set failed [catch {
            set channel [open $path r]
            fconfigure $channel -encoding utf-8
            set text [read $channel]
            close $channel
            usableModels [::va::json $text]
        } result]
    } else {
        set failed 1
        set result $message
    }
    catch {file delete -force $path}

    if {$failed || [llength $result] == 0} {
        catalogueStatus "The list of models is unavailable."
        if {[winfo exists .catalogue]} {
            tk_messageBox -parent .catalogue -icon error -title "No list of models" \
                -message "Vosk's model list could not be fetched.\n\n$result\n\nCheck the network connection, or point the panel at a model directory you already have."
        }
        return
    }
    set Catalogue $result
    showCatalogue $Catalogue
}

# Fills the language list and the table. Kept separate from the fetch so it can
# be driven from a list that came from anywhere -- which is what the interface
# test does, with no network in reach.
proc ::va::ui::showCatalogue {models} {
    variable Catalogue
    variable S
    set Catalogue $models
    if {![winfo exists .catalogue]} { return }

    set languages {}
    foreach entry $Catalogue {
        # "all" is the speaker model's language: it belongs with every one of
        # them, so it is not offered as a choice of its own.
        if {[field $entry lang] eq "all"} { continue }
        set label [field $entry lang_text [field $entry lang]]
        if {[lsearch -exact $languages $label] < 0} { lappend languages $label }
    }
    set languages [linsert [lsort -dictionary $languages] 0 "All languages"]
    .catalogue.top.lang configure -values $languages
    if {[lsearch -exact $languages $S(catalogueLang)] < 0} {
        set S(catalogueLang) "All languages"
    }

    populateCatalogue
    catalogueStatus "[llength $Catalogue] models available."
}

proc ::va::ui::populateCatalogue {} {
    variable Catalogue
    variable S
    if {![winfo exists .catalogue]} { return }
    set tree .catalogue.list.tree
    $tree delete [$tree children {}]

    set rows {}
    foreach entry $Catalogue {
        set universal [expr {[field $entry lang] eq "all"}]
        set language [field $entry lang_text [field $entry lang]]
        if {$S(catalogueLang) ne "All languages" && !$universal &&
            $language ne $S(catalogueLang)} {
            continue
        }
        lappend rows $entry
    }

    foreach entry [lsort -command ::va::ui::compareModels $rows] {
        set name [field $entry name]
        set installed [expr {[installedModelPath $name] ne ""}]
        $tree insert {} end -id $name -values [list \
            $name \
            [field $entry size_text [humanBytes [field $entry size 0]]] \
            [modelKind $entry] \
            [expr {$installed ? "installed" : ""}]]
    }
}

proc ::va::ui::closeCatalogue {} {
    if {[transferRunning]} {
        set answer [tk_messageBox -parent .catalogue -icon question -type yesno \
            -title "Stop the download" \
            -message "A download is still running. Stop it?"]
        if {$answer ne "yes"} { return }
        abortTransfer
    }
    stopProgress
    destroy .catalogue
}

# ---------------------------------------------------------------------------
# Transfers
# ---------------------------------------------------------------------------

# Runs a child process with its error output folded into its standard output,
# and calls `done ok message` once it exits.
proc ::va::ui::startProcess {command target expected done} {
    variable Transfer
    if {[transferRunning]} {
        uplevel #0 [list {*}$done 0 "another transfer is already running"]
        return
    }
    lappend command 2>@1
    if {[catch {open "|$command" r} pipe]} {
        uplevel #0 [list {*}$done 0 $pipe]
        return
    }
    fconfigure $pipe -blocking 0
    array set Transfer [list pipe $pipe output "" target $target expected $expected]
    fileevent $pipe readable [list ::va::ui::onTransferReadable $pipe $done]
    trackProgress
}

proc ::va::ui::onTransferReadable {pipe done} {
    variable Transfer
    if {[catch {read $pipe} chunk]} { set chunk "" }
    append Transfer(output) $chunk
    if {![eof $pipe]} { return }

    fileevent $pipe readable {}
    # A non-zero exit shows up here, as an error from close.
    set failed [catch {close $pipe} reason]
    set output [string trim $Transfer(output)]
    set Transfer(pipe) ""
    stopProgress

    if {$failed} {
        uplevel #0 [list {*}$done 0 [expr {$output ne "" ? $output : $reason}]]
    } else {
        uplevel #0 [list {*}$done 1 ""]
    }
}

# --fail so an HTTP error page is never mistaken for an archive, --location
# because the models sit behind a redirect.
proc ::va::ui::curlCommand {url target args} {
    return [list curl --fail --location --silent --show-error {*}$args \
        --output $target $url]
}

proc ::va::ui::startDownload {url target expected done} {
    variable Connections
    variable SplitThreshold
    file mkdir [file dirname $target]

    if {$expected >= $SplitThreshold} {
        startSegmentedDownload $url $target $expected $Connections $done
        return
    }
    startProcess [curlCommand $url $target] $target $expected $done
}

# The byte ranges the pieces cover, as inclusive pairs. The last one takes the
# remainder, so a size that does not divide evenly is still fetched to its final
# byte -- a gap here would only show up as a corrupt archive.
proc ::va::ui::partRanges {expected count} {
    set span [expr {$expected / $count}]
    set ranges {}
    for {set index 0} {$index < $count} {incr index} {
        set first [expr {$index * $span}]
        set last [expr {$index == $count - 1 ? $expected - 1 : $first + $span - 1}]
        lappend ranges [list $first $last]
    }
    return $ranges
}

# Asks for the file in several ranges at once. Each range lands in a file of its
# own and they are joined once they have all arrived, which keeps the progress
# reading to adding up their sizes.
proc ::va::ui::startSegmentedDownload {url target expected count done} {
    variable Transfer
    variable Parts

    resetParts
    set Parts(target) $target
    set Parts(expected) $expected
    set Parts(done) $done
    set Transfer(target) $target
    set Transfer(expected) $expected

    set index -1
    foreach range [partRanges $expected $count] {
        lassign $range first last
        set part "$target.part[incr index]"
        set command [curlCommand $url $part --range "$first-$last"]
        lappend command 2>@1

        if {[catch {open "|$command" r} pipe]} {
            set Parts(failed) 1
            set Parts(output) $pipe
            break
        }
        fconfigure $pipe -blocking 0
        lappend Parts(pipes) $pipe
        lappend Parts(files) $part
        incr Parts(pending)
        fileevent $pipe readable [list ::va::ui::onPartReadable $pipe]
    }

    # Nothing started at all: report it the same way as any other failure,
    # rather than leaving the caller waiting for a callback that never comes.
    if {$Parts(pending) == 0} {
        finishSegments
        return
    }
    trackProgress
}

proc ::va::ui::onPartReadable {pipe} {
    variable Parts
    if {[catch {read $pipe} chunk]} { set chunk "" }
    append Parts(output) $chunk
    if {![eof $pipe]} { return }

    fileevent $pipe readable {}
    if {[catch {close $pipe} reason]} {
        incr Parts(failed)
        if {[string trim $Parts(output)] eq ""} { set Parts(output) $reason }
    }
    incr Parts(pending) -1
    if {$Parts(pending) == 0} { finishSegments }
}

proc ::va::ui::finishSegments {} {
    variable Parts
    stopProgress

    set done $Parts(done)
    set failed $Parts(failed)
    set message [string trim $Parts(output)]
    set files $Parts(files)
    set target $Parts(target)
    set expected $Parts(expected)
    resetParts

    if {!$failed} {
        set failed [catch {joinParts $files $target $expected} message]
        if {$failed} { catch {file delete -force $target} }
    }
    foreach part $files { catch {file delete -force $part} }

    if {$failed} {
        if {$message eq ""} { set message "the download did not complete" }
        uplevel #0 [list {*}$done 0 $message]
    } else {
        uplevel #0 [list {*}$done 1 ""]
    }
}

# The unpacker wants one file and the ranges arrived separately. Reading 2 GB
# back and writing it out again measures at half a second on an SSD, against
# the minutes the split saves.
proc ::va::ui::joinParts {files target expected} {
    set out [open $target wb]
    try {
        foreach part $files {
            set in [open $part rb]
            try {
                fcopy $in $out
            } finally {
                close $in
            }
        }
    } finally {
        close $out
    }

    # A range that came back short would otherwise surface only as a corrupt
    # archive, long after the point where the cause is still visible.
    set size [file size $target]
    if {$expected > 0 && $size != $expected} {
        return -code error \
            "the download came back incomplete: [humanBytes $size] of [humanBytes $expected]"
    }
    return ""
}

# Unpacking the archive
#
# A stock Windows has no unzip: downloading a model from the interface is the
# one thing a user can do without ever opening a build shell, so it cannot be
# what the build happens to need. Windows has shipped bsdtar as tar.exe since
# Windows 10 1803, and bsdtar reads zip; macOS has both; Linux distributions
# have unzip, and it is a prerequisite there anyway.
#
# GNU tar is deliberately not a candidate. It is what "tar" is on most Linux
# machines and it cannot read a zip at all, which is why the version is asked
# for rather than the name being trusted.
proc ::va::ui::unpackers {} {
    set found {}
    set unzip [lindex [auto_execok unzip] 0]
    if {$unzip ne ""} { lappend found [list unzip $unzip] }
    foreach candidate [tarCandidates] {
        if {[readsZip $candidate]} {
            lappend found [list tar $candidate]
            break
        }
    }
    return $found
}

# System32 first on Windows: that one is bsdtar for certain, where a "tar" on
# PATH can be the GNU one from a Git or MSYS2 installation.
proc ::va::ui::tarCandidates {} {
    set candidates {}
    if {$::tcl_platform(platform) eq "windows" && [info exists ::env(SystemRoot)]} {
        lappend candidates [file join $::env(SystemRoot) System32 tar.exe]
    }
    foreach name {tar bsdtar} {
        set path [lindex [auto_execok $name] 0]
        if {$path ne ""} { lappend candidates $path }
    }
    return $candidates
}

# GNU tar answers "tar (GNU tar) 1.35" and bsdtar names both itself and
# libarchive. Mistaking the first for the second would show up only at the end
# of a long download, as an archive that will not open.
proc ::va::ui::isBsdtar {banner} {
    return [expr {[string match -nocase "*bsdtar*" $banner]
               || [string match -nocase "*libarchive*" $banner]}]
}

proc ::va::ui::readsZip {program} {
    if {[catch {exec $program --version} banner]} { return 0 }
    return [isBsdtar $banner]
}

# Worked out once: the answer cannot change while the application runs, and
# readsZip starts a process to find it.
proc ::va::ui::unpackCommand {archive destination} {
    variable Unpacker
    if {![info exists Unpacker]} { set Unpacker [lindex [unpackers] 0] }
    lassign $Unpacker kind program
    switch -- $kind {
        unzip { return [list $program -q -o $archive -d $destination] }
        tar   { return [list $program -x -f $archive -C $destination] }
    }
    return -code error \
        "nothing on this machine can unpack a zip archive: install unzip"
}

proc ::va::ui::startUnpack {archive destination done} {
    file mkdir $destination
    if {[catch {unpackCommand $archive $destination} result]} {
        uplevel #0 [list {*}$done 0 $result]
        return
    }
    startProcess $result $destination 0 $done
}

# curl's own progress output would have to be scraped out of terminal control
# sequences; the size of the files on disk says the same thing.
proc ::va::ui::transferredBytes {} {
    variable Transfer
    variable Parts
    set total 0
    if {[llength $Parts(files)] > 0} {
        foreach part $Parts(files) { catch {incr total [file size $part]} }
        return $total
    }
    catch {set total [file size $Transfer(target)]}
    return $total
}

proc ::va::ui::trackProgress {} {
    variable Transfer
    variable S
    set Transfer(timer) ""
    if {![transferRunning]} { return }

    if {$Transfer(expected) > 0} {
        set got [transferredBytes]
        set S(catalogueProgress) [expr {100.0 * $got / $Transfer(expected)}]
        catalogueStatus "Downloading: [humanBytes $got] of [humanBytes $Transfer(expected)]"
    }
    set Transfer(timer) [after 300 ::va::ui::trackProgress]
}

proc ::va::ui::stopProgress {} {
    variable Transfer
    if {$Transfer(timer) ne ""} { after cancel $Transfer(timer) }
    set Transfer(timer) ""
}

# Best effort: curl writes to a file rather than to the pipe, so closing our end
# does not necessarily stop it. The process id is the only handle Tcl gives on
# the child, and the way to signal it differs per platform.
proc ::va::ui::killPipe {pipe} {
    catch {fileevent $pipe readable {}}
    catch {
        foreach child [pid $pipe] {
            if {$::tcl_platform(platform) eq "windows"} {
                exec taskkill /F /PID $child
            } else {
                exec kill $child
            }
        }
    }
    catch {close $pipe}
}

proc ::va::ui::abortTransfer {} {
    variable Transfer
    variable Parts

    foreach pipe $Parts(pipes) { killPipe $pipe }
    foreach part $Parts(files) { catch {file delete -force $part} }
    resetParts

    if {$Transfer(pipe) ne ""} {
        set pipe $Transfer(pipe)
        set Transfer(pipe) ""
        killPipe $pipe
        # Only ever a half-written archive: an unpack's target is a directory,
        # and deleting that would take the user's other models with it.
        if {[file isfile $Transfer(target)]} {
            catch {file delete -force $Transfer(target)}
        }
    }
    stopProgress
}

# ---------------------------------------------------------------------------
# Downloading the selected model
# ---------------------------------------------------------------------------

proc ::va::ui::catalogueBusy {busy} {
    if {![winfo exists .catalogue]} { return }
    .catalogue.foot.download configure -state [expr {$busy ? "disabled" : "normal"}]
    .catalogue.top.lang configure -state [expr {$busy ? "disabled" : "readonly"}]
}

proc ::va::ui::catalogueEntry {name} {
    variable Catalogue
    foreach entry $Catalogue {
        if {[field $entry name] eq $name} { return $entry }
    }
    return ""
}

proc ::va::ui::downloadSelected {} {
    variable S
    if {![winfo exists .catalogue]} { return }
    if {[transferRunning]} { return }

    set selection [.catalogue.list.tree selection]
    if {$selection eq ""} {
        catalogueStatus "Select a model in the list first."
        return
    }
    set entry [catalogueEntry [lindex $selection 0]]
    if {$entry eq ""} { return }
    set name [field $entry name]

    # Already on disk: put it to use rather than fetch it a second time.
    set existing [installedModelPath $name]
    if {$existing ne ""} {
        useModel $entry $existing
        catalogueStatus "Already downloaded. $name is now selected."
        return
    }

    set destination [modelsDir]
    set archive [file join $destination .cache "$name.zip"]
    set S(catalogueProgress) 0
    catalogueBusy 1
    catalogueStatus "Starting the download..."
    startDownload [field $entry url] $archive [field $entry size 0] \
        [list ::va::ui::onModelDownloaded $entry $archive $destination]
}

proc ::va::ui::onModelDownloaded {entry archive destination ok message} {
    variable S
    if {!$ok} {
        catch {file delete -force $archive}
        set S(catalogueProgress) 0
        catalogueBusy 0
        catalogueStatus "The download failed."
        if {[winfo exists .catalogue]} {
            tk_messageBox -parent .catalogue -icon error -title "Download failed" \
                -message "[field $entry name] could not be downloaded.\n\n$message"
        }
        return
    }

    set S(catalogueProgress) 100
    catalogueStatus "Unpacking [field $entry name]..."
    # The archive is big enough that unpacking takes a while, and there is no
    # progress to report from it -- a moving bar at least shows it is alive.
    if {[winfo exists .catalogue]} {
        .catalogue.foot.bar configure -mode indeterminate
        .catalogue.foot.bar start 15
    }
    startUnpack $archive $destination \
        [list ::va::ui::onModelUnpacked $entry $archive $destination]
}

proc ::va::ui::onModelUnpacked {entry archive destination ok message} {
    variable S
    if {[winfo exists .catalogue]} {
        .catalogue.foot.bar stop
        .catalogue.foot.bar configure -mode determinate
    }
    set S(catalogueProgress) 0
    catalogueBusy 0
    # The archive is only a means to an end, and a full model's zip is well over
    # a gigabyte to leave lying around.
    catch {file delete -force $archive}

    set name [field $entry name]
    set path [file join $destination $name]
    if {!$ok || ![file isdirectory $path]} {
        catalogueStatus "The archive could not be unpacked."
        if {[winfo exists .catalogue]} {
            tk_messageBox -parent .catalogue -icon error -title "Unpacking failed" \
                -message "$name was downloaded but could not be unpacked.\n\n$message"
        }
        return
    }

    useModel $entry $path
    populateCatalogue
    catalogueStatus "$name is ready, and is now the selected model."
    say "Model ready: $name"
}

# A model that has just been downloaded is put to use straight away: having to
# then point the panel at it by hand would be a pointless second step.
proc ::va::ui::useModel {entry path} {
    variable S
    if {[field $entry type] eq "spk"} {
        set S(spkmodel) $path
    } else {
        set S(model) $path
    }
    saveConfig
}

# ---------------------------------------------------------------------------
# Event loop
#
# The C++ thread drops its events into a queue; this drains it. A timer rather
# than a callback from the thread: that is the only safe way to have a worker
# and a Tcl interpreter talk to each other.
# ---------------------------------------------------------------------------

proc ::va::ui::schedulePoll {} {
    variable PollId
    set PollId [after 100 ::va::ui::poll]
}

proc ::va::ui::poll {} {
    variable S
    variable PollId
    set PollId ""

    foreach event [::va::poll] {
        switch -- [dict get $event type] {
            status {
                say [dict get $event message]
            }
            progress {
                set S(progress) [expr {[dict get $event fraction] * 100.0}]
                set position [::va::timecode [dict get $event position]]
                set speed [format "%.1f" [dict get $event speed]]
                set S(stats) "$position    ${speed}x realtime    $S(segments) segments"
            }
            segment {
                appendSegment [dict get $event segment]
            }
            finished {
                onFinished $event
            }
            failed {
                set S(running) 0
                setBusy 0
                set S(progress) 0
                say "Failed."
                oops "Transcription failed" [dict get $event message]
            }
        }
    }

    if {$S(running)} { schedulePoll }
}

proc ::va::ui::onFinished {event} {
    variable S
    set S(running) 0
    setBusy 0
    set S(progress) 100

    refreshSpeakers
    # The final grouping sees the whole file, unlike the labels shown while the
    # transcription was running, so the table has to be redrawn.
    if {[dict get $event relabelled]} { refreshTable }
    refreshTextView

    set saved [saveBesideAudio]
    set elapsed [humanDuration [dict get $event elapsed]]
    set audio [humanDuration [dict get $event duration]]

    if {[dict get $event cancelled]} {
        set message "Interrupted: $S(segments) segments kept."
    } else {
        set message "Done: $S(segments) segments, $S(speakers) speaker(s), $audio of audio in $elapsed."
    }
    if {$saved} { append message "  Saved to [file tail $S(autosavePath)]." }
    say $message
}

# ---------------------------------------------------------------------------
# Showing results
# ---------------------------------------------------------------------------

proc ::va::ui::segmentRow {segment} {
    return [list \
        [::va::timecode [dict get $segment start]] \
        [::va::timecode [dict get $segment end]] \
        [format "%.1f s" [dict get $segment duration]] \
        [dict get $segment name] \
        [dict get $segment text]]
}

proc ::va::ui::ensureSpeakerTag {widget id} {
    set tag "spk$id"
    if {[lsearch -exact [$widget tag names] $tag] < 0} {
        $widget tag configure $tag -foreground [speakerColor $id]
    }
    return $tag
}

proc ::va::ui::appendSegment {segment} {
    variable S
    set tree .panes.main.book.table.tree
    set index [dict get $segment index]
    set id "seg$index"
    set tag [ensureSpeakerTag $tree [dict get $segment speaker]]

    $tree insert {} end -id $id -values [segmentRow $segment] -tags [list $tag]
    incr S(segments)

    # Follow the end of the list only while the user has not scrolled away,
    # otherwise re-reading an earlier passage mid-run becomes impossible.
    if {[lindex [$tree yview] 1] > 0.999} { $tree see $id }
}

proc ::va::ui::refreshTable {} {
    variable S
    set tree .panes.main.book.table.tree
    set selection [$tree selection]
    $tree delete [$tree children {}]

    foreach segment [::va::segments] {
        set index [dict get $segment index]
        set tag [ensureSpeakerTag $tree [dict get $segment speaker]]
        $tree insert {} end -id "seg$index" -values [segmentRow $segment] -tags [list $tag]
    }
    set S(segments) [llength [$tree children {}]]
    if {$selection ne "" && [$tree exists $selection]} {
        $tree selection set $selection
        $tree see $selection
    }
}

proc ::va::ui::refreshSpeakers {} {
    variable S
    set tree .panes.side.speakers.tree
    set selection [$tree selection]
    $tree delete [$tree children {}]

    set speakers [::va::speakers]
    set S(speakers) [llength $speakers]
    foreach speaker $speakers {
        set id [dict get $speaker id]
        set tag [ensureSpeakerTag $tree $id]
        $tree insert {} end -id "spk$id" -tags [list $tag] -values [list \
            [dict get $speaker name] \
            [humanDuration [dict get $speaker time]] \
            [dict get $speaker segments]]
    }
    if {$selection ne "" && [$tree exists $selection]} { $tree selection set $selection }
}

proc ::va::ui::refreshTextView {} {
    set widget .panes.main.book.textview.text
    $widget configure -state normal
    $widget delete 1.0 end

    set previous -2
    foreach segment [::va::segments] {
        set speaker [dict get $segment speaker]
        if {$speaker != $previous} {
            set tag [ensureSpeakerTag $widget $speaker]
            $widget tag configure $tag -foreground [speakerColor $speaker]
            if {$previous != -2} { $widget insert end "\n" }
            $widget insert end "[::va::timecode [dict get $segment start]]  " timecode
            $widget insert end "[dict get $segment name]\n" [list $tag]
            set previous $speaker
        }
        $widget insert end "[dict get $segment text]\n" body
    }
    $widget configure -state disabled
}

proc ::va::ui::onTabChange {} {
    # The text view is rebuilt when shown rather than on every segment: during
    # a long transcription that avoids redrawing it in a loop.
    variable S
    if {$S(running)} { return }
    if {[catch {.panes.main.book index current} current]} { return }
    if {$current == 1} { refreshTextView }
}

# ---------------------------------------------------------------------------
# Selection, renaming, reassignment
# ---------------------------------------------------------------------------

proc ::va::ui::onSegmentSelect {} {
    variable S
    set tree .panes.main.book.table.tree
    set selection [$tree selection]
    if {$selection eq ""} {
        set S(selected) -1
        return
    }
    set S(selected) [string range [lindex $selection 0] 3 end]
}

proc ::va::ui::onSpeakerSelect {} {
    variable S
    set tree .panes.side.speakers.tree
    set selection [$tree selection]
    if {$selection eq ""} { return }
    set S(renameEntry) [lindex [$tree item [lindex $selection 0] -values] 0]
}

proc ::va::ui::renameSpeaker {} {
    variable S
    set tree .panes.side.speakers.tree
    set selection [$tree selection]
    if {$selection eq ""} {
        warn "No speaker" "Select a speaker in the list first."
        return
    }
    set id [string range [lindex $selection 0] 3 end]
    set name [string trim $S(renameEntry)]
    ::va::speakername $id $name
    refreshSpeakers
    refreshTable
    refreshTextView
    refreshSavedFile
    say "Speaker renamed."
}

# Context menu on a segment: reassign the row to another speaker.
proc ::va::ui::segmentMenu {x y rootX rootY} {
    variable S
    if {$S(running)} { return }
    set tree .panes.main.book.table.tree
    set row [$tree identify row $x $y]
    if {$row eq ""} { return }
    $tree selection set $row
    set index [string range $row 3 end]

    set popup $tree.popup
    $popup delete 0 end
    foreach speaker [::va::speakers] {
        $popup add command -label "Assign to [dict get $speaker name]" \
            -command [list ::va::ui::assignSegment $index [dict get $speaker id]]
    }
    if {[llength [::va::speakers]] > 0} { $popup add separator }
    $popup add command -label "New speaker" \
        -command [list ::va::ui::assignSegment $index $S(speakers)]
    tk_popup $popup $rootX $rootY
}

proc ::va::ui::assignSegment {index speaker} {
    if {[catch {::va::assign $index $speaker} message]} {
        oops "Cannot reassign" $message
        return
    }
    refreshSpeakers
    refreshTable
    refreshTextView
    refreshSavedFile
    say "Segment reassigned."
}

proc ::va::ui::onThresholdChange {value} {
    variable S
    set S(thresholdText) [format "%.2f" $value]
}

proc ::va::ui::recluster {} {
    variable S
    if {$S(running)} { return }
    if {$S(segments) == 0} {
        warn "Nothing to regroup" "Transcribe a file first."
        return
    }

    if {[catch {
        ::va::recluster -threshold $S(threshold) -minframes $S(minframes) \
            -maxspeakers $S(maxspeakers)
    } result]} {
        oops "Cannot regroup" $result
        return
    }

    refreshSpeakers
    refreshTable
    refreshTextView
    refreshSavedFile
    say "Regrouped: $result speaker(s). Custom names have been reset."
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------

proc ::va::ui::exportAs {format} {
    variable S
    if {$S(segments) == 0} {
        warn "Nothing to export" "Transcribe a file first."
        return
    }

    array set descriptions {
        txt  {"Annotated text" .txt}
        srt  {"SubRip subtitles" .srt}
        vtt  {"WebVTT" .vtt}
        json {"JSON" .json}
        csv  {"CSV" .csv}
    }
    lassign $descriptions($format) label extension

    set initial ""
    if {$S(audio) ne ""} { set initial "[file rootname [file tail $S(audio)]]$extension" }

    set path [tk_getSaveFile -parent . -title "Export as $label" \
        -defaultextension $extension -initialfile $initial \
        -filetypes [list [list $label $extension] {"All files" *}]]
    if {$path eq ""} { return }

    if {[catch {::va::export $path $format} message]} {
        oops "Cannot export" $message
        return
    }
    say "Exported: [file tail $path]"
}

# ---------------------------------------------------------------------------
# Odds and ends
# ---------------------------------------------------------------------------

proc ::va::ui::about {} {
    tk_messageBox -parent . -icon info -title "About voiceannotate" -message \
"voiceannotate

Transcription with speaker annotation.
Engine: Vosk (Kaldi). Interface: Tcl/Tk [info patchlevel].

Voices are grouped from the speaker embeddings produced by the speaker model.
The sensitivity slider redoes that grouping without reprocessing the audio.

When a transcription finishes, the text is saved beside the audio file under
the same name with a .txt extension."
}

proc ::va::ui::quit {} {
    variable S
    variable PollId
    if {$S(running)} {
        set answer [tk_messageBox -parent . -icon question -type yesno \
            -title "Quit" -message "A transcription is running. Quit anyway?"]
        if {$answer ne "yes"} { return }
        ::va::cancel
    }
    if {$PollId ne ""} { after cancel $PollId }
    # Leaving a curl or an unpacker child behind would keep writing into the
    # models directory after the window it belongs to is gone.
    abortTransfer
    saveConfig
    destroy .
}

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

proc ::va::ui::main {} {
    variable S

    loadConfig
    autodetectModels
    build

    # Default wording lives in the interface, not in the C++: the exported
    # files then carry the same words as what is on screen.
    ::va::labels "Speaker" "Unknown"

    set selfTest 0
    foreach argument $::va::argv {
        if {$argument eq "--self-test"} {
            set selfTest 1
        } elseif {[file readable $argument]} {
            set S(audio) $argument
        }
    }

    if {$S(model) eq ""} {
        say "Point to a Vosk model in the panel on the right to begin."
    } else {
        say "Ready. Model: [file tail $S(model)]"
    }

    if {$selfTest} {
        # Builds the whole interface, exercises the refresh paths, then exits:
        # enough to validate the script with nobody watching.
        refreshSpeakers
        refreshTextView
        onThresholdChange $S(threshold)
        # The puts is guarded: a Windows GUI process has no stdout channel, and
        # the error would abort the script before the quit, leaving the window
        # open behind an error dialog. The exit status is the real signal.
        after 400 {
            catch {puts "self-test ok"}
            ::va::ui::quit
        }
    }
}

::va::ui::main
