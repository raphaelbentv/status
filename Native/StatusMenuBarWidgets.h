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

// Un widget de consommation hebdomadaire d'une IA (« claudeWeek » / « codexWeek ») : sa donnée
// vient des familles quota injectées dans le snapshot, pas du moniteur système.
BOOL TMWidgetIsQuota(NSString *widgetId);

// Un widget de crédit API (« anthropicApi » / « openaiApi ») : famille injectée par Status.m avec
// { text, fraction, severity, template } déjà calculés.
BOOL TMWidgetIsApi(NSString *widgetId);
// Quota ou crédit API : la donnée vient des comptes, pas du moniteur système, et le clic ouvre le
// popover des comptes.
BOOL TMWidgetUsesAccounts(NSString *widgetId);

// Libellé lisible d'un widget (pour les Réglages).
NSString *TMMenuBarWidgetLabel(NSString *widgetId);

#pragma mark - Logique pure (testable)

// Déplace `item` de `delta` rangs dans `list` (−1 = vers la gauche, +1 = vers la droite).
// Retourne une nouvelle liste. Inchangée si l'élément est absent, si `delta` est nul, ou si le
// déplacement sortirait des bornes — un bouton en butée ne doit rien casser.
NSArray<NSString *> *TMArrayByMovingItem(NSArray<NSString *> *list, NSString *item, NSInteger delta);

// Signature du rendu d'un widget : deux ticks produisant la même signature dessineraient les mêmes
// pixels et le même titre — l'appelant peut alors sauter la régénération de l'image et la
// réassignation au NSStatusItem (chaque réassignation redéclenche un dessin WindowServer). Les
// formes à série (bars/graph, et spark pour la jauge principale) incluent la série — elle glisse
// à chaque tick, c'est leur raison d'être ; les autres l'ignorent, car leur dessin n'en dépend pas.
NSDictionary *TMWidgetRenderSignature(NSDictionary *readout, NSString *_Nullable shape,
                                      NSString *_Nullable colorName);

// Débit (octets/s) → 0..1, échelle logarithmique (1 = 100 Mo/s ou plus). Arcs ↓/↑ et sparkline réseau.
double TMWidgetRateFraction(double bytesPerSec);

// Forme réellement dessinée pour `shape` : elle-même si elle sait représenter la donnée du widget
// (d'après les champs du readout), sinon la forme naturelle (readout[@"style"]). Vide ou inconnue →
// forme naturelle.
NSString *TMWidgetResolvedShape(NSDictionary *readout, NSString *_Nullable shape);

// La forme (après résolution) dessine-t-elle son texte dans l'image ? Alors pas de titre système
// à côté de l'icône.
BOOL TMWidgetShapeCarriesText(NSDictionary *readout, NSString *_Nullable shape);

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
//   template      : gabarit du bloc texte dessiné (twoLine/battery) — pire cas de largeur
//   valueTemplate : gabarit de la valeur seule (titre système, forme « texte »)
// Retourne toujours un dictionnaire ; hasValue=NO si la famille source manque.
NSDictionary *TMWidgetReadout(NSString *widgetId, NSDictionary *snapshot);

#pragma mark - Dessin (AppKit)

// Icône d'un widget à partir de son readout, avec une forme et une couleur choisies.
//   shape : « bars » | « graph » | « ring » | « pie » | « bar » | « text » | « twoLine » | « battery ».
//           Vide → forme naturelle du widget. Une forme qui ne colle pas à la donnée retombe
//           dessus aussi (repli gracieux).
//   colorName : nom de la palette (blue, green, purple, cyan, orange, amber, red, pink, gray) ou
//           nil/« auto » → template neutre. La sévérité (alerte) prime toujours sur la couleur.
NSImage *TMWidgetImageStyled(NSDictionary *readout, NSString *_Nullable shape, NSString *_Nullable colorName);

// Variante à encre imposée : `inkOrNil` nil ⇒ image template (macOS l'inverse selon le thème).
// Sert à la jauge quota, dont l'encre vient de l'identité du fournisseur et non de la palette.
NSImage *TMWidgetImageWithInk(NSDictionary *readout, NSString *_Nullable shape, NSColor *_Nullable inkOrNil);

// Rendu par défaut (forme naturelle, couleur auto). Pour les tests et le premier tick.
NSImage *TMWidgetImage(NSDictionary *readout);

