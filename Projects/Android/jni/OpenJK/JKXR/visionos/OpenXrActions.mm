// Nachbau des OpenXR-Action-Systems für visionOS.
//
// visionOS hat keine OpenXR-Laufzeit. JKXRs plattformneutraler Code ruft aber
// direkt OpenXR auf — allerdings nur sechzehn Funktionen, und alle aus dem
// Action-System. Kein Rendering, keine Session- oder Frame-Verwaltung.
//
// Statt OpenXrInput.cpp (1078 Zeilen) neu zu schreiben, werden hier diese
// sechzehn Funktionen auf visionOS-APIs abgebildet. JKXRs Eingabelogik —
// Bindings, Waffenausrichtung, Gestenerkennung — bleibt damit unverändert.
//
// Die Abbildung ist erstaunlich direkt, weil Apples Accessory-Tracking den
// OpenXR-Konventionen folgt:
//
//   ar_accessory_location_name_grip / _aim   ==  /input/grip, /input/aim
//   ar_accessory_tracking_provider_predict_anchor_at_timestamp
//                                            ==  xrLocateSpace(time)
//
//   Posen und Geschwindigkeiten  ->  ARKit  (ar_accessory_tracking_provider)
//   Tasten, Achsen, Haptik       ->  GameController (SpatialController)

#include "TBXR_Common.h"

#import <ARKit/ARKit.h>
#import <GameController/GameController.h>

// Von TBXR_Common.mm bereitgestellt.
extern "C" void TBXR_visionOS_Vibrate(int hand, float amplitude, float seconds);

// Aus der Engine.
//
// NICHT extern "C": Com_Printf ist dort C++ (qcommon.h:615), und eine
// C-Bindung suchte einen Namen, den es nicht gibt. QDECL steht hier nicht,
// weil q_platform.h in dieser Datei nicht eingebunden ist -- auf arm64 ist das
// Makro leer, die Signatur stimmt also ueberein.
void Com_Printf(const char *fmt, ...);

/// Wann die Zuordnung der Controller zuletzt gewechselt hat, 0 = nie.
static CFTimeInterval gMappingChangedAt = 0.0;

/// Wie lange danach keine Tasten gemeldet werden.
///
/// Lang genug, dass der Wechsel abgeschlossen ist, kurz genug, dass ein echter
/// Druck in dieser Zeit nicht auffaellt -- er wird ohnehin gehalten und kommt
/// im naechsten Bild durch.
static const CFTimeInterval BERUHIGUNG = 0.30;

/// Gilt gerade das Beruhigungsfenster?
static bool mappingBeruhigt(void)
{
    return gMappingChangedAt > 0.0 &&
           (CACurrentMediaTime() - gMappingChangedAt) < BERUHIGUNG;
}

// Vom App-Ziel bereitgestellt (Sources/Bridge/WorldTracking.m). Liefert das
// GCDevice einer Hand, dessen Händigkeit ARKit über
// ar_accessory_get_inherent_chirality bestimmt hat — dieselbe Quelle, aus der
// auch die Posen stammen. Vor dem Anlaufen der Zubehörverfolgung nil.
extern "C" void *TBXR_visionOS_GetSpatialDevice(int hand);

/// XrTime ist in Nanosekunden, CFTimeInterval in Sekunden.
static inline CFTimeInterval XrTimeToSeconds(XrTime time)
{
    return (CFTimeInterval)time / 1000000000.0;
}

#include <string>
#include <unordered_map>
#include <vector>

