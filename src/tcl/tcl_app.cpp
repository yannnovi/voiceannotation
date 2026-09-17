#include "tcl/tcl_app.h"

#include <tcl.h>

#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

#include "core/pipeline.h"
#include "core/transcript.h"
#include "stt/vosk_engine.h"
#include "util/json.h"

namespace va {
namespace {

// One pipeline per process. The GUI is single-document, and the pipeline
// already owns the worker thread and the loaded models.
std::unique_ptr<Pipeline> gPipeline;

Pipeline& pipeline() {
    if (!gPipeline) gPipeline.reset(new Pipeline);
    return *gPipeline;
}

// --- small Tcl helpers -----------------------------------------------------

Tcl_Obj* str(const std::string& s) {
    return Tcl_NewStringObj(s.c_str(), static_cast<int>(s.size()));
}

void dictPut(Tcl_Interp* interp, Tcl_Obj* dict, const char* key, Tcl_Obj* value) {
    Tcl_DictObjPut(interp, dict, Tcl_NewStringObj(key, -1), value);
}

void setError(Tcl_Interp* interp, const std::string& message) {
    Tcl_SetObjResult(interp, str(message));
}

// Reads -name value pairs into a config. Unknown options are reported so a
// typo in the GUI script surfaces immediately instead of being ignored.
bool parseOptions(Tcl_Interp* interp, int objc, Tcl_Obj* const objv[], int first,
                  PipelineConfig* config) {
    for (int i = first; i < objc; i += 2) {
        if (i + 1 >= objc) {
            setError(interp, std::string("option ") + Tcl_GetString(objv[i]) + " needs a value");
            return false;
        }
        std::string key = Tcl_GetString(objv[i]);
        Tcl_Obj* value = objv[i + 1];

        if (key == "-audio") {
            config->audioPath = Tcl_GetString(value);
        } else if (key == "-model") {
            config->modelPath = Tcl_GetString(value);
        } else if (key == "-spkmodel") {
            config->speakerModelPath = Tcl_GetString(value);
        } else if (key == "-threshold") {
            double v = 0.0;
            if (Tcl_GetDoubleFromObj(interp, value, &v) != TCL_OK) return false;
            config->diarizer.threshold = v;
        } else if (key == "-minframes") {
            int v = 0;
            if (Tcl_GetIntFromObj(interp, value, &v) != TCL_OK) return false;
            config->diarizer.minFrames = v;
        } else if (key == "-maxspeakers") {
            int v = 0;
            if (Tcl_GetIntFromObj(interp, value, &v) != TCL_OK) return false;
            config->diarizer.maxSpeakers = v;
        } else {
            setError(interp, "unknown option " + key);
            return false;
        }
    }
    return true;
}

Tcl_Obj* segmentToDict(Tcl_Interp* interp, const Segment& segment, int index) {
    Tcl_Obj* dict = Tcl_NewDictObj();
    dictPut(interp, dict, "index", Tcl_NewIntObj(index));
    dictPut(interp, dict, "start", Tcl_NewDoubleObj(segment.start));
    dictPut(interp, dict, "end", Tcl_NewDoubleObj(segment.end));
    dictPut(interp, dict, "duration", Tcl_NewDoubleObj(segment.duration()));
    dictPut(interp, dict, "speaker", Tcl_NewIntObj(segment.speaker));
    dictPut(interp, dict, "name", str(pipeline().transcript().speakerName(segment.speaker)));
    dictPut(interp, dict, "text", str(segment.text));
    dictPut(interp, dict, "words", Tcl_NewIntObj(static_cast<int>(segment.words.size())));
    dictPut(interp, dict, "spkframes", Tcl_NewIntObj(segment.speakerFrames));
    return dict;
}

const char* eventTypeName(EventType type) {
    switch (type) {
        case EventType::Status: return "status";
        case EventType::Progress: return "progress";
        case EventType::Segment: return "segment";
        case EventType::Finished: return "finished";
        case EventType::Failed: return "failed";
    }
    return "status";
}

// --- commands --------------------------------------------------------------

int cmdStart(ClientData, Tcl_Interp* interp, int objc, Tcl_Obj* const objv[]) {
    PipelineConfig config;
    if (!parseOptions(interp, objc, objv, 1, &config)) return TCL_ERROR;

    std::string error;
    if (!pipeline().start(config, &error)) {
        setError(interp, error);
        return TCL_ERROR;
    }
    return TCL_OK;
}

int cmdCancel(ClientData, Tcl_Interp*, int, Tcl_Obj* const[]) {
    pipeline().cancel();
    return TCL_OK;
}

int cmdRunning(ClientData, Tcl_Interp* interp, int, Tcl_Obj* const[]) {
    Tcl_SetObjResult(interp, Tcl_NewBooleanObj(pipeline().running() ? 1 : 0));
    return TCL_OK;
}

// Returns every event queued since the last call, as a list of dicts. The GUI
// polls this from an `after` timer -- see the header for why.
int cmdPoll(ClientData, Tcl_Interp* interp, int, Tcl_Obj* const[]) {
    std::vector<Event> events = pipeline().drain();
    Tcl_Obj* list = Tcl_NewListObj(0, nullptr);

    for (const Event& e : events) {
        Tcl_Obj* dict = Tcl_NewDictObj();
        dictPut(interp, dict, "type", Tcl_NewStringObj(eventTypeName(e.type), -1));

        switch (e.type) {
            case EventType::Status:
            case EventType::Failed:
                dictPut(interp, dict, "message", str(e.message));
                break;

            case EventType::Progress:
                dictPut(interp, dict, "fraction", Tcl_NewDoubleObj(e.fraction));
                dictPut(interp, dict, "position", Tcl_NewDoubleObj(e.audioPosition));
                dictPut(interp, dict, "duration", Tcl_NewDoubleObj(e.duration));
                dictPut(interp, dict, "elapsed", Tcl_NewDoubleObj(e.elapsed));
                dictPut(interp, dict, "speed", Tcl_NewDoubleObj(e.speed));
                break;

            case EventType::Segment:
                dictPut(interp, dict, "segment", segmentToDict(interp, e.segment, e.segmentIndex));
                break;

            case EventType::Finished:
                dictPut(interp, dict, "cancelled", Tcl_NewBooleanObj(e.cancelled ? 1 : 0));
                dictPut(interp, dict, "relabelled", Tcl_NewBooleanObj(e.relabelled ? 1 : 0));
                dictPut(interp, dict, "elapsed", Tcl_NewDoubleObj(e.elapsed));
                dictPut(interp, dict, "duration", Tcl_NewDoubleObj(e.duration));
                dictPut(interp, dict, "speed", Tcl_NewDoubleObj(e.speed));
                break;
        }
        Tcl_ListObjAppendElement(interp, list, dict);

        // The worker has stopped by the time either of these is seen, so this
        // is the safe point to reap the thread.
        if (e.type == EventType::Finished || e.type == EventType::Failed) {
            pipeline().wait();
        }
    }
    Tcl_SetObjResult(interp, list);
    return TCL_OK;
}

int cmdSegments(ClientData, Tcl_Interp* interp, int objc, Tcl_Obj* const objv[]) {
    const Transcript& transcript = pipeline().transcript();
    const std::vector<Segment>& segments = transcript.segments();

    int from = 0;
    int count = static_cast<int>(segments.size());
    if (objc >= 2 && Tcl_GetIntFromObj(interp, objv[1], &from) != TCL_OK) return TCL_ERROR;
    if (objc >= 3 && Tcl_GetIntFromObj(interp, objv[2], &count) != TCL_OK) return TCL_ERROR;
    if (from < 0) from = 0;

    Tcl_Obj* list = Tcl_NewListObj(0, nullptr);
    for (int i = from; i < static_cast<int>(segments.size()) && i < from + count; ++i) {
        Tcl_ListObjAppendElement(interp, list,
                                 segmentToDict(interp, segments[static_cast<std::size_t>(i)], i));
    }
    Tcl_SetObjResult(interp, list);
    return TCL_OK;
}

int cmdSpeakers(ClientData, Tcl_Interp* interp, int, Tcl_Obj* const[]) {
    const Transcript& transcript = pipeline().transcript();
    std::vector<double> totals = transcript.speakingTime();
    std::vector<int> counts(totals.size(), 0);
    for (const Segment& s : transcript.segments()) {
        if (s.speaker >= 0 && static_cast<std::size_t>(s.speaker) < counts.size()) {
            ++counts[static_cast<std::size_t>(s.speaker)];
        }
    }

    Tcl_Obj* list = Tcl_NewListObj(0, nullptr);
    for (std::size_t i = 0; i < totals.size(); ++i) {
        Tcl_Obj* dict = Tcl_NewDictObj();
        dictPut(interp, dict, "id", Tcl_NewIntObj(static_cast<int>(i)));
        dictPut(interp, dict, "name", str(transcript.speakerName(static_cast<int>(i))));
        dictPut(interp, dict, "time", Tcl_NewDoubleObj(totals[i]));
        dictPut(interp, dict, "segments", Tcl_NewIntObj(counts[i]));
        Tcl_ListObjAppendElement(interp, list, dict);
    }
    Tcl_SetObjResult(interp, list);
    return TCL_OK;
}

// va::speakername id ?newName?  -- reads or sets one speaker's label.
int cmdSpeakerName(ClientData, Tcl_Interp* interp, int objc, Tcl_Obj* const objv[]) {
    if (objc < 2 || objc > 3) {
        Tcl_WrongNumArgs(interp, 1, objv, "id ?name?");
        return TCL_ERROR;
    }
    int id = 0;
    if (Tcl_GetIntFromObj(interp, objv[1], &id) != TCL_OK) return TCL_ERROR;

    Transcript& transcript = pipeline().transcript();
    if (objc == 3) {
        transcript.setSpeakerName(id, Tcl_GetString(objv[2]));
    }
    Tcl_SetObjResult(interp, str(transcript.speakerName(id)));
    return TCL_OK;
}

// va::labels prefix unknown  -- the wording used for unnamed speakers.
int cmdLabels(ClientData, Tcl_Interp* interp, int objc, Tcl_Obj* const objv[]) {
    if (objc != 3) {
        Tcl_WrongNumArgs(interp, 1, objv, "speakerPrefix unknownLabel");
        return TCL_ERROR;
    }
    Transcript& transcript = pipeline().transcript();
    transcript.setSpeakerPrefix(Tcl_GetString(objv[1]));
    transcript.setUnknownLabel(Tcl_GetString(objv[2]));
    return TCL_OK;
}

// va::assign segmentIndex speakerId  -- manual correction. `speakerId` may be
// the current speaker count, which starts a new speaker.
int cmdAssign(ClientData, Tcl_Interp* interp, int objc, Tcl_Obj* const objv[]) {
    if (objc != 3) {
        Tcl_WrongNumArgs(interp, 1, objv, "segmentIndex speakerId");
        return TCL_ERROR;
    }
    if (pipeline().running()) {
        setError(interp, "cannot reassign while a transcription is running");
        return TCL_ERROR;
    }
    int index = 0;
    int speaker = 0;
    if (Tcl_GetIntFromObj(interp, objv[1], &index) != TCL_OK) return TCL_ERROR;
    if (Tcl_GetIntFromObj(interp, objv[2], &speaker) != TCL_OK) return TCL_ERROR;

    if (!pipeline().transcript().setSegmentSpeaker(index, speaker)) {
        setError(interp, "segment or speaker index out of range");
        return TCL_ERROR;
    }
    return TCL_OK;
}

int cmdRecluster(ClientData, Tcl_Interp* interp, int objc, Tcl_Obj* const objv[]) {
    if (pipeline().running()) {
        setError(interp, "cannot regroup while a transcription is running");
        return TCL_ERROR;
    }
    PipelineConfig config;
    if (!parseOptions(interp, objc, objv, 1, &config)) return TCL_ERROR;

    int speakers = pipeline().recluster(config.diarizer);
    Tcl_SetObjResult(interp, Tcl_NewIntObj(speakers));
    return TCL_OK;
}

int cmdExport(ClientData, Tcl_Interp* interp, int objc, Tcl_Obj* const objv[]) {
    if (objc < 2 || objc > 3) {
        Tcl_WrongNumArgs(interp, 1, objv, "path ?format?");
        return TCL_ERROR;
    }
    std::string path = Tcl_GetString(objv[1]);
    ExportFormat format = Transcript::formatForPath(path);
    if (objc == 3) {
        std::string name = Tcl_GetString(objv[2]);
        if (name == "txt" || name == "text") format = ExportFormat::Text;
        else if (name == "srt") format = ExportFormat::Srt;
        else if (name == "vtt") format = ExportFormat::Vtt;
        else if (name == "json") format = ExportFormat::Json;
        else if (name == "csv") format = ExportFormat::Csv;
        else {
            setError(interp, "unknown export format: " + name);
            return TCL_ERROR;
        }
    }

    std::string error;
    if (!pipeline().transcript().save(path, format, &error)) {
        setError(interp, error);
        return TCL_ERROR;
    }
    return TCL_OK;
}

// Renders a format to a string, for the preview pane.
int cmdRender(ClientData, Tcl_Interp* interp, int objc, Tcl_Obj* const objv[]) {
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "format");
        return TCL_ERROR;
    }
    std::string name = Tcl_GetString(objv[1]);
    ExportFormat format = ExportFormat::Text;
    if (name == "srt") format = ExportFormat::Srt;
    else if (name == "vtt") format = ExportFormat::Vtt;
    else if (name == "json") format = ExportFormat::Json;
    else if (name == "csv") format = ExportFormat::Csv;

