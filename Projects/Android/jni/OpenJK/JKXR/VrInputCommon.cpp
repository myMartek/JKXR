/************************************************************************************

Content		:	Handles common controller input functionality
Created		:	September 2019
Authors		:	Simon Brown

*************************************************************************************/

#include "VrInput.h"

#include <qcommon/qcommon.h>
#include <qcommon/q_platform.h>
// A_CURSOR_UP und die uebrigen Tastencodes. VrInputDefault.cpp bindet die
// Datei ohnehin ein; hier wird sie gebraucht, seit die Menuebedienung mit
// Gamepad Tasten statt Mausbewegungen schickt.
#include <client/keycodes.h>

cvar_t	*vr_turn_mode;
cvar_t	*vr_turn_angle;
cvar_t	*vr_positional_factor;
cvar_t	*vr_walkdirection;
cvar_t	*vr_3rdperson_digital_direction;
cvar_t	*vr_weapon_pitchadjust;
cvar_t	*vr_saber_pitchadjust;
cvar_t	*vr_control_scheme;
cvar_t	*vr_virtual_stock;
cvar_t	*vr_switch_sticks;
cvar_t	*vr_immersive_cinematics;
cvar_t	*vr_screen_dist;
cvar_t	*vr_weapon_velocity_trigger;
cvar_t	* vr_scope_engage_distance;
cvar_t	*vr_force_velocity_trigger;
cvar_t	*vr_force_distance_trigger;
cvar_t	*vr_two_handed_weapons;
cvar_t	*vr_force_motion_controlled;
cvar_t	*vr_force_motion_push;
cvar_t	*vr_force_motion_pull;
cvar_t	*vr_motion_enable_saber;
cvar_t	* vr_always_run;
cvar_t	*vr_crouch_toggle;
cvar_t  *vr_irl_crouch_enabled;
cvar_t  *vr_irl_crouch_to_stand_ratio;
cvar_t	*vr_saber_block_debounce_time;
cvar_t	*vr_haptic_intensity;
cvar_t  *vr_comfort_vignette;
cvar_t  *vr_saber_3rdperson_mode;
cvar_t  *vr_vehicle_use_hmd_direction;
cvar_t  *vr_vehicle_use_3rd_person;
cvar_t  *vr_vehicle_use_controller_for_speed;
cvar_t  *vr_gesture_triggered_use;
cvar_t  *vr_use_gesture_boundary;
cvar_t  *vr_align_weapons;
cvar_t  *vr_refresh;
cvar_t  *vr_super_sampling;
cvar_t  *vr_engage_trigger;
cvar_t  *vr_release_trigger;
cvar_t  *vr_engage_trigger_index;
cvar_t  *vr_release_trigger_index;

ovrInputStateTrackedRemote leftTrackedRemoteState_old;
ovrInputStateTrackedRemote leftTrackedRemoteState_new;
ovrTrackedController leftRemoteTracking_new;
ovrInputStateTrackedRemote rightTrackedRemoteState_old;
ovrInputStateTrackedRemote rightTrackedRemoteState_new;
ovrTrackedController rightRemoteTracking_new;

float remote_movementSideways;
float remote_movementForward;
float remote_movementUp;
float positional_movementSideways;
float positional_movementForward;
long long global_time;
int ducked;
vr_client_info_t vr;

extern ovrApp gAppState;


//keys.h
void Sys_QueEvent( int time, sysEventType_t type, int value, int value2, int ptrLength, void *ptr );
void handleTrackedControllerButton(ovrInputStateTrackedRemote * trackedRemoteState, ovrInputStateTrackedRemote * prevTrackedRemoteState, uint32_t button, int key)
{
    if ((trackedRemoteState->Buttons & button) != (prevTrackedRemoteState->Buttons & button))
    {
        Sys_QueEvent( 0, SE_KEY, key, (trackedRemoteState->Buttons & button) != 0, 0, NULL );
    }
}

void rotateAboutOrigin(float x, float y, float rotation, vec2_t out)
{
    out[0] = cosf(DEG2RAD(-rotation)) * x  +  sinf(DEG2RAD(-rotation)) * y;
    out[1] = cosf(DEG2RAD(-rotation)) * y  -  sinf(DEG2RAD(-rotation)) * x;
}

float length(float x, float y)
{
    return sqrtf(powf(x, 2.0f) + powf(y, 2.0f));
}

#define NLF_DEADZONE 0.1
#define NLF_POWER 2.2

float nonLinearFilter(float in)
{
    float val = 0.0f;
    if (in > NLF_DEADZONE)
    {
        val = in > 1.0f ? 1.0f : in;
        val -= NLF_DEADZONE;
        val /= (1.0f - NLF_DEADZONE);
        val = powf(val, NLF_POWER);
    }
    else if (in < -NLF_DEADZONE)
    {
        val = in < -1.0f ? -1.0f : in;
        val += NLF_DEADZONE;
        val /= (1.0f - NLF_DEADZONE);
        val = -powf(fabsf(val), NLF_POWER);
    }

    return val;
}

