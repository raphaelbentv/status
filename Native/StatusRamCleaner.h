// StatusRamCleaner — libère de la RAM sans droits administrateur.
//
// `purge` exige root ; ici on fait réclamer de la mémoire au noyau pendant un instant, qui rend le
// cache de fichiers pour la satisfaire, puis on la rend. Aucune app n'est fermée. La demande monte à 60 % de la RAM, ce
// qui pousse aussi le noyau à compresser des pages d'apps inactives ; arrêt dès la pression critique.

#import <Foundation/Foundation.h>

// Octets à réclamer. 0 si la machine n'a pas de marge. Plafonné à 60 % de la RAM, et réduit
// d'une réserve fixe pour que le système garde de quoi respirer.
uint64_t TMRamCleanTarget(uint64_t freeBytes, uint64_t cachedBytes, uint64_t totalBytes);

@interface TMRamCleaner : NSObject
@property (readonly, getter=isRunning) BOOL running;
// Lance un nettoyage en arrière-plan (ignoré s'il y en a déjà un). `completion` revient sur la file
// principale avec { status: done|nothing|aborted, freedBytes, claimedBytes }.
- (void)runWithCompletion:(void (^)(NSDictionary *result))completion;
@end
