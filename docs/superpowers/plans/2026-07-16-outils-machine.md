# Outils machine (verrou clavier + anti-veille) — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ajouter à Status deux contrôles machine — un verrou clavier pour nettoyer le clavier sans rien déclencher, et un interrupteur anti-veille — dans une rangée d'outils du popover.

**Architecture:** Deux modules autonomes (`StatusAwake`, `StatusKeyboardLock`) sur le modèle de l'extraction `StatusQuota` déjà en place. Ni l'un ni l'autre ne connaît les quotas ; `Status.m` ne gagne que le câblage. Le verrou repose sur un `CGEventTap` HID (permission Accessibilité) plus un overlay plein écran dont le bouton de sortie demande un maintien du clic.

**Tech Stack:** Objective-C + ARC, clang sans Xcode, AppKit, IOKit, ApplicationServices. Build : `./scripts/package-app.sh`. Tests : `./scripts/run-tests.sh`.

**Spec :** `docs/superpowers/specs/2026-07-16-outils-machine-design.md`

## Global Constraints

- **Pas de Xcode.** Tout se compile via `scripts/package-app.sh` ; tout nouveau `.m` doit y être ajouté, et tout nouveau framework aussi.
- **macOS 13+** (déjà supposé : `SMAppService` est utilisé).
- **Préfixe `TM`** pour tous les types et fonctions globales — convention de tout le codebase.
- **Commentaires en français** dans les nouveaux modules, comme `StatusQuota.h`. Identifiants en anglais.
- **Langage visuel « Blueprint »** pour toute UI : variables CSS déjà définies dans `Resources/menubar.html` (`--bg`, `--text`, `--muted`, `--hair`, `--hair-strong`, `--soft`, `--blue`, `--purple`, `--danger`). Pas de nouvelle couleur.
- **Le boost de luminosité XDR est hors périmètre** — réfuté par prototype, voir la spec. Ne pas le réintroduire.
- **Aucun état persistant pour l'anti-veille ni le verrou.** Les deux sont éteints à chaque lancement, délibérément.
- **Le dépôt n'est pas versionné** aujourd'hui. La tâche 0 y remédie ; sans elle, sauter toutes les étapes « Commit ».

## Structure des fichiers

| Fichier | Responsabilité |
| --- | --- |
| `Native/StatusAwake.h` / `.m` | **Créer.** Assertion IOKit anti-veille. Rien d'autre. |
| `Native/StatusKeyboardLock.h` / `.m` | **Créer.** Logique pure du verrou (tâche 2), overlay + bouton (tâche 3), tap HID (tâche 4). |
| `Tests/native-tests.m` | **Modifier.** Ajouter `TestAwake`, `TestHoldFraction`, `TestLockStateMachine`. |
| `scripts/run-tests.sh` | **Modifier.** Lier les nouveaux modules et frameworks. |
| `scripts/package-app.sh` | **Modifier.** Ligne 11-14 : ajouter les `.m` et `-framework IOKit`. |
| `Resources/menubar.html` | **Modifier.** Rangée `.tools` entre `.providers` et `.footer`. |
| `Native/Status.m` | **Modifier.** Ligne 557 (hauteur popover), `payload`, `userContentController:`, ivars, `applicationWillTerminate:`. |

---

## Task 0: Versionner le projet

Le dépôt n'existe pas. On s'apprête à ajouter un `CGEventTap` qui bloque le clavier de la machine : il faut pouvoir revenir en arrière.

**Files:**
- Create: `.gitignore`

**Interfaces:**
- Consumes: rien
- Produces: un dépôt git avec un commit initial, prérequis de toutes les étapes « Commit » suivantes.

- [ ] **Step 1: Écrire le .gitignore**

`work/` contient les binaires intermédiaires, `outputs/` le bundle et le zip : aucun des deux n'est une source.

```
work/
outputs/
.DS_Store
```

- [ ] **Step 2: Initialiser et committer**

```bash
cd /Users/raphaelbentvelzen/Dev/Status-terminal
git init
git add -A
git commit -m "chore: initialiser le dépôt avant les outils machine"
```

- [ ] **Step 3: Vérifier que les artefacts de build sont bien exclus**

Run: `git status --porcelain | grep -E "^\?\? (work|outputs)/" || echo "correctement ignorés"`
Expected: `correctement ignorés`

---

## Task 1: Anti-veille de bout en bout

Le moins cher des deux, et il valide toute la chaîne (module → `payload` → JS → action → module) avant qu'on y branche quelque chose de risqué.

**Files:**
- Create: `Native/StatusAwake.h`, `Native/StatusAwake.m`
- Modify: `Tests/native-tests.m`, `scripts/run-tests.sh`, `scripts/package-app.sh:11-14`, `Resources/menubar.html`, `Native/Status.m`

**Interfaces:**
- Consumes: rien
- Produces:
  - `@interface TMAwake : NSObject` avec `@property (nonatomic, getter=isEnabled) BOOL enabled;`
  - Rangée `.tools` dans `menubar.html`, avec la fonction JS `tools(t)` que la tâche 3 étendra.
  - Bloc `tools` dans `payload` : `{ awake: { active: bool } }` ; la tâche 4 y ajoutera `keyboardLock`.
  - Action JS→natif `toggleAwake`.

- [ ] **Step 1: Écrire le test qui échoue**

