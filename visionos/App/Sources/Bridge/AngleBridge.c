#include "AngleBridge.h"

#include <stdio.h>
#include <string.h>

#define EGL_EGL_PROTOTYPES 1
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
// gl2ext liefert die Prototypen der OES-Erweiterungen, unter anderem
// glEGLImageTargetTexture2DOES — den Kern des Texturimports.
#include <GLES2/gl2ext.h>

static EGLDisplay g_display = EGL_NO_DISPLAY;
static EGLContext g_context = EGL_NO_CONTEXT;
static const void *g_metalDevice = NULL;

// Beim Initialisieren eingesammelt, solange der Kontext dort noch aktiv ist.
// Danach wird er freigegeben, damit ihn der Renderthread übernehmen kann —
// ein EGL-Kontext darf immer nur auf einem Thread gleichzeitig aktiv sein.
static char g_vendor[128] = "?";
static char g_renderer[256] = "?";
static char g_version[128] = "?";

static const char *egl_error_name(EGLint code) {
    switch (code) {
        case EGL_SUCCESS:             return "EGL_SUCCESS";
        case EGL_NOT_INITIALIZED:     return "EGL_NOT_INITIALIZED";
        case EGL_BAD_ACCESS:          return "EGL_BAD_ACCESS";
        case EGL_BAD_ALLOC:           return "EGL_BAD_ALLOC";
        case EGL_BAD_ATTRIBUTE:       return "EGL_BAD_ATTRIBUTE";
        case EGL_BAD_CONFIG:          return "EGL_BAD_CONFIG";
        case EGL_BAD_CONTEXT:         return "EGL_BAD_CONTEXT";
        case EGL_BAD_DISPLAY:         return "EGL_BAD_DISPLAY";
        case EGL_BAD_MATCH:           return "EGL_BAD_MATCH";
        case EGL_BAD_PARAMETER:       return "EGL_BAD_PARAMETER";
        case EGL_BAD_SURFACE:         return "EGL_BAD_SURFACE";
        default:                      return "unbekannter EGL-Fehler";
    }
}

static void log_egl(const char *what) {
    EGLint code = eglGetError();
    printf("[ANGLE] %s schlug fehl: %s (0x%04x)\n", what, egl_error_name(code), code);
}

bool angle_init(void) {
    if (g_display != EGL_NO_DISPLAY) return true;

    // Metal-Backend ausdrücklich anfordern. Ohne diese Angabe würde ANGLE auf
    // Apple-Plattformen sonst nichts Brauchbares wählen.
    const EGLAttrib displayAttribs[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
        EGL_NONE
    };

    PFNEGLGETPLATFORMDISPLAYEXTPROC getPlatformDisplay =
        (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    if (!getPlatformDisplay) {
        printf("[ANGLE] eglGetPlatformDisplayEXT nicht verfügbar\n");
        return false;
    }

    // eglGetPlatformDisplayEXT nimmt EGLint-Attribute, nicht EGLAttrib.
    const EGLint displayAttribsInt[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
        EGL_NONE
    };
    (void)displayAttribs;

    g_display = getPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE,
                                   EGL_DEFAULT_DISPLAY, displayAttribsInt);
    if (g_display == EGL_NO_DISPLAY) {
        log_egl("eglGetPlatformDisplayEXT");
        return false;
    }

    EGLint major = 0, minor = 0;
    if (!eglInitialize(g_display, &major, &minor)) {
        log_egl("eglInitialize");
        g_display = EGL_NO_DISPLAY;
        return false;
    }
    printf("[ANGLE] EGL %d.%d initialisiert\n", major, minor);

    // Kontext ohne Surface: gerendert wird ausschließlich in FBOs, die auf
    // Texturen von CompositorServices zeigen. Eine Swapchain gibt es hier nicht
    // und braucht es auch nicht.
    EGLint configAttribs[] = {
        EGL_SURFACE_TYPE,    EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE,        8,
        EGL_GREEN_SIZE,      8,
        EGL_BLUE_SIZE,       8,
        EGL_ALPHA_SIZE,      8,
        EGL_DEPTH_SIZE,      24,
        EGL_NONE
    };
    EGLConfig config = NULL;
    EGLint configCount = 0;
    if (!eglChooseConfig(g_display, configAttribs, &config, 1, &configCount)
        || configCount == 0) {
        log_egl("eglChooseConfig");
        return false;
    }

    const EGLint contextAttribs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    g_context = eglCreateContext(g_display, config, EGL_NO_CONTEXT, contextAttribs);
    if (g_context == EGL_NO_CONTEXT) {
        log_egl("eglCreateContext");
        return false;
    }

    if (!eglMakeCurrent(g_display, EGL_NO_SURFACE, EGL_NO_SURFACE, g_context)) {
        log_egl("eglMakeCurrent (surfaceless)");
        return false;
    }

    // Das von ANGLE gewählte MTLDevice abfragen. Übereinstimmung mit dem Device
    // von CompositorServices ist Voraussetzung für den Texturimport — und
    // nichts, worauf man sich ungeprüft verlassen sollte.
    PFNEGLQUERYDISPLAYATTRIBEXTPROC queryDisplayAttrib =
        (PFNEGLQUERYDISPLAYATTRIBEXTPROC)eglGetProcAddress("eglQueryDisplayAttribEXT");
    PFNEGLQUERYDEVICEATTRIBEXTPROC queryDeviceAttrib =
        (PFNEGLQUERYDEVICEATTRIBEXTPROC)eglGetProcAddress("eglQueryDeviceAttribEXT");

    if (queryDisplayAttrib && queryDeviceAttrib) {
        EGLAttrib deviceHandle = 0;
        if (queryDisplayAttrib(g_display, EGL_DEVICE_EXT, &deviceHandle)) {
            EGLAttrib metalDevice = 0;
            if (queryDeviceAttrib((EGLDeviceEXT)deviceHandle,
                                  EGL_METAL_DEVICE_ANGLE, &metalDevice)) {
                g_metalDevice = (const void *)metalDevice;
            } else {
                log_egl("eglQueryDeviceAttribEXT(EGL_METAL_DEVICE_ANGLE)");
            }
        } else {
            log_egl("eglQueryDisplayAttribEXT(EGL_DEVICE_EXT)");
        }
    } else {
        printf("[ANGLE] Device-Query-Funktionen nicht verfügbar\n");
    }

    // GL-Strings jetzt einsammeln, solange der Kontext noch hier aktiv ist.
    const char *v = (const char *)glGetString(GL_VENDOR);
    const char *r = (const char *)glGetString(GL_RENDERER);
    const char *s = (const char *)glGetString(GL_VERSION);
    if (v) snprintf(g_vendor, sizeof(g_vendor), "%s", v);
    if (r) snprintf(g_renderer, sizeof(g_renderer), "%s", r);
    if (s) snprintf(g_version, sizeof(g_version), "%s", s);

    // Kontext wieder freigeben. Ohne das scheitert eglMakeCurrent auf dem
    // Renderthread mit EGL_BAD_ACCESS — ein Kontext darf immer nur auf genau
    // einem Thread aktiv sein.
    if (!eglMakeCurrent(g_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)) {
        log_egl("Freigeben des Kontexts nach der Initialisierung");
    }

    return true;
}

