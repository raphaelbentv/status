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
// Intl met une fine insécable avant « % » en français : on la ramène à une espace pour comparer.
const plain = text => String(text).replace(/[\u202f\u00a0]/g, ' ');
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
const loadDictionary = lang => JSON.parse(readFileSync(join(root, 'Resources', 'i18n', `${lang}.json`), 'utf8'));
const LOCALES = { fr: 'fr-FR', en: 'en-US', it: 'it-IT', es: 'es-ES' };
function i18nPayload(lang) {
  const reverse = {};
  for (const [key, value] of Object.entries(loadDictionary('fr'))) if (key.startsWith('msg.')) reverse[value] = key;
  return { lang, locale: LOCALES[lang], dict: loadDictionary(lang), reverse };
}
function sandboxFor(htmlFile, language = 'fr') {
  const html = readFileSync(join(root, 'Resources', htmlFile), 'utf8');
  const script = html.slice(html.indexOf('<script>') + 8, html.lastIndexOf('</script>'));

  const element = () => ({
    innerHTML: '', textContent: '', className: '', style: {}, dataset: {}, disabled: false,
    classList: { toggle() {}, add() {}, remove() {}, contains: () => false },
    addEventListener() {}, querySelector: () => element(), querySelectorAll: () => [],
    getBoundingClientRect: () => ({ width: 0, height: 0, left: 0 }), closest: () => null,
  });
  const sandbox = {
    document: { documentElement: {dataset:{}}, querySelector: () => element(), querySelectorAll: () => [], addEventListener() {} },
    window: {}, setInterval() {}, setTimeout() {}, console,
    Intl, Date, Math, JSON, Number, String, Array, Object, isNaN, parseFloat, parseInt,
  };
  sandbox.window = sandbox;
  // Le natif injecte le dictionnaire avant la page : on fait de même (français, la langue des
  // assertions ci-dessous), puis i18n.js définit t() et StatusI18n comme dans l'app.
  sandbox.__STATUS_I18N__ = i18nPayload(language);
  const context = createContext(sandbox);
  runInContext(readFileSync(join(root, 'Resources', 'i18n.js'), 'utf8'), context);
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
checkEqual(dashboard('fmtBytes')(1024), '1,0 Ko/s', 'bascule au kilo-octet, une décimale');
checkEqual(dashboard('fmtBytes')(2411724), '2,3 Mo/s', 'méga-octets');
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
checkEqual(dashboard('METRIC_LABELS')['system.load1'][1], 'decimal',
  'la charge est décimale : arrondie à l’entier, 2,4 deviendrait 2 et ne dirait plus rien');
checkEqual(dashboard('METRIC_LABELS')['network.rxBytesPerSec'][1], 'bytes', 'les débits passent par fmtBytes');
checkEqual(dashboard('METRIC_LABELS')['cpu.total'][1], 'int', 'les pourcentages sont entiers');

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

// ── Cartes du popover (menubar.html) ───────────────────────────────────────
section('provider — une carte par fournisseur, volume hebdo en tête');
const openaiHTML = menubar('provider')('openai', 'OpenAI', [{ provider: 'openai', connected: true, label: 'Boulot', windows: [
  { windowId: 'seven_day', usedPercent: 42, resetsAt: Date.now() / 1000 + 90000 } ] }], 'openai:weekly');
const claudeHTML = menubar('provider')('claude', 'Claude', [{ provider: 'claude', cookieConfigured: true, orgId: 'org', label: 'Perso', windows: [
  { windowId: 'seven_day', usedPercent: 81, resetsAt: Date.now() / 1000 + 90000 },
  { windowId: 'five_hour', usedPercent: 4, resetsAt: Date.now() / 1000 + 9000 },
  { windowId: 'seven_day_scoped_fable', label: 'Fable', usedPercent: 54, resetsAt: Date.now() / 1000 + 90000 } ] }], 'claude:weekly');
check(openaiHTML.includes('58<span class="unit">%</span>') && openaiHTML.includes('restant cette semaine'), 'restant hebdo en grand');
check(claudeHTML.includes('19<span class="unit">%</span>') && claudeHTML.includes('class="value warning"'), 'Claude : semaine entamée signalée');
check(claudeHTML.includes('session-row') && plain(claudeHTML).includes('96 %'), 'la fenêtre 5 h reste en ligne compacte');
check(!claudeHTML.includes('Fable') && !claudeHTML.includes('54'), 'aucune jauge Fable');
check(!openaiHTML.includes('session-row'), 'pas de ligne 5 h côté OpenAI');
check(!claudeHTML.match(/réinitialisation hebdo|Prévision|épuisé/), 'ni prévision ni historique de reset');

// ── Coût par modèle (dashboard) ─────────────────────────────────────────────
section('fmtTokens — volumes de tokens, toujours en millions');
checkEqual(dashboard('fmtTokens')(186207), '0,2 M', 'sous le million : arrondi au dixième de million');
checkEqual(dashboard('fmtTokens')(61493255), '61,5 M', 'dizaines de millions, une décimale');
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
check(/91 %/.test(plain(wBat)) && /218/.test(wBat) && /13,10 V/.test(wBat), 'Batterie : santé, cycles, tension française');

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
check(quotaRow && plain(quotaRow).includes('80 %'), 'seuil quota : choix de pourcentages');
const resetRow = rows.split('<div class="wc-row">').find(r => r.includes('Réinitialisation'));
check(resetRow && !resetRow.includes('wc-shapes'), 'reset hebdo : interrupteur seul, pas de seuil');

// Le sous-quota hebdo Fable est épinglable dans la barre des menus, comme les autres fenêtres.
section('settingsView — épinglage de la semaine Fable');
const settings = dashboard(`settingsView({prefs:{}},'quotas')`);
check(!settings.includes("claude:weekly-fable"), 'Fable absent sans fenêtre correspondante');
check(!settings.includes('Claude Fable'), 'aucun libellé de métrique indisponible');

// Fabrique de comptes au format poussé par l'app : une liste, un payload par compte.
const uuid = n => `${String(n).repeat(8)}-${String(n).repeat(4)}-4${String(n).repeat(3)}-8${String(n).repeat(3)}-${String(n).repeat(12)}`;
const claudeAccount = (n, label, windows) => ({
  accountId: uuid(n === 'a' ? 1 : n === 'b' ? 2 : 3), provider: 'claude', label,
  windows, cookieConfigured: true, orgId: 'org', capturedAt: 0, error: '',
});
const openAIAccount = (n, label, windows) => ({
  accountId: uuid(n), provider: 'openai', label, windows, connected: true, error: '',
});

section('reset manuel — chaque jauge principale et état vérifié');
{
  const now=Math.floor(Date.now()/1000);
  const weekly={windowId:'seven_day',label:'7 jours',usedPercent:30,resetsAt:now+90000};
  const session={windowId:'five_hour',label:'5 h',usedPercent:40,resetsAt:now+9000};
  const scoped={windowId:'seven_day_scoped_fable',label:'Fable',usedPercent:60,resetsAt:now+90000};
  const claude={...claudeAccount('a','Perso',[]),manualReset:{status:'available',scope:'weekly',observedAt:now}};
  check(dashboard('manualResetLine')(weekly,claude).includes('disponible'),'offre Claude hebdo sous la semaine');
  checkEqual(dashboard('manualResetLine')(session,claude),'','offre Claude hebdo absente de la session');
  checkEqual(dashboard('manualResetLine')(scoped,claude),'','offre absente du quota de modèle');
  check(dashboard('manualResetLine')(session,{...claude,manualReset:{status:'available',scope:'session',observedAt:now}}).includes('disponible'),
    'offre Claude session sous le compteur 5 h');
  const openai={...openAIAccount(2,'Pro',[]),manualReset:{status:'available',count:2,observedAt:now}};
  const primary={...weekly,primaryLimit:true};
  check(dashboard('manualResetLine')(primary,openai).includes('2 disponibles'),'nombre OpenAI confirmé');
  checkEqual(dashboard('manualResetLine')({...primary,primaryLimit:false},openai),'','limite OpenAI secondaire exclue');
  const withExpiry=dashboard('manualResetLine')(primary,{...openai,manualReset:{status:'available',count:2,observedAt:now,credits:[{expiresAt:now+86400*0.5},{title:'Offert',resetType:'codexRateLimits'}]}});
  check(withExpiry.includes('expire le')&&withExpiry.includes('demain')&&withExpiry.includes('class="soon"'),'expiration proche datée et signalée');
  check(withExpiry.includes('Offert · sans expiration'),'crédit sans expiration jamais daté');
  const claudeReset=dashboard('manualResetLine')(weekly,{...claude,manualReset:{status:'available',scope:'weekly',count:1,observedAt:now,credits:[{title:'Réinitialisation complète',expiresAt:now+18*86400}]}});
  check(claudeReset.includes('Réinitialisation complète · expire le')&&claudeReset.includes('dans 18 j'),'expiration Claude datée');
  check(!dashboard('manualResetLine')(weekly,{...claude,manualReset:{status:'available',scope:'weekly',count:1,observedAt:now,credits:[{}]}}).includes('sans expiration'),'crédit Claude sans mention : jamais « sans expiration »');
  check(dashboard('manualResetLine')(weekly,{...claude,manualReset:{status:'available',scope:'weekly',count:1,observedAt:now,credits:[{expiryText:'bientôt'}]}}).includes('expiration : bientôt'),'mention non datée reprise telle quelle');
  checkEqual(dashboard('manualResetLine')(primary,{...openai,manualReset:{status:'none',observedAt:now}}),'',
    'aucun reset : pas de ligne inutile');
  checkEqual(dashboard('manualResetLine')(primary,{...openai,manualReset:{status:'available',count:2,observedAt:now-700}}),'',
    'ancien relevé positif jamais présenté comme actuel');
}

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

  section('overview — un bloc par compte, sans synthèse');
  const view = dashboard(`overview(${json})`);
  check(!view.includes('hero') && !view.includes('provider-summary'), 'ni héros ni synthèses en tête');
  check(view.includes('Perso') && view.includes('Boulot'), 'tous les comptes sont rendus');

  section('weeklySeriesFor — une série par compte');
  const series = dashboard(`weeklySeriesFor(${json})`);
  checkEqual(series.length, 3, 'trois séries pour trois comptes');
  check(new Set(series.map(s => s.key)).size === 3, 'trois clés distinctes');
  check(series.every(s => !String(s.color).includes('--chart-c')), 'aucune couleur ne pointe un jeton inexistant');

  section('numérotation des comptes — le numéro nomme, l’identité situe');
  {
    const nomme = { ...claudeAccount('a', 'Claude 1', []), orgName: 'Venio' };
    const chiffre = { ...openAIAccount(3, 'OpenAI 1', []), email: 'contact@venio.paris' };
    const view = JSON.stringify({ ...data, accounts: [chiffre, nomme] });
    const connections = dashboard(`connectionsView(${view})`);
    check(connections.includes('>OpenAI 1<'), 'le compte OpenAI porte son numéro');
    check(connections.includes('contact@venio.paris'), 'et l’e-mail reste visible en dessous');
    check(connections.includes('>Claude 1<'), 'le compte Claude porte son numéro');
    check(connections.includes('Venio'), 'et l’organisation reste visible');
    const overviewHTML = dashboard(`overview(${view})`);
    check(overviewHTML.includes('account-identity'), 'la vue Volumes situe aussi les comptes');
    checkEqual(dashboard(`accountIdentity(${JSON.stringify(nomme)})`), 'Venio', 'identité Claude = organisation');
    checkEqual(dashboard(`accountIdentity(${JSON.stringify(chiffre)})`), 'contact@venio.paris', 'identité OpenAI = e-mail');
    checkEqual(dashboard(`accountIdentity(${JSON.stringify({ ...nomme, orgName: '' })})`), '',
               'compte qui n’a pas encore répondu : rien plutôt qu’un intitulé inventé');
  }

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
  check(!dashboard(`settingsView(${JSON.stringify({ ...data, prefs: {} })},'quotas')`).includes('${'),
        'settingsView rend du HTML complet');

  section('settingsView — épinglage par compte');
  const settings2 = dashboard(`settingsView(${JSON.stringify({ ...data, prefs: {} })},'appearance')`);
  check(settings2.includes(`acct:claude:${pro.accountId}:weekly`), 'chaque compte Claude est épinglable');
  check(!settings2.includes(`acct:openai:${boulot.accountId}`), 'un fournisseur à compte unique n’encombre pas la liste');

  section('basculement rapide depuis la barre des menus');
  {
    const pinPro = `acct:claude:${pro.accountId}:weekly`;
    checkEqual(menubar(`parseMetric('${pinPro}')`).accountId, pro.accountId, 'une métrique épinglée se relit');
    checkEqual(menubar(`parseMetric('claude:weekly')`).accountId, undefined, 'un agrégat ne porte pas de compte');
    checkEqual(menubar(`parseMetric('lowest')`).lowest, true, '« lowest » est reconnu');
    checkEqual(menubar(`parseMetric('system:cpu')`).system, true, 'les métriques système aussi');

    // Le popover doit montrer le compte épinglé, sinon le geste n'a aucun retour à l'écran.
    checkEqual(menubar(`pickAccount(${JSON.stringify([perso, pro])},'${pinPro}')`).label, 'Pro',
               'la colonne suit le compte épinglé');
    checkEqual(menubar(`pickAccount(${JSON.stringify([perso, pro])},'acct:claude:inconnu:weekly')`).label, 'Pro',
               'un compte épinglé disparu retombe sur le plus contraint');
    checkEqual(menubar(`pickAccount(${JSON.stringify([pro, perso])},'claude:weekly')`).label, 'Pro',
               'sans épinglage, le plus contraint');

    // Le sélecteur intégré à la carte remplace la rangée de pastilles.
    const pickerHTML = menubar(`provider('claude','Claude',${JSON.stringify([perso, pro])},'${pinPro}')`);
    check(pickerHTML.includes('Le plus entamé'), 'un retour à l’agrégat est proposé');
    check(pickerHTML.includes(`value="${pro.accountId}" selected`), 'le compte épinglé est sélectionné');
    check(!menubar(`provider('claude','Claude',${JSON.stringify([perso, pro])},'claude:weekly')`).includes('" selected>Pro'), 'sans épinglage, l’agrégat est sélectionné');

    // Réglages : la fenêtre reste allumée quand un compte est épinglé, et le compte est sélectionné.
    const prefs = { providerMenuMetrics: { claude: pinPro, openai: 'openai:weekly' } };
    const pinned = dashboard(`settingsView(${JSON.stringify({ ...data, prefs })},'appearance')`);
    const claudeRow = pinned.slice(pinned.indexOf('Compte Claude'));
    check(/class="seg on" onclick="send\('setMenuBarMetric',\{value:'acct:claude:[^']+:weekly'\}\)">Semaine/.test(pinned),
          'la fenêtre Semaine reste allumée quand un compte est épinglé');
    check(claudeRow.includes(`value="${`acct:claude:${pro.accountId}:weekly`}" selected`), 'le compte épinglé est sélectionné dans la liste');
    check(!claudeRow.includes(`value="acct:claude:${perso.accountId}:weekly" selected`), 'et pas l’autre compte');
    check(!pinned.includes("value:'lowest'") && !pinned.includes("value:'system:"), 'plus de métrique « la plus élevée » ni système dans la jauge');
    check(!pinned.includes('${'), 'la section Barre des menus rend du HTML complet');

    // menuBarQuota : ce que montre l'icône, comme TMResolveMenuBarMetric.
    const quotaOf = (provider, prefsX) => dashboard(`menuBarQuota(${JSON.stringify({ ...data, prefs: prefsX })},'${provider}')`);
    check(Math.abs(quotaOf('claude', { providerMenuMetrics: { claude: pinPro } }).remaining - 0.28) < 1e-9, 'compte épinglé : son restant (72 % consommé)');
    check(Math.abs(quotaOf('claude', {}).remaining - 0.28) < 1e-9, 'sans épinglage : le compte le plus consommé');
    checkEqual(quotaOf('claude', { providerMenuMetrics: { claude: `acct:claude:${perso.accountId}:session` } }).remaining, null,
               'un compte sans fenêtre 5 h : donnée absente, pas le chiffre d’un autre');
    checkEqual(quotaOf('claude', { providerMenuMetrics: { claude: 'claude:session' } }).kind, 'session', 'la fenêtre 5 h se relit');
    checkEqual(quotaOf('openai', {}).accountId, '', 'OpenAI sans épinglage : agrégat');
    const icons = dashboard('ICON_DESIGNS.map(d=>d[0])');
    check(icons.length === 11, 'onze styles d’icône proposés');
    icons.forEach(id => { for (const rem of [null, 0, 0.5, 1]) {
      const svg = dashboard(`iconSvg('${id}',${rem},'#33A6FF',22)`);
      if (!svg.startsWith('<svg') || /NaN|undefined/.test(svg)) check(false, `${id} @${rem} : SVG valide`);
    } });
    check(true, 'chaque style se dessine à 0 %, 50 %, 100 % et sans donnée, sans NaN');
  }

  section('popover — le compte le plus contraint, nommé');
  const picked = menubar(`pickAccount(${JSON.stringify([perso, pro])},'claude:weekly')`);
  checkEqual(picked?.label, 'Pro', 'le popover retient le compte le plus contraint');
  const block = menubar(`provider('claude','Claude',${JSON.stringify([perso, pro])},'claude:weekly')`);
  check(block.includes('>Pro<'), 'et le nomme, puisqu’il y en a plusieurs');
  check(!menubar(`provider('claude','Claude',${JSON.stringify([perso])},'claude:weekly')`).includes('<select'),
        'compte unique : pas de sélecteur');

  section('aucun compte — l’app le dit au lieu de rester muette');
  const empty = JSON.stringify({ accounts: [], history: [], updatedAt: 0, accountLimit: 5 });
  check(dashboard(`overview(${empty})`).includes('Ajouter un compte'), 'la vue Volumes invite à en ajouter un');
  check(dashboard(`connectionsView(${empty})`).includes('Aucun compte'), 'la vue Connexions le dit aussi');
  check(menubar(`provider('openai','OpenAI',[],'openai:weekly')`).includes("send('addAccount',{provider:'openai'})"), 'le popover propose l’ajout');

  section('compte non connecté — le bouton nomme une action réelle');
  {
    // Un gabarit imbriqué peut émettre « ${action} » littéralement au lieu de l'interpoler : le
    // bouton reste visible, et n'appelle rien.
    const sansCookie = { ...claudeAccount('a', 'Perso', []), cookieConfigured: false, orgId: '' };
    const html = menubar(`provider('claude','Claude',${JSON.stringify([sansCookie])},'claude:weekly')`);
    check(!html.includes('${'), 'aucune interpolation non résolue dans le HTML émis');
    check(html.includes(`send('connectClaudeWeb',{accountId:'${sansCookie.accountId}'})`),
          'le bouton cible l’action et le compte');
    const openaiVierge = { ...openAIAccount(3, 'Boulot', []), connected: false };
    check(menubar(`provider('openai','OpenAI',${JSON.stringify([openaiVierge])},'openai:weekly')`).includes(`send('loginOpenAI',{accountId:'${openaiVierge.accountId}'})`),
          'côté OpenAI aussi');
  }
}

