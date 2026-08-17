// World Tracking für die XR-Schicht.
//
// Warum die C-API von ARKit und nicht Swifts ARKitSession/WorldTrackingProvider:
// TBXR_Common.mm braucht ein `ar_world_tracking_provider_t`, um
// ar_world_tracking_provider_query_device_anchor_at_timestamp() aufzurufen.
// Swifts WorldTrackingProvider kapselt diesen Handle und gibt ihn nicht heraus
// — er lässt sich aus Swift also nicht durchreichen. Über die C-API ist es
// dagegen dieselbe Sitzung, nur direkt.
//
// Der Spike S4 kam mit der Swift-Fassung aus, weil dort in Swift gerendert
// wurde und queryDeviceAnchor gleich daneben stand.

#import <ARKit/ARKit.h>
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>

// Die Tabelle des gewählten Spiels: der Zubehör-Provider muss dorthin, und die
// Funktion gibt es zweimal — einmal in Outcast, einmal in Academy.
#include "JKXR_visionOS_Spiel.h"

/*
 * Bauzeit-Kennung.
 *
 * +load läuft beim Laden des Programms, also noch vor allem anderen und
 * unabhängig davon, ob der Immersive Space geöffnet wird. Damit steht in jedem
 * Konsolenprotokoll, WELCHE Fassung tatsächlich läuft.
 *
 * Anlass: eine alte Instanz lag noch im Speicher, während schon eine neue
 * installiert war — zwei Messungen waren dadurch wertlos, ohne dass es
 * auffiel. Bei einem Zyklus aus Bauen, Installieren und manuellem Starten ist
 * das keine Zusatzarbeit, sondern Grundausstattung.
 */
@interface JKXRBuildStamp : NSObject
@end

@implementation JKXRBuildStamp
+ (void)load
{
    NSLog(@"[JKXR] ==== Build vom %s %s ====", __DATE__, __TIME__);
}
@end

static ar_session_t                     sSession  = NULL;
static ar_world_tracking_provider_t     sProvider = NULL;
static ar_accessory_tracking_provider_t sAccessory = NULL;
static ar_data_providers_t              sProviders = NULL;

void TBXR_visionOS_StartAccessoryTracking(void);

void *TBXR_visionOS_GetAccessoryTracking(void)
{
    return (__bridge void *)sAccessory;
}

/*
 * Von TBXR_FrameSetup pro Bild aufgerufen.
 *
 * Unretained: der Provider gehört dieser Datei und lebt, solange die App läuft.
 */
void *TBXR_visionOS_GetWorldTracking(void)
{
    return (__bridge void *)sProvider;
}

/*
 * Startet ARKit. Aus der Hülle aufzurufen, sobald der Immersive Space offen ist.
 *
 * Die Freigabe kommt asynchron und auf einer beliebigen Warteschlange. Der
 * Provider wird trotzdem sofort erzeugt und ar_session_run gleich aufgerufen:
 * ARKit hält die Sitzung dann zurück, bis der Nutzer entschieden hat. Bis
 * dahin liefert query_device_anchor keine Pose, und die XR-Schicht rendert mit
 * der zuletzt bekannten — genau das Verhalten, das man will, statt zu warten.
 */
