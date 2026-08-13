// JKXRs XR-Schicht für visionOS.
//
// Gegenstück zu android/TBXR_Common.cpp (OpenXR auf Quest/Pico) und
// windows/TBXR_Common.cpp (OpenXR auf PCVR). Hier läuft es über
// CompositorServices, das eine vollständige C-API mitbringt — Swift-Interop ist
// also nicht nötig.
//
// Der Renderpfad entspricht dem in spikes/s4-angle erprobten Verfahren:
// GLES rendert über ANGLE direkt in die Metal-Texturen der Drawable, ohne
// Zwischenkopie. Die dort teuer erkauften Fallstricke sind unten an den
// jeweiligen Stellen vermerkt.

// VrCommon.h bindet diesen Header selbst ein — andersherum entstünde ein
// Konflikt bei der Deklaration von "vr".
#include "TBXR_Common.h"

#import <CompositorServices/CompositorServices.h>
#import <Metal/Metal.h>
#import <ARKit/ARKit.h>
#import <QuartzCore/QuartzCore.h>

#include <dlfcn.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>

// Fork-Ergänzung in ANGLEs Metal-Backend, siehe spikes/s4-angle. Ohne diesen
// Patch existiert das Symbol nicht und Foveation ist unmöglich.
extern "C" void ANGLESetDrawFramebufferRateMapMTL(const void *rateMap);
#include <GLES/gl.h>
#include <GLES2/gl2ext.h>   // ANGLE: glEGLImageTargetTexture2DOES

// vec3_t für den Mathe-Block am Dateiende. Android bekommt es indirekt über
// seine Include-Kette; hier wird es ausdrücklich geholt.
#include "qcommon/q_shared.h"
#include "qcommon/qcommon.h"   // Cvar_VariableValue, Cbuf_AddText

// vr — die gemeinsame VR-Zustandsstruktur. Mit -DJKXR_CLIENT ist sie eine
// Struktur, ohne das Makro ein Zeiger (VrClientInfo.h:120).
#include "VrClientInfo.h"
extern vr_client_info_t vr;

// Aus JKXR_visionOS.mm, übernommen aus android/JKXR_SurfaceView.cpp.
void VR_SetHMDPosition(float x, float y, float z);
void VR_SetHMDOrientation(float pitch, float yaw, float roll);
void VR_FrameSetup();
void VR_HandleControllerInput();
void QuatToYawPitchRoll(XrQuaternionf q, vec3_t rotation, vec3_t out);


// ---------------------------------------------------------------------------
// GLES direkt von ANGLE, an gl4es vorbei
//
// Auf Android ist diese Trennung geschenkt: gl4es ist dort libGL.so, und
// TBXR_Common.cpp linkt gegen -lGLESv3. Die XR-Schicht spricht mit dem echten
// GLES, gl4es liegt nur unter der Engine.
//
// Bei uns ist alles statisch in einem Programm, und die 793 gl4es-Aliase
// (siehe patch-gl4es-darwin.py) belegen die Namen glGenTextures, glBindTexture
// und so fort. Ohne diese Umleitung liefen die Aufrufe hier durch gl4es'
// Emulation — die von EGLImage nichts weiß (kein einziger Treffer für
// EGLImageTargetTexture2DOES in ihrem gesamten gl/-Verzeichnis) und eigenen
// Zustand über Texturgrößen führt, den wir nie füllen.
//
// Die Engine benutzt weiterhin gl4es. Nur diese Schicht nicht.
// ---------------------------------------------------------------------------

