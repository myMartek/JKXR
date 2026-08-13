/*
 * Umsetzung von __android_log_print für visionOS.
 *
 * Siehe compat/android/log.h. Getrennt von der Header-Datei, weil sie aus
 * mehreren Übersetzungseinheiten eingebunden wird.
 */

#include <stdarg.h>
#include <stdio.h>

#include "qcommon/q_shared.h"
#include "qcommon/qcommon.h"

extern "C" int __android_log_print(int prio, const char *tag, const char *fmt, ...)
{
    char buf[2048];

    va_list ap;
    va_start(ap, fmt);
    const int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    // Com_Printf wertet '%' im Argument selbst aus. Ohne "%s" würde ein
    // Prozentzeichen in einer bereits formatierten Meldung ein zweites Mal
    // interpretiert — und läse Argumente, die es nicht gibt.
    Com_Printf("[%s] %s\n", tag ? tag : "JNI", buf);

    (void)prio;
    return n;
}
