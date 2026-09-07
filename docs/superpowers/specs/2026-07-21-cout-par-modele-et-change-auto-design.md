# Coût par modèle, tarifs visibles et change automatique

21 juillet 2026

## Contexte

La feature « coût équivalent API » (voir `2026-07-19-cout-equivalent-api-design.md`) affiche déjà,
à côté des pourcentages d'abonnement, ce que les usages terminal auraient coûté en API — total par
fournisseur, sur la fenêtre choisie, en dollars et en euros.

Trois manques demandés :

1. **Le taux de change est figé** dans le binaire (`TMEurPerUsd = 0.92`, relevé « 19 juillet 2026 »).
   L'euro affiché vieillit à chaque jour qui passe.
2. **Le calcul est opaque** : on voit un montant, jamais les tarifs qui le produisent.
3. **Aucune ventilation** : impossible de voir quel modèle pèse dans la facture. Le scan connaît
   pourtant le modèle de chaque message — il le jette juste au moment d'agréger.

## Décisions actées

### Ventilation par modèle : coût + tokens, dans le dashboard

Le scan garde aujourd'hui `heure → coût` et perd le modèle à l'accumulation
(`TMAccumulate`, `StatusCost.m`). Nouveau format de tranche :

```
heure(epoch) → modèle → { "cost": Double, "tokens": Double }
```

- Un modèle **tarifé** : clé `cost` présente (son coût) + `tokens` (somme de tous ses compartiments).
- Un modèle **non tarifé** (prix inconnu) : clé `cost` **absente**, `tokens` seul. On garde ainsi le
  **nom** du modèle inconnu, là où l'ancien code fondait tout dans un scalaire `unpriced` anonyme.
  L'absence de `cost` distingue proprement « pas de tarif » de « tarif nul ».

Ce nid rend la ventilation window-filtrable : le tableau du dashboard trie par coût décroissant sur
la fenêtre active, et les modèles non tarifés y apparaissent en fin de liste avec un coût « — ».

Affichage : **dans le dashboard uniquement**. Un tableau par fournisseur — *Modèle | Tokens | Coût
($ / €)*. Le popover reste synthétique (total par fournisseur) : sa hauteur est déjà juste, on n'y
ajoute rien.

### Tarifs en infobulle sur la ligne de coût

La table de prix (`TMPricesForModel`) reste la source unique — par million de tokens, par modèle.
Au survol de la ligne de coût du dashboard, une infobulle liste les tarifs **appliqués** pour les
modèles présents dans la fenêtre : entrée / sortie / lecture cache / écriture cache, par million.
`costPayload` transmet donc une map `prices` restreinte aux modèles vus (pas toute la table).

### Taux de change automatique, avec repli strict

Nouveau module `StatusFx`. Au lancement, si le cache local date de plus de ~20 h, une requête de
fond récupère le taux USD→EUR ; sinon on réutilise le cache.

