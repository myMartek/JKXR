# Erzeugt aus Android.mk von mk2cmake.py — nicht von Hand ändern.
# Modul: libpng, 17 Quelldateien
#
# Pfade sind relativ zu dieser Datei (CMAKE_CURRENT_LIST_DIR), damit ein
# frischer Klon an beliebigem Ort konfiguriert.

add_library(libpng STATIC
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libpng/arm/arm_init.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libpng/arm/filter_neon_intrinsics.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libpng/png.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libpng/pngerror.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libpng/pngget.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libpng/pngmem.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libpng/pngpread.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libpng/pngread.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libpng/pngrio.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libpng/pngrtran.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libpng/pngrutil.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libpng/pngset.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libpng/pngtrans.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libpng/pngwio.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libpng/pngwrite.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libpng/pngwtran.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libpng/pngwutil.c
)

target_include_directories(libpng PUBLIC
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libpng
)
