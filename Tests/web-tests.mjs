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
check(/Utilisateur/.test(wCPU) && /Système/.test(wCPU), 'CPU : découpe utilisateur/système présente');
check(/2,66 · 3,16 · 3,68/.test(wCPU), 'CPU : charge moyenne en décimales françaises');
check(wCPU.indexOf('Gros CPU') > -1 && wCPU.indexOf('Gros CPU') < wCPU.indexOf('Grosse RAM'),
  'CPU : liste des processus triée par CPU (le plus gros d’abord)');

const wMem = widget('renderMemory()');
check(noJunk(wMem), 'Mémoire : aucun NaN/undefined/null');
check(/App/.test(wMem) && /Compressée/.test(wMem) && /Cache/.test(wMem), 'Mémoire : répartition app/compressée/cache');
check(/13,4 Go/.test(wMem), 'Mémoire : octets en Go français (App 13,4 Go)');
check(wMem.indexOf('Grosse RAM') > -1 && wMem.indexOf('Grosse RAM') < wMem.indexOf('Gros CPU'),
  'Mémoire : liste des processus triée par RAM');

const wNet = widget('renderNetwork()');
check(noJunk(wNet), 'Réseau : aucun NaN/undefined/null');
check(/Session/.test(wNet) && /4,2 Mo/.test(wNet), 'Réseau : totaux de session cumulés');

const wSens = widget('renderTemperature()');
check(noJunk(wSens), 'Capteurs : aucun NaN/undefined/null');
check(/3.184 tr\/min/.test(wSens) && /3.188 tr\/min/.test(wSens), 'Capteurs : les deux ventilateurs');

const wBat = widget('renderBattery()');
check(noJunk(wBat), 'Batterie : aucun NaN/undefined/null');
check(/91 %/.test(wBat) && /218/.test(wBat) && /13,10 V/.test(wBat), 'Batterie : santé, cycles, tension française');

const wDisk = widget('renderDisk()');
check(noJunk(wDisk), 'Disque : aucun NaN/undefined/null');
check(/Macintosh HD/.test(wDisk) && /libres/.test(wDisk), 'Disque : volume nommé avec espace libre');

const wGPU = widget('renderGPU()');
check(noJunk(wGPU), 'GPU : aucun NaN/undefined/null');
check(!/Processus/.test(wGPU), 'GPU : pas de liste de processus (charge GPU par process non mesurable)');

process.stdout.write(`\n${failures ? '\x1b[31m' : '\x1b[32m'}${checks} vérifications, ${failures} échec(s)\x1b[0m\n\n`);
process.exit(failures ? 1 : 0);
