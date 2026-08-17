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
#include <execinfo.h>
#include <signal.h>
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
#include "visionos/JKXR_visionOS_Spiel.h"

// Der Ordner im Dokumentenverzeichnis, in dem dieses Spiel seine Dateien sucht.
//
// Beide Spiele heißen ihr Datenverzeichnis "base", liegen aber im selben
// Container — ohne diese Trennung würden sich die pk3-Dateien überschreiben.
//
// Spielstände und Konfiguration trennen sich dagegen schon von selbst:
// HOMEPATH_NAME_MACOSX ist in q_shared.h je Spiel definiert (OpenJK gegen
// OpenJO), und sys_unix.cpp baut den Heimatpfad daraus.
#if JK2_MODE
#define JKXR_SPIELORDNER "JediOutcast"
#define JKXR_SPIELNAME   "Jedi Outcast"
#else
#define JKXR_SPIELORDNER "JediAcademy"
#define JKXR_SPIELNAME   "Jedi Academy"
#endif

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

// Der Clientteil des Spielcodes steckt in derselben Bibliothek und hat zwei
// eigene Einsprungpunkte, die CL_InitCGameVM (cl_cgame.cpp:68-75) auf demselben
// Weg holt.
//
// Die Signaturen sind die aus cg_main.cpp:106 und cg_syscalls.cpp:33. Hier wird
// nur die Adresse genommen, aufgerufen wird über die Engine.
extern "C" intptr_t vmMain(intptr_t command, intptr_t arg0, intptr_t arg1,
                           intptr_t arg2, intptr_t arg3, intptr_t arg4,
                           intptr_t arg5, intptr_t arg6, intptr_t arg7);
extern "C" void dllEntry(intptr_t (*syscallptr)(intptr_t arg, ...));

// Die Modultabelle. Sie ersetzt dlsym, und das aus zwei Gründen.
//
// Der eine ist zwingend: Outcast und Academy stecken in einem Programm, jedes
// mit eigenem GetRefAPI, GetGameAPI und vmMain. Nach dem Teil-Link sind diese
// Symbole lokal, und dlsym(RTLD_DEFAULT) fände sie entweder nicht oder — wären
// sie global — die falsche Fassung.
//
// Der andere ist Erfahrung. Vorher stand hier ein reiner Ankertisch, der die
// Symbole nur am Leben hielt, während dlsym sie über Zeichenketten suchte. Er
// nannte vmMain und dllEntry nicht, und -dead_strip warf sie im Release-Build
// weg: das Spiel brach im Hauptmenü mit "Failed to load client game functions"
// ab. Zwei Listen, die übereinstimmen MÜSSEN, aber nicht müssen — jetzt ist es
// eine.
//
// `used` bleibt: die Tabelle wird nur über den Namen gesucht, nicht aufgerufen.
struct JKXR_visionOS_Modulfunktion {
    const char *name;
    void *fn;
};

__attribute__((used))
static const JKXR_visionOS_Modulfunktion s_moduleFunctions[] = {
    { "GetGameAPI", (void *)&GetGameAPI },
    { "GetRefAPI",  (void *)&GetRefAPI  },
    { "vmMain",     (void *)&vmMain     },
    { "dllEntry",   (void *)&dllEntry   },
};

/*
=================
JKXR_visionOS_ModuleHandle

Ersatz für RTLD_DEFAULT. Ein Zeiger auf die Tabelle selbst, damit ein falsches
Handle auffällt statt stillschweigend zu funktionieren.
=================
*/
extern "C" void *JKXR_visionOS_ModuleHandle(void)
{
    return (void *)s_moduleFunctions;
}

/*
=================
JKXR_visionOS_LoadFunction

Gegenstück zu dlsym. Vier Einträge, also eine lineare Suche — sie läuft beim
Start je Modul einmal.
=================
*/
extern "C" void *JKXR_visionOS_LoadFunction(void *handle, const char *name)
{
    if (handle != (void *)s_moduleFunctions || !name) {
        return NULL;
    }
    for (const JKXR_visionOS_Modulfunktion &f : s_moduleFunctions) {
        if (!strcmp(f.name, name)) {
            return f.fn;
        }
    }
    return NULL;
}

