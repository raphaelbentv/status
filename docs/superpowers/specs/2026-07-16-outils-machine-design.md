# Outils machine — verrou clavier et anti-veille

16 juillet 2026

## Contexte

Status surveille des quotas OAuth. Ces deux features n'ont rien à voir avec les quotas : elles
contrôlent la machine physique depuis la barre des menus. L'app devient donc, assumé, une petite
boîte à outils personnelle en plus de son métier d'origine.

## Périmètre

Dans le périmètre :

- **Verrou clavier** — bloquer toutes les touches le temps de nettoyer le clavier.
- **Anti-veille** — maintenir le Mac éveillé.

Hors périmètre, écartés explicitement :

- **Boost de luminosité XDR** — abandonné, voir « Décisions » ci-dessous.
- **Mode présentation**, **éjection des disques externes**, **raccourci clavier global** — proposés,
  non retenus.

## Décisions

### Le boost XDR est abandonné

Un prototype jetable a été construit le 16 juillet 2026 : une fenêtre plein écran hébergeant un
`CAMetalLayer` en `wantsExtendedDynamicRangeContent`, avec trois modes de composition (fondu normal,
additif `plusL`, `screenBlendMode`) et un affichage en direct de la réserve EDR. Résultat mesuré :

- La réserve EDR de l'écran est restée à **9.53 avant, pendant et après** le test. Le calque
  `CAMetalLayer` en `wantsExtendedDynamicRangeContent` n'a **jamais déclenché le mode HDR**.
- Ce que le calque produisait n'était pas un gain de luminosité mais un **voile blanc translucide** :
  les noirs montaient avec le reste, donc contraste détruit.
- La prémisse était fausse de toute façon : l'EDR est conçu pour maintenir le SDR à son niveau de
  référence et ne dépenser la marge que sur les hautes lumières.

Leviers recherchés ensuite, et pourquoi aucun ne convient :

| Levier | Verdict |
| --- | --- |
| `DisplayServicesSetBrightness` (privé) | Plage 0–100 % : doublon des touches F1/F2, ne franchit pas le plafond |
| `CGSetDisplayTransferByTable` (public) | Remappe le gamma dans la plage existante : délave les noirs, même défaut que le voile |
| `CoreDisplay_Display_SetHDRModeEnabled` (privé) | Non testé ; activer le HDR délave généralement le SDR au lieu de l'éclairer |
| Point blanc SDR relatif au pic HDR | **Le knob qu'il faudrait — exposé sous aucun nom identifiable** |

**Décision : recourir à Vivid**, application tierce dédiée. Reconstruire un équivalent exigerait de la
rétro-ingénierie d'API privées, dans une app dont ce n'est pas le métier, avec rupture garantie à une
future version de macOS.

### Le verrou bloque totalement, sans repli

`CGEventTap` au niveau HID, permission Accessibilité requise. Si la permission manque, le bouton
n'active rien : il explique et ouvre le panneau des Réglages Système. **Pas de faux verrou** — un
verrou qui laisse passer Cmd+Tab est pire qu'un verrou absent, parce qu'on lui fait confiance.

### Le déverrouillage se fait à la souris

Bouton plein écran, **maintien du clic pendant 1 seconde** (pas un clic sec : un chiffon ne maintient
pas). Le trackpad reste actif — il est la porte de sortie, donc il ne peut pas être nettoyé pendant
le verrou. Pas de minuterie utilisateur.

### Placement : une rangée d'outils dans le popover

Deux contrôles entre les jauges et le pied de page, langage Blueprint existant. Le popover passe de
450 à ~500 px. Un verrou clavier doit être à un clic : c'est justement quand on ne peut plus taper
qu'on en a besoin.

## Architecture

Deux modules indépendants, sur le modèle de l'extraction `StatusQuota` déjà en place. Aucun ne
connaît les quotas ; `Status.m` (1406 lignes, déjà trop gros) ne gagne que le câblage.