namespace angle {

void (*GenTextures)(GLsizei, GLuint *) = nullptr;
void (*ActiveTexture)(GLenum) = nullptr;
void (*BindTexture)(GLenum, GLuint) = nullptr;
void (*DeleteTextures)(GLsizei, const GLuint *) = nullptr;
void (*GenFramebuffers)(GLsizei, GLuint *) = nullptr;
void (*BindFramebuffer)(GLenum, GLuint) = nullptr;
void (*FramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint) = nullptr;
GLenum (*CheckFramebufferStatus)(GLenum) = nullptr;
void (*Viewport)(GLint, GLint, GLsizei, GLsizei) = nullptr;
void (*Enable)(GLenum) = nullptr;
void (*Disable)(GLenum) = nullptr;
GLboolean (*IsEnabled)(GLenum) = nullptr;
void (*DepthFunc)(GLenum) = nullptr;
void (*DepthMask)(GLboolean) = nullptr;
void (*ClearDepthf)(GLfloat) = nullptr;
GLenum (*GetError)(void) = nullptr;
void (*Flush)(void) = nullptr;
void (*ClearColor)(GLfloat, GLfloat, GLfloat, GLfloat) = nullptr;
void (*Clear)(GLbitfield) = nullptr;
void (*Finish)(void) = nullptr;
GLuint (*CreateShader)(GLenum) = nullptr;
void (*ShaderSource)(GLuint, GLsizei, const GLchar *const *, const GLint *) = nullptr;
void (*CompileShader)(GLuint) = nullptr;
void (*GetShaderiv)(GLuint, GLenum, GLint *) = nullptr;
void (*GetShaderInfoLog)(GLuint, GLsizei, GLsizei *, GLchar *) = nullptr;
void (*DeleteShader)(GLuint) = nullptr;
GLuint (*CreateProgram)(void) = nullptr;
void (*AttachShader)(GLuint, GLuint) = nullptr;
void (*LinkProgram)(GLuint) = nullptr;
void (*GetProgramiv)(GLuint, GLenum, GLint *) = nullptr;
void (*GetProgramInfoLog)(GLuint, GLsizei, GLsizei *, GLchar *) = nullptr;
void (*UseProgram)(GLuint) = nullptr;
void (*DrawArrays)(GLenum, GLint, GLsizei) = nullptr;
void (*ColorMask)(GLboolean, GLboolean, GLboolean, GLboolean) = nullptr;
void (*GetIntegerv)(GLenum, GLint *) = nullptr;
void (*GetBooleanv)(GLenum, GLboolean *) = nullptr;

bool resolve()
{
    static bool done = false;
    static bool ok = false;
    if (done) return ok;
    done = true;

    // Dasselbe Handle, das auch gl4es benutzt. dlopen lädt nichts neu: das
    // Framework hängt bereits als LC_LOAD_DYLIB im Programm.
    //
    // NICHT RTLD_DEFAULT: das Hauptprogramm exportiert dieselben Namen als
    // gl4es-Aliase und käme in der Suchreihenfolge zuerst — wir bekämen genau
    // die Emulation zurück, die wir umgehen wollen.
    void *lib = dlopen("@rpath/libGLESv2.framework/libGLESv2", RTLD_LOCAL | RTLD_NOW);
    if (!lib) {
        ALOGE("libGLESv2 nicht ladbar: %s", dlerror());
        return false;
    }

    #define RESOLVE(name) \
        *(void **)&name = dlsym(lib, "gl" #name); \
        if (!name) { ALOGE("gl" #name " nicht in libGLESv2"); return false; }

    RESOLVE(GenTextures)
    RESOLVE(ActiveTexture)
    RESOLVE(BindTexture)
    RESOLVE(DeleteTextures)
    RESOLVE(GenFramebuffers)
    RESOLVE(BindFramebuffer)
    RESOLVE(FramebufferTexture2D)
    RESOLVE(CheckFramebufferStatus)
    RESOLVE(Viewport)
    RESOLVE(Enable)
    RESOLVE(Disable)
    RESOLVE(IsEnabled)
    RESOLVE(DepthFunc)
    RESOLVE(DepthMask)
    RESOLVE(ClearDepthf)
    RESOLVE(GetError)
    RESOLVE(Flush)
    RESOLVE(ClearColor)
    RESOLVE(Clear)
    RESOLVE(Finish)
    RESOLVE(CreateShader)
    RESOLVE(ShaderSource)
    RESOLVE(CompileShader)
    RESOLVE(GetShaderiv)
    RESOLVE(GetShaderInfoLog)
    RESOLVE(DeleteShader)
    RESOLVE(CreateProgram)
    RESOLVE(AttachShader)
    RESOLVE(LinkProgram)
    RESOLVE(GetProgramiv)
    RESOLVE(GetProgramInfoLog)
    RESOLVE(UseProgram)
    RESOLVE(DrawArrays)
    RESOLVE(ColorMask)
    RESOLVE(GetIntegerv)
    RESOLVE(GetBooleanv)
    #undef RESOLVE

    ok = true;
    return true;
}

} // namespace angle

// ---------------------------------------------------------------------------
// Zustand
// ---------------------------------------------------------------------------

ovrApp gAppState = {};
ovrJava java = {};

namespace {

/// Von der SwiftUI-Hülle gesetzt, sobald der Immersive Space offen ist.
cp_layer_renderer_t gLayerRenderer = nullptr;

cp_frame_t     gFrame    = nullptr;
cp_drawable_t  gDrawable = nullptr;
id<MTLCommandQueue>  gQueue = nil;
id<MTLCommandBuffer> gCommandBuffer = nil;

/// Pro Auge die aus der Drawable importierten GL-Objekte. Sie gelten nur für
/// den laufenden Frame und werden in TBXR_finishEyeBuffer wieder abgeräumt.
struct EyeImport {
    EGLImageKHR colorImage = EGL_NO_IMAGE_KHR;
    EGLImageKHR depthImage = EGL_NO_IMAGE_KHR;
    GLuint      colorTexture = 0;
    GLuint      depthTexture = 0;
};
EyeImport gEyes[ovrMaxNumEyes];
GLuint    gFramebuffer = 0;
GLuint    gBackgroundDepthProgram = 0;

/// Entspricht `superSampling` in der Android-Fassung.
float gSuperSampling = 1.0f;

/// Welches Auge gerade vorbereitet ist — RB_SetGL2D braucht das.
int gCurrentEye = 0;

/// Letzte bekannte Kopfposition und -ausrichtung im Weltursprung.
simd_float4x4 gHeadTransform = matrix_identity_float4x4;
bool gHeadValid = false;

/// Die eingerastete Wand. Weltfest, nicht kopfgekoppelt.
simd_float4x4 gWallTransform = matrix_identity_float4x4;
bool gWallSnapped = false;

/// Nur zur Fehlersuche: die ersten Bilder Schritt für Schritt protokollieren.
/// Der Absturz kommt wortlos, also muss die letzte erreichte Stelle her.
int gFrameCounter = 0;
#define TRACE(...) do { if (gFrameCounter < 3) ALOGV(__VA_ARGS__); } while (0)

bool forceMetalClear()
{
    static int enabled = -1;
    if (enabled < 0) {
        const char *value = getenv("JKXR_FORCE_METAL_CLEAR");
        enabled = value && value[0] != '\0' && strcmp(value, "0") != 0;
        if (enabled) {
            ALOGV("Diagnose: reiner Metal-Clear erzwungen");
        }
    }
    return enabled != 0;
}

bool forceAngleClear()
{
    static int enabled = -1;
    if (enabled < 0) {
        const char *value = getenv("JKXR_FORCE_ANGLE_CLEAR");
        enabled = value && value[0] != '\0' && strcmp(value, "0") != 0;
        if (enabled) ALOGV("Diagnose: reiner ANGLE-Clear erzwungen");
    }
    return enabled != 0;
}

GLuint compileBackgroundShader(GLenum type, const char *source)
{
    GLuint shader = angle::CreateShader(type);
    const GLchar *text = source;
    angle::ShaderSource(shader, 1, &text, nullptr);
    angle::CompileShader(shader);
    GLint compiled = GL_FALSE;
    angle::GetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (!compiled) {
        GLchar log[1024] = {};
        angle::GetShaderInfoLog(shader, sizeof(log), nullptr, log);
        ALOGE("ANGLE-Hintergrundshader fehlgeschlagen: %s", log);
        angle::DeleteShader(shader);
        return 0;
    }
    return shader;
}

bool ensureBackgroundDepthProgram()
{
    if (gBackgroundDepthProgram) return true;

    static const char *vertexSource =
        "#version 300 es\n"
        "void main() {\n"
        "  vec2 p[4];\n"
        "  p[0]=vec2(-1.0,-1.0); p[1]=vec2(1.0,-1.0);\n"
        "  p[2]=vec2(-1.0,1.0);  p[3]=vec2(1.0,1.0);\n"
        "  gl_Position=vec4(p[gl_VertexID],-0.9998,1.0);\n"
        "}\n";
    static const char *fragmentSource =
        "#version 300 es\n"
        "precision mediump float;\n"
        "out vec4 color;\n"
        "void main() { color=vec4(0.0); }\n";

    GLuint vertex = compileBackgroundShader(GL_VERTEX_SHADER, vertexSource);
    GLuint fragment = compileBackgroundShader(GL_FRAGMENT_SHADER, fragmentSource);
    if (!vertex || !fragment) return false;

    GLuint program = angle::CreateProgram();
    angle::AttachShader(program, vertex);
    angle::AttachShader(program, fragment);
    angle::LinkProgram(program);
    angle::DeleteShader(vertex);
    angle::DeleteShader(fragment);

    GLint linked = GL_FALSE;
    angle::GetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) {
        GLchar log[1024] = {};
        angle::GetProgramInfoLog(program, sizeof(log), nullptr, log);
        ALOGE("ANGLE-Hintergrundprogramm fehlgeschlagen: %s", log);
        return false;
    }
    gBackgroundDepthProgram = program;
    return true;
}

void drawBackgroundDepth()
{
    if (!ensureBackgroundDepthProgram()) return;

    GLint previousProgram = 0;
    GLboolean previousColorMask[4] = { GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE };
    angle::GetIntegerv(GL_CURRENT_PROGRAM, &previousProgram);
    angle::GetBooleanv(GL_COLOR_WRITEMASK, previousColorMask);

    // Das Quad schreibt ausschließlich einen sehr fernen Tiefenwert. Farbe
    // kommt danach von JKXR; dessen 2D-Pässe brauchen selbst keine Tiefe zu
    // schreiben und bleiben für den visionOS-Compositor trotzdem sichtbar.
    angle::ColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
    angle::Enable(GL_DEPTH_TEST);
    angle::DepthFunc(GL_ALWAYS);
    angle::DepthMask(GL_TRUE);
    angle::UseProgram(gBackgroundDepthProgram);
    angle::DrawArrays(GL_TRIANGLE_STRIP, 0, 4);

    angle::UseProgram((GLuint)previousProgram);
    angle::ColorMask(previousColorMask[0], previousColorMask[1],
                     previousColorMask[2], previousColorMask[3]);
    angle::DepthFunc(GL_GREATER);
    angle::DepthMask(GL_TRUE);
}

EGLDisplay gDisplay = EGL_NO_DISPLAY;

PFNEGLCREATEIMAGEKHRPROC  eglCreateImage_  = nullptr;
PFNEGLDESTROYIMAGEKHRPROC eglDestroyImage_ = nullptr;
PFNGLEGLIMAGETARGETTEXTURE2DOESPROC glImageTargetTexture_ = nullptr;

void resolveEglFunctions()
{
    if (eglCreateImage_) return;
    eglCreateImage_  = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
    eglDestroyImage_ = (PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");
    glImageTargetTexture_ = (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)
        eglGetProcAddress("glEGLImageTargetTexture2DOES");
}

/// Importiert eine MTLTexture als GL-Textur.
///
/// EGL_METAL_TEXTURE_ARRAY_SLICE_ANGLE wählt bei layered-Layout das Auge. Für
/// Foveation nutzen wir allerdings dedicated (siehe TBXR_InitRenderer), dort ist
/// die Slice immer 0.
bool importTexture(id<MTLTexture> texture, int slice,
                   GLuint *outTexture, EGLImageKHR *outImage, const char *what)
{
    resolveEglFunctions();
    if (!eglCreateImage_ || !glImageTargetTexture_) {
        ALOGE("EGL-Importfunktionen nicht verfügbar");
        return false;
    }

    const EGLint attribs[] = { EGL_METAL_TEXTURE_ARRAY_SLICE_ANGLE, slice, EGL_NONE };
    EGLImageKHR image = eglCreateImage_(gDisplay, EGL_NO_CONTEXT,
                                        EGL_METAL_TEXTURE_ANGLE,
                                        (EGLClientBuffer)(__bridge void *)texture, attribs);
    if (image == EGL_NO_IMAGE_KHR) {
        ALOGE("eglCreateImageKHR(%s) schlug fehl: 0x%04x", what, eglGetError());
        return false;
    }

    GLuint name = 0;
    angle::GenTextures(1, &name);
    angle::BindTexture(GL_TEXTURE_2D, name);

    // Fehlerschlange leeren, bevor wir sie als Prüfung benutzen.
    //
    // glGetError liefert den ersten Fehler seit der letzten Abfrage. Solange
    // diese Schicht über gl4es lief, hat gl4es seinen Fehlerzustand selbst
    // geleert (errorGL()); seit wir ANGLE direkt ansprechen, bekommen wir auch
    // alles, was die Engine über gl4es hinterlassen hat — und die rendert
    // unmittelbar davor das Menü. Ohne dieses Leeren meldet der Import einen
    // Fehler, den ein ganz anderer verursacht hat.
    while (angle::GetError() != GL_NO_ERROR) { }

    glImageTargetTexture_(GL_TEXTURE_2D, image);

    GLenum error = angle::GetError();
    if (error != GL_NO_ERROR) {
        ALOGE("glEGLImageTargetTexture2DOES(%s): 0x%04x", what, error);
        angle::DeleteTextures(1, &name);
        eglDestroyImage_(gDisplay, image);
        return false;
    }

    *outTexture = name;
    *outImage = image;
    return true;
}

} // namespace

// ---------------------------------------------------------------------------
// Anbindung an die SwiftUI-Hülle
// ---------------------------------------------------------------------------

/*
=================
TBXR_visionOS_SetScreenRes

Von der App-Hülle aufzurufen, BEVOR der Engine-Thread startet.

CompositorServices gibt die Renderauflösung nirgends heraus — die C-API hat
keinen einzigen Zugriff auf Breite oder Höhe. Sie steht erst fest, wenn eine
Drawable existiert, also frühestens im ersten Frame.

Die Engine fragt sie aber schon beim Start: WIN_Init ruft TBXR_GetScreenRes auf,
um glConfig.vidWidth/vidHeight zu setzen. Daher muss die Hülle einen Frame
holen, die Größe daraus ablesen und sie hier hinterlegen, bevor sie
JKXR_visionOS_Main aufruft.

Anzugeben ist die Größe in **Screen-Koordinaten**, nicht die der physischen
Textur: bei aktiver Foveation ist die Textur kleiner, und die Rate-Map bildet
dazwischen ab. Rendert die Engine auf Texturgröße, verschenkt man genau die
Auflösung, für die die Foveation da ist.
=================
*/
extern "C" void JKXR_visionOS_RequestShutdown(void);

extern "C" void TBXR_visionOS_SetScreenRes(int width, int height)
{
    gAppState.Width = width;
    gAppState.Height = height;
    ALOGV("TBXR: Renderauflösung %dx%d je Auge (Screen-Koordinaten)",
          width, height);
}

/*
=================
TBXR_GetScreenRes
=================
*/
void TBXR_GetScreenRes(int *width, int *height)
{
    if (gAppState.Width == 0 || gAppState.Height == 0) {
        // Reihenfolge verletzt: die Hülle hat den Engine-Thread gestartet, ohne
        // vorher TBXR_visionOS_SetScreenRes aufzurufen. Lieber laut scheitern
        // als still in einer falschen Auflösung rendern.
        ALOGE("TBXR_GetScreenRes vor TBXR_visionOS_SetScreenRes aufgerufen");
        *width = 1920;
        *height = 1824;
        return;
    }

    // vr_super_sampling wie auf Android. Achtung: die Ausgangsauflösung ist
    // hier bereits sehr hoch (S4 hat 5087x4081 je Auge gemessen), Werte über
    // 1.0 sind also kaum sinnvoll.
    float configured = Cvar_VariableValue("vr_super_sampling");
    if (configured != 0.0f && configured != gSuperSampling) {
        gSuperSampling = configured;
        Cbuf_AddText("vid_restart\n");
    }

    *width = (int)(gAppState.Width * gSuperSampling);
    *height = (int)(gAppState.Height * gSuperSampling);
}

extern "C" void TBXR_visionOS_SetLayerRenderer(cp_layer_renderer_t renderer)
{
    // Auf Android füllt TBXR dieses Feld aus den OpenXR-Systemeigenschaften mit
    // dem Namen des Headsets. Es bleibt sonst NULL, und VR_Init reicht es
    // ungeprüft an Cvar_Get weiter — die Engine bricht dann mit
    // "Cvar_Get: NULL parameter" ab, lange nach der eigentlichen Ursache.
    //
    // JKXR vergleicht den Namen an drei Stellen gegen "meta" und "pico", um
    // herstellerspezifische Pfade zu schalten. "Apple Vision Pro" trifft
    // richtigerweise auf keinen davon zu.
    gAppState.OpenXRHMD = (char *)"Apple Vision Pro";

    if (!angle::resolve()) {
        ALOGE("GLES-Funktionen von ANGLE nicht auflösbar — kein Rendern möglich");
    }

    gLayerRenderer = renderer;
    id<MTLDevice> device = cp_layer_renderer_get_device(renderer);
    gQueue = [device newCommandQueue];
    gDisplay = eglGetCurrentDisplay();

    if (gDisplay == EGL_NO_DISPLAY) {
        ALOGE("Kein aktueller EGL-Display — ANGLE muss vor dieser Funktion "
              "initialisiert und auf diesem Thread aktiv sein");
    }
}

// ---------------------------------------------------------------------------
// Frame
// ---------------------------------------------------------------------------


/*
=================
TBXR_GetHMDOrientation

Gibt die Kopfpose an die Engine weiter. Gegenstück zur gleichnamigen Funktion in
android/TBXR_Common.cpp, die dort xrLocateSpace benutzt.

Bei uns liegt die Pose schon vor: FrameSetup fragt sie über ARKit ab und
übergibt sie dem Compositor für die Reprojektion. Bis hierher landete sie aber
NUR dort — die Engine bekam nie eine Blickrichtung, und ohne die rendert sie
nichts Sichtbares.

Die Matrix ist origin-from-anchor: Spalte 3 ist die Position, der obere linke
3x3-Block die Drehung.
=================
*/
static void TBXR_GetHMDOrientation(ar_device_anchor_t anchor)
{
    if (!anchor) return;

    simd_float4x4 m = ar_device_anchor_get_origin_from_anchor_transform(anchor);

    simd_quatf q = simd_quaternion(simd_matrix(m.columns[0].xyz,
                                               m.columns[1].xyz,
                                               m.columns[2].xyz));

    XrQuaternionf quat = { q.vector.x, q.vector.y, q.vector.z, q.vector.w };

    vec3_t rotation = {0, 0, 0};
    vec3_t hmdorientation = {0, 0, 0};
    QuatToYawPitchRoll(quat, rotation, hmdorientation);

    VR_SetHMDPosition(m.columns[3].x, m.columns[3].y, m.columns[3].z);
    VR_SetHMDOrientation(hmdorientation[0], hmdorientation[1], hmdorientation[2]);
}

/*
=================
TBXR_updateProjections

Auf Android füllt xrLocateViews hier gAppState.Views, aus denen später die
Projektionen entstehen. Bei uns lesen VR_GetVRProjection und
VR_GetFovTangentsForEye ihre Werte pro Auge direkt aus cp_view der aktuellen
Drawable — es gibt also nichts vorzuhalten.

Die Funktion bleibt trotzdem, damit FrameSetup dieselbe Abfolge hat wie die
Android-Fassung und ein späterer Abgleich nicht ins Leere greift.
=================
*/
void TBXR_updateProjections()
{
}

void TBXR_FrameSetup()
{
    TRACE("[Bild %d] FrameSetup", gFrameCounter);

    // Wächter gegen doppelten Einstieg — wie in der Android-Fassung.
    //
    // Die Engine ruft TBXR_FrameSetup von ZWEI Stellen: SCR_UpdateScreen()
    // in cl_scrn.cpp und Com_Frame() in common.cpp. Ohne diesen Wächter wird
    // ein zweiter Frame geholt, während der erste noch läuft, und
    // CompositorServices beendet den Prozess mit SIGABRT — ohne Meldung.
    //
    // Zurückgesetzt wird das Flag in TBXR_submitFrame.
    if (gAppState.FrameSetup) {
        return;
    }
    if (!gLayerRenderer) return;

    // Zustand abwarten statt blind rendern: der Compositor pausiert die Ebene,
    // wenn das Headset abgesetzt wird.
    cp_layer_renderer_state state = cp_layer_renderer_get_state(gLayerRenderer);
    if (state == cp_layer_renderer_state_paused) {
        cp_layer_renderer_wait_until_running(gLayerRenderer);
        return;
    }
    if (state == cp_layer_renderer_state_invalidated) {
        // Der Immersive Space wurde geschlossen (etwa per Krone). Ohne diese
        // Behandlung läuft die Engine-Schleife weiter und greift auf einen
        // ungültigen LayerRenderer zu — das endet mit SIGABRT und verfälscht
        // jeden Test, bei dem man aussteigt.
        ALOGV("LayerRenderer ungültig — Engine wird beendet");
        JKXR_visionOS_RequestShutdown();
        return;
    }

    gFrame = cp_layer_renderer_query_next_frame(gLayerRenderer);
    if (!gFrame) return;

    cp_frame_timing_t timing = cp_frame_predict_timing(gFrame);
    if (!timing) { gFrame = nullptr; return; }

    cp_frame_start_update(gFrame);
    cp_frame_end_update(gFrame);

    cp_time_wait_until(cp_frame_timing_get_optimal_input_time(timing));

    cp_frame_start_submission(gFrame);
    gDrawable = cp_frame_query_drawable(gFrame);
    if (!gDrawable) {
        cp_frame_end_submission(gFrame);
        gFrame = nullptr;
        return;
    }

    // Kopfpose zum trackableAnchorTime, nicht zur Präsentationszeit: Ersteres
    // ist der Zeitpunkt, für den der Compositor die Pose erwartet.
    // Einmalige Bestandsaufnahme der Drawable.
    //
    // Bis hierher war durchgehend ANGENOMMEN, dass das Layout "dedicated" ist
    // und jedes Auge eine eigene Textur hat. Bei "shared" gäbe es dagegen EINE
    // Textur mit beiden Augen nebeneinander — cp_drawable_get_color_texture(.., 1)
    // griffe dann ins Leere, und alles Gezeichnete landete nirgends. Genau das
    // würde das schwarze Bild erklären, auch bei reinem Metal.
    static bool described = false;
    if (!described) {
        described = true;
        const size_t views = cp_drawable_get_view_count(gDrawable);
        const size_t textures = cp_drawable_get_texture_count(gDrawable);
        ALOGV("[Drawable] %zu View(s), %zu Textur(en)", views, textures);
        for (size_t i = 0; i < textures; ++i) {
            id<MTLTexture> t = cp_drawable_get_color_texture(gDrawable, i);
            id<MTLTexture> d = cp_drawable_get_depth_texture(gDrawable, i);
            ALOGV("[Drawable]  Farbe %zu: %lux%lu, %lu Slice(s), Format %lu, usage 0x%lx",
                  i, (unsigned long)t.width, (unsigned long)t.height,
                  (unsigned long)t.arrayLength, (unsigned long)t.pixelFormat,
                  (unsigned long)t.usage);
            // printf-Format, kein %@: ALOGV ist kein NSLog.
            if (d) {
                ALOGV("[Drawable]  Tiefe %zu: %lux%lu, Format %lu, usage 0x%lx",
                      i, (unsigned long)d.width, (unsigned long)d.height,
                      (unsigned long)d.pixelFormat, (unsigned long)d.usage);
            } else {
                ALOGV("[Drawable]  Tiefe %zu: KEINE — visionOS verwirft Frames "
                      "ohne geschriebene Tiefe lautlos (siehe S4)", i);
            }
        }
    }

    cp_frame_timing_t actual = cp_drawable_get_frame_timing(gDrawable);
    ar_device_anchor_t anchor = ar_device_anchor_create();
    ar_world_tracking_provider_t tracking =
        (__bridge ar_world_tracking_provider_t)TBXR_visionOS_GetWorldTracking();
    if (tracking) {
        ar_device_anchor_query_status_t anchorStatus =
            ar_world_tracking_provider_query_device_anchor_at_timestamp(
            tracking,
            cp_time_to_cf_time_interval(cp_frame_timing_get_trackable_anchor_time(actual)),
            anchor);
        if (anchorStatus == ar_device_anchor_query_status_success) {
            // Anker IMMER setzen — nicht abschaltbar.
        //
        // Gemessen: ohne ihn präsentiert der Compositor überhaupt nichts, es
        // bleibt beim Passthrough. Er ist Pflicht, nicht Diagnose. Als cvar hat
        // er nur Schaden angerichtet: einmal auf 0 gesetzt, blieb er über die
        // Konfigurationsdatei erhalten und machte drei Läufe unbrauchbar.
        cp_drawable_set_device_anchor(gDrawable, anchor);
            // ... und dieselbe Pose an die Engine, sonst hat sie keine Blickrichtung.
            TBXR_GetHMDOrientation(anchor);
        gHeadTransform = ar_device_anchor_get_origin_from_anchor_transform(anchor);
        gHeadValid = true;
        } else if (gFrameCounter < 3) {
            // Ein frisch erzeugter, aber nicht befüllter Anchor darf nicht an
            // den Compositor gehen. Ohne Statusprüfung sah er bisher wie eine
            // echte (Identitäts-)Pose aus und machte die Diagnose unbrauchbar.
            ALOGE("[Bild %d] keine gültige Kopfpose", gFrameCounter);
        }
    }

    gCommandBuffer = [gQueue commandBuffer];
    gAppState.FrameState.predictedDisplayTime =
        ToXrTime(cp_time_to_cf_time_interval(
            cp_frame_timing_get_presentation_time(actual)));


    // Dieselbe Abfolge wie am Ende von Androids TBXR_FrameSetup. Ohne diese
    // vier Aufrufe bekommt die Engine weder Projektionen noch Eingaben — sie
    // fehlten in der ersten Fassung dieser Datei vollständig.
    VR_FrameSetup();
    TBXR_updateProjections();
    VR_HandleControllerInput();
    TBXR_ProcessHaptics();
    gAppState.FrameSetup = true;
}

void TBXR_prepareEyeBuffer(int eye)
{
    gCurrentEye = eye;
    TRACE("[Bild %d] prepareEyeBuffer Auge %d", gFrameCounter, eye);
    if (!gDrawable) return;

    id<MTLTexture> color = cp_drawable_get_color_texture(gDrawable, eye);
    id<MTLTexture> depth = cp_drawable_get_depth_texture(gDrawable, eye);

    // The compositor imports below bypass gl4es and therefore also bypass its
    // state cache.  Preserve the physical ANGLE texture binding; otherwise
    // gl4es may later skip a logically redundant bind while ANGLE still has
    // the imported depth texture bound.  Cinematic glTexSubImage2D calls then
    // target that immutable external texture and fail with GL_INVALID_OPERATION.
    GLint previousActiveTexture = GL_TEXTURE0;
    GLint previousTexture2D = 0;
    GLint previousDepthFunc = GL_LESS;
    GLboolean previousDepthMask = GL_TRUE;
    const GLboolean depthWasEnabled = angle::IsEnabled(GL_DEPTH_TEST);
    angle::GetIntegerv(GL_ACTIVE_TEXTURE, &previousActiveTexture);
    angle::GetIntegerv(GL_TEXTURE_BINDING_2D, &previousTexture2D);
    angle::GetIntegerv(GL_DEPTH_FUNC, &previousDepthFunc);
    angle::GetBooleanv(GL_DEPTH_WRITEMASK, &previousDepthMask);
    const auto restoreTextureBinding = [&]() {
        angle::ActiveTexture((GLenum)previousActiveTexture);
        angle::BindTexture(GL_TEXTURE_2D, (GLuint)previousTexture2D);
    };
    const auto restoreDepthState = [&]() {
        if (depthWasEnabled) angle::Enable(GL_DEPTH_TEST);
        else angle::Disable(GL_DEPTH_TEST);
        angle::DepthFunc((GLenum)previousDepthFunc);
        angle::DepthMask(previousDepthMask);
    };

    EyeImport &import = gEyes[eye];
    if (!importTexture(color, 0, &import.colorTexture, &import.colorImage, "Farbe")) {
        restoreTextureBinding();
        restoreDepthState();
        return;
    }

    // Die Tiefe MUSS mit: visionOS nutzt sie für die Reprojektion und verwirft
    // sonst den kompletten Frame — lautlos, ohne Fehlermeldung. Das war der
    // teuerste Fehler in spikes/s4-angle.
    importTexture(depth, 0, &import.depthTexture, &import.depthImage, "Tiefe");

    if (!gFramebuffer) angle::GenFramebuffers(1, &gFramebuffer);
    angle::BindFramebuffer(GL_FRAMEBUFFER, gFramebuffer);
    angle::FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_2D, import.colorTexture, 0);
    if (import.depthTexture) {
        angle::FramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                               GL_TEXTURE_2D, import.depthTexture, 0);
    }

    GLenum status = angle::CheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        ALOGE("Framebuffer unvollständig für Auge %d: 0x%04x", eye, status);
        restoreTextureBinding();
        restoreDepthState();
        return;
    }