section('Claude Code : source, connexion et fraîcheur');
{
  const a={provider:'claude',accountId:'a',label:'Claude 1',claudeSource:'code',connected:true,email:'test@example.invalid',windows:[],capturedAt:0};
  check(dashboard('isConnected')('claude',a),'connecté sans cookie ni organisation web');
  const waiting=dashboard('claudePanel')(a);
  check(waiting.includes('Ouvrir Claude Code')&&waiting.includes('première réponse'),'première mesure explicitement attendue');
  check(!waiting.includes('Coller le cookie')&&!waiting.includes('en direct'),'pas de cookie ou de direct pour le bridge');
  check(dashboard('claudePanel')({...a,stale:true,capturedAt:100}).includes('Mesure ancienne'),'snapshot ancien visible');
  check(dashboard('claudePanel')({...a,connected:false}).includes('Utiliser Claude Code'),'connexion Claude Code toujours disponible');
  check(menubar(`provider('claude','Claude',${JSON.stringify([a])},'claude:weekly')`).includes('connecté · en attente'),'compte bridge reconnu connecté en barre des menus');
}

section('Disponibilité : fraîcheur, fenêtres comparables et quotas non cumulés');
{
  const future=Date.now()/1000+7200;
  const account={accountId:uuid(8),provider:'claude',claudeSource:'code',connected:true,label:'Disponible',capturedAt:Date.now()/1000,windows:[
    {windowId:'five_hour',label:'5 h',usedPercent:5,resetsAt:future},
    {windowId:'seven_day',label:'7 jours',usedPercent:25,resetsAt:future}]};
  checkEqual(dashboard('availability')(account).remaining,75,'restant hebdo = 100 moins consommé');
  checkEqual(dashboard('availability')({...account,stale:true}),null,'mesure ancienne exclue');
  checkEqual(dashboard('availability')({...account,capturedAt:Date.now()/1000-1900}),null,'âge recalculé indépendamment du drapeau');
  checkEqual(dashboard('availability')({...account,connected:false}),null,'compte déconnecté exclu');
  checkEqual(dashboard('availability')({...account,windows:[]}),null,'absence de donnée distincte de 100 % restant');
  checkEqual(dashboard('availability')({...account,windows:account.windows.slice(1)}),null,'Claude sans mesure 5 h non recommandé');
  checkEqual(dashboard('availability')({...account,windows:account.windows.map(w=>({...w,resetsAt:1}))}),null,'fenêtres expirées exclues');
  check(!dashboard('availability')({...account,windows:account.windows.map(w=>({...w,usedPercent:w.windowId==='five_hour'?100:25}))}).available,'quota 5 h épuisé empêche la recommandation');
  const spark={...account,provider:'openai',windows:[{windowId:'base',durationMinutes:10080,label:'Semaine',usedPercent:2,resetsAt:future},{windowId:'spark',durationMinutes:10080,label:'Spark',usedPercent:99,resetsAt:future}]};
  checkEqual(dashboard('availability')(spark).remaining,98,'la synthèse standard ne mélange pas Spark avec le quota général');
  checkEqual(dashboard('sortedAccounts')([{...account,label:'Ancien',stale:true},account])[0].label,'Disponible','tri place les données exploitables en premier');
}
section('Réglages regroupés, connexions compactes et données conditionnelles');
{
  const fable={...claudeAccount('a','Perso',[]),windows:[{windowId:'seven_day_scoped_fable',label:'Fable',usedPercent:10,resetsAt:9999999999}]};
  const data={prefs:{notificationsAuthorized:false},accounts:[fable,claudeAccount('b','Pro',[])]};
  const quotas=dashboard('settingsView')(data,'quotas');
  check(!dashboard('settingsView')(data,'appearance').includes('Claude Fable'),'jauge Fable retirée');
  check(!dashboard('accountBlock')(fable,[]).includes('Fable'),'aucun compteur Fable');
  const accountsTab=dashboard('settingsView')(data,'accounts');
  check(accountsTab.includes("send('addAccount',{provider:'claude'})")&&accountsTab.includes("send('refresh')"),'les comptes (ex-Connexions) sont dans Réglages');
  check(!dashboard('settingsView')(data,'system').includes("send('addAccount'"),'et seulement dans leur catégorie');
  check(!quotas.includes('Piloter la luminosité au clavier'),'raccourcis séparés des quotas');
  check(dashboard('settingsView')(data,'shortcuts').includes('Piloter la luminosité au clavier'),'raccourcis restent accessibles');
  check(dashboard('settingsView')(data,'alerts').includes('Quota entamé'),'alertes conservées');
  check(dashboard('settingsView')(data,'system').includes('Lancer au démarrage'),'système conserve le démarrage');
  check(dashboard('settingsView')(data,'appearance').includes('Thème'),'apparence conserve les thèmes');
  check(dashboard('notificationsNotice')(data).includes("send('openNotificationSettings')"),'lien explicite vers les notifications');
  checkEqual(dashboard('notificationsNotice')({prefs:{notificationsAuthorized:true}}),'','pas de fausse alerte quand les notifications fonctionnent');
  const conn=dashboard('claudePanel')({...fable,claudeSource:'code',connected:true});
  check(conn.includes('account-menu')&&conn.includes('Ouvrir Claude Code'),'action principale et menu secondaire');
  check(!conn.includes('quota-track')&&!conn.includes('quota-grid'),'pas de doublon des jauges dans Connexions');
  const disk=dashboard('storageSummary')({freeBytes:25*1024**3,totalBytes:512*1024**3});
  check(disk.includes('25 Go libres')&&disk.includes('512 Go'),'capacité et espace libre affichés');
  check(disk.includes("send('openStorageSettings')"),'accès au stockage');
}
section('Coût partiel pour les deux fournisseurs');
{
  dashboard(`appData={costs:{claude:{periods:{d8:{total:42,unpricedTokens:2000000,breakdown:[]}}},codex:{periods:{d8:{total:5,unpricedTokens:1000000,breakdown:[]}}}}}`);
  for(const id of ['claude','openai']){
    const html=dashboard('providerCostTotal')(id);
    check(html.includes('estimation partielle')&&html.includes('sans tarif'),'volumes exclus signalés pour '+id);
    check(html.includes('pas une facture'),'nature de l’estimation pour '+id);
  }
}
section('Popup : jauges, sous-quotas, sélecteurs et état inconnu');
{
  const windows=[{windowId:'weekly',durationMinutes:10080,label:'Semaine',usedPercent:25,resetsAt:9999999999},{windowId:'spark',durationMinutes:10080,label:'Spark',usedPercent:15,resetsAt:9999999999}];
  const one=openAIAccount(1,'Boulot',windows),two=openAIAccount(2,'Personnel',windows);
  const html=menubar('provider')('openai','OpenAI',[one,two],'openai:weekly');
  check(html.includes('role="meter"')&&plain(html).includes('75 % restant'),'jauge principale et restant');
  check(!html.includes('Spark')&&!html.includes('85 % restant'),'jauge Spark masquée dans le popup');
  checkEqual(dashboard('windowsFor')('openai',one).length,1,'listing OpenAI : seule la jauge générale reste');
  checkEqual(dashboard('weeklySeriesFor')({accounts:[one]}).length,1,'historique visuel : Spark exclu');
  check(html.includes('Compte OpenAI')&&html.includes('Personnel'),'choix de tous les comptes du fournisseur');
  check(html.includes('Renouvellement'),'réinitialisation près des jauges');
  checkEqual(menubar('quotaRail')(null),'','aucune jauge inventée sans valeur');
  check(menubar('quotaRail')({usedPercent:95,label:'Semaine'}).includes('var(--danger)'),'quota critique en couleur d’alerte');
  check(!menubar('provider')('openai','OpenAI',[{...one,windows:windows.map(w=>({...w,resetsAt:1}))}],'openai:weekly').includes('role="meter"'),'fenêtres expirées masquées dans le popup');
  menubar(`lastData=${JSON.stringify({accounts:[one,two],updatedAt:0})}`);
  menubar('window.sent=[]; window.webkit={messageHandlers:{native:{postMessage:m=>window.sent.push(m)}}}');
  menubar(`selectPopupAccount('openai','${two.accountId}')`);
  checkEqual(menubar('window.sent[0]'),{action:'setMenuBarMetric',value:`acct:openai:${two.accountId}:weekly`},'sélecteur popup transmet le compte à la jauge native');
  menubar(`selectPopupAccount('openai','unknown')`);
  checkEqual(menubar('window.sent.length'),1,'sélection inconnue ignorée');
  menubar(`selectPopupAccount('claude','${two.accountId}')`);
  checkEqual(menubar('window.sent.length'),1,'sélection appartenant à un autre fournisseur ignorée');
  check(menubar('provider')('openai','OpenAI',[one,two],`acct:openai:${two.accountId}:weekly`).includes(`value="${two.accountId}" selected`),'choix persisté reflété dans le sélecteur au prochain rendu');
}

