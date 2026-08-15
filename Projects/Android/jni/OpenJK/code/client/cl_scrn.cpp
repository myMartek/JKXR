/*
===========================================================================
Copyright (C) 1999 - 2005, Id Software, Inc.
Copyright (C) 2000 - 2013, Raven Software, Inc.
Copyright (C) 2001 - 2013, Activision, Inc.
Copyright (C) 2005 - 2015, ioquake3 contributors
Copyright (C) 2013 - 2015, OpenJK contributors

This file is part of the OpenJK source code.

OpenJK is free software; you can redistribute it and/or modify it
under the terms of the GNU General Public License version 2 as
published by the Free Software Foundation.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, see <http://www.gnu.org/licenses/>.
===========================================================================
*/

// cl_scrn.c -- master for refresh, status bar, console, chat, notify, etc

#include "../server/exe_headers.h"

#include "client.h"
#include "client_ui.h"
#include <VrCommon.h>

extern console_t con;

qboolean	scr_initialized;		// ready to draw

cvar_t		*cl_timegraph;
cvar_t		*cl_debuggraph;
cvar_t		*cl_graphheight;
cvar_t		*cl_graphscale;
cvar_t		*cl_graphshift;

/*
================
SCR_DrawNamedPic

Coordinates are 640*480 virtual values
=================
*/
void SCR_DrawNamedPic( float x, float y, float width, float height, const char *picname ) {
	qhandle_t	hShader;

	assert( width != 0 );

	hShader = re.RegisterShader( picname );
	re.DrawStretchPic( x, y, width, height, 0, 0, 1, 1, hShader );
}


/*
================
SCR_FillRect

Coordinates are 640*480 virtual values
=================
*/
void SCR_FillRect( float x, float y, float width, float height, const float *color ) {
	re.SetColor( color );

	re.DrawStretchPic( x, y, width, height, 0, 0, 0, 0, cls.whiteShader );

	re.SetColor( NULL );
}


/*
================
SCR_DrawPic

Coordinates are 640*480 virtual values
A width of 0 will draw with the original image width
=================
*/
void SCR_DrawPic( float x, float y, float width, float height, qhandle_t hShader ) {
	re.DrawStretchPic( x, y, width, height, 0, 0, 1, 1, hShader );
}


/*
** SCR_DrawBigChar
** big chars are drawn at 640*480 virtual screen size
*/
void SCR_DrawBigChar( int x, int y, int ch ) {
	int row, col;
	float frow, fcol;
	float size;
	float	ax, ay, aw, ah;

	ch &= 255;

	if ( ch == ' ' ) {
		return;
	}

	if ( y < -BIGCHAR_HEIGHT ) {
		return;
	}

	ax = x;
	ay = y;
	aw = BIGCHAR_WIDTH;
	ah = BIGCHAR_HEIGHT;

	row = ch>>4;
	col = ch&15;

	frow = row*0.0625;
	fcol = col*0.0625;
	size = 0.0625;
/*
	re.DrawStretchPic( ax, ay, aw, ah,
					   fcol, frow,
					   fcol + size, frow + size,
					   cls.charSetShader );
*/
	float size2;

	frow = row*0.0625;
	fcol = col*0.0625;
	size = 0.03125;
	size2 = 0.0625;

	re.DrawStretchPic( ax, ay, aw, ah,
					   fcol, frow,
					   fcol + size, frow + size2,
					   cls.charSetShader );

}

