/*
 * JKXR-Initialisierung für visionOS.
 *
 * Gegenstück zum plattformneutralen Teil von android/JKXR_SurfaceView.cpp.
 * VR_Init legt dort ausschließlich cvars an und setzt Bewegungsvariablen
 * zurück — kein Android-spezifischer Code zwischen Anfang und Ende der
 * Funktion. Sie steht nur deshalb in der Plattformdatei, weil JKXR sie nie
 * herausgezogen hat.
 *
 * Wörtlich übernommen (JKXR_SurfaceView.cpp, Zeilen 314-392). Die Werte sind
 * über Jahre an echten Spielern abgeglichen; Abweichungen gehören in eine
 * eigene, begründete Änderung, nicht in die Portierung.
 */

#include "TBXR_Common.h"
#include "VrCommon.h"
#include "VrCvars.h"
#include "VrInput.h"   // remote_movementSideways u.a.

// VR_GetMove prüft den Fahrzeugtyp (VH_FIGHTER, VH_FLIER). Auf Android kommt
// das Enum über client/client.h herein; hier ausdrücklich geholt.
#include "game/g_vehicles.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>

void VR_Init()
{
	//Initialise all our variables
	remote_movementSideways = 0.0f;
	remote_movementForward = 0.0f;
	remote_movementUp = 0.0f;
	positional_movementSideways = 0.0f;
	positional_movementForward = 0.0f;
	vr.snapTurn = 0.0f;
	vr.immersive_cinematics = true;
	vr.move_speed = 1; // Default to full speed now

	//init randomiser
	srand(time(NULL));

	//Create Cvars
	vr_turn_mode = Cvar_Get( "vr_turn_mode", "0", CVAR_ARCHIVE); // 0 = snap, 1 = smooth (3rd person only), 2 = smooth (all modes)
	vr_turn_angle = Cvar_Get( "vr_turn_angle", "45", CVAR_ARCHIVE);
	vr_positional_factor = Cvar_Get( "vr_positional_factor", "12", CVAR_ARCHIVE);
    vr_walkdirection = Cvar_Get( "vr_walkdirection", "1", CVAR_ARCHIVE);
	vr_3rdperson_digital_direction = Cvar_Get( "vr_3rdperson_digital_direction", "1", CVAR_ARCHIVE);
	vr_weapon_pitchadjust = Cvar_Get( "vr_weapon_pitchadjust", "-20.0", CVAR_ARCHIVE);
	vr_saber_pitchadjust = Cvar_Get( "vr_saber_pitchadjust", "-13.36", CVAR_ARCHIVE);
    vr_virtual_stock = Cvar_Get( "vr_virtual_stock", "0", CVAR_ARCHIVE);

    //Defaults
	vr_control_scheme = Cvar_Get( "vr_control_scheme", "0", CVAR_ARCHIVE);
	vr_switch_sticks = Cvar_Get( "vr_switch_sticks", "0", CVAR_ARCHIVE);

	vr_immersive_cinematics = Cvar_Get("vr_immersive_cinematics", "1", CVAR_ARCHIVE);
	vr_screen_dist = Cvar_Get( "vr_screen_dist", "3.5", CVAR_ARCHIVE);
	vr_weapon_velocity_trigger = Cvar_Get( "vr_weapon_velocity_trigger", "2.0", CVAR_ARCHIVE);
	vr_scope_engage_distance = Cvar_Get( "vr_scope_engage_distance", "0.25", CVAR_ARCHIVE);
	vr_force_velocity_trigger = Cvar_Get( "vr_force_velocity_trigger", "2.09", CVAR_ARCHIVE);
	vr_force_distance_trigger = Cvar_Get( "vr_force_distance_trigger", "0.15", CVAR_ARCHIVE);
    vr_two_handed_weapons = Cvar_Get ("vr_two_handed_weapons", "1", CVAR_ARCHIVE);
	vr_force_motion_controlled = Cvar_Get ("vr_force_motion_controlled", "1", CVAR_ARCHIVE);
	vr_force_motion_push = Cvar_Get ("vr_force_motion_push", "3", CVAR_ARCHIVE);
	vr_force_motion_pull = Cvar_Get ("vr_force_motion_pull", "4", CVAR_ARCHIVE);
	vr_motion_enable_saber = Cvar_Get ("vr_motion_enable_saber", "0", CVAR_ARCHIVE);
	vr_always_run = Cvar_Get ("vr_always_run", "1", CVAR_ARCHIVE);
	vr_crouch_toggle = Cvar_Get ("vr_crouch_toggle", "0", CVAR_ARCHIVE);
	vr_irl_crouch_enabled = Cvar_Get ("vr_irl_crouch_enabled", "0", CVAR_ARCHIVE);
	vr_irl_crouch_to_stand_ratio = Cvar_Get ("vr_irl_crouch_to_stand_ratio", "0.65", CVAR_ARCHIVE);
	vr_saber_block_debounce_time = Cvar_Get ("vr_saber_block_debounce_time", "200", CVAR_ARCHIVE);
	vr_haptic_intensity = Cvar_Get ("vr_haptic_intensity", "1.0", CVAR_ARCHIVE);
	vr_comfort_vignette = Cvar_Get ("vr_comfort_vignette", "0.0", CVAR_ARCHIVE);
	vr_saber_3rdperson_mode = Cvar_Get ("vr_saber_3rdperson_mode", "1", CVAR_ARCHIVE);
	vr_vehicle_use_hmd_direction = Cvar_Get ("vr_vehicle_use_hmd_direction", "0", CVAR_ARCHIVE);
	vr_vehicle_use_3rd_person = Cvar_Get ("vr_vehicle_use_3rd_person", "0", CVAR_ARCHIVE);
	vr_vehicle_use_controller_for_speed = Cvar_Get ("vr_vehicle_use_controller_for_speed", "1", CVAR_ARCHIVE);
	vr_gesture_triggered_use = Cvar_Get ("vr_gesture_triggered_use", "1", CVAR_ARCHIVE);
	vr_use_gesture_boundary = Cvar_Get ("vr_use_gesture_boundary", "0.35", CVAR_ARCHIVE);
	vr_align_weapons = Cvar_Get ("vr_align_weapons", "0", CVAR_ARCHIVE);
	vr_refresh = Cvar_Get ("vr_refresh", "72", CVAR_ARCHIVE);
	vr_super_sampling = Cvar_Get ("vr_super_sampling", "1.0", CVAR_ARCHIVE);
	vr_engage_trigger = Cvar_Get("vr_engage_trigger", "0.7", CVAR_ARCHIVE);
	vr_release_trigger = Cvar_Get("vr_release_trigger", "0.7", CVAR_ARCHIVE);
	vr_engage_trigger_index = Cvar_Get("vr_engage_trigger_index", "0.7", CVAR_ARCHIVE);
	vr_release_trigger_index = Cvar_Get("vr_release_trigger_index", "0.05", CVAR_ARCHIVE);

	cvar_t *expanded_menu_enabled = Cvar_Get ("expanded_menu_enabled", "0", CVAR_ARCHIVE);
	if (FS_FileExists("expanded_menu.pk3") || FS_BaseFileExists("expanded_menu.pk3")) {
		Cvar_Set( "expanded_menu_enabled", "1" );
	} else {
		Cvar_Set( "expanded_menu_enabled", "0" );
	}

	cvar_t *mod_npcsp_enabled = Cvar_Get ("mod_npcsp_enabled", "0", CVAR_ARCHIVE);
	if (FS_FileExists("NpcSP_v1.1.pk3") || FS_BaseFileExists("NpcSP_v1.1.pk3")) {
		Cvar_Set( "mod_npcsp_enabled", "1" );
	} else {
		Cvar_Set( "mod_npcsp_enabled", "0" );
	}

    vr.menu_right_handed = vr_control_scheme->integer == 0;

    // Nur für explizite Diagnoseläufe; darf nie in der Spielkonfiguration
    // archiviert werden oder einen normalen Start übermalen.
    Cvar_Get ("vr_debug_metal_clear_only", "0", 0);
    Cvar_Get ("vr_debug_angle_clear_only", "0", 0);
    const char *forceMetal = getenv("JKXR_FORCE_METAL_CLEAR");
    if (forceMetal && forceMetal[0] != '\0' && strcmp(forceMetal, "0") != 0) {
        // Der normale Debug-Clear läuft erst NACH zwei vollständigen Engine-
        // Renderpässen. Für die Compositor-Diagnose muss dieser Aufwand weg,
        // sonst kann ein korrektes Metal-Bild trotzdem die Deadline verpassen.
        Cvar_Set("vr_debug_metal_clear_only", "1");
    }
    const char *forceAngle = getenv("JKXR_FORCE_ANGLE_CLEAR");
    if (forceAngle && forceAngle[0] != '\0' && strcmp(forceAngle, "0") != 0) {
        Cvar_Set("vr_debug_angle_clear_only", "1");
    }

    Cvar_Get ("openXRHMD", gAppState.OpenXRHMD, CVAR_ARCHIVE);
}