void TBXR_visionOS_StartWorldTracking(void)
{
    if (sSession) {
        return;
    }

    sSession = ar_session_create();

    ar_world_tracking_configuration_t config = ar_world_tracking_configuration_create();
    sProvider = ar_world_tracking_provider_create(config);

    ar_data_providers_t providers = ar_data_providers_create();
    ar_data_providers_add_data_provider(providers, sProvider);

    // Die Zubehörverfolgung kommt nach, sobald die Geräte geladen sind. Die
    // Sitzung läuft zunächst nur mit World Tracking, damit das Bild sofort steht.
    sProviders = providers;

    // Freigabe für BEIDE Bereiche anfragen.
    //
    // Ohne diesen Aufruf erscheint keine Rückfrage beim Nutzer, die
    // Zubehörverfolgung bleibt verweigert und GCSpatialAccessory liefert nichts
    // — was von außen wie ein Hardware- oder Kopplungsproblem aussieht.
    //
    // Voraussetzung dafür sind die beiden Info.plist-Schlüssel
    // NSWorldSensingUsageDescription und NSAccessoryTrackingUsageDescription;
    // fehlt einer, wird die Anfrage wortlos abgelehnt.
    ar_session_request_authorization(
        sSession,
        ar_authorization_type_world_sensing | ar_authorization_type_accessory_tracking,
        ^(ar_authorization_results_t results, ar_error_t error) {
            if (error) {
                NSLog(@"[JKXR] ARKit-Freigabe fehlgeschlagen");
                return;
            }
            ar_authorization_results_enumerate_results(
                results, ^bool(ar_authorization_result_t result) {
                    NSLog(@"[JKXR] ARKit-Freigabe: Typ %llu, Status %d",
                          (unsigned long long)ar_authorization_result_get_authorization_type(result),
                          (int)ar_authorization_result_get_status(result));
                    return true;
                });

            // Erst JETZT aufzählen: vor der Freigabe antwortet
            // GCSpatialAccessory zwar, kennt aber keine Geräte. Der Rückruf
            // kommt auf einer beliebigen Warteschlange.
            dispatch_async(dispatch_get_main_queue(), ^{
                TBXR_visionOS_StartAccessoryTracking();
            });
        });

    ar_session_run(sSession, providers);
    NSLog(@"[JKXR] World Tracking gestartet");
}


// ---------------------------------------------------------------------------
// Zubehörverfolgung: räumliche Posen der Sense-Controller
//
// Die Sense-Controller sind KEINE gewöhnlichen GCController. Ein einzelner
// kann kein vollständiges Gamepad-Profil anbieten, und GameController zählt nur
// Geräte auf, die das können — deshalb erscheint über [GCController controllers]
// immer nur das PAAR als ein kombiniertes MFi-Gamepad.
//
// Die einzelnen Geräte liegen stattdessen in GCSpatialAccessory.spatialAccessories.
// Diese Klasse ist neuer als das SDK, gegen das wir bauen, also wird sie über
// NSClassFromString und perform: geholt statt direkt referenziert.
//
// Ein früherer Versuch scheiterte daran, dass die Konfiguration erzeugt, aber
// ar_accessory_tracking_configuration_set_accessories nie aufgerufen wurde: die
// App beendete sich beim Öffnen des Immersive Space kommentarlos mit Exit 0.
// ---------------------------------------------------------------------------

static id<GCDevice> sSpatialDevices[2] = { nil, nil };

void *TBXR_visionOS_GetSpatialDevice(int hand)
{
    if (hand < 0 || hand > 1) return NULL;
    return (__bridge void *)sSpatialDevices[hand];
}

static NSArray *spatialAccessoryDevices(void)
{
    // Das Klassenobjekt beantwortet seine eigene Klasseneigenschaft. perform:
    // statt valueForKey: — Key-Value-Coding gegen eine Metaklasse ist nirgends
    // zugesichert.
    Class cls = NSClassFromString(@"GCSpatialAccessory");
    if (!cls) {
        NSLog(@"[JKXR] GCSpatialAccessory gibt es auf diesem System nicht");
        return @[];
    }
    SEL sel = NSSelectorFromString(@"spatialAccessories");
    if (![cls respondsToSelector:sel]) {
        NSLog(@"[JKXR] GCSpatialAccessory antwortet nicht auf spatialAccessories");
        return @[];
    }
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSArray *devices = [cls performSelector:sel];
    #pragma clang diagnostic pop
    if (devices.count > 0) return devices;

    // Rückfall über die gewöhnliche Controllerliste.
    //
    // GEMESSEN: auf diesem System liefert GCSpatialAccessory.spatialAccessories
    // null Geräte, während [GCController controllers] die beiden Sense-Controller
    // einzeln zeigt — mit productCategory "Spatial Controller". Sie sind also da,
    // nur nicht über die neue Klasse erreichbar.
    //
    // GCController erfüllt GCDevice, und genau das verlangt
    // ar_accessory_load_from_device. Der Weg ist damit derselbe, nur die Quelle
    // eine andere.
    NSMutableArray *fallback = [NSMutableArray array];
    for (GCController *c in [GCController controllers]) {
        if ([c.productCategory isEqualToString:GCProductCategorySpatialController]) {
            [fallback addObject:c];
        }
    }
    if (fallback.count > 0) {
        NSLog(@"[JKXR] %lu über GCController gefunden (Kategorie Spatial Controller)",
              (unsigned long)fallback.count);
    }
    return fallback;
}

