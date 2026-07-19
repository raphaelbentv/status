// StatusSystemMonitor — métriques système (CPU, GPU, RAM, réseau, disque, capteurs).
//
// Deux couches dans ce module, jamais mélangées :
//   — la logique pure ci-dessous (anneaux, deltas, assemblage du snapshot), testable sans machine ;
//   — les collecteurs (voir .m), qui lisent réellement le système et ne sont pas testés
//     unitairement : leur contrat — un dictionnaire ou nil — est couvert par les tests de snapshot.
//
// Voir docs/superpowers/specs/2026-07-19-monitoring-tab-design.md.

#import <Foundation/Foundation.h>

#pragma mark - Logique pure (testable sans machine)

// Fenêtre glissante : 5 minutes à 1 Hz. Fixée ici et non configurable — la spec ne prévoit
// qu'une profondeur, et un anneau de taille unique simplifie tout le reste.
extern const NSUInteger TMMetricRingCapacity;

// Anneau d'échantillons à capacité fixe. Écriture circulaire : plein, il écrase le plus ancien.
// La série ressort toujours du plus ancien au plus récent, prête à tracer.
@interface TMMetricRing : NSObject
- (instancetype)initWithCapacity:(NSUInteger)capacity;
- (void)push:(double)value;
@property (readonly) NSUInteger count;
// Valeurs ordonnées, du plus ancien au plus récent. Moins de `capacity` éléments tant que
// l'anneau n'a pas fait un tour complet.
- (NSArray<NSNumber *> *)series;
@end

// Débit instantané entre deux lectures d'un compteur cumulatif (octets réseau, E/S disque).
// NO — et *outRate intact — si l'intervalle est nul/négatif ou si le compteur a reculé
// (interface réinitialisée, compteur rebouclé) : mieux vaut un point manquant qu'un pic absurde.
BOOL TMRatePerSecond(uint64_t previous, uint64_t current, NSTimeInterval elapsed, double *outRate);

// Pourcentage d'activité CPU entre deux relevés de ticks cumulatifs (actifs, totaux).
// Borné [0, 100]. NO si aucun tick ne s'est écoulé ou si un compteur a reculé.
BOOL TMCPUPercentBetweenTicks(uint64_t activePrevious, uint64_t totalPrevious,
                              uint64_t activeCurrent, uint64_t totalCurrent, double *outPercent);

#pragma mark - Moniteur

// Un collecteur échantillonne une famille de métriques : dictionnaire clé → NSNumber, ou nil si
// la source est indisponible (clé IOKit absente, SMC muet). nil = la famille sort du snapshot.
// C'est l'unique mécanisme de dégradation : pas d'état d'erreur, pas de log répété à 1 Hz.
typedef NSDictionary<NSString *, NSNumber *> * _Nullable (^TMMetricCollector)(void);

@interface TMSystemMonitor : NSObject
// L'ordre de `familyOrder` est celui du snapshot — l'interface l'affiche tel quel.
- (instancetype)initWithCollectors:(NSDictionary<NSString *, TMMetricCollector> *)collectors
                       familyOrder:(NSArray<NSString *> *)familyOrder;
// Fait échantillonner chaque collecteur et pousse les valeurs dans les anneaux de sa famille.
- (void)sample;
// { familles: [ { id, now: {clé: valeur}, series: {clé: [valeurs]} } ] } — familles dont le
// collecteur a répondu, dans l'ordre de familyOrder. Sérialisable en JSON tel quel.
- (NSDictionary *)snapshot;
@end

// Le moniteur de production : tous les collecteurs réels branchés, dans l'ordre de la spec.
TMSystemMonitor *TMSystemMonitorCreate(void);
