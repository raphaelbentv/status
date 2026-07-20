# Gestionnaire de fenêtres

Validé le 19 juillet 2026.

## Intention

Disposer les fenêtres au clavier pour le multitâche, sans quitter les mains du clavier ni viser
à la souris. Le besoin premier est le duo : deux applications côte à côte, dans un rapport choisi.

## Périmètre général

Le projet est découpé en trois étapes, chacune livrable et utile seule.

| Étape | Contenu | État |
|---|---|---|
| **1a** | Placement de la fenêtre active sur une disposition, déplacement entre écrans | cette spec |
| **1b** | Duo : deux fenêtres placées d'un coup, la seconde choisie dans un sélecteur | cette spec |
| **2** | Pavage automatique principale + pile, observation des événements de fenêtres | spec ultérieure |

L'étape 1 construit ce dont l'étape 2 a besoin — énumération, application des cadres,
infrastructure de raccourcis, plomberie des réglages. Rien n'y est jeté.

## Limites assumées, valables pour tout le projet

- **Déplacer une fenêtre vers un autre espace** (bureau virtuel) est hors de portée sans API
  privées ou SIP désactivé. Tout reste confiné à l'espace courant.
- **Certaines applications refusent le redimensionnement** par l'API d'Accessibilité — taille
  fixe, ou implémentations Electron capricieuses. On le détecte et on renonce, sans lutter.
- **Les fenêtres en plein écran natif** vivent dans leur propre espace : elles sont écartées.
- **L'autorisation d'Accessibilité est requise.** Elle est déjà accordée (verrou clavier,
  raccourci global) et le certificat de signature étant stable, elle survit aux reconstructions.

## Dispositions retenues

Familles cochées lors de la conception :

- **Moitiés** : gauche, droite (haute et basse disponibles, non retenues)
- **Deux tiers** : 2/3 gauche, 2/3 droite
- **Tiers verticaux** : gauche, centre, droite
- **Trois quarts** : 3/4 gauche, 3/4 droite
- **Plein écran** et **centrer**
- **Entre écrans** : suivant, précédent

Raccourcis proposés, tous sur la base `⌃⌥` (rien de réservé par macOS, et base commune avec
Rectangle pour que les réflexes soient transférables) :

| Disposition | Raccourci |
|---|---|
| Moitié gauche / droite | `⌃⌥←` / `⌃⌥→` |
| 2/3 gauche / droite | `⌃⌥⇧←` / `⌃⌥⇧→` |
| Tiers gauche / centre / droite | `⌃⌥⌘←` / `⌃⌥⌘↑` / `⌃⌥⌘→` |
| 3/4 gauche / droite | `⌃⌥⇧U` / `⌃⌥⇧I` |
| Plein écran | `⌃⌥↩` |
| Centrer | `⌃⌥C` |
| Écran suivant / précédent | `⌃⌥⌘↩` / `⌃⌥⌘⌫` |

Pas de cyclage : un raccourci par disposition, choix explicite de l'utilisateur.

## Architecture

`StatusWindowManager.{h,m}`, sur le modèle des modules existants, en deux couches nettement
séparées :

**Logique pure, testable sans machine.** `TMWindowFrameForLayout(zone, disposition, marges)`
rend le cadre à appliquer. Aucun appel système. C'est là que vivent les pièges réels : arrondis
au pixel qui laisseraient une bande d'un point entre deux fenêtres adjacentes, marges qui ne
doivent pas se cumuler aux bords de l'écran, écrans de rapports différents.

**Application.** Énumération via `AXUIElementCreateApplication` + `kAXWindowsAttribute`,
écriture de `kAXPositionAttribute` et `kAXSizeAttribute`. Cette couche sait qu'une application
peut refuser, et le signale au lieu de faire semblant.

`TMAppDelegate` ne gagne qu'un objet `windowManager` et l'enregistrement des raccourcis, sur le
mécanisme déjà éprouvé par `⌘⇧S` (moniteur global + moniteur local, le global ne recevant rien
quand Status est l'app active). Il ne connaît ni l'API d'Accessibilité ni la géométrie.

## Étape 1b — le sélecteur

`NSPanel` centré sur l'écran actif, environ 520 × 400, niveau flottant, sans barre de titre,
contenant une `WKWebView` qui charge `picker.html`. Il hérite ainsi de `themes.css` : le
sélecteur suit le thème actif sans une ligne de CSS dupliquée.

- **Liste** : toutes les fenêtres visibles sauf l'active, avec icône, nom d'application et titre.
  La première est présélectionnée.
- **Clavier** : ↑ ↓ pour naviguer, ↩ pour valider, ⎋ pour annuler ; la frappe filtre sur le nom
  d'application et le titre. Le panneau devient `keyWindow`, donc reçoit les touches directement.
- **Aperçu** : deux rectangles au rapport demandé, l'application active nommée dans l'un et la
  sélection courante dans l'autre — on voit le résultat avant de valider.
- **Validation** : les deux fenêtres sont placées, le focus revient à celle qui était active.
- Le panneau se ferme au clic extérieur ou au changement d'application : il ne survit jamais à
  l'intention qui l'a ouvert.

Trois raccourcis, un par partage : 50/50, 2/3 pour l'active, 1/3 pour l'active.

## Réglages — section « Fenêtres » de l'onglet 04

- **Activer le gestionnaire** — interrupteur maître ; éteint, aucun raccourci n'est enregistré.
- **Marge entre fenêtres** — 0, 4, 8, 12 px.
- **Marge des bords d'écran** — même échelle, indépendante.
- **Respecter les zones réservées** — actif par défaut : les cadres évitent la barre des menus et
  le Dock. Désactivé, ils occupent l'écran physique entier.
- **Liste des raccourcis**, en lecture seule pour cette livraison. Les rendre modifiables exige un
  capteur de touches ; c'est noté pour plus tard plutôt que bâclé.

## Erreurs

Même principe que le reste de l'app : ne jamais faire semblant.

- Application qui refuse le redimensionnement : on écrit, on relit, et si le cadre obtenu s'écarte
  de plus de quelques points, la fenêtre est laissée telle quelle. Pas de boucle, pas d'insistance.
- Autorisation d'Accessibilité révoquée : les raccourcis ne répondent plus et les Réglages
  l'affichent, comme le fait déjà le raccourci global.
- Fenêtre en plein écran natif : écartée.
- Aucune fenêtre candidate pour un duo : le sélecteur le dit au lieu de s'ouvrir vide.

## Tests

Dans `native-tests.m`, sur la logique pure :

- chaque disposition sur un écran de référence ;
- les marges qui ne se cumulent pas aux bords de l'écran ;
- l'absence de bande résiduelle entre deux fenêtres adjacentes — le cas classique où 1/3 + 2/3
  ne fait pas 100 % à cause des arrondis ;
- des écrans de rapports différents ;
- le déplacement entre écrans, qui conserve les proportions relatives.

La couche d'application n'est pas testée unitairement : elle parle à d'autres processus. Elle est
vérifiée en lançant l'app et en déplaçant une vraie fenêtre, comme le verrou clavier — et cette
vérification doit être faite avant toute affirmation de bon fonctionnement.
