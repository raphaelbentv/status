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

process.stdout.write(`\n${failures ? '\x1b[31m' : '\x1b[32m'}${checks} vérifications, ${failures} échec(s)\x1b[0m\n\n`);
process.exit(failures ? 1 : 0);