namespace {

// ---------------------------------------------------------------------------
// Pfade
//
// OpenXR adressiert alles über Zeichenketten-Pfade wie
// "/user/hand/left/input/trigger/value", die zur Laufzeit in XrPath-Handles
// übersetzt werden. Hier genügt eine fortlaufende Nummer je Pfad.
// ---------------------------------------------------------------------------

std::vector<std::string> gPaths{""};   // Index 0 bleibt frei: XR_NULL_PATH
std::unordered_map<std::string, XrPath> gPathLookup;

XrPath internPath(const std::string &text)
{
    auto found = gPathLookup.find(text);
    if (found != gPathLookup.end()) return found->second;
    gPaths.push_back(text);
    XrPath path = static_cast<XrPath>(gPaths.size() - 1);
    gPathLookup[text] = path;
    return path;
}

// ---------------------------------------------------------------------------
// Aktionen
// ---------------------------------------------------------------------------

struct Action {
    std::string name;
    XrActionType type;
    std::vector<XrPath> subactionPaths;
    // Aus xrSuggestInteractionProfileBindings: welcher Eingabepfad steuert
    // diese Aktion. Ohne die Zuordnung wüssten wir nicht, welche Taste gemeint
    // ist — JKXR legt sie einmalig beim Start fest.
    std::vector<std::string> bindings;
};

std::vector<Action *> gActions;
std::vector<void *>   gActionSets;

/// Handles sind undurchsichtige Zeiger. Ein Zeiger auf unser eigenes Objekt
/// erfüllt den Vertrag genauso wie ein Laufzeit-internes Handle.
inline Action *toAction(XrAction handle) { return reinterpret_cast<Action *>(handle); }

// ---------------------------------------------------------------------------
// Geräte
// ---------------------------------------------------------------------------

ar_accessory_tracking_provider_t gTracking = nullptr;

/// Die beiden Sense-Controller, nach Händigkeit sortiert. GameController
/// liefert Tasten, ARKit die Posen — beide zum selben Gerät.
GCController *gControllers[2] = { nil, nil };

int handIndexForPath(const std::string &path)
{
    // OpenXR-Pfade beginnen mit /user/hand/left oder /user/hand/right.
    if (path.find("/user/hand/left") == 0)  return 0;
    if (path.find("/user/hand/right") == 0) return 1;
    return -1;
}

/// Bildet einen OpenXR-Eingabepfad auf den Namen eines GameController-Elements ab.
///
/// Die Namen im Rumpf sind auf dem Gerät GEMESSEN, nicht geraten --
/// TBXR_visionOS_DumpInputs gibt sie aus. (Ein früherer Kopf dieser Funktion
/// behauptete das Gegenteil und stand damit im Widerspruch zu seinem eigenen
/// Rumpf.)
///
/// Gesucht wird über `physicalInputProfile` statt über `extendedGamepad`: das
/// Profil legt alle Elemente als zeichenkettenindizierte Sammlung offen, und ein
/// unbekannter Name führt dann zu "nicht gefunden" statt zu einem falschen
/// Element.
/// Wahr, wenn beide Hände auf demselben Gerät liegen (kombiniertes Gamepad).
bool gCombinedDevice = false;

NSString *gcNameForInputPath(const std::string &path, int hand)
{
    auto ends = [&](const char *suffix) {
        const size_t len = strlen(suffix);
        return path.size() >= len && path.compare(path.size() - len, len, suffix) == 0;
    };

    const bool left = (hand == 0);

    // ZWEI gemessene Gerätezustände, beide müssen bedient werden.
    //
    // A) Zwei Spatial Controller — "PlayStation VR2 Sense Controller (L)" und
    //    "(R)", je mit eigenem, UNPRÄFIXIERTEM Elementsatz:
    //       Trigger · Grip · Thumbstick · Thumbstick Button
    //       Button A · Button B · Button Menu
    //    Die Hand steckt im Gerät. Auf dem linken sind Quadrat und Dreieck als
    //    "Button A"/"Button B" ausgewiesen — OpenXR nennt sie X und Y.
    //
    // B) Ein kombiniertes Gerät der Kategorie "MFi", das sich als
    //    "... Controllers (L/R)" meldet und die üblichen präfixierten Namen
    //    trägt: "Left Trigger", "Right Thumbstick", "Button X" und so fort.
    //    Diesen Zustand liefert visionOS, solange die Zubehörverfolgung nicht
    //    läuft.
    if (gCombinedDevice) {
        if (ends("/trigger/value") || ends("/trigger"))
            return left ? GCInputLeftTrigger : GCInputRightTrigger;
        if (ends("/squeeze/value") || ends("/squeeze"))
            return left ? GCInputLeftShoulder : GCInputRightShoulder;
        if (ends("/thumbstick/click"))
            return left ? GCInputLeftThumbstickButton : GCInputRightThumbstickButton;
        if (ends("/thumbstick"))
            return left ? GCInputLeftThumbstick : GCInputRightThumbstick;
        if (ends("/a/click"))     return GCInputButtonA;
        if (ends("/b/click"))     return GCInputButtonB;
        if (ends("/x/click"))     return GCInputButtonX;
        if (ends("/y/click"))     return GCInputButtonY;
        if (ends("/menu/click"))  return GCInputButtonMenu;
        return nil;
    }

    if (ends("/trigger/value") || ends("/trigger"))  return @"Trigger";
    if (ends("/squeeze/value") || ends("/squeeze"))  return @"Grip";
    if (ends("/thumbstick/click"))                   return @"Thumbstick Button";
    if (ends("/thumbstick"))                         return @"Thumbstick";
    if (ends("/menu/click"))                         return @"Button Menu";
    if (ends("/x/click"))  return left  ? @"Button A" : nil;
    if (ends("/y/click"))  return left  ? @"Button B" : nil;
    if (ends("/a/click"))  return !left ? @"Button A" : nil;
    if (ends("/b/click"))  return !left ? @"Button B" : nil;
    return nil;
}

/// Sucht den Eingabepfad einer Aktion für eine bestimmte Hand.
const std::string *bindingForHand(const Action *action, int hand)
{
    for (const std::string &binding : action->bindings) {
        if (handIndexForPath(binding) == hand) return &binding;
    }
    return action->bindings.empty() ? nullptr : &action->bindings.front();
}

int handForSubaction(const Action *action, XrPath subactionPath)
{
    if (subactionPath == XR_NULL_PATH || subactionPath >= gPaths.size()) {
        // Ohne Angabe: die erste gebundene Hand.
        for (const std::string &binding : action->bindings) {
            int hand = handIndexForPath(binding);
            if (hand >= 0) return hand;
        }
        return 0;
    }
    int hand = handIndexForPath(gPaths[subactionPath]);
    return hand < 0 ? 0 : hand;
}

GCControllerButtonInput *buttonFor(const Action *action, int hand)
{
    GCController *controller = (hand >= 0 && hand < 2) ? gControllers[hand] : nil;
    if (!controller) return nil;

    const std::string *binding = bindingForHand(action, hand);
    if (!binding) return nil;
    NSString *name = gcNameForInputPath(*binding, hand);
    if (!name) return nil;

    // physicalInputProfile statt einer konkreten Profilklasse: es legt jedes
    // Element als zeichenkettenindizierte Sammlung offen. Ein unbekannter Name
    // liefert dann nil, statt dass eine Profilklasse angenommen wird, die das
    // Gerät womöglich gar nicht anbietet.
    GCControllerButtonInput *button = controller.physicalInputProfile.buttons[name];
    return button;
}

} // namespace

