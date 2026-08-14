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

// ---------------------------------------------------------------------------
// GLES-Rendering in die Texturen von CompositorServices
// ---------------------------------------------------------------------------

static GLuint g_program = 0;
static GLint g_mvpLocation = -1;
static GLuint g_fbo = 0;

static const char *kVertexSource =
    "#version 300 es\n"
    "uniform mat4 uMVP;\n"
    "out vec3 vColor;\n"
    "void main() {\n"
    // Dieselben Eckpunkte und Farben wie im Metal-Shader — nur so ist der
    // Vergleich zwischen beiden Pfaden aussagekräftig.
    "    vec3 positions[3];\n"
    "    positions[0] = vec3(-0.3, -0.3, 0.0);\n"
    "    positions[1] = vec3( 0.3, -0.3, 0.0);\n"
    "    positions[2] = vec3( 0.0,  0.3, 0.0);\n"
    "    vec3 colors[3];\n"
    "    colors[0] = vec3(1.0, 0.2, 0.2);\n"
    "    colors[1] = vec3(0.2, 1.0, 0.3);\n"
    "    colors[2] = vec3(0.3, 0.4, 1.0);\n"
    "    vColor = colors[gl_VertexID];\n"
    "    gl_Position = uMVP * vec4(positions[gl_VertexID], 1.0);\n"
    "}\n";

static const char *kFragmentSource =
    "#version 300 es\n"
    "precision mediump float;\n"
    "in vec3 vColor;\n"
    "out vec4 fragColor;\n"
    "void main() { fragColor = vec4(vColor, 1.0); }\n";

static GLuint g_backgroundProgram = 0;

// Gegenstück zum Metal-Hintergrund: bildschirmfüllend, knapp vor der fernen
// Ebene. Der Wert 1e-4 ist bewusst nicht 0.0 — das wäre exakt der Clear-Wert
// bei Reversed-Z und damit für den Compositor "nichts".
static const char *kBackgroundVertexSource =
    "#version 300 es\n"
    "void main() {\n"
    "    vec2 corners[4];\n"
    "    corners[0] = vec2(-1.0, -1.0);\n"
    "    corners[1] = vec2( 1.0, -1.0);\n"
    "    corners[2] = vec2(-1.0,  1.0);\n"
    "    corners[3] = vec2( 1.0,  1.0);\n"
    // OpenGLs NDC-z läuft von -1 bis 1; 1e-4 in Metal-Tiefe entspricht hier
    // 2*1e-4 - 1, also knapp vor der fernen Ebene.
    "    gl_Position = vec4(corners[gl_VertexID], -0.9998, 1.0);\n"
    "}\n";

static const char *kBackgroundFragmentSource =
    "#version 300 es\n"
    "precision mediump float;\n"
    "out vec4 fragColor;\n"
    "void main() { fragColor = vec4(0.0, 0.25, 0.35, 1.0); }\n";

static GLuint compile_shader(GLenum type, const char *source) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);

    GLint ok = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        // Erst die Länge erfragen: ein leerer Fehlertext ist mehrdeutig und
        // hat hier schon einmal in die Irre geführt. Bleibt er leer, liegt es
        // meist daran, dass gar kein GL-Kontext aktiv ist.
        GLint length = 0;
        glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &length);
        char log[1024] = {0};
        if (length > 0) {
            glGetShaderInfoLog(shader, sizeof(log) - 1, NULL, log);
        }
        printf("[ANGLE] Shader-Übersetzung fehlgeschlagen (Logtext %d Zeichen): %s\n",
               length, length > 0 ? log
                                  : "<leer — vermutlich kein aktiver GL-Kontext>");
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

static bool ensure_program(void) {
    if (g_program != 0) return true;

    GLuint vs = compile_shader(GL_VERTEX_SHADER, kVertexSource);
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER, kFragmentSource);
    if (!vs || !fs) return false;

    g_program = glCreateProgram();
    glAttachShader(g_program, vs);
    glAttachShader(g_program, fs);
    glLinkProgram(g_program);

    GLint ok = 0;
    glGetProgramiv(g_program, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[512];
        glGetProgramInfoLog(g_program, sizeof(log), NULL, log);
        printf("[ANGLE] Programm-Linken fehlgeschlagen: %s\n", log);
        glDeleteProgram(g_program);
        g_program = 0;
        return false;
    }

    glDeleteShader(vs);
    glDeleteShader(fs);
    g_mvpLocation = glGetUniformLocation(g_program, "uMVP");
    return true;
}