    // Der Viewport steht bei aktiver Foveation in Screen-Koordinaten, die
    // Textur ist physisch kleiner. Die Rate Map bildet dazwischen ab; ohne den
    // ANGLE-Patch aus spikes/s4-angle bliebe nur eine Ecke des Bildes übrig.
    cp_view_t view = cp_drawable_get_view(gDrawable, eye);
    cp_view_texture_map_t map = cp_view_get_view_texture_map(view);
    MTLViewport viewport = cp_view_texture_map_get_viewport(map);
    angle::Viewport((GLint)viewport.originX, (GLint)viewport.originY,
               (GLsizei)viewport.width, (GLsizei)viewport.height);

    ANGLESetDrawFramebufferRateMapMTL(
        (__bridge const void *)cp_drawable_get_rasterization_rate_map(gDrawable, eye));


    // Reversed-Z wie vom Compositor erwartet. visionOS behandelt Pixel, deren
    // Tiefe exakt dem Clear-Wert 0 entspricht, als nicht belegt. Das betrifft
    // insbesondere Menüs, HUD und Himmel, die selbst keine Tiefe schreiben.
    // Deshalb bekommt die komplette Fläche zunächst eine minimale, aber
    // gültige Hintergrundtiefe. Näher liegende 3D-Geometrie überschreibt sie.
    angle::Enable(GL_DEPTH_TEST);
    angle::DepthFunc(GL_GREATER);
    angle::DepthMask(GL_TRUE);
    angle::ClearDepthf(1.0e-4f);

