/*
===========================================================================
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

// Die Schnittstelle zwischen der Swift-Hülle und einem Spiel.
//
// Jedi Outcast und Jedi Academy sind zwei vollständige Engines im selben
// Programm. Möglich ist das nur, weil jeder Satz zu einem Objekt teil-gelinkt
// wird, in dem ALLES lokal ist außer einem einzigen Symbol — sonst gäbe es
// Com_Printf, GetRefAPI und vmMain zweimal (siehe link-visionos.sh).
//
// Dieses eine Symbol ist die Tabelle unten. Sie ist damit nicht bloß eine
// bequeme Bündelung, sondern der Grund, weshalb die Konstruktion aufgeht: sechs
// Einsprungpunkte, ein Name.
//
// Die Gegenrichtung braucht das nicht. Was die Engine in der Hülle aufruft
// (ARKit-Provider, Zubehörgeräte) liegt im App-Ziel und bleibt global — beide
// Sätze dürfen dieselbe Fassung sehen.

#pragma once

#include <CompositorServices/CompositorServices.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Welches Spiel. Die Werte stehen so auch in der Swift-Seite.
typedef enum {
    JKXR_visionOS_JediAcademy = 0,
    JKXR_visionOS_JediOutcast = 1,
} JKXR_visionOS_SpielArt;

typedef struct {
    /// Der Name für Protokoll und Fehlermeldungen ("Jedi Academy").
    const char *name;

    /// Die Hauptschleife der Engine. Blockiert bis zum Ende.
    ///
    /// Auf einem eigenen Thread aufzurufen, niemals auf einer Warteschlange von
    /// Swift Concurrency: die Schleife gibt nie ab und würde den Pool
    /// aushungern. Genau dieser Fehler war in S4 die Ursache, dass ARKit keine
    /// Posen lieferte.
    int (*Main)(int argc, char *argv[]);

    /// Beendet die Schleife nach dem laufenden Bild.
    void (*RequestShutdown)(void);

    /// Übergibt den LayerRenderer. Danach kann die XR-Schicht Frames holen.
    ///
    /// Voraussetzung: ANGLE ist initialisiert und sein Kontext auf *diesem*
    /// Thread aktiv — die Funktion holt sich den EGLDisplay über
    /// eglGetCurrentDisplay().
    void (*SetLayerRenderer)(cp_layer_renderer_t renderer);

    /// Hinterlegt die Renderauflösung je Auge, in Screen-Koordinaten.
    ///
    /// Muss vor Main aufgerufen werden: WIN_Init fragt die Auflösung beim Start
    /// ab, CompositorServices gibt sie aber erst mit der ersten Drawable heraus
    /// (die C-API hat überhaupt keinen Zugriff auf Breite oder Höhe).
    void (*SetScreenRes)(int width, int height);

    /// Gibt die tatsächlichen Namen aller Elemente verbundener Controller aus.
    void (*DumpInputs)(void);

    /// Übergibt den Zubehör-Provider an das Action-System.
    ///
    /// Der Provider steht erst asynchron zur Verfügung, deshalb geschoben und
    /// nicht geholt.
    void (*SetAccessoryTracking)(void *provider);
} JKXR_visionOS_Spiel;

/// Die beiden Tabellen. Je eine pro teil-gelinktem Satz.
extern const JKXR_visionOS_Spiel JKXR_visionOS_Spiel_ja;
extern const JKXR_visionOS_Spiel JKXR_visionOS_Spiel_jo;

/// Das gewählte Spiel, gesetzt von der Hülle, sobald die Auswahl gefallen ist.
///
/// Liegt im App-Ziel (Sources/Bridge/SpielWahl.c), nicht in einem der Sätze —
/// die Auswahl steht ja gerade noch nicht fest, wenn sie gelesen wird.
extern const JKXR_visionOS_Spiel *JKXR_visionOS_Gewaehlt;

/// Setzt die Auswahl. Aus Swift aufgerufen.
void JKXR_visionOS_Waehle(JKXR_visionOS_SpielArt art);

#ifdef __cplusplus
}
#endif