const void *angle_metal_device(void) {
    return g_metalDevice;
}

bool angle_make_current(void) {
    if (g_display == EGL_NO_DISPLAY || g_context == EGL_NO_CONTEXT) return false;
    if (eglGetCurrentContext() == g_context) return true;

    if (!eglMakeCurrent(g_display, EGL_NO_SURFACE, EGL_NO_SURFACE, g_context)) {
        log_egl("eglMakeCurrent auf dem Renderthread");
        return false;
    }
    printf("[ANGLE] Kontext auf dem Renderthread aktiviert\n");
    return true;
}

bool angle_has_extension(const char *name) {
    if (g_display == EGL_NO_DISPLAY) return false;
    const char *extensions = eglQueryString(g_display, EGL_EXTENSIONS);
    if (!extensions) return false;

    // Teilstring-Suche reicht nicht: "EGL_ANGLE_device_metal" käme auch in
    // "EGL_ANGLE_device_metal_shared_event" vor. Auf Wortgrenzen prüfen.
    size_t len = strlen(name);
    const char *p = extensions;
    while ((p = strstr(p, name)) != NULL) {
        bool startOK = (p == extensions) || (p[-1] == ' ');
        bool endOK = (p[len] == ' ') || (p[len] == '\0');
        if (startOK && endOK) return true;
        p += len;
    }
    return false;
}

// Der S4-Spike hatte hier seinen Renderpfad: Shader, Framebuffer und
// Texturimport, um ein Dreieck in die Drawable zu zeichnen und damit die Kette
// GLES -> ANGLE -> Metal -> CompositorServices zu belegen.
//
// Bei JKXR macht das die XR-Schicht selbst (JKXR/visionos/TBXR_Common.mm): sie
// importiert die Texturen, setzt die Rate-Map und übergibt der Engine einen
// fertigen Framebuffer. Diese Brücke fährt ANGLE nur noch hoch.

void angle_describe(char *out, size_t cap) {
    if (g_display == EGL_NO_DISPLAY) {
        snprintf(out, cap, "ANGLE nicht initialisiert");
        return;
    }

    // Aus angle_init(), nicht frisch abgefragt: hier ist der Kontext nicht mehr
    // aktiv, glGetString würde NULL liefern.
    const char *vendor = g_vendor;
    const char *renderer = g_renderer;
    const char *version = g_version;

    snprintf(out, cap,
             "GL_VENDOR:   %s\n"
             "GL_RENDERER: %s\n"
             "GL_VERSION:  %s\n"
             "MTLDevice:   %p (%s)\n"
             "metal_texture_client_buffer: %s",
             vendor ? vendor : "?",
             renderer ? renderer : "?",
             version ? version : "?",
             g_metalDevice,
             // EGL_ANGLE_device_metal ist eine *Device*-Extension und taucht
             // deshalb nicht in den Display-Extensions auf. Ob sie da ist,
             // beantwortet allein die geglückte Abfrage.
             g_metalDevice ? "abgefragt" : "Abfrage fehlgeschlagen",
             angle_has_extension("EGL_ANGLE_metal_texture_client_buffer")
                 ? "ja" : "NEIN");
}
