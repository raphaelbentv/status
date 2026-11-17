// StatusKeyboardLock — bloque tout le clavier le temps de le nettoyer.
//
// Le blocage est total (CGEventTap au niveau HID) et exige la permission Accessibilité. Il n'y a
// délibérément pas de repli « léger » : un verrou qui laisse passer Cmd+Tab est pire qu'un verrou
// absent, parce qu'on lui fait confiance. Voir la spec du 16 juillet 2026.
//
// Limites assumées, à afficher dans l'interface :
//   — le bouton d'alimentation et Touch ID restent actifs, aucun tap ne les intercepte ;
//   — l'overlay recouvre la barre des menus, donc Pomme > Forcer à quitter est hors d'atteinte.
// Filets de sécurité : si l'app se fige, macOS désactive le tap tout seul ; et le verrou se lève
// inconditionnellement au bout de TMLockBackstopSeconds.
//
// Le tap tourne sur son propre thread, jamais sur le thread principal : chaque frappe attend la
// réponse du tap, et un thread principal occupé (WebView, sondages) faisait expirer le tap.
// Pendant la coupure, des frappes passaient ; un ⌘ appuyé passé puis relâché avalé laissait la
// session croire ⌘ tenu, et toutes les lettres devenaient des raccourcis après la sortie.

#import <Foundation/Foundation.h>

#pragma mark - Logique pure (testable sans machine)

// Durée de maintien du clic pour déverrouiller. Un clic sec ne suffit pas : un chiffon qui frotte
// le trackpad produit des clics, pas des maintiens.
extern const NSTimeInterval TMHoldRequiredSeconds;

// Levée inconditionnelle du verrou. Garde-fou contre l'enfermement — pas un mode d'emploi, et
// l'interface ne le présente pas comme une durée de nettoyage.
extern const NSTimeInterval TMLockBackstopSeconds;

// Fraction de maintien accomplie, bornée à [0, 1]. Bornée parce qu'elle pilote un anneau de
// progression et qu'une horloge qui recule ne doit pas le faire déborder.
double TMHoldFraction(NSTimeInterval elapsed, NSTimeInterval required);

typedef NS_ENUM(NSInteger, TMLockState) {
    TMLockStateUnlocked,  // repos
    TMLockStateLocked,    // tap actif, overlay affiché
    TMLockStateBlocked    // permission Accessibilité absente : rien n'est verrouillé
};

// Déverrouiller est toujours possible, même sans permission : elle peut être révoquée pendant le
// verrou, et l'utilisateur ne doit pas se retrouver enfermé pour autant.
TMLockState TMLockStateAfterToggle(TMLockState current, BOOL permissionGranted);

// Modificateurs que la session croit encore appuyés alors que le clavier physique les a relâchés.
// Leur relâchement a été avalé par le verrou (un appui passé pendant une coupure du tap, ou posté
// par un autre outil) : sans correction, chaque lettre tapée après la sortie arrive comme un
// raccourci. Rend les codes de touche à relâcher artificiellement, dans un ordre stable.
// Verr. Maj est exclu : c'est un état basculé, pas une touche tenue.
NSArray<NSNumber *> * _Nonnull TMStuckModifierKeyCodes(uint64_t sessionFlags, uint64_t hardwareFlags);

#pragma mark - Contrôleur (tap HID + overlay — lit la machine, pas de tests unitaires)

// Le verrou lui-même. `toggle` applique TMLockStateAfterToggle : il demande la permission
// Accessibilité au premier usage (macOS affiche le panneau), verrouille si elle est accordée,
// passe en Blocked sinon. Le clavier n'est intercepté qu'à l'état Locked ; le déverrouillage se
// fait par maintien du clic sur l'overlay (TMHoldRequiredSeconds) ou par le garde-fou
// (TMLockBackstopSeconds).
@interface TMKeyboardLock : NSObject
@property (readonly) TMLockState state;
// Notifié sur le thread principal à chaque changement, y compris la levée automatique.
@property (copy) void (^ _Nullable stateChanged)(TMLockState state);
- (void)toggle;
- (void)forceUnlock;  // arrêt de l'app : relâcher le tap explicitement
@end