/*
** SCR_DrawSmallChar
** small chars are drawn at native screen resolution
*/
void SCR_DrawSmallChar( int x, int y, int ch ) {
	int row, col;
	float frow, fcol;
	float size;

	ch &= 255;

	if ( ch == ' ' ) {
		return;
	}

	if ( y < -SMALLCHAR_HEIGHT ) {
		return;
	}

	row = ch>>4;
	col = ch&15;
/*
	frow = row*0.0625;
	fcol = col*0.0625;
	size = 0.0625;

	re.DrawStretchPic( x, y, SMALLCHAR_WIDTH, SMALLCHAR_HEIGHT,
					   fcol, frow,
					   fcol + size, frow + size,
					   cls.charSetShader );
*/

	float size2;

	frow = row*0.0625;
	fcol = col*0.0625;
	size = 0.03125;
	size2 = 0.0625;

	re.DrawStretchPic( x * con.xadjust, y * con.yadjust,
						SMALLCHAR_WIDTH * con.xadjust, SMALLCHAR_HEIGHT * con.yadjust,
		fcol, frow,
		fcol + size, frow + size2,
		cls.charSetShader );

}



/*
==================
SCR_DrawBigString[Color]

Draws a multi-colored string with a drop shadow, optionally forcing
to a fixed color.

Coordinates are at 640 by 480 virtual resolution
==================
*/
void SCR_DrawBigStringExt( int x, int y, const char *string, float *setColor, qboolean forceColor, qboolean noColorEscape ) {
	vec4_t		color;
	const char	*s;
	int			xx;

	// draw the drop shadow
	color[0] = color[1] = color[2] = 0;
	color[3] = setColor[3];
	re.SetColor( color );
	s = string;
	xx = x;
	while ( *s ) {
		if ( !noColorEscape && Q_IsColorString( s ) ) {
			s += 2;
			continue;
		}
		SCR_DrawBigChar( xx+2, y+2, *s );
		xx += BIGCHAR_WIDTH;
		s++;
	}


	// draw the colored text
	s = string;
	xx = x;
	re.SetColor( setColor );
	while ( *s ) {
		if ( Q_IsColorString( s ) ) {
			if ( !forceColor ) {
				memcpy( color, g_color_table[ColorIndex(*(s+1))], sizeof( color ) );
				color[3] = setColor[3];
				re.SetColor( color );
			}
			if ( !noColorEscape ) {
				s += 2;
				continue;
			}
		}
		SCR_DrawBigChar( xx, y, *s );
		xx += BIGCHAR_WIDTH;
		s++;
	}
	re.SetColor( NULL );
}


void SCR_DrawBigString( int x, int y, const char *s, float alpha, qboolean noColorEscape ) {
	float	color[4];

	color[0] = color[1] = color[2] = 1.0;
	color[3] = alpha;
	SCR_DrawBigStringExt( x, y, s, color, qfalse, noColorEscape );
}

void SCR_DrawBigStringColor( int x, int y, const char *s, vec4_t color, qboolean noColorEscape ) {
	SCR_DrawBigStringExt( x, y, s, color, qtrue, noColorEscape );
}

/*
==================
SCR_DrawSmallString[Color]

Draws a multi-colored string with a drop shadow, optionally forcing
to a fixed color.
==================
*/
void SCR_DrawSmallStringExt( int x, int y, const char *string, float *setColor, qboolean forceColor,
		qboolean noColorEscape ) {
	vec4_t		color;
	const char	*s;
	int			xx;

	// draw the colored text
	s = string;
	xx = x;
	re.SetColor( setColor );
	while ( *s ) {
		if ( Q_IsColorString( s ) ) {
			if ( !forceColor ) {
				memcpy( color, g_color_table[ColorIndex(*(s+1))], sizeof( color ) );
				color[3] = setColor[3];
				re.SetColor( color );
			}
			if ( !noColorEscape ) {
				s += 2;
				continue;
			}
		}
		SCR_DrawSmallChar( xx, y, *s );
		xx += SMALLCHAR_WIDTH;
		s++;
	}
	re.SetColor( NULL );
}

/*
** SCR_Strlen -- skips color escape codes
*/
static int SCR_Strlen( const char *str ) {
	const char *s = str;
	int count = 0;

	while ( *s ) {
		if ( Q_IsColorString( s ) ) {
			s += 2;
		} else {
			count++;
			s++;
		}
	}

	return count;
}