void sendButtonActionSimple(const char* action)
{
    char command[256];
    snprintf( command, sizeof( command ), "%s\n", action );
    Cbuf_AddText( command );
}

bool between(float min, float val, float max)
{
    return (min < val) && (val < max);
}

void sendButtonAction(const char* action, long buttonDown)
{
    char command[256];
    snprintf( command, sizeof( command ), "%s\n", action );
    if (!buttonDown)
    {
        command[0] = '-';
    }
    Cbuf_AddText( command );
}

#ifndef _WIN32
void PortableMouseAbs(float x,float y);
#else
void PortableMouseAbs(float x, float y)
{
    int absx = 0, absy = 0;
    absx = x * 640;
    absy = y * 480;

    CL_MouseEvent(absx, absy, 0);
}
#endif

float clamp(float _min, float _val, float _max)
{
    return fmax(fmin(_val, _max), _min);
}

void interactWithTouchScreen(float menuYaw, vec3_t controllerAngles) {
    float cursorX = -sinf(DEG2RAD(controllerAngles[YAW] - menuYaw)) + 0.5f;
    float cursorY = (float)(controllerAngles[PITCH] / 90.0) + 0.5f;

    PortableMouseAbs(cursorX, cursorY);
}

#if defined(JKXR_VISIONOS)
extern "C" bool TBXR_visionOS_GamepadFallback(void);

/// Menuebedienung mit einem gewoehnlichen Gamepad.
///
/// Der uebliche Weg (interactWithTouchScreen) rechnet den Cursor aus dem WINKEL
/// des Controllers. Ein Gamepad hat keinen: es wird von ARKit nicht verfolgt,
/// die Winkel stehen auf NaN -- auf dem Geraet gemessen -- und der Cursor landet
/// nirgends. Mit einem DualSense uebersprang die Menuetaste noch, danach war
/// nichts mehr bedienbar.
///
/// Hier stand zuerst eine Tastenbedienung: Stick auf A_CURSOR_UP/DOWN,
/// Bestaetigen auf A_ENTER. Sie funktionierte bis kurz vors Ziel -- gemessen
/// wanderte der Fokus ueber die richtigen Schaltflaechen und A_ENTER fand
/// "newgamebutton" samt seiner Aktion --, aber der Menuewechsel blieb aus.
/// Statt diesem Eigensinn weiter nachzugehen, bewegt der Stick nun den Cursor.
/// Das ist der Weg, den die Menues ohnehin erwarten und der mit den
/// Sense-Controllern seit jeher traegt; hier kommt er nur aus einer anderen
/// Quelle.
void menuGamepadNavigation(const ovrInputStateTrackedRemote *linksNeu,
                           const ovrInputStateTrackedRemote *rechtsNeu,
                           const ovrInputStateTrackedRemote *rechtsAlt)
{
    if (!TBXR_visionOS_GamepadFallback()) return;

    // Der Cursor liegt in Anteilen der Flaeche, 0..1, und faengt in der Mitte
    // an. Er bleibt zwischen den Bildern stehen -- ein Zeiger, kein Ausschlag.
    static float x = 0.5f, y = 0.5f;

    // Totzone, sonst wandert der Cursor bei einem ruhenden Stick von selbst.
    // Analogsticks liefern auch in Ruhe selten genau null.
    const float totzone = 0.15f;
    // Der LINKE Stick fuehrt den Zeiger. Nicht der dominante: am Gamepad liegt
    // die Fortbewegung links, und der Zeiger gehoert an dieselbe Hand.
    float dx = fabsf(linksNeu->Joystick.x) > totzone ? linksNeu->Joystick.x : 0.0f;
    float dy = fabsf(linksNeu->Joystick.y) > totzone ? linksNeu->Joystick.y : 0.0f;

    // Anteil der Flaeche je Bild. Bei 90 Bildern/s braucht der Cursor damit
    // knapp eine Sekunde von Rand zu Rand -- schnell genug zum Zielen, langsam
    // genug zum Treffen.
    const float tempo = 0.012f;
    x = clamp(0.0f, x + dx * tempo, 1.0f);
    // Bildschirmkoordinaten wachsen nach unten, der Stick nach oben.
    y = clamp(0.0f, y - dy * tempo, 1.0f);

    PortableMouseAbs(x, y);

    // Ausgewaehlt wird mit R2, nicht mit einer Taste: an den Sense-Controllern
    // klickt der Trigger, und derselbe Finger soll dasselbe tun. Der rechte
    // Trigger des Gamepads kommt ueber dieselbe Aktion herein
    // (GCInputRightTrigger -> xrButton_Trigger), die Zeile darunter ist deshalb
    // wortgleich mit der im Zeigepfad.
    handleTrackedControllerButton(const_cast<ovrInputStateTrackedRemote *>(rechtsNeu),
                                  const_cast<ovrInputStateTrackedRemote *>(rechtsAlt),
                                  xrButton_Trigger, A_MOUSE1);
}
#endif