Ce test ne se contente pas de relire notre propre booléen — il demande à IOKit si l'assertion existe réellement, et la filtre sur notre pid pour qu'une autre app tenant la même assertion ne le fasse pas passer à tort.

Ajouter dans `Tests/native-tests.m`, après les `#import` existants :

```objc
#import "StatusAwake.h"
#import <IOKit/pwr_mgt/IOPMLib.h>
```

Puis, avant `main` :

```objc
// Interroge IOKit plutôt que notre propre état : c'est la seule façon de savoir si l'assertion
// existe vraiment. Filtré sur notre pid — une autre app tenant la même assertion ne doit pas
// rendre ce test faussement vert.
static BOOL TMOurSleepAssertionPresent(void) {
    CFDictionaryRef raw = NULL;
    if (IOPMCopyAssertionsByProcess(&raw) != kIOReturnSuccess || !raw) return NO;
    NSDictionary *byPid = CFBridgingRelease(raw);
    for (NSDictionary *assertion in byPid[@(getpid())]) {
        NSString *type = assertion[(__bridge NSString *)kIOPMAssertionTypeKey];
        if ([type isEqualToString:(__bridge NSString *)kIOPMAssertionTypePreventUserIdleDisplaySleep]) return YES;
    }
    return NO;
}

static void TestAwake(void) {
    printf("\n\033[1mTMAwake\033[0m\n");
    TMAwake *awake = [TMAwake new];
    Check(!awake.isEnabled, @"éteint au départ");
    Check(!TMOurSleepAssertionPresent(), @"aucune assertion au départ");

    awake.enabled = YES;
    Check(awake.isEnabled, @"s'allume");
    Check(TMOurSleepAssertionPresent(), @"IOKit voit notre assertion");

    awake.enabled = YES;  // idempotent : ne doit pas créer une seconde assertion fuyante
    Check(awake.isEnabled, @"rallumer ne change rien");

    awake.enabled = NO;
    Check(!awake.isEnabled, @"s'éteint");
    Check(!TMOurSleepAssertionPresent(), @"IOKit ne voit plus d'assertion");
}
```

Enfin, appeler `TestAwake();` dans `main`, juste après `TestHistory();`.

- [ ] **Step 2: Câbler le lanceur de tests**

Remplacer le bloc `clang` de `scripts/run-tests.sh` (sous `echo "── Tests natifs (StatusQuota) ──"`) par :

```bash
clang -fobjc-arc -I "$ROOT/Native" -framework Foundation -framework IOKit \
  "$ROOT/Tests/native-tests.m" "$ROOT/Native/StatusQuota.m" "$ROOT/Native/StatusAwake.m" \
  -o "$BUILD/native-tests"
```

- [ ] **Step 3: Lancer le test pour vérifier qu'il échoue**

Run: `./scripts/run-tests.sh 2>&1 | head -20`
Expected: échec de compilation, `'StatusAwake.h' file not found`

- [ ] **Step 4: Écrire l'en-tête**

Créer `Native/StatusAwake.h` :

```objc
// StatusAwake — empêche la mise en veille de l'écran tant que l'interrupteur est actif.
//
// Volontairement minuscule et sans persistance : un Mac qui refuse de dormir après un redémarrage,
// sans que personne ne se souvienne pourquoi, est un piège. Voir la spec du 16 juillet 2026.

#import <Foundation/Foundation.h>

@interface TMAwake : NSObject
// Les deux accesseurs sont écrits à la main : l'état réel vit dans IOKit, pas dans un ivar
// synthétisé qui pourrait mentir si IOKit refuse l'assertion.
@property (nonatomic, getter=isEnabled) BOOL enabled;
@end
```

- [ ] **Step 5: Écrire l'implémentation**

Créer `Native/StatusAwake.m` :

```objc
#import "StatusAwake.h"
#import <IOKit/pwr_mgt/IOPMLib.h>

@implementation TMAwake {
    IOPMAssertionID _assertion;
    BOOL _enabled;
}

- (BOOL)isEnabled { return _enabled; }

- (void)setEnabled:(BOOL)enabled {
    if (enabled == _enabled) return;  // sans ce garde, rallumer fuit l'assertion précédente
    if (enabled) {
        IOReturn result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionLevelOn,
            CFSTR("Status — veille désactivée"), &_assertion);
        // Si IOKit refuse, on reste éteint : mieux vaut un interrupteur qui ne s'allume pas qu'un
        // interrupteur allumé qui ne fait rien.
        _enabled = (result == kIOReturnSuccess);
    } else {
        IOPMAssertionRelease(_assertion);
        _assertion = 0;
        _enabled = NO;
    }
}

- (void)dealloc {
    if (_enabled) IOPMAssertionRelease(_assertion);
}

@end
```

- [ ] **Step 6: Lancer les tests pour vérifier qu'ils passent**

Run: `./scripts/run-tests.sh 2>&1 | grep -A9 "TMAwake"`
Expected: les 7 vérifications de `TMAwake` en vert, et le total global sans échec.

- [ ] **Step 7: Ajouter le module au build de l'app**

Dans `scripts/package-app.sh`, remplacer les lignes 11-14 par :

```bash
clang -fobjc-arc -O2 -I "$ROOT/Native" \
  -framework Cocoa -framework WebKit -framework Security \
  -framework ServiceManagement -framework UserNotifications -framework IOKit \
  "$ROOT/Native/Status.m" "$ROOT/Native/StatusQuota.m" "$ROOT/Native/StatusAwake.m" -o "$BUILD"
```