const webClaude = {provider:'claude',accountId:'web-test',label:'Web',claudeSource:'web',connected:true,cookieConfigured:false,orgId:'org',capturedAt:Math.floor(Date.now()/1000),windows:[]};
check(dashboard('isConnected')('claude',webClaude),'session web connectée sans cookie collé');
check(!dashboard('isConnected')('claude',{...webClaude,connected:false}),'session web déconnectée signalée');
const webPanel=dashboard('claudePanel')(webClaude);
check(webPanel.includes('suivi automatique')&&webPanel.includes('connectClaudeWeb'),'action de connexion web et mode automatique');
check(!webPanel.includes('Recoller le cookie'),'aucun collage de cookie pour une session web');

check(!dashboard('accountBlock')(claudeAccount('a','Perso',[{windowId:'seven_day',label:'7 jours',usedPercent:30,resetsAt:9999999999}]),[]).match(/Prévision|réinitialisation hebdo|épuisé/),
  'ni prévision ni historique de reset dans les compteurs');
const lidSettings=dashboard('lidModeSettings');
check(lidSettings({tools:{lidMode:{authorized:false,available:true}}}).includes('Autoriser le service macOS'),'autorisation distincte du démarrage');
check(!lidSettings({tools:{lidMode:{authorized:false}}}).includes('onclick="startLidMode()"'),'aucun démarrage sans service autorisé');
check(lidSettings({tools:{lidMode:{authorized:true}}}).includes('Durée en minutes'),'durée personnalisée visible');
check(!lidSettings({tools:{lidMode:{authorized:true}}}).includes('40 °C'),'seuil numérique supprimé');
check(lidSettings({tools:{lidMode:{active:true,remainingSeconds:600}}}).includes('Arrêter maintenant'),'session active stoppable');
check(lidSettings({tools:{lidMode:{unconfirmed:true,active:true}}}).includes('État à vérifier'),'perte de connexion ne prétend pas active');
check(lidSettings({tools:{lidMode:{restorationPending:true}}}).includes('Arrêter et restaurer'),'restauration en attente visible');
check(dashboard('settingsView')({prefs:{},accounts:[],tools:{lidMode:{}}},'system').includes('Continuer capot fermé'),'réglage disponible dans Système');
check(menubar('tools')({lidMode:{active:true,remainingSeconds:61}}).includes('capot · 2 min'),'popup affiche durée restante');
check(!lidSettings({tools:{lidMode:{authorized:true}}}).includes('disabled'),'pas de dépendance à une sonde pour démarrer');



