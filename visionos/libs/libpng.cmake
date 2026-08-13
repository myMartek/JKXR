# Erzeugt aus Android.mk von mk2cmake.py — nicht von Hand ändern.
# Modul: libpng, 17 Quelldateien

add_library(libpng STATIC
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libpng/arm/arm_init.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libpng/arm/filter_neon_intrinsics.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libpng/png.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libpng/pngerror.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libpng/pngget.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libpng/pngmem.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libpng/pngpread.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libpng/pngread.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libpng/pngrio.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libpng/pngrtran.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libpng/pngrutil.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libpng/pngset.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libpng/pngtrans.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libpng/pngwio.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libpng/pngwrite.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libpng/pngwtran.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libpng/pngwutil.c
)

target_include_directories(libpng PUBLIC
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libpng
)
