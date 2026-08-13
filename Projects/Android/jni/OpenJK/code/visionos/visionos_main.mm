/*
===========================================================================
Copyright (C) 2005 - 2015, ioquake3 contributors
Copyright (C) 2013 - 2015, OpenJK contributors

This file is part of the OpenJK source code.

OpenJK is free software; you can redistribute it and/or modify it
under the terms of the GNU General Public License version 2 as
published by the Free Software Foundation.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, see <http://www.gnu.org/licenses/>.
===========================================================================
*/

// Systemschicht für visionOS — Gegenstück zu android/android_main.cpp.
//
// Warum eine eigene Datei und nicht die Android-Fassung mitbenutzt:
// q_platform.h definiert MACOS_X automatisch über __APPLE_CC__, und damit
// schalten sich in android_main.cpp 17 `#ifdef MACOS_X`-Zweige ein, die für
// Desktop-macOS geschrieben wurden — Programmbündel, dlopen von .dylib,
// Pfade unter ~/Library. Einer davon ruft FS_LoadMachOBundle auf, das es in
// dieser Codebasis gar nicht mehr gibt.
//
// android_window.cpp und in_android.cpp werden dagegen unverändert
// mitübersetzt: sie enthalten keinen Android-spezifischen Code.

#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#import <Foundation/Foundation.h>

#include "qcommon/q_shared.h"
#include "qcommon/qcommon.h"
#include "sys/sys_local.h"
#include "sys/sys_loadlib.h"
#include "client/client.h"   // CL_ShutdownUI

// In sys_public.h nur `extern` deklariert; die Definition steht auf Android in
// android_main.cpp. Com_Frame und Sys_Init greifen darauf zu.
cvar_t *com_unfocused;
cvar_t *com_minimized;
cvar_t *com_maxfps;
cvar_t *com_maxfpsUnfocused;
cvar_t *com_maxfpsMinimized;

static char installPath[MAX_OSPATH];
static char binaryPath[MAX_OSPATH];

// ---------------------------------------------------------------------------
// Module
//
// Die Engine lädt zwei Module zur Laufzeit nach: den Renderer (rd-gles, über
// Sys_LoadDll + Sys_LoadFunction("GetRefAPI")) und den Spielcode (jagame, über
// Sys_LoadSPGameDll). Auf Android sind das .so-Dateien.
//
// Hier sind beide statisch gelinkt. Nachladen wäre auf visionOS auch nicht der
// bequemere Weg: der JIT-Spike (spikes/s1-jit) hat gemessen, wie streng die
// Code-Signatur durchgesetzt wird, und ungesignierte Bibliotheken nachzuladen
// führt in dasselbe Minenfeld.
//
// Sys_LoadFunction ist ein Makro auf dlsym (sys_loadlib.h), also lässt sich der
// Aufrufweg der Engine unverändert lassen: Sys_LoadDll gibt RTLD_DEFAULT
// zurück, und dlsym findet damit die statisch gelinkten Symbole des
// Hauptprogramms. Kein Eingriff in cl_main.cpp oder sv_game.cpp nötig.
// ---------------------------------------------------------------------------

extern "C" void *GetGameAPI(void *import);
extern "C" void *GetRefAPI(int apiVersion, void *refimp);

// Ohne diesen Anker fänden die Symbole nie den Weg ins Programm: referenziert
// werden sie ausschließlich über Zeichenketten in dlsym, und ein Archivmitglied,
// das niemand referenziert, bindet der Linker gar nicht erst ein. Was er
// einbindet, könnte -dead_strip anschließend wieder entfernen.
//
// `used` verhindert beides — die Adressen stehen hier sichtbar im Code.
__attribute__((used))
static void *const s_moduleAnchors[] = {
    (void *)&GetGameAPI,
    (void *)&GetRefAPI,
};

/*
=================
Sys_LoadDll

`name` wird bewusst ignoriert: es ist genau ein Renderer gelinkt. Käme später
eine Auswahl zwischen rd-gles und rd-vanilla hinzu, müsste hier nach Namen
unterschieden und je ein eigenes Handle vergeben werden.
=================
*/
void * QDECL Sys_LoadDll(const char *name, qboolean useSystemLib)
{
    (void)useSystemLib;
    Com_DPrintf("Sys_LoadDll(%s): statisch gelinkt\n", name ? name : "?");
    return RTLD_DEFAULT;
}

