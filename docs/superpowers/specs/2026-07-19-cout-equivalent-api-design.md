# Coût équivalent API

19 juillet 2026

## Contexte

Status affiche des pourcentages de consommation d'abonnement. Cette feature ajoute, à côté,
combien ces usages **auraient coûté en API** — un coût réel calculé sur les logs de session,
pas une estimation tirée d'un pourcentage.

Un prototype jetable (`scratchpad/cost.py`, 19 juillet 2026) a validé le concept sur les vrais
logs de la machine : **Claude ≈ 21 391 $ cumulé / 12 029 $ sur 7 jours**, Codex ≈ 83 k$ sur les
modèles chiffrables. Les décisions ci-dessous découlent de ce prototype.

## Décisions actées

### La source est les logs CLI, pas les pourcentages

Les quotas de l'app sont des pourcentages d'une fenêtre opaque — inconvertibles en dollars sans
une hypothèse de volume fabriquée (piste écartée, cf. le débat XDR : ne pas livrer un chiffre
décoratif). Les **logs de session** contiennent les vrais tokens par modèle :

- **Claude Code** : `~/.claude/projects/**/*.jsonl` — un bloc `usage` par message.
- **Codex** : `~/.codex/sessions/**/*.jsonl` + `~/.codex/archived_sessions/*.jsonl` — événements
  `token_count`.

Limite assumée, à afficher : ces logs ne couvrent que l'**usage terminal**. L'usage web
(claude.ai, chatgpt.com) n'est journalisé nulle part et n'est pas inclus. Étiquette « usage
terminal » partout.

### Les deux fournisseurs comptent le cache à l'opposé — LE point de correctness

C'est le piège que le prototype a révélé (surcompte ×8 s'il est ignoré) :

- **Claude** : compartiments **disjoints**. `input_tokens` = input hors cache, plus
  `cache_read_input_tokens` et `cache_creation_input_tokens` séparés. On somme les trois.
- **Codex/OpenAI** : `input_tokens` **inclut** `cached_input_tokens` (le cache est un
  sous-ensemble facturé au rabais). On facture `(input_tokens − cached_input_tokens)` au tarif
  plein, puis `cached_input_tokens` au tarif cache.

Un token a **quatre prix** (entrée, sortie, cache lu, cache écrit). Le raisonnement Codex
(`reasoning_output_tokens`) est facturé comme de la sortie.

### Claude précis, Codex best-effort étiqueté « approximatif »

- **Claude** : chiffre précis, réconcilié, par modèle.
- **Codex** : chiffré pour les modèles dont on a le tarif, affiché avec « ~ » et une mention
  « approximatif ». Raisons de la moindre confiance, à documenter en commentaire : deux signaux
  de tokens divergent d'un facteur ~2 (compaction, ré-émissions en streaming), et 8 modèles
  (gpt-5.4, gpt-5.2-codex, gpt-5.3-codex, famille gpt-5.1-codex, gpt-5.4-mini) n'ont pas de
  tarif. Les tokens des modèles sans tarif sont comptés à part, jamais chiffrés à un prix inventé.

Signal Codex retenu : le **dernier `total_token_usage` par session** (cumulé propre), sommé entre
fichiers — pas la somme des `last_token_usage` (qui double-compte les ré-émissions).

### Tarifs : table dans le code + fichier surchargeable, datée

Table de référence livrée dans le code (datée et sourcée), écrasable par un fichier de config
sans recompiler. La vue Réglages affiche la date des tarifs. Modèle inconnu → tokens comptés à
part et signalés, **jamais** de prix fabriqué.

Tarifs par 1M de tokens (sources : skill claude-api pour Claude ; BenchLM / aipricing.guru /
developers.openai.com / gptbreeze pour OpenAI ; relevés le 19 juillet 2026) :

