// Tests de la logique JavaScript des deux surfaces web.
//
//   ./scripts/run-tests.sh
//
// Le script vit à l'intérieur des fichiers HTML : on l'extrait et on l'exécute dans un bac à
// sable `vm` muni du strict minimum de DOM. Zéro dépendance, comme le harnais natif — pas de
// jsdom, pas de npm install : ce qui est testé ici est de la logique, pas du rendu.
//
// Ce qui est couvert est ce qui a réellement cassé pendant le développement : le calage de
// séries de longueurs différentes, le formatage des unités (une charge arrondie à l'entier ne
// dit plus rien), et la sélection de la fenêtre à afficher.

import { readFileSync } from 'node:fs';
import { createContext, runInContext } from 'node:vm';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

let checks = 0, failures = 0;
const section = name => process.stdout.write(`\n\x1b[1m${name}\x1b[0m\n`);
const check = (condition, what) => {
  checks++;
  if (condition) process.stdout.write(`  \x1b[32m✓\x1b[0m ${what}\n`);
  else { failures++; process.stdout.write(`  \x1b[31m✗ ${what}\x1b[0m\n`); }
};
const checkEqual = (actual, expected, what) => {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  checks++;
  if (ok) process.stdout.write(`  \x1b[32m✓\x1b[0m ${what}\n`);
  else {
    failures++;
    process.stdout.write(`  \x1b[31m✗ ${what}\x1b[0m\n     attendu: ${JSON.stringify(expected)}\n     obtenu : ${JSON.stringify(actual)}\n`);
  }
};

// Un DOM juste assez crédible pour que le script s'installe sans lever. Les fonctions testées
// plus bas sont pures ; ces bouchons ne servent qu'à traverser l'initialisation.
function sandboxFor(htmlFile) {
  const html = readFileSync(join(root, 'Resources', htmlFile), 'utf8');
  const script = html.slice(html.indexOf('<script>') + 8, html.lastIndexOf('</script>'));

  const element = () => ({
    innerHTML: '', textContent: '', className: '', style: {}, dataset: {}, disabled: false,
    classList: { toggle() {}, add() {}, remove() {}, contains: () => false },
    addEventListener() {}, querySelector: () => element(), querySelectorAll: () => [],
    getBoundingClientRect: () => ({ width: 0, height: 0, left: 0 }), closest: () => null,
  });
  const sandbox = {
    document: { querySelector: () => element(), querySelectorAll: () => [], addEventListener() {} },
    window: {}, setInterval() {}, setTimeout() {}, console,
    Intl, Date, Math, JSON, Number, String, Array, Object, isNaN, parseFloat, parseInt,
  };
  sandbox.window = sandbox;
  const context = createContext(sandbox);
  runInContext(script, context);
  // Les `const` de haut niveau vivent dans l'environnement lexical du contexte, pas sur l'objet
  // global : on les récupère en évaluant une expression dans ce même contexte.
  return name => runInContext(name, context);
}

const dashboard = sandboxFor('dashboard.html');
const menubar = sandboxFor('menubar.html');

// ── Formatage ───────────────────────────────────────────────────────────────
section('fmtBytes — débits');
checkEqual(dashboard('fmtBytes')(0), '0 o/s', 'zéro');
checkEqual(dashboard('fmtBytes')(512), '512 o/s', 'sous le kilo-octet');
checkEqual(dashboard('fmtBytes')(1024), '1.0 Ko/s', 'bascule au kilo-octet, une décimale');
checkEqual(dashboard('fmtBytes')(2411724), '2.3 Mo/s', 'méga-octets');
checkEqual(dashboard('fmtBytes')(null), '—', 'valeur absente : tiret, jamais « 0 o/s »');
checkEqual(dashboard('fmtBytes')(NaN), '—', 'NaN : tiret');

section('fmtUptime — durée de fonctionnement');
checkEqual(dashboard('fmtUptime')(90), '1 min', 'moins d’une heure');
checkEqual(dashboard('fmtUptime')(3660), '1 h 01', 'heures et minutes, minutes cadrées');
checkEqual(dashboard('fmtUptime')(437000), '5 j 1 h', 'jours et heures');
checkEqual(dashboard('fmtUptime')(null), '—', 'valeur absente');

// ── Statistiques du tableau ─────────────────────────────────────────────────
section('stats — agrégats de la vue tableau');
checkEqual(dashboard('stats')([10, 20, 30]), { now: 30, min: 10, max: 30, avg: 20 }, 'courant, min, max, moyenne');
checkEqual(dashboard('stats')([]), null, 'série vide : rien à agréger');
checkEqual(dashboard('stats')(undefined), null, 'série absente');
checkEqual(dashboard('stats')([7]), { now: 7, min: 7, max: 7, avg: 7 }, 'un seul point');

section('METRIC_LABELS — le format ne se déduit pas de l’unité');
checkEqual(dashboard('METRIC_LABELS')['system.load1'][2], 'decimal',
  'la charge est décimale : arrondie à l’entier, 2,4 deviendrait 2 et ne dirait plus rien');
checkEqual(dashboard('METRIC_LABELS')['network.rxBytesPerSec'][2], 'bytes', 'les débits passent par fmtBytes');
checkEqual(dashboard('METRIC_LABELS')['cpu.total'][2], 'int', 'les pourcentages sont entiers');

