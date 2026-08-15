/*
===========================================================================
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

// Audio-Backend für visionOS — Gegenstück zu android/android_snd.cpp.
//
// Warum dieser Weg und nicht OpenAL: snd_dma.cpp bringt zwar einen
// vollständigen OpenAL-Pfad mit, aber der ist an Windows gebunden. Er hängt an
// EAX (207 Stellen, nicht abschaltbar), am EAX-Manager über COM und an
// LoadLibrary/GetProcAddress; deshalb steht er hinter `#if defined(_MSC_VER)`.
// JKXR nutzt ihn auf Quest gar nicht, sondern Quakes plattformneutralen
// Software-Mixer. Genau der läuft hier — also derselbe Klangpfad, der sich im
// Quest-Port bereits mit der VR-Schicht bewährt hat.
//
// Die Engine schreibt in dma.buffer, einen Ringpuffer, und liest über
// SNDDMA_GetDMAPos, wie weit die Wiedergabe ist. Die fünf SNDDMA_*-Funktionen
// sind die gesamte Schnittstelle.
//
// Statt OpenSL ES steht darunter eine RemoteIO-AudioUnit.

#include <AudioToolbox/AudioToolbox.h>
#include <AVFoundation/AVFoundation.h>

#include "qcommon/q_shared.h"
#include "client/snd_local.h"

// Anders als Android (22050 Hz) läuft hier die Hardwarerate. Die Klangdateien
// von Jedi Academy sind überwiegend 22050 Hz; der Mixer rechnet beim Abspielen
// ohnehin um, also kostet die höhere Ausgaberate nichts an Qualität, spart aber
// eine zweite Umrechnung im Audiosystem des Betriebssystems.
#define VISIONOS_SND_SPEED      44100

// 16384 Einzelsamples wie auf Android, bei 44100 Hz und zwei Kanälen also
// 8192 Frames oder rund 186 ms. Wie weit der Mixer tatsächlich vorausrechnet,
// bestimmt die Engine — das hier ist nur die Obergrenze des Rings.
#define VISIONOS_SND_SAMPLES    (1024 * 16)

static AudioUnit    s_audioUnit     = NULL;
static int          s_sndInited     = 0;
static int          s_dmaPos        = 0;   // in Einzelsamples, wie dma.samples
static int          s_dmaSize       = 0;   // in Bytes

/*
===============
VisionOS_SndRender

Läuft auf dem Echtzeit-Thread des Audiosystems. Hier darf nichts blockieren:
kein malloc, keine Sperre, kein Objective-C-Aufruf. Kopiert wird nur aus dem
Ringpuffer, den der Mixer parallel befüllt.

Dass Schreiber und Leser dabei ohne Sperre auf denselben Puffer zugreifen, ist
Absicht und entspricht dem Android-Backend. Im schlimmsten Fall wird ein Bereich
gelesen, während er überschrieben wird — hörbar als einzelner Knacks, nicht als
Fehlverhalten. Eine Sperre im Echtzeit-Thread wäre der schlechtere Tausch: sie
könnte den Puffer verspätet füllen und damit hörbar aussetzen.
===============
*/
static OSStatus VisionOS_SndRender(
    void                        *inRefCon,
    AudioUnitRenderActionFlags  *ioActionFlags,
    const AudioTimeStamp        *inTimeStamp,
    UInt32                      inBusNumber,
    UInt32                      inNumberFrames,
    AudioBufferList             *ioData)
{
    (void)inRefCon; (void)inTimeStamp; (void)inBusNumber;

    unsigned char *out = (unsigned char *)ioData->mBuffers[0].mData;
    const int len = (int)ioData->mBuffers[0].mDataByteSize;

    if (!s_sndInited || !dma.buffer) {
        memset(out, 0, len);
        // Ohne dieses Flag hält das Audiosystem die Stille für gültige Daten
        // und kann sie nicht wegoptimieren.
        *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }

    const int bytesPerSample = dma.samplebits / 8;

    int pos = s_dmaPos * bytesPerSample;
    if (pos >= s_dmaSize) {
        s_dmaPos = 0;
        pos = 0;
    }

    const int toBufEnd = s_dmaSize - pos;
    int len1 = len;
    int len2 = 0;

    if (len1 > toBufEnd) {
        len1 = toBufEnd;
        len2 = len - len1;
    }

    memcpy(out, dma.buffer + pos, len1);
    if (len2 <= 0) {
        s_dmaPos += len1 / bytesPerSample;
    } else {
        // Umlauf: der Rest kommt vom Ringanfang.
        memcpy(out + len1, dma.buffer, len2);
        s_dmaPos = len2 / bytesPerSample;
    }

    if (s_dmaPos >= dma.samples) {
        s_dmaPos = 0;
    }

    return noErr;
}

