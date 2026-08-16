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
void (*TexImage2D)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *) = nullptr;
void (*TexParameteri)(GLenum, GLenum, GLint) = nullptr;
void (*DeleteTextures)(GLsizei, const GLuint *) = nullptr;
void (*GenFramebuffers)(GLsizei, GLuint *) = nullptr;
void (*BindFramebuffer)(GLenum, GLuint) = nullptr;
void (*FramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint) = nullptr;
GLenum (*CheckFramebufferStatus)(GLenum) = nullptr;
// Für den Tiefenpuffer des Flat-Screen-Ziels.
void (*GenRenderbuffers)(GLsizei, GLuint *) = nullptr;
void (*BindRenderbuffer)(GLenum, GLuint) = nullptr;
void (*RenderbufferStorage)(GLenum, GLenum, GLsizei, GLsizei) = nullptr;
void (*FramebufferRenderbuffer)(GLenum, GLenum, GLenum, GLuint) = nullptr;
void (*DeleteRenderbuffers)(GLsizei, const GLuint *) = nullptr;
// Nur für die Diagnose weiter unten.
void (*ReadPixels)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *) = nullptr;
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
void (*GetFloatv)(GLenum, GLfloat *) = nullptr;
GLint (*GetUniformLocation)(GLuint, const GLchar *) = nullptr;
void (*UniformMatrix4fv)(GLint, GLsizei, GLboolean, const GLfloat *) = nullptr;
void (*Uniform2f)(GLint, GLfloat, GLfloat) = nullptr;
void (*Uniform1i)(GLint, GLint) = nullptr;

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
    RESOLVE(TexImage2D)
    RESOLVE(TexParameteri)
    RESOLVE(DeleteTextures)
    RESOLVE(GenFramebuffers)
    RESOLVE(BindFramebuffer)
    RESOLVE(FramebufferTexture2D)
    RESOLVE(CheckFramebufferStatus)
    RESOLVE(GenRenderbuffers)
    RESOLVE(BindRenderbuffer)
    RESOLVE(RenderbufferStorage)
    RESOLVE(FramebufferRenderbuffer)
    RESOLVE(DeleteRenderbuffers)
    RESOLVE(ReadPixels)
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
    RESOLVE(GetFloatv)
    RESOLVE(GetUniformLocation)
    RESOLVE(UniformMatrix4fv)
    RESOLVE(Uniform2f)
    RESOLVE(Uniform1i)
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

// Sichtsonde über Metal (siehe TBXR_submitFrame). Der Blit läuft in einem
// Bild, gelesen wird im nächsten — so muss nirgends auf die GPU gewartet
// werden.
static id<MTLTexture> gProbeStaging = nil;
static id<MTLCommandBuffer> gProbeCommands = nil;
static bool gProbePending = false;

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
GLuint    gScreenWallDepthProgram = 0;
GLuint    gScreenPanelProgram = 0;

// Menü und Video werden zunächst wie auf einem normalen Monitor in diese
// Textur gezeichnet. Erst danach setzt ein kleiner direkter ANGLE-Pass die
// Textur als echte Wand in die Welt. Dadurch gelangen weder ARKits Pose noch
// die visionOS-Projektionsmatrix durch gl4es' Fixed-Function-Matrixemulation.
GLuint gFlatScreenFramebuffer = 0;
// Tiefenpuffer des Zwischenpuffers; ohne ihn hat die Menü-3D keinen Tiefentest.
GLuint gFlatScreenDepth = 0;
GLuint gFlatScreenTexture = 0;
EGLImageKHR gFlatScreenImage = EGL_NO_IMAGE_KHR;
id<MTLTexture> gFlatScreenMetalTexture = nil;
int gFlatScreenWidth = 0;
int gFlatScreenHeight = 0;
bool gRenderingFlatScreen[ovrMaxNumEyes] = { false, false };
bool gFlatScreenIsCinematic = false;

id<MTLRenderPipelineState> gMetalPanelPipeline = nil;
id<MTLDepthStencilState> gMetalPanelDepthState = nil;
MTLPixelFormat gMetalPanelColorFormat = MTLPixelFormatInvalid;
MTLPixelFormat gMetalPanelDepthFormat = MTLPixelFormatInvalid;

// Unveränderte Pose, die auch cp_drawable_set_device_anchor beschreibt. Der
// Compositor und der finale Panel-Pass müssen exakt dieselbe Kamera meinen.
simd_float4x4 gRawHeadTransform = matrix_identity_float4x4;
bool gRawHeadValid = false;
simd_float4x4 gPanelTransform = matrix_identity_float4x4;
bool gPanelSnapped = false;

EGLDisplay gDisplay = EGL_NO_DISPLAY;
PFNEGLCREATEIMAGEKHRPROC  eglCreateImage_  = nullptr;
PFNEGLDESTROYIMAGEKHRPROC eglDestroyImage_ = nullptr;
PFNGLEGLIMAGETARGETTEXTURE2DOESPROC glImageTargetTexture_ = nullptr;

bool importTexture(id<MTLTexture> texture, int slice,
                   GLuint *outTexture, EGLImageKHR *outImage,
                   const char *what);

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

/// Auf dem ANGLE/GLES-Importpfad stimmen die Rotationsrichtungen nicht für
/// alle Achsen überein: Yaw ist mit ARKits normaler Richtung weltstabil,
/// Pitch und Roll mit der invertierten. Das ist exakt ein Basiswechsel durch
/// Spiegeln der Y-Achse: S * R * S. Anders als eine Euler-Zerlegung bleibt
/// diese Abbildung auch bei kombinierten Kopfbewegungen orthogonal und mischt
/// keine scheinbare Neigung in eine Yaw-Drehung.
simd_float4x4 screenWallOriginFromDevice()
{
    // Die Y-Konjugation der Kopfdrehung BLEIBT. Zweimal geprüft, zweimal
    // bestätigt, das zweite Mal mit Zahlen.
    //
    // Sie umzurechnen sieht nach doppelter Korrektur aus:
    //
    //     flipY = diag(1, -1, 1)
    //     adjusted = flipY * headRotation * flipY
    //
    // Eine Konjugation erhält die Determinante, ist also keine Spiegelung. Die
    // Drehachse transformiert sich dabei aber als Pseudovektor:
    //
    //     n -> det(flipY) * flipY * n = (-n_x, n_y, -n_z)
    //
    // Gieren bleibt, Nicken und Rollen kehren sich um. Das klingt nach Fehler --
    // und ist die notwendige Umrechnung: gHeadTransform kommt in der Konvention
    // des Compositors, die Wand wird in der des Renderers gezeichnet, und die
    // beiden unterscheiden sich genau um diese Y-Umkehr.
    //
    // Ohne sie auf dem Gerät gemessen:
    //
    //     Kopf 30 Grad nach oben   ->  Bild wandert 60 Grad
    //     Kopf nach links geneigt  ->  Bild neigt sich nach rechts
    //     nach links/rechts sehen  ->  Bild bleibt stehen (richtig)
    //
    // Also doppelter Fehler bei Nicken und Rollen, Gieren unauffällig -- exakt
    // die Signatur (-n_x, n_y, -n_z), nur eben andersherum als vermutet: nicht
    // die Konjugation erzeugt sie, sie hebt sie auf.
    //
    // Die damals gemessene zu kleine Disparität (0,025 m statt 0,064 m Augen-
    // abstand) bleibt davon unberührt und ungeklärt. Eine Rotation ändert keine
    // Längen, die Ursache liegt also anderswo -- der nächste Ansatzpunkt ist die
    // Achsenkonvention in VR_GetScreenWall, wo der Kommentar right_down_back
    // begründet und der Code right_up_back benutzt.
    simd_float4x4 headRotation = gHeadTransform;
    headRotation.columns[3] = (simd_float4){0.0f, 0.0f, 0.0f, 1.0f};

    simd_float4x4 flipY = matrix_identity_float4x4;
    flipY.columns[1].y = -1.0f;
    simd_float4x4 adjusted =
        simd_mul(flipY, simd_mul(headRotation, flipY));
    adjusted.columns[3] = gHeadTransform.columns[3];
    return adjusted;
}

/// Nur zur Fehlersuche: die ersten Bilder Schritt für Schritt protokollieren.
/// Der Absturz kommt wortlos, also muss die letzte erreichte Stelle her.
int gFrameCounter = 0;

// Zeitpunkt des zuletzt abgegebenen Bildes, gesetzt in TBXR_submitFrame.
// TBXR_visionOS_PumpLoadingFrame springt nur ein, wenn dieser Wert alt ist —
// solange die Engine selbst zeichnet, bleibt die Pumpe still.
static double gLastFrameSubmitted = 0.0;
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

bool ensureScreenWallDepthProgram()
{
    if (gScreenWallDepthProgram) return true;

    static const char *vertexSource =
        "#version 300 es\n"
        "uniform mat4 mvp;\n"
        "uniform vec2 halfSize;\n"
        "void main() {\n"
        "  vec2 p[4];\n"
        "  p[0]=vec2(-1.0,-1.0); p[1]=vec2(1.0,-1.0);\n"
        "  p[2]=vec2(-1.0,1.0);  p[3]=vec2(1.0,1.0);\n"
        "  gl_Position=mvp*vec4(p[gl_VertexID]*halfSize,0.0,1.0);\n"
        "}\n";
    static const char *fragmentSource =
        "#version 300 es\n"
        "precision mediump float;\n"
        "out vec4 color;\n"
        "void main() { color=vec4(0.0); }\n";

    GLuint vertex = compileBackgroundShader(GL_VERTEX_SHADER, vertexSource);
    GLuint fragment = compileBackgroundShader(GL_FRAGMENT_SHADER, fragmentSource);
    if (!vertex || !fragment) return false;

    gScreenWallDepthProgram = angle::CreateProgram();
    angle::AttachShader(gScreenWallDepthProgram, vertex);
    angle::AttachShader(gScreenWallDepthProgram, fragment);
    angle::LinkProgram(gScreenWallDepthProgram);
    angle::DeleteShader(vertex);
    angle::DeleteShader(fragment);

    GLint linked = GL_FALSE;
    angle::GetProgramiv(gScreenWallDepthProgram, GL_LINK_STATUS, &linked);
    if (!linked) {
        GLchar log[1024] = {};
        angle::GetProgramInfoLog(gScreenWallDepthProgram, sizeof(log), nullptr, log);
        ALOGE("ANGLE-Wandtiefenprogramm fehlgeschlagen: %s", log);
        return false;
    }
    return true;
}