// ---------------------------------------------------------------------------
// Anbindung an die SwiftUI-Hülle
// ---------------------------------------------------------------------------

extern "C" void TBXR_visionOS_SetAccessoryTracking(void *provider)
{
    gTracking = (__bridge ar_accessory_tracking_provider_t)provider;
}

extern "C" void TBXR_visionOS_RefreshControllers(void)
{
    // Bei jeder Änderung ausgeben, was tatsächlich da ist.
    //
    // TBXR_visionOS_DumpInputs läuft nur einmal beim Start, und da hat
    // GameController noch nichts gemeldet — die Erkennung ist asynchron. Ohne
    // diese Ausgabe sieht man nie, ob ein Controller ankommt, welche Kategorie
    // er meldet und wie seine Elemente heißen.
    //
    // Ausgegeben wird JEDER Controller, nicht nur SpatialController: falls die
    // Sense-Controller eine andere Kategorie melden, würde der Filter unten sie
    // stillschweigend verwerfen, und man stünde ohne Hinweis da.
    {
        static NSUInteger lastCount = NSUIntegerMax;
        NSArray<GCController *> *all = [GCController controllers];
        if (all.count != lastCount) {
            lastCount = all.count;
            fprintf(stderr, "[TBXR] %lu Controller verbunden\n",
                    (unsigned long)all.count);
            for (GCController *c in all) {
                fprintf(stderr, "[TBXR]   %s · %s · Kategorie \"%s\" · playerIndex %ld\n",
                        c.vendorName.UTF8String ?: "?",
                        c.productCategory.UTF8String ?: "?",
                        c.productCategory.UTF8String ?: "?",
                        (long)c.playerIndex);
                for (NSString *n in c.physicalInputProfile.buttons)
                    fprintf(stderr, "[TBXR]     Taste: %s\n", n.UTF8String);
                for (NSString *n in c.physicalInputProfile.dpads)
                    fprintf(stderr, "[TBXR]     Stick: %s\n", n.UTF8String);
                for (NSString *n in c.physicalInputProfile.axes)
                    fprintf(stderr, "[TBXR]     Achse: %s\n", n.UTF8String);
            }
        }
    }

    // Beide Gerätezustände erkennen (siehe gcNameForInputPath).
    gControllers[0] = gControllers[1] = nil;
    gCombinedDevice = false;

    // Die Händigkeit von ARKit übernehmen, nicht raten.
    //
    // Hier stand vorher eine Suche nach "(L)" und "(R)" im Gerätenamen, mit der
    // Verbindungsreihenfolge als Rückfall. Das ging schief, sobald die Namen
    // diese Kennzeichnung nicht tragen: der zuerst verbundene Controller wurde
    // dann die linke Hand. Und weil die POSEN aus derselben ARKit-Quelle kommen
    // wie sSpatialDevices, während die TASTEN aus dieser Ratung kamen, konnten
    // beide auseinanderlaufen — im Menü zeigte die eine Hand und die andere
    // musste klicken.
    //
    // WorldTracking.m löst die Frage längst richtig: es lädt jedes Zubehör über
    // ar_accessory_load_from_device und liest ar_accessory_get_inherent_chirality.
    // Dasselbe Gerät, dieselbe Händigkeit, EINE Quelle für Pose und Taste.
    //
    // Der Namenspfad bleibt als Rückfall stehen: die Zubehörverfolgung läuft
    // asynchron an, und bis sie steht, ist eine geratene Zuordnung besser als
    // gar keine Eingabe.
    GCController *ausArkit[2] = { nil, nil };
    for (int hand = 0; hand < 2; ++hand) {
        id geraet = (__bridge id)TBXR_visionOS_GetSpatialDevice(hand);
        if ([geraet isKindOfClass:[GCController class]]) {
            ausArkit[hand] = (GCController *)geraet;
        }
    }

    for (GCController *controller in [GCController controllers]) {
        GCPhysicalInputProfile *profile = controller.physicalInputProfile;

        // Kombiniertes Gerät: erkennbar an den präfixierten Elementnamen.
        // Beide Hände zeigen dann auf dasselbe Objekt.
        if (profile.buttons[GCInputLeftTrigger] && profile.buttons[GCInputRightTrigger]) {
            gControllers[0] = gControllers[1] = controller;
            gCombinedDevice = true;
            break;
        }

        if (controller == ausArkit[0])      gControllers[0] = controller;
        else if (controller == ausArkit[1]) gControllers[1] = controller;
    }

    // Nur was ARKit offen lässt, wird geraten — und getrennt vom Durchgang
    // oben, damit ein von ARKit bestätigter Controller nicht von einem
    // geratenen verdrängt wird.
    if (!gCombinedDevice && (!gControllers[0] || !gControllers[1])) {
        for (GCController *controller in [GCController controllers]) {
            if (controller == gControllers[0] || controller == gControllers[1]) continue;
            NSString *name = controller.vendorName ?: @"";
            if ([name containsString:@"(L)"] && !gControllers[0])      gControllers[0] = controller;
            else if ([name containsString:@"(R)"] && !gControllers[1]) gControllers[1] = controller;
            else if (!gControllers[0])                                 gControllers[0] = controller;
            else if (!gControllers[1])                                 gControllers[1] = controller;
        }
    }

    // Einmal melden, auf welchem Weg die Zuordnung zustande kam. Ohne das bleibt
    // eine vertauschte Steuerung eine Vermutung — so steht sie im Protokoll.
    {
        static GCController *gemeldet[2] = { nil, nil };
        static bool kombiniertGemeldet = false;
        if (gControllers[0] != gemeldet[0] || gControllers[1] != gemeldet[1] ||
            gCombinedDevice != kombiniertGemeldet) {
            const bool ersteZuordnung = (gemeldet[0] == nil && gemeldet[1] == nil);
            gemeldet[0] = gControllers[0];
            gemeldet[1] = gControllers[1];
            kombiniertGemeldet = gCombinedDevice;

            // Nach einem Wechsel kurz keine Tasten melden.
            //
            // visionOS reicht die Controller in ZWEI Zustaenden heraus: erst ein
            // kombiniertes MFi-Geraet, und sobald die Zubehoerverfolgung laeuft,
            // zwei getrennte Spatial Controller mit ganz anderen Elementnamen
            // (siehe gcNameForInputPath). Beim Umbruch zeigt derselbe
            // Tastenzustand auf ein anderes Element -- und die Engine sieht eine
            // FLANKE, obwohl niemand etwas gedrueckt hat.
            //
            // Das ist nicht theoretisch: waehrend einer Filmsequenz genuegt eine
            // einzige solche Flanke, um sie abzubrechen (CL_KeyDownEvent
            // beendet sie bei JEDER Taste, cl_keys.cpp:1244). Der Umbruch faellt
            // genau in die Startphase -- Videos und erste Sequenz.
            //
            // Beim allerersten Zuordnen ist nichts zu unterdruecken: davor gab
            // es keinen Zustand, aus dem eine Flanke entstehen koennte.
            if (!ersteZuordnung) {
                gMappingChangedAt = CACurrentMediaTime();
            }

            // Ueber Com_Printf, nicht fprintf: stderr landet nicht in
            // qconsole.log, und genau dort braucht man diese Zeile.
            Com_Printf("[TBXR] Haende: links %s (ARKit %s) · rechts %s (ARKit %s)%s\n",
                       gControllers[0].vendorName.UTF8String ?: "-",
                       ausArkit[0] ? "ja" : "nein",
                       gControllers[1].vendorName.UTF8String ?: "-",
                       ausArkit[1] ? "ja" : "nein",
                       gCombinedDevice ? " · kombiniertes Geraet" : "");
        }
    }
}

