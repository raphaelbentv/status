#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Pilotage des ventilateurs côté application : modes « auto », « curve » (courbe température →
// vitesse) et « manual » (palier fixe). Logique pure, sans E/S ni horloge : le temps, la
// température et l'état du service sont injectés, d'où des tests déterministes (fan-boost-tests).
//
// Le service privilégié (StatusFanBoost) n'est PAS modifié : il ne sait que « boost de N minutes
// à P % » et « retour à Auto Apple ». La courbe est donc une suite de boosts COURTS (bail de
// TMFanLeaseMinutes, renouvelé) — voir TMFanController.

// Plancher du service : StatusFanBoost refuse tout palier sous 50 %.
#define TMFanCurveFloor 50
// Au-delà, ou dès l'état thermique « serious » (2) de macOS, la courbe force 100 %.
#define TMFanCurveCriticalC 95.0
#define TMFanCurveCriticalThermal 2
// Hystérésis : un palier ne change que si l'écart atteint 5 points ET au plus toutes les 10 s.
#define TMFanCurveStepPoints 5
#define TMFanCurveMinInterval 10.0
// Retour au « zéro » (macOS reprend la main) : 3 °C sous le premier point de la courbe.
#define TMFanCurveIdleBandC 3.0
// Capteur muet plus de 10 s : la courbe abandonne et rend la main à macOS.
#define TMFanCurveSensorTimeout 10.0
// Bail d'un boost de courbe, et marge de renouvellement avant son échéance.
#define TMFanLeaseMinutes 2
#define TMFanLeaseRenewSeconds 30.0

// Préréglages, dans l'ordre d'affichage : silent, balanced, performance.
NSArray<NSString *> *TMFanCurvePresetIds(void);
// Points [[°C, %], …] triés par température croissante ; nil pour un identifiant inconnu.
NSArray<NSArray<NSNumber *> *> * _Nullable TMFanCurvePoints(NSString * _Nullable preset);
// Valeur brute de la courbe : interpolation linéaire entre points, bornée à [50, 100]. NAN sous le
// premier point (zone « macOS ») ou pour une température non finie.
double TMFanCurveValue(NSArray<NSArray<NSNumber *> *> * _Nullable points, double tempC);

typedef NS_ENUM(NSInteger, TMFanCurveReason) {
    TMFanCurveReasonIdle,        // sous le premier point : macOS pilote
    TMFanCurveReasonCurve,       // palier issu de la courbe
    TMFanCurveReasonCritical,    // ≥ 95 °C ou état thermique serious/critical : 100 %
    TMFanCurveReasonSensorLost,  // température absente > 10 s : abandon
};

// Une courbe en cours d'exécution : convertit chaque relevé en palier cible, avec hystérésis.
@interface TMFanCurve : NSObject
- (nullable instancetype)initWithPreset:(NSString *)preset;
@property (readonly, copy) NSString *preset;
@property (readonly) NSInteger target;   // 0 = macOS (zéro de la courbe), sinon 50…100
@property (readonly) double raw;          // valeur brute au dernier relevé (NAN si aucune)
@property (readonly) TMFanCurveReason reason;
// tempC non finie ou ≤ 0 = capteur absent. thermal = NSProcessInfoThermalState (0…3).
- (NSInteger)stepAt:(double)now tempC:(double)tempC thermal:(NSInteger)thermal;
@end

// Vue minimale de l'état du service, lue dans le snapshot de TMLidClient.
typedef struct {
    BOOL ok;                  // autorisé, protocole ventilateurs v2, état confirmé
    BOOL busy;                // une requête XPC est en vol : le client refuserait la suivante
    BOOL active;              // boost en cours
    BOOL restorationPending;  // retour à Auto Apple en cours de vérification par le service
    NSInteger percent;        // palier du boost en cours
    double remainingSeconds;
} TMFanServiceView;

typedef NS_ENUM(NSInteger, TMFanCommandKind) { TMFanCommandNone, TMFanCommandStart, TMFanCommandStop };
typedef struct { TMFanCommandKind kind; NSInteger minutes, percent; } TMFanCommand;

// Contrôleur de mode : décide, à chaque tick, de LA commande à envoyer au service (au plus une,
// jamais pendant une requête en vol). Le mode retombe tout seul en « auto » quand il ne peut plus
// être tenu (service perdu, capteur muet, palier refusé, palier manuel terminé) ; `notice` dit
// pourquoi (suffixe de clé i18n fan.mode.notice.*).
@interface TMFanController : NSObject
@property (readonly, copy) NSString *mode;            // auto | curve | manual
@property (readonly, copy) NSString *preset;          // préréglage de la courbe (même hors mode courbe)
@property (readonly) NSInteger manualPercent, manualMinutes;
@property (readonly, nullable) TMFanCurve *curve;     // non nil en mode courbe
@property (readonly, copy, nullable) NSString *notice;
@property (readonly) BOOL idle;                       // auto, rien à arrêter : inutile de piloter
// Validation stricte (listes blanches, bornes entières) ; NO = rien n'a changé.
- (BOOL)setMode:(NSString *)mode preset:(nullable NSString *)preset percent:(NSInteger)percent minutes:(NSInteger)minutes;
- (void)forceAuto:(nullable NSString *)notice;
// Relevé capteur (mode courbe seulement ; ignoré sinon).
- (void)sensorAt:(double)now tempC:(double)tempC thermal:(NSInteger)thermal;
// Palier voulu à cet instant : 0 = rendre la main à macOS.
- (NSInteger)desiredPercent;
- (TMFanCommand)nextCommand:(TMFanServiceView)service now:(double)now;
@end

NS_ASSUME_NONNULL_END