    const GLboolean scissorWasEnabled = angle::IsEnabled(GL_SCISSOR_TEST);
    if (scissorWasEnabled) angle::Disable(GL_SCISSOR_TEST);
    angle::Clear(GL_DEPTH_BUFFER_BIT);

    // CompositorServices wertet nur tatsächlich von Geometrie beschriebene
    // Tiefe als sichtbaren Inhalt. Ein Clear allein genügt im ANGLE-Pfad nicht.
    drawBackgroundDepth();

    // Expliziter Import-/FBO-Test: Farbe und Tiefe werden ausschließlich über
    // ANGLE geschrieben. Der Client überspringt dabei den gesamten Renderer.
    if (forceAngleClear()) {
        angle::ClearColor(eye == 0 ? 0.0f : 0.0f,
                          eye == 0 ? 0.45f : 0.1f,
                          eye == 0 ? 0.1f : 0.55f, 1.0f);
        angle::Clear(GL_COLOR_BUFFER_BIT);
    }
    if (scissorWasEnabled) angle::Enable(GL_SCISSOR_TEST);
    restoreTextureBinding();
    restoreDepthState();

    // Asymmetrisches Sichtfeld ausgleichen — dieselben zwei Zeilen wie am Ende
    // von TBXR_prepareEyeBuffer in der Android- und der Windows-Fassung.
    //
    // Sie fehlten hier bisher vollständig. Der Renderer verschiebt damit 2D-
    // Inhalte (HUD, Menü, Video) pro Auge; siehe tr_cmds.cpp:117 und
    // cg_drawtools.cpp:44. Ohne sie zeichnet er in beide Augen exakt dasselbe
    // Bild, obwohl jede View der Vision Pro ein eigenes, nicht zentriertes
    // Frustum hat — die Bilder laufen dann auseinander (links zu weit links,
    // rechts zu weit rechts), und die Augen müssen nach außen schielen.
    //
    // Der Kommentar im Android-Original beschreibt genau diesen Fall: bei einem
    // symmetrischen Sichtfeld (Pico) steht hier 0, bei einem asymmetrischen
    // (Quest, und ebenso Vision Pro) wäre das HUD sonst stark verschoben.
    //
    // OpenXR liefert dort Winkel, unsere Projektionsmatrix Tangenten — daher
    // atanf. Die Vorzeichen stimmen überein: tanLeft und tanDown sind negativ.
    {
        float tanLeft, tanRight, tanUp, tanDown;
        if (VR_GetFovTangentsForEye(eye, &tanLeft, &tanRight, &tanUp, &tanDown)) {
            vr.off_center_fov_x = -(atanf(tanLeft) + atanf(tanRight)) / 2.0f;
            vr.off_center_fov_y = -(atanf(tanUp) + atanf(tanDown)) / 2.0f;
        }
    }
}