static bool ensure_background_program(void) {
    if (g_backgroundProgram != 0) return true;

    GLuint vs = compile_shader(GL_VERTEX_SHADER, kBackgroundVertexSource);
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER, kBackgroundFragmentSource);
    if (!vs || !fs) return false;

    g_backgroundProgram = glCreateProgram();
    glAttachShader(g_backgroundProgram, vs);
    glAttachShader(g_backgroundProgram, fs);
    glLinkProgram(g_backgroundProgram);

    GLint ok = 0;
    glGetProgramiv(g_backgroundProgram, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[512];
        glGetProgramInfoLog(g_backgroundProgram, sizeof(log), NULL, log);
        printf("[ANGLE] Hintergrund-Programm-Linken fehlgeschlagen: %s\n", log);
        glDeleteProgram(g_backgroundProgram);
        g_backgroundProgram = 0;
        return false;
    }

    glDeleteShader(vs);
    glDeleteShader(fs);
    return true;
}

/// Importiert eine MTLTexture als GL-Textur. Der Aufrufer besitzt beides und
/// muss nach dem Zeichnen wieder aufräumen.
// EGLImage-Funktionen sind Extensions und stehen nicht als normale Symbole
// bereit — sie müssen zur Laufzeit aufgelöst werden.
static PFNEGLCREATEIMAGEKHRPROC eglCreateImage_ = NULL;
static PFNEGLDESTROYIMAGEKHRPROC eglDestroyImage_ = NULL;
static PFNGLEGLIMAGETARGETTEXTURE2DOESPROC glImageTargetTexture_ = NULL;