// ── Sélection de fenêtre (popover) ──────────────────────────────────────────
section('isWeekly / isSession — reconnaissance des fenêtres');
check(menubar('isWeekly')({ windowId: 'seven_day' }), 'seven_day est hebdomadaire');
check(menubar('isWeekly')({ windowId: 'seven_day_fable' }), 'seven_day_fable aussi (préfixe)');
check(menubar('isWeekly')({ durationMinutes: 10080 }), 'reconnue par sa durée');
check(!menubar('isWeekly')({ windowId: 'five_hour' }), 'five_hour n’est pas hebdomadaire');
check(menubar('isSession')({ windowId: 'five_hour' }), 'five_hour est une session');
check(!menubar('isSession')(null), 'null n’est rien');

section('used — bornage du pourcentage');
checkEqual(menubar('used')({ usedPercent: 42.4 }), 42, 'arrondi');
checkEqual(menubar('used')({ usedPercent: -5 }), 0, 'borné en bas : jamais de négatif affiché');
checkEqual(menubar('used')({ usedPercent: 130 }), 100, 'borné en haut');
checkEqual(menubar('used')(null), null, 'fenêtre absente : null, distinct de 0');

// ── Alignement des deux colonnes du popover (menubar.html) ──────────────────
// Claude porte des sous-jauges (5 h, Fable) qu'OpenAI n'a pas. En empilant librement, la note de
// fraîcheur et le coût des deux fournisseurs se retrouvaient décalés de plus de cent pixels : on
// ne pouvait plus comparer une ligne à celle d'en face. Chaque donnée occupe donc une rangée
// nommée de la même grille, et une case sans donnée reste vide plutôt que d'absorber la suivante.
section('provider — les deux colonnes partagent les mêmes rangées');
const rowsOf = html => [...html.matchAll(/class="cell (c\d) (r\d)/g)].map(m => m[2]);
const colsOf = html => [...new Set([...html.matchAll(/class="cell (c\d) /g)].map(m => m[1]))];
const openaiHTML = menubar('provider')('openai', 'OpenAI', [{ provider: 'openai', connected: true, label: 'Boulot', windows: [
  { windowId: 'seven_day', usedPercent: 42, resetsAt: Date.now() / 1000 + 90000 } ] }], 'openai:weekly');
const claudeHTML = menubar('provider')('claude', 'Claude', [{ provider: 'claude', cookieConfigured: true, orgId: 'org', label: 'Perso', windows: [
  { windowId: 'seven_day', usedPercent: 81, resetsAt: Date.now() / 1000 + 90000 },
  { windowId: 'five_hour', usedPercent: 4, resetsAt: Date.now() / 1000 + 9000 } ] }], 'claude:weekly');
checkEqual(rowsOf(openaiHTML), rowsOf(claudeHTML),
  'mêmes rangées des deux côtés, sous-jauges ou non');
checkEqual(colsOf(openaiHTML), ['c1'], 'OpenAI occupe la première colonne');
checkEqual(colsOf(claudeHTML), ['c2'], 'Claude occupe la seconde');
check(/class="cell c2 r5[^"]*"[^>]*>\s*<div class="subgauge"/.test(claudeHTML),
  'la sous-jauge 5 h vit dans la rangée qui lui est réservée');
check(/class="cell c1 r5[^"]*"[^>]*>\s*<\/div>/.test(openaiHTML),
  'côté OpenAI la même rangée existe, vide — elle ne remonte pas la suite');

// ── Coût par modèle (dashboard) ─────────────────────────────────────────────
section('fmtTokens — volumes de tokens, toujours en millions');
checkEqual(dashboard('fmtTokens')(186207), '0.2 M', 'sous le million : arrondi au dixième de million');
checkEqual(dashboard('fmtTokens')(61493255), '61.5 M', 'dizaines de millions, une décimale');
check(/^9.741 M$/.test(dashboard('fmtTokens')(9741100000)), 'milliards : entier en millions avec séparateur (9 741 M)');
checkEqual(dashboard('fmtTokens')(null), '', 'absent : chaîne vide');

section('tariffTitle — infobulle des tarifs appliqués');
const tt = dashboard('tariffTitle')({ 'claude-opus-4-8': { input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25 } });
check(tt.includes('claude-opus-4-8') && tt.includes('entrée 5') && tt.includes('sortie 25'), 'liste le modèle et ses tarifs');
checkEqual(dashboard('tariffTitle')({}), '', 'aucun modèle : pas d’infobulle');

section('modelBreakdown — tableau par modèle');
const mb = dashboard('modelBreakdown')({ breakdown: [
  { model: 'claude-opus-4-8', tokens: 9741100000, cost: 7524.4 },
  { model: 'codex-auto-review', tokens: 61493255 } ] });  // pas de cost : non tarifé
check(mb.includes('claude-opus-4-8') && /9.741 M/.test(mb), 'ligne tarifée avec ses tokens');
check(/class="model-row unpriced"[\s\S]*codex-auto-review[\s\S]*—/.test(mb), 'ligne non tarifée : classe unpriced et coût «—»');
checkEqual(dashboard('modelBreakdown')({ breakdown: [] }), '', 'aucun modèle : pas de tableau');

// ── Panneaux d'info des widgets (widget.html) ────────────────────────────────
// Les renderers sont purs : on injecte un snapshot réaliste dans la variable `metrics` du
// contexte, puis on évalue chaque renderXxx(). On vérifie l'absence de NaN/undefined (le piège
// numéro un quand une clé matérielle manque) et le formatage français des valeurs clés.
section('widget.html — panneaux détaillés façon iStat');
const widget = sandboxFor('widget.html');
const wsnap = { families: [
  { id: 'cpu', now: { total: 12, userPercent: 7, systemPercent: 5, coreTypes: 'EEPP', core0: 3, core1: 4, core2: 20, core3: 25 }, series: { total: [10, 12] } },
  { id: 'ram', now: { usedPercent: 61, pressureLevel: 1, totalBytes: 38654705664, usedBytes: 25231056896,
      appBytes: 14384218112, wiredBytes: 4831838208, compressedBytes: 6012954624, cachedBytes: 11274289152,
      freeBytes: 1288490188, swapUsedBytes: 1610612736, swapTotalBytes: 2147483648 }, series: {} },
  { id: 'gpu', now: { usage: 0, renderer: 0, tiler: 0, memInUse: 1288490188 }, series: {} },
  { id: 'network', now: { rxBytesPerSec: 5767168, txBytesPerSec: 21504, 'rx:en0': 5767168, 'tx:en0': 21504,
      rxSessionBytes: 4404019, txSessionBytes: 16384 }, series: {} },
  { id: 'sensors', now: { tempC: 41, thermalState: 0, fan0: 3184, fan1: 3188 }, series: {} },
  { id: 'battery', now: { percent: 100, charging: false, externalConnected: true, fullyCharged: true,
      healthPercent: 91, cycleCount: 218, voltageV: 13.1, fullCapacity: 5673, designCapacity: 6249,
      adapterWatts: 94, conditionOK: true }, series: {} },
  { id: 'disk', now: { usedPercent: 90, totalBytes: 994662584320, freeBytes: 98784247808,
      readBytesPerSec: 129024, writeBytesPerSec: 1677721, 'vol:/': 90,
      'volTotal:/': 994662584320, 'volFree:/': 98784247808 }, series: {} },
  { id: 'system', now: { load1: 2.66, load5: 3.16, load15: 3.68, processCount: 1088, uptimeSec: 339200 }, series: {} },
], processes: [
  { pid: '1', name: 'Gros CPU', cpuPercent: 15, rssBytes: 104857600, energyWatts: 0.1 },
  { pid: '2', name: 'Grosse RAM', cpuPercent: 1, rssBytes: 1073741824, energyWatts: 0.01 },
], prefs: { theme: 'blueprint' } };
widget('metrics = ' + JSON.stringify(wsnap));
const noJunk = h => !/NaN|undefined/.test(h) && !/>null</.test(h);

const wCPU = widget('renderCPU()');
check(noJunk(wCPU), 'CPU : aucun NaN/undefined/null');
check(/utilisateur/.test(wCPU) && /système/.test(wCPU), 'CPU : découpe utilisateur/système présente');
check(/2,66 · 3,16 · 3,68/.test(wCPU), 'CPU : charge moyenne en décimales françaises');
check(wCPU.indexOf('Gros CPU') > -1 && wCPU.indexOf('Gros CPU') < wCPU.indexOf('Grosse RAM'),
  'CPU : liste des processus triée par CPU (le plus gros d’abord)');

const wMem = widget('renderMemory()');
check(noJunk(wMem), 'Mémoire : aucun NaN/undefined/null');
check(/App/.test(wMem) && /Compr\./.test(wMem) && /Cache/.test(wMem), 'Mémoire : répartition app/compressée/cache');
check(/13,4 Go/.test(wMem), 'Mémoire : octets en Go français (App 13,4 Go)');
check(wMem.indexOf('Grosse RAM') > -1 && wMem.indexOf('Grosse RAM') < wMem.indexOf('Gros CPU'),
  'Mémoire : liste des processus triée par RAM');

const wNet = widget('renderNetwork()');
check(noJunk(wNet), 'Réseau : aucun NaN/undefined/null');
check(/Session/.test(wNet) && /4,2 Mo/.test(wNet), 'Réseau : totaux de session cumulés');
// Les tunnels VPN inactifs (utun*, souvent 6 ou plus) noyaient la seule interface qui transmet.
widget('Object.assign(metrics.families.find(f=>f.id==="network").now,' +
  '{"rx:utun0":0,"tx:utun0":0,"rx:utun1":0,"tx:utun1":0,"rx:awdl0":0,"tx:awdl0":0})');
const wNetIdle = widget('renderNetwork()');
check(!/utun0/.test(wNetIdle) && !/awdl0/.test(wNetIdle), 'Réseau : interfaces sans trafic masquées');
check(/en0/.test(wNetIdle), 'Réseau : l’interface active reste listée');
check(/\+ 3 inactives/.test(wNetIdle), 'Réseau : le nombre d’interfaces masquées est annoncé');
widget('metrics = ' + JSON.stringify(wsnap));

const wSens = widget('renderTemperature()');
check(noJunk(wSens), 'Capteurs : aucun NaN/undefined/null');
check(/3.184 tr\/min/.test(wSens) && /3.188 tr\/min/.test(wSens), 'Capteurs : les deux ventilateurs');

const wBat = widget('renderBattery()');
check(noJunk(wBat), 'Batterie : aucun NaN/undefined/null');
check(/91 %/.test(wBat) && /218/.test(wBat) && /13,10 V/.test(wBat), 'Batterie : santé, cycles, tension française');

const wDisk = widget('renderDisk()');
check(noJunk(wDisk), 'Disque : aucun NaN/undefined/null');
check(/Macintosh HD/.test(wDisk) && /92 \/ 926 Go/.test(wDisk), 'Disque : volume nommé, espace libre / total');
// Unités différentes : l'unité du libre ne doit pas être omise, sinon « 800 / 1,2 To » se lirait
// 800 To. Volume de 1,2 To dont 800 Mo libres.
widget('metrics.families.find(f=>f.id==="disk").now["volTotal:/"] = 1319413953331');
widget('metrics.families.find(f=>f.id==="disk").now["volFree:/"] = 838860800');
check(/800 Mo \/ 1,2 To/.test(widget('renderDisk()')), 'Disque : unités distinctes toutes deux affichées');
widget('metrics = ' + JSON.stringify(wsnap));

const wGPU = widget('renderGPU()');
check(noJunk(wGPU), 'GPU : aucun NaN/undefined/null');
check(!/Processus/.test(wGPU), 'GPU : pas de liste de processus (charge GPU par process non mesurable)');

// Sections activables : prefs.panels[widgetId][section]===false masque la section.
const gated = JSON.parse(JSON.stringify(wsnap));
gated.prefs.panels = { cpu: { processes: false, load: false }, memory: { breakdown: false } };
widget('metrics = ' + JSON.stringify(gated));
widget('widgetId = "cpu"');  // les renderers lisent la variable de module widgetId (posée par show())
const gCPU = widget('renderCPU()');
check(!/Processus · CPU/.test(gCPU), 'CPU : section processus masquée quand désactivée');
check(!/charge moy\./.test(gCPU), 'CPU : section charge masquée quand désactivée');
check(/utilisateur/.test(gCPU), 'CPU : les sections non désactivées restent (user/système)');
widget('widgetId = "memory"');
const gMem = widget('renderMemory()');
check(!/Résidente/.test(gMem), 'Mémoire : répartition masquée quand désactivée');
check(/Processus · mémoire/.test(gMem), 'Mémoire : section processus conservée (non désactivée)');
widget('metrics = ' + JSON.stringify(wsnap)); widget('widgetId = null');  // restaure

// ── Hauteur du panneau (widget.html) ────────────────────────────────────────
// Le popover natif est dimensionné par cette mesure : si elle cesse de partir, les panneaux longs
// se retrouvent tronqués — le défaut que ce mécanisme corrige.
section('widget.html — hauteur mesurée poussée au natif');
widget('window.__sent = []');
widget('window.webkit = {messageHandlers:{native:{postMessage:m=>window.__sent.push(m)}}}');
widget('let __h = 412; document.querySelector = () => ({getBoundingClientRect:()=>({height:__h})}); window.__setH = v => { __h = v }');
widget('widgetId = "cpu"');
widget('syncPanelHeight()');
checkEqual(widget('window.__sent'), [{ action: 'resizeWidgetPanel', id: 'cpu', height: 412 }],
  'la hauteur mesurée part avec l’identifiant du widget');
widget('syncPanelHeight()');
checkEqual(widget('window.__sent.length'), 1, 'hauteur inchangée : aucun message inutile');
widget('window.__setH(268)'); widget('syncPanelHeight()');
checkEqual(widget('window.__sent.length'), 2, 'hauteur changée : nouveau message');
checkEqual(widget('window.__sent[1].height'), 268, 'la nouvelle hauteur est celle mesurée');
// Panneau pas encore rendu : ne rien envoyer plutôt qu'une hauteur nulle qui écraserait le popover.
widget('window.__setH(0)'); widget('syncPanelHeight()');
checkEqual(widget('window.__sent.length'), 2, 'hauteur nulle : rien n’est poussé');

// Échelle auto : la crête ne doit pas toucher le bord haut, sinon la courbe se lit comme saturée.
section('widget.html — échelle des courbes sans pourcentage');
const autoScale = widget('chart([{values:[10,50],color:"var(--chart-a)"}],{percent:false})');
check(!/,0\.0/.test(autoScale), 'échelle auto : la crête garde de l’air au-dessus');
const pctScale = widget('chart([{values:[0,100],color:"var(--chart-a)"}])');
check(/,0\.0/.test(pctScale), 'échelle 0-100 : 100 % touche bien le haut du cadre');

// Le tick incrémental : le natif n'envoie les séries qu'à l'ouverture d'une surface ; ensuite
// chaque tick n'apporte que `now`, et la série glisse côté client — même sémantique que l'anneau
// natif (plafond 300, valeurs non numériques écartées, famille muette absente du snapshot).
section('mergeMetricsDelta — ticks incrémentaux (les trois surfaces)');
for (const [name, evalIn] of [['dashboard', dashboard], ['menubar', menubar], ['widget', widget]]) {
  const full = { families: [{ id: 'cpu', now: { total: 43, coreTypes: 'EEPP' }, series: { total: [40, 41, 43] } }],
                 processes: [], intervalSeconds: 1 };
  const fullJson = JSON.stringify(full);
  checkEqual(evalIn(`mergeMetricsDelta(null, ${fullJson})`), full, `${name} : payload complet adopté tel quel`);

  const delta = { delta: true, families: [{ id: 'cpu', now: { total: 50, coreTypes: 'EEPP' } }],
                  processes: [{ name: 'X' }], intervalSeconds: 1 };
  const merged = evalIn(`mergeMetricsDelta(${fullJson}, ${JSON.stringify(delta)})`);
  checkEqual(merged?.families?.[0]?.now?.total, 50, `${name} : now remplacé`);
  checkEqual(merged?.families?.[0]?.series?.total, [40, 41, 43, 50], `${name} : la série glisse`);
  check(merged?.families?.[0]?.series?.coreTypes === undefined, `${name} : valeur non numérique sans série`);
  checkEqual(merged?.processes, [{ name: 'X' }], `${name} : processus du delta adoptés`);
  check(evalIn(`mergeMetricsDelta(null, ${JSON.stringify(delta)})`) === null,
        `${name} : delta sans base ignoré (le natif renverra un complet)`);

  const long = { families: [{ id: 'cpu', now: { total: 1 }, series: { total: Array.from({ length: 300 }, (_, i) => i) } }] };
  const capped = evalIn(`mergeMetricsDelta(${JSON.stringify(long)}, ${JSON.stringify({ delta: true, families: [{ id: 'cpu', now: { total: 99 } }] })})`);
  checkEqual(capped?.families?.[0]?.series?.total?.length, 300, `${name} : série plafonnée à 300`);
  checkEqual(capped?.families?.[0]?.series?.total?.[299], 99, `${name} : la nouvelle valeur entre`);
  checkEqual(capped?.families?.[0]?.series?.total?.[0], 1, `${name} : le plus ancien point sort`);

  const appeared = evalIn(`mergeMetricsDelta(${fullJson}, ${JSON.stringify({ delta: true, families: [{ id: 'cpu', now: { total: 44 } }, { id: 'battery', now: { percent: 90 } }] })})`);
  checkEqual(appeared?.families?.length, 2, `${name} : famille apparue créée`);
  checkEqual(appeared?.families?.[1]?.series?.percent, [90], `${name} : sa série démarre au premier point`);
  const vanished = evalIn(`mergeMetricsDelta(${fullJson}, ${JSON.stringify({ delta: true, families: [] })})`);
  checkEqual(vanished?.families?.length, 0, `${name} : famille muette absente, comme le snapshot natif`);
}

// Bout en bout : les VRAIS handlers exposés au natif, enchaînant payload complet puis delta —
// exactement la séquence que le natif envoie (amorçage à l'ouverture, ticks incrémentaux ensuite).
// Le rendu tourne sur le DOM bouchonné ; ce qui est vérifié est l'état fusionné.
section('updateMetrics — enchaînement complet puis delta via les handlers réels');
{
  const full = JSON.stringify({ families: [{ id: 'cpu', now: { total: 43 }, series: { total: [40, 41, 43] } }],
                                processes: [], intervalSeconds: 1 });
  const tick = JSON.stringify({ delta: true, families: [{ id: 'cpu', now: { total: 50 } }],
                                processes: [], intervalSeconds: 1 });
  dashboard(`StatusApp.updateMetrics(${full})`); dashboard(`StatusApp.updateMetrics(${tick})`);
  checkEqual(dashboard('metricsData.families[0].series.total'), [40, 41, 43, 50], 'dashboard : le handler réel fusionne le delta');
  checkEqual(dashboard('metricsData.families[0].now.total'), 50, 'dashboard : now à jour');
  menubar(`StatusMenu.updateMetrics(${full})`); menubar(`StatusMenu.updateMetrics(${tick})`);
  checkEqual(menubar('lastMetrics.families[0].series.total'), [40, 41, 43, 50], 'popover : le handler réel fusionne le delta');
  widget(`StatusWidget.updateMetrics(${full})`); widget(`StatusWidget.updateMetrics(${tick})`);
  checkEqual(widget('metrics.families[0].series.total'), [40, 41, 43, 50], 'widget : le handler réel fusionne le delta');
}

// Les alertes quota rejoignent le bloc des alertes réglables : un seuil à choix pour « entamé »,
// un simple interrupteur pour la réinitialisation hebdo (pas de seuil à régler sur un événement).
section('alertRows — réglages des alertes, quotas compris');
const rows = dashboard(`alertRows({})`);
check(rows.includes('Quota entamé'), 'la rangée du seuil quota existe');
check(rows.includes('Réinitialisation hebdo'), 'la rangée du reset hebdo existe');
const quotaRow = rows.split('<div class="wc-row">').find(r => r.includes('Quota entamé'));
check(quotaRow && quotaRow.includes('80 %'), 'seuil quota : choix de pourcentages');
const resetRow = rows.split('<div class="wc-row">').find(r => r.includes('Réinitialisation'));
check(resetRow && !resetRow.includes('wc-shapes'), 'reset hebdo : interrupteur seul, pas de seuil');

// Le sous-quota hebdo Fable est épinglable dans la barre des menus, comme les autres fenêtres.
section('settingsView — épinglage de la semaine Fable');
const settings = dashboard(`settingsView({prefs:{}})`);
check(settings.includes("claude:weekly-fable"), 'le choix « semaine Fable » est proposé');
check(settings.includes('Claude Fable'), 'avec un libellé lisible');

// Fabrique de comptes au format poussé par l'app : une liste, un payload par compte.
const uuid = n => `${String(n).repeat(8)}-${String(n).repeat(4)}-4${String(n).repeat(3)}-8${String(n).repeat(3)}-${String(n).repeat(12)}`;
const claudeAccount = (n, label, windows) => ({
  accountId: uuid(n === 'a' ? 1 : n === 'b' ? 2 : 3), provider: 'claude', label,
  windows, cookieConfigured: true, orgId: 'org', capturedAt: 0, error: '',
});
const openAIAccount = (n, label, windows) => ({
  accountId: uuid(n), provider: 'openai', label, windows, connected: true, error: '',
});

// Les sous-quotas « scoped » (7 j · Fable) ne pilotent aucun chiffre agrégé : ni le héros du
// tableau de bord, ni la jauge hebdo du popover. Ils gardent leur carte et leur épinglage dédié.
section('sous-quotas scoped — exclus des chiffres agrégés');
{
  const claudeWindows = [
    { windowId: 'seven_day', label: '7 jours', usedPercent: 37, resetsAt: 9999999999 },
    { windowId: 'seven_day_scoped_fable', label: '7 j · Fable', usedPercent: 54, resetsAt: 9999999999 },
  ];
  check(dashboard(`isScopedWeekly({windowId:'seven_day_scoped_fable'})`) === true, 'dashboard : scoped reconnu');
  check(dashboard(`isScopedWeekly({windowId:'seven_day'})`) === false, 'dashboard : la semaine générale ne l’est pas');
  const data = JSON.stringify({ accounts: [claudeAccount('a', 'Perso', claudeWindows)],
                                history: [], updatedAt: 0 });
  const hero = dashboard(`overview(${data})`).split('hero-detail')[0];
  check(hero.includes('hero-value">37<span'), 'héros : la semaine générale (37) donne le chiffre');
  check(!hero.includes('54'), 'héros : le sous-quota Fable (54) ne le pilote pas');
  const mw = menubar(`mainWeekly(${JSON.stringify(claudeWindows)})`);
  checkEqual(mw?.windowId, 'seven_day', 'popover : la jauge hebdo suit la semaine générale');
  checkEqual(menubar(`mainWeekly([{windowId:'codex-10080',durationMinutes:10080,usedPercent:1},{windowId:'codex_b-10080',durationMinutes:10080,usedPercent:84}])`)?.usedPercent,
             84, 'popover : OpenAI garde le max de ses limites générales');
  check(menubar(`mainWeekly([])`) == null, 'popover : aucune hebdo → rien');
}

// ── Multi-comptes ───────────────────────────────────────────────────────────
// Ce qui casse en silence ici, c'est un compte qui n'apparaît pas, ou deux comptes dont les
// courbes partagent une clé d'historique et s'écrasent l'une l'autre.
section('accountsOf / historyKey — la liste de comptes');
{
  const perso = claudeAccount('a', 'Perso', [{ windowId: 'seven_day', label: '7 jours', usedPercent: 40, resetsAt: 9999999999 }]);
  const pro = claudeAccount('b', 'Pro', [{ windowId: 'seven_day', label: '7 jours', usedPercent: 72, resetsAt: 9999999999 }]);
  const boulot = openAIAccount(3, 'Boulot', [{ windowId: 'codex-10080', label: 'Semaine', durationMinutes: 10080, usedPercent: 55, resetsAt: 9999999999 }]);
  const data = { accounts: [boulot, perso, pro], history: [], updatedAt: 0, accountLimit: 5 };
  const json = JSON.stringify(data);

  checkEqual(dashboard(`accountsOf(${json},'claude').map(a=>a.label)`), ['Perso', 'Pro'], 'les comptes sont filtrés par fournisseur');
  const k1 = dashboard(`historyKey(${JSON.stringify(perso)},{windowId:'seven_day'})`);
  const k2 = dashboard(`historyKey(${JSON.stringify(pro)},{windowId:'seven_day'})`);
  check(k1 !== k2, 'deux comptes ne partagent pas une clé d’historique');
  check(k1.includes(perso.accountId), 'la clé porte l’identifiant, pas le nom');

  section('overview — le héros nomme le compte, pas seulement le fournisseur');
  const view = dashboard(`overview(${json})`);
  check(view.includes('hero-value">72<span'), 'le compte le plus contraint donne le chiffre');
  check(view.split('hero-detail')[1].includes('Pro'), 'et le héros le nomme');
  check(view.includes('Perso') && view.includes('Boulot'), 'tous les comptes sont rendus');

  section('weeklySeriesFor — une série par compte');
  const series = dashboard(`weeklySeriesFor(${json})`);
  checkEqual(series.length, 3, 'trois séries pour trois comptes');
  check(new Set(series.map(s => s.key)).size === 3, 'trois clés distinctes');
  check(series.every(s => !String(s.color).includes('--chart-c')), 'aucune couleur ne pointe un jeton inexistant');

  section('depuis Volumes, Connexions est atteignable');
  {
    // « voir Connexions » n'était qu'une phrase : rien ne menait à l'endroit où l'on ajoute un
    // compte, et l'ajout restait à découvrir dans la barre latérale.
    const view = dashboard(`overview(${json})`);
    check(view.includes("goToView('connections')"), 'la vue Volumes ouvre Connexions');
    const sansCompte = JSON.stringify({ ...data, accounts: [] });
    check(dashboard(`overview(${sansCompte})`).includes("goToView('connections')"),
          'y compris quand aucun compte n’existe');
  }

  section('weeklyChart — le graphe traverse la voie des séries');
  {
    // Le graphe n'est rendu que s'il y a deux points : sans ce test, weeklySeriesFor et la
    // résolution des couleurs ne seraient jamais exécutées ici, et une référence morte y
    // passerait inaperçue jusqu'à l'ouverture réelle de la fenêtre.
    const now = Date.now() / 1000;
    const key = dashboard(`historyKey(${JSON.stringify(pro)},{windowId:'seven_day'})`);
    const history = [{ t: now - 3600, p: { [key]: 60 } }, { t: now - 60, p: { [key]: 72 } }];
    const chart = dashboard(`weeklyChart(${JSON.stringify({ ...data, history })})`);
    check(chart.length > 0, 'le graphe est rendu');
    check(chart.includes('Pro'), 'la série porte le nom du compte');
    check(!chart.includes('${'), 'aucune interpolation non résolue');
  }

  section('connectionsView — ajout et plafond');
  const connections = dashboard(`connectionsView(${json})`);
  check(connections.includes("send('addAccount',{provider:'claude'})"), 'on peut ajouter un compte Claude');
  check(connections.includes('2 / 5'), 'le décompte par rapport au plafond est affiché');
  check(connections.includes("send('removeAccount',{accountId:'" + pro.accountId + "'})"), 'chaque compte est retirable individuellement');
  const full = JSON.stringify({ ...data, accounts: [perso, pro, claudeAccount('c', 'Tiers', []), { ...claudeAccount('c', 'Quatre', []), accountId: uuid(4) }, { ...claudeAccount('c', 'Cinq', []), accountId: uuid(5) }] });
  check(dashboard(`connectionsView(${full})`).includes('disabled'), 'au plafond, le bouton d’ajout est désactivé');

  section('aucune interpolation non résolue dans les vues du dashboard');
  ['overview', 'connectionsView'].forEach(view => {
    check(!dashboard(`${view}(${json})`).includes('${'), `${view} rend du HTML complet`);
  });
  check(!dashboard(`settingsView(${JSON.stringify({ ...data, prefs: {} })})`).includes('${'),
        'settingsView rend du HTML complet');

  section('settingsView — épinglage par compte');
  const settings2 = dashboard(`settingsView(${JSON.stringify({ ...data, prefs: {} })})`);
  check(settings2.includes(`acct:claude:${pro.accountId}:weekly`), 'chaque compte Claude est épinglable');
  check(!settings2.includes(`acct:openai:${boulot.accountId}`), 'un fournisseur à compte unique n’encombre pas la liste');

  section('basculement rapide depuis la barre des menus');
  {
    const pinPro = `acct:claude:${pro.accountId}:weekly`;
    checkEqual(menubar(`parseMetric('${pinPro}')`).accountId, pro.accountId, 'une métrique épinglée se relit');
    checkEqual(menubar(`parseMetric('claude:weekly')`).accountId, undefined, 'un agrégat ne porte pas de compte');
    checkEqual(menubar(`parseMetric('lowest')`).lowest, true, '« lowest » est reconnu');
    checkEqual(menubar(`parseMetric('system:cpu')`).system, true, 'les métriques système aussi');

    // Le piège : changer de fenêtre ne doit pas rendre l'icône à un autre compte en silence.
    checkEqual(menubar(`metricForWindow('${pinPro}','claude','session')`),
               `acct:claude:${pro.accountId}:session`, 'changer de fenêtre garde le compte épinglé');
    checkEqual(menubar(`metricForWindow('${pinPro}','openai','weekly')`), 'openai:weekly',
               'chez un autre fournisseur, on repart de l’agrégat');
    checkEqual(menubar(`metricForWindow('claude:weekly','claude','session')`), 'claude:session',
               'sans épinglage, l’agrégat reste l’agrégat');
    checkEqual(dashboard(`metricForWindow('${pinPro}','claude','session')`),
               `acct:claude:${pro.accountId}:session`, 'même grammaire côté dashboard');

    // Le popover doit montrer le compte épinglé, sinon le geste n'a aucun retour à l'écran.
    checkEqual(menubar(`pickAccount(${JSON.stringify([perso, pro])},'${pinPro}')`).label, 'Pro',
               'la colonne suit le compte épinglé');
    checkEqual(menubar(`pickAccount(${JSON.stringify([perso, pro])},'acct:claude:inconnu:weekly')`).label, 'Pro',
               'un compte épinglé disparu retombe sur le plus contraint');
    checkEqual(menubar(`pickAccount(${JSON.stringify([pro, perso])},'claude:weekly')`).label, 'Pro',
               'sans épinglage, le plus contraint');

    // La rangée de bascule elle-même : présente quand il y a un choix, absente sinon.
    const all = JSON.stringify([boulot, perso, pro]);
    const switcher = menubar(`accountSwitcher(${all},'claude:weekly')`);
    check(switcher.includes('>tous<'), 'un retour à l’agrégat est proposé');
    check(switcher.includes('>Perso<') && switcher.includes('>Pro<'), 'les deux comptes Claude y sont');
    checkEqual(menubar(`chipLabel("contact@venio.paris's Organization")`), 'contact',
               'un libellé auto se réduit à ce qui identifie');
    checkEqual(menubar(`chipLabel('Pro')`), 'Pro', 'un nom court est laissé tel quel');
    checkEqual(menubar(`chipLabel('Organisation')`), 'Organisation', 'douze caractères passent entiers');
    checkEqual(menubar(`chipLabel('Organisationnelle')`), 'Organisatio…', 'au-delà, on tronque');
    check(menubar(`accountSwitcher(${all},'claude:weekly')`).includes('title="Perso"'),
          'le nom complet reste dans l’infobulle');
    check(!switcher.includes('Boulot'), 'et pas ceux d’un autre fournisseur');
    check((switcher.match(/class="seg on"/g) || []).length === 1, 'un seul choix est marqué');
    check(menubar(`accountSwitcher(${all},'openai:weekly')`) === '',
          'un fournisseur à compte unique n’affiche aucune rangée');
    check(menubar(`accountSwitcher(${all},'lowest')`) === '', '« lowest » non plus');
    check(menubar(`accountSwitcher(${all},'system:cpu')`) === '', 'les métriques système non plus');
    // Basculer garde la fenêtre choisie : on change de compte, pas de jauge.
    check(menubar(`accountSwitcher(${all},'claude:session')`).includes(`acct:claude:${pro.accountId}:session`),
          'la bascule conserve la fenêtre en cours');

    // Réglages : la rangée ne doit pas paraître vide dès qu'un compte est épinglé.
    const pinned = dashboard(`settingsView(${JSON.stringify({ ...data, prefs: { menuBarMetric: pinPro } })})`);
    // La liste d'épinglage plus bas allume elle aussi un segment : on ne compte que la rangée
    // des fenêtres, qui précède « pin-list ».
    const windowRow = pinned.split('pin-list')[0];
    const segs = windowRow.split('<button class="seg').filter(b => b.startsWith(' on'));
    check(segs.length === 1, 'exactement un segment de fenêtre reste allumé');
    check(segs[0].includes('Claude sem.'), 'et c’est bien la semaine Claude');
    const onFor = id => pinned.includes(`class="seg on" onclick="send('setMenuBarMetric',{value:'acct:claude:${id}:weekly'})"`);
    check(onFor(pro.accountId), 'le compte épinglé est marqué dans la liste');
    check(!onFor(perso.accountId), 'et pas l’autre compte');
  }

  section('popover — le compte le plus contraint, nommé');
  const picked = menubar(`pickAccount(${JSON.stringify([perso, pro])},'claude:weekly')`);
  checkEqual(picked?.label, 'Pro', 'le popover retient le compte le plus contraint');
  const block = menubar(`provider('claude','Claude',${JSON.stringify([perso, pro])},'claude:weekly')`);
  check(block.includes('name-sub">Pro'), 'et le nomme, puisqu’il y en a plusieurs');
  check(!menubar(`provider('claude','Claude',${JSON.stringify([perso])},'claude:weekly')`).includes('name-sub'),
        'compte unique : pas de nom redondant');

  section('aucun compte — l’app le dit au lieu de rester muette');
  const empty = JSON.stringify({ accounts: [], history: [], updatedAt: 0, accountLimit: 5 });
  check(dashboard(`overview(${empty})`).includes('Ajoutez un compte'), 'la vue Volumes invite à en ajouter un');
  check(dashboard(`connectionsView(${empty})`).includes('Aucun compte'), 'la vue Connexions le dit aussi');
  check(menubar(`provider('openai','OpenAI',[],'openai:weekly')`).includes("send('addAccount',{provider:'openai'})"), 'le popover propose l’ajout');

  section('compte non connecté — le bouton nomme une action réelle');
  {
    // Un gabarit imbriqué peut émettre « ${action} » littéralement au lieu de l'interpoler : le
    // bouton reste visible, et n'appelle rien.
    const sansCookie = { ...claudeAccount('a', 'Perso', []), cookieConfigured: false, orgId: '' };
    const html = menubar(`provider('claude','Claude',${JSON.stringify([sansCookie])},'claude:weekly')`);
    check(!html.includes('${'), 'aucune interpolation non résolue dans le HTML émis');
    check(html.includes(`send('configureClaudeCookie',{accountId:'${sansCookie.accountId}'})`),
          'le bouton cible l’action et le compte');
    const openaiVierge = { ...openAIAccount(3, 'Boulot', []), connected: false };
    check(menubar(`provider('openai','OpenAI',${JSON.stringify([openaiVierge])},'openai:weekly')`).includes(`send('loginOpenAI',{accountId:'${openaiVierge.accountId}'})`),
          'côté OpenAI aussi');
  }
}

process.stdout.write(`\n${failures ? '\x1b[31m' : '\x1b[32m'}${checks} vérifications, ${failures} échec(s)\x1b[0m\n\n`);
process.exit(failures ? 1 : 0);
