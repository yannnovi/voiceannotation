# voiceannotate — User Guide

voiceannotate turns an MP3 or WAV recording into text and says **who is
speaking**: the transcript is cut into passages, and each passage is attributed
to a voice. Everything runs on your own machine; nothing is sent anywhere.

```
[00:00:00.120] Speaker 1:
  hello and thank you very much for coming in today for this interview

[00:00:04.830] Speaker 2:
  thank you, I'm very happy to be here this morning
```

The speech recognition is done by [Vosk](https://alphacephei.com/vosk/),
which works offline once it has a language model. Speakers are told apart by
comparing voiceprints, and you can adjust that grouping afterwards without
processing the audio again.

This guide covers the desktop application and the command-line tool. Building
from source is described in the README at the root of the project.

---

## Contents

1. [Installing](#1-installing)
2. [The first launch: models](#2-the-first-launch-models)
3. [Transcribing a file](#3-transcribing-a-file)
4. [Reading the result](#4-reading-the-result)
5. [Correcting the speakers](#5-correcting-the-speakers)
6. [Saving and exporting](#6-saving-and-exporting)
7. [The command line](#7-the-command-line)
8. [Keyboard shortcuts](#8-keyboard-shortcuts)
9. [What to expect](#9-what-to-expect)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Installing

### Windows

Run `voiceannotate-<version>-setup.exe`. It needs nothing else on the machine
— no runtime, no framework — and it does not ask for an administrator
password: the program is installed **for your user account only**, in

```
C:\Users\<you>\AppData\Local\Programs\voiceannotate
```

The installer speaks English or French, following the language of Windows.
It adds *voiceannotate* to the Start menu and, if you tick the option, a
shortcut on the desktop. The default installation already contains a small
French recognition model and the speaker model, so it can transcribe as soon
as it is done.

To remove it, use *Settings › Apps › Installed apps*, or run `uninstall.exe`
from the installation folder. If models were downloaded in the meantime, the
uninstaller asks whether to keep them: they can be large and slow to fetch
again.

### Linux and macOS

There is no installer; the program is built from source with `make`, and the
README lists the packages to install first. In short:

```sh
make deps      # fetches the Vosk library and the MP3 decoder
make models    # fetches a language model and the speaker model
make           # builds bin/voiceannotate and bin/voiceannotate-cli
make run       # starts the application
```

`make install PREFIX=~/.local` puts the binaries somewhere permanent.

---

## 2. The first launch: models

Vosk needs two things, both shown in the **Vosk models** panel on the right:

- **Recognition** — a language model. This is what turns sound into words, and
  it has to match the language spoken in the recording.
- **Speakers (optional)** — the speaker model, the same for every language.
  Without it, the whole transcript is attributed to a single speaker.

If the models are already in a `models` folder beside the application — the
Windows installer puts two there — they are picked up automatically and the
status bar reads *Ready. Model: …*. Otherwise:

**Download a model…** opens the list that Vosk publishes: some forty languages,
filtered with the menu at the top. Models are sorted from the lightest to the
heaviest and the ones already on disk are marked *installed*. The speaker
model appears whatever language is selected, since it serves them all. Pick
one, click **Download**; when it has been fetched and unpacked, it is selected
in the panel by itself — a speaker model goes into the *Speakers* field,
anything else into *Recognition*. The window stays usable during the
transfer, and *Close* offers to interrupt it.

The **…** buttons let you point to a model folder you obtained some other
way, for instance one unpacked by hand from <https://alphacephei.com/vosk/models>.

Downloaded models go into the `models` folder beside the application when it
can be written to — which is the case for the Windows installer — and into
`~/.voiceannotate/models` in your home directory otherwise. Both places are
searched at every launch.

A small model (about 40 MB) is enough to try things out and is fast; the full
models (1 to 2 GB) transcribe noticeably better. Vosk publishes a single,
generic French model; for English, *US English* and *UK English* are distinct.

---

## 3. Transcribing a file

1. **Browse…** (or *File › Open audio file…*, Ctrl+O) and choose an MP3 or
   WAV file. The path can also be typed or pasted into the *Audio file* field.
2. Check that a recognition model is selected on the right.
3. **Transcribe** (or *Transcription › Start*, Ctrl+R).

Passages appear in the table as they are recognised. The status bar shows how
far into the recording the engine is, its speed relative to real time, and
the number of passages so far. **Cancel** stops the run; what has been
transcribed up to that point is kept.

A transcription takes a few minutes for an hour of audio with a small model,
longer with a full one. It runs in the background, so the window stays
responsive.

---

## 4. Reading the result

The main area has two tabs.

**Segments** is a table, one row per passage:

| Column | Meaning |
|---|---|
| Start, End | Timecodes in the recording |
| Length | Duration of the passage |
| Speaker | Who it is attributed to |
| Transcript | The words |

**Running text** shows the same transcript as continuous text, timecode and
speaker at the head of each passage — the way it is saved to the `.txt` file.

The **Speakers** panel lists every voice found, with its total speaking time
(*Speech*) and its number of passages (*Seg.*). Speakers are numbered in the
order they are first heard.

---

## 5. Correcting the speakers

Grouping voices is the part of the job that most often needs a hand. Three
tools, from the lightest touch to the heaviest.

### Renaming

Select a speaker in the **Speakers** panel, type a name in the field below,
and press **Rename** or Enter. The name replaces *Speaker 2* everywhere: in
the table, in the running text, and in every file written afterwards.

### Reassigning a passage

Right-click a row in the **Segments** table (Control-click on a Mac). The menu
offers **Assign to** each existing speaker, and **New speaker** to create one
from that passage alone. Use this for the odd passage that ended up with the
wrong voice.

### Regrouping

When the grouping as a whole is wrong — two people merged into one, or one
person split into several — adjust the **Voice grouping** settings and click
**Regroup** (or *Transcription › Regroup speakers*).

Regrouping is **instant**, even on a recording several hours long: it replays
the grouping on the voiceprints already computed, without touching the audio.
So the way to work is to transcribe once, then regroup as many times as it
takes. Note that regrouping starts the names over: after it, *Speaker 2* is
not necessarily the same person as before. Rename last.

The three settings:

**Sensitivity** (default 0.05) — how close two passages have to sound to be
attributed to the same person. Towards the right, voices are split apart;
towards the left, they are merged.

- Two people merged into one → move it **right**.
- One person split into several → move it **left**.

**Number of speakers** (default 0) — if you know how many people took part,
say so: the grouping will produce exactly that many, whatever the
sensitivity. 0 lets the tool decide. A number that is too low forces
arbitrary merges.

**Minimum length** (default 40, in units of 10 ms, so 0.4 s) — a passage
shorter than this is attached to the closest known voice but is not allowed
to create a new one. A voiceprint computed from half a second of speech is
unreliable, and raising this is often more effective than adjusting the
sensitivity when a recording produces too many speakers.

No setting is right for every recording; it depends on the voices, the
microphone and the background noise. As a guide, here is the number of
speakers found on two recordings at opposite ends of the difficulty scale — a
clean two-voice interview, and a 15-minute podcast where four people share one
microphone:

| Sensitivity | Interview (2 expected) | Podcast (4 expected) |
|---|---|---|
| −0.10 | **2** | — |
| 0.00 | **2** | **4** |
| **0.05** (default) | **2** | **5** |
| 0.10 | **2** | 9 |
| 0.20 | 4 | 13 |
| 0.35 | 5 | 32 |

The same range of settings suits both, which is what makes the slider
usable: the program removes from every voiceprint the component the recording
imposes on all of them — the room, the microphone — before comparing voices.
Raising the minimum length to 100 (1 s) flattens the curve further on the
podcast: 5 speakers at 0.05 and 11 at 0.20.

---

## 6. Saving and exporting

### The transcript is saved by itself

When a transcription finishes, the annotated text is written **beside the
audio file**, under the same name with a `.txt` extension:

```
interview.mp3   →   interview.txt
```

The file is rewritten after every change that alters the text — a renamed
speaker, a reassigned passage, a regrouping — so it is never a stale copy of
what is on screen. *File › Save transcript beside the audio* (Ctrl+S) forces
a write at any time.

If a file of that name already exists, the application asks before
overwriting it — once per audio file. If you decline, nothing is written to
that path, and *Export as* lets you choose another.

### Other formats

*File › Export as* writes the transcript wherever you like, in one of:

| Format | Contents |
|---|---|
| Annotated text (`.txt`) | Timecode and speaker at the head of each passage, as shown in *Running text* |
| Subtitles (`.srt`) | One cue per passage, prefixed with the speaker's name |
| WebVTT (`.vtt`) | Same, in the format browsers play; the speaker is given as a `<v>` voice tag |
| Full JSON (`.json`) | Every passage with its speaker and every word with its timing — for further processing |
| Spreadsheet (`.csv`) | One row per passage: index, start, end, duration, speaker, text |

### Settings are remembered

Model paths and the grouping settings are kept in `.voiceannotate.conf` in
your home directory (`C:\Users\<you>` on Windows), and restored at the next
launch.

---

## 7. The command line

`voiceannotate-cli` is the same engine without the window — for a server, a
script, or a batch of files. It is installed beside the application (in
`bin\` on Windows).

```sh
voiceannotate-cli \
  --model models/vosk-model-small-fr-0.22 \
  --spk-model models/vosk-model-spk-0.4 \
  --format srt --output interview.srt \
  interview.mp3
```

Without `--output` the transcript goes to standard output; without
`--spk-model` everything is attributed to one speaker.

| Option | Effect |
|---|---|
| `-m`, `--model DIR` | recognition model directory (required) |
| `-s`, `--spk-model DIR` | speaker model directory |
| `-o`, `--output FILE` | write here instead of standard output |
| `-f`, `--format FMT` | `txt` (default), `srt`, `vtt`, `json` or `csv` |
| `-t`, `--threshold F` | sensitivity (default 0.05); the useful range is about −0.2 to 0.4 |
| `--min-frames N` | minimum length in 10 ms frames (default 40) |
| `--max-speakers N` | force at most N speakers |
| `--speaker-prefix S` | label for unnamed speakers (default `Speaker`) |
| `-v`, `--verbose` | show Vosk's own log output |
| `-q`, `--quiet` | no progress reporting |

The environment variables `VOSK_MODEL` and `VOSK_SPK_MODEL` provide defaults
for `--model` and `--spk-model`, so a script need not repeat them.

Unlike the application, the command line has no regrouping step: the settings
are applied once, during the transcription. Run it again with different values
if the grouping is off.

---

## 8. Keyboard shortcuts

On macOS, read Cmd for Ctrl.

| Shortcut | Action |
|---|---|
| Ctrl+O | Open an audio file |
| Ctrl+R | Start the transcription |
| Ctrl+S | Save the transcript beside the audio |
| Ctrl+Q | Quit |
| Enter, in the rename field | Rename the selected speaker |
| Right-click on a passage | Reassign it |

---

## 9. What to expect

On a clean recording with distinct voices — a two-person interview, each on
their own microphone — the attribution is reliable. On a hard one — several
similar voices, a single microphone, people talking over each other — no
setting will give a perfect cut, and some passages will need reassigning by
hand. That is a limit of the method, not a matter of tuning.

Recognition quality depends above all on the model. The small models are
quick and adequate for clear speech; for accented, fast or noisy speech, the
full model for the language is worth its download.

---

## 10. Troubleshooting

**The model download fails, or "The archive could not be unpacked."**
Downloading uses `curl`; unpacking uses `unzip` when it is installed and
otherwise `tar`, provided it is the bsdtar variant that reads zip files. Every
Windows since version 1803 ships both `curl` and that `tar`, as does macOS.
On Linux install `unzip` (`sudo apt install unzip` on Debian and Ubuntu). As a
fallback, download the model from <https://alphacephei.com/vosk/models>,
unpack it by hand, and point to the folder with the **…** button.

**A model download is slow.**
The Vosk server limits each connection to roughly 0.7 MB/s. The application
fetches every model in eight simultaneous ranges to get round this; a 40 MB
model should arrive in about fifteen seconds, a 1.4 GB one in a few minutes.

**On Windows, built from source, double-clicking `voiceannotate.exe` shows a
"DLL not found" error.**
A source build finds Tcl/Tk in the MSYS2 environment it was built in, which a
double-click does not inherit. Start it with `scripts\voiceannotate.cmd`, which
sets the path first, or use the installer, which carries everything.

**"Tk could not initialise" on Linux.**
There is no display. Start an X server, or use `voiceannotate-cli`, which
needs none.

**The transcript is attributed to a single speaker.**
No speaker model is selected. Download `vosk-model-spk-0.4` from the model
list, or point the *Speakers* field to it, then transcribe again — the
voiceprints are computed during the transcription, so regrouping alone will
not do.

**Settings behave strangely after an upgrade.**
The settings file carries a version number. When it was written by an
earlier version in which a setting meant something else, it is ignored and
the defaults apply; set the values again and they will be saved anew.
