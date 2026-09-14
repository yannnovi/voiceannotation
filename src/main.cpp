// Entry point for the Tk application.
//
// This file does one job: bring up a Tcl interpreter with Tk and the ::va
// commands in it, then hand control to the GUI script. Keeping it this thin is
// what makes the port to Linux and macOS a no-op -- there is nothing here that
// knows which platform it is on.
#include <tcl.h>
#include <tk.h>

#include <cstdio>
#include <string>
#include <vector>

#include "app_main.h"
#include "tcl/tcl_app.h"

namespace {

const char kScriptName[] = "app.tcl";

// Reports a startup failure. Tk gets used when it is already up, because on
// Windows a GUI-subsystem process has no console for stderr to reach.
void reportStartupError(Tcl_Interp* interp, bool tkReady, const std::string& message) {
    std::fprintf(stderr, "voiceannotate: %s\n", message.c_str());
    if (!tkReady || !interp) return;

    Tcl_Obj* command = Tcl_NewListObj(0, nullptr);
    Tcl_ListObjAppendElement(interp, command, Tcl_NewStringObj("tk_messageBox", -1));
    Tcl_ListObjAppendElement(interp, command, Tcl_NewStringObj("-icon", -1));
    Tcl_ListObjAppendElement(interp, command, Tcl_NewStringObj("error", -1));
    Tcl_ListObjAppendElement(interp, command, Tcl_NewStringObj("-title", -1));
    Tcl_ListObjAppendElement(interp, command, Tcl_NewStringObj("voiceannotate", -1));
    Tcl_ListObjAppendElement(interp, command, Tcl_NewStringObj("-message", -1));
    Tcl_ListObjAppendElement(
        interp, command, Tcl_NewStringObj(message.c_str(), static_cast<int>(message.size())));
    Tcl_IncrRefCount(command);
    Tcl_EvalObjEx(interp, command, TCL_EVAL_GLOBAL);
    Tcl_DecrRefCount(command);
}

}  // namespace

namespace va {

int runApplication(int argc, char** argv) {
    // Must come first: it is how Tcl works out where its own script library
    // lives, on every platform.
    Tcl_FindExecutable(argv[0]);

    Tcl_Interp* interp = Tcl_CreateInterp();
    if (!interp) {
        std::fprintf(stderr, "voiceannotate: cannot create a Tcl interpreter\n");
        return 1;
    }

    if (Tcl_Init(interp) != TCL_OK) {
        reportStartupError(interp, false,
                           std::string("Tcl could not initialise: ") + Tcl_GetStringResult(interp));
        return 1;
    }
    if (Tk_Init(interp) != TCL_OK) {
        reportStartupError(interp, false,
                           std::string("Tk could not initialise: ") + Tcl_GetStringResult(interp) +
                               "\n\nOn a headless machine, start an X server or use "
                               "voiceannotate-cli instead.");
        return 1;
    }

    if (va::registerCommands(interp) != TCL_OK) {
        reportStartupError(interp, true,
                           std::string("cannot register the ::va commands: ") +
                               Tcl_GetStringResult(interp));
        return 1;
    }

    // Pass the command line through so the GUI can preload a file given on it.
    Tcl_Obj* args = Tcl_NewListObj(0, nullptr);
    for (int i = 1; i < argc; ++i) {
        Tcl_ListObjAppendElement(interp, args, Tcl_NewStringObj(argv[i], -1));
    }
    Tcl_SetVar2Ex(interp, "::va::argv", nullptr, args, TCL_GLOBAL_ONLY);

    const char* executable = Tcl_GetNameOfExecutable();
    std::vector<std::string> tried;
    std::string script = va::locateScript(executable ? executable : argv[0], kScriptName, &tried);
    if (script.empty()) {
        std::string message = "cannot find the interface script (";
        message += kScriptName;
        message += ").\nLooked in:\n";
        for (const std::string& candidate : tried) message += "  " + candidate + "\n";
        message += "\nSet VOICEANNOTATE_TCL_DIR to the directory holding it.";
        reportStartupError(interp, true, message);
        return 1;
    }

    std::string scriptDir = script.substr(0, script.find_last_of("/\\"));
    Tcl_SetVar2Ex(interp, "::va::scriptDir", nullptr,
                  Tcl_NewStringObj(scriptDir.c_str(), static_cast<int>(scriptDir.size())),
                  TCL_GLOBAL_ONLY);

    if (Tcl_EvalFile(interp, script.c_str()) != TCL_OK) {
        std::string message = "error in " + script + ":\n" + Tcl_GetStringResult(interp);
        const char* trace = Tcl_GetVar(interp, "errorInfo", TCL_GLOBAL_ONLY);
        if (trace) message += "\n\n" + std::string(trace);
        reportStartupError(interp, true, message);
        return 1;
    }

    Tk_MainLoop();

    // Stop the worker before the interpreter goes away: it may still hold
    // references to data the interpreter is about to free.
    va::shutdown();
    Tcl_DeleteInterp(interp);
    return 0;
}

}  // namespace va

int main(int argc, char** argv) { return va::runApplication(argc, argv); }
