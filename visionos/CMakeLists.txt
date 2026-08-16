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
    include(libs/openjk_game_ja.cmake)
    include(libs/openjk_gles_ja.cmake)
    include(libs/openjk_client_ja.cmake)

    # Abhängigkeiten laut den Android-Makefiles. Die Include-Verzeichnisse der
    # Bibliotheken sind PUBLIC, werden also mitvererbt — sonst findet etwa der
    # Renderer jpeglib.h nicht.
    target_link_libraries(rd-gles-ja_arm PUBLIC libpng libjpeg)
    target_compile_definitions(rd-gles-ja_arm PRIVATE JKXR_VISIONOS=1)
    target_link_libraries(openjk_ja PUBLIC sigc libzip libpng libminizip)
    target_compile_definitions(openjk_ja PRIVATE JKXR_VISIONOS=1)

    # Das Spielmodul braucht das Makro genauso.
    #
    # Es fehlte hier, und zwar folgenlos still: jeder `#ifdef JKXR_VISIONOS` in
    # code/cgame, code/game und code/ui fiel ersatzlos weg, ohne Warnung. Betroffen
    # waren die Ausklammerung von vmMain in ui_main.cpp (gegen die Namenskollision
    # mit dem Spielcode) und die Rahmendicke in _UI_DrawSides/_UI_DrawTopBottom.
    #
    # Aufgefallen ist es erst, als ein Messpunkt in cg_draw.cpp stumm blieb und die
    # Zeichenkette auch im übersetzten Objekt nicht auftauchte.
    target_compile_definitions(jagamearm PRIVATE JKXR_VISIONOS=1)

    # Die visionOS-XR-Schicht: Gegenstück zu android/TBXR_Common.cpp.
    # Objective-C++, weil CompositorServices, Metal und ARKit angesprochen
    # werden — deren C-API macht Swift-Interop entbehrlich.
    set(JKXR_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../Projects/Android/jni/OpenJK/JKXR")
    add_library(tbxr_visionos STATIC
        "${JKXR_DIR}/visionos/TBXR_Common.mm"
        # Nachbau des OpenXR-Action-Systems: sechzehn Funktionen auf ARKit
        # (Posen) und GameController (Tasten, Haptik).
        "${JKXR_DIR}/visionos/OpenXrActions.mm"
        # VR_Init: die cvar-Liste aus Androids JKXR_SurfaceView.cpp
        "${JKXR_DIR}/visionos/JKXR_visionOS.mm")
    # ANGLE muss hier VOR gl4es stehen — genau umgekehrt zur Engine. Die
    # XR-Schicht braucht die EGL_METAL_*-Erweiterungen und echtes GLES3;
    # gl4es' EGL-Header kennen beides nicht.
    target_include_directories(tbxr_visionos BEFORE PRIVATE ${ANGLE_INCLUDE})
    target_include_directories(tbxr_visionos PUBLIC
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
    target_compile_options(tbxr_visionos PRIVATE
        -DHAVE_GLES -DBOTLIB -D_JK2EXE -DJKXR_CLIENT -fobjc-arc)
    target_link_libraries(openjk_ja PUBLIC tbxr_visionos)

    # --- Plattformschicht -------------------------------------------------
    # Was auf Android unter code/android/ liegt.
    set(OPENJK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../Projects/Android/jni/OpenJK")

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
    target_sources(openjk_ja PRIVATE
        "${OPENJK_DIR}/code/android/android_window.cpp"
        "${OPENJK_DIR}/code/android/in_android.cpp"
        "${OPENJK_DIR}/code/visionos/visionos_main.mm"
        "${OPENJK_DIR}/code/visionos/visionos_snd.mm"
        "${CMAKE_CURRENT_SOURCE_DIR}/compat/android_log.cpp")

    set_source_files_properties(
        "${OPENJK_DIR}/code/visionos/visionos_main.mm"
        "${OPENJK_DIR}/code/visionos/visionos_snd.mm"
        PROPERTIES COMPILE_OPTIONS "-fobjc-arc")

    target_link_libraries(openjk_ja PUBLIC
        "-framework AudioToolbox"
        "-framework AVFoundation"
        "-framework Foundation")
endif()