// ---------------------------------------------------------------------------
// Weitere plattformneutrale Teile aus android/JKXR_SurfaceView.cpp
//
// Sie stehen dort nur deshalb in der Plattformdatei, weil JKXR sie nie
// herausgezogen hat — Android-spezifisch ist an ihnen nichts.
//
// VR_SetHMDOrientation und VR_SetHMDPosition füttern die Kopfpose in die
// Engine; TBXR_GetHMDOrientation ruft sie pro Bild auf. VR_GetMove ist die
// eigentliche Bewegungslogik (Zeilen 222-308) — sie ersetzt den Platzhalter,
// der bisher in TBXR_Common.mm stand.
// ---------------------------------------------------------------------------

void VR_SetHMDOrientation(float pitch, float yaw, float roll)
{
	//Orientation
	VectorSet(vr.hmdorientation, pitch, yaw, roll);
	VectorSubtract(vr.hmdorientation_last, vr.hmdorientation, vr.hmdorientation_delta);

	//Keep this for our records
	VectorCopy(vr.hmdorientation, vr.hmdorientation_last);

	if (!vr.third_person && !vr.remote_npc && !vr.remote_turret && !vr.cgzoommode
#ifndef JK2_MODE
		&& !vr.in_vehicle
#endif
	)
	{
		VectorCopy(vr.hmdorientation, vr.hmdorientation_first);
	}

	if (!vr.remote_turret && !vr.cgzoommode)
	{
		VectorCopy(vr.weaponangles[ANGLES_ADJUSTED], vr.weaponangles_first[ANGLES_ADJUSTED]);
	}

	// View yaw delta
	float clientview_yaw = vr.clientviewangles[YAW] - vr.hmdorientation[YAW];
	vr.clientview_yaw_delta = vr.clientview_yaw_last - clientview_yaw;
	vr.clientview_yaw_last = clientview_yaw;

	// Max-height is set only once on start, or after re-calibration
	// (ignore too low value which is sometimes provided on start)
	if (!vr.maxHeight || vr.maxHeight < 1.0) {
		vr.maxHeight = vr.hmdposition[1];
	}

	//GB Instantiate initial velocity
	if(!vr.tempWeaponVelocity)
	{
		vr.tempWeaponVelocity = 400.0f;
	}

	vr.curHeight = vr.hmdposition[1];
}

