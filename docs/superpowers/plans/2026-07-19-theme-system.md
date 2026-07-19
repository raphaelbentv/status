# Système de thèmes (Phosphore, Synthwave, Circuit, Holograme, Ion) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the five approved theme mockups (01 Phosphore, 02 Synthwave, 03 Circuit, 04 Holograme, 05 Ion) as real, switchable skins for the popover (`Resources/menubar.html`) and dashboard (`Resources/dashboard.html`), selectable from a new "Thème" setting, alongside the existing default (renamed `blueprint`).

**Architecture:** Both HTML files already read every color through CSS custom properties defined in a single `:root{...}` block (no hardcoded colors inside component rules) — confirmed by inspection. This means a theme is just a different set of custom-property values. We extract those values into a new shared stylesheet, `Resources/themes.css`, with one base block (`:root`, the current look, renamed `blueprint`) and one `[data-theme="..."]` override block per new theme. Both HTML files link the stylesheet and set `document.documentElement.dataset.theme` from a new `theme` preference pushed by the native layer, exactly like the existing `menuBarMetric` preference (`Native/Status.m`). A handful of *new* tokens (`--font`, `--radius`, `--rail-fill`, `--value-glow`, `--edge-glow`, `--clip`, `--panel-bg`, `--panel-bg-strong`, `--bg-image`, `--bg-size`) are introduced so the neon themes can add glow, angular clipping, and gradients without touching business-logic JS. A theme picker (swatch grid, not a segmented bar — six labels would overflow like the metric picker once did) is added to the dashboard's Réglages view.

**Tech Stack:** Plain HTML/CSS/JS (no build step, loaded via `WKWebView loadFileURL`), Objective-C (`Native/Status.m`), `NSUserDefaults` for persistence.

## Global Constraints

