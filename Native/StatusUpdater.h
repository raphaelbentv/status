// StatusUpdater — mises à jour automatiques, par Sparkle.
//
// Sparkle lit SUFeedURL et SUPublicEDKey dans Info.plist : l'appcast est publié avec chaque release
// (scripts/release.sh --publish) et chaque archive est signée EdDSA, ce qui empêche d'installer autre
// chose que ce que nous avons publié. Rien n'est téléchargé sans cette signature.
#import <Foundation/Foundation.h>

@interface TMUpdater : NSObject
// Lance la vérification périodique. Sans clé publique dans Info.plist (build de développement
// compilé hors scripts/package-app.sh), Sparkle refuse de démarrer : `available` reste NO.
- (instancetype)init;
@property (readonly) BOOL available;
@property (readonly) BOOL canCheckForUpdates;
// Vérifie ET installe sans demander (les deux réglages de Sparkle sont liés : un seul interrupteur).
@property BOOL automatic;
- (void)checkForUpdates;
@end