static void resolve_image_functions(void) {
    if (eglCreateImage_) return;
    eglCreateImage_ = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
    eglDestroyImage_ = (PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");
    glImageTargetTexture_ = (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)
        eglGetProcAddress("glEGLImageTargetTexture2DOES");
}

static bool import_texture(const void *mtlTexture, int slice,
                           GLuint *outTexture, EGLImageKHR *outImage,
                           const char *label) {
    resolve_image_functions();
    PFNEGLCREATEIMAGEKHRPROC createImage = eglCreateImage_;
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC imageTargetTexture = glImageTargetTexture_;
    if (!createImage || !imageTargetTexture || !eglDestroyImage_) {
        printf("[ANGLE] Import-Funktionen fehlen (createImage=%p target=%p)\n",
               (void *)createImage, (void *)imageTargetTexture);
        return false;
    }

    const EGLint attribs[] = {
        EGL_METAL_TEXTURE_ARRAY_SLICE_ANGLE, slice,
        EGL_NONE
    };

    EGLImageKHR image = createImage(g_display, EGL_NO_CONTEXT,
                                    EGL_METAL_TEXTURE_ANGLE,
                                    (EGLClientBuffer)mtlTexture, attribs);
    if (image == EGL_NO_IMAGE_KHR) {
        EGLint code = eglGetError();
        printf("[ANGLE] eglCreateImageKHR(%s, slice %d) schlug fehl: %s (0x%04x)\n",
               label, slice, egl_error_name(code), code);
        return false;
    }

    GLuint texture = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    imageTargetTexture(GL_TEXTURE_2D, image);

    GLenum err = glGetError();
    if (err != GL_NO_ERROR) {
        printf("[ANGLE] glEGLImageTargetTexture2DOES(%s) meldete 0x%04x\n", label, err);
        glDeleteTextures(1, &texture);
        eglDestroyImage_(g_display, image);
        return false;
    }

    *outTexture = texture;
    *outImage = image;
    return true;
}

// Fork-Ergänzung in ANGLEs Metal-Backend, siehe patch-angle-foveation.py.
// Ohne diesen Patch existiert das Symbol nicht.
extern void ANGLESetDrawFramebufferRateMapMTL(const void *rateMap);

bool angle_render_view(const void *colorTexture, const void *depthTexture,
                       const void *rateMap,
                       int slice, int originX, int originY,
                       int width, int height, const float *mvp16) {
    if (g_display == EGL_NO_DISPLAY || !ensure_program()) return false;

    GLuint colorTex = 0, depthTex = 0;
    EGLImageKHR colorImage = EGL_NO_IMAGE_KHR, depthImage = EGL_NO_IMAGE_KHR;

    if (!import_texture(colorTexture, slice, &colorTex, &colorImage, "Farbe")) {
        return false;
    }
    bool haveDepth = depthTexture != NULL
        && import_texture(depthTexture, slice, &depthTex, &depthImage, "Tiefe");

    if (g_fbo == 0) glGenFramebuffers(1, &g_fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, g_fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_2D, colorTex, 0);
    if (haveDepth) {
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                               GL_TEXTURE_2D, depthTex, 0);
    }

    // Rate Map am gebundenen Framebuffer setzen — muss nach dem Binden und vor
    // dem Zeichnen passieren. NULL schaltet Foveation wieder ab; das muss
    // ebenfalls durchgereicht werden, sonst bliebe eine Map aus einem früheren
    // Auge stehen.
    ANGLESetDrawFramebufferRateMapMTL(rateMap);

    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    bool ok = (status == GL_FRAMEBUFFER_COMPLETE);
    if (!ok) {
        printf("[ANGLE] Framebuffer unvollständig: 0x%04x (Tiefe %s)\n",
               status, haveDepth ? "importiert" : "FEHLT");
    } else {
        // Ursprung mitnehmen: die Viewport-Region der Drawable beginnt
        // nicht zwingend bei (0,0), und ein ignorierter Versatz verschiebt
        // das gesamte Bild.
        glViewport(originX, originY, width, height);

        // Reversed-Z wie im Metal-Pfad: leeren auf 0.0 (fern), Test auf
        // "größer ist näher".
        glEnable(GL_DEPTH_TEST);
        glDepthFunc(GL_GREATER);
        glDepthMask(GL_TRUE);
        glClearDepthf(0.0f);
        glClearColor(0.0f, 0.25f, 0.35f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        // Zwei Konventionsunterschiede zwischen Metal und OpenGL, beide in der
        // Matrix zu erledigen:
        //
        // 1. Tiefe: Metals Clip-Raum hat z in [0,1], OpenGLs in [-1,1]. Ohne
        //    Umrechnung läge die halbe Tiefe hinter der nahen Ebene.
        //
        // 2. Y-Achse: OpenGL hat den Framebuffer-Ursprung unten links, Metal
        //    den Texturursprung oben links. Beim Rendern in eine importierte
        //    Metal-Textur steht das Bild sonst vertikal gekippt. In der
        //    Bildmitte fällt das nicht auf — erst beim Kopfnicken läuft das
        //    Bild in die falsche Richtung und driftet doppelt weg.
        float gl_mvp[16];
        memcpy(gl_mvp, mvp16, sizeof(gl_mvp));
        for (int col = 0; col < 4; col++) {
            float y = mvp16[col * 4 + 1];
            float z = mvp16[col * 4 + 2];
            float w = mvp16[col * 4 + 3];
            gl_mvp[col * 4 + 1] = -y;
            gl_mvp[col * 4 + 2] = 2.0f * z - w;
        }

        // Hintergrund zuerst, auf einer sehr fernen, aber endlichen Ebene.
        // Ein reiner Clear bleibt unsichtbar: der Compositor zeigt nur, wo
        // Tiefe ungleich dem Clear-Wert steht.
        if (ensure_background_program()) {
            glUseProgram(g_backgroundProgram);
            glDepthFunc(GL_ALWAYS);
            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
            glDepthFunc(GL_GREATER);
        }

        glUseProgram(g_program);
        glUniformMatrix4fv(g_mvpLocation, 1, GL_FALSE, gl_mvp);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        glFlush();

        GLenum err = glGetError();
        if (err != GL_NO_ERROR) {
            printf("[ANGLE] GL-Fehler nach dem Zeichnen: 0x%04x\n", err);
            ok = false;
        }
    }

    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glDeleteTextures(1, &colorTex);
    eglDestroyImage_(g_display, colorImage);
    if (haveDepth) {
        glDeleteTextures(1, &depthTex);
        eglDestroyImage_(g_display, depthImage);
    }
    return ok;
}

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
