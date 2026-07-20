// StatusWindowManager — placement des fenêtres au clavier.
//
// Deux couches, jamais mélangées :
//   — la géométrie ci-dessous, pure et testable sans machine ;
//   — l'application via l'API d'Accessibilité (voir .m), qui parle aux autres processus et n'est
//     donc pas testée unitairement.
//
// Voir docs/superpowers/specs/2026-07-19-window-manager-design.md.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Géométrie (testable sans machine)

typedef NS_ENUM(NSInteger, TMWindowLayout) {
    TMLayoutLeftHalf, TMLayoutRightHalf,
    TMLayoutLeftTwoThirds, TMLayoutRightTwoThirds,
    TMLayoutLeftThird, TMLayoutCenterThird, TMLayoutRightThird,
    TMLayoutLeftThreeQuarters, TMLayoutRightThreeQuarters,
    TMLayoutMaximize, TMLayoutCenter,
};

// Marges : `between` sépare deux fenêtres voisines, `edge` sépare une fenêtre du bord de l'écran.
// Distinctes parce qu'elles ne jouent pas le même rôle : on veut souvent respirer entre deux
// fenêtres sans perdre de place sur les bords, ou l'inverse avec un Dock latéral.
typedef struct { CGFloat between; CGFloat edge; } TMWindowGaps;

// Cadre à appliquer pour `layout` dans `zone` (la portion utilisable de l'écran, barre des menus
// et Dock déjà retranchés par l'appelant si l'option est active).
//
// Les bords partagés reçoivent une demi-marge chacun, jamais une marge entière : deux fenêtres
// voisines sont ainsi séparées d'exactement `between`, et non du double. Les coordonnées sont
// arrondies de sorte que deux dispositions complémentaires (1/3 et 2/3, par exemple) se touchent
// exactement — sans bande résiduelle d'un point, ni recouvrement.
CGRect TMWindowFrameForLayout(CGRect zone, TMWindowLayout layout, TMWindowGaps gaps);

// Traduit l'identifiant venu de la webview. NO si inconnu — une disposition mal orthographiée ne
// doit pas déplacer une fenêtre au hasard.
BOOL TMWindowLayoutFromIdentifier(NSString *identifier, TMWindowLayout *outLayout);

// Reporte `frame` de `fromScreen` vers `toScreen` en conservant ses proportions relatives : une
// fenêtre occupant la moitié gauche d'un écran occupe la moitié gauche de l'autre, quels que
// soient leurs rapports d'aspect. Bornée à `toScreen` pour ne jamais sortir de l'écran.
CGRect TMWindowFrameMovedToScreen(CGRect frame, CGRect fromScreen, CGRect toScreen);

#pragma mark - Application (parle aux autres processus)

@interface TMWindowManager : NSObject
// NO si l'autorisation d'Accessibilité manque, si aucune fenêtre n'est au premier plan, ou si
// l'application refuse le cadre demandé — vérifié par relecture après écriture.
- (BOOL)applyLayout:(TMWindowLayout)layout;
// Déplace la fenêtre active vers l'écran suivant (ou précédent) en conservant ses proportions.
- (BOOL)moveToAdjacentScreen:(BOOL)next;
@end

NS_ASSUME_NONNULL_END