void VR_SetHMDPosition(float x, float y, float z )
{
	static bool s_useScreen = qfalse;

	VectorSet(vr.hmdposition, x, y, z);

	//Can be set elsewhere
	vr.take_snap |= s_useScreen != VR_UseScreenLayer();
	if (vr.take_snap)
    {
		s_useScreen = VR_UseScreenLayer();

		//Record player position on transition
		VectorSet(vr.hmdposition_snap, x, y, z);
		VectorCopy(vr.hmdorientation, vr.hmdorientation_snap);
		if (vr.cin_camera)
		{
			//Reset snap turn too if in a cinematic
			vr.snapTurn = 0;
		}
		vr.take_snap = false;
    }

	VectorSubtract(vr.hmdposition, vr.hmdposition_snap, vr.hmdposition_offset);

	//Position
	VectorSubtract(vr.hmdposition_last, vr.hmdposition, vr.hmdposition_delta);

	//Keep this for our records
	VectorCopy(vr.hmdposition, vr.hmdposition_last);
}

void VR_GetMove(float *forward, float *side, float *pos_forward, float *pos_side, float *up,
				float *yaw, float *pitch, float *roll)
{
	if (vr.remote_turret) {
		*forward = 0.0f;
		*pos_forward = 0.0f;
		*up = 0.0f;
		*side = 0.0f;
		*pos_side = 0.0f;
		*yaw = vr.snapTurn + vr.hmdorientation_first[YAW] +
				vr.weaponangles[ANGLES_ADJUSTED][YAW] - vr.weaponangles_first[ANGLES_ADJUSTED][YAW];
		*pitch = vr.weaponangles[ANGLES_ADJUSTED][PITCH];
		*roll = 0.0f;
	}
	else if (vr.cgzoommode == 2 || vr.cgzoommode == 4)
	{
		*forward = remote_movementForward / 3.0f;
		*pos_forward = 0.0f;
		*up = 0.0f;
		*side = remote_movementSideways / 3.0f;
		*pos_side = 0.0f;
		*yaw = vr.snapTurn + vr.hmdorientation_first[YAW] +
                             vr.weaponangles[ANGLES_ADJUSTED][YAW] - vr.weaponangles_first[ANGLES_ADJUSTED][YAW];
		*pitch = vr.weaponangles[ANGLES_ADJUSTED][PITCH];
		*roll = 0.0f;//vr.hmdorientation[ROLL];
	}
	else if (vr.remote_npc) {
		*forward = remote_movementForward;
		*pos_forward = 0.0f;
		*up = 0.0f;
		*side = remote_movementSideways;
		*pos_side = 0.0f;
		*yaw = vr.hmdorientation[YAW] + vr.snapTurn;
		*pitch = vr.hmdorientation[PITCH];
		*roll = 0.0f;
	}
#ifndef JK2_MODE
	//Special code for JKA's vehicles
	else  if (vr.in_vehicle) {
		//in vehicle
		*forward = remote_movementForward;
		*pos_forward = 0.0f;
		*up = 0.0f;
		*side = remote_movementSideways;
		*pos_side = 0.0f;
		if (vr_vehicle_use_hmd_direction->integer)
		{
			*yaw = vr.hmdorientation[YAW] + vr.snapTurn;
			*pitch = vr.hmdorientation[PITCH];
		}
		else
		{
			*yaw = vr.snapTurn + vr.hmdorientation_first[YAW];
			if (vr.vehicle_type == VH_FIGHTER || vr.vehicle_type == VH_FLIER)
			{
				*pitch = (vr.weaponangles[ANGLES_ADJUSTED][PITCH] + vr.offhandangles[ANGLES_ADJUSTED][PITCH]) / 2.0f;
			}
			else
			{
				*pitch = 0.0f;
			}
		}
		*roll = 0.0f;
	}
#endif
	else if (!vr.third_person) {
		*forward = remote_movementForward;
		*pos_forward = positional_movementForward;
		*up = remote_movementUp;
		*side = remote_movementSideways;

		*pos_side = positional_movementSideways;
		*yaw = vr.hmdorientation[YAW] + vr.snapTurn;
		*pitch = vr.hmdorientation[PITCH];
		*roll = 0.0f;//vr.hmdorientation[ROLL];
	} else {
		//in third person just send the bare minimum
		*forward = remote_movementForward;
		*pos_forward = 0.0f;
		*up = 0.0f;
		*side = remote_movementSideways;
		*pos_side = 0.0f;
		*yaw = vr.snapTurn + vr.hmdorientation_first[YAW];
		*pitch = 0.0f;
		*roll = 0.0f;
	}
}