section('Facturation par compte');
{
  const line=dashboard('billingLine'),now=Date.now()/1000;
  checkEqual(line({}),'','inconnue : rien d’affiché');
  checkEqual(line({billing:{status:'unknown'}}),'','statut inconnu : rien');
  const exact=line({billing:{status:'known',nextAt:now+10*86400,estimated:false,plan:'pro'}});
  check(exact.includes('Facturation le')&&exact.includes('dans 10 j')&&exact.includes('Pro'),'date exacte, délai et offre');
  check(line({billing:{status:'known',nextAt:now+86400*2,estimated:true}}).includes('vers le'),'date reportée signalée');
  check(line({billing:{status:'known',nextAt:now+86400*2,estimated:false}}).includes('soon'),'échéance proche mise en avant');
  check(dashboard('accountBlock')({...claudeAccount('a','Perso',[]),billing:{status:'known',nextAt:now+5*86400}},[]).includes('Facturation le'),'visible dans le bloc du compte');
}
section('Crédits supplémentaires par compte');
{
  const render=dashboard('extraCreditsCard');
  checkEqual(render({}),'','solde inconnu : pas de carte, jamais un faux zéro');
  check(render({extraCredits:{status:'known',unit:'credits',balance:125.5}}).includes('125,5 crédits restants'),'solde OpenAI dans son unité');
  check(render({extraCredits:{status:'known',unit:'credits',unlimited:true}}).includes('illimités'),'crédits illimités explicites');
  const claude=render({extraCredits:{status:'known',unit:'money',currency:'USD',balance:12.5,used:3.68,monthlyLimit:50}});
  check(claude.includes('12,50')&&claude.includes('3,68')&&claude.includes('50,00'),'solde dépense et plafond Claude distincts');
  check(render({extraCredits:{status:'known',unit:'money',used:3.68}}).includes('Solde prépayé indisponible'),'dépense seule ne devient pas un solde');
}
section('Ventilateurs : autorisation, vérification et retour automatique');
{
  const settings=dashboard('fanBoostSettings'),popup=menubar('fanControls');
  check(settings({tools:{lidMode:{authorized:true}}}).includes('Mettre le service à jour'),'ancien service ne propose pas un boost inutilisable');
  check(!popup({lidMode:{authorized:true,fanBoost:{version:1}}}).includes('startFanBoost()'),'protocole v1 (sans Ftst) refusé');
  const lid={authorized:true,fanBoost:{version:2,active:false,fans:[{rpm:2345,mode:0}]}};
  check(settings({tools:{lidMode:lid}}).includes('Boost temporaire'),'boost disponible avec service compatible');
  check(popup({lidMode:lid}).replace(/[\u202f\u00a0]/g,' ').includes('2 345 tr/min'),'vitesse réelle dans le popup');
  check(popup({lidMode:lid}).includes("setFanChoice('percent',60)")&&popup({lidMode:lid}).includes("setFanChoice('minutes',30)"),'paliers et durées en un geste');
  lid.fanBoost={...lid.fanBoost,active:true,verified:false,percent:80,remainingSeconds:61};
  check(plain(popup({lidMode:lid})).includes('Montée 80 % · 2 min'),'montée en vitesse ne prétend pas boost confirmé');
  lid.fanBoost.verified=true;
  check(plain(popup({lidMode:lid})).includes('Boost 80 % · 2 min')&&popup({lidMode:lid}).includes('Auto Apple'),'boost confirmé avec arrêt immédiat');
  const stuck={authorized:true,fanBoost:{version:2,active:false,manualOutsideBoost:true,fans:[{rpm:4900,mode:1}]}};
  check(popup({lidMode:stuck}).includes("send('stopFanBoost')")&&popup({lidMode:stuck}).includes('Ventilateur en manuel'),'ventilateur resté en manuel réparable depuis le popup');
  check(settings({tools:{lidMode:stuck}}).includes('(manuel)'),'mode manuel signalé dans les réglages');
  lid.unconfirmed=true;
  check(popup({lidMode:lid}).includes('État à vérifier')&&!popup({lidMode:lid}).includes('Boost 80 %'),'rupture du service visible');
}
section('Popup : crédits du compte sélectionné');
{
  const render=menubar('provider'),credits=menubar('extraCredits');
  const one={...openAIAccount(1,'Boulot',[]),extraCredits:{status:'known',unit:'credits',balance:125.5}};
  const two={...openAIAccount(2,'Personnel',[]),extraCredits:{status:'known',unit:'credits',balance:42}};
  const first=render('openai','OpenAI',[one,two],`acct:openai:${one.accountId}:weekly`);
  const second=render('openai','OpenAI',[one,two],`acct:openai:${two.accountId}:weekly`);
  check(first.includes('125,5 crédits restants')&&!first.includes('42 crédits restants'),'solde du premier compte uniquement');
  check(second.includes('42 crédits restants')&&!second.includes('125,5 crédits restants'),'changement de compte change aussi le solde');
  checkEqual(credits({}),'','solde inconnu : rien plutôt qu’un faux zéro');
  check(credits({extraCredits:{status:'known',unit:'credits',balance:0}}).includes('0 crédits restants'),'solde nul explicite');
  check(credits({extraCredits:{status:'known',unit:'credits',unlimited:true}}).includes('Crédits illimités'),'solde illimité explicite');
  const claude=credits({extraCredits:{status:'known',unit:'money',balance:97,balanceCurrency:'EUR',currency:'USD',used:3,enabled:false}});
  check(claude.includes('97,00')&&claude.includes('€')&&!claude.includes('$'),'devise du solde Claude conservée');
  check(claude.includes('Usage supplémentaire désactivé'),'solde prépayé distinct de son activation');
  checkEqual(credits({extraCredits:{status:'known',unit:'money',used:3}}),'','dépense seule ne devient pas un solde');
  check(credits({extraCredits:{status:'known',unit:'credits',balance:42,observedAt:1}}).includes('Relevé il y a'),'ancienneté du relevé affichée');
}
// ── Thèmes : tableau JS, liste blanche native et feuilles de style doivent rester alignés ──
section('thèmes — THEMES, Status.m et feuilles CSS synchronisés');
{
  const ids = dashboard('THEMES.map(t=>t.id)');
  const native = readFileSync(join(root, 'Native', 'Status.m'), 'utf8');
  const allowed = [...native.slice(native.indexOf('validThemes = [NSSet setWithArray:'), native.indexOf(']]', native.indexOf('validThemes = [NSSet setWithArray:'))).matchAll(/@"([a-z]+)"/g)].map(m => m[1]);
  checkEqual([...ids].sort(), [...allowed].sort(), 'les identifiants de THEMES sont ceux acceptés par setTheme');
  const base = readFileSync(join(root, 'Resources', 'themes.css'), 'utf8');
  for (const id of ids) {
    let css = base;
    try { css += readFileSync(join(root, 'Resources', 'themes', id + '.css'), 'utf8'); } catch {}
    check(id === 'blueprint' || css.includes(`[data-theme="${id}"]`), `${id} : jetons [data-theme="${id}"] présents`);
  }
  for (const page of ['dashboard.html', 'menubar.html']) {
    const html = readFileSync(join(root, 'Resources', page), 'utf8');
    for (const id of ids.filter(i => ['moderne','dark','neon','bento','widget'].includes(i)))
      check(html.includes(`themes/${id}.css`), `${page} charge themes/${id}.css`);
  }
}