/*
=================
Sys_LoadSPGameDll
=================
*/
void *Sys_LoadSPGameDll(const char *name, GetGameAPIProc **GetGameAPIOut)
{
    assert(GetGameAPIOut);
    Com_DPrintf("Sys_LoadSPGameDll(%s): statisch gelinkt\n", name ? name : "?");

    *GetGameAPIOut = (GetGameAPIProc *)Sys_LoadFunction(RTLD_DEFAULT, "GetGameAPI");
    if (!*GetGameAPIOut) {
        // Wenn das fehlschlägt, ist das Symbol nicht exportiert — dann fehlt
        // entweder Q_EXPORT an der Definition oder der Anker oben greift nicht.
        Com_Printf("Sys_LoadSPGameDll: GetGameAPI nicht auffindbar: %s\n",
                   Sys_LibraryError());
        return NULL;
    }

    return RTLD_DEFAULT;
}

/*
=================
Sys_UnloadDll

Kein dlclose: RTLD_DEFAULT ist kein echtes Handle, und statisch gelinkter Code
lässt sich ohnehin nicht entladen.
=================
*/
void Sys_UnloadDll(void *dllHandle)
{
    (void)dllHandle;
}

// ---------------------------------------------------------------------------
// Pfade
// ---------------------------------------------------------------------------

/*
=================
Sys_DefaultInstallPath

Hier sucht die Engine `base/` mit den pk3-Dateien. Das Dokumentenverzeichnis
des App-Containers ist der richtige Ort: es überlebt Aktualisierungen, und mit
UIFileSharingEnabled plus LSSupportsOpeningDocumentsInPlace in der Info.plist
können die Spieldateien über die Dateien-App hineingelegt werden — sonst gäbe
es auf einem Gerät ohne Dateisystemzugriff keinen Weg, sie einzuspielen.
=================
*/
char *Sys_DefaultInstallPath(void)
{
    if (*installPath) {
        return installPath;
    }

    @autoreleasepool {
        NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES);
        if (dirs.count > 0) {
            Q_strncpyz(installPath, [dirs[0] UTF8String], sizeof(installPath));
        }
    }

    return installPath;
}

/*
=================
Sys_DefaultAppPath

Das Programmbündel — hier liegt, was mitgeliefert wird, etwa die
z_vr_assets-Dateien von JKXR. Schreibbar ist es nicht.
=================
*/
char *Sys_DefaultAppPath(void)
{
    if (*binaryPath) {
        return binaryPath;
    }

    @autoreleasepool {
        NSString *path = [[NSBundle mainBundle] bundlePath];
        if (path) {
            Q_strncpyz(binaryPath, [path UTF8String], sizeof(binaryPath));
        }
    }

    return binaryPath;
}

// ---------------------------------------------------------------------------
// Konsole
// ---------------------------------------------------------------------------

/*
=================
Sys_ConsoleInput

Es gibt keine Standardeingabe. Die Spielkonsole im Headset läuft über den
eigenen Ereignispfad der Engine, nicht hierüber.
=================
*/
char *Sys_ConsoleInput(void)
{
    return NULL;
}

#define MAXPRINTMSG 4096

void Sys_Print(const char *msg)
{
    // Aus RTCW übernommen, wie in der Android-Fassung: Präfixe, die nur die
    // Anzeige in der Spielkonsole steuern, gehören nicht ins Protokoll.
    if (!Q_strncmp(msg, "[skipnotify]", 12)) {
        msg += 12;
    }
    if (msg[0] == '*') {
        msg += 1;
    }

    char buf[MAXPRINTMSG] = {0};
    Q_strncpyz(buf, msg, sizeof(buf));
    Q_StripColor(buf);

    // fputs statt NSLog: NSLog setzt bei jedem Aufruf einen Zeilenumbruch und
    // einen Zeitstempel, was die zeilenweise aufgebaute Ausgabe der Engine
    // zerreißt. Der Umbruch steht bereits in der Meldung.
    fputs(buf, stderr);
}

// ---------------------------------------------------------------------------
// Start und Ende
// ---------------------------------------------------------------------------

static void Sys_In_Restart_f(void)
{
}