/*
=================
JKXR_visionOS_LibraryError

Gegenstück zu dlerror. Die Meldung nennt die Tabelle, weil dort die Ursache
liegt, wenn ein Name nicht gefunden wird — nicht im Dateisystem.
=================
*/
extern "C" const char *JKXR_visionOS_LibraryError(void)
{
    return "kein Eintrag in s_moduleFunctions (visionos_main.mm)";
}

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
    return JKXR_visionOS_ModuleHandle();
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

    *GetGameAPIOut = (GetGameAPIProc *)Sys_LoadFunction(
        JKXR_visionOS_ModuleHandle(), "GetGameAPI");
    if (!*GetGameAPIOut) {
        Com_Printf("Sys_LoadSPGameDll: GetGameAPI nicht auffindbar: %s\n",
                   Sys_LibraryError());
        return NULL;
    }

    return JKXR_visionOS_ModuleHandle();
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
        if (dirs.count == 0) {
            return installPath;
        }

        // Je Spiel ein eigener Unterordner, damit beide ihr "base" behalten
        // können. Er wird hier angelegt und nicht erst beim ersten Schreiben:
        // sonst gäbe es in der Dateien-App nichts, wohin man die pk3-Dateien
        // legen könnte, und die Fehlermeldung wäre "base nicht gefunden" ohne
        // sichtbaren Ausweg.
        NSString *pfad = [dirs[0] stringByAppendingPathComponent:
                                     @JKXR_SPIELORDNER];
        NSError *err = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:pfad
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:&err]) {
            Com_Printf("Sys_DefaultInstallPath: %s liess sich nicht anlegen: %s\n",
                       JKXR_SPIELORDNER, err.localizedDescription.UTF8String);
        }
        Q_strncpyz(installPath, [pfad UTF8String], sizeof(installPath));
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

    // Sofort leeren.
    //
    // stderr ist zwar üblicherweise ungepuffert, über die Weiterleitung von
    // devicectl aber vollgepuffert. Bei einem Absturz geht der Puffer verloren,
    // und das Protokoll endet nicht dort, wo es knallte, sondern beim letzten
    // tatsächlich geschriebenen Block. Genau das hat hier zwei Läufe gekostet:
    // derselbe Build zeigte einmal "Server Initialization" und einmal nicht.
    fflush(stderr);
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
/*
=================
Rückverfolgung bei Speicherzugriffsfehlern

visionOS legt für abgestürzte Prozesse keinen Bericht ab, den wir hier abholen
könnten, und das Konsolenprotokoll endet bei einem SIGSEGV einfach mitten im
Satz. Ohne Aufrufkette bleibt nur Raten, an welcher Stelle im Spielstart es
knallt.

backtrace_symbols_fd ist ausdrücklich signalsicher — es allokiert nicht und
formatiert direkt in den Dateideskriptor. Deshalb hier und nicht das bequemere
backtrace_symbols, das malloc benutzt und in einem Signalhandler hängen kann.
=================
*/
static void JKXR_CrashHandler(int sig)
{
    void *frames[64];
    const int count = backtrace(frames, 64);

    const char *name = (sig == SIGSEGV) ? "SIGSEGV"
                     : (sig == SIGBUS)  ? "SIGBUS"
                     : (sig == SIGILL)  ? "SIGILL"  : "Signal";
    char header[64];
    const int n = snprintf(header, sizeof(header), "\n*** %s — Aufrufkette:\n", name);
    write(STDERR_FILENO, header, (size_t)n);
    backtrace_symbols_fd(frames, count, STDERR_FILENO);

    // Voreinstellung wiederherstellen und erneut auslösen, damit das System
    // den Absturz normal behandelt statt hier hängenzubleiben.
    signal(sig, SIG_DFL);
    raise(sig);
}

