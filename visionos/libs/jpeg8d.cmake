# Erzeugt aus Android.mk von mk2cmake.py — nicht von Hand ändern.
# Modul: libjpeg, 46 Quelldateien
#
# Pfade sind relativ zu dieser Datei (CMAKE_CURRENT_LIST_DIR), damit ein
# frischer Klon an beliebigem Ort konfiguriert.

add_library(libjpeg STATIC
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jaricom.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jcapimin.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jcapistd.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jcarith.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jccoefct.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jccolor.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jcdctmgr.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jchuff.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jcinit.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jcmainct.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jcmarker.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jcmaster.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jcomapi.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jcparam.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jcprepct.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jcsample.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jctrans.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jdapimin.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jdapistd.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jdarith.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jdatadst.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jdatasrc.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jdcoefct.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jdcolor.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jddctmgr.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jdhuff.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jdinput.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jdmainct.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jdmarker.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jdmaster.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jdmerge.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jdpostct.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jdsample.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jdtrans.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jerror.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jfdctflt.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jfdctfst.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jfdctint.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jidctflt.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jidctfst.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jidctint.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jmemmgr.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jmemnobs.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jquant1.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jquant2.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d/jutils.c
)

target_include_directories(libjpeg PUBLIC
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/jpeg8d
)