// Titre système occupant au minimum la largeur de `widthTemplate`, sans altérer le texte : le
// complément est un crénage posé après le dernier caractère. Un NSStatusItem dont le titre
// rétrécit (« 100 % » → « 9 % ») décale toutes les icônes voisines à chaque tick, et le panneau
// ouvert cesse de pointer sur la sienne. Un texte plus large que le gabarit est rendu tel quel.
NSAttributedString *TMTitleWithReservedWidth(NSString *text, NSString *_Nullable widthTemplate,
                                             NSDictionary<NSAttributedStringKey, id> *attributes);

// Couleur nommée de la palette, ou nil si « auto »/inconnu (pour l'aperçu éventuel côté natif).
NSColor *_Nullable TMWidgetNamedColor(NSString *name);

#pragma mark - Espacement système des icônes (réglage macOS, toutes les apps)

// macOS règle l'espace entre les icônes de la barre des menus pour TOUTES les apps par deux clés globales
// (NSStatusItemSpacing, NSStatusItemSelectionPadding), lues à l'ouverture de session. Trois préréglages :
// « normal » = clés absentes (réglage d'origine), « snug » = 8/8, « tight » = 4/4.
extern NSArray<NSString *> *TMSystemSpacingPresetIDs(void);                   // normal, snug, tight
// Valeurs à écrire pour un préréglage : @{ @"spacing": n, @"padding": n }, ou @{} pour « normal » (supprimer
// les clés) ; nil pour un préréglage inconnu — l'action native n'écrit alors rien.
NSDictionary<NSString *, NSNumber *> *_Nullable TMSystemSpacingValues(NSString *_Nullable preset);
// Préréglage correspondant aux valeurs lues (nil = clé absente) : normal, snug, tight, ou « custom ».
NSString *TMSystemSpacingPresetFor(id _Nullable spacing, id _Nullable padding);

#pragma mark - Taille et espacement des icônes (Réglages › Affichage)

// Valeurs autorisées, dans l'ordre des boutons des Réglages. Défauts : 1.0 (taille) et 0 (espacement).
extern NSArray<NSNumber *> *TMMenuBarIconScales(void);     // 0.85, 1.0, 1.15, 1.25
extern NSArray<NSNumber *> *TMMenuBarIconSpacings(void);   // 0, 4, 8, 14 (points ajoutés autour de l'image)

// Valeur validée : `value` si c'est un nombre de la liste autorisée, sinon le défaut. Une préférence
// bricolée, absente ou venue d'une version ultérieure retombe sur l'apparence actuelle.
CGFloat TMMenuBarIconScaleFromValue(id _Nullable value);
CGFloat TMMenuBarIconSpacingFromValue(id _Nullable value);
// La valeur est-elle exactement l'une des valeurs autorisées ? (l'action native n'écrit que celles-là)
BOOL TMMenuBarIconScaleIsAllowed(id _Nullable value);
BOOL TMMenuBarIconSpacingIsAllowed(id _Nullable value);

// Taille de l'image finale : (largeur × scale + spacing, hauteur × scale). Pure, testable.
NSSize TMMenuBarLayoutSize(NSSize size, CGFloat scale, CGFloat spacing);

// Corps (pt) du titre système à côté de l'icône : 12 × scale, arrondi au demi-point.
CGFloat TMMenuBarTitleFontSize(CGFloat scale);

// Enveloppe `image` pour la barre des menus : agrandie/réduite de `scale`, centrée dans une marge
// transparente qui ajoute `spacing` en largeur, drapeau template conservé. Image à drawingHandler :
// une source vectorielle reste nette à toute échelle. scale == 1 et spacing == 0 : retourne `image`
// elle-même, sans enveloppe (aucun changement pour les réglages par défaut).
NSImage *_Nullable TMMenuBarImageWithLayout(NSImage *_Nullable image, CGFloat scale, CGFloat spacing);

// Variante de TMWidgetRenderSignature qui inclut la mise en page : changer la taille ou l'espacement
// doit redessiner tout de suite, même si la donnée n'a pas bougé.
NSDictionary *TMWidgetRenderSignatureWithLayout(NSDictionary *readout, NSString *_Nullable shape,
                                                NSString *_Nullable colorName, CGFloat scale, CGFloat spacing);

NS_ASSUME_NONNULL_END
