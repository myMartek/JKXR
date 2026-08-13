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

#include <dlfcn.h>

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
void (*BindTexture)(GLenum, GLuint) = nullptr;
void (*DeleteTextures)(GLsizei, const GLuint *) = nullptr;
void (*GenFramebuffers)(GLsizei, GLuint *) = nullptr;
void (*BindFramebuffer)(GLenum, GLuint) = nullptr;
void (*FramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint) = nullptr;
GLenum (*CheckFramebufferStatus)(GLenum) = nullptr;
void (*Viewport)(GLint, GLint, GLsizei, GLsizei) = nullptr;
void (*Enable)(GLenum) = nullptr;
void (*DepthFunc)(GLenum) = nullptr;
void (*DepthMask)(GLboolean) = nullptr;
void (*ClearDepthf)(GLfloat) = nullptr;
GLenum (*GetError)(void) = nullptr;
void (*Flush)(void) = nullptr;
void (*ClearColor)(GLfloat, GLfloat, GLfloat, GLfloat) = nullptr;
void (*Clear)(GLbitfield) = nullptr;
void (*Finish)(void) = nullptr;

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
    RESOLVE(BindTexture)
    RESOLVE(DeleteTextures)
    RESOLVE(GenFramebuffers)
    RESOLVE(BindFramebuffer)
    RESOLVE(FramebufferTexture2D)
    RESOLVE(CheckFramebufferStatus)
    RESOLVE(Viewport)
    RESOLVE(Enable)
    RESOLVE(DepthFunc)
    RESOLVE(DepthMask)
    RESOLVE(ClearDepthf)
    RESOLVE(GetError)
    RESOLVE(Flush)
    RESOLVE(ClearColor)
    RESOLVE(Clear)
    RESOLVE(Finish)
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

/// Entspricht `superSampling` in der Android-Fassung.
float gSuperSampling = 1.0f;

/// Nur zur Fehlersuche: die ersten Bilder Schritt für Schritt protokollieren.
/// Der Absturz kommt wortlos, also muss die letzte erreichte Stelle her.
int gFrameCounter = 0;
#define TRACE(...) do { if (gFrameCounter < 3) ALOGV(__VA_ARGS__); } while (0)

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
        ar_world_tracking_provider_query_device_anchor_at_timestamp(
            tracking,
            cp_time_to_cf_time_interval(cp_frame_timing_get_trackable_anchor_time(actual)),
            anchor);
        cp_drawable_set_device_anchor(gDrawable, anchor);
        // ... und dieselbe Pose an die Engine, sonst hat sie keine Blickrichtung.
        TBXR_GetHMDOrientation(anchor);
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
    TRACE("[Bild %d] prepareEyeBuffer Auge %d", gFrameCounter, eye);
    if (!gDrawable) return;

    id<MTLTexture> color = cp_drawable_get_color_texture(gDrawable, eye);
    id<MTLTexture> depth = cp_drawable_get_depth_texture(gDrawable, eye);

    EyeImport &import = gEyes[eye];
    if (!importTexture(color, 0, &import.colorTexture, &import.colorImage, "Farbe")) return;

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


    // Reversed-Z wie vom Compositor erwartet.
    angle::Enable(GL_DEPTH_TEST);
    angle::DepthFunc(GL_GREATER);
    angle::DepthMask(GL_TRUE);
    angle::ClearDepthf(0.0f);
}

void TBXR_finishEyeBuffer(int eye)
{
    TRACE("[Bild %d] finishEyeBuffer Auge %d", gFrameCounter, eye);
    if (!gDrawable) return;

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
    // Encoder wird sofort wieder beendet.
    if (Cvar_VariableValue("vr_debug_metal_clear") != 0.0f) {
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
                pass.depthAttachment.clearDepth = 0.0;   // Reversed-Z
            }

            id<MTLRenderCommandEncoder> enc =
                [gCommandBuffer renderCommandEncoderWithDescriptor:pass];
            [enc endEncoding];
        }
    }

    cp_drawable_encode_present(gDrawable, gCommandBuffer);
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
        ALOGV("[Bild %d] CommandBuffer Status %ld%s%s",
              gFrameCounter,
              (long)gCommandBuffer.status,
              gCommandBuffer.error ? " FEHLER: " : "",
              gCommandBuffer.error
                  ? [[gCommandBuffer.error localizedDescription] UTF8String] : "");
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

bool VR_UseScreenLayer()
{
    // Menüs und Videosequenzen zeichnet JKXR auf eine flache Ebene. Das läuft
    // hier über denselben Renderpfad, eine gesonderte Compositor-Ebene gibt es
    // nicht.
    return false;
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