/*
** SCR_GetBigStringWidth
*/
int	SCR_GetBigStringWidth( const char *str ) {
	return SCR_Strlen( str ) * BIGCHAR_WIDTH;
}

//===============================================================================


/*
===============================================================================

DEBUG GRAPH

===============================================================================
*/
typedef struct
{
	float	value;
	int		color;
} graphsamp_t;

static	int			current;
static	graphsamp_t	values[1024];

/*
==============
SCR_DebugGraph
==============
*/
void SCR_DebugGraph (float value, int color)
{
	values[current&1023].value = value;
	values[current&1023].color = color;
	current++;
}

/*
==============
SCR_DrawDebugGraph
==============
*/
void SCR_DrawDebugGraph (void)
{
	int		a, x, y, w, i, h;
	float	v;

	//
	// draw the graph
	//
	w = cls.glconfig.vidWidth;
	x = 0;
	y = cls.glconfig.vidHeight;
	re.SetColor( g_color_table[0] );
	re.DrawStretchPic(x, y - cl_graphheight->integer,
		w, cl_graphheight->integer, 0, 0, 0, 0, 0 );
	re.SetColor( NULL );

	for (a=0 ; a<w ; a++)
	{
		i = (current-1-a+1024) & 1023;
		v = values[i].value;
		v = v * cl_graphscale->integer + cl_graphshift->integer;

		if (v < 0)
			v += cl_graphheight->integer * (1+(int)(-v / cl_graphheight->integer));
		h = (int)v % cl_graphheight->integer;
		re.DrawStretchPic( x+w-1-a, y - h, 1, h, 0, 0, 0, 0, 0 );
	}
}
//=============================================================================

/*
==================
SCR_Init
==================
*/
void SCR_Init( void ) {
	cl_timegraph = Cvar_Get ("timegraph", "0", CVAR_CHEAT);
	cl_debuggraph = Cvar_Get ("debuggraph", "0", CVAR_CHEAT);
	cl_graphheight = Cvar_Get ("graphheight", "32", CVAR_CHEAT);
	cl_graphscale = Cvar_Get ("graphscale", "1", CVAR_CHEAT);
	cl_graphshift = Cvar_Get ("graphshift", "0", CVAR_CHEAT);

	scr_initialized = qtrue;
}


//=======================================================

void UI_SetActiveMenu( const char* menuname,const char *menuID );
void _UI_Refresh( int realtime );
void UI_DrawConnect( const char *servername, const char * updateInfoString );

/*
==================
SCR_DrawScreenField

This will be called twice if rendering in stereo mode
==================
*/

void SCR_DrawScreenField( stereoFrame_t stereoFrame ) {

	re.BeginFrame( stereoFrame );

	qboolean uiFullscreen = _UI_IsFullscreen();

	// if the menu is going to cover the entire screen, we
	// don't need to render anything under it
	if ( !uiFullscreen ) {
		switch( cls.state ) {
		default:
			Com_Error( ERR_FATAL, "SCR_DrawScreenField: bad cls.state" );
			break;
		case CA_CINEMATIC:
			SCR_DrawCinematic();
			break;
		case CA_DISCONNECTED:
			// force menu up
			UI_SetActiveMenu( "mainMenu", NULL );
			break;
		case CA_CONNECTING:
		case CA_CHALLENGING:
		case CA_CONNECTED:
			// connecting clients will only show the connection dialog
			UI_DrawConnect( clc.servername, cls.updateInfoString );
			break;
		case CA_LOADING:
		case CA_PRIMED:
			// draw the game information screen and loading progress
			CL_CGameRendering( stereoFrame );
			break;
		case CA_ACTIVE:
			if (CL_IsRunningInGameCinematic() || CL_InGameCinematicOnStandBy())
			{
				SCR_DrawCinematic();
			}
			else
			{
				CL_CGameRendering( stereoFrame );
			}
			break;
		}
	}
	re.ProcessDissolve();

	// draw downloading progress bar

	// the menu draws next
	_UI_Refresh( cls.realtime );

	// console draws next
	Con_DrawConsole ();

	// debug graph can be drawn on top of anything
	if ( cl_debuggraph->integer || cl_timegraph->integer ) {
		SCR_DrawDebugGraph ();
	}
}

