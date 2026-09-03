# Status

Application macOS native qui affiche, depuis la barre des menus, les **quotas d'abonnement restants**
de ChatGPT et de Claude — les fenêtres glissantes (session 5 h, semaine) et non la consommation
facturée à l'API.

## Ce que l'app suit

| Fournisseur | Fenêtres affichées | Source |
|---|---|---|
| OpenAI / ChatGPT | Semaine | Codex app-server local (JSON-RPC, officiel) |
| Claude | 5 h, semaine, par modèle (Fable) | Endpoint `/usage` de claude.ai (non officiel) |

OpenAI n'expose plus de fenêtre 5 h : seule la jauge hebdomadaire est affichée.

Le suivi de la **consommation API facturée** (tokens, coûts, clés admin) a été entièrement retiré :
l'app ne traite plus que les quotas d'abonnement.

## Plusieurs comptes par fournisseur

Status suit jusqu'à **cinq comptes par fournisseur**, tous affichés en même temps. Chacun a son
identité, ses jauges, son historique et ses alertes.

**OpenAI.** Chaque compte a son propre `CODEX_HOME`, sous
`~/Library/Application Support/Status/codex/<compte>`. Les comptes sont donc étanches entre eux, et
se déconnecter dans Status **ne déconnecte pas** Codex ni l'app ChatGPT sur ce Mac. En contrepartie,
il faut se connecter une fois par compte depuis Status.

**Claude.** Chaque compte a son propre cookie de session claude.ai et sa propre session WebKit
isolée (un `WKWebsiteDataStore` par compte). Cette isolation n'est pas cosmétique : les cookies de
claude.ai portent les mêmes noms sur le même domaine, et un magasin partagé afficherait pour un
compte les chiffres d'un autre — des chiffres plausibles, silencieux et faux.

## La source Claude, et ce qu'elle coûte

Les quotas Claude sont lus sur `GET /api/organizations/{org}/usage`, avec la session du compte.
Cet endpoint est **non documenté**, peut casser sans préavis, et exige un cookie de session —
équivalent à un accès complet au compte. Le cookie est conservé dans le Trousseau de ce Mac, n'est
envoyé qu'à claude.ai, et se périme à la prochaine déconnexion.

C'est la seule source. Les versions précédentes retombaient sur la status line de Claude Code
quand aucun cookie n'était configuré ; cette voie a été retirée avec le multi-comptes, car elle
n'écrit qu'un seul `quota-snapshot.json`, accroché à l'installation locale de `claude` : elle ne
peut refléter qu'un compte, celui auquel la CLI est connectée. La conserver pour ce seul compte
aurait produit deux natures de comptes, deux modes de fraîcheur et deux jeux de bugs.

Conséquence à assumer : **un cookie expiré n'éteint pas seulement le direct, il éteint le compte.**
Celui-ci affiche alors son erreur et ses dernières fenêtres connues, et rien de plus. Le remède est
de recoller son cookie depuis Connexions.

Voir [`docs/quota-auth-research.md`](docs/quota-auth-research.md) § 6 pour l'historique de cet
arbitrage, et [`docs/superpowers/specs/2026-09-03-multi-comptes-design.md`](docs/superpowers/specs/2026-09-03-multi-comptes-design.md)
pour la conception du multi-comptes.

## Prérequis

- macOS 14 ou plus récent
- **OpenAI** : Codex CLI (fourni par l'app ChatGPT, ou `codex` dans le `PATH`)
- **Claude** : un cookie de session claude.ai par compte — aucune installation requise, la CLI
  `claude` n'est plus utilisée

## Signature stable (recommandé)

Sans identité de signature, chaque build est signé ad hoc : macOS voit une app différente à
chaque compilation et **révoque la permission Accessibilité** (verrou clavier) ainsi que le
lancement au démarrage. Une fois pour toutes :

```bash
./scripts/create-signing-identity.sh   # guide la création dans Trousseau d'accès
./scripts/package-app.sh               # détecte l'identité automatiquement
```

Après le premier build signé, ré-accordez l'Accessibilité une dernière fois : la signature
change d'ad-hoc à stable, donc macOS la redemande — puis plus jamais.

Le certificat apparaît comme non approuvé (`CSSMERR_TP_NOT_TRUSTED`) et **c'est normal** : une
racine auto-signée n'est pas approuvée par défaut. `codesign` l'accepte quand même, et c'est tout
ce qu'il faut — on ne cherche pas une chaîne vérifiable par des tiers (ce serait un Developer ID
Apple), seulement une empreinte stable d'un build à l'autre. Pour le vérifier :