void TBXR_finishEyeBuffer(int eye)
{
    TRACE("[Bild %d] finishEyeBuffer Auge %d", gFrameCounter, eye);
    if (!gDrawable) return;

    // gl4es reports its logical default framebuffer as 0.  Query ANGLE
    // directly here, after the engine rendered, to verify that the physical
    // binding still points at the imported compositor framebuffer.
    static int framebufferDiagnostics = 0;
    if (eye == 0 && framebufferDiagnostics < 8) {
        GLint actualFramebuffer = -1;
        angle::GetIntegerv(GL_FRAMEBUFFER_BINDING, &actualFramebuffer);
        const GLenum error = angle::GetError();
        ALOGV("[ANGLE FBO] frame=%d actual=%d expected=%u error=0x%04x",
              gFrameCounter, actualFramebuffer, gFramebuffer, error);
        framebufferDiagnostics++;
    }

    // glFinish, nicht glFlush.
    //
    // ANGLE rendert auf seiner EIGENEN Metal-Warteschlange; cp_drawable_encode_present
    // läuft auf gQueue. Zwischen zwei Warteschlangen garantiert Metal keine
    // Reihenfolge. glFlush startet ANGLEs Arbeit nur — der Compositor kann die
    // Textur also präsentieren, bevor etwas darin steht.
    //
    // S4 hatte dieselbe Aufteilung und funktionierte, aber dort wurde ein
    // einzelnes Dreieck gezeichnet; das Rennen ging zufällig aus.
    //
    // glFinish blockiert bis zur Fertigstellung. Das kostet Parallelität und
    // ist nicht die endgültige Lösung — die wäre ein MTLSharedEvent zwischen
    // beiden Warteschlangen. Erst messen, ob die Diagnose überhaupt stimmt.
    angle::Finish();

    EyeImport &import = gEyes[eye];
    // Rate Map wieder abmelden, sonst wirkt sie im nächsten Pass weiter.
    ANGLESetDrawFramebufferRateMapMTL(nullptr);
    angle::BindFramebuffer(GL_FRAMEBUFFER, 0);

    if (import.colorTexture) {
        angle::DeleteTextures(1, &import.colorTexture);
        eglDestroyImage_(gDisplay, import.colorImage);
        import.colorTexture = 0;
        import.colorImage = EGL_NO_IMAGE_KHR;
    }
    if (import.depthTexture) {
        angle::DeleteTextures(1, &import.depthTexture);
        eglDestroyImage_(gDisplay, import.depthImage);
        import.depthTexture = 0;
        import.depthImage = EGL_NO_IMAGE_KHR;
    }
}

void TBXR_copyEyeBuffer(int sourceEye, int destinationEye)
{
    if (!gDrawable || !gCommandBuffer || sourceEye == destinationEye) return;

    id<MTLTexture> sourceColor = cp_drawable_get_color_texture(gDrawable, sourceEye);
    id<MTLTexture> destinationColor =
        cp_drawable_get_color_texture(gDrawable, destinationEye);
    id<MTLTexture> sourceDepth = cp_drawable_get_depth_texture(gDrawable, sourceEye);
    id<MTLTexture> destinationDepth =
        cp_drawable_get_depth_texture(gDrawable, destinationEye);
    if (!sourceColor || !destinationColor || !sourceDepth || !destinationDepth) {
        ALOGE("Screen-Layer konnte nicht von Auge %d nach %d kopiert werden",
              sourceEye, destinationEye);
        return;
    }

    static bool compareFirstCopy = true;
    id<MTLDevice> device = cp_layer_renderer_get_device(gLayerRenderer);
    id<MTLBuffer> sourceReadback = nil;
    id<MTLBuffer> destinationReadback = nil;
    NSUInteger readbackBytesPerRow = 0;
    if (compareFirstCopy && sourceColor.pixelFormat == MTLPixelFormatRGBA16Float) {
        compareFirstCopy = false;
        NSUInteger alignment =
            [device minimumLinearTextureAlignmentForPixelFormat:sourceColor.pixelFormat];
        NSUInteger rawBytesPerRow = sourceColor.width * 8;
        readbackBytesPerRow =
            ((rawBytesPerRow + alignment - 1) / alignment) * alignment;
        NSUInteger length = readbackBytesPerRow * sourceColor.height;
        sourceReadback = [device newBufferWithLength:length
                                             options:MTLResourceStorageModeShared];
        destinationReadback = [device newBufferWithLength:length
                                                  options:MTLResourceStorageModeShared];
    }

    id<MTLBlitCommandEncoder> blit = [gCommandBuffer blitCommandEncoder];
    MTLSize colorSize = MTLSizeMake(sourceColor.width, sourceColor.height, 1);
    [blit copyFromTexture:sourceColor sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:colorSize
                toTexture:destinationColor destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];

    MTLSize depthSize = MTLSizeMake(sourceDepth.width, sourceDepth.height, 1);
    [blit copyFromTexture:sourceDepth sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:depthSize
                toTexture:destinationDepth destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];

    if (sourceReadback && destinationReadback) {
        MTLSize readbackSize = MTLSizeMake(sourceColor.width, sourceColor.height, 1);
        [blit copyFromTexture:sourceColor sourceSlice:0 sourceLevel:0
                sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:readbackSize
                   toBuffer:sourceReadback destinationOffset:0
          destinationBytesPerRow:readbackBytesPerRow
        destinationBytesPerImage:readbackBytesPerRow * sourceColor.height];
        [blit copyFromTexture:destinationColor sourceSlice:0 sourceLevel:0
                sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:readbackSize
                   toBuffer:destinationReadback destinationOffset:0
          destinationBytesPerRow:readbackBytesPerRow
        destinationBytesPerImage:readbackBytesPerRow * destinationColor.height];
    }
    [blit endEncoding];

    if (sourceReadback && destinationReadback) {
        const NSUInteger length = readbackBytesPerRow * sourceColor.height;
        [gCommandBuffer addCompletedHandler:^(id<MTLCommandBuffer>) {
            const bool identical =
                memcmp(sourceReadback.contents, destinationReadback.contents, length) == 0;
            ALOGV("[Stereo-2D] Augentexturen nach Blit: %s (%lu Bytes)",
                  identical ? "bytegleich" : "VERSCHIEDEN", (unsigned long)length);
        }];
    }
}

