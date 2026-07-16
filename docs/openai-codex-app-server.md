# Connexion OpenAI dans Status

Status lit les limites du compte ChatGPT via l’interface locale officielle `codex app-server`. Il ne lit, ne copie et ne journalise aucun jeton d’authentification.

## Parcours

1. Status lance le binaire `codex` livré avec l’app ChatGPT, ou une installation locale connue.
2. La connexion `stdio` est initialisée avec le protocole JSONL (`initialize`, puis `initialized`).
3. `account/read` détermine si un compte ChatGPT est déjà connecté.
4. Si nécessaire, `account/login/start` renvoie une URL HTTPS que Status ouvre dans le navigateur. Codex conserve lui-même la session.
5. `account/rateLimits/read` fournit les fenêtres disponibles pour le compte. Status affiche dynamiquement leur durée, le pourcentage restant et l’heure de réinitialisation. Il ne suppose donc pas qu’un compte possède forcément une fenêtre 5 h ou semaine.
6. Les notifications `account/login/completed`, `account/updated` et `account/rateLimits/updated` déclenchent une nouvelle lecture.

La déconnexion appelle `account/logout`. Comme Status partage la session Codex locale, l’interface avertit qu’elle déconnecte également Codex sur ce Mac.

## Données affichées

Chaque fenêtre utilise les champs officiels :

- `windowDurationMins`
- `usedPercent`
- `resetsAt`

Le pourcentage restant est calculé localement comme `100 - usedPercent`. Les compteurs mensuels de l’API OpenAI existants restent indépendants et continuent d’utiliser, lorsqu’elle est configurée, la clé administrateur stockée dans le Trousseau macOS.

## Compatibilité

Le chemin du binaire est résolu dans cet ordre :

1. variable d’environnement `STATUS_CODEX_PATH` ;
2. binaire embarqué dans `/Applications/ChatGPT.app` ;
3. `~/.local/bin/codex` ;
4. Homebrew (`/opt/homebrew/bin/codex`) ;
5. `/usr/local/bin/codex`.

Le schéma de référence peut être régénéré pour la version installée avec :

```sh
codex app-server generate-json-schema --out work/app-server-schema
```

## Vérifications réalisées

- compilation AppKit/WebKit avec ARC ;
- validation de la signature ad hoc et du `Info.plist` ;
- validation syntaxique du JavaScript embarqué ;
- échange réel et filtré avec `initialize`, `account/read` et `account/rateLimits/read` ;
- test de lancement de cinq secondes sans arrêt inattendu.