```bash
codesign -d -r- outputs/Status.app   # l'exigence désignée doit être identique entre deux builds
```

## Demandes d'accès au Trousseau pendant le développement

Recompiler l'app provoque une demande d'accès au Trousseau à son lancement suivant, et
« Toujours autoriser » ne l'empêche pas de revenir. Ce n'est pas un défaut de configuration :

- le Trousseau classique attache l'autorisation à l'**empreinte du binaire**, pas au certificat ;
- chaque compilation change cette empreinte, donc l'autorisation accordée ne vaut que pour le
  binaire qu'on vient de remplacer.

Le Trousseau « protection des données », lui, indexe sur l'identité de signature et n'aurait pas
ce défaut — mais il exige l'entitlement `keychain-access-groups`, réservé aux identifiants
d'équipe Apple Developer. Mesuré : sans cet identifiant, `SecItemAdd` renvoie `-34018`
(entitlement manquant), et déclarer l'entitlement quand même fait **tuer le binaire au lancement**
par le système. Cette voie est fermée pour un certificat auto-signé.

En usage normal — sans recompilation — l'empreinte ne change pas et aucune demande n'apparaît.
La friction est donc limitée aux sessions de développement. Deux façons de la réduire :

- grouper les déploiements plutôt que réinstaller après chaque modification ;
- ou désactiver la source « direct » le temps de la session : sans cookie configuré, l'app ne
  touche jamais au Trousseau.

Le cookie est lu **une seule fois par lancement** et mémorisé (voir `usageCookie` dans
`Native/Status.m`) : le relire à chaque rafraîchissement multipliait les demandes, puisque le
survol de l'icône ouvre le popover, ce qui déclenche un rafraîchissement.

## Installer sur un autre Mac

L'app n'est pas notarisée (cela exigerait un compte Apple Developer payant) : Gatekeeper la
bloquera au premier lancement. Procédure :

1. Copiez `outputs/Status.zip` sur l'autre Mac (AirDrop, disque, etc.) et décompressez dans
   `/Applications`.
2. Premier lancement : macOS refuse d'ouvrir l'app. Deux options :
   - Réglages système › Confidentialité et sécurité › bouton **« Ouvrir quand même »** (apparaît
     dans les instants qui suivent la tentative), **ou**
   - retirer la quarantaine en une commande : `xattr -d com.apple.quarantine /Applications/Status.app`
3. Les permissions sont par machine : ré-accordez notifications et Accessibilité (verrou
   clavier), et refaites les connexions OpenAI/Claude — les identifiants ne voyagent pas avec
   l'app, c'est voulu (ils vivent dans le Trousseau).

Le prérequis (Codex CLI) s'applique sur chaque machine pour les quotas OpenAI, et chaque compte
Claude y demande son cookie ; le Moniteur système, lui, fonctionne sans rien.

## Construire et lancer

```bash
./scripts/package-app.sh
open outputs/Status.app
```

Le script compile `Native/Status.m` avec les Command Line Tools et assemble le bundle. Aucun Xcode
requis.

## Connexions

Depuis l'onglet **Connexions** :

- **Ajouter un compte** : présent sous chaque fournisseur, jusqu'à cinq comptes chacun.
- **OpenAI** → « Se connecter » : OAuth navigateur piloté par le Codex app-server du compte.
  Status ne voit jamais les jetons. « Déconnecter » n'efface que la session de ce compte, pas celle
  de Codex ni celle des autres comptes.
- **Claude** → « Coller le cookie » : accepte un collage « Copier comme cURL » et n'en extrait que
  le cookie, stocké dans le Trousseau sous une entrée propre au compte. L'organisation est ensuite
  résolue depuis ce cookie ; si le compte en couvre plusieurs, Status demande laquelle suivre.
- **Renommer** / **Retirer** : sur chaque compte. Retirer efface le secret ou le dossier de session
  du compte, ainsi que son historique de quotas.

