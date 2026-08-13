/*
 * <android/log.h> für visionOS.
 *
 * in_android.cpp baut sich daraus LOGI/LOGW/LOGE. Der Rest der Datei ist
 * plattformneutral — Tastencodes, Achsenbelegung, Ereigniswarteschlange —,
 * sodass dieser Shim genügt, um sie unverändert zu übersetzen.
 *
 * Ausgegeben wird über Com_Printf, nicht über NSLog oder printf: dann landen
 * die Meldungen in derselben Spielkonsole wie alles andere und lassen sich im
 * Headset lesen, wo kein Xcode-Protokoll zur Hand ist.
 *
 * Gegenstück: compat/android/keycodes.h
 */

#ifndef VISIONOS_COMPAT_ANDROID_LOG_H
#define VISIONOS_COMPAT_ANDROID_LOG_H

#ifdef __cplusplus
extern "C" {
#endif

/* Werte wie im NDK. Nur der Rang wird benutzt, nie als Index. */
typedef enum android_LogPriority {
    ANDROID_LOG_UNKNOWN = 0,
    ANDROID_LOG_DEFAULT,
    ANDROID_LOG_VERBOSE,
    ANDROID_LOG_DEBUG,
    ANDROID_LOG_INFO,
    ANDROID_LOG_WARN,
    ANDROID_LOG_ERROR,
    ANDROID_LOG_FATAL,
    ANDROID_LOG_SILENT
} android_LogPriority;

int __android_log_print(int prio, const char *tag, const char *fmt, ...);

#ifdef __cplusplus
}
#endif

#endif /* VISIONOS_COMPAT_ANDROID_LOG_H */