void TBXR_submitFrame()
{
    TRACE("[Bild %d] submitFrame", gFrameCounter);
    if (!gDrawable || !gFrame) return;

    // --- Nur zur Fehlersuche: mit reinem Metal füllen ---------------------
    //
    // Umgeht ANGLE, gl4es und den gesamten GL-Pfad vollständig. Bleibt auch
    // DIESES Bild schwarz, liegt der Fehler in unserem Frame-Ablauf oder in der
    // Präsentation — nicht im Renderer. Erscheint es, ist umgekehrt bewiesen,
    // dass CompositorServices bei uns funktioniert und nur ANGLEs Ausgabe nicht
    // ankommt.
    //
    // loadAction .clear schreibt die Farbe ohne jeden Zeichenaufruf; der
    // Encoder wird sofort wieder beendet. Die Tiefe darf dabei nicht auf dem
    // transparenten Compositor-Clear-Wert 0 bleiben.
    if (forceMetalClear()) {
        const size_t views = cp_drawable_get_view_count(gDrawable);
        for (size_t v = 0; v < views; ++v) {
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = cp_drawable_get_color_texture(gDrawable, v);
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor =
                MTLClearColorMake(v == 0 ? 0.4 : 0.0, 0.15, v == 0 ? 0.0 : 0.4, 1.0);

            // Die Tiefe MUSS mitgeschrieben werden: visionOS nutzt sie für die
            // Reprojektion und verwirft den Frame sonst lautlos. Das war der
            // teuerste Fehler in S4.
            id<MTLTexture> depth = cp_drawable_get_depth_texture(gDrawable, v);
            if (depth) {
                pass.depthAttachment.texture = depth;
                pass.depthAttachment.loadAction = MTLLoadActionClear;
                pass.depthAttachment.storeAction = MTLStoreActionStore;
                pass.depthAttachment.clearDepth = 1.0e-4; // sichtbarer Fernwert bei Reversed-Z
            }

            id<MTLRenderCommandEncoder> enc =
                [gCommandBuffer renderCommandEncoderWithDescriptor:pass];
            [enc endEncoding];
        }
    }

    cp_drawable_encode_present(gDrawable, gCommandBuffer);

    if (gFrameCounter < 3) {
        cp_time_t deadline = cp_frame_timing_get_rendering_deadline(
            cp_drawable_get_frame_timing(gDrawable));
        const double slackMs = (cp_time_to_cf_time_interval(deadline)
                              - CACurrentMediaTime()) * 1000.0;
        ALOGV("[Bild %d] %.2f ms bis zur Rendering-Deadline",
              gFrameCounter, slackMs);
    }
    [gCommandBuffer commit];

    // Metal selbst fragen, statt weiter zu vermuten.
    //
    // Alle Eigenschaften der Drawable sind nachweislich richtig: 2 Views, 2
    // Farbtexturen (rgba16Float, Renderziel), 2 Tiefentexturen (depth32Float).
    // Trotzdem erscheint nichts, und kein Aufruf meldet einen Fehler. Bleibt
    // die Frage, ob Metal den Befehlspuffer überhaupt annimmt.
    //
    // Nur für die ersten Bilder: waitUntilCompleted wirft die Parallelität weg.
    if (gFrameCounter < 3) {
        [gCommandBuffer waitUntilCompleted];
        cp_time_t completedDeadline = cp_frame_timing_get_rendering_deadline(
            cp_drawable_get_frame_timing(gDrawable));
        const double completedSlackMs =
            (cp_time_to_cf_time_interval(completedDeadline)
             - CACurrentMediaTime()) * 1000.0;
        ALOGV("[Bild %d] CommandBuffer Status %ld%s%s",
              gFrameCounter,
              (long)gCommandBuffer.status,
              gCommandBuffer.error ? " FEHLER: " : "",
              gCommandBuffer.error
                  ? [[gCommandBuffer.error localizedDescription] UTF8String] : "");
        ALOGV("[Bild %d] GPU %.2f ms vor Deadline fertig",
              gFrameCounter, completedSlackMs);
    }
    cp_frame_end_submission(gFrame);

    gDrawable = nullptr;
    gFrame = nullptr;
    gCommandBuffer = nil;
    TRACE("[Bild %d] submitFrame fertig", gFrameCounter);
    ++gFrameCounter;
    gAppState.FrameSetup = false;
}

int TBXR_GetRefresh()
{
    // Apple Vision Pro rendert mit 90 Hz. Eine Abfrage wie die
    // FB_display_refresh_rate-Extension von OpenXR gibt es hier nicht.
    return 90;
}

XrInstance TBXR_GetXrInstance()
{
    // Es gibt keine OpenXR-Laufzeit. Der neutrale Code reicht das Handle nur an
    // unsere eigenen Action-System-Funktionen weiter, die es ignorieren.
    return gAppState.Instance;
}

// ---------------------------------------------------------------------------
// Projektion
// ---------------------------------------------------------------------------

bool VR_GetVRProjection(int eye, float zNear, float zFar,
                        float zZoomX, float zZoomY, float *projection)
{
    if (!gDrawable) return false;

    // Der Compositor liefert die Projektion passend zur aktuellen Kopfpose und
    // Linsengeometrie — sie selbst aus FOV-Winkeln aufzubauen wäre ungenauer.
    simd_float4x4 matrix = cp_drawable_compute_projection(
        gDrawable, cp_axis_direction_convention_right_up_back, eye);

    // Zoom (Fernglas, Scharfschützenmodus) skaliert die beiden ersten Spalten.
    matrix.columns[0] *= zZoomX;
    matrix.columns[1] *= zZoomY;

    memcpy(projection, &matrix, sizeof(float) * 16);
    return true;
}

bool VR_GetFovTangentsForEye(int eye, float *tanLeft, float *tanRight,
                             float *tanUp, float *tanDown)
{
    if (!gDrawable) return false;

    simd_float4x4 p = cp_drawable_compute_projection(
        gDrawable, cp_axis_direction_convention_right_up_back, eye);

    // Aus einer Projektionsmatrix zurückgerechnet: die Tangenten stecken in den
    // Elementen [0][0]/[0][2] beziehungsweise [1][1]/[1][2].
    const float sx = p.columns[0][0], ox = p.columns[2][0];
    const float sy = p.columns[1][1], oy = p.columns[2][1];
    *tanLeft  = (-1.0f - ox) / sx;
    *tanRight = ( 1.0f - ox) / sx;
    *tanDown  = (-1.0f - oy) / sy;
    *tanUp    = ( 1.0f - oy) / sy;
    return true;
}

float VR_GetEyeStereoSeparation(int eye)
{
    if (!gDrawable) return 0.0f;

    // Augenabstand aus den beiden Ansichtstransformationen. visionOS kennt den
    // tatsächlichen Wert des Trägers, statt einen Mittelwert anzunehmen.
    cp_view_t left  = cp_drawable_get_view(gDrawable, 0);
    cp_view_t right = cp_drawable_get_view(gDrawable, 1);
    simd_float4x4 lt = cp_view_get_transform(left);
    simd_float4x4 rt = cp_view_get_transform(right);
    float separation = simd_distance(lt.columns[3].xyz, rt.columns[3].xyz);
    return (eye == 0) ? -separation * 0.5f : separation * 0.5f;
}

// ---------------------------------------------------------------------------
// Noch offen
// ---------------------------------------------------------------------------

void VR_HapticEvent(const char *event, int position, int flags,
                    int intensity, float angle, float yHeight)
{
    // Braucht das Action-System auf PSVR2-Sense-Controllern; siehe
    // PORT-visionOS.md. Bis dahin absichtlich wirkungslos statt falsch.
    (void)event; (void)position; (void)flags;
    (void)intensity; (void)angle; (void)yHeight;
}

void VR_HapticEndFrame() {}

/// Vom Action-System aufgerufen. Sense-Controller können Vibration; die
/// adaptiven Trigger und die Präzisionshaptik der PlayStation stehen auf
/// visionOS nicht zur Verfügung.
extern "C" void TBXR_visionOS_Vibrate(int hand, float amplitude, float seconds)
{
    (void)hand; (void)amplitude; (void)seconds;
    // Umsetzung über GCDeviceHaptics, sobald die Controller angebunden sind.
}
// VR_GetMove steht jetzt in JKXR_visionOS.mm — dort die echte Bewegungslogik
// aus android/JKXR_SurfaceView.cpp statt des Platzhalters, der hier stand.


void VR_BeginStereoReplayCapture() {}
void VR_CancelStereoReplayCapture() {}
void VR_ReplayStereoFrame() {}

// ---------------------------------------------------------------------------
// Quaternionen- und Matrizenmathematik
//
// Wörtlich aus android/TBXR_Common.cpp (Zeilen 789–994) übernommen. Der Code
// ist plattformneutral; er steht dort nur deshalb in der Plattformdatei, weil
// JKXR ihn nie in einen gemeinsamen Header gezogen hat.
//
// Nicht anpassen: die Achsenvertauschung in QuatToYawPitchRoll (VR-Raum nach
// Quake-Raum) muss auf allen Plattformen identisch sein, sonst zielt die
// Waffe woanders hin als die Hand zeigt.
// ---------------------------------------------------------------------------

ovrMatrix4f ovrMatrix4f_CreateFromQuaternion(const XrQuaternionf* q) {
	const float ww = q->w * q->w;
	const float xx = q->x * q->x;
	const float yy = q->y * q->y;
	const float zz = q->z * q->z;

	ovrMatrix4f out;
	out.M[0][0] = ww + xx - yy - zz;
	out.M[0][1] = 2 * (q->x * q->y - q->w * q->z);
	out.M[0][2] = 2 * (q->x * q->z + q->w * q->y);
	out.M[0][3] = 0;

	out.M[1][0] = 2 * (q->x * q->y + q->w * q->z);
	out.M[1][1] = ww - xx + yy - zz;
	out.M[1][2] = 2 * (q->y * q->z - q->w * q->x);
	out.M[1][3] = 0;

	out.M[2][0] = 2 * (q->x * q->z - q->w * q->y);
	out.M[2][1] = 2 * (q->y * q->z + q->w * q->x);
	out.M[2][2] = ww - xx - yy + zz;
	out.M[2][3] = 0;

	out.M[3][0] = 0;
	out.M[3][1] = 0;
	out.M[3][2] = 0;
	out.M[3][3] = 1;
	return out;
}


