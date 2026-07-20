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
//   — Claude  : `input` = entrée HORS cache ; `cacheRead`/`cacheWrite` = compartiments séparés.
//   — OpenAI  : `input` = entrée TOTALE (cache inclus) ; `cacheRead` = sous-ensemble mis en cache ;
//               `cacheWrite` inutilisé (pas de notion côté OpenAI).
typedef struct { double input, output, cacheRead, cacheWrite; } TMTokens;

// Prix par million de tokens, un par compartiment.
typedef struct { double input, output, cacheRead, cacheWrite; } TMPrices;

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

// Somme des coûts des tranches horaires postérieures à `startEpoch`. Pure : `buckets` est un
// dictionnaire heure_epoch(chaîne) → coût. Le coût d'une fenêtre = ce total depuis son début.
double TMCostSince(NSDictionary<NSString *, NSNumber *> *buckets, NSTimeInterval startEpoch);

// Balaye les logs terminal (Claude + Codex), de façon incrémentale : un cache token-usage.json
// retient l'empreinte (taille+date) de chaque fichier déjà lu et ses tranches de coût, seuls les
// fichiers nouveaux ou modifiés sont relus. I/O — vérifié en exécutant, pas en testant.
// Retourne @{ @"claude": @{ @"buckets": {...}, @"unpriced": @(tokens) }, @"codex": {...} }.
NSDictionary *TMScanTerminalCosts(void);

// Date de relevé des tarifs, pour l'afficher dans les Réglages.
extern NSString *const TMPricesAsOfDate;

NS_ASSUME_NONNULL_END
