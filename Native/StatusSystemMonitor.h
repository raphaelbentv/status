// StatusSystemMonitor — métriques système (CPU, GPU, RAM, réseau, disque, capteurs).
//
// Deux couches dans ce module, jamais mélangées :
//   — la logique pure ci-dessous (anneaux, deltas, assemblage du snapshot), testable sans machine ;
//   — les collecteurs (voir .m), qui lisent réellement le système et ne sont pas testés
//     unitairement : leur contrat — un dictionnaire ou nil — est couvert par les tests de snapshot.
//
// Voir docs/superpowers/specs/2026-07-19-monitoring-tab-design.md.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

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

// Processus les plus gourmands entre deux relevés, sur TROIS dimensions. Chaque relevé : pid (clé
// texte) → { name, cpuTimeNs, rssBytes, energyNJ }. Retourne l'union — dédupliquée par pid — des
// `count` plus gros par CPU, par RAM et par énergie : [{ pid, name, cpuPercent, rssBytes,
// energyWatts }]. L'interface trie ensuite selon la dimension voulue ; garder les trois tops évite
// qu'un gros consommateur d'une ressource disparaisse au tri d'une autre. energyWatts est la
// puissance moyenne sur l'intervalle (delta de nanojoules / temps) ; la dimension énergie n'entre
// dans l'union que si des deltas non nuls existent. Taille : de `count` (tops confondus) à 3×count
// (disjoints). Un pid absent du relevé précédent garde cpuPercent/energyWatts = 0 mais reste
// éligible au tri mémoire ; un compteur qui recule (pid réutilisé) laisse aussi 0. Le pourcentage
// CPU n'est pas plafonné à 100 : un processus multithread dépasse légitimement un cœur.
NSArray<NSDictionary *> *TMTopProcesses(NSDictionary *previous, NSDictionary *current,
                                        NSTimeInterval elapsed, NSUInteger count);

// Alerte à seuil avec hystérésis. `wasAbove` est l'état persistant, mis à jour par l'appel.
// YES au franchissement montant uniquement ; l'alerte se réarme quand la valeur redescend sous
// `rearmBelow` (< threshold), pas dès qu'elle repasse sous le seuil — sinon une valeur qui
// oscille autour du seuil mitraille de notifications.
BOOL TMThresholdShouldFire(BOOL *wasAbove, double value, double threshold, double rearmBelow);

// Seuil de réarmement déduit d'un seuil d'alerte réglable par l'utilisateur. L'hystérésis vaut 8 %
// du seuil (soit ~7 points pour 90 °C, proche des marges d'origine) et au moins 2 unités, pour que
// des seuils bas gardent une bande utile. Toujours < threshold, et jamais négatif.
double TMAlertRearmThreshold(double threshold);

// Famille d'un capteur thermique, d'après son nom matériel. Les noms Apple Silicon sont opaques
// (« PMU tdie3 », « PMU tdev1 », « gas gauge battery ») : aucune étiquette « CPU » ou « GPU »
// n'existe, on ne peut donc pas en inventer. On regroupe ce qui est identifiable de façon sûre :
//   @"die"     — température de die du SoC (tdie…) : le point chaud qui gouverne le bridage ;
//   @"device"  — périphériques / alimentation (tdev…) : plus froids, moins critiques ;
//   @"battery" — cellule (« gas gauge battery ») : la famille battery l'expose déjà, on l'écarte
//                pour ne pas polluer la moyenne du SoC ;
//   nil        — non classé (calibration « tcal », capteurs inconnus) : ignoré des agrégats.
// Insensible à la casse. Le nom Intel courant (TC0P/PECI) tombe aussi dans « die ».
NSString * _Nullable TMSensorFamilyForName(NSString * _Nullable name);

// Agrégats thermiques d'un relevé de capteurs : [{ name: NSString (optionnel), celsius: NSNumber }]
// → { tempC, dieMaxC, dieAvgC, dieCount, deviceMaxC, deviceAvgC, deviceCount }, valeurs arrondies.
// Les lectures implausibles (≤ 10 °C ou ≥ 120 °C : capteurs fantômes) sont écartées. `tempC` est
// le max des dies — le point chaud qui gouverne le bridage — ou, faute de die identifiable, la
// moyenne de toutes les lectures plausibles. nil si aucune lecture plausible.
NSDictionary<NSString *, NSNumber *> * _Nullable TMSensorTempAggregates(NSArray<NSDictionary *> *readings);

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

#pragma mark - Historique long (24 h)

// Les anneaux du moniteur ne couvrent que quelques minutes et vivent en RAM. Cet historique-ci est
// l'autre échelle : une ligne par minute, horodatée, conservée sur disque, pour répondre à « qu'est-ce
// qui a chauffé cette nuit ? ». Chaque ligne : { @"t": epoch (s), puis les métriques présentes }.
extern const NSTimeInterval TMLongHistoryMaxAge;   // 24 h
extern const NSTimeInterval TMLongHistoryInterval; // 60 s entre deux lignes

// Ajoute `row` à `rows` puis élague : lignes plus vieilles que `maxAge` par rapport à la plus
// récente, et débordement au-delà de `maxRows` (garde-fou si l'horloge saute). Retourne un nouveau
// tableau, trié du plus ancien au plus récent. `row` sans clé @"t" numérique est ignorée.
// Une ligne dont l'horodatage précède la dernière conservée est rejetée : après un changement
// d'heure ou une restauration, mieux vaut perdre un point que d'obtenir un historique non monotone
// que les courbes afficheraient à l'envers.
NSArray<NSDictionary *> *TMLongHistoryAppend(NSArray<NSDictionary *> * _Nullable rows,
                                             NSDictionary *row, NSTimeInterval maxAge, NSUInteger maxRows);

// Extrait d'un snapshot les quelques métriques qui méritent d'être suivies sur 24 h, horodatées à
// `timestamp`. nil si le snapshot n'en contient aucune (rien à journaliser).
NSDictionary * _Nullable TMLongHistoryRow(NSDictionary *snapshot, NSTimeInterval timestamp);

// Relevé instantané des processus via libproc, au format attendu par TMTopProcesses.
// nil si la liste des pids est illisible. Coûte quelques centaines d'appels noyau : à n'appeler
// que quand une surface est visible.
NSDictionary * _Nullable TMProcessSample(void);

NS_ASSUME_NONNULL_END