- **Source** : [Frankfurter](https://frankfurter.dev), `api.frankfurter.dev/v1/latest?base=USD&symbols=EUR`.
  Taux de référence BCE, sans clé, gratuit. Publié une fois par jour ouvré.
- **Cache** : `Application Support/Status/fx-rate.json` — `{ rate, asOf, fetchedAt }`.
- **Chaîne de repli** (stricte, jamais de taux inventé) : taux du jour → dernier taux connu en
  cache → constante compilée `TMEurPerUsd`. La date affichée est celle du relevé réellement utilisé
  (`asOf` BCE, ou la constante `TMFxAsOfDate` en dernier recours).
- **Cadre** : c'est le **premier appel sortant de l'app vers un tiers** autre qu'Anthropic/OpenAI.
  Il ne transporte aucune donnée utilisateur (juste `base` et `symbols`). Toujours étiqueté
  « indicatif », jamais présenté comme un taux de facturation exact.

Logique pure testable :

- `BOOL TMFxShouldRefresh(NSTimeInterval fetchedAt, NSTimeInterval now, NSTimeInterval ttl)` —
  rafraîchir si jamais récupéré (`fetchedAt <= 0`) ou plus vieux que `ttl`.
- `BOOL TMParseFxResponse(NSDictionary *json, double *outRate, NSString **outAsOf)` — extrait
  `rates.EUR` et `date`, rejette une réponse malformée ou un taux non positif.

L'appel réseau et l'écriture du cache sont vérifiés en exécutant, comme le reste de l'I/O.

## Architecture

### `StatusCost` — le refactor du cœur

- `double TMCostSince(NSDictionary *buckets, NSTimeInterval startEpoch)` — **même signature**,
  parcourt désormais `heure → modèle → {cost}` et somme les `cost` des heures ≥ début. Le total
  accentué du dashboard/popover est inchangé.
- `NSArray<NSDictionary *> *TMModelBreakdownSince(NSDictionary *buckets, NSTimeInterval startEpoch)`
  — **nouvelle**. Retourne `[{ "model": NSString, "cost": NSNumber|absent, "tokens": NSNumber }]`
  triée par coût décroissant (les non tarifés, sans `cost`, en fin). Pure.
- `TMAccumulate` réécrite : range `{cost?, tokens}` par modèle dans la tranche horaire, au lieu d'un
  coût scalaire + `unpriced` séparé.
- `TMScanClaudeFile` / `TMScanCodexFile` : mêmes marqueurs et même parsing, seule change la forme
  accumulée. Le retour par fichier devient `{ fp, provider, buckets }` (plus de `unpriced` séparé).

### Cache versionné

Le format de `token-usage.json` change → l'ancien cache est incompatible. On ajoute
`"version": 2` au fichier. À la lecture, si la version ne correspond pas, on ignore le cache : un
**rescan complet** (~20 s, déjà le comportement à froid) reconstruit au nouveau format, puis
l'incrémental par empreinte reprend. Aucune migration, aucun format hybride.

### `StatusFx` — module isolé

`StatusFx.{h,m}` : les deux fonctions pures ci-dessus + une classe `TMFxRate` qui charge le cache,
déclenche le fetch de fond si périmé, et expose `eurPerUsd` / `asOf` avec la chaîne de repli. Status.m
l'interroge de façon synchrone (valeur en cache) et laisse le rafraîchissement se faire en fond.

### Câblage `costPayload` (Status.m)

`refreshCostsInBackground` / `costPayload` envoient en plus :

- `breakdown` : `{ claude: [ {model, cost?, tokens} … ], codex: [ … ] }`, déjà trié, pour la fenêtre.
- `prices` : `{ model → {input, output, cacheRead, cacheWrite} }` restreint aux modèles présents,
  pour l'infobulle.
- `eurPerUsd` et `fxAsOf` proviennent de `TMFxRate` (live si dispo, repli sinon).

### Affichage

- **dashboard.html** : sous le coût, un tableau par fournisseur (*Modèle | Tokens | Coût $ / €*),
  trié, avec une ligne finale « non tarifés » (tokens seuls, coût «—») si présents. Infobulle des
  tarifs appliqués au survol de la ligne de coût.
- **menubar.html** : inchangé.

## Tests

Natifs (logique pure) :

- `TMCostSince` sur le nouveau nid (héritage : mêmes totaux qu'avant à données égales).
- `TMModelBreakdownSince` : tri, présence/absence de `cost`, filtrage par fenêtre.
- `TMFxShouldRefresh` : jamais récupéré, frais, périmé.
- `TMParseFxResponse` : réponse valide, `rates.EUR` manquant, taux ≤ 0, JSON non-dictionnaire.

JS (harnais existant) : rendu du tableau par modèle et de l'infobulle si testable en `vm`.

I/O vérifiés en exécutant : scan au nouveau format (valeurs cohérentes avec l'actuel à total égal),
bascule de version du cache, fetch FX réel + repli quand le réseau est coupé.

## Hors périmètre

- Pas de ventilation par modèle dans le popover (hauteur).
- Pas d'historique du taux de change ni de graphe de change.
- La borne des 8 jours du scan et l'étiquette « usage terminal » restent inchangées.
  - **Révision du 2026-09-07** : le scan remonte désormais à **31 jours** (`TMCostMaxAge`) et le
    compteur de la vue Volumes propose **deux fenêtres, 8 jours et 30 jours**, choisies par un
    sélecteur commun aux deux fournisseurs (comparer l'un sur 8 j et l'autre sur 30 n'aurait aucun
    sens). Chaque fenêtre porte son propre total, sa ventilation par modèle et ses tarifs
    (`costs.<fournisseur>.periods.d8 / .d30`) : le tableau explique toujours le montant affiché.
    Les totaux sont maintenant **bornés explicitement** (`now − 8 j`, `now − 30 j`) au lieu de
    sommer tout le contenu lu — un journal modifié hier peut contenir des lignes bien plus
    anciennes, qui gonflaient le « 8 jours ». Le compteur reste **par fournisseur, tous comptes
    confondus** : les journaux de session terminal ne sont rattachés à aucun compte.