- No new build tooling: `themes.css` must be a static file dropped in `Resources/` and copied by `scripts/package-app.sh` exactly like `menubar.html`/`dashboard.html` are today.
- Preserve the current look pixel-for-pixel as the `blueprint` theme — it must remain the default (`NSUserDefaults registerDefaults`) so existing users see no change until they opt in.
- Only six theme ids are ever valid: `blueprint`, `phosphore`, `synthwave`, `circuit`, `holograme`, `ion`. The native layer must reject anything else (mirrors how `setMenuBarMetric` is trusted input from the webview and should not be written blindly).
- `color-mix(in srgb, ...)` is already used in both HTML files today, so it's safe to reuse for the new tokens (no new browser-support risk).
- French UI copy throughout (this app's convention — see any existing string in `Resources/dashboard.html`).
- There is no JS test harness in this repo (`Tests/` only covers native Objective-C logic and the Python bridge — confirmed via `scripts/run-tests.sh`). Verification for the HTML/CSS/JS tasks is therefore manual: open the file in the Browser tool and inject mock data through the existing `window.StatusMenu.update(...)` / `window.StatusApp.update(...)` entry points (already used by the real native layer), and visually confirm.

---

## File Structure

- **Create:** `Resources/themes.css` — the six theme token blocks. Nothing else references it except the two HTML files' `<head>`.
- **Modify:** `Resources/menubar.html` — link the stylesheet, trim the old hardcoded `:root`, apply `data-theme`, wire the new tokens into `.provider`, `.value`, `.name`, `.rail i`, `.mtile`, `.tool`, `.footer`, `.account-action`, `.footer-row > button`, `.popover`.
- **Modify:** `Resources/dashboard.html` — same treatment for `.shell`, `.hero`, `.hero-value`, `.provider-block`, `.connection-panel`, `.quota-track i`, `.quota-top strong`, `.setting`, plus a new theme-picker row and swatch CSS/JS in the Réglages view.
- **Modify:** `Native/Status.m` — register the `theme` default, accept a `setTheme` action, expose `theme` in the `payload` prefs dict.
- **Modify:** `scripts/package-app.sh` — copy `themes.css` into the built `.app` bundle.

---

### Task 1: `Resources/themes.css` — the six theme token blocks

**Files:**
- Create: `Resources/themes.css`

**Interfaces:**
- Produces: CSS custom properties consumed by `Resources/menubar.html` and `Resources/dashboard.html`: `--bg --sidebar --panel-bg --panel-bg-strong --text --muted --hair --hair-strong --soft --soft-hover --blue --blue-soft --purple --purple-soft --green --amber --danger --chart-a --chart-b --grid --bg-image --bg-size --font --radius --rail-fill --value-glow --edge-glow --clip`, keyed off `:root` (base = `blueprint`) and `[data-theme="phosphore|synthwave|circuit|holograme|ion"]`.

- [ ] **Step 1: Write the file**

```css
/* Status — jetons de thème.
   Un seul bloc de base (:root, thème « blueprint », identique à l'apparence historique de
   l'app) puis un bloc [data-theme="…"] par thème qui ne redéfinit que ce qui change. L'ordre
   des blocs compte : à spécificité égale avec :root, un bloc [data-theme] placé après lui
   l'emporte dans la cascade — ne réordonnez pas ces blocs sans le garder en tête. */

:root{
  color-scheme:dark;
  --bg:#12161C;--sidebar:#0E1217;--panel-bg:rgba(18,22,28,.72);--panel-bg-strong:rgba(18,22,28,.9);
  --text:#CBD5E1;--muted:#5B6673;
  --hair:rgba(103,232,249,.14);--hair-strong:rgba(103,232,249,.28);
  --soft:rgba(103,232,249,.05);--soft-hover:rgba(103,232,249,.1);
  --blue:#67E8F9;--blue-soft:rgba(103,232,249,.07);--purple:#A78BFA;--purple-soft:rgba(167,139,250,.07);
  --green:#5EEAD4;--amber:#FBBF24;--danger:#FB7185;
  --chart-a:#0891B2;--chart-b:#8B5CF6;
  --grid:rgba(103,232,249,.045);
  --font:ui-monospace,"SF Mono","Menlo",monospace;
  --radius:2px;
  --rail-fill:repeating-linear-gradient(90deg,var(--provider) 0 2px,color-mix(in srgb,var(--provider) 45%,transparent) 2px 4px);
}

[data-theme="phosphore"]{
  --bg:#050B06;--sidebar:#020503;--panel-bg:rgba(89,255,176,.04);--panel-bg-strong:rgba(2,5,3,.9);
  --text:#59FFB0;--muted:#2E8F5E;
  --hair:rgba(89,255,176,.18);--hair-strong:rgba(89,255,176,.28);
  --soft:rgba(89,255,176,.05);--soft-hover:rgba(89,255,176,.1);
  --blue:#59FFB0;--blue-soft:rgba(89,255,176,.08);--purple:#2E8F5E;--purple-soft:rgba(46,143,94,.12);
  --green:#59FFB0;--amber:#FBBF24;--danger:#FF6B6B;
  --chart-a:#59FFB0;--chart-b:#2E8F5E;
  --grid:rgba(89,255,176,.035);
  --font:ui-monospace,"SF Mono","Menlo",monospace;
  --radius:0px;
  --bg-image:repeating-linear-gradient(0deg,rgba(89,255,176,.035) 0 1px,transparent 1px 3px);
}

[data-theme="synthwave"]{
  --bg:#0B0620;--sidebar:#080417;--panel-bg:rgba(255,60,214,.05);--panel-bg-strong:rgba(8,4,23,.92);
  --text:#F0D9FF;--muted:#7C6FA8;
  --hair:rgba(255,60,180,.22);--hair-strong:rgba(255,60,180,.32);
  --soft:rgba(255,60,180,.06);--soft-hover:rgba(255,60,180,.12);
  --blue:#3CF2FF;--blue-soft:rgba(60,242,255,.08);--purple:#FF3CD6;--purple-soft:rgba(255,60,214,.08);
  --green:#5EEAD4;--amber:#FBBF24;--danger:#FF5C7A;
  --chart-a:#3CF2FF;--chart-b:#FF3CD6;
  --grid:rgba(255,60,220,.05);
  --font:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
  --radius:0px;
  --rail-fill:linear-gradient(90deg,var(--provider),color-mix(in srgb,var(--provider) 55%,#FF9E5C 45%));
  --value-glow:0 0 14px color-mix(in srgb,var(--provider) 70%,transparent);
  --edge-glow:0 0 8px color-mix(in srgb,var(--provider) 55%,transparent);
}

[data-theme="circuit"]{
  --bg:#050A10;--sidebar:#03060A;--panel-bg:rgba(180,255,60,.04);--panel-bg-strong:rgba(3,6,10,.92);
  --text:#C9F7FF;--muted:#5C7A66;
  --hair:rgba(180,255,60,.22);--hair-strong:rgba(180,255,60,.32);
  --soft:rgba(180,255,60,.05);--soft-hover:rgba(180,255,60,.1);
  --blue:#B4FF3C;--blue-soft:rgba(180,255,60,.08);--purple:#3CD6FF;--purple-soft:rgba(60,214,255,.08);
  --green:#B4FF3C;--amber:#FBBF24;--danger:#FF6B6B;
  --chart-a:#B4FF3C;--chart-b:#3CD6FF;
  --grid:rgba(180,255,60,.04);
  --font:ui-monospace,"SF Mono","Menlo",monospace;
  --radius:0px;
  --rail-fill:var(--provider);
  --edge-glow:0 0 6px color-mix(in srgb,var(--provider) 60%,transparent);
  --clip:polygon(0 0,calc(100% - 10px) 0,100% 10px,100% 100%,10px 100%,0 calc(100% - 10px));
}

[data-theme="holograme"]{
  --bg:#0A0F1C;--sidebar:#0A0F1C;--panel-bg:rgba(124,200,255,.07);--panel-bg-strong:rgba(10,15,28,.85);
  --text:#E4E9FF;--muted:#8B93B8;
  --hair:rgba(255,255,255,.1);--hair-strong:rgba(255,255,255,.16);
  --soft:rgba(255,255,255,.05);--soft-hover:rgba(255,255,255,.09);
  --blue:#7CC8FF;--blue-soft:rgba(124,200,255,.1);--purple:#E29AFF;--purple-soft:rgba(226,154,255,.1);
  --green:#5EEAD4;--amber:#FBBF24;--danger:#FF9AB0;
  --chart-a:#7CC8FF;--chart-b:#E29AFF;
  --grid:transparent;
  --font:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
  --radius:14px;
  --bg-image:radial-gradient(55% 55% at 10% -10%,rgba(80,180,255,.2),transparent 60%),radial-gradient(60% 55% at 100% 20%,rgba(200,110,255,.18),transparent 60%),radial-gradient(60% 55% at 40% 120%,rgba(255,120,190,.14),transparent 60%);
  --bg-size:auto;
  --rail-fill:linear-gradient(90deg,color-mix(in srgb,var(--provider) 55%,white 45%),var(--provider));
}

[data-theme="ion"]{
  --bg:#020306;--sidebar:#020306;--panel-bg:transparent;--panel-bg-strong:transparent;
  --text:#CFEFFF;--muted:#4F7480;
  --hair:rgba(120,225,255,.25);--hair-strong:rgba(120,225,255,.4);
  --soft:transparent;--soft-hover:rgba(120,225,255,.06);
  --blue:#78E1FF;--blue-soft:rgba(120,225,255,.08);--purple:#B98CFF;--purple-soft:rgba(185,140,255,.08);
  --green:#78E1FF;--amber:#FBBF24;--danger:#FF5C5C;
  --chart-a:#78E1FF;--chart-b:#B98CFF;
  --grid:transparent;
  --font:ui-monospace,"SF Mono","Menlo",monospace;
  --radius:0px;
  --rail-fill:var(--provider);
  --value-glow:0 0 16px color-mix(in srgb,var(--provider) 70%,transparent);
  --edge-glow:0 0 12px color-mix(in srgb,var(--provider) 30%,transparent) inset;
  --bg-image:none;
  --bg-size:auto;
}
```

- [ ] **Step 2: Verify it parses**

Run: `python3 -c "import re,sys; s=open('Resources/themes.css').read(); assert s.count('{')==s.count('}'), 'unbalanced braces'; print('ok', s.count('{'), 'blocks')"`
Expected: `ok 6 blocks`

- [ ] **Step 3: Commit**

```bash
git add Resources/themes.css
git commit -m "feat: ajoute les jetons des cinq thèmes néon dans themes.css"
```

---

### Task 2: Wire `Resources/menubar.html` to the shared theme tokens

**Files:**
- Modify: `Resources/menubar.html:2-73` (head + style block), `Resources/menubar.html:128` (`renderMenu`)

**Interfaces:**
- Consumes: the CSS custom properties produced by Task 1 (`Resources/themes.css`).
- Produces: `document.documentElement.dataset.theme` set from `data.prefs.theme` — Task 4 (dashboard) and Task 5 (native) rely on this same preference name.

- [ ] **Step 1: Link the stylesheet and trim the old hardcoded root**

In `Resources/menubar.html`, replace:

```html
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  /* Direction « Blueprint » — même système que dashboard.html : grille cyan sur ardoise,
     barres hachurées, cyan = OpenAI, violet = Claude. */
  :root{color-scheme:dark;--bg:#12161C;--text:#CBD5E1;--muted:#5B6673;--hair:rgba(103,232,249,.14);--hair-strong:rgba(103,232,249,.28);--soft:rgba(103,232,249,.05);--blue:#67E8F9;--purple:#A78BFA;--amber:#FBBF24;--danger:#FB7185;--grid:rgba(103,232,249,.045)}
```

with:

```html
<meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="stylesheet" href="themes.css">
<style>
  /* Le thème actif vient de themes.css ([data-theme] sur <html>, poussé par renderMenu()) ;
     cyan = OpenAI, violet = Claude reste la convention par défaut, mais chaque thème peut
     réassigner --blue/--purple à ses deux teintes propres. */
```

- [ ] **Step 2: Route the body background/font through the new tokens**

Replace:

```html
  html,body{width:100%;height:100%;margin:0;overflow:hidden;color:var(--text);font:12.5px/1.4 ui-monospace,"SF Mono","Menlo",monospace;
    background:linear-gradient(var(--grid) 1px,transparent 1px),linear-gradient(90deg,var(--grid) 1px,transparent 1px),var(--bg);
    background-size:22px 22px,22px 22px,auto}
```

with:

```html
  html,body{width:100%;height:100%;margin:0;overflow:hidden;color:var(--text);font:12.5px/1.4 var(--font);
    background:var(--bg);
    background-image:var(--bg-image,linear-gradient(var(--grid) 1px,transparent 1px),linear-gradient(90deg,var(--grid) 1px,transparent 1px));
    background-size:var(--bg-size,22px 22px,22px 22px)}
```

- [ ] **Step 3: Let the popover frame clip itself for Circuit**

Replace:

```html
  .popover{height:100%;display:flex;flex-direction:column}
```

with:

```html
  .popover{height:100%;display:flex;flex-direction:column;clip-path:var(--clip,none)}
```

- [ ] **Step 4: Route panel backgrounds through `--panel-bg`/`--panel-bg-strong`**

Replace each of these (same file):

```html
  .provider{padding:18px 16px 14px;text-align:center;min-width:0;position:relative;background:rgba(18,22,28,.55)}
```
→
```html
  .provider{padding:18px 16px 14px;text-align:center;min-width:0;position:relative;background:var(--panel-bg)}
```

```html
  .mtile{flex:1;background:rgba(18,22,28,.85);padding:7px 8px 6px;min-width:0}
```
→
```html
  .mtile{flex:1;background:var(--panel-bg-strong);padding:7px 8px 6px;min-width:0}
```

```html
  .tool{flex:1;border:0;background:rgba(18,22,28,.85);color:var(--muted);padding:10px 6px;cursor:pointer;font:inherit;font-size:9.5px;display:flex;flex-direction:column;align-items:center;gap:5px;text-transform:lowercase;letter-spacing:.05em}
```
→
```html
  .tool{flex:1;border:0;background:var(--panel-bg-strong);color:var(--muted);padding:10px 6px;cursor:pointer;font:inherit;font-size:9.5px;display:flex;flex-direction:column;align-items:center;gap:5px;text-transform:lowercase;letter-spacing:.05em}
```

```html
  .footer{border-top:1px solid var(--hair-strong);display:flex;flex-direction:column;gap:7px;padding:9px 10px;background:rgba(14,18,23,.9);flex:none}
```
→
```html
  .footer{border-top:1px solid var(--hair-strong);display:flex;flex-direction:column;gap:7px;padding:9px 10px;background:var(--panel-bg-strong);flex:none}
```

- [ ] **Step 5: Add glow tokens to the hero numbers and the measurement rail**

Replace:

```html
  .name{font-size:10px;color:var(--provider);font-weight:700;margin-bottom:10px;text-transform:lowercase;letter-spacing:.06em}
  .value .unit{font-size:.42em;margin-left:.08em;opacity:.65;font-weight:400}
  .value{font-size:44px;line-height:1;font-weight:700;letter-spacing:-.02em;font-variant-numeric:tabular-nums;color:var(--provider)}
```
→
```html
  .name{font-size:10px;color:var(--provider);font-weight:700;margin-bottom:10px;text-transform:lowercase;letter-spacing:.06em;text-shadow:var(--value-glow,none)}
  .value .unit{font-size:.42em;margin-left:.08em;opacity:.65;font-weight:400}
  .value{font-size:44px;line-height:1;font-weight:700;letter-spacing:-.02em;font-variant-numeric:tabular-nums;color:var(--provider);text-shadow:var(--value-glow,none)}
```

Replace:

```html
  .subgauge-head strong{font-size:13px;color:var(--provider);font-variant-numeric:tabular-nums;text-transform:none;letter-spacing:0}
  /* Même trame hachurée que la fenêtre principale : une mesure, pas une progression. */
  .rail{height:10px;background:rgba(255,255,255,.03);border:1px solid var(--hair);margin-top:7px;overflow:hidden}
  .rail i{display:block;height:100%;background:repeating-linear-gradient(90deg,var(--provider) 0 2px,color-mix(in srgb,var(--provider) 45%,transparent) 2px 4px);transition:width .3s ease}
```
→
```html
  .subgauge-head strong{font-size:13px;color:var(--provider);font-variant-numeric:tabular-nums;text-transform:none;letter-spacing:0;text-shadow:var(--value-glow,none)}
  /* Même trame que la fenêtre principale : une mesure, pas une progression — sauf thème qui
     remplace --rail-fill par un aplat ou un dégradé (voir themes.css). */
  .rail{height:10px;background:rgba(255,255,255,.03);border:1px solid var(--hair);margin-top:7px;overflow:hidden}
  .rail i{display:block;height:100%;background:var(--rail-fill);box-shadow:var(--edge-glow,none);transition:width .3s ease}
```

- [ ] **Step 6: Use `--radius` instead of the hardcoded `2px`**

Replace each occurrence in the same file (three call sites):

```html
  .account-action{border:1px solid var(--provider);color:var(--provider);background:color-mix(in srgb,var(--provider) 10%,transparent);border-radius:2px;padding:6px 9px;margin-top:9px;cursor:pointer;font-size:10px;font-weight:700}
```
→
```html
  .account-action{border:1px solid var(--provider);color:var(--provider);background:color-mix(in srgb,var(--provider) 10%,transparent);border-radius:var(--radius);padding:6px 9px;margin-top:9px;cursor:pointer;font-size:10px;font-weight:700}
```

```html
  .footer-row > button.sync{flex:1;min-width:0;text-align:left;color:var(--muted);font-size:9.5px;
    white-space:nowrap;overflow:hidden;text-overflow:ellipsis;border:1px solid transparent;background:transparent;
    padding:5px 6px;border-radius:2px;cursor:pointer;font-family:inherit}
```
→
```html
  .footer-row > button.sync{flex:1;min-width:0;text-align:left;color:var(--muted);font-size:9.5px;
    white-space:nowrap;overflow:hidden;text-overflow:ellipsis;border:1px solid transparent;background:transparent;
    padding:5px 6px;border-radius:var(--radius);cursor:pointer;font-family:inherit}
```

```html
  .footer-row > button{border:1px solid transparent;background:transparent;padding:6px 7px;border-radius:2px;cursor:pointer;color:var(--muted);white-space:nowrap;flex:none}
```
→
```html
  .footer-row > button{border:1px solid transparent;background:transparent;padding:6px 7px;border-radius:var(--radius);cursor:pointer;color:var(--muted);white-space:nowrap;flex:none}
```

- [ ] **Step 7: Apply the active theme when the popover renders**

In `function renderMenu(data){`, add the theme line first:

```js
function renderMenu(data){
  document.documentElement.dataset.theme=data.prefs?.theme||'blueprint';
  document.querySelector('#providers').innerHTML=provider('openai','OpenAI',data.accounts?.openai)+provider('claude','Claude',data.accounts?.claude);
```

(only the first line is new — the rest of the function body is unchanged).

- [ ] **Step 8: Manual verification**

Open `Resources/menubar.html` directly in the Browser tool (`file://` path — no dev server needed), then in its console run:

```js
document.documentElement.dataset.theme='synthwave';
window.StatusMenu.update({
  accounts:{
    openai:{connected:true,windows:[{windowId:'seven_day',usedPercent:78,resetsAt:Date.now()/1000+86400}]},
    claude:{authenticated:true,windows:[
      {windowId:'seven_day',usedPercent:51,resetsAt:Date.now()/1000+3600*40},
      {windowId:'five_hour',usedPercent:34,durationMinutes:300}
    ]}
  },
  prefs:{menuBarMetric:'claude:weekly',theme:'synthwave'},
  tools:{},
  updatedAt:Date.now()
});
```

Expected: the popover redraws in the Synthwave palette (magenta/cyan, glowing numbers). Repeat with `'phosphore'`, `'circuit'`, `'holograme'`, `'ion'`, and `'blueprint'` — confirm `'blueprint'` looks pixel-identical to how the file rendered before this task (compare against `git stash`/`git diff` if unsure).

- [ ] **Step 9: Commit**

```bash
git add Resources/menubar.html
git commit -m "feat: le popover consomme themes.css et applique le thème actif"
```

---

### Task 3: Wire `Resources/dashboard.html` to the shared theme tokens

**Files:**
- Modify: `Resources/dashboard.html:2-12` (head), `Resources/dashboard.html:13-16,19,32,35-41,45,57,68,73,76,79,86-87,91` (style block), `Resources/dashboard.html:211` (`render`)

**Interfaces:**
- Consumes: same tokens as Task 2.
- Produces: same `document.documentElement.dataset.theme` contract as Task 2 — both webviews must always show the same theme since they read the same `prefs.theme`.

- [ ] **Step 1: Link the stylesheet and trim the old hardcoded root**

Replace:

```html
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  /* Direction « Blueprint » : plan technique. Grille cyan sur ardoise, tracés fins, monospace.
     Le cyan appartient à OpenAI, le violet à Claude ; la couleur ne sert qu'aux données. */
  /* --chart-a/--chart-b : marques de graphique du Moniteur, plus sombres que les couleurs
     d'interface — paire validée (bande de luminance, CVD, contraste) sur ce fond. */
  :root{color-scheme:dark;--bg:#12161C;--sidebar:#0E1217;--text:#CBD5E1;--muted:#5B6673;--hair:rgba(103,232,249,.14);--hair-strong:rgba(103,232,249,.28);--soft:rgba(103,232,249,.05);--soft-hover:rgba(103,232,249,.1);--blue:#67E8F9;--blue-soft:rgba(103,232,249,.07);--purple:#A78BFA;--purple-soft:rgba(167,139,250,.07);--green:#5EEAD4;--amber:#FBBF24;--danger:#FB7185;--grid:rgba(103,232,249,.045);--chart-a:#0891B2;--chart-b:#8B5CF6}
```

with:

```html
<meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="stylesheet" href="themes.css">
<style>
  /* Le thème actif vient de themes.css ([data-theme] sur <html>, poussé par render()).
     --chart-a/--chart-b restent les marques de graphique du Moniteur, définies par thème. */
```

- [ ] **Step 2: Route body font and shell background through the new tokens**

Replace:

```html
  *{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden;background:var(--bg);color:var(--text);font:13px/1.45 ui-monospace,"SF Mono","Menlo",monospace}button,select{font:inherit;color:inherit}
  .shell{height:100%;display:grid;grid-template-columns:210px 1fr;padding-top:28px;background:
    linear-gradient(var(--grid) 1px,transparent 1px),
    linear-gradient(90deg,var(--grid) 1px,transparent 1px),
    var(--bg);background-size:22px 22px,22px 22px,auto}
```

with:

```html
  *{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden;background:var(--bg);color:var(--text);font:13px/1.45 var(--font)}button,select{font:inherit;color:inherit}
  .shell{height:100%;display:grid;grid-template-columns:210px 1fr;padding-top:28px;background:var(--bg);
    background-image:var(--bg-image,linear-gradient(var(--grid) 1px,transparent 1px),linear-gradient(90deg,var(--grid) 1px,transparent 1px));
    background-size:var(--bg-size,22px 22px,22px 22px)}
```

- [ ] **Step 3: `--radius` instead of the hardcoded `2px` (eight call sites)**

Replace each of these lines in the same file:

```html
  .nav button,.sidebar-bottom button{position:relative;width:100%;border:1px solid transparent;background:transparent;border-radius:2px;padding:9px 12px 9px 32px;text-align:left;color:var(--muted);cursor:pointer;margin-bottom:3px}
```
→ `border-radius:var(--radius)` (same line otherwise)

```html
  .button{border:1px solid var(--hair-strong);border-radius:2px;background:var(--soft);padding:7px 10px;cursor:pointer;color:var(--blue)}
```
→ `border-radius:var(--radius)`

```html
  .provider-block{border:1px solid var(--hair);border-radius:2px;background:rgba(18,22,28,.72);padding:20px;position:relative}
```
→ (also see Step 4 for the background change) `border-radius:var(--radius)`

```html
  .connection-panel{border:1px solid var(--hair);border-radius:2px;background:rgba(18,22,28,.72);padding:22px;min-height:300px;position:relative}
```
→ (also see Step 4) `border-radius:var(--radius)`

```html
  .account-action{border:1px solid var(--hair-strong);border-radius:2px;background:var(--soft);padding:6px 9px;cursor:pointer;font-size:10px;color:var(--text)}
```
→ `border-radius:var(--radius)`

```html
  .quota-card{padding:11px 12px;border:1px solid var(--hair);border-radius:2px;background:var(--soft)}
```
→ `border-radius:var(--radius)`

```html
  .quota-empty{padding:13px;border:1px dashed var(--hair-strong);border-radius:2px}
```
→ `border-radius:var(--radius)`

```html
  .settings{display:flex;flex-direction:column;gap:1px;background:var(--hair);border:1px solid var(--hair);border-radius:2px;overflow:hidden}
```
→ `border-radius:var(--radius)`

```html
  .segmented{display:flex;border:1px solid var(--hair-strong);border-radius:2px;overflow:hidden;flex:none}
```
→ `border-radius:var(--radius)`

- [ ] **Step 4: Route panel backgrounds, add clip-path and glow to hero/blocks**

Replace:

```html
  .hero{position:relative;padding:24px 20px;border-bottom:1px solid var(--hair-strong);border-left:1px solid var(--hair);border-right:1px solid var(--hair);margin-top:-1px;background:linear-gradient(90deg,color-mix(in srgb,var(--hero,var(--blue)) 7%,transparent),transparent 60%)}
  .hero:before{content:"";position:absolute;left:0;top:0;bottom:0;width:3px;background:repeating-linear-gradient(0deg,var(--hero,var(--blue)) 0 4px,transparent 4px 8px)}
  .hero-line{display:flex;align-items:baseline;gap:18px;flex-wrap:wrap}
  .hero-value .unit{font-size:.4em;margin-left:.08em;opacity:.65;font-weight:400}
  .hero-value{font-size:52px;font-weight:700;line-height:.94;letter-spacing:-.02em;font-variant-numeric:tabular-nums;color:var(--hero,var(--blue))}
```
→
```html
  .hero{position:relative;padding:24px 20px;border-bottom:1px solid var(--hair-strong);border-left:1px solid var(--hair);border-right:1px solid var(--hair);margin-top:-1px;background:linear-gradient(90deg,color-mix(in srgb,var(--hero,var(--blue)) 7%,transparent),transparent 60%);clip-path:var(--clip,none);box-shadow:var(--edge-glow,none)}
  .hero:before{content:"";position:absolute;left:0;top:0;bottom:0;width:3px;background:repeating-linear-gradient(0deg,var(--hero,var(--blue)) 0 4px,transparent 4px 8px)}
  .hero-line{display:flex;align-items:baseline;gap:18px;flex-wrap:wrap}
  .hero-value .unit{font-size:.4em;margin-left:.08em;opacity:.65;font-weight:400}
  .hero-value{font-size:52px;font-weight:700;line-height:.94;letter-spacing:-.02em;font-variant-numeric:tabular-nums;color:var(--hero,var(--blue));text-shadow:var(--value-glow,none)}
```

Replace:

```html
  .provider-block{border:1px solid var(--hair);border-radius:2px;background:rgba(18,22,28,.72);padding:20px;position:relative}
```
with (radius already updated in Step 3 — apply both changes together):
```html
  .provider-block{border:1px solid var(--hair);border-radius:var(--radius);background:var(--panel-bg);padding:20px;position:relative;clip-path:var(--clip,none)}
```

Replace:

```html
  .connection-panel{border:1px solid var(--hair);border-radius:2px;background:rgba(18,22,28,.72);padding:22px;min-height:300px;position:relative}
```
with:
```html
  .connection-panel{border:1px solid var(--hair);border-radius:var(--radius);background:var(--panel-bg);padding:22px;min-height:300px;position:relative;clip-path:var(--clip,none)}
```

Replace:

```html
  .setting{display:flex;align-items:center;gap:20px;padding:16px 18px;background:rgba(18,22,28,.9)}
```
with:
```html
  .setting{display:flex;align-items:center;gap:20px;padding:16px 18px;background:var(--panel-bg-strong);flex-wrap:wrap}
```

(`flex-wrap:wrap` is needed so the new theme-swatch grid — Task 3 Step 6 — doesn't force the row to overflow horizontally on narrower windows.)

- [ ] **Step 5: Glow on the rail fill and quota numbers**

Replace:

```html
  .quota-top span{font-weight:700;font-size:11px;color:var(--text)}
  .quota-top strong{font-variant-numeric:tabular-nums;color:var(--provider)}
  /* Barre hachurée : la trame dit « mesure », pas « barre de progression ». */
  .quota-track{height:14px;background:rgba(255,255,255,.03);border:1px solid var(--hair);margin:8px 0 6px;overflow:hidden}
  .quota-track i{display:block;height:100%;background:repeating-linear-gradient(90deg,var(--provider) 0 2px,color-mix(in srgb,var(--provider) 45%,transparent) 2px 4px);transition:width .3s ease}
```
with:
```html
  .quota-top span{font-weight:700;font-size:11px;color:var(--text)}
  .quota-top strong{font-variant-numeric:tabular-nums;color:var(--provider);text-shadow:var(--value-glow,none)}
  /* Trame par défaut : la mesure dit « mesure », pas « barre de progression » — un thème peut
     remplacer --rail-fill par un aplat ou un dégradé (voir themes.css). */
  .quota-track{height:14px;background:rgba(255,255,255,.03);border:1px solid var(--hair);margin:8px 0 6px;overflow:hidden}
  .quota-track i{display:block;height:100%;background:var(--rail-fill);box-shadow:var(--edge-glow,none);transition:width .3s ease}
```

- [ ] **Step 6: Theme picker — CSS**

Add right after the `.segmented`/`.seg` rules:

```html
  .theme-swatch-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:8px;flex:1;min-width:220px}
  .theme-swatch{display:flex;align-items:center;gap:7px;border:1px solid var(--hair);border-radius:var(--radius);background:var(--soft);padding:8px 10px;cursor:pointer;color:var(--text);font:inherit;font-size:11px;text-align:left}
  .theme-swatch:hover{background:var(--soft-hover);border-color:var(--hair-strong)}
  .theme-swatch.on{border-color:var(--hair-strong);background:var(--soft-hover);font-weight:700}
  .theme-swatch .dot{width:7px;height:7px;border-radius:50%;flex:none}
```

- [ ] **Step 7: Theme picker — JS metadata + settings row**

Replace:

```js
const PROVIDERS=[{id:'openai',name:'OpenAI'},{id:'claude',name:'Claude'}];
let appData=null,currentView='overview';
```
with:
```js
const PROVIDERS=[{id:'openai',name:'OpenAI'},{id:'claude',name:'Claude'}];
// Gardez ces couleurs synchronisées avec Resources/themes.css : le JS ne peut pas lire les
// jetons d'un thème non actif, donc l'aperçu de chaque pastille est dupliqué ici à la main.
const THEMES=[
  {id:'blueprint',label:'Blueprint',blue:'#67E8F9',purple:'#A78BFA'},
  {id:'phosphore',label:'Phosphore',blue:'#59FFB0',purple:'#2E8F5E'},
  {id:'synthwave',label:'Synthwave',blue:'#3CF2FF',purple:'#FF3CD6'},
  {id:'circuit',label:'Circuit',blue:'#B4FF3C',purple:'#3CD6FF'},
  {id:'holograme',label:'Holograme',blue:'#7CC8FF',purple:'#E29AFF'},
  {id:'ion',label:'Ion',blue:'#78E1FF',purple:'#B98CFF'}
];
let appData=null,currentView='overview';
```

Replace:

```js
function settingsView(data){const p=data.prefs||{},metric=p.menuBarMetric||'claude:weekly',opt=(v,l)=>`<button class="seg ${metric===v?'on':''}" onclick="send('setMenuBarMetric',{value:'${v}'})">${l}</button>`;return `<div class="toolbar"><h1>Réglages</h1></div><div class="section-head"><div><h2>Comportement</h2><p>Ces choix sont conservés entre les lancements.</p></div></div><div class="settings">
  <div class="setting"><div class="setting-copy"><strong>Lancer au démarrage</strong><small>Sans cela, les jauges ne se mettent plus à jour après un redémarrage tant que Status n’est pas ouvert.</small></div><button class="button ${p.launchAtLogin?'on':''}" onclick="send('toggleLaunchAtLogin')">${p.launchAtLogin?'Activé':'Désactivé'}</button></div>
```
with:
```js
function settingsView(data){const p=data.prefs||{},metric=p.menuBarMetric||'claude:weekly',opt=(v,l)=>`<button class="seg ${metric===v?'on':''}" onclick="send('setMenuBarMetric',{value:'${v}'})">${l}</button>`,theme=p.theme||'blueprint',themeSwatches=THEMES.map(t=>`<button class="theme-swatch ${theme===t.id?'on':''}" onclick="send('setTheme',{value:'${t.id}'})"><span class="dot" style="background:${t.blue}"></span><span class="dot" style="background:${t.purple}"></span>${t.label}</button>`).join('');return `<div class="toolbar"><h1>Réglages</h1></div><div class="section-head"><div><h2>Comportement</h2><p>Ces choix sont conservés entre les lancements.</p></div></div><div class="settings">
  <div class="setting"><div class="setting-copy"><strong>Thème</strong><small>Habillage visuel du popover et du tableau de bord.</small></div><div class="theme-swatch-grid">${themeSwatches}</div></div>
  <div class="setting"><div class="setting-copy"><strong>Lancer au démarrage</strong><small>Sans cela, les jauges ne se mettent plus à jour après un redémarrage tant que Status n’est pas ouvert.</small></div><button class="button ${p.launchAtLogin?'on':''}" onclick="send('toggleLaunchAtLogin')">${p.launchAtLogin?'Activé':'Désactivé'}</button></div>
```

- [ ] **Step 8: Apply the active theme when the dashboard renders**

Replace:

```js
function render(){if(!appData)return;document.querySelector('#overview').innerHTML=overview(appData);
```
with:
```js
function render(){if(!appData)return;document.documentElement.dataset.theme=appData.prefs?.theme||'blueprint';document.querySelector('#overview').innerHTML=overview(appData);
```

- [ ] **Step 9: Manual verification**

Open `Resources/dashboard.html` in the Browser tool and run:

```js
window.StatusApp.update({
  accounts:{
    openai:{connected:true,windows:[{windowId:'seven_day',usedPercent:78,resetsAt:Date.now()/1000+86400,label:'Semaine'}]},
    claude:{authenticated:true,trackingConfigured:true,windows:[
      {windowId:'seven_day',usedPercent:51,resetsAt:Date.now()/1000+3600*40,label:'Semaine'},
      {windowId:'five_hour',usedPercent:34,durationMinutes:300,label:'5 h'}
    ]}
  },
  prefs:{menuBarMetric:'claude:weekly',theme:'holograme',launchAtLogin:true,hoverPopover:true,metricsInterval:1,notificationsAuthorized:true},
  history:[],updatedAt:Date.now()
});
document.querySelector('[data-view="settings"]').click();
```

Expected: the dashboard redraws in Holograme's palette, and the Réglages view shows a "Thème" row with six swatches, the "holograme" one marked active. Click each swatch — since there's no real native bridge in the browser, clicking only calls `send()` (a no-op outside the app), so instead re-run `window.StatusApp.update({...prefs:{theme:'<id>'}})` for each of the six ids and confirm the picker's active state and the whole page's palette both update. Confirm `'blueprint'` still matches the pre-Task-3 screenshot.

- [ ] **Step 10: Commit**

```bash
git add Resources/dashboard.html
git commit -m "feat: le tableau de bord consomme themes.css et ajoute le sélecteur de thème"
```

---

### Task 4: Native — persist and serve the `theme` preference

**Files:**
- Modify: `Native/Status.m:522-528` (`registerDefaults`), `Native/Status.m:939-943` (script message handling), `Native/Status.m:1002-1008` (`payload`)

**Interfaces:**
- Consumes: `setTheme` action with `{value: <string>}`, sent by both webviews via the existing `send(action, extra)` JS helper (already defined in both HTML files — no new bridge code needed there).
- Produces: `data.prefs.theme` in every `payload` pushed to both webviews — read by Task 2 Step 7 and Task 3 Step 8.

- [ ] **Step 1: Register the default**

Replace:

```objc
    [defaults registerDefaults:@{
        @"refreshIntervalMinutes": @5,
        // lowest | claude:session | claude:weekly | openai:weekly — quel % accompagne l'icône.
        // Claude semaine par défaut : c'est la limite qui contraint réellement le travail.
        @"menuBarMetric": @"claude:weekly",
        @"hoverPopover": @YES
    }];
```
with:
```objc
    [defaults registerDefaults:@{
        @"refreshIntervalMinutes": @5,
        // lowest | claude:session | claude:weekly | openai:weekly — quel % accompagne l'icône.
        // Claude semaine par défaut : c'est la limite qui contraint réellement le travail.
        @"menuBarMetric": @"claude:weekly",
        @"hoverPopover": @YES,
        // blueprint reste l'apparence historique : les utilisateurs existants ne voient aucun
        // changement tant qu'ils ne choisissent pas un autre thème dans Réglages.
        @"theme": @"blueprint"
    }];
```

- [ ] **Step 2: Accept `setTheme`, rejecting unknown ids**

Replace:

```objc
    if ([action isEqualToString:@"setMenuBarMetric"]) {
        NSString *value = [body[@"value"] isKindOfClass:NSString.class] ? body[@"value"] : @"lowest";
        [NSUserDefaults.standardUserDefaults setObject:value forKey:@"menuBarMetric"];
        [self pushData];
    }
```
with:
```objc
    if ([action isEqualToString:@"setMenuBarMetric"]) {
        NSString *value = [body[@"value"] isKindOfClass:NSString.class] ? body[@"value"] : @"lowest";
        [NSUserDefaults.standardUserDefaults setObject:value forKey:@"menuBarMetric"];
        [self pushData];
    }
    if ([action isEqualToString:@"setTheme"]) {
        // Entrée non fiable (vient de la webview) : seuls les six identifiants de themes.css
        // sont acceptés, sinon un thème mal orthographié figerait l'app sur les jetons par
        // défaut de :root sans jamais le dire.
        static NSSet<NSString *> *validThemes;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            validThemes = [NSSet setWithArray:@[@"blueprint", @"phosphore", @"synthwave", @"circuit", @"holograme", @"ion"]];
        });
        NSString *value = [body[@"value"] isKindOfClass:NSString.class] ? body[@"value"] : @"";
        if ([validThemes containsObject:value]) {
            [NSUserDefaults.standardUserDefaults setObject:value forKey:@"theme"];
            [self pushData];
        }
    }
```

- [ ] **Step 3: Expose it in the payload**

Replace:

```objc
        @"prefs": @{
            @"launchAtLogin": @([self launchAtLoginEnabled]),
            @"menuBarMetric": [NSUserDefaults.standardUserDefaults stringForKey:@"menuBarMetric"] ?: @"claude:weekly",
            @"hoverPopover": @([self hoverPopoverEnabled]),
            @"metricsInterval": @([self metricsInterval]),
            @"notificationsAuthorized": @(self.notificationsAuthorized)
        },
```
with:
```objc
        @"prefs": @{
            @"launchAtLogin": @([self launchAtLoginEnabled]),
            @"menuBarMetric": [NSUserDefaults.standardUserDefaults stringForKey:@"menuBarMetric"] ?: @"claude:weekly",
            @"hoverPopover": @([self hoverPopoverEnabled]),
            @"metricsInterval": @([self metricsInterval]),
            @"notificationsAuthorized": @(self.notificationsAuthorized),
            @"theme": [NSUserDefaults.standardUserDefaults stringForKey:@"theme"] ?: @"blueprint"
        },
```

- [ ] **Step 4: Compile the app target to confirm `Status.m` still builds**

Run: `clang -fobjc-arc -fsyntax-only -I Native -framework Cocoa -framework WebKit -framework Security -framework ServiceManagement -framework UserNotifications -framework IOKit Native/Status.m Native/StatusQuota.m Native/StatusAwake.m Native/StatusSystemMonitor.m Native/StatusKeyboardLock.m`
Expected: no output, exit code 0. (`-fsyntax-only` skips linking/codesigning — this is a syntax/type check only; `scripts/run-tests.sh` does not compile `Status.m` at all, so this is the only build check this task gets.)

- [ ] **Step 5: Run the existing native test suite (unaffected, but must still pass)**

Run: `./scripts/run-tests.sh`
Expected: both suites report success (exit code 0) — this task doesn't touch any file `run-tests.sh` compiles, so this is a regression guard, not new coverage.

- [ ] **Step 6: Commit**

```bash
git add Native/Status.m
git commit -m "feat: persiste et sert la préférence de thème (setTheme, prefs.theme)"
```

---

### Task 5: Ship `themes.css` in the packaged app

**Files:**
- Modify: `scripts/package-app.sh`

**Interfaces:**
- Consumes: `Resources/themes.css` (Task 1).
- Produces: `outputs/Status.app/Contents/Resources/themes.css` — without this, the packaged app's `<link href="themes.css">` 404s inside the WKWebView sandbox and every theme (including `blueprint`, since Task 2/3 removed the old inline `:root` values) silently loses all its colors.

- [ ] **Step 1: Copy the stylesheet alongside the two HTML files**

Replace:

```bash
cp "$ROOT/Resources/dashboard.html" "$OUTPUT/Contents/Resources/dashboard.html"
cp "$ROOT/Resources/menubar.html" "$OUTPUT/Contents/Resources/menubar.html"
```
with:
```bash
cp "$ROOT/Resources/dashboard.html" "$OUTPUT/Contents/Resources/dashboard.html"
cp "$ROOT/Resources/menubar.html" "$OUTPUT/Contents/Resources/menubar.html"
cp "$ROOT/Resources/themes.css" "$OUTPUT/Contents/Resources/themes.css"
```

- [ ] **Step 2: Build the app and confirm the file landed in the bundle**

Run: `./scripts/package-app.sh && test -f outputs/Status.app/Contents/Resources/themes.css && echo "themes.css present"`
Expected: `themes.css present` (plus the normal package-app.sh signing output).

- [ ] **Step 3: Commit**

```bash
git add scripts/package-app.sh
git commit -m "build: embarque themes.css dans le bundle de l'app"
```

---

### Task 6: End-to-end verification in the real app

**Files:**
- None (verification only — no new files).

**Interfaces:**
- Consumes: everything from Tasks 1–5.

- [ ] **Step 1: Launch the freshly packaged app**

Run: `open outputs/Status.app`
Expected: the app launches, menu-bar icon appears, popover opens on click showing the `blueprint` theme (the default) exactly as before this plan.

- [ ] **Step 2: Switch through every theme from the dashboard**

Open the dashboard (`ouvrir` in the popover footer, or the `send('openDashboard')` button), go to Réglages, and click each of the six swatches in turn. After each click, reopen the popover from the menu bar.

Expected: both the dashboard and the popover reflect the newly selected theme within one refresh (`pushData` is called synchronously by `setTheme`, so this should be immediate). Quit and relaunch the app once with a non-default theme selected — expected: the chosen theme persists (confirms `NSUserDefaults` round-trip).

- [ ] **Step 3: Confirm no regressions in the existing settings**

In Réglages, toggle "Lancer au démarrage", change "Jauge affichée dans la barre des menus", and change "Cadence du moniteur système" — confirm all three still work (Task 3 added a sibling row above them but didn't touch their markup or handlers).

- [ ] **Step 4: Final commit (if any cleanup was needed)**

Only if Steps 1–3 surfaced a fix — commit it with a message describing the specific defect found, not a generic "fixes".