/*
===============
VisionOS_SndConfigureSession

Ohne eine aktive AVAudioSession gibt eine RemoteIO-AudioUnit nichts aus — sie
meldet keinen Fehler, sie bleibt einfach stumm.

.ambient ist hier richtig und nicht .playback: es respektiert den Lautlos-
Schalter und mischt sich mit anderem Ton, statt ihn zu verdrängen. Für ein Spiel
in einem geteilten Raum ist das das erwartete Verhalten.
===============
*/
static void VisionOS_SndConfigureSession(void)
{
    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];

    // Playback, nicht Ambient.
    //
    // Ambient ist an den Vordergrundzustand gebunden: sobald das Startfenster
    // zugeht und nur noch der Immersive Space offen ist, deaktiviert das System
    // die Sitzung und der Ton verstummt — ohne Fehlermeldung, denn die
    // RemoteIO-AudioUnit läuft weiter und schreibt nur ins Leere.
    //
    // Ursprünglich war Ambient bewusst gewählt, um den Lautlos-Schalter zu
    // respektieren und fremden Ton nicht zu verdrängen. Das ist die richtige
    // Etikette im GETEILTEN Raum — wir laufen aber in einem VOLLEN Immersive
    // Space (immersionStyle .full in JKXRApp.swift). Dort ist die App die
    // Erfahrung, und Playback ist die dafür vorgesehene Kategorie.
    if (![session setCategory:AVAudioSessionCategoryPlayback error:&err]) {
        Com_Printf("SNDDMA: setCategory fehlgeschlagen: %s\n",
                   [[err localizedDescription] UTF8String]);
    }
    if (![session setActive:YES error:&err]) {
        Com_Printf("SNDDMA: setActive fehlgeschlagen: %s\n",
                   [[err localizedDescription] UTF8String]);
    }
}