// VR_SetRefreshRate und VR_FrameSetup (Zeilen 441-466)
int VR_SetRefreshRate(int refreshRate)
{
	if (gAppState.OpenXRHMD != NULL &&
		strstr(gAppState.OpenXRHMD, "meta") != NULL &&
		gAppState.pfnRequestDisplayRefreshRate != NULL)
	{
		OXR(gAppState.pfnRequestDisplayRefreshRate(gAppState.Session, (float) refreshRate));
		return refreshRate;
	}

	return 0;
}

//All the stuff we want to do each frame specifically for this game
void VR_FrameSetup()
{
	static float refresh = 0;
	if (refresh != vr_refresh->value)
	{
		refresh = vr_refresh->value;
		VR_SetRefreshRate(vr_refresh->value);
	}

	//get any cvar values required here
	vr.immersive_cinematics = (vr_immersive_cinematics->value != 0.0f);
}


// VR_HandleControllerInput (Zeilen 735-757)
void VR_HandleControllerInput() {
	TBXR_UpdateControllers();

	//Call additional control schemes here
	switch (vr_control_scheme->integer)
	{
		case RIGHT_HANDED_DEFAULT:
			HandleInput_Default(&rightTrackedRemoteState_new, &rightTrackedRemoteState_old, &rightRemoteTracking_new,
								&leftTrackedRemoteState_new, &leftTrackedRemoteState_old, &leftRemoteTracking_new,
								xrButton_A, xrButton_B, xrButton_X, xrButton_Y);
			break;
		case LEFT_HANDED_DEFAULT:
			HandleInput_Default(&leftTrackedRemoteState_new, &leftTrackedRemoteState_old, &leftRemoteTracking_new,
								&rightTrackedRemoteState_new, &rightTrackedRemoteState_old, &rightRemoteTracking_new,
								xrButton_X, xrButton_Y, xrButton_A, xrButton_B);
			break;
		case WEAPON_ALIGN:
			HandleInput_WeaponAlign(&rightTrackedRemoteState_new, &rightTrackedRemoteState_old, &rightRemoteTracking_new,
								&leftTrackedRemoteState_new, &leftTrackedRemoteState_old, &leftRemoteTracking_new,
								xrButton_A, xrButton_B, xrButton_X, xrButton_Y);
			break;
	}
}