/// Stößt einen Neuaufbau an, aber erst wenn kurz Ruhe war.
///
/// Die Verbindungsmeldungen feuern mehrfach hintereinander, und die Controller
/// tauchen einzeln auf. Sofort loszulaufen lud entweder dasselbe Gerät zweimal
/// (gemessen: "(Right)" doppelt) oder verschluckte den zweiten, wenn eine
/// Sperre den zweiten Anlauf blockierte, während der erste noch lief.
///
/// Eine halbe Sekunde Ruhe abzuwarten löst beides: es wird genau einmal
/// aufgebaut, mit allem, was dann da ist.
static void rebuildAccessories(void);

static void scheduleRebuild(void)
{
    static NSUInteger generation = 0;
    const NSUInteger mine = ++generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (mine != generation) return;   // inzwischen kam eine neue Meldung
        rebuildAccessories();
    });
}

static void rebuildAccessories(void)
{
    // Einer nach dem anderen, und nur bei echter Änderung.
    //
    // Die Verbindungsmeldungen feuern mehrfach kurz hintereinander — gemessen
    // dreimal in 15 ms. Jeder Durchlauf lud die Geräte erneut und rief
    // ar_session_run auf, während die Rückrufe des vorigen noch liefen: der
    // Zähler `pending` wurde von mehreren Threads ohne Absicherung
    // heruntergezählt, dasselbe Gerät zweimal geladen ("(Right)" erschien
    // doppelt), und die Sitzung mehrfach parallel neu gestartet.
    static NSUInteger lastCount = NSUIntegerMax;

    NSArray *devices = spatialAccessoryDevices();
    if (devices.count == lastCount) return;
    lastCount = devices.count;
    NSLog(@"[JKXR] %lu räumliche Zubehörgeräte", (unsigned long)devices.count);
    if (devices.count == 0) return;

    __block NSUInteger pending = devices.count;
    ar_accessories_t accessories = ar_accessories_create();

    for (id<GCDevice> device in devices) {
        ar_accessory_load_from_device(device, ^(id<GCDevice> loadedDevice,
                                                bool successful,
                                                ar_error_t error,
                                                ar_accessory_t accessory) {
            if (successful && accessory) {
                ar_accessories_add_accessory(accessories, accessory);

                // Händigkeit von ARKit, nicht aus dem Gerätenamen geraten.
                const ar_accessory_chirality_t chirality =
                    ar_accessory_get_inherent_chirality(accessory);
                if (chirality == ar_accessory_chirality_left) {
                    sSpatialDevices[0] = loadedDevice;
                } else if (chirality == ar_accessory_chirality_right) {
                    sSpatialDevices[1] = loadedDevice;
                }
                NSLog(@"[JKXR] Zubehör \"%s\" geladen, Händigkeit %ld",
                      ar_accessory_get_name(accessory) ?: "?", (long)chirality);
            } else {
                NSLog(@"[JKXR] Zubehör ließ sich nicht laden");
            }

            if (--pending > 0) return;

            // Alle geladen: Provider bauen und die Sitzung damit neu starten.
            // Neu starten ist der grobe, aber überall funktionierende Weg, die
            // verfolgte Menge zu ändern; World Tracking geht dabei wieder mit
            // hinein, damit es nie ausfällt.
            ar_accessory_tracking_configuration_t config =
                ar_accessory_tracking_configuration_create();
            ar_accessory_tracking_configuration_set_accessories(config, accessories);
            sAccessory = ar_accessory_tracking_provider_create(config);

            if (sProvider && sAccessory) {
                // Die Sammlung FRISCH aufbauen, nicht ergänzen.
                //
                // Vorher wurde der neue Zubehör-Provider einfach zu sProviders
                // hinzugefügt. Beim ersten Mal geht das gut — beim zweiten
                // steckt der alte noch drin, und ar_session_run wirft beim
                // Durchzählen der Provider eine NSException, die niemand fängt:
                //
                //   ARKitCore ar_session_run
                //   ARKitCore ar_data_providers_enumerate_data_providers
                //   → uncaught NSException → SIGABRT
                //
                // Ein zweiter Durchlauf ist der Normalfall, kein Randfall: er
                // passiert, sobald ein Controller einschläft und wieder
                // aufwacht, denn dann ändert sich die Geräteanzahl.
                //
                // World Tracking kommt wieder mit hinein, damit es beim
                // Neustart der Sitzung nicht ausfällt.
                ar_data_providers_t providers = ar_data_providers_create();
                ar_data_providers_add_data_provider(providers, sProvider);
                ar_data_providers_add_data_provider(providers, sAccessory);
                sProviders = providers;
                ar_session_run(sSession, sProviders);

                // Den Provider ans Action-System durchreichen.
                //
                // Ohne diesen Aufruf bleibt gTracking in OpenXrActions.mm nil,
                // xrLocateSpace liefert keine Pose, und die Controller werden
                // nicht verfolgt — obwohl ARKit sie einwandfrei kennt. Der
                // Aufruf stand einmal in EngineHost.swift und ging beim Umbau
                // verloren, als der Provider hierher wanderte.
                //
                // Über die Tabelle des gewählten Spiels, weil es die Funktion
                // zweimal gibt — einmal in Outcast, einmal in Academy.
                //
                // Der umgekehrte Fall ist auch abgedeckt: steht der Provider
                // vor der Auswahl (etwa weil ein Controller neu verbunden wurde
                // und die Benachrichtigung einen Neuaufbau anstieß), holt
                // JKXR_visionOS_Waehle ihn per GetAccessoryTracking nachträglich
                // ab. Ohne diese zweite Richtung wäre der Provider verloren.
                if (JKXR_visionOS_Gewaehlt) {
                    JKXR_visionOS_Gewaehlt->SetAccessoryTracking(
                        (__bridge void *)sAccessory);
                } else {
                    NSLog(@"[JKXR] Zubehör-Provider steht, aber noch kein Spiel "
                          @"gewählt — wird beim Start zugestellt");
                }

                NSLog(@"[JKXR] Zubehörverfolgung läuft");
            }
        });
    }
}

void TBXR_visionOS_StartAccessoryTracking(void)
{
    if (!sSession) return;
    scheduleRebuild();

    // Controller können jederzeit dazukommen oder verschwinden. Die
    // GCSpatialAccessory-Benachrichtigungen gibt es erst in neueren SDKs,
    // deshalb über den Namen statt über die Konstante.
    for (NSString *name in @[@"GCControllerDidConnectNotification",
                             @"GCControllerDidDisconnectNotification",
                             @"GCSpatialAccessoryDidConnectNotification",
                             @"GCSpatialAccessoryDidDisconnectNotification"]) {
        [[NSNotificationCenter defaultCenter]
            addObserverForName:name object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *note) { scheduleRebuild(); }];
    }
}
