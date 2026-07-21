// StatusFx — taux de change USD→EUR, rafraîchi automatiquement.
//
// Voir docs/superpowers/specs/2026-07-21-cout-par-modele-et-change-auto-design.md.
//
// Deux couches, comme les autres modules :
//   — la logique pure ci-dessous (péremption, parsing d'une réponse), testable ;
//   — le fetch réseau + cache disque dans la classe TMFxRate (.m), vérifié en exécutant.
//
// Chaîne de repli stricte, jamais de taux inventé : taux du jour (Frankfurter/BCE) → dernier taux
// connu en cache → constante compilée TMEurPerUsd. Toujours « indicatif ».

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Faut-il rafraîchir ? Oui si jamais récupéré (fetchedAt ≤ 0) ou plus vieux que `ttl` secondes.
BOOL TMFxShouldRefresh(NSTimeInterval fetchedAt, NSTimeInterval now, NSTimeInterval ttl);

// Extrait `rates.EUR` (taux) et `date` (relevé) d'une réponse Frankfurter. NO si la réponse n'est
// pas un dictionnaire, si EUR manque, ou si le taux n'est pas strictement positif. `outAsOf` peut
// rester nil sans invalider un taux par ailleurs valide.
BOOL TMParseFxResponse(NSDictionary *json, double *outRate, NSString * _Nullable * _Nullable outAsOf);

// Fournit le taux courant avec la chaîne de repli, et déclenche un rafraîchissement de fond si le
// cache est périmé. Interrogé de façon synchrone (valeur immédiate), rafraîchi en arrière-plan.
@interface TMFxRate : NSObject
+ (instancetype)shared;
- (double)eurPerUsd;          // taux en cache, ou la constante de repli
- (NSString *)asOfDate;       // date du relevé réellement utilisé (BCE en cache, ou constante)
- (void)refreshIfStale;       // fetch de fond si le cache dépasse la TTL ; sans effet sinon
@end

NS_ASSUME_NONNULL_END