// ---------------------------------------------------------------------------
// Pfade
// ---------------------------------------------------------------------------

/// Gibt aus, wie die verbundenen Controller ihre Elemente tatsächlich benennen.
///
/// Ohne diese Ausgabe bleibt die Tastenzuordnung Raterei: welche Namen ein
/// räumlicher Controller anbietet, steht nirgends geschrieben. Beim ersten Lauf
/// auf echter Hardware einmal aufrufen und gcNameForInputPath danach ausrichten.
extern "C" void TBXR_visionOS_DumpInputs(void)
{
    for (GCController *controller in [GCController controllers]) {
        fprintf(stderr, "[TBXR] Controller: %s · %s\n",
                controller.vendorName.UTF8String ?: "?",
                controller.productCategory.UTF8String ?: "?");
        for (NSString *name in controller.physicalInputProfile.buttons) {
            fprintf(stderr, "[TBXR]   Taste:  %s\n", name.UTF8String);
        }
        for (NSString *name in controller.physicalInputProfile.axes) {
            fprintf(stderr, "[TBXR]   Achse:  %s\n", name.UTF8String);
        }
        for (NSString *name in controller.physicalInputProfile.dpads) {
            fprintf(stderr, "[TBXR]   Stick:  %s\n", name.UTF8String);
        }
    }
}

extern "C" XrResult xrStringToPath(XrInstance, const char *pathString, XrPath *path)
{
    *path = internPath(pathString ? pathString : "");
    return XR_SUCCESS;
}

extern "C" XrResult xrPathToString(XrInstance, XrPath path, uint32_t capacity,
                                   uint32_t *countOutput, char *buffer)
{
    const std::string &text = (path < gPaths.size()) ? gPaths[path] : gPaths[0];
    *countOutput = static_cast<uint32_t>(text.size() + 1);
    if (capacity == 0) return XR_SUCCESS;
    if (capacity < *countOutput) return XR_ERROR_SIZE_INSUFFICIENT;
    memcpy(buffer, text.c_str(), *countOutput);
    return XR_SUCCESS;
}