extern "C" Q_EXPORT int JKXR_visionOS_Main(int argc, char *argv[])
{
    signal(SIGSEGV, JKXR_CrashHandler);
    signal(SIGBUS,  JKXR_CrashHandler);
    signal(SIGILL,  JKXR_CrashHandler);

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

    // Hier endet der PROZESS, nicht nur die Schleife.
    //
    // Warum kein zweiter Durchgang: id Tech 3 ist nicht darauf ausgelegt, in
    // einem Prozess zweimal zu starten. Com_Init verteilt den Hunk, legt cvars
    // an, baut das Dateisystem auf und meldet Kommandos an -- alles gegen
    // globalen Zustand, den Com_Shutdown nur teilweise zurücknimmt. Dazu kommen
    // auf visionOS der ANGLE-Kontext, gl4es' Zustand und die ARKit-Provider.
    //
    // Vorher kehrte diese Funktion einfach zurück. Schloss man den Immersive
    // Space mit der Krone und öffnete ihn wieder, lief Com_Init auf eine halb
    // abgebaute Engine: das Spiel lud nicht mehr, und mitunter musste die Brille
    // neu starten. Ein sauberer Neustart im Prozess wäre der schönere Weg, aber
    // er verlangt eine vollständige Abbaukette durch drei Fremdschichten -- und
    // solange die nicht steht, ist ein ehrliches Ende besser als ein Zustand,
    // aus dem nur ein Geräteneustart heraushilft.
    //
    // Die Reihenfolge ist die von Com_Quit_f (common.cpp:320) und nicht selbst
    // erfunden: Com_Shutdown darin schreibt die Konfiguration und schliesst das
    // Protokoll. Ohne diesen Aufruf gingen Einstellungen des Laufs verloren.
    CL_ShutdownUI();

    // Die Meldung VOR der Abbaukette: Com_Shutdown schliesst das Protokoll, und
    // danach geschriebene Zeilen landen nirgends.
    Com_Printf( "JKXR beendet sich: der Immersive Space wurde geschlossen.\n" );

    SV_Shutdown( "Immersive Space geschlossen\n" );
    CL_Shutdown();
    Com_Shutdown();
    FS_Shutdown();

    exit( 0 );
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

// ---------------------------------------------------------------------------
// Die Spieltabelle
//
// Der EINZIGE Name, den dieser Satz nach außen trägt. Alles andere wird beim
// Teil-Link lokal, damit Outcast und Academy im selben Programm nebeneinander
// bestehen können — Begründung in JKXR_visionOS_Spiel.h und link-visionos.sh.
//
// Definiert in dieser Datei, weil sie zu jedem Satz gehört und die Engineseite
// der sechs Funktionen kennt. Die vier TBXR-Funktionen liegen in derselben
// Übersetzungseinheit-Gruppe (JKXR/visionos), deshalb genügt die Deklaration.
// ---------------------------------------------------------------------------

extern "C" void TBXR_visionOS_SetLayerRenderer(cp_layer_renderer_t renderer);
extern "C" void TBXR_visionOS_SetScreenRes(int width, int height);
extern "C" void TBXR_visionOS_DumpInputs(void);
extern "C" void TBXR_visionOS_SetAccessoryTracking(void *provider);

#if JK2_MODE
#define JKXR_SPIELTABELLE JKXR_visionOS_Spiel_jo
#else
#define JKXR_SPIELTABELLE JKXR_visionOS_Spiel_ja
#endif

extern "C" Q_EXPORT const JKXR_visionOS_Spiel JKXR_SPIELTABELLE = {
    JKXR_SPIELNAME,
    JKXR_visionOS_Main,
    JKXR_visionOS_RequestShutdown,
    TBXR_visionOS_SetLayerRenderer,
    TBXR_visionOS_SetScreenRes,
    TBXR_visionOS_DumpInputs,
    TBXR_visionOS_SetAccessoryTracking,
};