- [ ] **Step 8: Ajouter la rangée d'outils au popover**

Dans `Resources/menubar.html`, ajouter ce CSS juste avant `.segmented` (vers la ligne 34) :

```css
  /* Outils machine — rien à voir avec les quotas, d'où la séparation visuelle nette. */
  .tools{display:flex;gap:1px;background:var(--hair-strong);border-top:1px solid var(--hair-strong);flex:none}
  .tool{flex:1;border:0;background:rgba(18,22,28,.85);color:var(--muted);padding:10px 6px;cursor:pointer;font:inherit;font-size:9.5px;display:flex;flex-direction:column;align-items:center;gap:5px;text-transform:lowercase;letter-spacing:.05em}
  .tool:hover{background:var(--soft);color:var(--text)}
  .tool.on{color:var(--blue);background:rgba(103,232,249,.12)}
  .tool .glyph{font-size:15px;line-height:1}
```

Remplacer la ligne 49 (`<div class="popover">…`) par :

```html
<div class="popover"><div class="providers" id="providers"></div><div class="tools" id="tools"></div><footer class="footer"><span class="sync" id="sync">maj…</span><span class="segmented" id="metric"></span><button onclick="send('refresh')" title="Actualiser">⟳</button><button class="go" onclick="send('openDashboard')">ouvrir</button><button onclick="send('quit')" style="color:var(--danger)" title="Quitter Status">×</button></footer></div>
```

Ajouter cette fonction JS juste avant `let lastData=null;` :

```js
// La tâche 4 ajoutera ici le bouton du verrou clavier.
function tools(t){
  const btn=(action,glyph,label,active)=>`<button class="tool ${active?'on':''}" onclick="send('${action}')"><span class="glyph">${glyph}</span>${label}</button>`;
  const awake=t?.awake||{};
  return btn('toggleAwake','☾',awake.active?'veille bloquée':'veille',awake.active);
}
```

Et dans `renderMenu(data)`, juste après la ligne qui remplit `#providers` :

```js
  document.querySelector('#tools').innerHTML=tools(data.tools);
```

- [ ] **Step 9: Câbler le natif**

Dans `Native/Status.m` :

1. Après `#import "StatusQuota.h"` (ligne 8), ajouter :

```objc
#import "StatusAwake.h"
```

2. Dans `@interface TMAppDelegate` (vers la ligne 456, après `@property BOOL notificationsAuthorized;`), ajouter :

```objc
@property TMAwake *awake;
```

3. Dans `payload` (ligne 888), juste avant la clé `@"backoffUntil"`, ajouter :

```objc
        @"tools": @{ @"awake": @{ @"active": @(self.awake.isEnabled) } },
```

4. Dans `userContentController:didReceiveScriptMessage:`, après la ligne `if ([action isEqualToString:@"quit"]) [NSApp terminate:nil];`, ajouter :

```objc
    if ([action isEqualToString:@"toggleAwake"]) {
        self.awake.enabled = !self.awake.isEnabled;
        [self pushData];
    }
```

5. Dans `applicationDidFinishLaunching:` (ligne 461), au tout début du corps, ajouter :

```objc
    self.awake = [TMAwake new];
```

6. Dans `applicationWillTerminate:` (ligne 500), au début du corps, ajouter :

```objc
    self.awake.enabled = NO;  // l'assertion mourrait avec le processus, mais la relâcher est explicite
```

7. Ligne 557, la rangée d'outils prend de la place :

```objc
    NSRect frame = NSMakeRect(0, 0, 400, 500);
```

- [ ] **Step 10: Vérifier dans l'app réelle**

Les tests couvrent le module ; ils ne couvrent pas le câblage. Il faut le voir marcher.

```bash
./scripts/install-app.sh
```

Puis, à la main : cliquer l'icône Status, cliquer l'outil **veille**. Il doit devenir cyan et afficher « veille bloquée ». Vérifier que le système est d'accord :

Run: `pmset -g assertions | grep -i preventuseridledisplaysleep`
Expected: une ligne avec un compteur à `1` et `Status` cité comme détenteur.

Re-cliquer l'outil, puis :

Run: `pmset -g assertions | grep -i "preventuseridledisplaysleep.*1" || echo "assertion relâchée"`
Expected: `assertion relâchée`

- [ ] **Step 11: Commit**

```bash
git add Native/StatusAwake.h Native/StatusAwake.m Tests/native-tests.m scripts/run-tests.sh scripts/package-app.sh Resources/menubar.html Native/Status.m
git commit -m "feat: interrupteur anti-veille dans une rangée d'outils du popover"
```

---

## Task 2: Verrou clavier — logique pure

Soyons honnêtes sur ce que cette tâche vaut : la logique testable du verrou est mince, et l'essentiel du risque (le tap, l'overlay) n'est pas testable sans machine. Ce qui suit couvre deux choses qui cassent réellement — une division par zéro dans l'anneau de progression, et l'impossibilité de sortir si la permission est révoquée pendant le verrou.

**Files:**
- Create: `Native/StatusKeyboardLock.h`, `Native/StatusKeyboardLock.m`
- Modify: `Tests/native-tests.m`, `scripts/run-tests.sh`

