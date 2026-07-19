# Status

Application macOS native qui affiche, depuis la barre des menus, les **quotas d'abonnement restants**
de ChatGPT et de Claude — les fenêtres glissantes (session 5 h, semaine) et non la consommation
facturée à l'API.

## Ce que l'app suit

| Fournisseur | Fenêtres affichées | Source |
|---|---|---|
| OpenAI / ChatGPT | Semaine | Codex app-server local (JSON-RPC, officiel) |
| Claude | 5 h, semaine, par modèle (Fable) | Status line Claude Code (officiel) **ou** endpoint `/usage` claude.ai (non officiel, en direct) |

OpenAI n'expose plus de fenêtre 5 h : seule la jauge hebdomadaire est affichée.

Le suivi de la **consommation API facturée** (tokens, coûts, clés admin) a été entièrement retiré :
l'app ne traite plus que les quotas d'abonnement.

## Les deux sources Claude, et pourquoi

C'est le point le moins évident du projet.

**Status line (par défaut, officielle).** Claude Code transmet un objet `rate_limits` aux scripts de
status line. C'est documenté et stable, mais le script **ne s'exécute que lorsqu'une session `claude`
en Terminal répond**. Si vous travaillez surtout dans Claude Code Desktop, les jauges se figent —
observé en pratique : 7 h sans mise à jour. L'app ne peut pas forcer ce rafraîchissement, et
déclencher une requête Claude uniquement pour rafraîchir une jauge consommerait du quota.

**Endpoint `/usage` (optionnel, non officiel).** `GET /api/organizations/{org}/usage` sur claude.ai
renvoie les trois fenêtres en direct à chaque appel. Il est **non documenté**, peut casser sans
préavis, et exige un cookie de session — équivalent à un accès complet au compte.

Quand le cookie est configuré, cette source remplace la status line pour toutes les fenêtres et
l'app affiche « ⟳ en direct ». Sinon elle retombe sur la status line et signale l'ancienneté
(« ⚠ figé depuis … »). Une fenêtre dont l'heure de reset est passée est écartée plutôt qu'affichée
avec un pourcentage périmé.

Voir [`docs/quota-auth-research.md`](docs/quota-auth-research.md) § 6 pour le détail de cet arbitrage.

## Prérequis

- macOS 14 ou plus récent
- **OpenAI** : Codex CLI (fourni par l'app ChatGPT, ou `codex` dans le `PATH`)
- **Claude** : Claude Code (`claude`), détecté via le `PATH` d'un shell de login — les installations
  par nvm/volta/asdf sont donc trouvées
- **Python 3** : requis par le collecteur de status line

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

Les prérequis (Codex CLI, Claude Code, Python 3) s'appliquent sur chaque machine pour les
quotas ; le Moniteur système, lui, fonctionne sans rien.

## Construire et lancer

```bash
./scripts/package-app.sh
open outputs/Status.app
```

Le script compile `Native/Status.m` avec les Command Line Tools et assemble le bundle. Aucun Xcode
requis.

## Connexions

Depuis l'onglet **Connexions** :

- **OpenAI** → « Se connecter » : OAuth navigateur piloté par le Codex app-server. Status ne voit
  jamais les jetons ; la session est celle de Codex (« Déconnecter » déconnecte donc aussi Codex).
- **Claude** → « Connecter » : lance `claude auth login` dans Terminal.
- **Claude** → « Activer le suivi » : installe le collecteur de status line. Une status line
  existante est sauvegardée et restaurée à la désactivation ; elle n'est jamais écrasée en silence.
- **Claude** → « direct » : active la source en direct. Accepte un collage « Copier comme cURL » et
  n'en extrait que le cookie, stocké dans le Trousseau. Bouton « Effacer » pour révoquer.

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
  des menus (la plus élevée / 5 h / semaine).

## Architecture

```
Native/StatusQuota.{h,m}   logique pure : parsing quotas, fenêtres, cookies, historique.
                           Foundation seul, aucune UI — c'est la partie testée.
Native/Status.m            shell AppKit + WebKit : fenêtres, popover, Codex, réseau, préférences
Resources/dashboard.html   fenêtre principale (WKWebView)
Resources/menubar.html     popover de la barre des menus (WKWebView)
Resources/StatusIcon.icns  icône du Dock ; l'icône de la barre des menus est dessinée
                           en template monochrome dans TMStatusIcon()
scripts/status-claude-bridge.py  collecteur de status line, opt-in
scripts/package-app.sh     compilation + bundle + signature
scripts/run-tests.sh       tests natifs + tests du bridge
scripts/create-signing-identity.sh  identité de signature locale (voir plus bas)
```

Le natif ne stocke que le cookie claude.ai dans le Trousseau. Il ne lit jamais
`~/.codex/auth.json`, ni les entrées Trousseau d'un autre produit, ni les transcripts.

## Tests

```bash
./scripts/run-tests.sh
```

Couvre `StatusQuota` (coercition des payloads non documentés, extraction de cookie, parsing des
deux sources Claude, rejet des fenêtres expirées, historique) et le collecteur Python.
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
