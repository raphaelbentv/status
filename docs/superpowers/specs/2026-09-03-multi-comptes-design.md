# Plusieurs comptes par fournisseur

Status suit aujourd'hui **un** compte OpenAI et **un** compte Claude. Ce document décrit le passage
à N comptes par fournisseur, tous affichés simultanément.

## Décisions structurantes

| Question | Décision |
|---|---|
| Usage | Tous les comptes visibles en même temps, chacun avec ses jauges. Pas de notion de « compte actif ». |
| Source Claude | **Uniquement** le cookie de session claude.ai, pour tous les comptes. La status line est retirée. |
| Sessions OpenAI | Un `CODEX_HOME` isolé par compte, géré par Status — y compris le premier. |
| Barre des menus | Agrégats par fournisseur **et** épinglage d'un compte précis. |
| Plafond | 5 comptes par fournisseur. |

### Pourquoi le cookie partout côté Claude

La status line de Claude Code n'écrit qu'un seul `quota-snapshot.json`, accroché à
`~/.claude/settings.json` (voir `scripts/status-claude-bridge.py`, `_paths()`). Cette source reflète
le compte auquel la CLI locale est connectée : elle est intrinsèquement mono-compte et ne peut pas
être multipliée. Un deuxième compte Claude ne peut donc venir que de l'endpoint `/usage`.

Garder deux chemins — status line pour le compte de la CLI, cookie pour les autres — aurait produit
deux natures de comptes, deux modes de fraîcheur et deux jeux de bugs. On uniformise : un cookie par
compte.

**Ce que ça coûte.** Il n'y a plus de repli officiel. Un cookie expiré n'entraîne plus une jauge
figée mais une jauge éteinte : le compte affiche son erreur et ses dernières fenêtres connues, rien
de plus.

### Pourquoi des `CODEX_HOME` isolés, y compris pour le premier compte

`CODEX_HOME` isole bien l'authentification — vérifié : `CODEX_HOME=<vide> codex login status` répond
`Not logged in` pendant que le home réel répond `Logged in using ChatGPT`.

Isoler *tous* les comptes rend le modèle symétrique et supprime un effet de bord actuel : aujourd'hui
`account/logout` déconnecte la session Codex partagée, donc l'app ChatGPT elle-même — d'où l'alerte
« Cette action déconnectera aussi Codex sur ce Mac » (`Status.m`, `confirmLogoutOpenAI:`). Avec un
home par compte, cette alerte devient fausse et disparaît.

**Ce que ça coûte.** Une reconnexion, une fois, par compte, au premier lancement de la nouvelle
version.

## Modèle de données

Un compte :