| Modèle | Entrée | Sortie | Cache lu | Cache écrit |
| --- | --- | --- | --- | --- |
| claude-opus-4-8 | 5,00 | 25,00 | 0,50 | 6,25 |
| claude-opus-4-7 | 5,00 | 25,00 | 0,50 | 6,25 |
| claude-sonnet-5 | 2,00¹ | 10,00¹ | 0,20¹ | 2,50¹ |
| claude-sonnet-4-6 | 3,00 | 15,00 | 0,30 | 3,75 |
| claude-fable-5 | 10,00 | 50,00 | 1,00 | 12,50 |
| claude-haiku-4-5 | 1,00 | 5,00 | 0,10 | 1,25 |
| gpt-5.6-sol | 5,00 | 30,00 | 0,50 | 6,25 |
| gpt-5.6-terra | 2,50 | 15,00 | 0,25 | 3,125 |
| gpt-5.6-luna | 1,00 | 6,00 | 0,10 | 1,25 |
| gpt-5.5 | 5,00 | 30,00 | 0,50 | 6,25 |
| gpt-5.3-codex-spark | 1,75 | 14,00 | 0,175 | 2,1875 |

¹ Sonnet 5 en tarif d'introduction jusqu'au 31 août 2026 ; prévoir la bascule vers 3,00 / 15,00
/ 0,30 / 3,75 après cette date (la table datée rend le changement visible).

### Alignement sur les fenêtres

Pour chaque fenêtre déjà affichée (Claude 5 h, Claude semaine, Claude semaine-Fable, OpenAI
semaine), le coût des tokens journalisés dans cette même plage temporelle, à côté du pourcentage.
Filtrage par timestamp du log. La fenêtre Fable (scopée modèle) ne compte que le modèle Fable.
OpenAI : coût affiché au niveau du fournisseur (les deux limites hebdo partagent la plage).

## Architecture

Module `StatusCost`, partie pure séparée du balayage de fichiers, sur le modèle de `StatusQuota`.

- **Pur et testable** : `TMCostForTokens(tokens, prices, provider)` applique les quatre prix avec
  la bonne sémantique de cache selon le fournisseur ; `TMParseClaudeUsageLine`,
  `TMParseCodexTokenCount` extraient les tokens d'une ligne. Aucune I/O.
- **Balayage** : cache incrémental. Il y a ~2900 fichiers (1337 Claude + 1565 Codex) et l'app
  rafraîchit toutes les 5 min — les relire tous à chaque fois est exclu. Un fichier
  `token-usage.json` retient quels logs ont déjà été lus (chemin + taille + date de modif) et
  stocke les tokens agrégés par **tranche horaire**, par modèle, par fournisseur. À chaque
  rafraîchissement, seuls les fichiers nouveaux ou modifiés sont relus. Le coût d'une fenêtre =
  somme des tranches dont l'heure tombe après le début de la fenêtre. Premier balayage (long)
  hors thread principal ; « calcul en cours » en attendant.

## Interface

- **Dashboard** : coût à côté de chaque pourcentage dans les cartes de quota (« 84 % · ≈ 12,40 $
  API »), plus un total par fournisseur. Codex marqué « ~ approximatif ».
- **Popover** : total compact par fournisseur.
- **Réglages** : date des tarifs.
- Étiquette « usage terminal » partout ; jamais laisser croire que le web est inclus.

## Tests

Partie pure, sans machine :

- Les quatre prix appliqués correctement, **les deux sémantiques de cache** (Claude disjoint,
  OpenAI cache = sous-ensemble d'input). C'est le test qui compte le plus.
- Un modèle inconnu : tokens comptés à part, exclu du total, signalé — jamais chiffré.
- Parsing d'une ligne Claude et d'un `token_count` Codex de forme réelle.
- Filtrage par fenêtre temporelle.
- Invalidation du cache quand un fichier change de taille/date.

Le balayage de fichiers et l'intégration UI sont vérifiés en exécutant, pas en testant.

## Hors périmètre

- L'usage web (claude.ai, chatgpt.com) — non journalisé.
- Un total Codex complet — 8 modèles sans tarif ; leurs tokens sont comptés à part.
- Lever l'incertitude ~2x des logs Codex — assumée et étiquetée « approximatif ».
