// StatusCost — coût équivalent API des usages terminal (feature 16).
//
// Voir docs/superpowers/specs/2026-07-19-cout-equivalent-api-design.md.
//
// Deux couches, comme les autres modules :
//   — la logique pure ci-dessous (prix, parsing d'une ligne, filtrage temporel), testable ;
//   — le balayage incrémental des ~2900 fichiers de logs (voir .m), vérifié en exécutant.
//
// LE point de correctness : les deux fournisseurs comptent le cache à l'opposé. Claude sépare les
// compartiments (input hors cache + cache_read + cache_creation, disjoints). OpenAI inclut le
// cache dans input (cached_input est un sous-ensemble facturé au rabais). S'y tromper surcompte
// d'un facteur ~8 côté Claude.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TMCostProvider) { TMCostProviderClaude, TMCostProviderOpenAI };

// Compteurs de tokens d'un message. La sémantique de `input`/`cacheRead` dépend du fournisseur :
//   — Claude  : `input` = entrée HORS cache ; `cacheRead`/`cacheWrite`/`cacheWrite1h` = compartiments
//               séparés. `cacheWrite` = écritures de cache 5 min ; `cacheWrite1h` = écritures 1 h,
//               facturées 2× l'input (contre 1,25× pour le 5 min) — distinction indispensable, ~70 %
//               des écritures réelles étant en 1 h.
//   — OpenAI  : `input` = entrée TOTALE (cache inclus) ; `cacheRead` = sous-ensemble mis en cache ;
//               `cacheWrite`/`cacheWrite1h` inutilisés (pas de notion côté OpenAI).
typedef struct { double input, output, cacheRead, cacheWrite, cacheWrite1h; } TMTokens;

// Prix par million de tokens, un par compartiment. `cacheWrite` = écriture 5 min ; `cacheWrite1h`
// = écriture 1 h (2× l'input).
typedef struct { double input, output, cacheRead, cacheWrite, cacheWrite1h; } TMPrices;

// Coût en dollars. Applique la bonne sémantique de cache selon `provider` — c'est ici que se joue
// la correctness. Claude somme les trois compartiments disjoints ; OpenAI facture (input − cache)
// au tarif plein puis le cache au tarif réduit, et ignore cacheWrite.
double TMCostForTokens(TMTokens tokens, TMPrices prices, TMCostProvider provider);

// Extrait les tokens d'un objet `usage` de Claude Code (~/.claude/projects/**/*.jsonl). nil si la
// ligne n'est pas un message chiffrable. `outModel` reçoit le modèle. Compartiments disjoints.
BOOL TMParseClaudeUsageLine(NSDictionary *line, TMTokens *outTokens, NSString * _Nullable * _Nullable outModel);

// Extrait les tokens d'un événement `token_count` de Codex (~/.codex/sessions/**/*.jsonl).
// Sémantique OpenAI : input total avec cached_input en sous-ensemble, reasoning compté en sortie.
BOOL TMParseCodexTokenCount(NSDictionary *info, TMTokens *outTokens, NSString * _Nullable * _Nullable outModel);

// Table de prix de référence, datée. nil si le modèle n'a pas de tarif connu — l'appelant compte
// alors ses tokens à part sans jamais fabriquer un prix. `outHasPrice` distingue « prix nul »
// (impossible) de « modèle inconnu ».
BOOL TMPricesForModel(NSString *model, TMPrices *outPrices);

// Somme des coûts des tranches horaires postérieures à `startEpoch`. Pure. Chaque tranche est un
// nid heure_epoch(chaîne) → modèle → @{ @"cost": prix, @"tokens": total } ; un modèle sans clé
// `cost` est non tarifé et ne contribue pas au total. Le coût d'une fenêtre = ce total depuis son
// début.
double TMCostSince(NSDictionary *buckets, NSTimeInterval startEpoch);

// Ventilation par modèle sur la fenêtre [startEpoch, ∞). Pure. Retourne une liste
// @[ @{ @"model": nom, @"cost": prix (absent si non tarifé), @"tokens": total } ], triée par coût
// décroissant, les modèles non tarifés (sans `cost`) en fin de liste.
NSArray<NSDictionary *> *TMModelBreakdownSince(NSDictionary *buckets, NSTimeInterval startEpoch);

// Balaye les logs terminal (Claude + Codex), de façon incrémentale : un cache token-usage.json
// (versionné) retient l'empreinte (taille+date) de chaque fichier déjà lu et ses tranches, seuls
// les fichiers nouveaux ou modifiés sont relus. I/O — vérifié en exécutant, pas en testant.
// Retourne @{ @"claude": @{ @"buckets": {...} }, @"codex": {...} } au format nid ci-dessus.
NSDictionary *TMScanTerminalCosts(void);

// Taux de change indicatif, daté comme la table de prix — pas d'appel réseau. Sert à afficher
// l'équivalent en euros à côté du dollar. Approximatif et surchargeable, jamais présenté comme
// un taux de facturation exact.
extern const double TMEurPerUsd;
extern NSString *const TMFxAsOfDate;

// Date de relevé des tarifs, pour l'afficher dans les Réglages.
extern NSString *const TMPricesAsOfDate;

NS_ASSUME_NONNULL_END
