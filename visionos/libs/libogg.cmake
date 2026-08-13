# Erzeugt aus Android.mk von mk2cmake.py — nicht von Hand ändern.

add_library(libogg STATIC
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libogg/bitwise.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libogg/framing.c
)

target_include_directories(libogg PUBLIC
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libogg
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libogg
)

target_compile_options(libogg PRIVATE
    $<$<COMPILE_LANGUAGE:C>:-ffast-math>
    $<$<COMPILE_LANGUAGE:C>:-fsigned-char>
)