extern "C" XrResult xrResultToString(XrInstance, XrResult value, char buffer[XR_MAX_RESULT_STRING_SIZE])
{
    snprintf(buffer, XR_MAX_RESULT_STRING_SIZE,
             value >= 0 ? "XR_SUCCESS(%d)" : "XR_ERROR(%d)", (int)value);
    return XR_SUCCESS;
}

// ---------------------------------------------------------------------------
// Aktionen anlegen
// ---------------------------------------------------------------------------

extern "C" XrResult xrCreateActionSet(XrInstance, const XrActionSetCreateInfo *info,
                                      XrActionSet *actionSet)
{
    gActionSets.push_back(new std::string(info ? info->actionSetName : ""));
    *actionSet = reinterpret_cast<XrActionSet>(gActionSets.back());
    return XR_SUCCESS;
}

extern "C" XrResult xrCreateAction(XrActionSet, const XrActionCreateInfo *info,
                                   XrAction *action)
{
    Action *created = new Action();
    created->name = info ? info->actionName : "";
    created->type = info ? info->actionType : XR_ACTION_TYPE_BOOLEAN_INPUT;
    if (info) {
        for (uint32_t i = 0; i < info->countSubactionPaths; ++i)
            created->subactionPaths.push_back(info->subactionPaths[i]);
    }
    gActions.push_back(created);
    *action = reinterpret_cast<XrAction>(created);
    return XR_SUCCESS;
}

extern "C" XrResult xrSuggestInteractionProfileBindings(
    XrInstance, const XrInteractionProfileSuggestedBinding *bindings)
{
    if (!bindings) return XR_SUCCESS;
    for (uint32_t i = 0; i < bindings->countSuggestedBindings; ++i) {
        const XrActionSuggestedBinding &suggestion = bindings->suggestedBindings[i];
        Action *action = toAction(suggestion.action);
        if (!action) continue;
        if (suggestion.binding < gPaths.size())
            action->bindings.push_back(gPaths[suggestion.binding]);
    }
    return XR_SUCCESS;
}

extern "C" XrResult xrAttachSessionActionSets(XrSession, const XrSessionActionSetsAttachInfo *)
{
    // In OpenXR friert dieser Aufruf die Aktionen ein. Hier gibt es nichts
    // einzufrieren — die Bindings liegen bereits vor.
    return XR_SUCCESS;
}

extern "C" XrResult xrCreateActionSpace(XrSession, const XrActionSpaceCreateInfo *info,
                                        XrSpace *space)
{
    // Der Raum einer Pose-Aktion ist durch die Aktion UND die Hand bestimmt.
    //
    // Bisher war das Handle nur der Aktionszeiger, info->subactionPath wurde
    // verworfen. Beide Hände bekamen damit denselben Raum, und xrLocateSpace
    // konnte die Hand nicht mehr ermitteln — es nahm mangels Pfad immer 0.
    // Gemessen: die Posenabfrage lief einwandfrei, meldete aber ausschließlich
    // "Hand 0", also für beide Hände den linken Controller.
    //
    // Die Hand wandert deshalb ins unterste Bit des Handles. Aktionszeiger
    // sind mindestens auf 2 Byte ausgerichtet, das Bit ist frei.
    Action *action = toAction(info ? info->action : nullptr);
    const int hand = handForSubaction(action, info ? info->subactionPath : XR_NULL_PATH);
    *space = reinterpret_cast<XrSpace>(
        reinterpret_cast<uintptr_t>(action) | (uintptr_t)(hand & 1));
    return XR_SUCCESS;
}

// ---------------------------------------------------------------------------
// Zustand abfragen
// ---------------------------------------------------------------------------

extern "C" XrResult xrSyncActions(XrSession, const XrActionsSyncInfo *)
{
    // OpenXR holt hier einen konsistenten Schnappschuss. GameController und
    // ARKit liefern jederzeit aktuelle Werte; nur die Controllerliste muss
    // aktuell gehalten werden, falls einer dazukommt oder verschwindet.
    TBXR_visionOS_RefreshControllers();
    return XR_SUCCESS;
}

/// Meldet einen Tastenzustand erst, wenn er sich eine Weile gehalten hat.
///
/// Ein Flackern von wenigen Bildern faellt damit weg, ein echter Druck kommt
/// verzoegert, aber vollstaendig durch -- man haelt ihn ohnehin laenger.
static bool entprellt(const void *action, int hand, bool roh)
{
    // Vier Eintraege genuegen: die Entprellung gilt nur der Menuetaste, und die
    // gibt es je Hand einmal.
    struct Eintrag { const void *action; int hand; bool roh; bool stabil; CFTimeInterval seit; };
    static Eintrag eintraege[4] = {};

    Eintrag *e = nullptr;
    for (Eintrag &kandidat : eintraege) {
        if (kandidat.action == action && kandidat.hand == hand) { e = &kandidat; break; }
        if (kandidat.action == nullptr && !e) { e = &kandidat; }
    }
    if (!e) return roh;

    const CFTimeInterval jetzt = CACurrentMediaTime();
    if (e->action != action || e->hand != hand) {
        *e = { action, hand, roh, roh, jetzt };
        return e->stabil;
    }

    if (roh != e->roh) {
        e->roh = roh;
        e->seit = jetzt;
    } else if (roh != e->stabil && (jetzt - e->seit) >= 0.08) {
        e->stabil = roh;
    }
    return e->stabil;
}