#if defined(JKXR_VISIONOS)
bool VR_UseScreenLayer()
{
	const bool inGameCinematic =
		CL_IsRunningInGameCinematic() || CL_InGameCinematicOnStandBy();

	vr.using_screen_layer = _UI_IsFullscreen() ||
		(bool)((vr.cin_camera && !vr.immersive_cinematics) ||
			vr.misc_camera ||
			(inGameCinematic && !vr.immersive_cinematics) ||
			cls.state == CA_DISCONNECTED ||
			cls.state == CA_CHALLENGING ||
			cls.state == CA_CONNECTING ||
			cls.state == CA_CINEMATIC ||
			cls.state == CA_LOADING ||
			cls.state == CA_PRIMED ||
			(Key_GetCatcher() & KEYCATCH_UI) ||
			(Key_GetCatcher() & KEYCATCH_CONSOLE));
	return vr.using_screen_layer;
}
#endif

/*
==================
SCR_UpdateScreen

This is called every frame, and can also be called explicitly to flush
text to the screen.
==================
*/
void SCR_UpdateScreen( void ) {
	static int	recursive;

	if ( !scr_initialized ) {
		return;				// not initialized yet
	}

	// load the ref / ui / cgame if needed
	CL_StartHunkUsers();

	if ( ++recursive > 2 ) {
		Com_Error( ERR_FATAL, "SCR_UpdateScreen: recursively called" );
	}
	recursive = qtrue;

	// If there is no VM, there are also no rendering commands issued. Stop the renderer in
	// that case.
	if ( cls.uiStarted )
	{
		//Try again here in case we've not done it yet
		TBXR_FrameSetup();

		qboolean skippingCin = Cvar_VariableIntegerValue( "skippingCinematic" ) != 0 ? qtrue : qfalse;
		qboolean useScreenLayer = VR_UseScreenLayer() ? qtrue : qfalse;

		if ( useScreenLayer )
		{
#if defined(JKXR_VISIONOS)
			// Screen-Layer über den Stereo-Replay.
			//
			// Android übergibt 2D-Inhalt als Quad-Layer, das der Compositor in
			// 5,5 m Entfernung platziert und selbst für beide Augen ableitet.
			// Auf visionOS gibt es kein Quad-Layer.
			//
			// JKXR hat für genau diesen Fall bereits eine Lösung, die der
			// PCVR-Zweig nutzt: den Inhalt einmal zeichnen, die Befehle
			// aufzeichnen und pro Auge mit Versatz erneut abspielen
			// (R_VR_GetHudReplayOffset, cg_hudStereo). Nur so entsteht
			// Disparität — zweimal dasselbe zu zeichnen legt den Inhalt ins
			// Unendliche, und die Bilder laufen auseinander.
			// Videos NICHT über den Replay.
			//
			// RE_StretchRaw zeichnet sofort und landet nie in der
			// aufgezeichneten Befehlsliste; ein Replay würde das Videobild also
			// gar nicht enthalten. Für Videosequenzen deshalb pro Auge zeichnen,
			// damit tr.currentStereoFrame gesetzt ist und der Versatz dort
			// greift (siehe tr_draw.cpp, RE_StretchRaw).
			const bool cinematicActive =
				(cls.state == CA_CINEMATIC) || CL_IsRunningInGameCinematic() ||
				CL_InGameCinematicOnStandBy();

			// Menü, Ladebild und Video benutzen denselben direkten 2D-Pfad.
			//
			// Der Stereo-Replay war nötig, solange JKXR den Screen-Inhalt direkt
			// in beide Augen zeichnete: er erzeugte künstliche HUD-Versätze. Jetzt
			// rendert JKXR zunächst eine gewöhnliche flache Textur und Metal setzt
			// diese anschließend als echte Welt-Geometrie vor beide Augen. Das
			// native Quad erzeugt die korrekte Disparität selbst; ein Replay würde
			// die GL-Oberfläche nur ein zweites Mal transformieren. Insbesondere
			// erschien das Menü dadurch auf X und Y gedreht, während der ohnehin
			// direkt gerenderte Cinematic-Pfad richtig lag.
			TBXR_visionOS_SetScreenCinematic(cinematicActive);
			for (int eye = 0; eye < 2; ++eye)
			{
				TBXR_prepareEyeBuffer(eye);
				SCR_DrawScreenField(eye == 0 ? STEREO_LEFT : STEREO_RIGHT);
				re.EndFrame(NULL, NULL);
				TBXR_finishEyeBuffer(eye);
			}
#else
			TBXR_prepareEyeBuffer(0);
			SCR_DrawScreenField(STEREO_CENTER);
			if (com_speeds->integer)
				re.EndFrame(&time_frontend, &time_backend);
			else
				re.EndFrame(NULL, NULL);
			TBXR_finishEyeBuffer(0);
#endif
		}
		else if ( skippingCin )
		{
			for (int eye = 0; eye < 2; ++eye)
			{
				TBXR_prepareEyeBuffer(eye);
				re.BeginFrame(eye == 0 ? STEREO_LEFT : STEREO_RIGHT);
				SCR_FillRect(0, 0, 640, 480, colorBlack);
				re.EndFrame(NULL, NULL);
				TBXR_finishEyeBuffer(eye);
			}
		}
		else
		{
			// Stereo-Replay auf visionOS abschaltbar, Vorgabe aus.
			//
			// Der Replay zeichnet die Szene EINMAL zentral, schneidet die
			// Renderbefehle mit und spielt sie je Auge mit angepasster
			// Projektion ab. Er ist der einzige Pfad, den das laufende Spiel
			// nimmt — Menüs, Ladebild und Kamerafahrten gehen direkt pro Auge.
			// Genau deshalb war die Spielwelt schwarz, während alles andere
			// zeichnete.
			//
			// Gemessen wurde: der Replay fängt die Befehle ein und patcht sie
			// korrekt (282 Flaechen, Ansicht 5086x4080, Projektion mit
			// gespiegeltem Y und Reversed-Z), in der Augentextur landet aber
			// nichts — glReadPixels liefert über 1024 Punkte hinweg exakt
			// null. Alles bis zum Abspielen stimmt also; das Abspielen selbst
			// erreicht unseren Puffer nicht.
			//
			// Der direkte Pfad darunter rendert jedes Auge vollständig und ist
			// erprobt: er zeichnet die Kamerafahrten. Er kostet einen zweiten
			// Durchlauf der Szene pro Bild, dafür ist er nachweislich richtig.
			//
			// Über cvar, damit sich beides ohne Neuübersetzung vergleichen
			// lässt: "vr_stereo_replay 1" schaltet den Replay wieder ein.
			static cvar_t *vr_stereo_replay = NULL;
			if ( !vr_stereo_replay ) {
				vr_stereo_replay = Cvar_Get( "vr_stereo_replay", "0", CVAR_ARCHIVE );
			}
			qboolean useStereoReplay =
				( vr_stereo_replay && vr_stereo_replay->integer ) ? qtrue : qfalse;
			qboolean replayed = qfalse;

			if (useStereoReplay &&
				re.VR_BeginStereoReplayCapture && re.VR_ReplayStereoFrame &&
				re.VR_BeginStereoReplayCapture())
			{
				qboolean replayFailed = qfalse;

				vr.eye = 0;
				vr.off_center_fov_x = 0.0f;
				vr.off_center_fov_y = 0.0f;

				SCR_DrawScreenField(STEREO_CENTER);

				for (int eye = 0; eye < 2; ++eye)
				{
					TBXR_prepareEyeBuffer(eye);
					if (!re.VR_ReplayStereoFrame(eye == 0 ? STEREO_LEFT : STEREO_RIGHT, eye == 1 ? qtrue : qfalse))
					{
						TBXR_finishEyeBuffer(eye);
						if (re.VR_CancelStereoReplayCapture)
						{
							re.VR_CancelStereoReplayCapture();
						}
						replayFailed = qtrue;
						break;
					}
					TBXR_finishEyeBuffer(eye);
				}

				replayed = replayFailed ? qfalse : qtrue;
			}

			if (!replayed)
			{
				for (int eye = 0; eye < 2; ++eye)
				{
					TBXR_prepareEyeBuffer(eye);
					SCR_DrawScreenField(eye == 0 ? STEREO_LEFT : STEREO_RIGHT);
					if (com_speeds->integer)
					{
						re.EndFrame(&time_frontend, &time_backend);
					}
					else
					{
						re.EndFrame(NULL, NULL);
					}
					TBXR_finishEyeBuffer(eye);
				}
			}
		}

		//And we're done
		re.SubmitStereoFrame();

		recursive = 0;
	}

	recursive = 0;
}

