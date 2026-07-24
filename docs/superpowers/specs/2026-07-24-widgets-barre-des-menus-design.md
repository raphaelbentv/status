# Widgets de la barre des menus (multi-icônes façon iStat Menus)

Validé le 24 juillet 2026, sections 1-2 approuvées, reste délégué (« je te fais
confiance »).

## Objectif

Afficher plusieurs indicateurs système en même temps dans la barre des menus,
chacun sa propre icône `NSStatusItem`, avec un rendu riche calqué sur iStat Menus
(capture fournie par l'utilisateur : histogramme CPU, camembert, pile batterie,
texte réseau ↓/↑, temp/watts sur deux lignes).

## Décisions

- **Rendu riche** (pas sobre) : histogrammes, camemberts, pile de batterie, texte
  deux lignes.
- **L'icône quota reste distincte** : identité de l'app + point d'entrée du
  popover. Les widgets système s'ajoutent à côté, indépendants.
- **Cadre de widgets couvrant tous les indicateurs** (cpu, memory, gpu, network,
  temperature, battery, disk), chacun activable dans les Réglages. Désactivés par
  défaut : les utilisateurs existants ne voient aucun changement.

## Architecture

**Nouveau module `Native/StatusMenuBarWidgets.{h,m}`** (isole ~7 rendus du
`Status.m` déjà volumineux) :

- **Pur, testable** : `TMWidgetReadout(NSString *widgetId, NSDictionary *snapshot)`
  → dictionnaire `{ style, title, primary, secondary, fraction, series, charging,
  hasValue }`. Extrait du snapshot moniteur la/les valeurs et les met en forme
  (« 74 Ko/s », « 50° », « Full »…). Aucun AppKit, sérialisable, testé.
- **Dessin** (non testé unitairement, comme les icônes actuelles) :
  `TMWidgetImage(NSDictionary *readout)` → `NSImage` selon `style` :
  `bars` (histogramme), `pie` (camembert), `battery` (pile + texte), `twoLine`
  (deux lignes de texte).

**`Status.m` — cycle de vie** :
- Un tableau de `NSStatusItem`, un par widget activé. (Re)construit quand la liste
  `menuBarWidgets` change (toggle Réglages).
- Redessin dans `metricsTick` : le moniteur échantillonne déjà à chaque tick pour
  les alertes ; on redessine chaque widget depuis ce snapshot, même toutes
  surfaces fermées.
- Clic sur un widget → popover partagé, ancré sous le widget cliqué. Widgets
  système en **clic seul** (pas de survol, trop d'icônes sinon) ; la jauge quota
  garde son survol.
- Ordre géré par macOS (⌘-glisser), comme iStat — rien à coder.
- Persistance : `menuBarWidgets` (NSUserDefaults, liste d'ids), vide par défaut.

## Les widgets

| id | style | primaire / secondaire | source (snapshot) |
|----|-------|----------------------|-------------------|
| cpu | bars | titre « 43 % » ; barres = série `cpu.total` | famille cpu |
| memory | pie | titre « 68 % » ; camembert = `ram.usedPercent` | famille ram |
| gpu | bars | titre « 24 % » ; barres = série `gpu.usage` | famille gpu |
| network | twoLine | « ↓ 74 Ko/s » / « ↑ 70 Ko/s » | famille network |
| temperature | twoLine | « 50° » / « 20 W » (watts omis si absent) | sensors.tempC, battery.powerWatts |
| battery | battery | pile + « Full »/« 2 h 14 » / « 100 % » ; éclair si charge | famille battery |
| disk | pie | titre « 74 % » ; camembert = `disk.usedPercent` | famille disk |

**Conventions** (héritées de l'icône actuelle) : chiffres monospace, couleur
seulement quand elle informe (ambre/rouge en alerte ; sinon template suivant le
thème), tiret tant qu'aucune donnée, échelle fixe 0-100 pour les graphes.

## Réglages (dashboard.html)

Section « Widgets de la barre des menus » : les 7 widgets, chacun avec un toggle
(`setMenuBarWidget {id, on}`). Un texte rappelle qu'on réordonne les icônes en les
⌘-glissant dans la barre.

## Tests

- **Pur** (`native-tests.m`) : `TMWidgetReadout` — formats réseau (o/Ko/Mo), temp
  avec/sans watts, batterie (Full/charge/temps), fractions cpu/mem/disk, absence
  de donnée → `hasValue` NO. Snapshots synthétiques, sans écran.
- **Fumée / réel** : build, install, vérifier que les icônes activées apparaissent
  et se mettent à jour avec de vraies valeurs.

## Non couvert

- Réordonnancement programmatique (délégué à macOS).
- Historique par-cœur dans l'icône CPU (charge globale seulement, comme la
  capture).
