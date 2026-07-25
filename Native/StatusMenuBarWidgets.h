// StatusMenuBarWidgets — widgets système multiples dans la barre des menus (façon iStat Menus).
//
// Deux couches, comme le reste du projet :
//   — TMWidgetReadout : logique pure, extrait du snapshot moniteur les valeurs d'un widget et les
//     met en forme (textes, fraction, série). Testable sans écran.
//   — TMWidgetImage : dessine l'icône (histogramme, camembert, pile, texte deux lignes). AppKit,
//     non testé unitairement — même compromis que les icônes de Status.m.
//
// Voir docs/superpowers/specs/2026-07-24-widgets-barre-des-menus-design.md.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Les ids de widgets disponibles, dans l'ordre d'affichage proposé aux Réglages.
extern NSArray<NSString *> *TMMenuBarWidgetIDs(void);

// Libellé lisible d'un widget (pour les Réglages).
NSString *TMMenuBarWidgetLabel(NSString *widgetId);

#pragma mark - Logique pure (testable)

// Déplace `item` de `delta` rangs dans `list` (−1 = vers la gauche, +1 = vers la droite).
// Retourne une nouvelle liste. Inchangée si l'élément est absent, si `delta` est nul, ou si le
// déplacement sortirait des bornes — un bouton en butée ne doit rien casser.
NSArray<NSString *> *TMArrayByMovingItem(NSArray<NSString *> *list, NSString *item, NSInteger delta);

// Lecture d'un widget depuis un snapshot moniteur ({ families: [ { id, now, series } ] }).
// Retourne un dictionnaire sérialisable :
//   style     : « bars » | « pie » | « battery » | « twoLine »
//   hasValue  : la source a-t-elle répondu (sinon l'icône montre un tiret)
//   title     : texte système à droite de l'image (widgets bars/pie), sinon « »
//   primary   : ligne principale dessinée dans l'image (twoLine/battery), sinon « »
//   secondary : seconde ligne dessinée (twoLine/battery), sinon « »
//   fraction  : 0..1 pour camembert/pile
//   series    : tableau 0..100 pour histogramme (du plus ancien au plus récent)
//   charging  : batterie en charge (widget battery)
// Retourne toujours un dictionnaire ; hasValue=NO si la famille source manque.
NSDictionary *TMWidgetReadout(NSString *widgetId, NSDictionary *snapshot);

#pragma mark - Dessin (AppKit)

// Icône d'un widget à partir de son readout, avec une forme et une couleur choisies.
//   shape : « bars » | « graph » | « ring » | « pie » | « text » | « twoLine » | « battery ».
//           Vide → forme naturelle du widget. Une forme qui ne colle pas à la donnée retombe
//           dessus aussi (repli gracieux).
//   colorName : nom de la palette (blue, green, purple, cyan, orange, amber, red, pink, gray) ou
//           nil/« auto » → template neutre. La sévérité (alerte) prime toujours sur la couleur.
NSImage *TMWidgetImageStyled(NSDictionary *readout, NSString *_Nullable shape, NSString *_Nullable colorName);

// Rendu par défaut (forme naturelle, couleur auto). Pour les tests et le premier tick.
NSImage *TMWidgetImage(NSDictionary *readout);

// Couleur nommée de la palette, ou nil si « auto »/inconnu (pour l'aperçu éventuel côté natif).
NSColor *_Nullable TMWidgetNamedColor(NSString *name);

NS_ASSUME_NONNULL_END