// this stuff is only used by the savegame (SG) code for screenshots...
//


static byte	bScreenData[SG_SCR_WIDTH * SG_SCR_HEIGHT * 4];
static qboolean screenDataValid = qfalse;
void SCR_UnprecacheScreenshot()
{
	screenDataValid = qfalse;
}


void SCR_PrecacheScreenshot()
{
	// No screenshots unless connected to single player local server...
	//
//	char *psInfo = cl.gameState.stringData + cl.gameState.stringOffsets[ CS_SERVERINFO ];
//	int iMaxClients = atoi(Info_ValueForKey( psInfo, "sv_maxclients" ));

	// (no need to check single-player status in voyager, this code base is all singleplayer)
	if ( cls.state != CA_ACTIVE )
	{
		return;
	}

	if (!Key_GetCatcher( ))
	{
		// in-game...
		//
//		SCR_UnprecacheScreenshot();
//		pbScreenData = (byte *)Z_Malloc(SG_SCR_WIDTH * SG_SCR_HEIGHT * 4);
		S_ClearSoundBuffer();	// clear DMA etc because the following glReadPixels() call can take ages
		re.GetScreenShot( (byte *) &bScreenData, SG_SCR_WIDTH, SG_SCR_HEIGHT);
		screenDataValid = qtrue;
	}

}

