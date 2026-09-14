// The only Windows-specific source file in the project, and the only reason it
// exists is the subsystem flag.
//
// Linking with -mwindows produces a process with no console, which is what a
// GUI application should be -- but the C runtime then looks for WinMain rather
// than main. This supplies one. Nothing else in the codebase needs a #ifdef,
// and the Makefile only compiles this file on Windows.
#ifdef _WIN32

#include <windows.h>

#include "app_main.h"

int WINAPI WinMain(HINSTANCE, HINSTANCE, LPSTR, int) {
    // __argc/__argv are the CRT's already-parsed command line, so the shim does
    // not have to deal with quoting rules itself.
    return va::runApplication(__argc, __argv);
}

#endif  // _WIN32
