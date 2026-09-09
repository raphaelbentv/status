# Suivi automatique Claude via le web

Dans Connexions, **Activer le suivi automatique** ouvre une fenêtre Claude isolée pour ce compte.
Connectez-vous, puis cliquez sur **Valider la connexion**. Status vérifie l’organisation du profil
précédent et reçoit un quota hebdomadaire avant de basculer. Un mauvais compte, une annulation ou
une erreur conserve le suivi précédent. Si un nouveau compte possède plusieurs organisations, un
choix explicite est demandé.

La session reste dans le WKWebsiteDataStore propre à l’UUID du compte. Aucun cookie n’est copié
ni aucun identifiant Claude Code extrait. Les relevés utilisent la session web toutes les cinq
minutes en fonctionnement normal, à l’ouverture du popup et au réveil ; le backoff existant ralentit
les requêtes en cas d’erreur. La session doit être reconnectée si Claude l’expire. Ces endpoints web
ne constituent pas une API publique garantie ; les erreurs et mesures anciennes restent visibles.

La fenêtre web doit être validée pour chaque compte. La connexion initiale exige une intervention
humaine. Les notifications restent limitées aux seuils et renouvellements de la semaine globale.

# Suivi Claude Code dans Status

## Parcours

1. Installer Claude Code natif. Sur ce Mac : Homebrew `claude-code@latest` 2.1.266.
2. Dans Connexions, cliquer sur **Se connecter avec Claude Code** ou **Passer à Claude Code**.
3. Terminal lance `claude auth login` avec le profil isolé. Terminer la connexion officielle.
4. Le terminal ouvre Claude Code. Les compteurs arrivent après la première réponse dans ce profil.
5. **Ouvrir Claude Code** réutilise le même profil. **Actualiser** relit les mesures, sans prompt.

## Isolation et collecte

Chaque UUID Status possède `~/Library/Application Support/Status/ClaudeCode/<UUID>/` (0700).
`settings.json` configure le collecteur natif livré dans le bundle. `bridge.json` porte une génération
aléatoire, renouvelée à chaque reconnexion. Les fichiers JSON sont en 0600. Un collecteur d’une ancienne
génération ou d’un profil retiré ne peut plus alimenter le suivi actif.

La connexion et la déconnexion sont exécutées par le binaire officiel non modifié. Status ne lit
ni le Trousseau de Claude Code, ni `.credentials.json`, ni ses transcripts. `claude auth status`
fournit seulement l’identité et l’état connecté. Son environnement exclut les clés API, tokens et
paramètres de proxy hérités. Aucun jeton ne transite par le bridge.

Le collecteur conserve seulement les deux fenêtres `five_hour` et `seven_day`, la date de collecte,
l’UUID Status, la génération et l’identité du compte vérifiée par `auth status`. Le lecteur vérifie
UUID, génération, identité et expiration avant d’afficher. L’historique utilise la date de collecte
et ne duplique pas un snapshot à chaque sondage. Les tests emploient des comptes fictifs isolés.

## Limites

- Les quotas proviennent de l’abonnement Pro/Max mais leur observation dépend de l’activité du
  profil Claude Code. Les autres sessions Claude Desktop/Cowork ne déclenchent pas ce collecteur.
- Aucune mesure avant la première réponse. Aucun appel payant n’est généré pour actualiser.
- Après 30 minutes, la mesure est indiquée ancienne ; après expiration, la fenêtre est masquée.
- Aucun sous-quota par modèle ni nombre exact de tokens restants n’est inventé.
- Les comptes web antérieurs restent en place jusqu’à la bascule volontaire.
- Déconnecter invalide le bridge puis appelle `claude auth logout`. Fermer les sessions interactives
  de ce profil pour terminer leur activité. Retirer conserve le profil local et ses conversations.
- La preuve de quotas réels nécessite une connexion humaine puis une réponse dans ce profil.

## Validation

`./scripts/run-tests.sh` exécute les tests natifs, web et les neuf tests d’intégration du bridge.
Ces derniers couvrent deux profils, métadonnées autorisées, générations, identité, invalidité et
expiration des fenêtres, fraîcheur, logout, quoting des chemins et historique sans doublons.

Sources : [status line](https://code.claude.com/docs/en/statusline),
[authentification](https://code.claude.com/docs/en/authentication),
[profils distincts](https://code.claude.com/docs/en/env-vars).
