# Erzeugt aus Android_gles_ja.mk von mk2cmake.py — nicht von Hand ändern.
# Modul: rd-gles-ja_arm, 44 Quelldateien
#
# Pfade sind relativ zu dieser Datei (CMAKE_CURRENT_LIST_DIR), damit ein
# frischer Klon an beliebigem Ort konfiguriert.

add_library(rd-gles-ja_arm STATIC
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/qcommon/matcomp.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/qcommon/q_shared.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-common/tr_font.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-common/tr_image_jpg.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-common/tr_image_load.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-common/tr_image_png.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-common/tr_image_tga.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-common/tr_noise.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/G2_API.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/G2_bolts.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/G2_bones.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/G2_misc.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/G2_surfaces.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_WorldEffects.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_arb.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_backend.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_bsp.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_cmds.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_curve.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_draw.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_ghoul2.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_image.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_init.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_light.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_main.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_marks.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_mesh.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_model.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_quicksprite.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_scene.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_shade.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_shade_calc.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_shader.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_shadows.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_skin.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_sky.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_stl.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_subs.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_surface.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_surfacesprites.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles/tr_world.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/shared/qcommon/q_color.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/shared/qcommon/q_math.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/shared/qcommon/q_string.c
)

target_include_directories(rd-gles-ja_arm PUBLIC
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/JKXR
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/lib
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/client
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/server
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/libs/freetype2/include
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/common
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/gl
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenXR-SDK/include
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenXR-SDK/src/common
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/shared
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/ui
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/lib/gsl-lite/include
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libpng
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-gles
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/OpenJK/code/rd-common
)

target_compile_options(rd-gles-ja_arm PRIVATE
    -DHAVE_GLES
    -DFINAL_BUILD
    -fexceptions
    -Wall
    -Wno-write-strings
    -Wno-comment
    -fno-caller-saves
    -fno-tree-vectorize
    -Wno-unused-but-set-variable
    -fvisibility=hidden
    -O1
    -DRENDERER
    -D_JK2EXE
    -DSP_GAME
    -Wno-narrowing
    $<$<COMPILE_LANGUAGE:CXX>:-std=gnu++14>
    $<$<COMPILE_LANGUAGE:CXX>:-fvisibility-inlines-hidden>
    $<$<COMPILE_LANGUAGE:CXX>:-Wno-invalid-offsetof>
    $<$<COMPILE_LANGUAGE:CXX>:-fvisibility=hidden>
    $<$<COMPILE_LANGUAGE:CXX>:-O1>
)