/// Use left-multiplication to accumulate transformations.
ovrMatrix4f ovrMatrix4f_Multiply(const ovrMatrix4f* a, const ovrMatrix4f* b) {
	ovrMatrix4f out;
	out.M[0][0] = a->M[0][0] * b->M[0][0] + a->M[0][1] * b->M[1][0] + a->M[0][2] * b->M[2][0] +
				  a->M[0][3] * b->M[3][0];
	out.M[1][0] = a->M[1][0] * b->M[0][0] + a->M[1][1] * b->M[1][0] + a->M[1][2] * b->M[2][0] +
				  a->M[1][3] * b->M[3][0];
	out.M[2][0] = a->M[2][0] * b->M[0][0] + a->M[2][1] * b->M[1][0] + a->M[2][2] * b->M[2][0] +
				  a->M[2][3] * b->M[3][0];
	out.M[3][0] = a->M[3][0] * b->M[0][0] + a->M[3][1] * b->M[1][0] + a->M[3][2] * b->M[2][0] +
				  a->M[3][3] * b->M[3][0];

	out.M[0][1] = a->M[0][0] * b->M[0][1] + a->M[0][1] * b->M[1][1] + a->M[0][2] * b->M[2][1] +
				  a->M[0][3] * b->M[3][1];
	out.M[1][1] = a->M[1][0] * b->M[0][1] + a->M[1][1] * b->M[1][1] + a->M[1][2] * b->M[2][1] +
				  a->M[1][3] * b->M[3][1];
	out.M[2][1] = a->M[2][0] * b->M[0][1] + a->M[2][1] * b->M[1][1] + a->M[2][2] * b->M[2][1] +
				  a->M[2][3] * b->M[3][1];
	out.M[3][1] = a->M[3][0] * b->M[0][1] + a->M[3][1] * b->M[1][1] + a->M[3][2] * b->M[2][1] +
				  a->M[3][3] * b->M[3][1];

	out.M[0][2] = a->M[0][0] * b->M[0][2] + a->M[0][1] * b->M[1][2] + a->M[0][2] * b->M[2][2] +
				  a->M[0][3] * b->M[3][2];
	out.M[1][2] = a->M[1][0] * b->M[0][2] + a->M[1][1] * b->M[1][2] + a->M[1][2] * b->M[2][2] +
				  a->M[1][3] * b->M[3][2];
	out.M[2][2] = a->M[2][0] * b->M[0][2] + a->M[2][1] * b->M[1][2] + a->M[2][2] * b->M[2][2] +
				  a->M[2][3] * b->M[3][2];
	out.M[3][2] = a->M[3][0] * b->M[0][2] + a->M[3][1] * b->M[1][2] + a->M[3][2] * b->M[2][2] +
				  a->M[3][3] * b->M[3][2];

	out.M[0][3] = a->M[0][0] * b->M[0][3] + a->M[0][1] * b->M[1][3] + a->M[0][2] * b->M[2][3] +
				  a->M[0][3] * b->M[3][3];
	out.M[1][3] = a->M[1][0] * b->M[0][3] + a->M[1][1] * b->M[1][3] + a->M[1][2] * b->M[2][3] +
				  a->M[1][3] * b->M[3][3];
	out.M[2][3] = a->M[2][0] * b->M[0][3] + a->M[2][1] * b->M[1][3] + a->M[2][2] * b->M[2][3] +
				  a->M[2][3] * b->M[3][3];
	out.M[3][3] = a->M[3][0] * b->M[0][3] + a->M[3][1] * b->M[1][3] + a->M[3][2] * b->M[2][3] +
				  a->M[3][3] * b->M[3][3];
	return out;
}

ovrMatrix4f ovrMatrix4f_CreateRotation(const float radiansX, const float radiansY, const float radiansZ) {
	const float sinX = sinf(radiansX);
	const float cosX = cosf(radiansX);
	const ovrMatrix4f rotationX = {
			{{1, 0, 0, 0}, {0, cosX, -sinX, 0}, {0, sinX, cosX, 0}, {0, 0, 0, 1}}};
	const float sinY = sinf(radiansY);
	const float cosY = cosf(radiansY);
	const ovrMatrix4f rotationY = {
			{{cosY, 0, sinY, 0}, {0, 1, 0, 0}, {-sinY, 0, cosY, 0}, {0, 0, 0, 1}}};
	const float sinZ = sinf(radiansZ);
	const float cosZ = cosf(radiansZ);
	const ovrMatrix4f rotationZ = {
			{{cosZ, -sinZ, 0, 0}, {sinZ, cosZ, 0, 0}, {0, 0, 1, 0}, {0, 0, 0, 1}}};
	const ovrMatrix4f rotationXY = ovrMatrix4f_Multiply(&rotationY, &rotationX);
	return ovrMatrix4f_Multiply(&rotationZ, &rotationXY);
}

XrVector4f XrVector4f_MultiplyMatrix4f(const ovrMatrix4f* a, const XrVector4f* v) {
	XrVector4f out;
	out.x = a->M[0][0] * v->x + a->M[0][1] * v->y + a->M[0][2] * v->z + a->M[0][3] * v->w;
	out.y = a->M[1][0] * v->x + a->M[1][1] * v->y + a->M[1][2] * v->z + a->M[1][3] * v->w;
	out.z = a->M[2][0] * v->x + a->M[2][1] * v->y + a->M[2][2] * v->z + a->M[2][3] * v->w;
	out.w = a->M[3][0] * v->x + a->M[3][1] * v->y + a->M[3][2] * v->z + a->M[3][3] * v->w;
	return out;
}

#ifndef EPSILON
#define EPSILON 0.001f
#endif

static XrVector3f normalizeVec(XrVector3f vec) {
    //NOTE: leave w-component untouched
    //@@const float EPSILON = 0.000001f;
    float xxyyzz = vec.x*vec.x + vec.y*vec.y + vec.z*vec.z;
    //@@if(xxyyzz < EPSILON)
    //@@    return *this; // do nothing if it is zero vector

    //float invLength = invSqrt(xxyyzz);
	XrVector3f result;
    float invLength = 1.0f / sqrtf(xxyyzz);
    result.x = vec.x * invLength;
    result.y = vec.y * invLength;
    result.z = vec.z * invLength;
    return result;
}

void NormalizeAngles(vec3_t angles)
{
	while (angles[0] >= 90) angles[0] -= 180;
	while (angles[1] >= 180) angles[1] -= 360;
	while (angles[2] >= 180) angles[2] -= 360;
	while (angles[0] < -90) angles[0] += 180;
	while (angles[1] < -180) angles[1] += 360;
	while (angles[2] < -180) angles[2] += 360;
}

void GetAnglesFromVectors(const XrVector3f forward, const XrVector3f right, const XrVector3f up, vec3_t angles)
{
	float sr, sp, sy, cr, cp, cy;

	sp = -forward.z;

	float cp_x_cy = forward.x;
	float cp_x_sy = forward.y;
	float cp_x_sr = -right.z;
	float cp_x_cr = up.z;

	float yaw = atan2(cp_x_sy, cp_x_cy);
	float roll = atan2(cp_x_sr, cp_x_cr);

	cy = cos(yaw);
	sy = sin(yaw);
	cr = cos(roll);
	sr = sin(roll);

	if (fabs(cy) > EPSILON)
	{
	cp = cp_x_cy / cy;
	}
	else if (fabs(sy) > EPSILON)
	{
	cp = cp_x_sy / sy;
	}
	else if (fabs(sr) > EPSILON)
	{
	cp = cp_x_sr / sr;
	}
	else if (fabs(cr) > EPSILON)
	{
	cp = cp_x_cr / cr;
	}
	else
	{
	cp = cos(asin(sp));
	}

	float pitch = atan2(sp, cp);

	angles[0] = pitch / (M_PI*2.f / 360.f);
	angles[1] = yaw / (M_PI*2.f / 360.f);
	angles[2] = roll / (M_PI*2.f / 360.f);

	NormalizeAngles(angles);
}


void QuatToYawPitchRoll(XrQuaternionf q, vec3_t rotation, vec3_t out) {

	ovrMatrix4f mat = ovrMatrix4f_CreateFromQuaternion( &q );

	if (rotation[0] != 0.0f || rotation[1] != 0.0f || rotation[2] != 0.0f)
	{
		ovrMatrix4f rot = ovrMatrix4f_CreateRotation(DEG2RAD(rotation[0]), DEG2RAD(rotation[1]), DEG2RAD(rotation[2]));
		mat = ovrMatrix4f_Multiply(&mat, &rot);
	}

	XrVector4f v1 = {0, 0, -1, 0};
	XrVector4f v2 = {1, 0, 0, 0};
	XrVector4f v3 = {0, 1, 0, 0};

	XrVector4f forwardInVRSpace = XrVector4f_MultiplyMatrix4f(&mat, &v1);
	XrVector4f rightInVRSpace = XrVector4f_MultiplyMatrix4f(&mat, &v2);
	XrVector4f upInVRSpace = XrVector4f_MultiplyMatrix4f(&mat, &v3);

	XrVector3f forward = {-forwardInVRSpace.z, -forwardInVRSpace.x, forwardInVRSpace.y};
	XrVector3f right = {-rightInVRSpace.z, -rightInVRSpace.x, rightInVRSpace.y};
	XrVector3f up = {-upInVRSpace.z, -upInVRSpace.x, upInVRSpace.y};

	XrVector3f forwardNormal = normalizeVec(forward);
	XrVector3f rightNormal = normalizeVec(right);
	XrVector3f upNormal = normalizeVec(up);

	GetAnglesFromVectors(forwardNormal, rightNormal, upNormal, out);
}


