; Windows installer for voiceannotate.
;
; Packs the tree staged by make-installer.sh, which already holds everything
; the program needs -- Tcl/Tk, the MinGW runtime, Vosk -- so the installer has
; nothing to look for on the machine it lands on and nothing to install first.
;
; It installs per user, into %LOCALAPPDATA%, on purpose: no administrator, no
; UAC prompt, and an installation directory that stays writable, which is where
; the interface puts the models it downloads afterwards.
;
; Built by scripts/make-installer.sh; the defines come from there.

Unicode true

!ifndef VERSION
  !define VERSION "0.0.0"
!endif
!ifndef VERSION4
  !define VERSION4 "0.0.0.0"
!endif
!ifndef STAGE_DIR
  !error "STAGE_DIR is not set; build this through scripts/make-installer.sh"
!endif
!ifndef OUT_FILE
  !error "OUT_FILE is not set; build this through scripts/make-installer.sh"
!endif

!define APP      "voiceannotate"
!define EXE      "bin\voiceannotate.exe"
!define REGKEY   "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP}"

Name "${APP} ${VERSION}"
OutFile "${OUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\${APP}"
InstallDirRegKey HKCU "Software\${APP}" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma

VIProductVersion "${VERSION4}"
VIAddVersionKey "ProductName" "${APP}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "FileDescription" "Speech to text with speaker annotation"
VIAddVersionKey "LegalCopyright" ""

!include "MUI2.nsh"
!include "FileFunc.nsh"

!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\${EXE}"
!define MUI_FINISHPAGE_RUN_NOTCHECKED

!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

; NSIS picks the table matching the system's interface language, and falls back
; to the first one inserted when there is none -- so English goes first: a
; French Windows still gets French by exact match, and a machine in any other
; language gets English rather than a language it has no reason to read.
;
; Adding one is a line here plus its three LangStrings below; a language with a
; missing LangString compiles to an empty string, so they come in pairs.
!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "French"

LangString SecMain    ${LANG_FRENCH}  "${APP} (obligatoire)"
LangString SecMain    ${LANG_ENGLISH} "${APP} (required)"
LangString SecDesktop ${LANG_FRENCH}  "Raccourci sur le Bureau"
LangString SecDesktop ${LANG_ENGLISH} "Desktop shortcut"
LangString MsgRunning ${LANG_FRENCH}  "${APP} est en cours d'exécution.$\n$\nFermez la fenêtre, puis relancez l'installation."
LangString MsgRunning ${LANG_ENGLISH} "${APP} is running.$\n$\nClose its window and start the installation again."
LangString MsgKeepModels ${LANG_FRENCH}  "Conserver les modèles de reconnaissance téléchargés ?$\n$\nIls occupent de la place mais évitent de tout retélécharger."
LangString MsgKeepModels ${LANG_ENGLISH} "Keep the downloaded recognition models?$\n$\nThey take up room, but keeping them saves downloading them again."

; --------------------------------------------------------------------------
; Install
; --------------------------------------------------------------------------

Section "$(SecMain)" SecMainId
    SectionIn RO

    ; Reinstalling over a running copy would leave a half-updated directory:
    ; the loader holds the .exe and the DLLs open, and File would fail on each.
    IfFileExists "$INSTDIR\${EXE}" 0 fresh
        ClearErrors
        Delete "$INSTDIR\${EXE}"
        IfErrors 0 fresh
            ; A silent run has nobody to answer a dialog, so it says what it
            ; can -- an exit code -- rather than waiting for a click forever.
            IfSilent +2
            MessageBox MB_OK|MB_ICONEXCLAMATION "$(MsgRunning)" /SD IDOK
            SetErrorLevel 2
            Abort
    fresh:

    SetOutPath "$INSTDIR"
    File /r "${STAGE_DIR}\*"

    WriteUninstaller "$INSTDIR\uninstall.exe"
    WriteRegStr HKCU "Software\${APP}" "InstallDir" "$INSTDIR"

    ; The working directory is $INSTDIR so the models bundled beside the
    ; program are found the same way whichever shortcut started it.
    SetOutPath "$INSTDIR"
    CreateShortcut "$SMPROGRAMS\${APP}.lnk" "$INSTDIR\${EXE}" "" "$INSTDIR\${EXE}" 0

    ; Add/Remove Programs. Under HKCU, matching a per-user installation.
    WriteRegStr HKCU "${REGKEY}" "DisplayName"     "${APP}"
    WriteRegStr HKCU "${REGKEY}" "DisplayVersion"  "${VERSION}"
    WriteRegStr HKCU "${REGKEY}" "DisplayIcon"     "$INSTDIR\${EXE}"
    WriteRegStr HKCU "${REGKEY}" "InstallLocation" "$INSTDIR"
    WriteRegStr HKCU "${REGKEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
    WriteRegStr HKCU "${REGKEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
    WriteRegDWORD HKCU "${REGKEY}" "NoModify" 1
    WriteRegDWORD HKCU "${REGKEY}" "NoRepair" 1
    ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
    IntFmt $0 "0x%08X" $0
    WriteRegDWORD HKCU "${REGKEY}" "EstimatedSize" "$0"
SectionEnd

Section "$(SecDesktop)" SecDesktopId
    SetOutPath "$INSTDIR"
    CreateShortcut "$DESKTOP\${APP}.lnk" "$INSTDIR\${EXE}" "" "$INSTDIR\${EXE}" 0
SectionEnd

; --------------------------------------------------------------------------
; Uninstall
; --------------------------------------------------------------------------

Section "Uninstall"
    ; Never turn a wrong $INSTDIR into a recursive delete: without the program
    ; in it, this is not our directory and nothing is removed.
    IfFileExists "$INSTDIR\${EXE}" 0 done

    Delete "$SMPROGRAMS\${APP}.lnk"
    Delete "$DESKTOP\${APP}.lnk"

    ; Models are downloads of their own, often a gigabyte and slow to fetch
    ; again, so they are not swept away without asking.
    IfFileExists "$INSTDIR\models\*.*" 0 removeall
        ; Nobody to ask during a silent uninstall, and leaving files behind
        ; would be the greater surprise there: it takes everything. /SD says
        ; so to NSIS, which otherwise answers a silent dialog with its default
        ; button -- Yes here, the opposite of what is wanted.
        IfSilent removeall
        MessageBox MB_YESNO|MB_ICONQUESTION "$(MsgKeepModels)" /SD IDNO IDNO removeall
            Delete "$INSTDIR\uninstall.exe"
            RMDir /r "$INSTDIR\bin"
            RMDir /r "$INSTDIR\lib"
            RMDir /r "$INSTDIR\share"
            Delete "$INSTDIR\*.md"
            Delete "$INSTDIR\*LICENSE*"
            Delete "$INSTDIR\*COPYING*"
            RMDir "$INSTDIR"
            Goto registry
    removeall:
        RMDir /r "$INSTDIR"

    registry:
    DeleteRegKey HKCU "${REGKEY}"
    DeleteRegKey HKCU "Software\${APP}"
    done:
SectionEnd