| Champ | Rôle |
|---|---|
| `accountId` | UUID généré à l'ajout. Jamais dérivé de l'e-mail ni de l'org id : ceux-là changent, et une clé d'historique qui change casse les courbes. |
| `provider` | `openai` \| `claude` |
| `label` | Auto (e-mail OpenAI, nom d'organisation Claude), éditable. |
| `order` | Ordre d'affichage. |
| `orgId` | Claude uniquement, résolu depuis le cookie. |

Le reste du payload poussé vers le JS (`windows`, `capturedAt`, `stale`, `error`…) garde sa forme
actuelle : `quotaCard`, `TMDropExpiredWindows` et les tests de fenêtres n'ont pas à changer.

**Persistance.** Le registre (id, provider, label, order, orgId) va dans `NSUserDefaults` : rien de
secret. Les secrets restent au Trousseau, une entrée par compte —
`claude-session-cookie:<accountId>`. L'entrée existante `claude-session-cookie` est migrée vers le
premier compte Claude créé.

**Plafond : 5 comptes par fournisseur.** Chaque compte coûte un processus (OpenAI) ou une WebView
(Claude). Une limite explicite vaut mieux qu'une dégradation silencieuse.

## Sources

### OpenAI — un app-server par compte

`TMCodexAppServer` gagne une propriété `codexHome`, injectée via `task.environment[@"CODEX_HOME"]`,
pointant sur `~/Library/Application Support/Status/codex/<accountId>`. Un serveur par compte,
démarré paresseusement.

Trois conséquences dans `Status.m` :

- `openAILoginID`, unique aujourd'hui, devient une entrée par compte — sinon deux connexions
  concurrentes se volent leur `loginId` ;
- `handleCodexNotification:params:` reçoit l'`accountId` du serveur émetteur, capturé dans le
  `notificationHandler` de chaque instance ;
- l'alerte de déconnexion partagée disparaît.

Supprimer un compte : `account/logout` sur son serveur, arrêt du processus, suppression du dossier.

### Claude — une WebView par compte

Un cookie par compte, et **une `WKWebView` par compte sur un `WKWebsiteDataStore` distinct**. Ce
point n'est pas cosmétique : les cookies de claude.ai portent les mêmes noms sur le
même domaine, un store partagé ferait s'écraser les comptes entre eux. Le bug serait « le compte Pro
affiche les chiffres du compte Perso » — silencieux, plausible et faux.

**Écart assumé à la mise en œuvre.** Le magasin isolé est *persistant*
(`+[WKWebsiteDataStore dataStoreForIdentifier:]`, macOS 14+, identifié par l'accountId) et non
éphémère comme envisagé ici. Un magasin éphémère isolerait aussi bien, mais reperdrait à chaque
lancement la session et le `cf_clearance` que WebKit gagne en résolvant le défi Cloudflare — un
coût inutile, puisque l'isolation par identifiant procure les deux propriétés à la fois. Un
identifiant illisible retombe sur un magasin éphémère plutôt que sur le magasin par défaut : mieux
vaut reperdre une session que mélanger deux comptes.

L'org id ne vient plus de `claude auth status`. À l'enregistrement d'un cookie, Status appelle
`GET /api/organizations` dans la WebView du compte et récupère l'org id et le nom d'organisation,
qui devient le label par défaut. Si le cookie donne accès à plusieurs organisations, on demande
laquelle.

`directWasStale` et `directFailures` (alerte de péremption, chien de garde) passent de champs d'app
à champs de compte : un cookie mort ne doit pas déclencher le rechargement des WebViews des autres.

## Retrait de la status line

Partent :

- `scripts/status-claude-bridge.py`, `Tests/test_status_claude_bridge.py`, et la copie du script
  dans `scripts/package-app.sh` ;
- `TMClaudeWindowsFromSnapshot` et les 22 assertions qui la couvrent dans `Tests/native-tests.m` ;
- `TMPythonExecutablePath` — le bridge en était le seul utilisateur. Python 3 quitte les prérequis
  du README ;
- `TMClaudeExecutablePath` et les actions qui en dépendent : `installClaudeCLI`, `loginClaude`,
  `openClaudeTerminal`, `installClaudeTracking`, `uninstallClaudeTracking`. La CLI `claude` n'est
  plus une dépendance de l'app ;
- les champs de compte devenus vides de sens : `cliAvailable`, `authenticated`, `authChecking`,
  `trackingInstalled`, `trackingConfigured`, `snapshotPresent`, `subscriptionType`.

Restent `capturedAt`, `stale` et la viscosité (garder les dernières fenêtres connues quand un
sondage ne rapporte rien) : ce n'était pas une béquille de la status line, ça protège d'un affichage
vidé sur un échec réseau et ça vaut autant pour le cookie.

`README.md` perd sa section « Les deux sources Claude, et pourquoi » : l'arbitrage qu'elle
documentait n'existe plus.

## Agrégation

### Barre des menus

La grammaire de `menuBarMetric` s'étend sans casser l'existant :

- `lowest` — inchangé, la pire fenêtre tous comptes confondus ;
- `claude:weekly`, `claude:session`, `claude:weekly-fable`, `openai:weekly` — deviennent des
  **agrégats fournisseur** : le maximum sur les comptes du fournisseur, le compte responsable étant
  nommé dans l'infobulle ;
- `acct:<accountId>:<fenêtre>` — épinglage explicite.

Les préférences enregistrées restent valides et prennent le sens « agrégat » : aucune migration,
aucun réglage perdu.

Un compte épinglé puis supprimé retombe sur l'agrégat de son fournisseur, jamais sur un affichage
vide.

### Historique

Les clés passent de `claude:seven_day` à `claude:<accountId>:seven_day` (`TMAppendHistory`). Les
points existants sont réécrits une fois, au premier lancement, vers l'`accountId` du premier compte
migré de chaque fournisseur : les courbes ne repartent pas de zéro. La migration est idempotente.

L'UUID reste interne : le libellé est résolu à l'affichage et à l'export CSV — sinon renommer un
compte réécrirait l'historique.

Supprimer un compte purge ses clés d'historique, sans quoi des séries orphelines s'accumulent dans
le graphe sans pouvoir être nommées.

### Notifications

`TMQuotaNotificationDecisions` prend déjà `pairs` sous forme `[[provider, fenêtres]]` : on y passe
`<provider>#<accountId>`, et les clés d'état suivent. Pas de migration — les clés incluent
`resetsAt` et sont purgées par période. Au pire une notification en double au premier changement de
période.

### Cache de comptes

`TMSaveAccountsCache` passe du dictionnaire `{openai, claude}` à une liste. Un cache à l'ancien
format est lu une fois pour la migration, puis remplacé.

### Angle mort assumé : le coût équivalent API

`StatusCost` balaie les logs locaux de `claude` et `codex`. Ces logs ne portent pas d'identité de
compte : le chiffre reste à l'échelle de la machine, affiché une fois par fournisseur et non par
compte, étiqueté « tous comptes ». Le rattacher à un compte serait de l'invention.

## Interface

### Dashboard

- `PROVIDERS` et `overview()` : deux colonnes fournisseur, chacune empilant un bloc par compte
  titré par son label. Le héros nomme le compte, pas seulement le fournisseur ;
- `connectionsView()` : chaque fournisseur liste ses comptes et gagne un bouton **Ajouter un
  compte** ;
- `SERIES` du graphe hebdo : les clés en dur deviennent une série par compte et par fenêtre, couleur
  dérivée du fournisseur et nuancée par rang.

**Ajouter un compte.** OpenAI : création de l'`accountId` et de son `CODEX_HOME`, démarrage du
serveur, `account/login/start`, navigateur ; le label se remplit à la première lecture de l'e-mail.
Claude : la feuille de collage cURL existante devient générique, puis résolution de l'organisation,
puis label.

**Supprimer un compte.** Feuille de confirmation, destruction de l'entrée Trousseau ou du
`CODEX_HOME`, purge des clés d'historique.

### Menubar

Le popover affiche un bloc par compte. Son sélecteur de jauge garde **uniquement** les agrégats,
`lowest` et les métriques système : avec dix comptes possibles, une liste complète dans un popover
de barre des menus serait inutilisable. L'épinglage par compte se fait dans Réglages.

## Extractions

`Status.m` fait 2676 lignes et cette feature l'alourdit franchement. Dans l'esprit de l'extraction
de `StatusCodexServer` :

- `Native/StatusAccounts.{h,m}` — le registre des comptes : chargement, écriture, ajout,
  suppression, renommage, migrations. Logique quasi pure, testable ;
- la résolution de `menuBarMetric`, aujourd'hui inline dans `Status.m`, remonte dans `StatusQuota`
  comme fonction pure. C'est la logique qui se complique le plus (agrégats, épinglages, comptes
  disparus) et la seule partie de la chaîne quota aujourd'hui non couverte par les tests.

## Tests

`Tests/native-tests.m` — retrait des assertions de `TMClaudeWindowsFromSnapshot`, ajout sur les
quatre points où un bug serait silencieux :

- `TMAppendHistory` avec deux comptes du même fournisseur. La régression exacte a déjà été vue côté
  OpenAI : sans `windowId`, « les deux limites écrasaient la même clé, la moitié de la donnée
  disparaissait en silence » (`StatusQuota.m`) ;
- migration des clés d'historique : ancien format → premier compte, et idempotence ;
- migration du cache de comptes, dictionnaire → liste ;
- résolution de `menuBarMetric` : agrégat, épinglage, et compte épinglé puis supprimé.

`Tests/web-tests.mjs` — rendu à zéro compte, un compte, cinq comptes ; fournisseur connecté sans
fenêtre.

`Tests/test_status_claude_bridge.py` — supprimé avec le bridge.

**Vérification à l'exécution.** La collision de cookies entre WebViews ne se voit dans aucun test
unitaire : elle produit des chiffres plausibles mais faux. Il faut une exécution réelle avec deux
comptes Claude distincts, en vérifiant que les deux blocs affichent des pourcentages différents et
cohérents avec claude.ai. Côté OpenAI : deux `CODEX_HOME`, deux e-mails distincts affichés, et
`codex login status` dans le home réel toujours `Logged in` après un logout depuis Status.