    Tcl_SetObjResult(interp, str(pipeline().transcript().render(format)));
    return TCL_OK;
}

Tcl_Obj* jsonToTcl(Tcl_Interp* interp, const Json& value) {
    switch (value.type()) {
        case Json::Type::Array: {
            Tcl_Obj* list = Tcl_NewListObj(0, nullptr);
            for (const Json& item : value.items()) {
                Tcl_ListObjAppendElement(interp, list, jsonToTcl(interp, item));
            }
            return list;
        }
        case Json::Type::Object: {
            Tcl_Obj* dict = Tcl_NewDictObj();
            for (const std::pair<const std::string, Json>& field : value.fields()) {
                dictPut(interp, dict, field.first.c_str(), jsonToTcl(interp, field.second));
            }
            return dict;
        }
        case Json::Type::Bool:
            return Tcl_NewBooleanObj(value.asBool() ? 1 : 0);
        case Json::Type::Number: {
            // A whole number goes back as an integer: a byte count has to stay
            // readable and comparable on the Tcl side, not become 4.12e+07.
            double number = value.asDouble();
            Tcl_WideInt whole = static_cast<Tcl_WideInt>(number);
            if (static_cast<double>(whole) == number) return Tcl_NewWideIntObj(whole);
            return Tcl_NewDoubleObj(number);
        }
        case Json::Type::String:
            return str(value.asString());
        case Json::Type::Null:
            break;
    }
    return Tcl_NewStringObj("", 0);
}