void Sys_Init(void)
{
    Cmd_AddCommand("in_restart", Sys_In_Restart_f);
    Cvar_Get("arch", OS_STRING " " ARCH_STRING, CVAR_ROM);
    Cvar_Get("username", Sys_GetCurrentUser(), CVAR_ROM);

    com_unfocused = Cvar_Get("com_unfocused", "0", CVAR_ROM);
    com_minimized = Cvar_Get("com_minimized", "0", CVAR_ROM);
    com_maxfps = Cvar_Get("com_maxfps", "90", CVAR_ARCHIVE);
    com_maxfpsUnfocused = Cvar_Get("com_maxfpsUnfocused", "0", CVAR_ARCHIVE_ND);
    com_maxfpsMinimized = Cvar_Get("com_maxfpsMinimized", "50", CVAR_ARCHIVE_ND);
}

static void NORETURN Sys_Exit(int ex)
{
    // Ein Programm, das sich auf visionOS selbst beendet, hinterlässt beim
    // Nutzer einen Absturzbericht — es gibt keinen sauberen Weg, eine App von
    // innen zu schließen. Das ist trotzdem richtig so: hierher kommt man nur
    // über Sys_Error, und dann ist der Zustand ohnehin verloren.
    _exit(ex);
}

void NORETURN QDECL Sys_Error(const char *error, ...)
{
    va_list argptr;
    char string[1024];

    va_start(argptr, error);
    Q_vsnprintf(string, sizeof(string), error, argptr);
    va_end(argptr);

    Sys_Print("*** Sys_Error: ");
    Sys_Print(string);
    Sys_Print("\n");

    Sys_Exit(3);
}

void NORETURN Sys_Quit(void)
{
    Com_ShutdownZoneMemory();
    Com_ShutdownHunkMemory();
    Sys_Exit(0);
}

// ---------------------------------------------------------------------------
// Einstiegspunkt
//
// Q_EXPORT ist hier zwingend. Der Client wird mit -fvisibility=hidden gebaut
// (aus Android_client_ja.mk übernommen), also wären diese beiden Funktionen
// sonst lokale Symbole — im Binary als kleines "t" statt "T" — und für die
// SwiftUI-Hülle unerreichbar.
// ---------------------------------------------------------------------------

void VR_Init();   // C++-Bindung, wie in JKXR_visionOS.mm definiert
static bool s_shutdown = false;

/*
=================
JKXR_visionOS_Main

Gegenstück zu VR_main aus der Android-Fassung. Ein `main` gibt es hier nicht:
die App ist eine SwiftUI-App, und diese Schleife läuft auf einem eigenen
Thread, den die Hülle startet — nachdem der Immersive Space offen und der
LayerRenderer an die XR-Schicht übergeben ist.

Blockierend, und das mit Absicht: die Engine erwartet, dass Com_Frame in einer
engen Schleife läuft. Auf keinen Fall auf einer der Warteschlangen von Swift
Concurrency aufrufen — dort würde die Schleife den Pool aushungern. Derselbe
Fehler war in S4 die Ursache, dass ARKit keine Posen mehr lieferte.
=================
*/
extern "C" Q_EXPORT int JKXR_visionOS_Main(int argc, char *argv[])
{
    char commandLine[MAX_STRING_CHARS] = {0};

    Sys_Milliseconds();

    for (int i = 1; i < argc; i++) {
        const bool containsSpaces = (strchr(argv[i], ' ') != NULL);
        if (containsSpaces) {
            Q_strcat(commandLine, sizeof(commandLine), "\"");
        }
        Q_strcat(commandLine, sizeof(commandLine), argv[i]);
        if (containsSpaces) {
            Q_strcat(commandLine, sizeof(commandLine), "\"");
        }
        Q_strcat(commandLine, sizeof(commandLine), " ");
    }

    Com_Init(commandLine);
    NET_Init();
    VR_Init();

    s_shutdown = false;
    while (!s_shutdown) {
        IN_Frame();
        Com_Frame();
    }

    CL_ShutdownUI();
    return 0;
}

/*
=================
JKXR_visionOS_RequestShutdown

Aus der App-Hülle aufzurufen, wenn der Immersive Space geschlossen wird. Die
Schleife endet dann nach dem laufenden Bild.
=================
*/
extern "C" Q_EXPORT void JKXR_visionOS_RequestShutdown(void)
{
    s_shutdown = true;
}
