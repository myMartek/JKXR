# JKXR für visionOS — Support-Bibliotheken
#
# Die Dateien unter libs/ erzeugt mk2cmake.py aus JKXRs Android-Makefiles.
# Nicht von Hand ändern: bei einem JKXR-Update neu erzeugen lassen.
#
# gl4es ist bewusst nicht dabei — es hat einen eigenen, funktionierenden
# CMake-Build und braucht einen Sonderweg beim Linken (-alias_list und
# -force_load, siehe patch-gl4es-darwin.py).

cmake_minimum_required(VERSION 3.20)
project(jkxr_visionos_libs LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Die Bibliotheken stammen aus den frühen 2000ern und lösen reichlich moderne
# Warnungen aus. Sie hier abzuschalten hält die Ausgabe lesbar, damit echte
# Portierungsfehler nicht in tausenden Zeilen Rauschen untergehen.
add_compile_options(
    -Wno-implicit-function-declaration
    -Wno-int-conversion
    -Wno-incompatible-pointer-types
    -Wno-deprecated-non-prototype
    -Wno-shift-negative-value
)

# Nur, was die Engine-Module laut ihren Android-Makefiles tatsächlich brauchen:
#
#   openjk_ja   (Client)    sigc libzip libpng libminizip
#   rd-gles-ja  (Renderer)  libpng libjpeg
#   jagame                  —
#
# libogg, libvorbis und openal werden von keinem Modul referenziert. Audio läuft
# auf Android über OpenSL ES (-lOpenSLES) und gehört damit in die
# Plattformschicht, nicht in eine dieser Bibliotheken.
#
# Für libogg und libvorbis lagen erzeugte Dateien unter libs/, ohne dass sie
# jemand eingebunden hätte. Sie sind entfernt: unbenutzt und deshalb unbemerkt
# zwei Werkzeugversionen hinterhergehinkt — mit heutigem mk2cmake.py entsteht
# etwas anderes. Bei Bedarf neu erzeugen (die Makefiles liegen je Unterordner,
# nicht im gemeinsamen liboggvorbis/Android.mk):
#
#   python3 mk2cmake.py Projects/Android/jni/SupportLibs/liboggvorbis/libogg \
#       visionos/libs/libogg.cmake --context Projects/Android/jni/Application.mk
#
# Achtung: mk2cmake.py wertet ifeq nicht aus. libogg/Android.mk stellt seine
# ARM32-Flags (-march=armv6, -mfpu=vfp) hinter ifeq ($(TARGET_ARCH),arm); die
# landen ungefiltert in der Ausgabe und müssen für arm64 weg.
include(libs/libpng.cmake)
include(libs/jpeg8d.cmake)
include(libs/libzip.cmake)
include(libs/sigc++.cmake)
include(libs/minizip.cmake)

# Audio läuft ohne OpenAL.
#
# snd_dma.cpp bringt zwar einen vollständigen OpenAL-Pfad mit, aber der steht
# hinter `#if defined(_MSC_VER)` und ist an Windows gebunden: 207 EAX-Stellen
# ohne eigenen Schalter, der EAX-Manager über COM, LoadLibrary/GetProcAddress.
# JKXR nutzt ihn auf Quest gar nicht.
#
# Stattdessen läuft Quakes plattformneutraler Software-Mixer — derselbe
# Klangpfad wie im Quest-Port, also bereits mit der VR-Schicht erprobt. Darunter
# braucht es nur eine Senke mit fünf Funktionen (SNDDMA_*); auf Android ist das
# OpenSL ES, bei uns eine RemoteIO-AudioUnit in code/visionos/visionos_snd.mm.
#
# build-openal-visionos.sh baut openal-soft 1.24.3 für xrOS und funktioniert,
# wird hier aber nicht gebraucht. Es bleibt liegen, falls später echte
# 3D-Positionierung statt der Stereo-Panoramik des Mixers gewünscht ist.

# --- Engine ---------------------------------------------------------------
# Erster Kompilierversuch. Erwartbar sind Android-spezifische Abhängigkeiten
# (JNI, OpenSL ES, EGL/Android-Fensterverwaltung) und die Plattformschicht
# unter code/android/, für die es auf visionOS keine Entsprechung gibt.
# Die Reihenfolge der GL-Header ist hier entscheidend.
#
# Die Engine ruft Desktop-OpenGL im Immediate Mode auf — glBegin, glColorPointer,
# glCallList. Genau das emuliert gl4es, und nur seine Header deklarieren diese
# Funktionen. ANGLE liefert dagegen das *echte* GLES ohne Fixed-Function-
# Pipeline: stünden seine Header vorn, sähe die Engine die Emulationsschicht
# nicht und der Compiler meldete hunderte unbekannte Funktionen.
#
# ANGLE kommt erst beim Linken ins Spiel, unterhalb von gl4es.
set(GL4ES_INCLUDE
    "${CMAKE_CURRENT_SOURCE_DIR}/../Projects/Android/jni/SupportLibs/gl4es/include"
    CACHE PATH "gl4es-Header")
include_directories(BEFORE
    ${GL4ES_INCLUDE}
    "${CMAKE_CURRENT_SOURCE_DIR}/compat")

# ANGLE *nach* gl4es: die XR-Schicht braucht echtes GLES3 und die
# EGL_METAL_*-Erweiterungen, die Engine dagegen gl4es' Emulation.
set(ANGLE_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}/../spikes/s4-angle/angle-include"
    CACHE PATH "ANGLE-Header")
