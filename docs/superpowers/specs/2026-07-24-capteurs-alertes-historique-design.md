# Capteurs détaillés, alertes réglables, historique 24 h, ordre des widgets

Date : 2026-07-24

Quatre évolutions livrées ensemble, issues d'une revue de ce qui manquait ou mentait dans l'app.

## 1. Capteurs thermiques — la moyenne mentait

### Le problème

`TMCollectSensors` faisait la **moyenne de tous les capteurs HID plausibles**. Sur la machine de
référence (Apple Silicon, 46 capteurs), cela mélangeait :

| Famille | Nom matériel | Valeur typique |
|---|---|---|
| Dies du SoC | `PMU tdie1…10` | 42–45 °C |
| Périphériques | `PMU tdev1…8` | 32–41 °C |
| Cellule de batterie | `gas gauge battery` | 30–32 °C |
| Calibration | `PMU tcal` | ~52 °C |

Résultat affiché : **41 °C**, alors que le point chaud réel était **45 °C**. La batterie tirait la
moyenne vers le bas et masquait précisément la valeur qui gouverne le bridage thermique.

### La solution

Une fonction pure `TMSensorFamilyForName` classe chaque capteur d'après son nom, et les agrégats
sont calculés **par famille** :

- `die` — `tdie`, ou `peci`/`cpu`/`soc` (Intel et noms génériques) ;
- `device` — `tdev` ;
- `battery` — `battery`/`gas gauge`, **écarté des agrégats** (la famille `battery` l'expose déjà) ;
- `nil` — non classé, ignoré. `tcal` en fait partie : c'est une référence de calibration qui lit
  ~10 °C au-dessus des dies et gonflerait le point chaud.

Nouvelles clés : `dieMaxC`, `dieAvgC`, `dieCount`, `deviceMaxC`, `deviceAvgC`, `deviceCount`.
**`tempC` devient le maximum des dies** — le point chaud, pas une moyenne diluée.

### Ce qu'on ne peut pas faire

Les noms Apple Silicon sont **opaques** : il n'existe aucune étiquette « CPU » ou « GPU ». On ne
peut donc pas dire « voici la température du GPU » sans l'inventer. L'interface parle de « SoC » et
de « périphériques », ce qui est exactement ce que le matériel permet d'affirmer.

Repli : si aucun capteur n'est classé `die` (machine aux noms inconnus), `tempC` retombe sur
l'ancienne moyenne générale — une approximation vaut mieux que pas de température.

## 2. Alertes système réglables

Les seuils étaient **codés en dur** (90 °C, disque 90 %, pression mémoire critique) et non
désactivables. Ils deviennent une préférence `alerts` :

```
alerts = { temp: {on, threshold}, disk: {on, threshold}, memory: {on, threshold} }
```

Absent = **activée au seuil par défaut** : les alertes fonctionnent sans configuration préalable.

L'hystérésis suit le seuil via `TMAlertRearmThreshold` : 8 % du seuil, avec un plancher de 2 unités
pour que des seuils bas gardent une bande utile. Un seuil modifié **réarme les trois alertes** —
sinon une alerte déjà déclenchée au-dessus de l'ancien seuil resterait muette sous le nouveau.

La pression mémoire n'est pas un pourcentage : l'échelle noyau vaut 1/2/4 (normale / avertissement /
critique), d'où deux niveaux nommés plutôt qu'un curseur.

## 3. Historique 24 h persistant

Les anneaux du moniteur couvrent quelques minutes et vivent en RAM. Le nouvel historique est l'autre
échelle : **une ligne horodatée par minute, 24 h glissantes, sur disque**
(`metrics-history.json`), pour répondre à « qu'est-ce qui a chauffé cette nuit ? ».

- `TMLongHistoryRow` extrait 8 métriques résumées (cpu, ram, gpu, temp, disk, batt, rx, tx).
  Une famille absente **omet sa clé** — aucun zéro inventé, comme partout ailleurs.
- `TMLongHistoryAppend` élague par âge **relatif à la ligne la plus récente** (et non à « maintenant »,
  pour qu'un historique importé ne s'auto-efface pas) et par plafond de lignes.
- Un horodatage **antérieur au dernier connu est refusé** : après un changement d'heure, mieux vaut
  perdre un point qu'obtenir une série non monotone que les courbes dessineraient à l'envers.
- Sauvegarde toutes les 5 min en tâche de fond, plus un vidage synchrone à la fermeture.

Vue « 24 h » dans le Moniteur : une bande par métrique, avec max horodaté / moyenne / min. Le tracé
est **fonction du temps, pas de l'index** : une coupure de plus de 3 minutes (app fermée, veille)
laisse un **trou visible** au lieu d'un raccord silencieux qui mentirait sur la continuité.

### Piège rencontré

Le tout premier tick après lancement journalisait une ligne **sans CPU ni réseau** : ces deux
collecteurs exigent deux échantillons pour produire un delta. Quelques redémarrages suffisaient à
cribler la vue de trous. Corrigé en démarrant le compteur d'intervalle **à l'heure de lancement**,
si bien que la première ligne n'est écrite qu'une minute plus tard, collecteurs chauds.

## 4. Ordre des widgets réglable

L'ordre d'affichage était figé sur le catalogue ; seul le ⌘-glisser macOS permettait de réordonner,
sans être mémorisé. Désormais **l'ordre du réglage `menuBarWidgets` est l'ordre d'affichage**, piloté
par des flèches ← → dans les Réglages (`TMArrayByMovingItem`, pure et testée, bornée aux extrémités).

Contrainte AppKit : la position d'un `NSStatusItem` est **fixée à sa création** et aucune API
publique ne la déplace ensuite. Réordonner impose donc de **tout détruire et recréer**, d'où un bref
clignotement. macOS place chaque nouvel item **à gauche** des précédents : la création parcourt donc
la liste **à l'envers** pour que le premier réglé finisse le plus à gauche.

Vérifié sur la machine réelle via l'API d'accessibilité (positions x réelles des items) : l'ordre
stocké correspond exactement à l'ordre affiché, dans les deux sens testés.

**Limite honnête** : la position de la jauge quota par rapport aux widgets n'est pas contrôlée —
macOS lui garde sa place d'une session à l'autre. Elle se déplace au ⌘-glisser.