/// Endet die Bindung dieser Aktion auf den angegebenen Pfad?
static bool bindungEndetAuf(const void *action, int hand, const char *ende)
{
    const std::string *b = bindingForHand(
        reinterpret_cast<const Action *>(action), hand);
    if (!b) return false;
    const size_t len = strlen(ende);
    return b->size() >= len && b->compare(b->size() - len, len, ende) == 0;
}

/// Schaltschwelle mit Hysterese: an ab 0,80, aus unter 0,35.
static bool schmitt(const void *action, int hand, float wert)
{
    struct Eintrag { const void *action; int hand; bool an; };
    static Eintrag eintraege[4] = {};

    Eintrag *e = nullptr;
    for (Eintrag &kandidat : eintraege) {
        if (kandidat.action == action && kandidat.hand == hand) { e = &kandidat; break; }
        if (kandidat.action == nullptr && !e) { e = &kandidat; }
    }
    if (!e) return wert > 0.5f;

    e->action = action;
    e->hand = hand;
    if (e->an) {
        if (wert < 0.35f) e->an = false;
    } else {
        if (wert >= 0.80f) e->an = true;
    }
    return e->an;
}

extern "C" XrResult xrGetActionStateBoolean(XrSession, const XrActionStateGetInfo *info,
                                            XrActionStateBoolean *state)
{
    memset(state, 0, sizeof(*state));
    state->type = XR_TYPE_ACTION_STATE_BOOLEAN;

    Action *action = toAction(info ? info->action : nullptr);
    if (!action) return XR_SUCCESS;

    GCControllerButtonInput *button = buttonFor(action, handForSubaction(action, info->subactionPath));
    if (!button) return XR_SUCCESS;

    // Waehrend der Beruhigung "nicht gedrueckt" melden. Ein Loslassen ist
    // harmlos -- die Filmsequenz bricht nur bei CL_KeyDownEvent ab.
    if (mappingBeruhigt()) {
        state->isActive = XR_TRUE;
        return XR_SUCCESS;
    }

    bool gedrueckt = button.pressed;

    // Die Menuetaste entprellen.
    //
    // GEMESSEN auf dem Geraet: das Element "Button Menu" des RECHTEN
    // Sense-Controllers meldet von sich aus Flanken, ohne dass es beruehrt wird
    // -- im Protokoll als Wechsel 0 -> 2 -> 0 -> 2 binnen weniger Bilder. Diese
    // Taste liegt auf A_ESCAPE, und eine einzige Flanke beendet eine laufende
    // Filmsequenz (cl_keys.cpp:1244). Genau daran starben die Szenen nach
    // hundert Millisekunden.
    //
    // Nur diese eine Taste, nicht alle: eine Entprellung kostet Reaktionszeit,
    // und beim Trigger waere das im Kampf zu spueren. Beim Menue faellt sie
    // nicht auf.
    if (bindungEndetAuf(action, handForSubaction(action, info->subactionPath),
                        "/menu/click")) {
        gedrueckt = entprellt(action, handForSubaction(action, info->subactionPath), gedrueckt);
    }

    state->currentState = gedrueckt ? XR_TRUE : XR_FALSE;
    state->isActive = XR_TRUE;
    return XR_SUCCESS;
}

extern "C" XrResult xrGetActionStateFloat(XrSession, const XrActionStateGetInfo *info,
                                          XrActionStateFloat *state)
{
    memset(state, 0, sizeof(*state));
    state->type = XR_TYPE_ACTION_STATE_FLOAT;

    Action *action = toAction(info ? info->action : nullptr);
    if (!action) return XR_SUCCESS;

    GCControllerButtonInput *button = buttonFor(action, handForSubaction(action, info->subactionPath));
    if (!button) return XR_SUCCESS;

    // Auch den Analogwert: der Trigger wird ueber ihn zur Taste gemacht
    // (OpenXrInput.cpp:876, Schwelle 0,5).
    if (mappingBeruhigt()) {
        state->isActive = XR_TRUE;
        return XR_SUCCESS;
    }

    float wert = button.value;

    // Schaltschwelle mit Hysterese fuer den Trigger.
    //
    // JKXR macht daraus eine Taste mit EINER Schwelle: IndexTrigger > 0,5
    // (OpenXrInput.cpp:876). Auf den Sense-Controllern genuegt ein aufliegender
    // Finger, um sie mehrfach zu ueberqueren -- GEMESSEN waehrend einer
    // Filmsequenz: 0,649 · 0,435 · 0,823 · 0,075 binnen weniger Bilder. Jede
    // Ueberquerung ist ein Druck, und ein Druck beendet die Sequenz.
    //
    // Zwei getrennte Schwellen loesen das: gedrueckt erst ab 0,80, losgelassen
    // erst unter 0,35. Ein bewusster Zug erreicht 1,000 und wirkt weiter, ein
    // aufliegender Finger nicht mehr.
    //
    // Zurueckgegeben wird ein Wert, der zur Entscheidung PASST -- die Engine
    // schwellt bei 0,5, also muss er auf der richtigen Seite liegen. Die
    // Groessenordnung bleibt erhalten, wo sie es kann.
    if (bindungEndetAuf(action, handForSubaction(action, info->subactionPath),
                        "/trigger/value")) {
        const bool gedrueckt = schmitt(action,
            handForSubaction(action, info->subactionPath), wert);
        if (gedrueckt && wert < 0.55f)  wert = 0.55f;
        if (!gedrueckt && wert > 0.45f) wert = 0.45f;
    }

    state->currentState = wert;
    state->isActive = XR_TRUE;
    return XR_SUCCESS;
}