// va::json text  -- objects become dicts, arrays become lists. The interface
// reads Vosk's published model catalogue with it; the parser is the one the
// rest of the program already uses, so there is no second one to keep correct.
int cmdJson(ClientData, Tcl_Interp* interp, int objc, Tcl_Obj* const objv[]) {
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "text");
        return TCL_ERROR;
    }
    std::string error;
    Json parsed = Json::parse(Tcl_GetString(objv[1]), &error);
    if (!error.empty()) {
        setError(interp, "invalid JSON: " + error);
        return TCL_ERROR;
    }
    Tcl_SetObjResult(interp, jsonToTcl(interp, parsed));
    return TCL_OK;
}

int cmdSummary(ClientData, Tcl_Interp* interp, int, Tcl_Obj* const[]) {
    const Transcript& transcript = pipeline().transcript();
    Tcl_Obj* dict = Tcl_NewDictObj();
    dictPut(interp, dict, "source", str(transcript.sourcePath));
    dictPut(interp, dict, "model", str(transcript.modelPath));
    dictPut(interp, dict, "spkmodel", str(transcript.speakerModelPath));
    dictPut(interp, dict, "duration", Tcl_NewDoubleObj(transcript.audioDuration));
    dictPut(interp, dict, "samplerate", Tcl_NewIntObj(transcript.sourceSampleRate));
    dictPut(interp, dict, "channels", Tcl_NewIntObj(transcript.sourceChannels));
    dictPut(interp, dict, "segments",
            Tcl_NewIntObj(static_cast<int>(transcript.segments().size())));
    dictPut(interp, dict, "speakers", Tcl_NewIntObj(transcript.speakerCount()));
    Tcl_SetObjResult(interp, dict);
    return TCL_OK;
}

