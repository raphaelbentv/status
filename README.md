# Status

Application macOS native qui affiche, depuis la barre des menus, les **quotas d'abonnement restants**
de ChatGPT et de Claude — les fenêtres glissantes (session 5 h, semaine) et non la consommation
facturée à l'API.

## Ce que l'app suit

| Fournisseur | Fenêtres affichées | Source |
|---|---|---|
| OpenAI / ChatGPT | Semaine | Codex app-server local (JSON-RPC, officiel) |
| Claude | 5 h, semaine | Status line officielle de Claude Code ; anciens comptes web conservés |

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

**Claude.** Les nouvelles connexions passent par Claude Code officiel. Chaque compte possède un
`CLAUDE_CONFIG_DIR` privé et sa propre status line. Status reçoit uniquement les quotas 5 h / 7 jours
et leur horodatage ; il ne collecte aucun jeton OAuth. Les comptes web existants restent disponibles
jusqu’au clic sur **Passer à Claude Code**.

## La source Claude et sa fraîcheur

Le bridge consomme les champs officiels `rate_limits` de la status line. Il ne lance aucun prompt.
Les mesures apparaissent après une réponse de Claude Code dans le profil du compte ; sans activité,
elles ne se renouvellent pas. **Actualiser** relit les mesures et l’état de connexion, sans consommer
de quota. Les fenêtres expirées sont masquées et les mesures de plus de 30 minutes signalées.

Les anciennes connexions par cookie utilisent toujours l’endpoint privé de claude.ai, sans changement
automatique de leurs sessions. Le bouton **Passer à Claude Code** prépare le nouveau profil et ouvre
la connexion officielle dans Terminal. Les détails et limites sont dans
[le guide du bridge](docs/claude-statusline-bridge.md).

## Prérequis

