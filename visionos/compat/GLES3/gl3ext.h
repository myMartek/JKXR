/* Platzhalter für GLES3/gl3ext.h.
 *
 * Das Android-NDK liefert diesen Header als leere Hülle aus — er existiert nur
 * aus Abwärtskompatibilität und definiert nichts. ANGLE bringt ihn gar nicht
 * mit, JKXRs TBXR_Common.h bindet ihn aber ein.
 *
 * Absichtlich leer, nicht etwa eine Weiterleitung auf gl4es' GLES/gl3ext.h:
 * so entspricht es dem NDK-Original.
 */
#ifndef __gl3ext_h_
#define __gl3ext_h_
#endif
