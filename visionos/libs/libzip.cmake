# Erzeugt aus Android.mk von mk2cmake.py — nicht von Hand ändern.
# Modul: libzip, 53 Quelldateien

add_library(libzip STATIC
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_add.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_add_dir.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_close.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_delete.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_dirent.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_entry_free.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_entry_new.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_err_str.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_error.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_error_clear.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_error_get.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_error_get_sys_type.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_error_strerror.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_error_to_str.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_fclose.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_file_error_clear.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_file_error_get.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_file_get_offset.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_file_strerror.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_filerange_crc.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_fopen.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_fopen_index.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_fread.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_free.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_get_archive_comment.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_get_archive_flag.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_get_file_comment.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_get_name.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_get_num_files.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_memdup.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_name_locate.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_new.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_open.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_rename.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_replace.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_set_archive_comment.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_set_archive_flag.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_set_file_comment.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_set_name.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_source_buffer.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_source_file.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_source_filep.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_source_free.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_source_function.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_source_zip.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_stat.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_stat_index.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_stat_init.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_strerror.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_unchange.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_unchange_all.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_unchange_archive.c
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip/zip_unchange_data.c
)

target_include_directories(libzip PUBLIC
    /Users/martek/Documents/Projects/botwvr/jkxr/Projects/Android/jni/SupportLibs/libzip
)