**Interfaces:**
- Consumes: rien
- Produces:
  - `extern const NSTimeInterval TMHoldRequiredSeconds;` (= 1.0)
  - `double TMHoldFraction(NSTimeInterval elapsed, NSTimeInterval required);` → 0…1 borné
  - `typedef NS_ENUM(NSInteger, TMLockState) { TMLockStateUnlocked, TMLockStateLocked, TMLockStateBlocked };`
  - `TMLockState TMLockStateAfterToggle(TMLockState current, BOOL permissionGranted);`

- [ ] **Step 1: Écrire les tests qui échouent**

Ajouter dans `Tests/native-tests.m`, après `#import "StatusAwake.h"` :

```objc
#import "StatusKeyboardLock.h"
```

Puis, avant `main` :

```objc
static void TestHoldFraction(void) {
    printf("\n\033[1mTMHoldFraction\033[0m\n");
    Check(TMHoldFraction(0.0, 1.0) == 0.0, @"rien de maintenu = 0");
    Check(TMHoldFraction(0.5, 1.0) == 0.5, @"moitié du temps = 0,5");
    Check(TMHoldFraction(1.0, 1.0) == 1.0, @"temps atteint = 1");
    Check(TMHoldFraction(9.0, 1.0) == 1.0, @"borné à 1 : l'anneau ne déborde pas");
    Check(TMHoldFraction(-3.0, 1.0) == 0.0, @"borné à 0 : une horloge qui recule ne casse rien");
    Check(TMHoldFraction(0.5, 0.0) == 1.0, @"durée nulle : pas de division par zéro");
}

static void TestLockStateMachine(void) {
    printf("\n\033[1mTMLockStateAfterToggle\033[0m\n");
    Check(TMLockStateAfterToggle(TMLockStateUnlocked, YES) == TMLockStateLocked,
          @"permission accordée : verrouille");
    Check(TMLockStateAfterToggle(TMLockStateUnlocked, NO) == TMLockStateBlocked,
          @"permission absente : bloqué, pas de faux verrou");
    Check(TMLockStateAfterToggle(TMLockStateBlocked, YES) == TMLockStateLocked,
          @"permission accordée après coup : verrouille");
    Check(TMLockStateAfterToggle(TMLockStateBlocked, NO) == TMLockStateBlocked,
          @"toujours pas de permission : reste bloqué");
    Check(TMLockStateAfterToggle(TMLockStateLocked, YES) == TMLockStateUnlocked,
          @"verrouillé : déverrouille");
    // Le cas qui compte : la permission est révoquée pendant le verrou. On doit pouvoir sortir.
    Check(TMLockStateAfterToggle(TMLockStateLocked, NO) == TMLockStateUnlocked,
          @"permission révoquée pendant le verrou : on sort quand même");
}
```

Appeler `TestHoldFraction();` et `TestLockStateMachine();` dans `main`, après `TestAwake();`.

- [ ] **Step 2: Câbler le lanceur de tests**

