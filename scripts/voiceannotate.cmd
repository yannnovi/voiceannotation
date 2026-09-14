@echo off
rem Lanceur Windows.
rem
rem Il ne fait qu'une chose : mettre le runtime MINGW64 (Tcl, Tk et leurs DLL)
rem dans le PATH. Un double-clic depuis l'Explorateur n'en herite pas, alors
rem qu'un shell MSYS2 MINGW64 l'a deja -- d'ou l'erreur "DLL introuvable" si on
rem lance bin\voiceannotate.exe directement.
rem
rem Ce fichier ne sert qu'a Windows. Sur Linux et macOS, lancez simplement
rem bin/voiceannotate (ou "make run").

setlocal

set "ROOT=%~dp0.."
set "EXE=%ROOT%\bin\voiceannotate.exe"

if not exist "%EXE%" (
    echo voiceannotate n'est pas encore construit.
    echo Ouvrez un shell MSYS2 MINGW64, placez-vous dans le projet et lancez : make
    echo.
    pause
    exit /b 1
)

rem Definissez MINGW64_BIN a la main si MSYS2 est installe ailleurs.
if not defined MINGW64_BIN (
    for %%D in (
        "%USERPROFILE%\scoop\apps\msys2\current\mingw64\bin"
        "C:\msys64\mingw64\bin"
        "%LOCALAPPDATA%\Programs\msys64\mingw64\bin"
        "C:\Program Files\msys64\mingw64\bin"
    ) do if exist "%%~D\tk86.dll" set "MINGW64_BIN=%%~D"
)

if not defined MINGW64_BIN (
    echo Impossible de trouver l'environnement MINGW64 ^(tk86.dll introuvable^).
    echo Definissez la variable MINGW64_BIN sur le repertoire mingw64\bin de MSYS2.
    echo.
    pause
    exit /b 1
)

set "PATH=%MINGW64_BIN%;%PATH%"

rem "start" rend la main tout de suite : la console se referme et l'application
rem reste ouverte.
start "voiceannotate" "%EXE%" %*