byte *SCR_GetScreenshot(qboolean *qValid)
{
	if (!screenDataValid) {
		SCR_PrecacheScreenshot();
	}
	if (qValid) {
		*qValid = screenDataValid;
	}
	return (byte *)&bScreenData;
}

// called from save-game code to set the lo-res loading screen to be the one from the save file...
//
void SCR_SetScreenshot(const byte *pbData, int w, int h)
{
	if (w == SG_SCR_WIDTH && h == SG_SCR_HEIGHT)
	{
		screenDataValid = qtrue;
		memcpy(&bScreenData, pbData, SG_SCR_WIDTH*SG_SCR_HEIGHT*4);
	}
	else
	{
		screenDataValid = qfalse;
		memset(&bScreenData, 0,      SG_SCR_WIDTH*SG_SCR_HEIGHT*4);
	}
}


#ifdef JK2_MODE
// This is just a client-side wrapper for the function RE_TempRawImage_ReadFromFile() in the renderer code...
//

byte* SCR_TempRawImage_ReadFromFile(const char *psLocalFilename, int *piWidth, int *piHeight, byte *pbReSampleBuffer, qboolean qbVertFlip)
{
	return re.TempRawImage_ReadFromFile(psLocalFilename, piWidth, piHeight, pbReSampleBuffer, qbVertFlip);
}
//
// ditto (sort of)...
//
void  SCR_TempRawImage_CleanUp()
{
	re.TempRawImage_CleanUp();
}
#endif