extern "C" XrResult xrGetActionStateVector2f(XrSession, const XrActionStateGetInfo *info,
                                             XrActionStateVector2f *state)
{
    memset(state, 0, sizeof(*state));
    state->type = XR_TYPE_ACTION_STATE_VECTOR2F;

    Action *action = toAction(info ? info->action : nullptr);
    if (!action) return XR_SUCCESS;

    const int hand = handForSubaction(action, info->subactionPath);
    GCController *controller = (hand >= 0 && hand < 2) ? gControllers[hand] : nil;
    if (!controller) return XR_SUCCESS;

    const std::string *binding = bindingForHand(action, hand);
    NSString *name = binding ? gcNameForInputPath(*binding, hand) : nil;
    GCControllerDirectionPad *stick =
        name ? controller.physicalInputProfile.dpads[name] : nil;
    if (!stick) return XR_SUCCESS;

    state->currentState.x = stick.xAxis.value;
    state->currentState.y = stick.yAxis.value;
    state->isActive = XR_TRUE;
    return XR_SUCCESS;
}

extern "C" XrResult xrGetCurrentInteractionProfile(
    XrSession, XrPath, XrInteractionProfileState *profile)
{
    if (!profile) return XR_SUCCESS;
    profile->type = XR_TYPE_INTERACTION_PROFILE_STATE;
    // JKXR kennt TOUCH_CONTROLLERS und emuliert alles Unbekannte als Touch.
    // Die Sense-Controller entsprechen dem Touch-Layout am ehesten.
    profile->interactionProfile =
        internPath("/interaction_profiles/oculus/touch_controller");
    return XR_SUCCESS;
}

// ---------------------------------------------------------------------------
// Posen
// ---------------------------------------------------------------------------

