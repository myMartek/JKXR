#if !defined(vrcommon_h)
#define vrcommon_h

#include "qcommon/q_shared.h"
#include "qcommon/qcommon.h"

#include "VrClientInfo.h"

#ifdef _WIN32
#include "windows/TBXR_Common.h"
#elif defined(__APPLE__)
#include "visionos/TBXR_Common.h"
#else
#include "android/TBXR_Common.h"
#endif


extern long long global_time;
extern int ducked;
extern vr_client_info_t vr;

float length(float x, float y);
float nonLinearFilter(float in);
bool between(float min, float val, float max);
void rotateAboutOrigin(float v1, float v2, float rotation, vec2_t out);
void QuatToYawPitchRoll(XrQuaternionf q, vec3_t rotation, vec3_t out);
void handleTrackedControllerButton(ovrInputStateTrackedRemote * trackedRemoteState, ovrInputStateTrackedRemote * prevTrackedRemoteState, uint32_t button, int key);
void interactWithTouchScreen(float menuYaw, vec3_t controllerAngles);
#if defined(JKXR_VISIONOS)
void menuGamepadNavigation(const ovrInputStateTrackedRemote *linksNeu,
                           const ovrInputStateTrackedRemote *rechtsNeu,
                           const ovrInputStateTrackedRemote *rechtsAlt);
extern "C" bool TBXR_visionOS_GamepadFallback(void);
extern "C" bool TBXR_visionOS_GamepadButton(const char *name);
extern "C" void TBXR_visionOS_GamepadDpad(int *x, int *y);
extern "C" void TBXR_visionOS_GamepadSwing(void);

/// Laesst die 2D-Tafel beim naechsten Bild neu vor dem Spieler einrasten.
///
/// Definiert in visionos/TBXR_Common.mm. Die Erklaerung fehlte hier, und
/// deshalb war die Funktion aus dem Eingabecode gar nicht erreichbar --
/// im ganzen Baum stand jahrelang nur ihre Definition, kein Aufruf.
extern "C" void VR_ResnapScreenWall(void);
#endif

#endif //vrcommon_h