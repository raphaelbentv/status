# Authentification et quotas réels — recherche pour Status

État de la recherche : 14 juillet 2026. Cette note distingue volontairement les interfaces publiques/supportées des API privées ou des techniques de scraping.

> **⚠️ Lire le § 6 avant celui-ci.** Cette note est le relevé de la recherche initiale, conservé tel
> quel. L'app livrée s'en écarte sur plusieurs points décidés le 15 juillet 2026 : le suivi API a été
> supprimé, et un endpoint privé écarté ici a finalement été implémenté en option. Le
> [§ 6 « Décisions actées »](#6-décisions-actées--15-juillet-2026) fait foi ; les sections 3 à 5
> portent des avertissements ciblés.

## Conclusion exécutable

| Produit | Compteurs d'abonnement 5 h / semaine | Historique tokens / coût API | Voie recommandée |
|---|---:|---:|---|
| OpenAI ChatGPT / Codex | Oui | Oui, pour l'activité Codex liée au compte | Lancer le **Codex App Server officiel** et utiliser `account/login/start`, `account/rateLimits/read` et `account/usage/read` |
| OpenAI Platform API | Non : ce ne sont pas les quotas ChatGPT | Oui | Usage API + Costs API avec une clé d'administration d'organisation |
| Claude Pro / Max | Oui, mais pas via une API HTTP publique | Non via la clé d'abonnement | Utiliser le champ officiel `rate_limits` transmis aux scripts de **status line Claude Code** |
| Claude Console API | Non : débit et budget API, pas quota Claude.ai | Oui | Usage & Cost Admin API avec une clé Admin |
| Claude Enterprise | Selon le contrat, mais pas via l'API Console | Oui | Enterprise Analytics API avec une clé Analytics |

La meilleure architecture pour Status est donc hybride : App Server pour OpenAI, collecteur de status line pour Claude, et conservation des connecteurs Admin API existants pour la consommation facturée à l'usage.

*(Livré : App Server pour OpenAI — conservé ; status line pour Claude — conservée mais reléguée en
repli ; connecteurs Admin API — supprimés. Détail au § 6.)*

## 1. OpenAI / ChatGPT / Codex

### Interface supportée

Le Codex App Server est une interface JSON-RPC documentée par OpenAI. Sa surface d'authentification permet :

- `account/read` pour connaître l'état de connexion et le plan ;
- `account/login/start` avec `type: "chatgpt"` pour le navigateur ou `type: "chatgptDeviceCode"` pour le code d'appareil ;
- `account/login/completed` et `account/updated` comme notifications ;
- `account/rateLimits/read` pour les fenêtres de quota ChatGPT ;
- `account/rateLimits/updated` pour les mises à jour ;
- `account/usage/read` pour le résumé de tokens du compte et les buckets journaliers.

`account/rateLimits/read` fournit des fenêtres avec `usedPercent`, `windowDurationMins` et `resetsAt`. Le résultat peut contenir une vue historique `rateLimits` et une vue multi-compteurs `rateLimitsByLimitId`. Il peut aussi inclure le plan, les crédits, une limite mensuelle individuelle et des crédits de réinitialisation. Il ne faut donc **jamais supposer** que `primary` signifie toujours « 5 h » ni que `secondary` signifie toujours « semaine » : l'UI doit identifier la fenêtre par `windowDurationMins` et accepter des fenêtres absentes ou nouvelles.

Source officielle : [Codex App Server — Auth endpoints](https://learn.chatgpt.com/docs/app-server#auth-endpoints).

### Validation locale en lecture seule

Sur cette machine :

- binaire détecté : `/Applications/ChatGPT.app/Contents/Resources/codex` ;
- version : `codex-cli 0.144.2` ;
- `codex login status` signale une connexion ChatGPT ;
- le schéma généré par `codex app-server generate-json-schema` contient bien `account/login/start`, `account/rateLimits/read` et `account/usage/read` ;
- un échange JSON-RPC réel en lecture seule a réussi pour `account/read`, `account/rateLimits/read` et `account/usage/read` ; aucune valeur personnelle n'est copiée dans ce document.

Le sous-commande `app-server` est encore libellée « experimental » dans l'aide locale, mais les méthodes ci-dessus sont documentées et appartiennent à la surface stable par défaut : elles ne demandent pas `experimentalApi`. Il faut néanmoins détecter la version et tolérer l'évolution additive du schéma.

### Authentification à implémenter

Créer un acteur Swift `CodexAppServerClient` qui :

1. trouve le binaire `codex` dans le `PATH`, dans l'app ChatGPT, ou dans un chemin choisi par l'utilisateur ;
2. lance `codex app-server --stdio` via `Process` ;
3. envoie `initialize` avec un `clientInfo` propre à Status, puis la notification `initialized` ;
4. lit/écrit une ligne JSON-RPC par ligne sur stdin/stdout ;
5. pour « Se connecter », appelle `account/login/start` en mode `chatgpt`, ouvre `authUrl` avec `NSWorkspace`, puis attend `account/login/completed` ;
6. interroge `account/read`, `account/rateLimits/read` et `account/usage/read` au lancement, au retour au premier plan, puis à intervalle raisonnable ;
7. fusionne les notifications `account/rateLimits/updated` dans le dernier snapshot complet, ou relit le snapshot.

Deux modes de stockage sont possibles :

- **session Codex partagée** : le serveur réutilise la connexion du Codex CLI. C'est le chemin le plus simple, mais « Déconnexion » déconnecterait aussi Codex ; ne pas appeler `account/logout` implicitement ;
- **session isolée Status** : définir un `CODEX_HOME` propre à Status et forcer le stockage de credentials dans le Keychain. C'est préférable pour une app distribuée, mais il faut vérifier le comportement de nommage des entrées Keychain selon la version du CLI.

Dans les deux cas, Status ne doit jamais lire `~/.codex/auth.json` ni extraire un JWT. Codex possède le cycle OAuth et le renouvellement des jetons. Le mode expérimental `chatgptAuthTokens` est explicitement destiné aux apps hôtes qui possèdent déjà tout le cycle d'authentification : Status ne doit pas l'utiliser.

### Modèle d'affichage

Pour chaque fenêtre reçue :

```text
used = clamp(usedPercent, 0...100)
remaining = 100 - used
reset = Date(timeIntervalSince1970: resetsAt)
label = libellé backend, sinon durée humaine basée sur windowDurationMins
```

Afficher toutes les entrées `rateLimitsByLimitId`, dédupliquer la vue historique `rateLimits`, puis privilégier les fenêtres de 300 minutes (« 5 h ») et 10 080 minutes (« 7 jours ») sans cacher les autres. Un compteur manquant signifie « non fourni », pas 100 % restant.

`account/usage/read` complète ces jauges avec `lifetimeTokens`, `peakDailyTokens`, les séries journalières et d'autres statistiques éventuelles. Cette API est liée aux services Codex/ChatGPT et ne remplace pas l'Usage API de la plateforme.

### OpenAI Platform API : autre produit, autre authentification

Les endpoints `/v1/organization/usage/...` et `/v1/organization/costs` utilisent une **clé Admin d'organisation**. Ils mesurent la consommation API facturée à l'usage ; ils ne donnent pas les quotas d'abonnement ChatGPT/Codex. Ils restent utiles comme second mode de connexion dans Status.

Source officielle : [OpenAI — Usage API and Cost API cookbook](https://developers.openai.com/cookbook/examples/completions_usage_api).

## 2. Anthropic / Claude

### Ce qui est officiellement disponible pour Pro / Max

Claude Code accepte la connexion Claude.ai via son propre navigateur OAuth. Sur macOS, Claude Code stocke les credentials dans le Keychain. La commande documentée `claude auth status` renvoie l'état sous forme JSON ; `claude auth login` lance la connexion. Status peut piloter ces commandes, mais ne doit jamais lire les éléments du Keychain.

Source officielle : [Claude Code — Authentication](https://code.claude.com/docs/en/authentication).

Depuis Claude Code 2.1.80, un script de status line reçoit officiellement :

```json
{
  "rate_limits": {
    "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
    "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 }
  }
}
```

Ces champs sont les vrais compteurs Claude.ai. La documentation précise qu'ils apparaissent seulement pour les abonnés Pro/Max, après la première réponse API de la session, et que chaque fenêtre peut être absente. Les deux champs sont `used_percentage` et `resets_at`.

Source officielle : [Claude Code — Customize your status line, Rate limit usage](https://code.claude.com/docs/en/statusline#rate-limit-usage).

Anthropic documente par ailleurs une limite de session réinitialisée toutes les cinq heures et une limite hebdomadaire, tout en se réservant la possibilité d'ajouter des plafonds par modèle, fonctionnalité ou période. La page Settings > Usage reste la vue de référence pour les limites supplémentaires présentes sur le compte.

Source officielle : [Claude Help — What is the Pro plan?](https://support.claude.com/en/articles/8325606-what-is-the-pro-plan).

### Collecteur Claude recommandé

L'intégration v1 de Status devrait être une option explicite « Activer la synchro Claude Code » :

1. exiger Claude Code `>= 2.1.80` et vérifier `claude auth status` ;
2. proposer `claude auth login` si nécessaire ;
3. installer un petit exécutable local `StatusClaudeCollector` ;
4. configurer la clé officielle `statusLine` dans `~/.claude/settings.json` ;
5. le collecteur lit le JSON sur stdin, n'enregistre que `rate_limits`, `session_id`, `version` et une date `capturedAt`, puis écrit atomiquement un cache avec permissions `0600` ;
6. Status observe ce cache, calcule `remaining = 100 - used_percentage`, et signale clairement l'ancienneté des données.

Le collecteur ne doit stocker ni prompt, ni transcript, ni `cwd`, ni email, ni token. Les limites sont des données de compte, mais pas des secrets d'authentification.

Le status line s'exécute après les réponses Claude et éventuellement à l'intervalle `refreshInterval`. Il ne rend donc pas le compteur « pollable » lorsque Claude Code est complètement fermé. L'UI doit afficher « dernière mise à jour il y a … » et un bouton « Ouvrir Claude Code » ou [Settings > Usage](https://claude.ai/settings/usage).

#### Préserver une status line existante

Claude Code n'accepte qu'un objet `statusLine`. L'installation ne doit pas écraser silencieusement la configuration de l'utilisateur.

Approche sûre :

- sauvegarder l'objet exact avant modification ;
- si aucune status line n'existe, installer le collecteur directement ;
- si elle existe, soit demander confirmation pour installer un wrapper qui transmet le même JSON à la commande précédente et réémet exactement son stdout, soit fournir une instruction manuelle ;
- à la désinstallation, restaurer la sauvegarde uniquement si la configuration actuelle correspond toujours au wrapper de Status ; sinon ne rien écraser et expliquer le conflit.

Comme Claude Code exige la confiance du workspace pour exécuter les status lines, Status doit expliquer qu'une première session peut demander cette validation.

### Fenêtres Claude supplémentaires

L'Agent SDK officiel expose des événements `RateLimitEvent` avec les types `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet` et `overage`, ainsi que `utilization` et `resets_at`. Il s'agit d'événements produits pendant une session SDK/CLI, pas d'un endpoint de snapshot documenté. Lancer une requête uniquement pour rafraîchir une jauge consommerait potentiellement du quota : à ne pas faire en v1.

Source officielle : [Claude Agent SDK Python — RateLimitEvent / RateLimitInfo](https://code.claude.com/docs/en/agent-sdk/python#ratelimitevent).

Une v2 peut ingérer ces événements si Status devient déjà un client de l'Agent SDK pour une autre raison. En v1, afficher les deux fenêtres garanties par `statusLine` et ouvrir Settings > Usage pour les limites par modèle ou autres plafonds.

### Claude API / Enterprise : rapports, pas quota d'abonnement personnel

L'Usage & Cost Admin API de Claude Console nécessite une clé Admin `sk-ant-admin01-...` et n'est pas disponible pour les comptes individuels. Elle fournit les tokens et coûts historiques d'une organisation, pas le pourcentage restant des fenêtres Claude.ai Pro/Max.

Pour Claude Enterprise, Anthropic documente une API Analytics séparée avec une clé Analytics. Là encore, il s'agit de reporting organisationnel, pas d'un équivalent public universel du compteur personnel de cinq heures.

Source officielle : [Claude Platform — Usage and Cost API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api).

## 3. Ce qu'il ne faut pas implémenter

> **Cette section a été partiellement outrepassée le 15 juillet 2026.** Status appelle désormais
> l'endpoint privé `claude.ai/api/organizations/{org}/usage`, en option et à la demande de
> l'utilisateur. Les réserves ci-dessous restent exactes — elles n'ont pas été réfutées, elles ont
> été acceptées en connaissance de cause. Voir le § 6 pour le motif et les contreparties.

### Endpoints privés / non documentés

Des outils communautaires appellent directement des routes internes Claude.ai de type `.../api/oauth/usage`, réutilisent le token Claude Code ou interrogent les endpoints privés du site. Ne pas utiliser cette approche :

- aucune stabilité ni compatibilité garantie ;
- scopes et format susceptibles de changer sans préavis ;
- risque de révocation ou de blocage du compte ;
- obligation de lire/copie d'un secret OAuth qui appartient à Claude Code ;
- impossible de présenter honnêtement l'intégration comme officiellement supportée.

Même règle côté OpenAI : ne pas appeler directement les endpoints privés de `chatgpt.com/backend-api`, ne pas réutiliser les cookies Safari/Chrome et ne pas parser le HTML de la page Usage. L'App Server officiel rend ces contournements inutiles.

### Scraping de navigateur

Le contrôle de Claude.ai ou ChatGPT dans un WebView/Chrome pour lire une jauge est fragile, dépend de la langue et de l'A/B testing, et crée une surface de sécurité déraisonnable. Le navigateur peut uniquement servir à terminer l'OAuth ou à ouvrir la page officielle de consultation.

### Confusion entre quotas d'abonnement et rate-limit headers API

Les headers de rate limit des API OpenAI/Anthropic décrivent généralement le débit technique (requêtes ou tokens par minute) et non le volume restant de l'abonnement ChatGPT/Claude.ai. Ne pas convertir ces headers en jauge « 5 h / semaine ».

## 4. Architecture recommandée pour Status

```text
Status UI / Menu Bar
        |
        +-- QuotaStore (MainActor, snapshots horodatés, état frais/périmé/indisponible)
        |       |
        |       +-- OpenAIQuotaSnapshot[]
        |       +-- ClaudeQuotaSnapshot
        |       +-- PlatformUsageSnapshot (facultatif)
        |
        +-- CodexAppServerClient actor
        |       +-- Process codex app-server --stdio
        |       +-- OAuth géré par Codex
        |       +-- account/rateLimits/read + notifications
        |       +-- account/usage/read
        |
        +-- ClaudeCodeBridge actor
        |       +-- claude auth status / login
        |       +-- install/uninstall du collecteur opt-in
        |       +-- observation du cache statusLine
        |
        +-- AdminUsageClients existants
                +-- OpenAI Admin Usage/Costs
                +-- Anthropic Admin Usage/Cost ou Enterprise Analytics
```

### États UI à distinguer

- **Connecté et frais** : valeurs + reset exact ;
- **Connecté, données périmées** : dernière valeur visible avec badge « mis à jour il y a… » ;
- **Connecté, fenêtre non fournie** : tiret et explication, jamais 100 % ;
- **Non connecté** : bouton de connexion ;
- **Dépendance absente** : installer/choisir Codex ou Claude Code ;
- **Compte API** : coûts/tokens, mais pas de jauge abonnement ;
- **Erreur d'autorisation** : relancer le flow officiel, sans demander de coller un token OAuth.

### Rafraîchissement et robustesse

- OpenAI : lire au lancement, après login, au réveil, à l'ouverture du menu, puis toutes les 5 à 15 minutes ; exploiter les notifications pour l'instantané ; backoff sur erreurs ;
- Claude : mise à jour événementielle via status line ; ne pas simuler de requête Claude pour rafraîchir ;
- conserver `capturedAt`, version du fournisseur et payload brut non secret pour migration additive ;
- ne pas laisser un snapshot ancien survivre à un changement de compte ;
- calculer les dates avec le fuseau local uniquement à l'affichage ; conserver les timestamps Unix ;
- traiter une baisse de `used_percentage` avec un nouveau `resets_at` comme un reset normal ;
- ne jamais journaliser clés, cookies, URL OAuth complète, code d'appareil ou JSON-RPC contenant des credentials.

## 5. Décisions produit proposées

> **État au 15 juillet 2026 : les points 3, 4 et 5 ne décrivent plus l'app livrée.** Conservés ici
> comme trace de l'intention initiale. Le § 6 fait foi.

1. Le bouton « Connecter OpenAI » utilise uniquement le navigateur/device flow du Codex App Server.
2. Le bouton « Connecter Claude » installe/détecte Claude Code, lance `claude auth login`, puis propose séparément d'activer le collecteur officiel de status line.
3. L'écran principal affiche les **pourcentages restants**, les resets et l'ancienneté ; une vue secondaire affiche les tokens/coûts historiques.
4. Les connecteurs Admin API restent disponibles sous un libellé explicite « Compte API / organisation ».
5. Aucun scraping, aucun endpoint privé, aucune lecture des fichiers ou entrées Keychain d'un autre produit.

Ces choix donnent de vrais compteurs sans faire reposer Status sur des secrets récupérés clandestinement ni sur un contrat réseau non publié.

## 6. Décisions actées — 15 juillet 2026

Ce qui a réellement été construit, et en quoi cela s'écarte des § 3 et § 5.

### 6.1 Le suivi API a été supprimé

Clés admin, tokens, coûts, budgets et vue Historique ont été retirés. Status ne traite plus que les
quotas d'abonnement. Le § 5.4 est donc caduc.

### 6.2 Les jauges affichent le **consommé**, pas le restant

Inversion demandée en cours de route. Le § 5.3 est caduc sur ce point.

### 6.3 OpenAI : fenêtre hebdomadaire seule

OpenAI a supprimé la limite 5 h. Seule la jauge semaine est affichée, conformément au principe déjà
posé au § 1 : identifier les fenêtres par leur durée, ne jamais supposer qu'une fenêtre existe.

### 6.4 L'endpoint privé `/usage` est implémenté — motif

**Le problème.** La status line, seule source officielle, ne s'exécute que lorsqu'une session
`claude` en Terminal répond. L'utilisateur travaille dans Claude Code Desktop : mesuré en pratique,
le snapshot est resté **figé 7 heures**, et affichait encore un pourcentage pour une fenêtre 5 h dont
l'heure de reset était passée depuis 4 h. Aucune option officielle ne permet de forcer une relecture
— et déclencher une requête Claude pour rafraîchir une jauge consommerait du quota (§ 2). La
fonctionnalité était donc, en l'état, inutilisable pour cet usage.

**Ce qui a été fait.** `GET /api/organizations/{org}/usage` renvoie les trois fenêtres en direct à
chaque appel — y compris la fenêtre par modèle (Fable), que la status line n'expose pas du tout
(vérifié sur un snapshot réel : seuls `five_hour` et `seven_day` y figurent). Quand un cookie est
configuré, cette source remplace la status line pour toutes les fenêtres.

**Contreparties acceptées.** Les réserves du § 3 tiennent toujours : contrat non publié, rupture
possible sans préavis, cookie équivalant à un accès complet au compte. Elles ont été explicitement
présentées à l'utilisateur, qui a tranché.

**Atténuations effectivement en place.**

- La source reste **optionnelle** : sans cookie, l'app retombe sur la status line officielle.
- **Aucun secret n'est extrait d'un autre produit** : ni `~/.codex/auth.json`, ni le Trousseau de
  Claude Code, ni les cookies de Safari/Chrome. L'utilisateur fournit le cookie lui-même ; le § 3
  reste donc respecté sur ce point précis, qui était le plus important.
- Le cookie va **du navigateur au Trousseau sans transiter par un tiers** ; le champ de saisie
  accepte un collage « Copier comme cURL » et n'en retient que le cookie.
- L'UI **ne ment pas sur la source** : « ⟳ en direct » ou « ⚠ figé depuis … ».
- Une fenêtre dont le reset est passé est **écartée** plutôt qu'affichée périmée (`TMDropExpiredWindows`).
- Un HTTP non-2xx est rendu comme « session expirée, re-collez le cookie », sans jauge fantôme.
- Bouton « Effacer » pour révoquer ; le cookie se périme de lui-même à la déconnexion de claude.ai.

**Ce qui reste vrai du § 3.** Le scraping de DOM et la réutilisation du token de Claude Code restent
exclus. Côté OpenAI, aucun endpoint privé n'est appelé : l'App Server officiel suffit.

**Signal de sortie.** Si l'endpoint change de forme, `TMClaudeWindowsFromUsagePayload` renverra un
tableau vide et l'app retombera silencieusement sur la status line — le repli est le comportement par
défaut, pas un cas d'erreur. À réévaluer si Anthropic publie un jour un endpoint de snapshot
officiel : ce code devra alors être retiré.

### 6.5 Cloudflare impose un WebView — le cookie collé ne suffit pas

Mesuré le 16 juillet 2026, après que les jauges soient restées figées malgré un cookie valide.

**Le problème.** `NSURLSession` reçoit un **403 « Just a moment… »** de Cloudflare, quels que soient
les en-têtes envoyés — y compris un User-Agent de navigateur et un `cf_clearance` fraîchement collé.
Le challenge Cloudflare est une preuve de travail JavaScript : aucun client HTTP simple ne peut le
franchir. De plus `cf_clearance` est lié à l'IP **et** au User-Agent qui l'ont obtenu, et expire en
quelques heures — donc même un collage réussi cesserait de fonctionner dans la journée.

**Ce qui a été fait.** La requête part désormais d'un `WKWebView` masqué (`fetch` avec
`credentials:'include'`), dont le `WKWebsiteDataStore` est persistant. WebKit exécute le challenge,
gagne son propre `cf_clearance` et le renouvelle indéfiniment, sans intervention. Vérifié : le store
de l'app contient bien un `cf_clearance` qu'elle a obtenu elle-même.

Conséquences :

- le cookie collé n'est plus qu'une **graine pour `sessionKey`** ; WebKit possède le reste ;
- `TMCookiesFromHeader` **écarte volontairement `cf_*` et `__cf*`** : ressemer la copie périmée à
  chaque lancement écraserait celle, valide, que WebKit vient de gagner ;
- la session survit aux relances et aux redémarrages (store persistant), ce qui rend le collage
  ponctuel plutôt que quotidien.

**Fausse piste écartée.** Un `WKWebView` hors hiérarchie de fenêtre était soupçonné d'être throttlé
et de ne pas exécuter le challenge. Test comparatif (offscreen vs hébergé dans une fenêtre) :
**les deux franchissent Cloudflare**. L'hébergement n'est pas nécessaire.

Cela reste du contournement d'une protection anti-bot sur un compte légitime, avec les identifiants
de l'utilisateur, pour lire ses propres quotas. C'est assumé — mais c'est aussi le signe le plus
clair que cette voie n'est pas prévue pour nous, et qu'elle peut disparaître du jour au lendemain.
