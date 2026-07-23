# Contrôle de luminosité des moniteurs

Validé le 23 juillet 2026 en conversation, section par section (« oui, go » après
chaque partie), puis « je valide tout, fais l'implémentation ».

## Périmètre

- **Écrans pilotés** : interne **et** externes.
  - Interne : lecture/écriture de la luminosité via API privée.
  - Externes : DDC/CI (norme VESA MCCS) transporté en I2C, **Apple Silicon uniquement** — pas
    de chemin Intel `IOFramebuffer` (le README exige déjà macOS 14+ ; sur ce parc Apple Silicon,
    le chemin Intel serait du code mort à maintenir).
- **Emplacements UI** : les deux.
  - Nouvel onglet « Écrans » dans le tableau de bord (barre latérale, entre Moniteur et
    Réglages, numéroté `04`, Réglages passe à `05`).
  - Rangée compacte de mini-curseurs dans le popover de la barre des menus.
- **Touches clavier F1/F2** : oui — pilotent aussi les moniteurs externes (fonction phare de
  MonitorControl : macOS ne le fait pas nativement pour les écrans non-Apple). Opt-in, réutilise
  l'autorisation Accessibilité déjà demandée pour le verrou clavier / le gestionnaire de fenêtres.
- **Multi-écrans** : curseurs **indépendants** par défaut, pas de mode « lié ». La touche
  clavier, elle, ajuste **tous les écrans pilotables ensemble** (choix délibéré : la touche
  physique règle l'ambiance générale du poste, le curseur règle un écran précis).
- **Échec DDC par écran** : l'écran reste **listé** (nom, badge externe) avec le curseur
  désactivé et la mention « DDC/CI indisponible » — pas de masquage silencieux dans le tableau
  de bord. Dans le popover (trop dense), un écran non pilotable est simplement omis.

## Architecture

`Native/StatusDisplays.{h,m}`, sur le modèle de `StatusSystemMonitor` :

- **Logique pure, testable sans machine** : bornage `[0,100]` (NaN → 0, jamais propagé au JSON),
  pas clavier (`TMSteppedBrightness`), conversion pourcentage ↔ valeur VCP (échelle propre au
  moniteur, souvent 0-100 mais parfois 0-64 ; `maximum` nul → 0, pas de division par zéro),
  construction/décodage des trames DDC/CI « Get/Set VCP Feature » (checksum, opcode, code VCP,
  erreur moniteur → rejet). Aucun appel système.
- **Contrôleurs** (`TMDisplay`, `TMDisplayManager`) : parlent au matériel, non testés
  unitairement — leur contrat (un écran disponible ou non) est couvert par le test de fumée.

**Détection** (API publiques) : `CGGetActiveDisplayList`, `CGDisplayIsBuiltin`,
`NSScreen.localizedName` pour le nom, `CGDisplayVendor/Model/SerialNumber` pour un identifiant
stable d'un lancement à l'autre (externe) ; l'interne est toujours `"builtin"`.

**Symboles privés chargés par `dlsym`, jamais liés statiquement** (même compromis que le GPU et
les capteurs HID du Moniteur, ou l'endpoint `/usage` claude.ai) : un symbole absent laisse le
pointeur à `NULL`, la famille se déclare indisponible — aucun risque d'échec de build ni de
plantage au lancement si Apple renomme le symbole dans une future version.

**Externes** : `IOAVServiceCreateWithService` + `IOAVServiceRead/WriteI2C` (adresse DDC `0x37`),
services `DCPAVServiceProxy` du registre IOKit. Appariement écran ↔ service par ordre
d'énumération — correct sans ambiguïté avec un seul écran externe (le cas courant). **Limite
assumée** : avec plusieurs externes, l'ordre entre `CGGetActiveDisplayList` et
`DCPAVServiceProxy` n'est pas garanti correspondre à l'agencement physique ; non levée faute de
matériel de test multi-écrans.

## Écran interne — DisplayServices, pas CoreDisplay (découvert au test)

Le design initial visait `CoreDisplay_Display_Get/SetUserBrightness`. **Vérifié empiriquement sur
la machine de développement (M4 Max, macOS 27) que CoreDisplay ment sur cette version** : `Get`
renvoie toujours `1.0` quelle que soit la luminosité réelle, `Set` n'a aucun effet. Bascule sur
`DisplayServicesGetBrightness` / `DisplayServicesSetBrightness` (framework privé
`DisplayServices`), qui lisent et écrivent correctement — prouvé par un round-trip indépendant
(écriture 35 % → relecture 35 % hors cache de l'app). C'est la raison d'être du test de fumée
`TestDisplayManagerLive` et de l'outil de vérification autonome.

## Intégration (`Status.m`)

- `TMDisplayManager` créé **avant** tout appel possible à `pushData` (le premier crash observé :
  `refreshCostsInBackground` pousse un payload dès le lancement, et `payload` lit
  `self.displayManager` sans filet — un `nil` fait planter le literal `@{...}`).
- `payload` : nouvelle clé `displays` (snapshot), et `prefs.brightnessKeys`.
- Action `setBrightness {id, value}` → `TMDisplay setBrightnessPercent:` (optimiste : pas de
  relecture DDC à chaque écriture, coûteuse sur le bus I2C).
- Action `toggleBrightnessKeys` → persiste `brightnessKeysEnabled`, (ré)installe le moniteur.
- **Touches F1/F2** : `NSEventMaskSystemDefined`, `subtype == 8`, `NX_KEYTYPE_BRIGHTNESS_UP/DOWN`,
  pas de 6 %. Le moniteur local **ne consomme jamais** l'événement (contrairement à ⌘⇧S) : on le
  renvoie inchangé pour laisser macOS continuer à piloter l'écran interne et afficher son propre
  indicateur — Status n'ajoute que le pilotage DDC/CI des externes à côté.
- **Rescan** sur `NSApplicationDidChangeScreenParametersNotification` (branchement/débranchement)
  et au réveil — pas en continu, la luminosité ne dérive pas seule entre deux branchements.

## Interface

- **Onglet Écrans** (`dashboard.html`) : une carte par écran (gabarit `.metric-card`), badge
  interne/externe, `<input type="range">` restylé à la trame de l'app, écriture au `change`
  (relâchement) et non au `input` (le glissement met à jour l'affichage local seulement). Écran
  indisponible : mention « DDC/CI indisponible ».
- **Popover** (`menubar.html`) : rangée `.brightness` sous les métriques, un mini-curseur par
  écran pilotable ; non pilotables omis.
- **Réglage** (onglet Réglages) : toggle « Piloter la luminosité au clavier », désactivé par
  défaut, même avertissement « Autorisation manquante » que les autres toggles Accessibilité.
  Pas de toggle pour les curseurs eux-mêmes : la détection DDC ne demande aucune permission,
  donc toujours active (comme le Moniteur).

## Tests

- **Logique pure** (`native-tests.m`) : bornage/pas clavier, conversion VCP (dont échelle 0-64 et
  `maximum` nul), cohérence construction/décodage DDC (checksum invalide → rejet, code VCP
  inattendu → rejet, trame vide → pas de crash).
  - **Réserve** : la convention exacte de l'octet de checksum d'une **réponse** DDC varie selon
    les sources, et aucun moniteur externe n'est branché sur la machine de dev. Le test valide la
    cohérence interne construction/lecture, **pas** la conformité à un vrai moniteur — à
    revérifier sur matériel externe réel.
- **Fumée réelle** (`TestDisplayManagerLive`) : détection de l'écran interne, snapshot
  sérialisable.
- **Round-trip réel** (outil autonome, hors suite) : écriture d'une luminosité puis relecture
  indépendante via `DisplayServices`, restauration de la valeur d'origine. C'est la preuve que
  l'app change bien l'état que macOS retient, pas seulement une valeur locale.

## Non vérifié / suites possibles

- Rendu visuel du curseur dans l'onglet Écrans du tableau de bord (câblage JS→natif confirmé par
  l'absence de crash de `pushData` + tests web verts, mais pas d'inspection à l'écran).
- Pilotage DDC/CI d'un **vrai moniteur externe** (protocole, appariement multi-écrans, checksum
  de réponse) — machine de dev sans écran externe au moment de l'implémentation.
