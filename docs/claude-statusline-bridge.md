# Bridge Claude Code pour Status

Le script `scripts/status-claude-bridge.py` collecte uniquement le champ officiel `rate_limits` fourni par Claude Code aux commandes `statusLine`. Il ne lit aucun identifiant, cookie, fichier de credentials ou transcript.

Prérequis : Claude Code 2.1.80 ou ultérieur, connecté à un abonnement Claude.ai Pro/Max. Les compteurs apparaissent après la première réponse d'une session Claude Code.

## Commandes

```bash
scripts/status-claude-bridge.py install
scripts/status-claude-bridge.py status
scripts/status-claude-bridge.py uninstall
```

`install` est opt-in. Il sauvegarde la status line existante et installe un wrapper qui lui retransmet le JSON d'entrée et reproduit son stdout. `uninstall` restaure l'objet `statusLine` précédent. Si l'utilisateur a modifié `statusLine` entre-temps, la désinstallation refuse de l'écraser ; `uninstall --force` est disponible comme action explicite.

Chemins par défaut :

- configuration Claude : `~/.claude/settings.json` ou `$CLAUDE_CONFIG_DIR/settings.json` ;
- état privé : `~/Library/Application Support/Status/Claude` en mode `0700` ;
- snapshot : `quota-snapshot.json` en mode `0600`.

Pour les tests, `STATUS_CLAUDE_SETTINGS_PATH` et `STATUS_CLAUDE_STATE_DIR` remplacent ces chemins.

## Contrat JSON du snapshot

```json
{
  "schema_version": 1,
  "provider": "claude",
  "source": "claude_code_statusline",
  "captured_at": "2026-07-14T20:00:00Z",
  "captured_at_epoch": 1784059200,
  "claude_code_version": "2.1.80",
  "session_id": "opaque-session-id",
  "rate_limits": {
    "five_hour": {
      "used_percentage": 23.5,
      "remaining_percentage": 76.5,
      "resets_at": 1784066400
    },
    "seven_day": {
      "used_percentage": 41.2,
      "remaining_percentage": 58.8,
      "resets_at": 1784491200
    }
  }
}
```

Chaque fenêtre peut être absente. Le collecteur accepte aussi de futures fenêtres dont le nom ne contient que `[a-z0-9_]`. Si un appel de status line ne contient aucun compteur valide, le dernier snapshot correct est conservé afin que Status puisse l'afficher comme périmé plutôt que comme « 100 % restant ».

La commande `status` renvoie un objet JSON sur une ligne contenant notamment `installed`, `configured`, `snapshot_present`, `snapshot_path` et `snapshot`.

Source : [Claude Code — Customize your status line](https://code.claude.com/docs/en/statusline#rate-limit-usage).

## Intégration dans l’application macOS

Le bridge est embarqué dans `Status.app/Contents/Resources/scripts`. L’application :

- détecte Claude Code sans lire son Trousseau ni ses fichiers d’authentification ;
- utilise uniquement `claude auth status` pour déterminer l’état connecté/non connecté ;
- ouvre `claude auth login` dans Terminal, sans rediriger ni capturer sa saisie ;
- appelle le bridge embarqué avec `status`, `install` et `uninstall` ;
- ne transmet à la WebView que les fenêtres normalisées, leur pourcentage restant, leur reset et l’ancienneté du snapshot ;
- distingue CLI absente, compte non connecté, suivi désactivé, suivi actif en attente d’une première réponse, données fraîches et données anciennes.

Le bouton **Installer** ouvre la documentation officielle de Claude Code. **Activer le suivi** demande une confirmation avant de modifier `~/.claude/settings.json`. **Désactiver** restaure la status line précédente et refuse toute restauration destructive si la configuration a été modifiée entre-temps.

## Vérification

```bash
python3 -m unittest Tests/test_status_claude_bridge.py
```
