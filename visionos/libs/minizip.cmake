# Erzeugt aus Android.mk von mk2cmake.py — nicht von Hand ändern.
# Modul: libminizip, 2 Quelldateien
#
# Pfade sind relativ zu dieser Datei (CMAKE_CURRENT_LIST_DIR), damit ein
# frischer Klon an beliebigem Ort konfiguriert.

add_library(libminizip STATIC
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/minizip/ioapi.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/minizip/unzip.c
)

target_include_directories(libminizip PUBLIC
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/minizip
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/minizip/include/minizip
)