void drawScreenWallDepth(int eye)
{
    if (!gWallSnapped || !gHeadValid || !ensureScreenWallDepthProgram()) return;

    // MUSS dieselbe Konvention benutzen wie der Farbpass.
    //
    // VR_GetScreenWall zeichnet die Wand mit right_DOWN_back, weil GL den
    // Framebuffer von unten adressiert und Metal Zeile 0 oben zeigt. Blieb es
    // hier bei right_up_back, wurde die Tiefe der Wand SENKRECHT GESPIEGELT zu
    // ihrer Farbe geschrieben.
    //
    // Das ist nicht bloß unsauber: der Compositor reprojiziert die Farbe
    // anhand der Tiefe. Stimmen beide nicht überein, bekommt jedes Auge eine
    // andere falsche Verschiebung — das HUD wandert beim Drehen, erscheint in
    // einem Auge früher als im anderen und lässt sich nicht fusionieren.
    simd_float4x4 projection = cp_drawable_compute_projection(
        // Auf right_DOWN_back umgestellt: dieselbe Konvention, mit der die
        // Welt-Szene gezeichnet wird (VR_GetVRProjection). Die Wand lief als
        // einzige auf right_up_back, und der Kommentar hier nennt genau das
        // gemessene Symptom -- beim Neigen dreht sich das Bild nicht mit,
        // sondern verformt sich.
        // ERWARTET: das Bild steht damit zunaechst auf dem Kopf. Das ist der
        // Preis dafuer, nur EINEN Faktor zu aendern; die Orientierung kommt im
        // naechsten Schritt ueber das Vorzeichen in der scale-Matrix.
        gDrawable, cp_axis_direction_convention_right_down_back, eye);
    simd_float4x4 deviceFromView =
        cp_view_get_transform(cp_drawable_get_view(gDrawable, eye));
    // Vollständige ARKit-Gerätepose. Die inverse View-Matrix verschiebt die
    // Wand im Sichtfeld entgegen der Kopfbewegung und hält sie dadurch in der
    // Welt. Farbe und Tiefe müssen exakt dieselbe Pose verwenden.
    simd_float4x4 originFromDevice = screenWallOriginFromDevice();
    simd_float4x4 originFromView = simd_mul(originFromDevice, deviceFromView);
    simd_float4x4 mvp = simd_mul(
        projection, simd_mul(simd_inverse(originFromView), gWallTransform));

    GLint previousProgram = 0;
    GLint previousDepthFunc = GL_LESS;
    GLboolean previousColorMask[4] = { GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE };
    GLboolean previousDepthMask = GL_TRUE;
    const GLboolean depthWasEnabled = angle::IsEnabled(GL_DEPTH_TEST);
    const GLboolean cullWasEnabled = angle::IsEnabled(GL_CULL_FACE);
    angle::GetIntegerv(GL_CURRENT_PROGRAM, &previousProgram);
    angle::GetIntegerv(GL_DEPTH_FUNC, &previousDepthFunc);
    angle::GetBooleanv(GL_COLOR_WRITEMASK, previousColorMask);
    angle::GetBooleanv(GL_DEPTH_WRITEMASK, &previousDepthMask);

    angle::ColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
    angle::Enable(GL_DEPTH_TEST);
    angle::Disable(GL_CULL_FACE);
    angle::DepthFunc(GL_ALWAYS);
    angle::DepthMask(GL_TRUE);
    angle::UseProgram(gScreenWallDepthProgram);
    angle::UniformMatrix4fv(
        angle::GetUniformLocation(gScreenWallDepthProgram, "mvp"),
        1, GL_FALSE, reinterpret_cast<const GLfloat *>(&mvp));
    angle::Uniform2f(
        angle::GetUniformLocation(gScreenWallDepthProgram, "halfSize"),
        2.4f * 0.5f, 2.4f * (480.0f / 640.0f) * 0.5f);
    angle::DrawArrays(GL_TRIANGLE_STRIP, 0, 4);

    angle::UseProgram((GLuint)previousProgram);
    angle::ColorMask(previousColorMask[0], previousColorMask[1],
                     previousColorMask[2], previousColorMask[3]);
    if (depthWasEnabled) angle::Enable(GL_DEPTH_TEST);
    else angle::Disable(GL_DEPTH_TEST);
    if (cullWasEnabled) angle::Enable(GL_CULL_FACE);
    angle::DepthFunc((GLenum)previousDepthFunc);
    angle::DepthMask(previousDepthMask);
}

bool ensureFlatScreenTarget()
{
    // Die Maße MÜSSEN glConfig.vidWidth/vidHeight entsprechen.
    //
    // RB_SetGL2D setzt die Ansicht auf glConfig.vidWidth/vidHeight; weicht der
    // Puffer davon ab, zeichnet die Engine nur in einen Teil von ihm, während
    // das Panel den ganzen anzeigt. Ein Versuch, hier auf 4:3 zu gehen (die
    // Oberfläche rechnet in 640x480, das Panel ist 4:3), hat deshalb nichts
    // verbessert und die beiden Größen auseinanderlaufen lassen.
    const int width = (int)(gAppState.Width * gSuperSampling);
    const int height = (int)(gAppState.Height * gSuperSampling);
    if (width <= 0 || height <= 0) return false;

    if (gFlatScreenTexture && width == gFlatScreenWidth &&
        height == gFlatScreenHeight) {
        return true;
    }

    if (gFlatScreenTexture) {
        angle::DeleteTextures(1, &gFlatScreenTexture);
        gFlatScreenTexture = 0;
    }
    if (gFlatScreenImage != EGL_NO_IMAGE_KHR && eglDestroyImage_) {
        eglDestroyImage_(gDisplay, gFlatScreenImage);
        gFlatScreenImage = EGL_NO_IMAGE_KHR;
    }
    gFlatScreenMetalTexture = nil;
    if (!gFlatScreenFramebuffer) {
        angle::GenFramebuffers(1, &gFlatScreenFramebuffer);
    }

    id<MTLDevice> device = cp_layer_renderer_get_device(gLayerRenderer);
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:(NSUInteger)width
                                                          height:(NSUInteger)height
                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModePrivate;
    gFlatScreenMetalTexture = [device newTextureWithDescriptor:descriptor];
    if (!gFlatScreenMetalTexture ||
        !importTexture(gFlatScreenMetalTexture, 0, &gFlatScreenTexture,
                       &gFlatScreenImage, "2D-Zwischenpuffer")) {
        ALOGE("2D-Zwischenpuffer konnte nicht zwischen Metal und ANGLE geteilt werden");
        gFlatScreenMetalTexture = nil;
        return false;
    }

    angle::ActiveTexture(GL_TEXTURE0);
    angle::BindTexture(GL_TEXTURE_2D, gFlatScreenTexture);
    angle::TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    angle::TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    angle::TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    angle::TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    angle::BindFramebuffer(GL_FRAMEBUFFER, gFlatScreenFramebuffer);
    angle::FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                GL_TEXTURE_2D, gFlatScreenTexture, 0);

    // Tiefenpuffer — für 2D überflüssig, für die Menü-3D unverzichtbar.
    //
    // Der Zwischenpuffer hatte bisher nur eine Farbanlage. Für Text und
    // Schaltflächen genügt das, aber die Charakter- und Lichtschwertvorschau
    // rendern ein echtes 3D-Modell hier hinein. Ohne Tiefenpuffer ist der
    // Tiefentest wirkungslos, und es entscheidet allein die Zeichenreihenfolge:
    // Mund und Augen liegen im Modell HINTER dem Gesicht, werden aber später
    // gezeichnet — und scheinen dadurch mitten durch den Kopf.
    if (!gFlatScreenDepth) {
        angle::GenRenderbuffers(1, &gFlatScreenDepth);
    }
    angle::BindRenderbuffer(GL_RENDERBUFFER, gFlatScreenDepth);
    angle::RenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, width, height);
    angle::FramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                                   GL_RENDERBUFFER, gFlatScreenDepth);
    angle::BindRenderbuffer(GL_RENDERBUFFER, 0);

    const GLenum status = angle::CheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        ALOGE("2D-Zwischenpuffer unvollstaendig: 0x%04x", status);
        return false;
    }

    gFlatScreenWidth = width;
    gFlatScreenHeight = height;
    ALOGV("2D-Zwischenpuffer: %dx%d", width, height);
    return true;
}

bool ensureScreenPanelProgram()
{
    if (gScreenPanelProgram) return true;

    static const char *vertexSource =
        "#version 300 es\n"
        "uniform mat4 mvp;\n"
        "uniform vec2 halfSize;\n"
        "out vec2 uv;\n"
        "void main() {\n"
        "  vec2 p[4];\n"
        "  p[0]=vec2(-1.0,-1.0); p[1]=vec2(1.0,-1.0);\n"
        "  p[2]=vec2(-1.0,1.0);  p[3]=vec2(1.0,1.0);\n"
        "  vec2 q=p[gl_VertexID];\n"
        "  uv=q*0.5+0.5;\n"
        "  gl_Position=mvp*vec4(q*halfSize,0.0,1.0);\n"
        "}\n";
    static const char *fragmentSource =
        "#version 300 es\n"
        "precision mediump float;\n"
        "uniform sampler2D screenTexture;\n"
        "in vec2 uv;\n"
        "out vec4 color;\n"
        "void main() { color=texture(screenTexture,uv); }\n";

    GLuint vertex = compileBackgroundShader(GL_VERTEX_SHADER, vertexSource);
    GLuint fragment = compileBackgroundShader(GL_FRAGMENT_SHADER, fragmentSource);
    if (!vertex || !fragment) return false;

    gScreenPanelProgram = angle::CreateProgram();
    angle::AttachShader(gScreenPanelProgram, vertex);
    angle::AttachShader(gScreenPanelProgram, fragment);
    angle::LinkProgram(gScreenPanelProgram);
    angle::DeleteShader(vertex);
    angle::DeleteShader(fragment);

    GLint linked = GL_FALSE;
    angle::GetProgramiv(gScreenPanelProgram, GL_LINK_STATUS, &linked);
    if (!linked) {
        GLchar log[1024] = {};
        angle::GetProgramInfoLog(gScreenPanelProgram, sizeof(log), nullptr, log);
        ALOGE("ANGLE-Panelprogramm fehlgeschlagen: %s", log);
        return false;
    }
    return true;
}

