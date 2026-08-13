/*
 * Erzeugt von patch-gl4es-darwin.py — nicht von Hand ändern.
 *
 * gl4es baut sein glx/-Verzeichnis nur unter Linux, Emscripten und AmigaOS.
 * Auf Darwin bleibt es außen vor, aber gl/init.c und gl/framebuffers.c rufen
 * drei Funktionen daraus trotzdem auf. Unter Emscripten fällt das nicht auf:
 * dort stehen die Aufrufe in `#ifndef __EMSCRIPTEN__`.
 *
 * Die Stubs sind nicht geraten. In der Konfiguration NOX11 + NOEGL, die wir
 * bauen, tut das Original genau nichts:
 *
 *   gl4es_getMainFBSize  ist in glx/glx.c vollständig von
 *                        `#if !defined(NOX11) && !defined(NOEGL) && !defined(ANDROID)`
 *                        umschlossen — der Rumpf ist leer, die übergebenen
 *                        Werte bleiben unverändert. Der Kommentar dort sagt es
 *                        ausdrücklich: "noegl, no updating of framebuffer size".
 *   glx_init             richtet die X11/EGL-Anbindung ein, die es hier nicht
 *                        gibt: ANGLE liefert den Kontext.
 *   LoadGBMFunctions     lädt libgbm, ein Linux-Grafikstack. Der Aufruf steht
 *                        ohnehin hinter `if (globals4es.usegbm)`, und usegbm
 *                        lässt sich außerhalb von Linux nicht einschalten.
 *
 * glx/hardext.c wird dagegen wirklich gebraucht (es definiert `hardext` und
 * GetHardwareExtensions) und behandelt NOX11+NOEGL bereits selbst. Es wird
 * darum in die Bauliste aufgenommen, genau wie im Emscripten-Zweig.
 */

#include <GL/gl.h>

void glx_init(void)
{
}

void LoadGBMFunctions(void)
{
}

void gl4es_getMainFBSize(GLint *width, GLint *height)
{
    (void)width;
    (void)height;
}
