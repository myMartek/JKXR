# Erzeugt aus Android.mk von mk2cmake.py — nicht von Hand ändern.
# Modul: libzip, 53 Quelldateien
#
# Pfade sind relativ zu dieser Datei (CMAKE_CURRENT_LIST_DIR), damit ein
# frischer Klon an beliebigem Ort konfiguriert.

add_library(libzip STATIC
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_add.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_add_dir.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_close.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_delete.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_dirent.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_entry_free.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_entry_new.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_err_str.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_error.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_error_clear.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_error_get.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_error_get_sys_type.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_error_strerror.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_error_to_str.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_fclose.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_file_error_clear.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_file_error_get.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_file_get_offset.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_file_strerror.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_filerange_crc.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_fopen.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_fopen_index.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_fread.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_free.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_get_archive_comment.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_get_archive_flag.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_get_file_comment.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_get_name.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_get_num_files.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_memdup.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_name_locate.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_new.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_open.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_rename.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_replace.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_set_archive_comment.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_set_archive_flag.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_set_file_comment.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_set_name.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_source_buffer.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_source_file.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_source_filep.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_source_free.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_source_function.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_source_zip.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_stat.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_stat_index.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_stat_init.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_strerror.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_unchange.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_unchange_all.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_unchange_archive.c
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip/zip_unchange_data.c
)

target_include_directories(libzip PUBLIC
    ${CMAKE_CURRENT_LIST_DIR}/../../Projects/Android/jni/SupportLibs/libzip
)
