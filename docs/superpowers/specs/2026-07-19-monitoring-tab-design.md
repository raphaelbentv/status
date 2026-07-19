# Onglet Moniteur — métriques système

Validé le 19 juillet 2026. Sections 1–2 approuvées explicitement ; le reste délégué
(« je te fais confiance, commence le dev »).

## Périmètre

- Métriques : CPU (global + par cœur), GPU, RAM (occupation + pression), réseau (débits
  montant/descendant), disque (espace + débits E/S), capteurs (températures, ventilateurs,
  batterie).
- Historique : fenêtre glissante en mémoire, 300 échantillons à 1 Hz (5 min). Rien sur disque.
- Échantillonnage : permanent, dès le lancement — les anneaux sont pleins quand on ouvre l'onglet.
- Affichage : vue `04 Moniteur` du dashboard **et** section compacte dans le popover.
- La barre des menus (icône) ne change pas : elle reste dédiée aux quotas.

## Approche retenue (A — hybride sans privilèges)

API publiques partout où elles existent : `host_processor_info` (CPU), `host_statistics64`
(RAM/pression), `getifaddrs` (réseau), `statfs` + registre `IOBlockStorageDriver` (disque),
`IOPSCopyPowerSourcesInfo` (batterie). GPU via la clé `PerformanceStatistics` du registre
`IOAccelerator` ; températures/ventilateurs via lecture SMC/HID read-only — deux sources non
documentées, assumées comme telles (même philosophie que l'endpoint `/usage` claude.ai).

Rejetées : `powermetrics` (exige root, donc helper privilégié — disproportionné) ; publiques
strictes (ampute GPU et capteurs, explicitement demandés).

## Architecture

`StatusSystemMonitor.h/.m`, sur le modèle des modules existants :

- **Logique pure, testable sans machine** : anneau `TMMetricRing` (capacité fixe, écriture
  circulaire, lecture ordonnée) ; deltas (ticks CPU → %, compteurs cumulatifs → débit, compteur
  qui recule → échantillon écarté) ; sérialisation du snapshot. Aucun appel système.
- **Collecteurs** : un par famille, même interface — « échantillonne, retourne un dictionnaire
  ou `nil` ». `nil` = la famille sort du payload. C'est l'unique mécanisme de dégradation.

`TMAppDelegate` : un timer 1 Hz, `sample` puis `snapshotJSON`, poussée aux webviews. Il ne
connaît ni IOKit ni les anneaux.

## Flux et cadence

- Tick 1 Hz : échantillonner (toujours) → pousser (seulement si la surface est visible :
  `window.isVisible` pour le dashboard, `statusPopover.isShown` pour le popover).
- Canal séparé des quotas : `StatusApp.updateMetrics(json)` / `StatusMenu.updateMetrics(json)`.
  Le cycle quotas de 5 min ne change pas.
- Chaque snapshot contient les séries complètes (pas d'incrémental) : la réouverture redessine
  tout l'historique d'un coup. Valeurs en entiers compacts ; snapshot ≤ ~15 Ko.

## Interface

- **Dashboard, vue `04 Moniteur`** : grille de cartes dans le style Blueprint existant
  (monospace, hairlines cyan, la couleur ne sert qu'aux données). Par carte : valeur courante en
  grand + sparkline SVG de la série (aucune bibliothèque — cohérent avec le reste du fichier).
  CPU affiche en plus une barre par cœur. Une famille absente du payload = carte absente,
  sans état d'erreur.
- **Popover** : rangées compactes (étiquette, valeur, mini-sparkline) sous les quotas.

## Erreurs

Un collecteur qui échoue retourne `nil`, silencieusement — pas de log répété à 1 Hz, pas de
tuile d'erreur. Les clés non documentées (GPU, SMC) sont précisément celles qui peuvent
disparaître à une mise à jour macOS : l'interface doit rester correcte ce jour-là sans
intervention.

## Tests (native-tests.m, harnais existant)

- Anneau : capacité, ordre après enroulement, série partielle avant remplissage.
- Deltas : cas nominal, compteur qui se réinitialise (reboot d'interface), horloge qui recule.
- CPU : conversion ticks → pourcentage, bornes 0–100.
- Snapshot : familles présentes/absentes selon les collecteurs, format des séries.

Les collecteurs eux-mêmes ne sont pas testés unitairement (ils lisent la machine) ; leur
contrat — dictionnaire ou `nil` — est couvert par les tests de snapshot.