// Formats seconds the same way the exported files do, so what the table shows
// and what lands in the .srt cannot drift apart.
int cmdTimecode(ClientData, Tcl_Interp* interp, int objc, Tcl_Obj* const objv[]) {
    if (objc < 2 || objc > 3) {
        Tcl_WrongNumArgs(interp, 1, objv, "seconds ?subtitleStyle?");
        return TCL_ERROR;
    }
    double seconds = 0.0;
    if (Tcl_GetDoubleFromObj(interp, objv[1], &seconds) != TCL_OK) return TCL_ERROR;
    int subtitle = 0;
    if (objc == 3 && Tcl_GetBooleanFromObj(interp, objv[2], &subtitle) != TCL_OK) {
        return TCL_ERROR;
    }
    Tcl_SetObjResult(interp, str(Transcript::timecode(seconds, subtitle != 0)));
    return TCL_OK;
}

struct CommandSpec {
    const char* name;
    Tcl_ObjCmdProc* proc;
};

}  // namespace

int registerCommands(Tcl_Interp* interp) {
    if (Tcl_Eval(interp, "namespace eval ::va {}") != TCL_OK) return TCL_ERROR;

    // A GUI process has nowhere to print: on Windows there is no console at
    // all, and elsewhere the messages would only clutter the terminal the user
    // happened to launch from. Warnings emitted while a model loads still get
    // through -- that is Vosk's own behaviour, not something this flag covers.
    VoskEngine::setLogLevel(-1);

    static const CommandSpec commands[] = {
        {"::va::start", cmdStart},         {"::va::cancel", cmdCancel},
        {"::va::running", cmdRunning},     {"::va::poll", cmdPoll},
        {"::va::segments", cmdSegments},   {"::va::speakers", cmdSpeakers},
        {"::va::speakername", cmdSpeakerName}, {"::va::labels", cmdLabels},
        {"::va::recluster", cmdRecluster}, {"::va::assign", cmdAssign},
        {"::va::export", cmdExport},
        {"::va::render", cmdRender},       {"::va::summary", cmdSummary},
        {"::va::timecode", cmdTimecode},   {"::va::json", cmdJson},
    };

    for (const CommandSpec& spec : commands) {
        if (Tcl_CreateObjCommand(interp, spec.name, spec.proc, nullptr, nullptr) == nullptr) {
            return TCL_ERROR;
        }
    }
    return TCL_OK;
}

