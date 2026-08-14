# Erzeugt aus Android.mk von mk2cmake.py — nicht von Hand ändern.
# Modul: sigc, 5 Quelldateien
#
# Pfade sind relativ zu dieser Datei (CMAKE_CURRENT_LIST_DIR), damit ein
# frischer Klon an beliebigem Ort konfiguriert.

add_library(sigc STATIC
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/sigc++/connection.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/sigc++/functors/slot_base.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/sigc++/signal.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/sigc++/signal_base.cpp
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/sigc++/trackable.cpp
)

target_include_directories(sigc PUBLIC
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs
)

target_compile_options(sigc PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:-fexceptions>
)