extern "C" XrResult xrLocateSpace(XrSpace space, XrSpace, XrTime time,
                                  XrSpaceLocation *location)
{
    if (!location) return XR_SUCCESS;
    location->locationFlags = 0;

    // Hand aus dem untersten Bit des Handles, siehe xrCreateActionSpace.
    const uintptr_t raw = reinterpret_cast<uintptr_t>(space);
    const int hand = (int)(raw & 1);
    Action *action = reinterpret_cast<Action *>(raw & ~(uintptr_t)1);
    if (!action || !gTracking) return XR_SUCCESS;
    const std::string *binding = bindingForHand(action, hand);

    // Grip oder Aim: OpenXR unterscheidet Griffpose (Handhaltung) und
    // Zielpose (Blickrichtung der Waffe). ARKit kennt dieselbe Unterscheidung
    // unter denselben Namen.
    const char *locationName =
        (binding && binding->find("/aim") != std::string::npos)
            ? ar_accessory_location_name_aim
            : ar_accessory_location_name_grip;

    // Der Ablauf ist zweistufig: erst den aktuellen Anker der gesuchten Hand
    // finden, dann auf den Anzeigezeitpunkt vorhersagen. Die Vorhersage ist
    // nötig, weil zwischen Abfrage und Anzeige ein paar Millisekunden liegen.
    ar_accessory_anchors_t anchors =
        ar_accessory_tracking_provider_get_latest_anchors(gTracking);
    if (!anchors) return XR_SUCCESS;

    // Händigkeit zuerst am GERÄT, nicht an der Haltung.
    //
    // ar_accessory_anchor_get_held_chirality sagt, in welcher Hand das Gerät
    // gerade gehalten wird — das kann unbestimmt sein. Gemessen: einer der
    // beiden Anker meldete damit weder links noch rechts, wodurch beide auf
    // Hand 1 passten und Hand 0 leer ausging ("passend 0").
    //
    // ar_accessory_get_inherent_chirality ist dagegen die feste Bauform des
    // Controllers und genau das, was ARKit beim Laden schon geliefert hat
    // (links 1, rechts 2). Die Haltung dient nur noch als Rückfall für
    // Zubehör ohne eigene Händigkeit.
    __block ar_accessory_anchor_t source = nil;
    ar_accessory_anchors_enumerate_anchors(anchors,
        ^bool(ar_accessory_anchor_t candidate) {
            ar_accessory_t accessory = ar_accessory_anchor_get_accessory(candidate);
            ar_accessory_chirality_t chirality =
                accessory ? ar_accessory_get_inherent_chirality(accessory)
                          : ar_accessory_chirality_unspecified;
            if (chirality == ar_accessory_chirality_unspecified) {
                chirality = ar_accessory_anchor_get_held_chirality(candidate);
            }
            if (chirality == ar_accessory_chirality_unspecified) return true;

            const bool isLeft = (chirality == ar_accessory_chirality_left);
            if ((hand == 0) == isLeft) { source = candidate; return false; }
            return true;
        });
    // Wo bricht die Kette ab? Vier Ausstiegspunkte, alle still.
    {
        static int n = 0;
        if ((++n % 90) == 0) {
            __block size_t count = 0;
            ar_accessory_anchors_enumerate_anchors(anchors,
                ^bool(ar_accessory_anchor_t) { ++count; return true; });
            fprintf(stderr,
                    "[Pose] Hand %d · %zu Anker · passend %d · getrackt %d · %s\n",
                    hand, count, source ? 1 : 0,
                    source ? (int)ar_accessory_anchor_is_tracked(source) : -1,
                    locationName ? locationName : "?");
        }
    }

    if (!source || !ar_accessory_anchor_is_tracked(source)) return XR_SUCCESS;

    ar_accessory_anchor_t anchor = ar_accessory_anchor_create();
    if (!ar_accessory_tracking_provider_predict_anchor_at_timestamp(
            gTracking, source, XrTimeToSeconds(time), anchor)) {
        anchor = source;   // ohne Vorhersage lieber die aktuelle Pose als keine
    }

    // Zwei Transformationen, nicht eine.
    //
    // anchor_from_location ist die Lage des benannten Punktes (Griff, Ziel)
    // RELATIV ZUM ANKER — ein kleiner, praktisch konstanter Versatz. Sie allein
    // zu nehmen war der Fehler: die Winkel blieben dadurch konstant bei null,
    // egal wie der Controller gehalten wurde, obwohl die Verfolgung einwandfrei
    // lief und beide Anker als getrackt gemeldet wurden.
    //
    // Die Pose im Raum ist origin_from_anchor. Der gesuchte Punkt liegt bei
    //     origin_from_location = origin_from_anchor * anchor_from_location
    const simd_float4x4 originFromAnchor =
        ar_accessory_anchor_get_origin_from_anchor_transform(anchor);
    const simd_float4x4 anchorFromLocation =
        ar_accessory_anchor_get_anchor_from_location_transform_with_correction(
            anchor, locationName, ar_transform_correction_none);
    simd_float4x4 transform = simd_mul(originFromAnchor, anchorFromLocation);

    location->pose.position = { transform.columns[3].x,
                                transform.columns[3].y,
                                transform.columns[3].z };
    simd_quatf rotation = simd_quaternion(transform);
    location->pose.orientation = { rotation.vector.x, rotation.vector.y,
                                   rotation.vector.z, rotation.vector.w };
    location->locationFlags = XR_SPACE_LOCATION_POSITION_VALID_BIT |
                              XR_SPACE_LOCATION_ORIENTATION_VALID_BIT |
                              XR_SPACE_LOCATION_POSITION_TRACKED_BIT |
                              XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT;

    // Geschwindigkeiten weiterreichen, falls angefordert: JKXRs
    // Schwung- und Stichentdeckung hängt daran.
    if (location->next) {
        XrSpaceVelocity *velocity = static_cast<XrSpaceVelocity *>(location->next);
        if (velocity->type == XR_TYPE_SPACE_VELOCITY) {
            simd_float3 linear  = ar_accessory_anchor_get_velocity(anchor);
            simd_float3 angular = ar_accessory_anchor_get_angular_velocity(anchor);
            velocity->linearVelocity  = { linear.x, linear.y, linear.z };
            velocity->angularVelocity = { angular.x, angular.y, angular.z };
            velocity->velocityFlags = XR_SPACE_VELOCITY_LINEAR_VALID_BIT |
                                      XR_SPACE_VELOCITY_ANGULAR_VALID_BIT;
        }
    }
    return XR_SUCCESS;
}

// ---------------------------------------------------------------------------
// Haptik
// ---------------------------------------------------------------------------

extern "C" XrResult xrApplyHapticFeedback(XrSession, const XrHapticActionInfo *info,
                                          const XrHapticBaseHeader *header)
{
    Action *action = toAction(info ? info->action : nullptr);
    if (!action || !header) return XR_SUCCESS;

    const int hand = handForSubaction(action, info->subactionPath);
    GCController *controller = (hand >= 0 && hand < 2) ? gControllers[hand] : nil;
    if (!controller) return XR_SUCCESS;

    const XrHapticVibration *vibration =
        (header->type == XR_TYPE_HAPTIC_VIBRATION)
            ? reinterpret_cast<const XrHapticVibration *>(header) : nullptr;
    if (!vibration) return XR_SUCCESS;

    // PSVR2 Sense unterstützt Vibration, aber weder die adaptiven Trigger noch
    // die Präzisionshaptik der PlayStation. Amplitude genügt für JKXR.
    TBXR_visionOS_Vibrate(hand, vibration->amplitude,
                          vibration->duration / 1000000000.0f);
    return XR_SUCCESS;
}

extern "C" XrResult xrStopHapticFeedback(XrSession, const XrHapticActionInfo *info)
{
    Action *action = toAction(info ? info->action : nullptr);
    if (action) TBXR_visionOS_Vibrate(handForSubaction(action, info->subactionPath), 0.0f, 0.0f);
    return XR_SUCCESS;
}