- macOS 14 ou plus récent
- **OpenAI** : Codex CLI (fourni par l'app ChatGPT, ou `codex` dans le `PATH`)
- **Claude** : Claude Code natif installé (`~/.local/bin`, `/opt/homebrew/bin` ou `/usr/local/bin`), une connexion par profil

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
ce qu’il faut pour stabiliser certains usages locaux. Cela ne suffit pas pour le service
privilégié capot fermé, dont le lancement est refusé sur le Mac testé. Pour le vérifier :

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
Claude y ouvre la connexion officielle dans Terminal ; le Moniteur système, lui, fonctionne sans rien.

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
- **Claude** → « Se connecter avec Claude Code » : connexion officielle puis session interactive.
  « Ouvrir Claude Code » réutilise ce profil. « Déconnecter » appelle le logout officiel du profil.
  Les comptes web existants proposent « Passer à Claude Code » ; leurs cookies ne sont pas importés.
  Pour Claude Code, « Retirer » arrête le suivi et retire l’historique de quotas, mais conserve le
  profil local : déconnectez et fermez ses terminaux auparavant pour terminer aussi sa session.
- **Renommer** / **Retirer** : sur chaque compte. Retirer efface le secret ou le dossier de session
  du compte, ainsi que son historique de quotas.

Actualisation automatique des quotas toutes les **minutes** par défaut (réglable de 30 secondes à 5 minutes), plus au lancement.

Sous les jauges de chaque compte, **Crédits supplémentaires** affiche le solde OpenAI en crédits,
ou le portefeuille Claude dans sa devise, avec la dépense et le plafond mensuels quand disponibles.
Ces montants suivent les relevés de quotas. Une donnée absente reste indisponible ; les crédits de
réinitialisation manuelle restent affichés séparément.

## Comportement

- **Actualisation** : toutes les minutes par défaut, au lancement, à l'ouverture du popover, et au réveil du Mac.
  En cas d'erreur répétée, seul le compte concerné ralentit jusqu'à 40 min (backoff) ; les autres
  continuent normalement. Un clic manuel ou une réponse correcte annule sa pause.
- **Alertes** : une notification au seuil configuré (80 % par défaut), puis à 95 % du quota
  hebdomadaire global, une seule fois par niveau et par période. Les renouvellements suivent ce
  même périmètre : aucun seuil ni renouvellement des modèles spécifiques, fenêtres 5 h ou dépassements.
- **Historique** : un point toutes les 5 min dans `~/Library/Application Support/Status/`
  (~2000 points, soit une semaine), rendu en sparkline sous chaque jauge. Ne contient que des
  identifiants de fenêtre et des pourcentages.
- **Réglages** (onglet dédié) : lancement au démarrage, et choix de la jauge affichée dans la barre
  des menus. Les agrégats (« Claude sem. ») suivent le compte le plus contraint du fournisseur et
  changent donc de compte tout seuls ; un épinglage par compte est proposé dès qu'un fournisseur en
  a plusieurs. Les réglages sont regroupés en Apparence, Quotas, Alertes, Système et Raccourcis.
- **Popup** : sélecteur de compte indépendant pour chaque fournisseur, jauges de consommation et
  pourcentage restant pour chaque fenêtre active, avec date de renouvellement. Ce choix ne modifie
  pas la jauge épinglée dans la barre des menus. Les outils du Mac sont repliables.
- **Vue d’ensemble** : disponibilité selon les mesures récentes, compte le plus disponible et
  prochain renouvellement hebdomadaire par fournisseur ; tri par disponibilité, renouvellement ou nom.
  Les comptes sans mesure récente restent à actualiser ; leurs quotas ne sont jamais additionnés.
- **Lisibilité** : connexions compactes, coûts API explicitement estimatifs et partiels lorsque des
  tokens ne sont pas tarifés, espace disque libre/total et accès aux réglages de stockage. Un bandeau
  signale les notifications refusées par macOS. Fable n’est proposé que si une fenêtre est reçue.

## Architecture

```
Native/StatusQuota.{h,m}   logique pure : parsing quotas, fenêtres, cookies, historique,
                           résolution de la métrique de la barre des menus.
                           Foundation seul, aucune UI — c'est la partie testée.
Native/StatusAccounts.{h,m}      registre des comptes : identités, ordre, plafond, migrations.
                                 Foundation seul, testé.
Native/StatusClaudeBridge.{h,m}  profils CLI, lecture auth status, compteurs, fraîcheur, historique
Native/StatusClaudeCollector.m   exécutable de status line, aucune lecture de credentials
Native/StatusClaudeSession.{h,m} une session claude.ai par compte : WebView et magasin de
                                 données isolés, fetch /usage et /organizations
Native/StatusCodexServer.{h,m}   app-server Codex, un par compte (CODEX_HOME dédié)
Native/Status.m            shell AppKit + WebKit : fenêtres, popover, comptes, préférences
Resources/dashboard.html   fenêtre principale (WKWebView)
Resources/menubar.html     popover de la barre des menus (WKWebView)
Resources/StatusIcon.icns  icône du Dock (sablier), générée depuis StatusIcon.svg avec
                           rsvg-convert + iconutil ; l'icône de la barre des menus est
                           dessinée en template monochrome dans TMStatusIcon()
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

### Tarif Astra

GPT-6 Astra est inclus dans l’équivalent API, y compris les logs déjà enregistrés : le cache
est recalculé à la mise à jour. Tarif standard vérifié le 9 septembre 2026 : 10 $ en entrée,
1 $ en lecture de cache et 50 $ en sortie par million de tokens. Les majorations Fast et contexte
long ne sont pas incluses dans cette estimation. [Source officielle](https://developers.openai.com/api/docs/models/gpt-6-astra).

Chaque compte affiche la dernière réinitialisation hebdomadaire **observée**, avec date et heure
locales, dans le tableau de bord, les connexions et le popup. Cette date de détection est persistée
indépendamment de l’activation des notifications. Sans observation antérieure, « Non observée »
est affiché ; aucune date n’est extrapolée depuis la prochaine échéance.

## Mode capot fermé à durée définie (0.8.5)

Dans **Réglages → Système → Continuer capot fermé**, autoriser le service macOS,
puis choisir une durée de **1 à 240 minutes** et cliquer sur **Démarrer**.
Le tableau de bord et le popup affichent le temps restant. Le mode température et
la dépendance aux sondes SMC ont été retirés. L’autorisation ne démarre aucune session.

Le service impose la faible consommation sur batterie et secteur, puis restaure les
réglages d’origine à l’échéance ou avec **Arrêter maintenant**. Il vérifie les écritures
`pmset` avant de confirmer l’activation. `disablesleep` affecte aussi la veille manuelle ;
ce réglage n’est pas une API publique garantie et nécessite un test physique sur le Mac.

Toutes les cinq secondes, arrêt anticipé à 30 % de batterie, si la charge devient
illisible, si macOS signale une pression thermique (dès « fair »), si les réglages
d’énergie changent ou si Status ne répond plus depuis vingt secondes. Il n’y a plus
aucun seuil en degrés. Conserver une ventilation suffisante : ces arrêts ne garantissent
pas un fonctionnement sûr dans un sac fermé.

Un journal root privé dans `/var/db/com.raphael.status.lid/` précède les modifications.
Le service restaure ses changements après une interruption sans reprendre la session ;
un échec de restauration conserve le journal et déclenche des réessais. Il préserve
les changements externes identifiables. Arrêter et restaurer avant une mise à jour.

Les échanges XPC vérifient le certificat et l’identifiant exact du pair dans les deux
sens. Le helper n’accepte aucune commande ni aucun chemin fournis par le client.
Les tests simulent l’échéance, la batterie, le signal thermique macOS, la perte de
contact, les erreurs d’écriture et la récupération sans modifier les réglages réels.
Le helper accepte `--diagnose` pour une lecture seule.

## Estimation des renouvellements (0.7.0)

Chaque compte affiche une prévision compacte sous ses jauges dans le tableau de bord uniquement.
Le popup et les connexions ne montrent pas de prédiction. La fréquence observée est accessible
dans l’infobulle de la prévision du quota **hebdomadaire global**. Les observations sont persistées
indépendamment des notifications : 64 dates maximum, sur 180 jours, purgées au retrait du compte.
La dernière date connue des versions précédentes est conservée ; aucun passé n'est reconstitué
à partir des échéances annoncées. Les modèles spécifiques et les fenêtres 5 h sont exclus.

Après trois détections, Status calcule la médiane des intervalles et une plage allant du plus
court au plus long intervalle, élargie de 15 % de la médiane (au moins un jour). Cette plage est
une extrapolation descriptive, pas un intervalle probabiliste calibré. Confiance faible, puis
modérée à partir de cinq intervalles dont l'étendue ne dépasse pas 25 % de la médiane. Si
l'étendue dépasse la médiane ou si un intervalle est inférieur à un jour, aucune date n'est
proposée. Une plage dépassée n'est jamais repoussée automatiquement d'une semaine.

Le détecteur conserve les baisses corroborantes existantes. Il enregistre aussi une recharge
à échéance inchangée au moins 24 h après la précédente si le compteur était remonté à 25 %
ou plus sur plusieurs relevés, avec au moins 30 min depuis sa confirmation haute, puis tombe
à 5 % ou moins. La déduplication des notifications par période reste inchangée. Ces dates sont
celles de **détection** : une longue absence, un usage faible, une correction du compteur ou
une recharge manuelle peuvent affecter les statistiques. Ce n'est pas un calendrier garanti.

### Références publiques prédictives (0.7.3)

Avant trois observations personnelles, un instantané vérifié le 11/09/2026 alimente la
prévision : dernier reset public + intervalle moyen, avec confiance faible et libellé
« repère public ». Il concerne une possibilité de reset exceptionnel, pas une échéance
contractuelle du compte. Aucun intervalle de confiance n'est inventé.

- [Claude Reset Tracker](https://claude-resets.com/) : 11 événements depuis avril ; moyenne
  14,1 jours, maximum 50,7 jours ; dernier reset le 04/09 à 20:08:45 UTC, Max uniquement.
- [Codex Reset](https://codex-reset.com/) : 8 derniers intervalles ; moyenne 4,8 jours,
  maximum 11 jours ; dernier reset le 08/09 à 04:05:53 UTC. La médiane sur 30 jours
  (5,5 jours) est affichée en contexte mais n'est pas mélangée à cette moyenne.
- La médiane SaveMeTibo de 2,2 jours n'alimente pas le calcul car son archive inclut
  des crédits de reset offerts.

L'historique personnel prend la priorité dès trois observations, y compris lorsqu'il est
irrégulier ou sa prévision dépassée. Aucun événement public n'est inséré dans l'historique
ou les notifications. Un repère dépassé n'est pas reporté ; l'instantané expire après
30 jours et affiche « à actualiser ». Il est embarqué, sans synchronisation automatique.

## Icônes par fournisseur (0.8.1)

La barre affiche deux icônes côte à côte, sans texte : OpenAI à gauche, Claude à droite.
Réglages → Apparence → Icônes des fournisseurs permet de choisir indépendamment parmi
six dessins de jauge : Double anneau, Capsules, Double arc, Anneau épais,
Réservoir et 5 segments. Le choix reste indépendant pour chaque fournisseur.

Depuis 0.8.7, les deux jauges n’ont plus de pictogramme adjacent : OpenAI est bleu
à gauche, Claude orange à droite. La partie pleine représente toujours le **quota
restant** du compte choisi dans le popup. Le choix est mémorisé indépendamment
pour OpenAI et Claude (0.8.8) et met à jour la jauge immédiatement. Le mode « tous »
suit le compte le plus contraint du fournisseur. Les widgets de
quota secondaires utilisent aussi le restant pour leur texte, leur remplissage et
leur historique. Un tiret distingue une mesure absente d’un quota épuisé.
Les dessins fixes (Orbite, Éventail, S) ont été retirés ; une ancienne sélection
correspondante utilise désormais l’Anneau épais. L’aperçu montre un restant fictif de 72 %.

## Installation du service capot fermé

La signature locale de Status est utilisable pour l’application mais le service embarqué
`SMAppService` a été refusé par macOS (-423 / EX_CONFIG) sur le Mac testé. Un redémarrage
seul ne résout pas ce refus.

Pour les builds locaux, **Autoriser le service macOS** ouvre désormais
`StatusLidService.pkg` dans l’installateur système. L’utilisateur saisit son autorisation
dans macOS ; Status ne lit aucun mot de passe. Le paquet installe uniquement :

- `/Library/PrivilegedHelperTools/com.raphael.status.lid-helper`
- `/Library/LaunchDaemons/com.raphael.status.lid-service.plist` (label et nom Mach
  `com.raphael.status.lid-service`)

Ces fichiers appartiennent à root et ne sont pas modifiables par les autres utilisateurs.
Le label et le nom Mach diffèrent volontairement de l’enregistrement SMAppService
(`com.raphael.status.lid-helper`) : smd recrée ce dernier après un `bootout`, et le
partage du label faisait échouer le `bootstrap` du paquet (« Bootstrap failed: 5 »).
Status désenregistre aussi au lancement tout SMAppService non signé par Apple, qui
ne peut jamais démarrer et que launchd relancerait en boucle. Le paquet retire
l’ancien `com.raphael.status.lid-helper.plist` d’une installation précédente.
L’installation refuse une session active ou une restauration en attente, démarre le
service avec `launchctl bootstrap system`, et vérifie la présence de son processus.
Elle n’active jamais le maintien éveillé. L’application exige ensuite une réponse XPC
avec la version du protocole attendue avant de permettre un démarrage.
Une signature ad hoc reste refusée : app et helper doivent partager un certificat stable.
Aucun réglage global de confiance, Gatekeeper ou SIP n’est modifié.

Les builds signés par Apple conservent la voie `SMAppService`. Pour cette voie, utiliser
la même identité Apple Development ou Developer ID Application pour les deux binaires :

```sh
STATUS_SIGN_IDENTITY='nom exact du certificat Apple' ./scripts/install-app.sh
/Applications/Status.app/Contents/MacOS/Status --repair-lid-registration
```

Un build et l’installation ne prouvent pas le comportement capot fermé : vérifier la
réponse XPC, un essai court avec restauration des profils, puis la fermeture physique.

Références : [installation classique avec Program et launchctl](https://developer.apple.com/forums/thread/771162),
[identité Apple pour SMAppService](https://developer.apple.com/forums/thread/799910).

### Ventilateurs : Auto Apple et Boost temporaire

Dans Réglages → Système et dans « Outils du Mac » du popup : boost de tous les
ventilateurs à leur maximum SMC pendant 1 à 60 minutes, puis retour à Auto Apple.
Le service macOS doit être mis à jour avec l’installateur fourni dans Status.
Aucun démarrage n’a lieu pendant l’installation. Les vitesses réelles sont affichées ;
le boost reste en vérification pendant la montée en vitesse et est annulé si la
vitesse n’est pas confirmée sous 20 secondes.

Le service indépendant restaure le mode automatique à l’expiration, à la rupture
XPC, après 20 secondes sans heartbeat, à son arrêt et après son redémarrage grâce
à un journal privé. Toute restauration non confirmée est signalée et réessayée.
Un outil externe déjà en mode manuel bloque le démarrage. Aucune clé SMC arbitraire
ni vitesse inférieure au maximum n’est exposée par le service. Le contrôle peut
être refusé par macOS, notamment sur certains M3/M4 : Status n’utilise pas le
contournement diagnostic `Ftst` et ne désactive pas `thermalmonitord`.

Tests simulés : durée, montée en vitesse, vitesse réelle, expiration, perte de contact,
écriture partielle, restauration en échec, récupération au redémarrage et reprise
par macOS. Ces tests ne constituent pas une validation des écritures sur un Mac réel.
