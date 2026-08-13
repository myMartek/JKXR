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

static ar_session_t                 sSession  = NULL;
static ar_world_tracking_provider_t sProvider = NULL;

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

    // Ohne NSWorldSensingUsageDescription in der Info.plist verweigert visionOS
    // die Freigabe wortlos — die Anfrage kommt gar nicht erst beim Nutzer an.
    ar_session_request_authorization(
        sSession, ar_authorization_type_world_sensing,
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
        });

    ar_session_run(sSession, providers);
    NSLog(@"[JKXR] World Tracking gestartet");
}