void shutdown() {
    if (gPipeline) {
        gPipeline->cancel();
        gPipeline->wait();
        gPipeline.reset();
    }
}

std::string locateScript(const std::string& executablePath, const std::string& fileName,
                         std::vector<std::string>* tried) {
    std::string dir;
    std::size_t slash = executablePath.find_last_of("/\\");
    if (slash != std::string::npos) dir = executablePath.substr(0, slash);
    if (dir.empty()) dir = ".";

    std::vector<std::string> candidates;
    if (const char* override = std::getenv("VOICEANNOTATE_TCL_DIR")) {
        candidates.push_back(std::string(override) + "/" + fileName);
    }
    candidates.push_back(dir + "/" + fileName);          // installed side by side
    candidates.push_back(dir + "/tcl/" + fileName);      // staged next to the binary
    candidates.push_back(dir + "/../tcl/" + fileName);   // build/ output in the tree
    candidates.push_back(dir + "/../share/voiceannotate/" + fileName);  // make install
    candidates.push_back("tcl/" + fileName);             // run from the source root

    for (const std::string& candidate : candidates) {
        if (tried) tried->push_back(candidate);
        FILE* f = std::fopen(candidate.c_str(), "rb");
        if (f) {
            std::fclose(f);
            return candidate;
        }
    }
    return std::string();
}

}  // namespace va