Remplacer le bloc `clang` de `scripts/run-tests.sh` par (Cocoa est lié dès maintenant : la tâche 3 ajoute l'overlay dans ce même module) :

```bash
clang -fobjc-arc -I "$ROOT/Native" -framework Foundation -framework IOKit -framework Cocoa \
  "$ROOT/Tests/native-tests.m" "$ROOT/Native/StatusQuota.m" "$ROOT/Native/StatusAwake.m" \
  "$ROOT/Native/StatusKeyboardLock.m" \
  -o "$BUILD/native-tests"
```

- [ ] **Step 3: Lancer les tests pour vérifier qu'ils échouent**

Run: `./scripts/run-tests.sh 2>&1 | head -20`
Expected: échec de compilation, `'StatusKeyboardLock.h' file not found`

- [ ] **Step 4: Écrire l'en-tête**

Créer `Native/StatusKeyboardLock.h` :

```objc
// StatusKeyboardLock — bloque tout le clavier le temps de le nettoyer.
//
// Le blocage est total (CGEventTap au niveau HID) et exige la permission Accessibilité. Il n'y a
// délibérément pas de repli « léger » : un verrou qui laisse passer Cmd+Tab est pire qu'un verrou
// absent, parce qu'on lui fait confiance. Voir la spec du 16 juillet 2026.
//
// Limites assumées, à afficher dans l'interface :
//   — le bouton d'alimentation et Touch ID restent actifs, aucun tap ne les intercepte ;
//   — l'overlay recouvre la barre des menus, donc Pomme > Forcer à quitter est hors d'atteinte.
// Filets de sécurité : si l'app se fige, macOS désactive le tap tout seul ; et le verrou se lève
// inconditionnellement au bout de TMLockBackstopSeconds.

#import <Foundation/Foundation.h>

#pragma mark - Logique pure (testable sans machine)

// Durée de maintien du clic pour déverrouiller. Un clic sec ne suffit pas : un chiffon qui frotte
// le trackpad produit des clics, pas des maintiens.
extern const NSTimeInterval TMHoldRequiredSeconds;

// Levée inconditionnelle du verrou. Garde-fou contre l'enfermement — pas un mode d'emploi, et
// l'interface ne le présente pas comme une durée de nettoyage.
extern const NSTimeInterval TMLockBackstopSeconds;

// Fraction de maintien accomplie, bornée à [0, 1]. Bornée parce qu'elle pilote un anneau de
// progression et qu'une horloge qui recule ne doit pas le faire déborder.
double TMHoldFraction(NSTimeInterval elapsed, NSTimeInterval required);

typedef NS_ENUM(NSInteger, TMLockState) {
    TMLockStateUnlocked,  // repos
    TMLockStateLocked,    // tap actif, overlay affiché
    TMLockStateBlocked    // permission Accessibilité absente : rien n'est verrouillé
};

// Déverrouiller est toujours possible, même sans permission : elle peut être révoquée pendant le
// verrou, et l'utilisateur ne doit pas se retrouver enfermé pour autant.
TMLockState TMLockStateAfterToggle(TMLockState current, BOOL permissionGranted);
```

- [ ] **Step 5: Écrire l'implémentation**

Créer `Native/StatusKeyboardLock.m` :

```objc
#import "StatusKeyboardLock.h"
// AXIsProcessTrusted / kAXTrustedCheckOptionPrompt vivent ici. AppKit les inclut peut-être de
// façon transitive : ne pas parier là-dessus.
#import <ApplicationServices/ApplicationServices.h>

const NSTimeInterval TMHoldRequiredSeconds = 1.0;
const NSTimeInterval TMLockBackstopSeconds = 300.0;

double TMHoldFraction(NSTimeInterval elapsed, NSTimeInterval required) {
    if (required <= 0) return 1.0;  // une durée nulle est déjà écoulée — jamais de division par zéro
    double fraction = elapsed / required;
    if (fraction < 0) return 0.0;
    if (fraction > 1) return 1.0;
    return fraction;
}

TMLockState TMLockStateAfterToggle(TMLockState current, BOOL permissionGranted) {
    if (current == TMLockStateLocked) return TMLockStateUnlocked;
    return permissionGranted ? TMLockStateLocked : TMLockStateBlocked;
}
```

- [ ] **Step 6: Lancer les tests pour vérifier qu'ils passent**

Run: `./scripts/run-tests.sh 2>&1 | grep -A8 "TMHoldFraction\|TMLockStateAfterToggle"`
Expected: les 12 vérifications en vert, total global sans échec.

- [ ] **Step 7: Commit**

```bash
git add Native/StatusKeyboardLock.h Native/StatusKeyboardLock.m Tests/native-tests.m scripts/run-tests.sh
git commit -m "feat: logique pure du verrou clavier (maintien, machine à états)"
```

---

## Task 3: Verrou clavier — overlay et bouton de sortie, sans tap

**On construit la porte de sortie avant la serrure.** Une tâche qui livrerait le tap sans sortie éprouvée obligerait à tester un verrou en étant enfermé dedans. Ici l'overlay est inoffensif : le clavier fonctionne pendant tout le développement de cette tâche, et quand le tap arrivera (tâche 4), la sortie sera déjà prouvée.

**Files:**
- Modify: `Native/StatusKeyboardLock.h`, `Native/StatusKeyboardLock.m`, `Native/Status.m`, `Resources/menubar.html`

**Interfaces:**
- Consumes: `TMHoldFraction`, `TMHoldRequiredSeconds`, `TMLockState`, `TMLockStateAfterToggle` (tâche 2)
- Produces:
  - `@interface TMKeyboardLock : NSObject` avec
    - `@property (nonatomic, readonly) TMLockState state;`
    - `@property (nonatomic, readonly) BOOL permissionGranted;`
    - `@property (nonatomic, copy) void (^onStateChange)(void);`
    - `- (void)toggle;` — applique `TMLockStateAfterToggle`, monte/démonte l'overlay
    - `- (void)unlock;` — sortie inconditionnelle, idempotente
    - `- (void)openAccessibilitySettings;`
  - Action JS→natif `toggleKeyboardLock` et `openAccessibilitySettings`.
  - Clé `keyboardLock: { available: bool, active: bool }` dans le bloc `tools` du `payload`.

- [ ] **Step 1: Déclarer la classe**

Ajouter à la fin de `Native/StatusKeyboardLock.h` :

```objc
#pragma mark - Verrou

#import <AppKit/AppKit.h>

@interface TMKeyboardLock : NSObject

@property (nonatomic, readonly) TMLockState state;
// Reflète AXIsProcessTrusted() à l'instant de l'appel : l'utilisateur peut révoquer à tout moment.
@property (nonatomic, readonly) BOOL permissionGranted;
// Appelé après chaque changement d'état, pour que l'app repousse son payload.
@property (nonatomic, copy) void (^onStateChange)(void);

// Verrouille si la permission est là, sinon passe en TMLockStateBlocked sans rien bloquer.
- (void)toggle;
// Sortie inconditionnelle et idempotente. Sûr à appeler à l'extinction.
- (void)unlock;
- (void)openAccessibilitySettings;

@end
```

- [ ] **Step 2: Écrire le bouton à maintien**

Ajouter à `Native/StatusKeyboardLock.m`, après les fonctions pures :

```objc
#pragma mark - Bouton à maintien

// Un clic sec ne déverrouille pas : il faut maintenir. L'anneau montre l'avancement, sinon le
// geste est indevinable et l'utilisateur croit que le bouton est cassé.
@interface TMHoldButton : NSView
@property (nonatomic, copy) void (^onComplete)(void);
@end

@implementation TMHoldButton {
    NSDate *_downAt;
    NSTimer *_timer;
}

- (double)fraction {
    if (!_downAt) return 0.0;
    return TMHoldFraction([[NSDate date] timeIntervalSinceDate:_downAt], TMHoldRequiredSeconds);
}

- (void)mouseDown:(NSEvent *)event {
    _downAt = [NSDate date];
    __weak typeof(self) weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
        typeof(self) self_ = weakSelf;
        if (!self_) { [timer invalidate]; return; }
        [self_ setNeedsDisplay:YES];
        if (self_.fraction >= 1.0) {
            void (^done)(void) = self_.onComplete;
            [self_ cancelHold];
            if (done) done();
        }
    }];
}

// La vue capture la souris entre mouseDown et mouseUp : relâcher hors du bouton passe quand même
// par ici. Pas besoin de NSTrackingArea.
- (void)mouseUp:(NSEvent *)event { [self cancelHold]; }

- (void)cancelHold {
    [_timer invalidate];
    _timer = nil;
    _downAt = nil;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect b = self.bounds;
    double f = self.fraction;

    // Cadre Blueprint : cyan sur ardoise.
    [[NSColor colorWithRed:0.071 green:0.086 blue:0.110 alpha:0.95] setFill];
    NSRectFill(b);
    NSBezierPath *border = [NSBezierPath bezierPathWithRect:NSInsetRect(b, 0.5, 0.5)];
    [[NSColor colorWithRed:0.404 green:0.910 blue:0.976 alpha:0.45] setStroke];
    border.lineWidth = 1;
    [border stroke];

    // Remplissage de progression : le geste doit être lisible pendant qu'on le fait.
    if (f > 0) {
        [[NSColor colorWithRed:0.404 green:0.910 blue:0.976 alpha:0.20] setFill];
        NSRectFill(NSMakeRect(0, 0, b.size.width * f, b.size.height));
    }

    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor colorWithRed:0.404 green:0.910 blue:0.976 alpha:1.0]
    };
    NSString *label = f > 0 ? @"maintenez…" : @"maintenir pour déverrouiller";
    NSSize size = [label sizeWithAttributes:attrs];
    [label drawAtPoint:NSMakePoint((b.size.width - size.width) / 2, (b.size.height - size.height) / 2)
        withAttributes:attrs];
}

@end
```

- [ ] **Step 3: Écrire l'overlay et la classe du verrou**

Ajouter ensuite à `Native/StatusKeyboardLock.m` :

```objc
#pragma mark - Verrou

@implementation TMKeyboardLock {
    NSMutableArray<NSWindow *> *_overlays;
    NSTimer *_backstop;
}

- (BOOL)permissionGranted { return AXIsProcessTrusted(); }

- (void)toggle {
    TMLockState next = TMLockStateAfterToggle(_state, self.permissionGranted);
    if (next == _state) { if (self.onStateChange) self.onStateChange(); return; }
    _state = next;
    if (next == TMLockStateLocked) [self showOverlays];
    else [self hideOverlays];
    if (self.onStateChange) self.onStateChange();
}

- (void)unlock {
    if (_state != TMLockStateLocked) return;
    _state = TMLockStateUnlocked;
    [self hideOverlays];
    if (self.onStateChange) self.onStateChange();
}

- (void)openAccessibilitySettings {
    // Demande la permission (macOS n'affiche sa boîte qu'une fois), puis ouvre le bon panneau :
    // sans lien direct, l'utilisateur doit fouiller les Réglages Système.
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{
        (__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES
    });
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}

- (void)showOverlays {
    _overlays = [NSMutableArray array];
    BOOL isMain = YES;
    for (NSScreen *screen in NSScreen.screens) {
        NSWindow *window = [[NSWindow alloc] initWithContentRect:screen.frame
                                                       styleMask:NSWindowStyleMaskBorderless
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        window.opaque = NO;
        window.backgroundColor = [NSColor colorWithRed:0.071 green:0.086 blue:0.110 alpha:0.92];
        window.level = NSScreenSaverWindowLevel;
        window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                    NSWindowCollectionBehaviorStationary |
                                    NSWindowCollectionBehaviorFullScreenAuxiliary;
        // Le bouton ne vit que sur l'écran principal : deux sorties ne valent pas mieux qu'une.
        if (isMain) {
            NSRect f = screen.frame;
            TMHoldButton *button = [[TMHoldButton alloc] initWithFrame:
                NSMakeRect(f.size.width / 2 - 170, f.size.height / 2 - 26, 340, 52)];
            __weak typeof(self) weakSelf = self;
            button.onComplete = ^{ [weakSelf unlock]; };
            [window.contentView addSubview:button];
            isMain = NO;
        }
        [window orderFrontRegardless];
        [_overlays addObject:window];
    }
    // Garde-fou : jamais enfermé, même si le bouton devient inatteignable.
    __weak typeof(self) weakSelf = self;
    _backstop = [NSTimer scheduledTimerWithTimeInterval:TMLockBackstopSeconds repeats:NO
                                                  block:^(NSTimer *t) { [weakSelf unlock]; }];
}

- (void)hideOverlays {
    [_backstop invalidate];
    _backstop = nil;
    for (NSWindow *window in _overlays) [window orderOut:nil];
    _overlays = nil;
}

@end
```

- [ ] **Step 4: Compiler pour vérifier que rien n'est cassé**

Run: `./scripts/run-tests.sh 2>&1 | tail -3`
Expected: total sans échec (les 12 tests purs de la tâche 2 passent toujours ; la classe compile).

- [ ] **Step 5: Câbler le natif**

Dans `Native/Status.m` :

1. Après `#import "StatusAwake.h"`, ajouter :

```objc
#import "StatusKeyboardLock.h"
```

2. Après `@property TMAwake *awake;`, ajouter :

```objc
@property TMKeyboardLock *keyboardLock;
```

3. Dans `applicationDidFinishLaunching:`, juste après `self.awake = [TMAwake new];`, ajouter :

```objc
    self.keyboardLock = [TMKeyboardLock new];
    __weak typeof(self) weakSelf = self;
    self.keyboardLock.onStateChange = ^{ [weakSelf pushData]; };
```

4. Dans `payload`, remplacer la ligne `@"tools":` ajoutée en tâche 1 par :

```objc
        @"tools": @{
            @"awake": @{ @"active": @(self.awake.isEnabled) },
            @"keyboardLock": @{
                @"available": @(self.keyboardLock.permissionGranted),
                @"active": @(self.keyboardLock.state == TMLockStateLocked)
            }
        },
```

5. Dans `userContentController:didReceiveScriptMessage:`, après le bloc `toggleAwake`, ajouter :

```objc
    if ([action isEqualToString:@"toggleKeyboardLock"]) {
        [self.statusPopover close];  // sinon le popover reste sous l'overlay, inutilisable
        [self.keyboardLock toggle];
    }
    if ([action isEqualToString:@"openAccessibilitySettings"]) [self.keyboardLock openAccessibilitySettings];
```

6. Dans `applicationWillTerminate:`, après `self.awake.enabled = NO;`, ajouter :

```objc
    [self.keyboardLock unlock];  // ne jamais laisser un overlay orphelin
```

- [ ] **Step 6: Ajouter le bouton au popover**

Dans `Resources/menubar.html`, ajouter ce CSS après la règle `.tool .glyph` :

```css
  .tool.unavailable{opacity:.55}
```

Puis remplacer la fonction `tools(t)` par :

```js
function tools(t){
  const btn=(action,glyph,label,active,cls='')=>`<button class="tool ${active?'on':''} ${cls}" onclick="send('${action}')"><span class="glyph">${glyph}</span>${label}</button>`;
  const awake=t?.awake||{}, lock=t?.keyboardLock||{};
  // Sans permission on n'affiche pas un verrou qui n'en est pas un : on affiche le chemin pour l'obtenir.
  const lockBtn=lock.available
    ? btn('toggleKeyboardLock','⌨',lock.active?'verrouillé':'verrou clavier',lock.active)
    : btn('openAccessibilitySettings','⌨','autoriser…',false,'unavailable');
  return btn('toggleAwake','☾',awake.active?'veille bloquée':'veille',awake.active)+lockBtn;
}
```

- [ ] **Step 7: Ajouter le module au build de l'app**

Dans `scripts/package-app.sh`, remplacer la ligne des sources par :

```bash
  "$ROOT/Native/Status.m" "$ROOT/Native/StatusQuota.m" "$ROOT/Native/StatusAwake.m" \
  "$ROOT/Native/StatusKeyboardLock.m" -o "$BUILD"
```

- [ ] **Step 8: Vérifier dans l'app réelle — sans aucun risque**

Le tap n'existe pas encore : **le clavier reste vivant pendant tout ce test.** C'est exactement l'intérêt de cet ordre.

```bash
./scripts/install-app.sh
```

À la main, dans l'ordre :

1. Cliquer l'icône Status → la rangée montre **veille** et **verrou clavier** (ou **autoriser…** si la permission Accessibilité manque encore).
2. Si **autoriser…** : cliquer, accorder Status dans Réglages Système > Confidentialité > Accessibilité, relancer l'app, revérifier que le bouton dit maintenant **verrou clavier**.
3. Cliquer **verrou clavier** → le popover se ferme, l'écran se couvre, le bouton « maintenir pour déverrouiller » apparaît au centre.
4. **Cliquer sec** le bouton → rien ne doit se passer. C'est le comportement voulu : un chiffon ne déverrouille pas.
5. **Maintenir 1 seconde** → le remplissage progresse, puis l'overlay disparaît.
6. Taper au clavier pendant l'overlay → **les touches fonctionnent encore** (le tap arrive en tâche 4).

- [ ] **Step 9: Commit**

```bash
git add Native/StatusKeyboardLock.h Native/StatusKeyboardLock.m Native/Status.m Resources/menubar.html scripts/package-app.sh
git commit -m "feat: overlay du verrou clavier et bouton de sortie à maintien"
```

---

## Task 4: Verrou clavier — le tap HID

La serrure, maintenant que la porte est prouvée.

**Files:**
- Modify: `Native/StatusKeyboardLock.m`

**Interfaces:**
- Consumes: `TMKeyboardLock` (tâche 3) — l'interface publique ne change pas.
- Produces: rien de nouveau. `-toggle` et `-unlock` gagnent l'effet réel de blocage.

- [ ] **Step 1: Ajouter le tap**

Dans `Native/StatusKeyboardLock.m`, ajouter en tête, après `#import "StatusKeyboardLock.h"` :

```objc
// Les événements « système » (touches média, luminosité, F-keys spéciales) ne sont pas un
// kCGEventType : c'est NX_SYSDEFINED, valeur 14. Le nommer ici évite de traîner un import IOKit
// privé pour une seule constante.
static const CGEventType TMEventTypeSystemDefined = (CGEventType)14;

// Le rappel du tap est une fonction C : il appelle -reenableTap avant que
// @implementation ne la définisse. Sans cette extension, le compilateur ne la trouve pas.
@interface TMKeyboardLock ()
- (void)reenableTap;
@end
```

Dans `@implementation TMKeyboardLock`, ajouter aux ivars :

```objc
    CFMachPortRef _tap;
    CFRunLoopSourceRef _tapSource;
```

Puis ajouter, avant `- (void)showOverlays` :

```objc
// Avale tout. macOS peut désactiver un tap sans prévenir (app trop lente à répondre, ou
// intervention utilisateur) : sans le réarmement ci-dessous, le verrou mourrait en silence en
// laissant l'overlay affiché — l'utilisateur croirait être protégé alors qu'il ne l'est plus.
static CGEventRef TMTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    TMKeyboardLock *lock = (__bridge TMKeyboardLock *)userInfo;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        [lock reenableTap];
        return event;
    }
    return NULL;
}

- (void)reenableTap {
    if (_tap) CGEventTapEnable(_tap, true);
}

- (BOOL)startTap {
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) |
                       CGEventMaskBit(kCGEventFlagsChanged) |
                       CGEventMaskBit(TMEventTypeSystemDefined);
    _tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                            mask, TMTapCallback, (__bridge void *)self);
    if (!_tap) return NO;  // permission révoquée entre la vérification et ici
    _tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _tap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), _tapSource, kCFRunLoopCommonModes);
    CGEventTapEnable(_tap, true);
    return YES;
}

- (void)stopTap {
    if (_tapSource) {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), _tapSource, kCFRunLoopCommonModes);
        CFRelease(_tapSource);
        _tapSource = NULL;
    }
    if (_tap) {
        CGEventTapEnable(_tap, false);
        CFRelease(_tap);
        _tap = NULL;
    }
}
```

- [ ] **Step 2: Brancher le tap sur le cycle de vie**

Dans `-toggle`, remplacer le corps de la branche verrouillage :

```objc
- (void)toggle {
    TMLockState next = TMLockStateAfterToggle(_state, self.permissionGranted);
    if (next == _state) { if (self.onStateChange) self.onStateChange(); return; }
    if (next == TMLockStateLocked) {
        // L'overlay ne s'affiche que si le tap a réellement pris : pas d'écran de verrou sans verrou.
        if (![self startTap]) {
            _state = TMLockStateBlocked;
            if (self.onStateChange) self.onStateChange();
            return;
        }
        _state = TMLockStateLocked;
        [self showOverlays];
    } else {
        _state = next;
        [self stopTap];
        [self hideOverlays];
    }
    if (self.onStateChange) self.onStateChange();
}
```

Et dans `-unlock`, ajouter `[self stopTap];` avant `[self hideOverlays];` :

```objc
- (void)unlock {
    if (_state != TMLockStateLocked) return;
    _state = TMLockStateUnlocked;
    [self stopTap];
    [self hideOverlays];
    if (self.onStateChange) self.onStateChange();
}
```

- [ ] **Step 3: Vérifier que les tests passent toujours**

Run: `./scripts/run-tests.sh 2>&1 | tail -3`
Expected: total sans échec.

- [ ] **Step 4: Vérifier dans l'app réelle**

**Le clavier va réellement mourir.** Deux sorties sont prouvées avant de commencer : le bouton à maintien (testé en tâche 3) et le garde-fou à 5 minutes. En dernier recours, depuis un autre appareil ou par SSH : `pkill -f "Status.app/Contents/MacOS/Status"`.

```bash
./scripts/install-app.sh
```

À la main :

1. Cliquer **verrou clavier**.
2. Taper n'importe quoi → **rien ne doit apparaître nulle part**.
3. Essayer **Cmd+Tab** → aucun changement d'application.
4. Essayer **Cmd+Espace** → pas de Spotlight.
5. Essayer les touches **luminosité** et **volume** → aucun effet (c'est `NX_SYSDEFINED` qui est avalé).
6. Maintenir le bouton 1 seconde → l'overlay disparaît, **et le clavier refonctionne immédiatement**.

Puis vérifier que le tap est bien démonté, et pas seulement caché :

Run: `pgrep -x Status >/dev/null && echo "Status tourne toujours — le clavier doit fonctionner"`
Expected: `Status tourne toujours — le clavier doit fonctionner`, et le clavier répond.

- [ ] **Step 5: Vérifier le garde-fou**

Ce filet n'est utile que s'il se déclenche vraiment. Il faut le voir.

1. Cliquer **verrou clavier**.
2. **Ne rien toucher pendant 5 minutes.**
3. L'overlay doit disparaître tout seul et le clavier revenir.

- [ ] **Step 6: Commit**

```bash
git add Native/StatusKeyboardLock.m
git commit -m "feat: tap HID du verrou clavier avec réarmement et garde-fou"
```

---

## Ce que ce plan ne couvre pas

À dire à l'utilisateur plutôt qu'à laisser découvrir :

- **Le bouton d'alimentation et Touch ID restent actifs** pendant le verrou. Limite de macOS, pas du plan.
- **L'overlay recouvre la barre des menus** : Pomme > Forcer à quitter est hors d'atteinte pendant le verrou.
- **Le trackpad reste actif** — c'est la sortie, donc il ne peut pas être nettoyé pendant le verrou.
- **Les tests sont maigres et le savent.** Le tap, l'overlay et l'assertion IOKit sont vérifiés en exécutant, pas en testant. Les étapes de vérification manuelle ci-dessus sont la vraie couverture ; ne pas les sauter.