// ---------------------------------------------------------------------------
// 2D auf einer virtuellen Wand
//
// Android übergibt 2D-Inhalt als Quad-Layer, das der Compositor in 5,5 m
// Entfernung im Raum platziert und für beide Augen selbst ableitet. Auf
// visionOS gibt es kein Quad-Layer.
//
// Statt den Inhalt orthographisch flach in beide Augenpuffer zu zeichnen —
// was ihn ins Unendliche legt und die Bilder auseinanderlaufen lässt — spannen
// wir eine Wand in echter Entfernung auf und zeichnen sie mit der ECHTEN
// Projektion des jeweiligen Auges. Damit ergibt sich die Disparität aus der
// Geometrie statt aus einem Stellwert wie cg_hudStereo.
//
// Kopfgekoppelt, nicht weltfest: die Wand folgt dem Blick. Android rastet sie
// dagegen auf eine Position ein (hmdorientation_snap). Das wäre der nächste
// Schritt, sobald die Geometrie stimmt.
// ---------------------------------------------------------------------------

extern "C" bool VR_GetScreenWall(int eye, float *projection16, float *modelview16)
{
    if (!gDrawable) return false;
    if (eye < 0 || eye > 1) eye = 0;

    // Entfernung und Breite der Wand in Metern, zur Laufzeit einstellbar.
    // TESTWEISE FEST: 6 m Entfernung, 6 m breit.
    //
    // Die Frage ist nicht, ob die Werte stimmen, sondern ob diese Matrizen
    // überhaupt beim Zeichnen ankommen. Bleibt das Video bei diesen Werten
    // unverändert groß und an derselben Stelle, wird die Matrix unterwegs
    // überschrieben oder ignoriert — dann suche ich im Renderpfad weiter und
    // nicht in der Rechnung.
    float distance = 2.0f;
    float width = 2.4f;
    const float height = width * (480.0f / 640.0f);

    // Projektion des Auges, unverändert übernommen.
    simd_float4x4 proj = cp_drawable_compute_projection(
        gDrawable, cp_axis_direction_convention_right_up_back, eye);
    memcpy(projection16, &proj, sizeof(float) * 16);

    // Wand einmal einrasten, dann im Raum stehen lassen.
    //
    // Ohne das dreht sich das Bild mit dem Kopf mit — es klebt am Blick statt
    // in der Welt zu hängen. Android macht dasselbe über hmdposition_snap und
    // hmdorientation_snap.
    //
    // Eingerastet wird die aktuelle Kopfposition plus die auf die Horizontale
    // projizierte Blickrichtung: die Wand steht damit senkrecht, auch wenn man
    // beim Einrasten nach oben oder unten geschaut hat.
    if (!gWallSnapped && gHeadValid) {
        simd_float3 headPos = gHeadTransform.columns[3].xyz;
        simd_float3 forward = -gHeadTransform.columns[2].xyz;
        forward.y = 0.0f;
        if (simd_length(forward) < 1e-4f) {
            forward = (simd_float3){0.0f, 0.0f, -1.0f};   // senkrecht geschaut
        }
        forward = simd_normalize(forward);

        const simd_float3 up = (simd_float3){0.0f, 1.0f, 0.0f};
        const simd_float3 right = simd_normalize(simd_cross(up, -forward));

        // TEST: Wand im Gerätekoordinatensystem, 2 m geradeaus.
        gWallTransform = matrix_identity_float4x4;
        gWallTransform.columns[3] = (simd_float4){0.0f, 0.0f, -distance, 1.0f};
        gWallSnapped = true;
        (void)headPos; (void)forward; (void)right; (void)up;
    }

    // Bildschirmkoordinaten (0..640, 0..480) in Wandkoordinaten (Meter):
    //   x = (sx/640 - 0.5) * width
    //   y = (0.5 - sy/480) * height      (y läuft in 2D nach unten)
    simd_float4x4 scale = matrix_identity_float4x4;
    scale.columns[0].x =  width / 640.0f;
    scale.columns[1].y = -height / 480.0f;
    scale.columns[3].x = -width * 0.5f;
    scale.columns[3].y =  height * 0.5f;

    // modelview = Auge-aus-Welt * Welt-aus-Wand * Skalierung
    //
    // cp_view_get_transform liefert Gerät-aus-Auge, NICHT Welt-aus-Auge — die
    // Transformation ist relativ zum Geräteanker. Ohne die Kopftransformation
    // davor fehlt die Kopfposition vollständig: die Wand folgt dann dem Kopf
    // statt im Raum zu stehen, und sie sitzt um die Kopfhöhe zu tief.
    //
    // In S4 stand dafür deviceAnchor.originFromAnchorTransform * view.transform.
    // Umschaltbar, weil die Messung beides widerlegt hat: OHNE die
    // Kopftransformation folgte die Wand dem Kopf und saß um die Kopfhöhe zu
    // tief; MIT ihr stimmt die Höhe, aber das Bild dreht sich mit etwa
    // doppelter Geschwindigkeit — ein klassisches Zeichen dafür, dass eine
    // Transformation zweimal angewandt wird.
    //
    // Wahrscheinlich enthält cp_view_get_transform die Kopfpose bereits, seit
    // cp_drawable_set_device_anchor gesetzt ist, und nur die Translation fehlte.
    // Deshalb hier drei Varianten zum Messen statt einer Vermutung:
    //   0 = nur die View-Transformation      (Rotation einfach)
    //   1 = Kopf * View                      (Rotation doppelt, Höhe richtig)
    //   2 = nur die Kopf-TRANSLATION * View  (Rotation einfach, Höhe richtig)
    // Fest verdrahtet, keine cvar mehr.
    //
    // Die Messung hat gezeigt: cp_view_get_transform enthält nur den
    // Augenversatz (32 mm seitlich), keine Kopfpose — die Blickrichtung dort
    // ist glatt (0,0,-1), während der Kopf tatsächlich geneigt war. Also ist
    // Kopf * View die richtige Formel, das Lehrbuchmuster von
    // CompositorServices.
    //
    // Die Umschaltbarkeit über eine cvar hat nur Verwirrung gestiftet: der Wert
    // stand aus der Konfigurationsdatei auf 2 und ließ sich nicht zuverlässig
    // überschreiben.
    simd_float4x4 viewTf = cp_view_get_transform(cp_drawable_get_view(gDrawable, eye));

    // TEST: kopfrelativ rendern statt weltfest.
    //
    // Unsere weltfeste Rechnung ist nachweislich richtig — die Wandmitte
    // wandert im Augenraum um genau den Winkel, um den sich der Kopf dreht.
    // Trotzdem bewegt sich das Bild doppelt so schnell. Also wendet der
    // Compositor die Kopfpose über den Anker ein zweites Mal an.
    //
    // Prüfung: Wand fest im GERÄTE-Koordinatensystem (2 m geradeaus, dreht sich
    // mit dem Kopf), Matrix ohne Kopftransformation. Macht der Compositor
    // daraus ein weltfestes Bild, ist bewiesen, dass er den Anker anwendet —
    // und dann ist kopfrelativ die richtige Art zu rendern.
    simd_float4x4 originFromView = viewTf;

    simd_float4x4 viewFromOrigin = simd_inverse(originFromView);
    simd_float4x4 mv = simd_mul(simd_mul(viewFromOrigin, gWallTransform), scale);
    memcpy(modelview16, &mv, sizeof(float) * 16);

    // Kernfrage, direkt gemessen: enthält die fertige Modelview-Matrix die
    // Kopfdrehung? Wenn ja, muss sich der Wandmittelpunkt im Augenraum beim
    // Kopfdrehen bewegen. Bleibt er stehen, fehlt die Rotation — dann liegt es
    // nicht am Compositor, sondern an unserer Rechnung.
    //
    // Ausgegeben wird die Wandmitte (Bildschirmmitte 320/240) im Augenraum.
    static int frame = 0;
    if (eye == 0 && (++frame % 30) == 0) {
        simd_float4 centre = simd_mul(mv, (simd_float4){320.0f, 240.0f, 0.0f, 1.0f});
        ALOGV("[Wand] Kopf vorwaerts %.3f %.3f %.3f  ->  Wandmitte im Auge %.3f %.3f %.3f",
              -gHeadTransform.columns[2].x, -gHeadTransform.columns[2].y,
              -gHeadTransform.columns[2].z, centre.x, centre.y, centre.z);
    }

    return true;
}

/// Lässt die Wand beim nächsten Bild neu einrasten — etwa wenn Menü oder
/// Video neu geöffnet werden, damit sie wieder vor dem Spieler steht.
extern "C" void VR_ResnapScreenWall(void)
{
    gWallSnapped = false;
}

extern "C" int VR_GetCurrentEye(void)
{
    return gCurrentEye;
}