| Module | Rôle | Dépendances |
| --- | --- | --- |
| `Native/StatusAwake.{h,m}` | assertion anti-veille | IOKit |
| `Native/StatusKeyboardLock.{h,m}` | tap clavier + overlay | ApplicationServices, AppKit |

## Verrou clavier

`TMKeyboardLock` : `-lock`, `-unlock`, `-isLocked`, `-isPermissionGranted`, plus un bloc de
notification de changement d'état.

- **Tap** : `CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, …)`
  sur `keyDown`, `keyUp`, `flagsChanged` et `NX_SYSDEFINED` (touches média et luminosité). Le rappel
  renvoie `NULL` pour avaler l'événement.
- **Réarmement** : sur `kCGEventTapDisabledByTimeout` / `ByUserInput`, réactiver via
  `CGEventTapEnable`. Sans ça le verrou meurt silencieusement.
- **Permission** : `AXIsProcessTrustedWithOptions` avec `kAXTrustedCheckOptionPrompt`. Lien direct
  vers `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.
- **Overlay** : une fenêtre sans bordure par écran, `NSScreenSaverWindowLevel`, `collectionBehavior`
  = `CanJoinAllSpaces | Stationary | FullScreenAuxiliary`. Le bouton vit sur l'écran principal.

### Limites assumées, à afficher dans l'interface

- **Le bouton d'alimentation et Touch ID restent actifs** — aucun tap ne les intercepte.
- **L'overlay recouvre la barre des menus**, donc Pomme > Forcer à quitter est inaccessible pendant
  le verrou. Le bouton est la seule sortie volontaire.

### Filets de sécurité

1. Si Status plante ou se fige, macOS désactive le tap tout seul : le clavier revient.
2. Levée **inconditionnelle au bout de 5 minutes**. Garde-fou contre l'enfermement, pas un mode
   d'emploi — l'interface ne le présente pas comme une durée de nettoyage.
3. `applicationWillTerminate` déverrouille explicitement.

## Anti-veille

`TMAwake` : `-setEnabled:`, `-isEnabled`. Une `IOPMAssertionCreateWithName` de type
`kIOPMAssertionTypePreventUserIdleDisplaySleep`, maintenue tant que l'interrupteur est actif,
relâchée à la désactivation et à l'extinction. Aucune permission.

L'état n'est **pas** persisté entre les lancements : un Mac qui refuse de dormir après un
redémarrage, sans que personne ne se souvienne pourquoi, est un piège.

## Interface

Rangée `.tools` entre `.providers` et `.footer` dans `Resources/menubar.html`. Deux contrôles au
langage Blueprint. L'état circule par le `pushData` existant, enrichi d'un bloc :

```
tools: {
  keyboardLock: { available: bool, active: bool },   // available = permission accordée
  awake:        { active: bool }
}
```

Nouvelles actions JS → natif, dans le `switch` de `userContentController:didReceiveScriptMessage:` :
`toggleKeyboardLock`, `toggleAwake`, `openAccessibilitySettings`.

## Tests

Soyons honnêtes sur la couverture. Les 63 vérifications actuelles portent sur de la logique pure ;
ici l'essentiel est de l'entrée-sortie système (tap, IOKit) que je vérifierai **en exécutant**, pas
en testant. Ce qui rejoint `Tests/native-tests.m` :

- la machine à états du verrou (verrouillé / déverrouillé / permission absente) ;
- la logique de maintien du clic (un clic de moins d'une seconde ne déverrouille pas).

Le tap lui-même, l'overlay et l'assertion IOKit sont vérifiés à la main sur la machine.

## Ordre de travail

1. **Anti-veille** — le moins cher, et il valide la rangée d'outils de bout en bout (natif → JS →
   natif) avant qu'on y branche quelque chose de risqué.
2. **Verrou clavier** — tap, permission, overlay, bouton, filets de sécurité.
