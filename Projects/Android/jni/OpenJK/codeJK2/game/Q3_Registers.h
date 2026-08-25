/*
===========================================================================
Copyright (C) 2000 - 2013, Raven Software, Inc.
Copyright (C) 2001 - 2013, Activision, Inc.
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

#ifndef __Q3_REGISTERS__
#define __Q3_REGISTERS__

// Wieviele ICARUS-Variablen gleichzeitig bestehen duerfen.
//
// Stand auf 32 und war damit zu klein. Die Variablen werden ueber Levelgrenzen
// MITGENOMMEN: beim Betreten eines Abschnitts stellt Q3_VariableLoad alles
// wieder her, was frueher deklariert wurde. In Outcast sind das beim Erreichen
// von yavin_trial bereits 33 Stueck -- gezaehlt auf dem Geraet --, und damit
// lehnt Q3_DeclareVariable ab diesem Punkt JEDE weitere Deklaration ab.
//
// Folge, so gemeldet: das Schiebeplatten-Raetsel in yavin_trial laesst sich
// nicht loesen. Seine achtzehn Variablen (slider1..slider8, peg1..4_pushed,
// finaldoor, saberdoor, slidebridge, pillar_level, weight3down, weight4down)
// entstehen nie, die Platten schreiben ins Leere, und das Pruefskript liest
// Nichts. Startet man dieselbe Karte dagegen direkt (+map yavin_trial), sind
// keine Variablen uebernommen, alle achtzehn kommen durch, und das Raetsel
// funktioniert -- das war der entscheidende Vergleich.
//
// Die Zahl haengt an nichts: die Ablage ist eine std::map, und das
// Speicherformat schreibt die tatsaechliche Groesse. Sie war nur eine
// Vorsichtsgrenze, und 256 ist fuer ein Spiel dieser Laenge reichlich.
#define	MAX_VARIABLES	256

typedef std::map < std::string, std::string >		varString_m;
typedef std::map < std::string, float >		varFloat_m;

extern	varString_m	varStrings;
extern	varFloat_m	varFloats;
extern	varString_m	varVectors;

enum
{
	VTYPE_NONE = 0,
	VTYPE_FLOAT,
	VTYPE_STRING,
	VTYPE_VECTOR,
};

extern void Q3_InitVariables( void );
extern void Q3_DeclareVariable( int type, const char *name );
extern void Q3_FreeVariable( const char *name );
extern int  Q3_GetStringVariable( const char *name, const char **value );
extern int  Q3_GetFloatVariable( const char *name, float *value );
extern int  Q3_GetVectorVariable( const char *name, vec3_t value );
extern int  Q3_VariableDeclared( const char *name );
extern int  Q3_SetFloatVariable( const char *name, float value );
extern int  Q3_SetStringVariable( const char *name, const char *value );
extern int  Q3_SetVectorVariable( const char *name, const char *value );

#endif	//__Q3_REGISTERS__