Actualisation automatique toutes les **5 minutes**, plus au lancement.

## Comportement

- **Actualisation** : toutes les 5 min, au lancement, à l'ouverture du popover, et au réveil du Mac.
  En cas d'erreur répétée l'intervalle double jusqu'à 40 min (backoff), et repart à zéro dès qu'un
  clic manuel ou une réponse correcte survient.
- **Alertes** : une notification à 80 % puis à 95 % de chaque fenêtre, une seule fois par période de
  reset.
- **Historique** : un point toutes les 5 min dans `~/Library/Application Support/Status/`
  (~2000 points, soit une semaine), rendu en sparkline sous chaque jauge. Ne contient que des
  identifiants de fenêtre et des pourcentages.
- **Réglages** (onglet dédié) : lancement au démarrage, et choix de la jauge affichée dans la barre
  des menus. Les agrégats (« Claude sem. ») suivent le compte le plus contraint du fournisseur et
  changent donc de compte tout seuls ; un épinglage par compte est proposé dès qu'un fournisseur en
  a plusieurs. Le popover de la barre des menus, lui, ne propose que les agrégats : avec dix comptes
  possibles, une liste complète y serait illisible.

## Architecture

```
Native/StatusQuota.{h,m}   logique pure : parsing quotas, fenêtres, cookies, historique,
                           résolution de la métrique de la barre des menus.
                           Foundation seul, aucune UI — c'est la partie testée.
Native/StatusAccounts.{h,m}      registre des comptes : identités, ordre, plafond, migrations.
                                 Foundation seul, testé.
Native/StatusClaudeSession.{h,m} une session claude.ai par compte : WebView et magasin de
                                 données isolés, fetch /usage et /organizations
Native/StatusCodexServer.{h,m}   app-server Codex, un par compte (CODEX_HOME dédié)
Native/Status.m            shell AppKit + WebKit : fenêtres, popover, comptes, préférences
Resources/dashboard.html   fenêtre principale (WKWebView)
Resources/menubar.html     popover de la barre des menus (WKWebView)
Resources/StatusIcon.icns  icône du Dock ; l'icône de la barre des menus est dessinée
                           en template monochrome dans TMStatusIcon()
scripts/package-app.sh     compilation + bundle + signature
scripts/run-tests.sh       tests natifs + tests des surfaces web
scripts/create-signing-identity.sh  identité de signature locale (voir plus bas)
```

Le natif ne stocke dans le Trousseau que les cookies claude.ai, un par compte. Les sessions
OpenAI vivent dans les `CODEX_HOME` que Status gère lui-même : il ne lit jamais `~/.codex/auth.json`,
ni les entrées Trousseau d'un autre produit, ni les transcripts.

## Tests

```bash
./scripts/run-tests.sh
```

Couvre `StatusQuota` (coercition des payloads non documentés, extraction de cookie, parsing de la
réponse `/usage`, rejet des fenêtres expirées, historique par compte, résolution de la métrique de
la barre des menus), `StatusAccounts` (registre, plafond, migrations depuis le mono-compte) et les
surfaces web (rendu à zéro, un et cinq comptes).
`STATUS_SUPPORT_DIR` permet aux tests d'écrire ailleurs que dans les données réelles — redéfinir
`HOME` ne suffit pas, Foundation met le chemin en cache.

## Signature

Sans identité, `package-app.sh` signe en **ad-hoc** : l'empreinte change à chaque build, donc macOS
voit chaque build comme une app différente — d'où des demandes d'accès au Trousseau répétées et un
`SMAppService` (lancement au démarrage) qui peut refuser de s'enregistrer.

`./scripts/create-signing-identity.sh` explique comment créer une identité auto-signée locale
(opération manuelle unique, macOS ne permet pas de le faire sans interaction). Une fois créée, le
packaging la détecte seul. Pour distribuer l'app à d'autres machines il faudrait un certificat
Developer ID Apple, hors sujet ici.

## Historique du projet

`legacy-swiftui-prototype.tar.gz` archive un prototype SwiftUI antérieur (`Sources/`,
`Package.swift`, ses tests), jamais compilé par le packaging et resté sur l'architecture par clés
API supprimée depuis. Conservé faute de dépôt Git ; supprimable sans risque.
