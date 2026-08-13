# Erzeugt aus Android.mk von mk2cmake.py — nicht von Hand ändern.
# Modul: libminizip, 2 Quelldateien

add_library(libminizip STATIC
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/minizip/ioapi.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/minizip/unzip.c
)

target_include_directories(libminizip PUBLIC
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/minizip
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/minizip/include/minizip
)