// ── Comptes API ─────────────────────────────────────────────────────────────
section('Comptes API — réglages et popover');
{
  const api = [
    { accountId: 'p1', provider: 'anthropic', label: 'Prod', mode: 'prepaid', keyConfigured: true, hasData: true, todayUSD: 3.2, monthUSD: 41.5,
      remainingUSD: -2, referenceUSD: 50, fraction: 0, severity: 2, balanceUSD: 50, balanceSetAt: Date.now() - 86400000, updatedAt: Date.now() - 120000, error: '' },
    { accountId: 'p2', provider: 'openai', label: 'Org', mode: 'budget', keyConfigured: true, hasData: true, todayUSD: 0, monthUSD: 120,
      remainingUSD: 80, referenceUSD: 200, fraction: 0.4, severity: 0, budgetUSD: 200, updatedAt: Date.now(), error: '' },
    { accountId: 'p3', provider: 'openai', label: 'Neuve', mode: 'none', keyConfigured: false, hasData: false, todayUSD: 0, monthUSD: 0, error: 'api.err.noKey' },
  ];
  dashboard(`appData=${JSON.stringify({ apiAccounts: api, apiAccountLimit: 5, prefs: { apiRefreshIntervalSeconds: 600 } })}`);
  const settings = plain(dashboard('apiConnectionsView(appData)'));
  check(settings.includes('≈ 0,00 $'), 'solde estimé épuisé : affiché à 0, jamais négatif');
  check(settings.includes('class="critical"'), 'solde épuisé : chiffre en rouge');
  check(settings.includes('80,00 $') && settings.includes('Reste du budget'), 'budget : reste du budget affiché');
  check(settings.includes(`send('configureApiKey',{accountId:'p3'})`), 'compte sans clé : la saisie passe par le natif');
  check(!/<input[^>]*(password|key)/i.test(settings), 'aucun champ de clé dans la page');
  check(settings.includes('Ni Anthropic ni OpenAI ne publient le solde'), 'l’estimation est annoncée comme telle');
  check(settings.includes(`seg on" onclick="send('setApiRefreshInterval',{seconds:600})`), 'cadence de relevé sélectionnée');
  checkEqual(dashboard(`apiWidgetAccountRow('openaiApi',{})`).includes('Le plus bas'), true, 'widget OpenAI : choix du compte quand il y en a deux');
  checkEqual(dashboard(`apiWidgetAccountRow('anthropicApi',{})`), '', 'widget Anthropic : un seul compte, pas de choix');
  checkEqual(dashboard(`apiWidgetAccountRow('cpu',{})`), '', 'autre widget : rien');

  checkEqual(menubar('apiCredits([])'), '', 'popover : rien sans compte API');
  const popup = plain(menubar(`apiCredits(${JSON.stringify(api)})`));
  check(popup.includes('≈ 0,00 $') && popup.includes('80,00 $ de budget'), 'popover : reste estimé et reste du budget');
  check(popup.includes('clé à saisir'), 'popover : clé manquante signalée');
  check((popup.match(/class="api-row"/g) || []).length === 3, 'popover : une ligne par compte');
}

process.stdout.write(`\n${failures ? '\x1b[31m' : '\x1b[32m'}${checks} vérifications, ${failures} échec(s)\x1b[0m\n\n`);
process.exit(failures ? 1 : 0);