void snapNativeScreenPanel()
{
    if (gPanelSnapped || !gRawHeadValid) return;

    const simd_float3 headPos = gRawHeadTransform.columns[3].xyz;
    simd_float3 forward = -gRawHeadTransform.columns[2].xyz;
    forward.y = 0.0f;
    if (simd_length(forward) < 1e-4f) {
        forward = (simd_float3){0.0f, 0.0f, -1.0f};
    }
    forward = simd_normalize(forward);

    const simd_float3 up = (simd_float3){0.0f, 1.0f, 0.0f};
    const simd_float3 right = simd_normalize(simd_cross(up, -forward));
    const simd_float3 centre = headPos + forward * 2.0f;

    gPanelTransform = matrix_identity_float4x4;
    gPanelTransform.columns[0] = (simd_float4){right.x, right.y, right.z, 0.0f};
    gPanelTransform.columns[1] = (simd_float4){up.x, up.y, up.z, 0.0f};
    gPanelTransform.columns[2] =
        (simd_float4){-forward.x, -forward.y, -forward.z, 0.0f};
    gPanelTransform.columns[3] =
        (simd_float4){centre.x, centre.y, centre.z, 1.0f};
    gPanelSnapped = true;
}

void drawNativeScreenPanel(int eye)
{
    snapNativeScreenPanel();
    if (!gPanelSnapped || !gFlatScreenTexture ||
        !ensureScreenPanelProgram()) return;

    const simd_float4x4 projection = cp_drawable_compute_projection(
        gDrawable, cp_axis_direction_convention_right_up_back, eye);
    const simd_float4x4 deviceFromView =
        cp_view_get_transform(cp_drawable_get_view(gDrawable, eye));
    const simd_float4x4 originFromView =
        simd_mul(gRawHeadTransform, deviceFromView);
    const simd_float4x4 mvp = simd_mul(
        projection, simd_mul(simd_inverse(originFromView), gPanelTransform));

    GLint previousProgram = 0;
    GLint previousActiveTexture = GL_TEXTURE0;
    GLint previousTexture2DUnit0 = 0;
    GLint previousDepthFunc = GL_LESS;
    GLboolean previousColorMask[4] = { GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE };
    GLboolean previousDepthMask = GL_TRUE;
    const GLboolean depthWasEnabled = angle::IsEnabled(GL_DEPTH_TEST);
    const GLboolean cullWasEnabled = angle::IsEnabled(GL_CULL_FACE);
    const GLboolean blendWasEnabled = angle::IsEnabled(GL_BLEND);
    const GLboolean scissorWasEnabled = angle::IsEnabled(GL_SCISSOR_TEST);
    angle::GetIntegerv(GL_CURRENT_PROGRAM, &previousProgram);
    angle::GetIntegerv(GL_ACTIVE_TEXTURE, &previousActiveTexture);
    angle::ActiveTexture(GL_TEXTURE0);
    angle::GetIntegerv(GL_TEXTURE_BINDING_2D, &previousTexture2DUnit0);
    angle::GetIntegerv(GL_DEPTH_FUNC, &previousDepthFunc);
    angle::GetBooleanv(GL_COLOR_WRITEMASK, previousColorMask);
    angle::GetBooleanv(GL_DEPTH_WRITEMASK, &previousDepthMask);

    angle::Enable(GL_DEPTH_TEST);
    angle::Disable(GL_CULL_FACE);
    angle::Disable(GL_BLEND);
    angle::Disable(GL_SCISSOR_TEST);
    angle::DepthFunc(GL_ALWAYS);
    angle::DepthMask(GL_TRUE);
    angle::ColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    angle::ActiveTexture(GL_TEXTURE0);
    angle::BindTexture(GL_TEXTURE_2D, gFlatScreenTexture);
    angle::UseProgram(gScreenPanelProgram);
    angle::UniformMatrix4fv(
        angle::GetUniformLocation(gScreenPanelProgram, "mvp"), 1, GL_FALSE,
        reinterpret_cast<const GLfloat *>(&mvp));
    angle::Uniform2f(
        angle::GetUniformLocation(gScreenPanelProgram, "halfSize"),
        1.2f, 0.9f);
    angle::Uniform1i(
        angle::GetUniformLocation(gScreenPanelProgram, "screenTexture"), 0);
    angle::DrawArrays(GL_TRIANGLE_STRIP, 0, 4);

    angle::UseProgram((GLuint)previousProgram);
    angle::BindTexture(GL_TEXTURE_2D, (GLuint)previousTexture2DUnit0);
    angle::ActiveTexture((GLenum)previousActiveTexture);
    angle::ColorMask(previousColorMask[0], previousColorMask[1],
                     previousColorMask[2], previousColorMask[3]);
    angle::DepthFunc((GLenum)previousDepthFunc);
    angle::DepthMask(previousDepthMask);
    if (depthWasEnabled) angle::Enable(GL_DEPTH_TEST);
    else angle::Disable(GL_DEPTH_TEST);
    if (cullWasEnabled) angle::Enable(GL_CULL_FACE);
    if (blendWasEnabled) angle::Enable(GL_BLEND);
    if (scissorWasEnabled) angle::Enable(GL_SCISSOR_TEST);
}

struct alignas(16) MetalPanelUniforms {
    simd_float4x4 modelViewProjection;
    simd_float2 halfSize;
    uint32_t flipVertical;
    uint32_t padding;
};

