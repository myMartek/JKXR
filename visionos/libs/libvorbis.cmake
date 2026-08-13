# Erzeugt aus Android.mk von mk2cmake.py — nicht von Hand ändern.

add_library(libvorbis STATIC
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis/analysis.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis/bitrate.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis/block.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis/codebook.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis/envelope.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis/floor0.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis/floor1.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis/info.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis/lookup.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis/lpc.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis/lsp.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis/mapping0.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis/mdct.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis/psy.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis/registry.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis/res0.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis/sharedbook.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis/smallft.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis/synthesis.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis/vorbisenc.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis/vorbisfile.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis/window.c
)

target_include_directories(libvorbis PUBLIC
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/liboggvorbis/libvorbis
)

target_compile_options(libvorbis PRIVATE
    $<$<COMPILE_LANGUAGE:C>:-ffast-math>
    $<$<COMPILE_LANGUAGE:C>:-fsigned-char>
)
