// The real entry point of the Tk application.
//
// It is a named function rather than main() itself so the Windows shim can
// call it: ISO C++ forbids calling ::main, and this way the shim needs no
// pragma or warning suppression to stay quiet.
#ifndef VA_APP_MAIN_H
#define VA_APP_MAIN_H

namespace va {

int runApplication(int argc, char** argv);

}  // namespace va

#endif  // VA_APP_MAIN_H