bool ensureMetalPanelPipeline(MTLPixelFormat colorFormat,
                              MTLPixelFormat depthFormat)
{
    if (gMetalPanelPipeline && gMetalPanelColorFormat == colorFormat &&
        gMetalPanelDepthFormat == depthFormat) {
        return true;
    }

    static const char *source = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct PanelUniforms {
    float4x4 modelViewProjection;
    float2 halfSize;
    uint flipVertical;
    uint padding;
};
struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut jkxr_panel_vertex(uint vid [[vertex_id]],
                                    constant PanelUniforms &u [[buffer(0)]]) {
    const float2 corners[4] = {
        float2(-1.0, -1.0), float2(1.0, -1.0),
        float2(-1.0,  1.0), float2(1.0,  1.0)
    };
    const float2 uvs[4] = {
        float2(0.0, 1.0), float2(1.0, 1.0),
        float2(0.0, 0.0), float2(1.0, 0.0)
    };
    const float2 corner = corners[vid] * u.halfSize;
    VertexOut out;
    out.position = u.modelViewProjection * float4(corner, 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

fragment float4 jkxr_panel_fragment(VertexOut in [[stage_in]],
                                     constant PanelUniforms &u [[buffer(0)]],
                                     texture2d<float> screen [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    // Normale GL-UI landet im gemeinsam genutzten Metal-Ziel nur vertikal
    // gedreht. X ist bereits richtig; beide Komponenten zu invertieren würde
    // das Menü zwar aufrecht, aber spiegelverkehrt anzeigen.
    const float2 sampleUV = u.flipVertical != 0
        ? float2(in.uv.x, 1.0 - in.uv.y)
        : in.uv;
    return float4(screen.sample(s, sampleUV).rgb, 1.0);
}
)METAL";

    id<MTLDevice> device = cp_layer_renderer_get_device(gLayerRenderer);
    NSError *error = nil;
    NSString *text = [NSString stringWithUTF8String:source];
    id<MTLLibrary> library = [device newLibraryWithSource:text
                                                  options:nil
                                                    error:&error];
    if (!library) {
        ALOGE("Metal-Panelshader fehlgeschlagen: %s",
              [[error localizedDescription] UTF8String]);
        return false;
    }

    MTLRenderPipelineDescriptor *descriptor =
        [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction =
        [library newFunctionWithName:@"jkxr_panel_vertex"];
    descriptor.fragmentFunction =
        [library newFunctionWithName:@"jkxr_panel_fragment"];
    descriptor.colorAttachments[0].pixelFormat = colorFormat;
    descriptor.depthAttachmentPixelFormat = depthFormat;
    gMetalPanelPipeline = [device newRenderPipelineStateWithDescriptor:descriptor
                                                                  error:&error];
    if (!gMetalPanelPipeline) {
        ALOGE("Metal-Panelpipeline fehlgeschlagen: %s",
              [[error localizedDescription] UTF8String]);
        return false;
    }

    MTLDepthStencilDescriptor *depthDescriptor =
        [[MTLDepthStencilDescriptor alloc] init];
    depthDescriptor.depthCompareFunction = MTLCompareFunctionGreater;
    depthDescriptor.depthWriteEnabled = YES;
    gMetalPanelDepthState =
        [device newDepthStencilStateWithDescriptor:depthDescriptor];
    gMetalPanelColorFormat = colorFormat;
    gMetalPanelDepthFormat = depthFormat;
    return true;
}

void drawMetalScreenPanel(int eye)
{
    snapNativeScreenPanel();
    if (!gPanelSnapped || !gFlatScreenMetalTexture || !gCommandBuffer) return;

    id<MTLTexture> color = cp_drawable_get_color_texture(gDrawable, eye);
    id<MTLTexture> depth = cp_drawable_get_depth_texture(gDrawable, eye);
    if (!color || !depth ||
        !ensureMetalPanelPipeline(color.pixelFormat, depth.pixelFormat)) return;

    const simd_float4x4 projection = cp_drawable_compute_projection(
        gDrawable, cp_axis_direction_convention_right_up_back, eye);
    const simd_float4x4 deviceFromView =
        cp_view_get_transform(cp_drawable_get_view(gDrawable, eye));
    const simd_float4x4 originFromView =
        simd_mul(gRawHeadTransform, deviceFromView);
    MetalPanelUniforms uniforms = {
        simd_mul(projection,
                 simd_mul(simd_inverse(originFromView), gPanelTransform)),
        (simd_float2){1.2f, 0.9f},
        gFlatScreenIsCinematic ? 0u : 1u,
        0u
    };

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = color;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    pass.depthAttachment.texture = depth;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    pass.depthAttachment.clearDepth = 0.0;
    pass.rasterizationRateMap =
        cp_drawable_get_rasterization_rate_map(gDrawable, eye);

    id<MTLRenderCommandEncoder> encoder =
        [gCommandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) return;

    cp_view_texture_map_t map = cp_view_get_view_texture_map(
        cp_drawable_get_view(gDrawable, eye));
    [encoder setViewport:cp_view_texture_map_get_viewport(map)];
    [encoder setRenderPipelineState:gMetalPanelPipeline];
    [encoder setDepthStencilState:gMetalPanelDepthState];
    [encoder setVertexBytes:&uniforms
                     length:sizeof(uniforms)
                    atIndex:0];
    [encoder setFragmentTexture:gFlatScreenMetalTexture atIndex:0];
    [encoder setFragmentBytes:&uniforms
                       length:sizeof(uniforms)
                      atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4];
    [encoder endEncoding];
}

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

void TBXR_visionOS_SetScreenCinematic(bool cinematic)
{
    gFlatScreenIsCinematic = cinematic;
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

    // Action-System aufsetzen.
    //
    // Auf Android und Windows steht dieser Aufruf in der Plattform-
    // Initialisierung (JKXR_SurfaceView.cpp, direkt nach TBXR_InitRenderer).
    // In unserer Fassung fehlte er vollständig — mit der Folge, dass gar keine
    // Eingabe ankam:
    //
    //   TBXR_InitActions fehlt -> kein actionSet
    //     -> TBXR_SyncActions überspringt xrSyncActions (if (actionSet))
    //       -> TBXR_visionOS_RefreshControllers läuft nie
    //         -> gControllers bleibt leer, keine Taste wird je gelesen
    //
    // Hier ist der richtige Ort: der LayerRenderer steht, ANGLE läuft, und die
    // Engine ist noch nicht gestartet.
    TBXR_InitActions();
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

    // cp_frame_query_drawables, nicht die Einzahlform.
    //
    // cp_frame_query_drawable ist seit visionOS 26.0 abgekündigt. Der Grund ist
    // nicht kosmetisch: die Mehrzahlform unterscheidet zwischen "keine Drawable"
    // und "Bild abgebrochen", und nur sie sagt, wie ein abgebrochenes Bild zu
    // behandeln ist.
    //
    // Ein abgebrochenes Bild darf NICHT beendet werden. Der Header ist dazu
    // unmissverständlich:
    //
    //   "If array count is 0, the frame has been cancelled as there are no
    //    drawables to draw to and the frame should be discarded and is invalid
    //    to access."
    //
    // Das vorherige cp_frame_end_submission auf genau diesem Pfad war deshalb
    // ein Zugriff auf ein ungültiges Bild, und CompositorServices beendet den
    // Prozess dafür hart:
    //
    //   CompositorNonUI  __BUG_IN_CLIENT__
    //   CompositorNonUI  cp_frame_end_submission
    //   JKXR             TBXR_FrameSetup()
    //
    // Ausgelöst wird der Pfad, sobald der Compositor ein Bild fallen lässt —
    // beim Kartenladen etwa, wenn die Engine lange nicht zeichnet.
    cp_drawable_array_t drawables = cp_frame_query_drawables(gFrame);
    if (!drawables || cp_drawable_array_get_count(drawables) == 0) {
        // Verwerfen heißt: nichts mehr am Bild aufrufen, auch kein
        // end_submission. Der Compositor räumt es selbst ab; der nächste
        // Durchlauf holt über query_next_frame ein frisches.
        //
        // ALOGV statt TRACE: TRACE schweigt ab dem dritten Bild, und dieses
        // Ereignis tritt gerade dann auf, wenn die Engine lange nicht zeichnet
        // — beim Kartenladen also. Genau dort muss es sichtbar sein.
        ALOGV("[Bild %d] Compositor hat das Bild abgebrochen — verworfen\n",
              gFrameCounter);
        gDrawable = nullptr;
        gFrame = nullptr;
        return;
    }
    gDrawable = cp_drawable_array_get_drawable(drawables, 0);

    // Das Gesamtsichtfeld für die Engine hinterlegen.
    //
    // Android tut das in TBXR_Common.cpp:2130, Windows in :1152 — in dieser
    // Fassung fehlte es, und vr.fov_x/fov_y blieben auf 0.
    //
    // Die Engine rechnet damit weiter, ohne sich zu beschweren:
    //
    //   cg_view.cpp:1425   fov_x = vr ? vr->fov_x : cg_fov.value;   -> 0
    //   CG_CalcFov         tan(0) = 0, danach eine Division dadurch
    //   cg_view.cpp:2074   speed = cg.refdef.fov_y / 75.0           -> NaN
    //   cgi_SetUserCmdValue(..., speed, ...)  -> cl.cgameSensitivity = NaN
    //   CL_MouseMove       mx = 0 * NaN = NaN, und die Wächterzeile
    //                      "if (!mx && !my) return;" greift nicht, weil sich
    //                      NaN nicht mit null vergleichen lässt
    //   CL_AdjustAngles    cl.viewangles[YAW] wird nur AUFSUMMIERT und ist
    //                      damit dauerhaft vergiftet
    //
    // Ergebnis war eine vollständig schwarze Spielwelt: AnglesToAxis macht aus
    // dem NaN-Yaw die Blickachse (nan, nan, gültig), der Rasterizer verwirft
    // NaN-Ecken stillschweigend, und die Engine meldet dabei keinen Fehler —
    // über tausend Flächen laufen sauber durch. Das HUD blieb sichtbar, weil
    // RB_SetGL2D sich seine eigene Modelview setzt.
    //
    // Gerechnet wird wie in der Android-Fassung: die waagerechte Ausdehnung
    // über BEIDE Augen (linker Rand des linken, rechter Rand des rechten), die
    // senkrechte aus einem Auge. Der Wert dient der Engine zum Aussortieren —
    // er soll großzügig sein, nicht exakt.
    {
        // Tangenten hier direkt aus der Projektionsmatrix, nicht über die
        // Hilfsfunktion weiter unten: die liegt in einem anonymen Namensraum,
        // und eine Vorwärtsdeklaration erzeugte dort eine zweite Funktion.
        const auto tangents = [&](size_t view, float *l, float *r,
                                  float *d, float *u) {
            const simd_float4x4 p = cp_drawable_compute_projection(
                gDrawable, cp_axis_direction_convention_right_up_back, view);
            const float sx = p.columns[0][0], ox = p.columns[2][0];
            const float sy = p.columns[1][1], oy = p.columns[2][1];
            *l = (ox - 1.0f) / sx;
            *r = (ox + 1.0f) / sx;
            *d = (oy - 1.0f) / sy;
            *u = (oy + 1.0f) / sy;
        };

        const size_t views = cp_drawable_get_view_count(gDrawable);
        if (views >= 1) {
            float l0, r0, d0, u0;
            tangents(0, &l0, &r0, &d0, &u0);
            float rRight = r0;
            if (views >= 2) {
                float l1, r1, d1, u1;
                tangents(1, &l1, &r1, &d1, &u1);
                rRight = r1;
            }
            const float deg = 180.0f / (float)M_PI;
            vr.fov_x = (fabsf(atanf(l0)) + fabsf(atanf(rRight))) * deg;
            vr.fov_y = (fabsf(atanf(u0)) + fabsf(atanf(d0))) * deg;
        }
    }

    // Die Geräte-/Kopfpose muss zur Präsentationszeit vorhergesagt werden.
    // trackableAnchorTime ist für Hand- und Zubehöranker gedacht. Wird es hier
    // verwendet, rendert die Kamera mit einer anderen Zeitbasis als die
    // Display-Time-Korrektur des Compositors; schnelle Kopfbewegungen werden
    // dann überkorrigiert und erzeugen Schlieren.
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

        // Stereo-Geometrie einmal ausmessen statt annehmen.
        //
        // Die Engine versetzt die Augen ausschließlich seitlich
        // (VectorMA in tr_cmds.cpp) und dreht sie nicht. Auf Geräten mit
        // gekippten Ansichten ist das falsch. Ob und wie stark diese Brille
        // kippt, steht in keiner Dokumentation — also messen.
        for (size_t v = 0; v < views && v < 2; ++v) {
            cp_view_t view = cp_drawable_get_view(gDrawable, v);
            const simd_float4x4 t = cp_view_get_transform(view);
            const simd_float3 pos = t.columns[3].xyz;
            const simd_float3 fwd = -t.columns[2].xyz;   // -Z ist die Blickrichtung
            ALOGV("[Stereo] Auge %zu: Position % .4f % .4f % .4f · "
                  "Blick % .4f % .4f % .4f",
                  v, pos.x, pos.y, pos.z, fwd.x, fwd.y, fwd.z);

            const simd_float4x4 p = cp_drawable_compute_projection(
                gDrawable, cp_axis_direction_convention_right_up_back, v);
            const float sx = p.columns[0][0], ox = p.columns[2][0];
            const float sy = p.columns[1][1], oy = p.columns[2][1];
            ALOGV("[Stereo] Auge %zu: tanL % .4f tanR % .4f tanD % .4f tanU % .4f",
                  v, (ox - 1.0f) / sx, (ox + 1.0f) / sx,
                  (oy - 1.0f) / sy, (oy + 1.0f) / sy);
        }
        if (views >= 2) {
            const simd_float3 f0 =
                -cp_view_get_transform(cp_drawable_get_view(gDrawable, 0)).columns[2].xyz;
            const simd_float3 f1 =
                -cp_view_get_transform(cp_drawable_get_view(gDrawable, 1)).columns[2].xyz;
            const float dot = simd_clamp(simd_dot(simd_normalize(f0),
                                                  simd_normalize(f1)), -1.0f, 1.0f);
            const simd_float3 p0 =
                cp_view_get_transform(cp_drawable_get_view(gDrawable, 0)).columns[3].xyz;
            const simd_float3 p1 =
                cp_view_get_transform(cp_drawable_get_view(gDrawable, 1)).columns[3].xyz;
            ALOGV("[Stereo] Kippwinkel %.2f Grad · Augenabstand %.4f m",
                  acosf(dot) * 180.0f / (float)M_PI, simd_length(p1 - p0));
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
            cp_time_to_cf_time_interval(cp_frame_timing_get_presentation_time(actual)),
            anchor);
        if (anchorStatus == ar_device_anchor_query_status_success) {
            // Pflicht für die Präsentation: ohne Geräteanker zeigt die
            // Compositor-Schicht auf diesem Pfad ausschließlich Passthrough.
            cp_drawable_set_device_anchor(gDrawable, anchor);

            gRawHeadTransform =
                ar_device_anchor_get_origin_from_anchor_transform(anchor);
            gRawHeadValid = true;

            // Die Pose weiterhin an Engine und Wandprojektion geben.
            TBXR_GetHMDOrientation(anchor);
            // visionOS 27 kann die Pose für die tatsächliche Darstellung auf
            // dem Passthrough-Display korrigieren. Die unkorrigierte physische
            // Pose zeigt bei schnellen Bewegungen sichtbar ein verzögertes
            // Nachsteuern; der Geräteanker selbst bleibt unverändert beim
            // Compositor, damit dessen Display-Time-Korrektur weiter greift.
            // Die korrigierte Variante gibt es für den Geräteanker NICHT.
            //
            // ar_..._get_origin_from_anchor_transform_with_correction existiert
            // im XROS-SDK nur für Bild-, Objekt- und Hand-Anker, nicht für
            // ar_device_anchor. Der Aufruf ließ sich deshalb nicht linken:
            //
            //   Undefined symbols: _ar_device_anchor_get_origin_from_anchor_
            //   transform_with_correction, referenced from TBXR_FrameSetup()
            //
            // @available prüft zur Laufzeit und hilft beim Linken nicht — dafür
            // bräuchte es schwaches Linken, und selbst dann fehlte das Symbol.
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

    // Kommen die Posen bis in die Winkel, aus denen der Menü-Cursor entsteht?
    // interactWithTouchScreen rechnet aus vr.weaponangles (dominante Hand)
    // beziehungsweise vr.offhandangles. Bleiben die null, ist die Kette
    // zwischen xrLocateSpace und JKXRs Eingabelogik unterbrochen.
    {
        static int n = 0;
        if ((++n % 90) == 0) {
            fprintf(stderr,
                    "[Winkel] Waffe %.1f %.1f %.1f · Nebenhand %.1f %.1f %.1f · "
                    "aktiv %d/%d · Menuhand rechts %d\n",
                    // weaponangles ist vec3_t[ANGLES_COUNT], also ZWEIDIMENSIONAL.
                    // vr.weaponangles[PITCH] wäre die Zeile ANGLES_DEFAULT als
                    // float* — mit %f ausgegeben undefiniert. Genau dieser
                    // Fehler hat eine Messung geliefert, die immer "0.0 0.0 0.0"
                    // zeigte, obwohl über den Inhalt nichts bekannt war.
                    vr.weaponangles[ANGLES_DEFAULT][PITCH],
                    vr.weaponangles[ANGLES_DEFAULT][YAW],
                    vr.weaponangles[ANGLES_DEFAULT][ROLL],
                    vr.offhandangles[ANGLES_DEFAULT][PITCH],
                    vr.offhandangles[ANGLES_DEFAULT][YAW],
                    vr.offhandangles[ANGLES_DEFAULT][ROLL],
                    (int)gAppState.TrackedController[0].Active,
                    (int)gAppState.TrackedController[1].Active,
                    (int)vr.menu_right_handed);
        }
    }
    TBXR_ProcessHaptics();
    gAppState.FrameSetup = true;
}

void TBXR_prepareEyeBuffer(int eye)
{
    // Das aktuelle Auge auch der Spiel-/Renderseite mitteilen, nicht nur intern.
    //
    // Android (TBXR_Common.cpp:2066) und Windows (:1080) tun das in derselben
    // Funktion als erste Zeile; in dieser Fassung fehlte sie.
    //
    // R_SetupProjection liest `vr->eye`, um die FOV-Tangenten des richtigen
    // Auges zu holen. Ohne diese Zeile bleibt der Wert stehen, und BEIDE Augen
    // rendern mit der Projektion desselben Auges.
    //
    // Das fällt nur deshalb so stark auf, weil die Frusta hier kräftig
    // asymmetrisch sind — gemessen auf diesem Gerät:
    //
    //   Auge 0: tanL -1.000  tanR +1.732   (-45° … +60°)
    //   Auge 1: tanL -1.732  tanR +1.000   (-60° … +45°)
    //
    // Die Achsen liegen also 15° auseinander. Nimmt ein Auge die Projektion des
    // anderen, schaut es sichtbar an der Szene vorbei. Der Kippwinkel der
    // Ansichten beträgt dagegen nur 1,13° und war NICHT die Ursache.
    gCurrentEye = eye;
    vr.eye = eye;
    gRenderingFlatScreen[eye] = false;
    TRACE("[Bild %d] prepareEyeBuffer Auge %d", gFrameCounter, eye);
    if (!gDrawable) return;

    // Zieltextur und Projektion gehören zum SELBEN Augenindex.
    //
    // Der Gegentest ist gelaufen: mit vertauschter Textur kehrt sich die
    // Disparität um. Auf dem Gerät äußert sich das als "der Fokuspunkt wirkt
    // invertiert", das HUD erscheint nur in einem Auge, und die Wand wandert
    // beim Drehen auf einer Umlaufbahn — jedes Auge bekommt die Geometrie, die
    // fürs andere berechnet wurde.
    //
    // Der Tausch schien kurzzeitig besser, das war aber unter der starken
    // Verzerrung der nicht wirksamen Rate-Map beurteilt, in der Stereo gar
    // nicht einschätzbar war.
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

    // DIAGNOSE: Rate-Map abschaltbar, Vorgabe AUS.
    //
    // Sie ist der letzte ungeprüfte Unterschied zwischen den beiden Zielen.
    // Der Zwischenpuffer, in den die Welt nachweislich rendert, hat keine; die
    // Augentextur, in der nur Clear und 2D ankommen, hat eine — und sie kommt
    // aus einem eigenen ANGLE-Patch, ist also der am wenigsten erprobte Teil
    // der Kette.
    //
    // Ohne Rate-Map muss auch die Ansicht auf die physische Texturgröße
    // zurück: der Compositor gibt sie in Screen-Koordinaten (5087x4081), die
    // Textur ist 2048x1984. Sonst läge nur eine Ecke des Bildes im Puffer.
    // Getestet: OHNE Rate-Map bleibt die Welt ebenfalls aus. Sie ist damit
    // nicht die Ursache, und der Normalzustand gilt wieder — sonst verfälscht
    // die abgeschaltete Foveation samt geänderter Bildschirmauflösung jede
    // weitere Messung (das HUD verlor dabei seine Weltstabilität).
    static const int useRateMap = 1;
    if (useRateMap) {
        ANGLESetDrawFramebufferRateMapMTL(
            (__bridge const void *)cp_drawable_get_rasterization_rate_map(gDrawable, eye));
    } else {
        ANGLESetDrawFramebufferRateMapMTL(nullptr);
        id<MTLTexture> phys = cp_drawable_get_color_texture(gDrawable, eye);
        if (phys) {
            TBXR_visionOS_SetScreenRes((int)phys.width, (int)phys.height);
            angle::Viewport(0, 0, (GLsizei)phys.width, (GLsizei)phys.height);
        }
    }


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
    GLboolean previousColorMask[4] = { GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE };
    GLfloat previousClearColor[4] = {};
    angle::GetBooleanv(GL_COLOR_WRITEMASK, previousColorMask);
    angle::GetFloatv(GL_COLOR_CLEAR_VALUE, previousClearColor);
    if (scissorWasEnabled) angle::Disable(GL_SCISSOR_TEST);

    // CompositorServices recycelt seine Drawable-Texturen. Ohne einen echten
    // Farb-Clear enthält die neue Pose deshalb weiterhin alle zuvor gezeichneten
    // Positionen der Welt-Wand (sichtbar als scharfer Stapel/Schlieren). Für
    // einen vollständigen Clear müssen Scissor aus und alle Farbkanäle offen
    // sein, unabhängig vom zuletzt von gl4es gecachten Rendererzustand.
    angle::ColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    angle::ClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    angle::Clear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    angle::ClearColor(previousClearColor[0], previousClearColor[1],
                      previousClearColor[2], previousClearColor[3]);
    angle::ColorMask(previousColorMask[0], previousColorMask[1],
                     previousColorMask[2], previousColorMask[3]);

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

    // Ein klassischer Screen-Layer (Menü, Ladebild, Video) wird nicht direkt
    // mit einer Weltmatrix in die Compositor-Textur gezeichnet. Zuerst entsteht
    // ein gewöhnliches flaches 2D-Bild; TBXR_finishEyeBuffer setzt es danach
    // mit der unveränderten ARKit-Kamera als Quad in die Welt.
    if (VR_UseScreenLayer() && ensureFlatScreenTarget()) {
        restoreTextureBinding();
        ANGLESetDrawFramebufferRateMapMTL(nullptr);
        angle::BindFramebuffer(GL_FRAMEBUFFER, gFlatScreenFramebuffer);
        angle::Viewport(0, 0, gFlatScreenWidth, gFlatScreenHeight);

        const GLboolean flatScissorWasEnabled = angle::IsEnabled(GL_SCISSOR_TEST);
        GLboolean flatColorMask[4] = { GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE };
        GLfloat flatClearColor[4] = {};
        angle::GetBooleanv(GL_COLOR_WRITEMASK, flatColorMask);
        angle::GetFloatv(GL_COLOR_CLEAR_VALUE, flatClearColor);
        if (flatScissorWasEnabled) angle::Disable(GL_SCISSOR_TEST);
        angle::ColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        angle::ClearColor(0.0f, 0.0f, 0.0f, 0.0f);
        angle::Clear(GL_COLOR_BUFFER_BIT);
        angle::ClearColor(flatClearColor[0], flatClearColor[1],
                          flatClearColor[2], flatClearColor[3]);
        angle::ColorMask(flatColorMask[0], flatColorMask[1],
                         flatColorMask[2], flatColorMask[3]);
        if (flatScissorWasEnabled) angle::Enable(GL_SCISSOR_TEST);
        gRenderingFlatScreen[eye] = true;
    }

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
    if (gRenderingFlatScreen[eye]) {
        vr.off_center_fov_x = 0.0f;
        vr.off_center_fov_y = 0.0f;
    } else {
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

    if (gRenderingFlatScreen[eye]) {
        // ANGLEs Warteschlange vollständig abschließen, bevor Metal dieselbe
        // geteilte Textur liest. Der finale Welt-Pass ist nun wirklich nativ:
        // keine zweite GL->Metal-Clipraumumrechnung mehr.
        angle::Finish();
        drawMetalScreenPanel(eye);
    } else {
        // Der klassische 2D-Renderer schreibt keine Tiefe. Für HUD-Inhalte im
        // normalen 3D-Pfad bleibt vorerst der bisherige Tiefenpass bestehen.
        //
        // Nicht die Ursache des fehlenden Vorspanntextes -- geprueft, indem sie
        // testweise wegblieb. Der Text kam trotzdem nicht; es lag am Verwerfen
        // der Rueckseiten und am Ausschnitt (tr_scene.cpp).
        drawScreenWallDepth(eye);
    }

    // gl4es reports its logical default framebuffer as 0.  Query ANGLE
    // directly here, after the engine rendered, to verify that the physical
    // binding still points at the imported compositor framebuffer.
    static int framebufferDiagnostics = 0;
    if (eye == 0 && framebufferDiagnostics < 8) {
        GLint actualFramebuffer = -1;
        angle::GetIntegerv(GL_FRAMEBUFFER_BINDING, &actualFramebuffer);
        const GLenum error = angle::GetError();
        ALOGV("[ANGLE FBO] frame=%d actual=%d compositor=%u flat=%u error=0x%04x",
              gFrameCounter, actualFramebuffer, gFramebuffer,
              gFlatScreenFramebuffer, error);
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

    // ---------------------------------------------------------------------
    // Sichtsonde über METAL statt über glReadPixels.
    //
    // glReadPixels liefert auf der importierten Drawable-Textur durchgehend
    // Nullen — es meldet nicht einmal den Clear, der auf dem Gerät sichtbar
    // ist. Damit war jede Messung darüber wertlos, und zwar unauffällig
    // wertlos: sie sagt immer "schwarz".
    //
    // Metal kommt an dieselbe Textur heran. Sie liegt in MTLStorageModePrivate,
    // also erst per Blit in einen sichtbaren Puffer kopieren.
    //
    // Gelesen wird das Ergebnis absichtlich ERST im nächsten Durchgang: sonst
    // müsste hier auf die GPU gewartet werden, und das verfälscht genau die
    // Zeitmessung, an der der Compositor die App beurteilt.
    if ((gFrameCounter % 90) == 0 || gProbePending) {
        id<MTLTexture> src = cp_drawable_get_color_texture(gDrawable, 0);

        if (gProbePending && gProbeStaging && gProbeCommands &&
            gProbeCommands.status == MTLCommandBufferStatusCompleted) {
            const int grid = 8;
            const NSUInteger w = gProbeStaging.width, h = gProbeStaging.height;
            char map[8 * 9 + 1];
            int at = 0, filled = 0, brightest = 0;
            // Das Format der Drawable ist NICHT 8-Bit.
            //
            // cp_drawable_get_color_texture liefert hier MTLPixelFormatRGBA16Float
            // (115) — acht Byte je Bildpunkt als Halbfloats. Vier Byte zu lesen
            // und als 0..255 zu deuten ergibt Unsinn, und zwar unauffälligen:
            // es kommt einfach "schwarz" heraus. Genau daran ist die vorherige
            // Fassung gescheitert, obwohl der Clear sichtbar auf dem Gerät war.
            const bool halfFloat =
                (gProbeStaging.pixelFormat == MTLPixelFormatRGBA16Float);
            const NSUInteger stride = halfFloat ? 8 : 4;
            for (int gy = 0; gy < grid; ++gy) {          // Zeile 0 = oben
                for (int gx = 0; gx < grid; ++gx) {
                    unsigned char raw[8] = {0};
                    MTLRegion r = MTLRegionMake2D(
                        gx * (w / grid) + (w / grid) / 2,
                        gy * (h / grid) + (h / grid) / 2, 1, 1);
                    [gProbeStaging getBytes:raw bytesPerRow:stride
                                 fromRegion:r mipmapLevel:0];
                    unsigned char px[4];
                    if (halfFloat) {
                        const __fp16 *f = (const __fp16 *)raw;
                        for (int c = 0; c < 4; ++c) {
                            float v = (float)f[c];
                            v = v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
                            px[c] = (unsigned char)(v * 255.0f + 0.5f);
                        }
                    } else {
                        memcpy(px, raw, 4);
                    }
                    const int sum = px[0] + px[1] + px[2];
                    if (sum > brightest) brightest = sum;
                    // Der Diagnose-Clear ist (0.25, 0, 0.45).
                    const bool isClear = (px[0] > 45 && px[0] < 85 &&
                                          px[1] < 25 && px[2] > 95 && px[2] < 135);
                    const bool content = (sum > 12 && !isClear);
                    map[at++] = content ? '#' : (isClear ? '.' : ' ');
                    if (content) ++filled;
                }
                map[at++] = '\n';
            }
            map[at] = 0;
            ALOGV("[Metal-Sicht] Bild %d, %lux%lu: %d/64 belegt, hellster %d\n%s",
                  gFrameCounter, (unsigned long)w, (unsigned long)h,
                  filled, brightest, map);
            gProbePending = false;
        }

        if (!gProbePending && src && (gFrameCounter % 90) == 0) {
            if (!gProbeStaging || gProbeStaging.width != src.width ||
                gProbeStaging.height != src.height) {
                MTLTextureDescriptor *d = [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:src.pixelFormat
                                                 width:src.width
                                                height:src.height
                                             mipmapped:NO];
                d.storageMode = MTLStorageModeShared;
                d.usage = MTLTextureUsageShaderRead;
                gProbeStaging = [cp_layer_renderer_get_device(gLayerRenderer)
                                    newTextureWithDescriptor:d];
            }
            if (gProbeStaging) {
                id<MTLBlitCommandEncoder> blit = [gCommandBuffer blitCommandEncoder];
                [blit copyFromTexture:src sourceSlice:0 sourceLevel:0
                         sourceOrigin:MTLOriginMake(0, 0, 0)
                           sourceSize:MTLSizeMake(src.width, src.height, 1)
                            toTexture:gProbeStaging destinationSlice:0
                     destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
                [blit endEncoding];
                gProbeCommands = gCommandBuffer;
                gProbePending = true;
            }
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
    // Jedes abgegebene Bild zählt — auch die der Pumpe. Sie misst dagegen.
    gLastFrameSubmitted = CACurrentMediaTime();
}

// ---------------------------------------------------------------------------
// Bildpumpe für lange Ladephasen
//
// visionOS beendet eine App, die einen Immersive Space offen hält und aufhört,
// Bilder abzugeben. Das trifft id Tech 3 an einer Stelle hart: RE_LoadWorldMap
// lädt die Karte synchron und lädt dabei hunderte Texturen hoch, ohne die
// Hauptschleife auch nur einmal zu erreichen. Belegt durch den Absturzbericht:
//
//   RE_LoadWorldMap → R_FindShader → R_FindImageFile → R_CreateImage
//     → glTexImage2D → ANGLE → Metal replaceRegion → waitUntilCompleted
//     ... SIGKILL
//
// Diese Funktion gibt zwischendurch ein leeres Bild ab. Gezeichnet wird nichts:
// TBXR_prepareEyeBuffer löscht Farbe und Tiefe bereits selbst, und ein
// gelöschtes Bild genügt dem Compositor vollauf — es geht nur darum, dass
// überhaupt eines kommt.
//
// Aufgerufen wird sie aus R_CreateImage, also je Textur. Die Entscheidung, ob
// tatsächlich ein Bild fällig ist, liegt bewusst HIER und nicht dort: der
// Renderer soll nichts über Bildraten wissen müssen.
void TBXR_visionOS_PumpLoadingFrame(void)
{
    if (!gLayerRenderer) return;

    // Läuft bereits ein Bild, gehört es der Hauptschleife — dann ist die Engine
    // ohnehin am Zeichnen und die Pumpe überflüssig. Ein zweites Bild zu holen
    // wäre genau der Fehler, den der Wächter in TBXR_FrameSetup abfängt.
    if (gAppState.FrameSetup) return;

    // Schutz gegen Rekursion: prepareEyeBuffer darf nicht in einer Pumpe landen,
    // die selbst wieder eine Textur anlegt.
    static bool pumping = false;
    if (pumping) return;

    // Nur einspringen, wenn die Engine WIRKLICH stillsteht.
    //
    // Der erste Entwurf pumpte alle 8 ms, also mit voller Bildrate. Das hält
    // die App zwar am Leben, schiebt aber ein leeres Bild zwischen jedes Bild,
    // das die Engine selbst zeichnet — und der Ladebildschirm flackerte heftig.
    //
    // Die Engine zeichnet während des Ladens durchaus, nur unregelmäßig. Es
    // genügt daher, den Abstand zum zuletzt ABGEGEBENEN Bild zu messen, egal
    // von wem es kam: solange die Engine liefert, schweigt die Pumpe ganz.
    //
    // Eine Sekunde ist reichlich Abstand zur Schwelle des Systems — beobachtet
    // wurde die Beendigung nach rund zehn Sekunden ohne Bild.
    const double now = CACurrentMediaTime();
    if (now - gLastFrameSubmitted < 1.0) return;

    pumping = true;
    TBXR_FrameSetup();
    if (gDrawable) {
        TBXR_prepareEyeBuffer(0);
        TBXR_finishEyeBuffer(0);
        TBXR_prepareEyeBuffer(1);
        TBXR_finishEyeBuffer(1);
        TBXR_submitFrame();
    }
    pumping = false;
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

    // NICHT die Brillenprojektion aufzwingen, wenn die Szene gar nicht in der
    // Welt steht. Beide Wächter stehen wörtlich so in der Android-Fassung
    // (JKXR_SurfaceView.cpp:475 ff.) und fehlten hier.
    //
    // Gibt diese Funktion false zurück, baut die Engine ihre eigene Projektion
    // aus der Spiel-FOV (R_SetupProjection) — und genau die brauchen die
    // 3D-Vorschauen im Menü: Charakterauswahl und Lichtschwert rendern ein
    // Modell in ein kleines Rechteck der Oberfläche, mit RDF_NOWORLDMODEL.
    //
    // Für dieses Flag überspringt R_SetupProjection den Tangenten-Pfad und
    // landet hier. Ohne die Wächter bekam die Vorschau das 105°-Frustum der
    // Brille samt Achsversatz — das Modell lag weit außerhalb des Rechtecks und
    // war schlicht nicht zu sehen.
    if (vr.cin_camera && !vr.immersive_cinematics) return false;
    if (vr.using_screen_layer) return false;

    // Dieselbe Falle wie in VR_GetFovTangentsForEye: -1 steht für "Mitte" und
    // würde als size_t zu SIZE_MAX. Hier genügt Auge 0 — diese Funktion ist
    // nur der Rückfallweg, und der Erfassungsdurchgang holt seine Tangenten
    // ohnehin über die Vereinigung beider Frusta.
    if (eye < 0) eye = 0;

    // Der Compositor liefert die Projektion passend zur aktuellen Kopfpose und
    // Linsengeometrie — sie selbst aus FOV-Winkeln aufzubauen wäre ungenauer.
    //
    // right_DOWN_forward, nicht right_up_back — hier gezielt abweichend vom
    // Rest der Datei.
    //
    // Diese Matrix ist die einzige, die in GL geladen wird; die übrigen
    // Aufrufe von cp_drawable_compute_projection speisen Metal-Pässe und
    // bleiben bei right_up_back.
    //
    // GL adressiert einen Framebuffer von UNTEN, Metal zeigt Speicherzeile 0
    // OBEN. Mit +Y=oben landet daher die Oberkante des Bildes in der letzten
    // Zeile und wird unten angezeigt — das Bild steht auf dem Kopf. Mit
    // +Y=unten stimmt es.
    //
    // "back" bleibt: die Wicklung wird bewusst NICHT hier ausgeglichen.
    //
    // Diese Funktion ist nur der Rückfallweg. Für die Welt baut die Engine ihre
    // Projektion selbst aus den FOV-Tangenten (R_SetupProjection in
    // tr_main.cpp) und spiegelt Y dort. Beide Wege müssen deshalb dieselbe
    // Wicklung erzeugen, sonst stimmt sie in genau einem der beiden Fälle nicht
    // — und welcher greift, hängt an RDF_NOWORLDMODEL, also an der Szene.
    //
    // Ausgeglichen wird einmal zentral über glFrontFace(GL_CW).
    simd_float4x4 matrix = cp_drawable_compute_projection(
        gDrawable, cp_axis_direction_convention_right_down_back, eye);

    // Zoom (Fernglas, Scharfschützenmodus) skaliert die beiden ersten Spalten.
    matrix.columns[0] *= zZoomX;
    matrix.columns[1] *= zZoomY;

    memcpy(projection, &matrix, sizeof(float) * 16);
    return true;
}

// Tangenten eines Auges aus seiner Projektionsmatrix zurückrechnen.
static void tangentsForView(size_t view, float *tanLeft, float *tanRight,
                            float *tanDown, float *tanUp)
{
    const simd_float4x4 p = cp_drawable_compute_projection(
        gDrawable, cp_axis_direction_convention_right_up_back, view);
    // Herleitung, weil das Vorzeichen von ox/oy hier zweimal falsch war:
    //
    //   x_clip = sx·x_e + ox·z_e        w_clip = -z_e
    //   ndc_x  = (sx·x_e + ox·z_e) / (-z_e) = sx·tan - ox   mit tan = x_e/(-z_e)
    //
    //   linker Rand  (ndc_x = -1):  tanLeft  = (ox - 1) / sx
    //   rechter Rand (ndc_x = +1):  tanRight = (ox + 1) / sx
    //
    // Mit (-1 - ox)/sx statt (ox - 1)/sx kippt das Vorzeichen des Versatzes,
    // und das Frustum wird horizontal GESPIEGELT: aus den echten -60°…+45° des
    // linken Auges werden -45°…+60°, also die Geometrie des rechten.
    //
    // Auf dem Gerät äußerte sich das als unmögliche Fusion — der Fokuspunkt
    // wirkte invertiert. Ein Tausch der Augentexturen schien deshalb zu helfen,
    // kompensierte aber nur die Hälfte des Fehlers. Bei Y dasselbe, sichtbar
    // als Verzerrung beim Hoch- und Runterschauen.
    const float sx = p.columns[0][0], ox = p.columns[2][0];
    const float sy = p.columns[1][1], oy = p.columns[2][1];
    *tanLeft  = (ox - 1.0f) / sx;
    *tanRight = (ox + 1.0f) / sx;
    *tanDown  = (oy - 1.0f) / sy;
    *tanUp    = (oy + 1.0f) / sy;
}

bool VR_GetFovTangentsForEye(int eye, float *tanLeft, float *tanRight,
                             float *tanUp, float *tanDown)
{
    if (!gDrawable) return false;

    // eye < 0 heißt "Mitte" und MUSS abgefangen werden.
    //
    // R_SetupProjection übergibt -1, wenn der Stereo-Replay seinen zentralen
    // Erfassungsdurchgang zeichnet (tr_main.cpp). Ungeprüft landet die -1 als
    // size_t in cp_drawable_compute_projection — also als SIZE_MAX und damit
    // als ungültiger View-Index. Die Matrix ist dann Unsinn, es überlebt keine
    // Fläche das Aussortieren, und der Replay spielt anschließend ein leeres
    // Kommandoband ab: das Spiel bleibt schwarz.
    //
    // Kamerafahrten fielen nicht darauf herein, weil sie ohne Replay direkt
    // pro Auge zeichnen und dort 0 oder 1 übergeben. Genau deshalb war das
    // eine sichtbar und das andere nicht.
    //
    // Für die Mitte ist die VEREINIGUNG beider Augenfrusta richtig, nicht das
    // Frustum eines der beiden: der Erfassungsdurchgang sammelt die Flächen
    // für BEIDE Augen ein. Nimmt man nur eines, fehlen später am Rand des
    // anderen Auges genau die Flächen, die dort sichtbar wären.
    if (eye < 0) {
        const size_t views = cp_drawable_get_view_count(gDrawable);
        if (views == 0) return false;

        float l, r, d, u;
        tangentsForView(0, &l, &r, &d, &u);
        for (size_t v = 1; v < views; ++v) {
            float l2, r2, d2, u2;
            tangentsForView(v, &l2, &r2, &d2, &u2);
            l = fminf(l, l2);
            r = fmaxf(r, r2);
            d = fminf(d, d2);
            u = fmaxf(u, u2);
        }
        *tanLeft = l; *tanRight = r; *tanDown = d; *tanUp = u;
        return true;
    }

    simd_float4x4 p = cp_drawable_compute_projection(
        gDrawable, cp_axis_direction_convention_right_up_back, eye);

    // Aus einer Projektionsmatrix zurückgerechnet: die Tangenten stecken in den
    // Elementen [0][0]/[0][2] beziehungsweise [1][1]/[1][2].
    const float sx = p.columns[0][0], ox = p.columns[2][0];
    const float sy = p.columns[1][1], oy = p.columns[2][1];
    *tanLeft  = (ox - 1.0f) / sx;
    *tanRight = (ox + 1.0f) / sx;
    *tanDown  = (oy - 1.0f) / sy;
    *tanUp    = (oy + 1.0f) / sy;
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
    const float ipd = simd_distance(lt.columns[3].xyz, rt.columns[3].xyz);

    // Spieleinheiten, nicht Meter.
    //
    // Der Rückgabewert geht in tr_cmds.cpp direkt in
    //
    //   VectorMA( refdef.vieworg, sep, refdef.viewaxis[1], refdef.vieworg );
    //
    // also in Weltkoordinaten der Engine. Ohne worldScale wären es rund 0,03
    // Einheiten statt 1,1 — praktisch kein Versatz. Beide Augen rendern dann
    // von derselben Stelle, aber mit den stark asymmetrischen Frusta der
    // Brille (gemessen -45°…+60° links, -60°…+45° rechts). Die Bilder liegen
    // dadurch rund 15° auseinander, ohne dass eine Parallaxe das erklärt —
    // genau das Gefühl, ein Auge schaue in eine andere Richtung.
    //
    // VORZEICHEN: positiv für Auge 0. viewaxis[1] ist in id Tech 3 der LINKS-
    // Vektor, das linke Auge muss also nach links. Die Fassung davor hatte es
    // umgekehrt und vertauschte damit effektiv die Augen. Der Rückfallweg der
    // Engine direkt daneben zeigt dieselbe Konvention:
    //
    //   sep = ( eye == 0 ? 0.5f : -0.5f ) * stereoSeparation * worldScale;
    //
    // und die Android-Fassung ebenso (JKXR_SurfaceView.cpp:588).
    float worldScale = 33.5f;
    cvar_t *worldScaleCvar = Cvar_Get("cg_worldScale", "33.5", 0);
    if (worldScaleCvar) {
        worldScale = worldScaleCvar->value;
    }

    return (eye == 0 ? 0.5f : -0.5f) * ipd * worldScale;
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
// Die Wand wird beim Öffnen einmal vor dem Benutzer im ARKit-Weltursprung
// eingerastet. Danach bewegt sie sich nicht mehr mit der Kopfpose.
// ---------------------------------------------------------------------------

extern "C" bool VR_GetScreenWall(int eye, float *projection16, float *modelview16)
{
    if (!gDrawable) return false;
    // Screen-Layer werden jetzt orthografisch in gFlatScreenTexture erzeugt.
    // Die Weltprojektion passiert anschließend einmal zentral im direkten
    // Panel-Pass und darf hier nicht ein zweites Mal angewendet werden.
    if (VR_UseScreenLayer()) return false;
    if (eye < 0 || eye > 1) eye = 0;

    const float distance = 2.0f;
    const float width = 2.4f;
    const float height = width * (480.0f / 640.0f);

    // right_DOWN_back, wie überall dort, wo in die Augentextur gezeichnet wird.
    //
    // Diese Matrix geht direkt per qglLoadMatrixf in GL (RB_SetGL2D) und
    // umgeht damit BEIDE Stellen, an denen sonst die Y-Achse gedreht wird:
    // den Tausch von ymin/ymax in R_SetupProjection und den Ortho-Wrapper
    // JKXR_visionOS_Ortho. Sie muss die Umkehr deshalb selbst mitbringen.
    //
    // Ohne sie ist die Wand gegenüber dem Rest der Szene gespiegelt. Das fällt
    // im Stand kaum auf — die Wand steht ja an der richtigen Stelle —, aber
    // eine Spiegelung und eine Drehung vertauschen sich nicht: sobald der Kopf
    // geneigt wird, dreht sich das Bild nicht mit, sondern verformt sich.
    simd_float4x4 proj = cp_drawable_compute_projection(
        // Auf right_DOWN_back umgestellt: dieselbe Konvention, mit der die
        // Welt-Szene gezeichnet wird (VR_GetVRProjection). Die Wand lief als
        // einzige auf right_up_back, und der Kommentar hier nennt genau das
        // gemessene Symptom -- beim Neigen dreht sich das Bild nicht mit,
        // sondern verformt sich.
        // ERWARTET: das Bild steht damit zunaechst auf dem Kopf. Das ist der
        // Preis dafuer, nur EINEN Faktor zu aendern; die Orientierung kommt im
        // naechsten Schritt ueber das Vorzeichen in der scale-Matrix.
        gDrawable, cp_axis_direction_convention_right_down_back, eye);
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

        // Welt-aus-Wand: X zeigt nach rechts, Y nach oben und -Z zur
        // Vorderseite der Wand. Die Transformation wird nur hier berechnet;
        // spätere Kopfbewegungen ändern sie nicht mehr.
        gWallTransform = matrix_identity_float4x4;
        gWallTransform.columns[0] = (simd_float4){right.x, right.y, right.z, 0.0f};
        gWallTransform.columns[1] = (simd_float4){up.x, up.y, up.z, 0.0f};
        gWallTransform.columns[2] = (simd_float4){-forward.x, -forward.y, -forward.z, 0.0f};
        simd_float3 wallCentre = headPos + forward * distance;
        gWallTransform.columns[3] =
            (simd_float4){wallCentre.x, wallCentre.y, wallCentre.z, 1.0f};
        gWallSnapped = true;
    }

    // Bildschirmkoordinaten (0..640, 0..480) in Wandkoordinaten (Meter):
    //   x = (sx/640 - 0.5) * width
    //   y = (0.5 - sy/480) * height      (y läuft in 2D nach unten)
    // Y-Richtung der Wand.
    //
    // Die Orientierung des 2D-Inhalts hängt an ZWEI Größen: hier und an der
    // Achsenkonvention der Projektion. Die Konvention wurde in beiden Varianten
    // geprüft (right_up_back und right_down_back) — das Bild stand beide Male
    // auf dem Kopf. Damit kann es nicht an ihr liegen, sondern nur an dieser
    // Zeile.
    //
    // Positiv statt negativ: Bildschirm-y läuft nach unten, Wand-Y nach oben.
    // Zusammen mit der Verschiebung darunter landet die Bildschirmoberkante
    // (y = 0) damit an der Wandoberkante.
    //
    // Der Tiefenpass (drawScreenWallDepth) ist davon nicht betroffen: er
    // zeichnet ein symmetrisches Viereck ohne diese Matrix, und seine
    // Tiefenwerte ändern sich durch eine Spiegelung nicht.
    simd_float4x4 scale = matrix_identity_float4x4;
    scale.columns[0].x =  width / 640.0f;
    scale.columns[1].y =  height / 480.0f;
    scale.columns[3].x = -width * 0.5f;
    scale.columns[3].y = -height * 0.5f;

    // cp_view_get_transform ist Gerät-aus-Auge. Mit der vollständigen
    // Welt-aus-Gerät-Pose entsteht Welt-aus-Auge; deren Inverse bewegt die
    // Projektion im Sichtfeld entgegen der Kopfbewegung und hält die Wand im
    // ARKit-Weltursprung fest.
    simd_float4x4 viewTf = cp_view_get_transform(cp_drawable_get_view(gDrawable, eye));
    simd_float4x4 originFromDevice = screenWallOriginFromDevice();
    simd_float4x4 originFromView = simd_mul(originFromDevice, viewTf);

    simd_float4x4 viewFromOrigin = simd_inverse(originFromView);
    simd_float4x4 mv = simd_mul(simd_mul(viewFromOrigin, gWallTransform), scale);
    memcpy(modelview16, &mv, sizeof(float) * 16);

    // Kernfrage, direkt gemessen: enthält die fertige Modelview-Matrix die
    // Kopfdrehung? Wenn ja, muss sich der Wandmittelpunkt im Augenraum beim
    // Kopfdrehen bewegen. Bleibt er stehen, fehlt die Rotation — dann liegt es
    // nicht am Compositor, sondern an unserer Rechnung.
    //
    // Ausgegeben wird die Wandmitte (Bildschirmmitte 320/240) im Augenraum.
    // Wandmitte im Augenraum UND als Bildposition, für beide Augen.
    //
    // "Im linken Auge ganz rechts, im rechten ganz links" ist der Richtung nach
    // korrekte Parallaxe — aber viel zu stark. Bei 2 m Wandabstand und 6,4 cm
    // Augenabstand wären es keine 1°. Die Zahlen trennen die beiden Fälle:
    //
    //   ndc_x knapp auseinander   Parallaxe stimmt, das Problem liegt woanders
    //   ndc_x weit auseinander    die Wand steht zu nah oder der Versatz ist
    //                             falsch skaliert
    //   ndc_x mit falschem
    //   Vorzeichen                die Augen bekommen vertauschte Geometrie
    //
    // Zusätzlich ndc_y für die Frage der Spiegelung: die Oberkante des
    // Bildschirms (y = 0) muss im Bild OBEN landen.
    {
        // Beide Augen MÜSSEN aus demselben Bild stammen.
        //
        // RB_SetGL2D läuft mehrfach je Bild und nicht zwingend gleich oft für
        // beide Augen. Zwei unabhängige Zähler liefern deshalb Zeilen aus
        // verschiedenen Bildern — mit Kopfbewegung dazwischen. Genau daraus
        // entstand der scheinbare Widerspruch, die Wandmitte liege nur 0,037 m
        // statt 0,063 m auseinander: verglichen wurden zwei Kopfposen.
        //
        // Deshalb wird die Probe von Auge 0 gemerkt und erst ausgegeben, wenn
        // Auge 1 im GLEICHEN gFrameCounter ankommt.
        static int lastFrame = -1;
        static int sampleFrame = -1;
        static simd_float4 sampleCentre = { 0, 0, 0, 0 };
        static simd_float3 sampleView = { 0, 0, 0 };
        static float sampleNdcX = 0.0f;
        const bool pairReady = (eye == 1 && sampleFrame == gFrameCounter);
        if (eye == 0 && gFrameCounter != lastFrame && (gFrameCounter % 30) == 0) {
            lastFrame = gFrameCounter;
            sampleFrame = gFrameCounter;
        }
        if (eye == 0 || pairReady) {
            const simd_float4 centre =
                simd_mul(mv, (simd_float4){320.0f, 240.0f, 0.0f, 1.0f});
            const simd_float4 clipC = simd_mul(proj, centre);
            const float ndcX = clipC.w != 0.0f ? clipC.x / clipC.w : 0.0f;

            if (eye == 0) {
                sampleCentre = centre;
                sampleView   = viewTf.columns[3].xyz;
                sampleNdcX   = ndcX;
            } else {
                // Erst jetzt ausgeben, mit beiden Proben aus demselben Bild.
                const simd_float3 dEye = centre.xyz - sampleCentre.xyz;
                const simd_float3 dView = viewTf.columns[3].xyz - sampleView;

                // Ist originFromView wirklich starr? Eine Rotation hat
                // Spaltenlängen 1. Weicht das ab, steckt eine Skalierung drin,
                // und dann darf die Länge tatsächlich schrumpfen.
                const float c0 = simd_length(originFromView.columns[0].xyz);
                const float c1 = simd_length(originFromView.columns[1].xyz);
                const float c2 = simd_length(originFromView.columns[2].xyz);

                ALOGV("[Wand] Bild %d · Augenabstand laut Compositor %.4f · "
                      "Wandmitte auseinander %.4f · ndc %.3f vs %.3f · "
                      "Spalten von originFromView %.4f %.4f %.4f\n",
                      gFrameCounter, simd_length(dView), simd_length(dEye),
                      sampleNdcX, ndcX, c0, c1, c2);
                sampleFrame = -1;
            }
        }
    }

    return true;
}

/// Lässt die Wand beim nächsten Bild neu einrasten — etwa wenn Menü oder
/// Video neu geöffnet werden, damit sie wieder vor dem Spieler steht.
extern "C" void VR_ResnapScreenWall(void)
{
    gWallSnapped = false;
    gPanelSnapped = false;
}

extern "C" int VR_GetCurrentEye(void)
{
    return gCurrentEye;
}
