// StatusAwake — empêche la mise en veille de l'écran tant que l'interrupteur est actif.
//
// Volontairement minuscule et sans persistance : un Mac qui refuse de dormir après un redémarrage,
// sans que personne ne se souvienne pourquoi, est un piège. Voir la spec du 16 juillet 2026.

#import <Foundation/Foundation.h>

@interface TMAwake : NSObject
// Les deux accesseurs sont écrits à la main : l'état réel vit dans IOKit, pas dans un ivar
// synthétisé qui pourrait mentir si IOKit refuse l'assertion.
@property (nonatomic, getter=isEnabled) BOOL enabled;
@end
