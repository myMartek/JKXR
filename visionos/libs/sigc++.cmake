# Erzeugt aus Android.mk von mk2cmake.py — nicht von Hand ändern.
# Modul: sigc, 5 Quelldateien

add_library(sigc STATIC
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/sigc++/connection.cpp
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/sigc++/functors/slot_base.cpp
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/sigc++/signal.cpp
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/sigc++/signal_base.cpp
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/sigc++/trackable.cpp
)

target_include_directories(sigc PUBLIC
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs
)

target_compile_options(sigc PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:-fexceptions>
)
