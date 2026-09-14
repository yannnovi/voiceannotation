// Exposes the C++ pipeline to Tcl as a handful of commands in the ::va
// namespace, and locates the GUI script.
//
// The split is deliberate: C++ owns decoding, recognition and clustering, Tcl
// owns every pixel. Neither knows much about the other, which is why the GUI
// can be edited without recompiling and why no user-facing wording lives in
// the C++ sources.
#ifndef VA_TCL_TCL_APP_H
#define VA_TCL_TCL_APP_H

#include <string>
#include <vector>

struct Tcl_Interp;

namespace va {

// Registers ::va::start, ::va::poll, ::va::export and friends.
// Returns TCL_OK / TCL_ERROR.
int registerCommands(Tcl_Interp* interp);

// Frees the pipeline owned by the interpreter. Called before the process ends.
void shutdown();

// Finds app.tcl by looking, in order, at $VOICEANNOTATE_TCL_DIR, the directory
// beside the executable, and the usual build/install layouts relative to it.
// Returns an empty string when nothing matches; `tried` collects the
// candidates so the error message can show them.
std::string locateScript(const std::string& executablePath, const std::string& fileName,
                         std::vector<std::string>* tried);

}  // namespace va

#endif  // VA_TCL_TCL_APP_H
