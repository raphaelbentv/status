# Moniteur — batterie complète, cœurs CPU P/E, GPU détaillé, apps par ressource

Validé le 23 juillet 2026 en conversation, section par section, puis « go, dev
directement, je te fais confiance » (revue de spec déléguée, comme la spec du
Moniteur d'origine).

## Périmètre

Trois ajouts à l'onglet Moniteur, dans le cadre du pattern collecteur existant de
`StatusSystemMonitor` (un collecteur = un dictionnaire ou `nil`, dégradation
silencieuse) :

1. **Batterie complète** — nouvelle carte dépliable.
2. **Schéma des cœurs CPU (P/E) + GPU détaillé** — sous la charge CPU/GPU.
3. **Applications qui consomment CPU et RAM** — liste triable.

## Contraintes matérielles constatées (sondées avant conception)

- **Pas de GPU par cœur.** macOS n'expose la charge GPU qu'en agrégat via
  `IOAccelerator/PerformanceStatistics` : `Device Utilization %`, `Renderer
  Utilization %`, `Tiler Utilization %`, et la mémoire GPU en usage. Aucune
  ventilation par cœur GPU (32/40 cœurs sur M4 Max) n'existe. → On affiche les 3
  utilisations + la mémoire, pas des cœurs.
- **Pas de GPU par processus** par voie propre : `proc_pid_rusage` ne fournit
  aucun temps GPU (vérifié : pas de champ `ri_gpu_time`). → La liste d'apps est
  **CPU + RAM** seulement (décision utilisateur : ni énergie, ni API privée
  fragile).

## Collecte native (`StatusSystemMonitor.{h,m}`)

**GPU** — `TMCollectGPU` ajoute aux côtés de `usage` (Device) : `renderer`,
`tiler` (pourcentages), `memInUse` (octets). Mêmes clés `PerformanceStatistics`
déjà présentes ; une clé absente disparaît, le reste survit.

**Batterie** — nouvelle famille `battery`, collecteur lisant `AppleSmartBattery`
(IORegistry) + `IOPSCopyPowerSourcesInfo`. Clés :
`percent`, `charging`, `externalConnected`, `fullyCharged`, `cycleCount`,
`healthPercent` (capacité max/design en mAh réels), `conditionOK` (Normal vs
Service), `powerWatts` (tension×courant, signé — négatif en décharge),
`adapterWatts`, `minutesRemaining` (vers vide ou plein selon l'état),
`temperatureC`. Read-only, dégradation silencieuse. **La batterie quitte
`TMCollectSensors`** (qui ne garde que la température) : pas de double lecture, et
seule la carte Capteurs du Moniteur est impactée (batteryPercent n'était référencé
qu'à cet endroit).

**Cœurs P/E** — au premier échantillon, lecture de `hw.perflevel0.logicalcpu`
(Performance = 10) et `hw.perflevel1.logicalcpu` (Efficiency = 4). Ordre des index
de `host_processor_info` **vérifié empiriquement** sur la machine (charge QoS
background → cœurs 0-3) : **les cœurs E occupent les premiers index, les P
ensuite**. Règle exposée : `index < nombreE → "E", sinon "P"`. Le collecteur CPU
ajoute la clé `coreTypes` (chaîne, ex. `"EEEEPPPPPPPPPP"`) aux `core0…coreN` et
`total` déjà présents.

**Apps CPU + RAM** — `TMProcessSample` échantillonne déjà tous les pids avec
`rssBytes`. `TMTopProcesses` renvoie désormais l'**union** dédupliquée (par pid)
des top-8-par-CPU et top-8-par-RAM ; chaque entrée porte `name`, `cpuPercent`,
`rssBytes`. Le tri final (par CPU ou par RAM) se fait côté interface, sur cette
union — un gros consommateur RAM à faible CPU n'est donc jamais oublié.

## Interface (`dashboard.html`, onglet Moniteur)

- **CPU** — sous la jauge globale, un schéma des cœurs **groupé en deux blocs
  étiquetés** « Performance » (10) et « Efficience » (4), une barre par cœur,
  hauteur = charge instantanée. Remplace la rangée `.core-bars` plate actuelle.
- **GPU** — carte dépliable : jauge Device en tête ; au dépliage, courbes
  Renderer et Tiler + mémoire GPU en usage.
- **Batterie** — nouvelle carte dépliable : en tête, `percent` + état (charge /
  décharge / branché-plein) + puissance instantanée ; au dépliage : santé,
  cycles, condition, temps restant, wattage chargeur, température, tension.
- **Capteurs** — ne montre plus que la température (la batterie est partie).
- **Processus** — carte enrichie : liste triable (bouton CPU / RAM), top 8, deux
  colonnes de valeurs (CPU %, mémoire). Remplace la carte « Processus les plus
  actifs » (fixée au tri CPU).

## Tests

- **Logique pure** (`native-tests.m`) : tri union CPU/RAM (dédup par pid, top-8
  correct des deux côtés) ; cohérence `coreTypes` (longueur = nombre de cœurs,
  E puis P).
- **Fumée réelle** : la famille `battery` répond sur un portable (percent,
  cycleCount plausibles) ; le GPU expose renderer/tiler.
- Vérification finale sur l'app lancée : cartes Batterie/GPU/cœurs/apps avec de
  vraies valeurs.

## Non couvert (assumé)

- GPU par cœur et GPU par processus : impossibles proprement (voir contraintes).
- Sur un Mac de bureau sans batterie, la famille `battery` est absente (nil) : la
  carte ne s'affiche pas, comme toute famille dont le collecteur ne répond pas.