include_directories(${ANGLE_INCLUDE})

option(BUILD_ENGINE "Engine-Module mitbauen" OFF)
if(BUILD_ENGINE)
    # Zwei Spiele, zwei vollständige Engines.
    #
    # Jedi Outcast und Jedi Academy unterscheiden sich nicht in Daten, sondern im
    # Code: JK2_MODE ändert Client, Renderer und Spielcode, und codeJK2/ ist ein
    # eigener Spielcode-Baum. Sie lassen sich deshalb nicht zu einem Programm
    # zusammenfassen, sondern nur nebeneinander bauen.
    #
    # Dieselben Quelldateien, andere Makros — unsere visionOS-Änderungen in
    # code/client und code/rd-gles gelten damit für beide Spiele automatisch.
    #
    # Wie daraus EIN Programm mit Auswahl wird, steht in link-visionos.sh: jeder
    # Satz wird zu einem Objekt teil-gelinkt, in dem alles außer dem
    # Einsprungpunkt lokal ist. Erst das macht zwei Com_Printf im selben Bild
    # möglich.
    include(libs/openjk_game_ja.cmake)
    include(libs/openjk_gles_ja.cmake)
    include(libs/openjk_client_ja.cmake)
    include(libs/openjk_game_jo.cmake)
    include(libs/openjk_gles_jo.cmake)
    include(libs/openjk_client_jo.cmake)

    set(JKXR_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../Projects/Android/jni/OpenJK/JKXR")
    # --- Plattformschicht -------------------------------------------------
    # Was auf Android unter code/android/ liegt.
    set(OPENJK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../Projects/Android/jni/OpenJK")

    # Die Zielnamen stammen aus den Android-Makefiles und folgen keinem
    # einheitlichen Muster (jagamearm, aber jogamearm; rd-gles-ja_arm mit
    # Bindestrich). Deshalb eine Tabelle statt einer Namensrechnung.
    foreach(spiel ja jo)
        if(spiel STREQUAL "ja")
            set(client openjk_ja)
            set(renderer rd-gles-ja_arm)
            set(spielcode jagamearm)
            set(jk2flag "")
        else()
            set(client openjk_jo)
            set(renderer rd-gles-jo_arm)
            set(spielcode jogamearm)
            set(jk2flag -DJK2_MODE)
        endif()

        # Abhängigkeiten laut den Android-Makefiles. Die Include-Verzeichnisse der
        # Bibliotheken sind PUBLIC, werden also mitvererbt — sonst findet etwa der
        # Renderer jpeglib.h nicht.
        target_link_libraries(${renderer} PUBLIC libpng libjpeg)
        target_compile_definitions(${renderer} PRIVATE JKXR_VISIONOS=1)
        target_link_libraries(${client} PUBLIC sigc libzip libpng libminizip)
        target_compile_definitions(${client} PRIVATE JKXR_VISIONOS=1)
        # VORUEBERGEHEND: frisches Heimatverzeichnis zum Ausprobieren, siehe
        # sys_unix.cpp. Diese Zeile entfernen, um wieder OpenJK/OpenJO zu
        # benutzen.
        target_compile_definitions(${client} PRIVATE JKXR_FRISCHES_HEIM=1)

        # -fno-common, sonst trägt der Teil-Link nicht.
        #
        # Der MP3-Decoder (code/mp3code) schreibt seine Zustandsvariablen als
        # vorläufige Definitionen — `unsigned char PCM_Buffer[…];` ohne extern —
        # und die Android-Makefiles übersetzen mit -fcommon. Daraus werden
        # COMMON-Symbole, und die kann ld beim Teil-Link nicht lokal machen: sie
        # haben noch keine Sektion. Vierzehn davon blieben global und
        # kollidierten zwischen Outcast und Academy.
        #
        # Gefunden hat es die Gegenprobe am Ende von link-visionos.sh, nicht der
        # Linker — der hätte es erst beim Bau der App gemeldet, dann aber als
        # Wand aus "duplicate symbol".
        target_compile_options(${client} PRIVATE -fno-common)
        target_compile_options(${renderer} PRIVATE -fno-common)
        target_compile_options(${spielcode} PRIVATE -fno-common)

        # Das Spielmodul braucht das Makro genauso.
        #
        # Es fehlte hier, und zwar folgenlos still: jeder `#ifdef JKXR_VISIONOS` in
        # code/cgame, code/game und code/ui fiel ersatzlos weg, ohne Warnung. Betroffen
        # waren die Ausklammerung von vmMain in ui_main.cpp (gegen die Namenskollision
        # mit dem Spielcode) und die Rahmendicke in _UI_DrawSides/_UI_DrawTopBottom.
        #
        # Aufgefallen ist es erst, als ein Messpunkt in cg_draw.cpp stumm blieb und die
        # Zeichenkette auch im übersetzten Objekt nicht auftauchte.
        target_compile_definitions(${spielcode} PRIVATE JKXR_VISIONOS=1)

        # Die visionOS-XR-Schicht: Gegenstück zu android/TBXR_Common.cpp.
        # Objective-C++, weil CompositorServices, Metal und ARKit angesprochen
        # werden — deren C-API macht Swift-Interop entbehrlich.
        #
        # Sie wird PRO SPIEL übersetzt, nicht einmal geteilt: sie ruft die
        # Engine (Com_Printf, Cvar_*, VR-Zustand), und nach dem Teil-Link sind
        # diese Symbole in jedem Satz lokal. Eine geteilte Fassung könnte sich
        # nur auf einen der beiden beziehen. Auf Android gilt dasselbe aus
        # anderem Grund: dort sind die JKXR-Quellen Teil des Client-Moduls und
        # erben dessen Flags, JK2_MODE eingeschlossen.
        add_library(tbxr_visionos_${spiel} STATIC
            "${JKXR_DIR}/visionos/TBXR_Common.mm"
            # Nachbau des OpenXR-Action-Systems: sechzehn Funktionen auf ARKit
            # (Posen) und GameController (Tasten, Haptik).
            "${JKXR_DIR}/visionos/OpenXrActions.mm"
            # VR_Init: die cvar-Liste aus Androids JKXR_SurfaceView.cpp
            "${JKXR_DIR}/visionos/JKXR_visionOS.mm")
        # ANGLE muss hier VOR gl4es stehen — genau umgekehrt zur Engine. Die
        # XR-Schicht braucht die EGL_METAL_*-Erweiterungen und echtes GLES3;
        # gl4es' EGL-Header kennen beides nicht.
        target_include_directories(tbxr_visionos_${spiel} BEFORE PRIVATE ${ANGLE_INCLUDE})
        target_include_directories(tbxr_visionos_${spiel} PUBLIC
            "${JKXR_DIR}"
            "${CMAKE_CURRENT_SOURCE_DIR}/../Projects/Android/jni/OpenXR-SDK/include"
            "${CMAKE_CURRENT_SOURCE_DIR}/../Projects/Android/jni/OpenXR-SDK/include/openxr"
            "${CMAKE_CURRENT_SOURCE_DIR}/../Projects/Android/jni/OpenXR-SDK/src/common"
            "${CMAKE_CURRENT_SOURCE_DIR}/../Projects/Android/jni/OpenJK/code"
            "${CMAKE_CURRENT_SOURCE_DIR}/../Projects/Android/jni/OpenJK/shared")
        # JKXR_CLIENT ist nicht optional: ohne dieses Makro deklariert
        # VrClientInfo.h `vr` als Zeiger statt als Struktur, und die gesamte
        # VR-Schicht übersetzt gegen den falschen Typ. Auf Android fällt das nicht
        # auf, weil die JKXR-Quellen dort Teil des Client-Moduls sind und dessen
        # Flags erben (Android_client_ja.mk: -DBOTLIB -D_JK2EXE -DJKXR_CLIENT).
        target_compile_options(tbxr_visionos_${spiel} PRIVATE
            -DHAVE_GLES -DBOTLIB -D_JK2EXE -DJKXR_CLIENT ${jk2flag} -fobjc-arc)
        target_link_libraries(${client} PUBLIC tbxr_visionos_${spiel})

        # Zwei der Android-Dateien enthalten nichts Android-spezifisches und werden
        # unverändert mitübersetzt — kein Fork, keine Pflege einer zweiten Fassung:
        #
        #   android_window.cpp  cvars und Modustabelle; die einzigen Aufrufe nach
        #                       außen sind TBXR_submitFrame und TBXR_GetScreenRes
        #   in_android.cpp      Tastencodes, Achsen, Ereigniswarteschlange
        #                       (braucht compat/android/log.h)
        #
        # android_main.cpp dagegen nicht: q_platform.h definiert MACOS_X über
        # __APPLE_CC__, und dann greifen dort 17 Zweige für Desktop-macOS.
        target_sources(${client} PRIVATE
            "${OPENJK_DIR}/code/android/android_window.cpp"
            "${OPENJK_DIR}/code/android/in_android.cpp"
            "${OPENJK_DIR}/code/visionos/visionos_main.mm"
            "${OPENJK_DIR}/code/visionos/visionos_snd.mm"
            "${CMAKE_CURRENT_SOURCE_DIR}/compat/android_log.cpp")

        target_link_libraries(${client} PUBLIC
            "-framework AudioToolbox"
            "-framework AVFoundation"
            "-framework Foundation")
    endforeach()

    # Objective-C-ARC für die beiden .mm-Dateien der Plattformschicht.
    #
    # Auf Quelldateiebene gesetzt, nicht je Ziel: dieselbe Datei geht in beide
    # Clients, und set_source_files_properties gilt im ganzen Verzeichnis.
    set_source_files_properties(
        "${OPENJK_DIR}/code/visionos/visionos_main.mm"
        "${OPENJK_DIR}/code/visionos/visionos_snd.mm"
        PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
endif()