/*
===============
SNDDMA_Init
===============
*/
int SNDDMA_Init(int sampleFrequencyInKHz)
{
    (void)sampleFrequencyInKHz;   // wie auf Android: die Rate steht hier fest

    if (s_sndInited) {
        return 1;
    }

    VisionOS_SndConfigureSession();

    dma.samplebits       = 16;
    dma.channels         = 2;
    dma.samples          = VISIONOS_SND_SAMPLES;
    dma.submission_chunk = 1024 * 2;
    dma.speed            = VISIONOS_SND_SPEED;

    s_dmaPos  = 0;
    s_dmaSize = dma.samples * (dma.samplebits / 8);
    dma.buffer = (byte *)calloc(1, s_dmaSize);
    if (!dma.buffer) {
        Com_Printf("SNDDMA: Ringpuffer (%d Bytes) nicht zuteilbar\n", s_dmaSize);
        return 0;
    }

    AudioComponentDescription desc = {};
    desc.componentType         = kAudioUnitType_Output;
    desc.componentSubType      = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;

    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp) {
        Com_Printf("SNDDMA: keine RemoteIO-AudioUnit gefunden\n");
        free(dma.buffer);
        dma.buffer = NULL;
        return 0;
    }

    OSStatus status = AudioComponentInstanceNew(comp, &s_audioUnit);
    if (status != noErr) {
        Com_Printf("SNDDMA: AudioComponentInstanceNew: %d\n", (int)status);
        free(dma.buffer);
        dma.buffer = NULL;
        return 0;
    }

    // Verschränktes 16-Bit-Ganzzahlformat — dasselbe Layout, das der Mixer in
    // dma.buffer schreibt, sodass der Render-Rückruf reines memcpy bleibt.
    AudioStreamBasicDescription fmt = {};
    fmt.mSampleRate       = VISIONOS_SND_SPEED;
    fmt.mFormatID         = kAudioFormatLinearPCM;
    fmt.mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fmt.mChannelsPerFrame = 2;
    fmt.mBitsPerChannel   = 16;
    fmt.mFramesPerPacket  = 1;
    fmt.mBytesPerFrame    = fmt.mChannelsPerFrame * fmt.mBitsPerChannel / 8;
    fmt.mBytesPerPacket   = fmt.mBytesPerFrame * fmt.mFramesPerPacket;

    // Element 0 ist der Ausgang; sein *Input*-Scope ist das, was wir liefern.
    status = AudioUnitSetProperty(s_audioUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input, 0,
                                  &fmt, sizeof(fmt));
    if (status != noErr) {
        Com_Printf("SNDDMA: StreamFormat: %d\n", (int)status);
        AudioComponentInstanceDispose(s_audioUnit);
        s_audioUnit = NULL;
        free(dma.buffer);
        dma.buffer = NULL;
        return 0;
    }

    AURenderCallbackStruct cb = {};
    cb.inputProc       = VisionOS_SndRender;
    cb.inputProcRefCon = NULL;

    status = AudioUnitSetProperty(s_audioUnit,
                                  kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Input, 0,
                                  &cb, sizeof(cb));
    if (status != noErr) {
        Com_Printf("SNDDMA: SetRenderCallback: %d\n", (int)status);
        AudioComponentInstanceDispose(s_audioUnit);
        s_audioUnit = NULL;
        free(dma.buffer);
        dma.buffer = NULL;
        return 0;
    }

    status = AudioUnitInitialize(s_audioUnit);
    if (status != noErr) {
        Com_Printf("SNDDMA: AudioUnitInitialize: %d\n", (int)status);
        AudioComponentInstanceDispose(s_audioUnit);
        s_audioUnit = NULL;
        free(dma.buffer);
        dma.buffer = NULL;
        return 0;
    }

    // Erst jetzt: ab dem Start läuft der Rückruf, und er prüft dieses Flag.
    s_sndInited = 1;

    status = AudioOutputUnitStart(s_audioUnit);
    if (status != noErr) {
        Com_Printf("SNDDMA: AudioOutputUnitStart: %d\n", (int)status);
        s_sndInited = 0;
        AudioUnitUninitialize(s_audioUnit);
        AudioComponentInstanceDispose(s_audioUnit);
        s_audioUnit = NULL;
        free(dma.buffer);
        dma.buffer = NULL;
        return 0;
    }

    Com_Printf("SNDDMA: %d Hz, %d Kanäle, %d Bit, %d Samples Ring\n",
               dma.speed, dma.channels, dma.samplebits, dma.samples);
    return 1;
}

/*
===============
SNDDMA_GetDMAPos

Wie weit die Wiedergabe im Ring vorangekommen ist, in Einzelsamples.
===============
*/
int SNDDMA_GetDMAPos(void)
{
    if (!s_sndInited) {
        return 0;
    }
    return s_dmaPos;
}

/*
===============
SNDDMA_Shutdown
===============
*/
void SNDDMA_Shutdown(void)
{
    if (!s_sndInited) {
        return;
    }

    // Reihenfolge zählt: erst das Flag löschen, damit ein noch laufender
    // Rückruf Stille liefert statt in einen gleich freigegebenen Puffer zu
    // greifen, dann die AudioUnit anhalten, und erst danach freigeben.
    s_sndInited = 0;

    if (s_audioUnit) {
        AudioOutputUnitStop(s_audioUnit);
        AudioUnitUninitialize(s_audioUnit);
        AudioComponentInstanceDispose(s_audioUnit);
        s_audioUnit = NULL;
    }

    if (dma.buffer) {
        free(dma.buffer);
        dma.buffer = NULL;
    }

    [[AVAudioSession sharedInstance] setActive:NO error:nil];
}

/*
===============
SNDDMA_BeginPainting

Auf Android leer — der Mixer schreibt direkt in den Ring, ohne Absprache mit
dem Wiedergabe-Thread. Hier ebenso.
===============
*/
void SNDDMA_BeginPainting(void)
{
}

/*
===============
SNDDMA_Submit

Nur nötig, wenn der Mixer in einen Zwischenpuffer schreibt statt in den Ring
selbst. Tut er nicht.
===============
*/
void SNDDMA_Submit(void)
{
}
