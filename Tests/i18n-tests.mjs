// Tests de la traduction : dictionnaires cohérents, clés du code toutes définies, rendu sans clé
// orpheline dans les quatre langues, formats de nombre propres à chaque langue.
//
//   ./scripts/run-tests.sh   (ou : node Tests/i18n-tests.mjs)

import { readFileSync, readdirSync } from 'node:fs';
import { createContext, runInContext } from 'node:vm';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const LANGS = ['fr', 'en', 'it', 'es'];
const LOCALES = { fr: 'fr-FR', en: 'en-US', it: 'it-IT', es: 'es-ES' };

let checks = 0, failures = 0;
const section = name => process.stdout.write(`\n\x1b[1m${name}\x1b[0m\n`);
const check = (condition, what, detail = '') => {
  checks++;
  if (condition) process.stdout.write(`  \x1b[32m✓\x1b[0m ${what}\n`);
  else { failures++; process.stdout.write(`  \x1b[31m✗ ${what}\x1b[0m${detail ? '\n     ' + detail : ''}\n`); }
};
const plain = text => String(text).replace(/[  ]/g, ' ');

const dictionaries = Object.fromEntries(LANGS.map(l =>
  [l, JSON.parse(readFileSync(join(root, 'Resources', 'i18n', `${l}.json`), 'utf8'))]));
const reverse = {};
for (const [key, value] of Object.entries(dictionaries.fr)) if (key.startsWith('msg.')) reverse[value] = key;
const payload = lang => ({ lang, locale: LOCALES[lang], dict: dictionaries[lang], reverse });
const placeholders = text => [...String(text).matchAll(/\{(\w+)\}/g)].map(m => m[1]).sort().join(',');
const tags = text => [...String(text).matchAll(/<\/?\w+[^>]*>/g)].map(m => m[0]).join('');

// ── Dictionnaires ───────────────────────────────────────────────────────────
section('Dictionnaires : mêmes clés, mêmes marqueurs');
const frKeys = Object.keys(dictionaries.fr).sort();
for (const lang of LANGS.slice(1)) {
  const keys = Object.keys(dictionaries[lang]).sort();
  const missing = frKeys.filter(k => !(k in dictionaries[lang]));
  const extra = keys.filter(k => !(k in dictionaries.fr));
  check(!missing.length && !extra.length, `${lang} : exactement les clés de fr (${keys.length})`,
    `manquantes: ${missing.slice(0, 8).join(', ')} · en trop: ${extra.slice(0, 8).join(', ')}`);
  const badPlaceholders = frKeys.filter(k => placeholders(dictionaries.fr[k]) !== placeholders(dictionaries[lang][k]));
  check(!badPlaceholders.length, `${lang} : mêmes {marqueurs} que fr`, badPlaceholders.slice(0, 8).join(', '));
  const badTags = frKeys.filter(k => tags(dictionaries.fr[k]) !== tags(dictionaries[lang][k]));
  check(!badTags.length, `${lang} : même HTML que fr`, badTags.slice(0, 8).join(', '));
  const empty = keys.filter(k => typeof dictionaries[lang][k] !== 'string' || !dictionaries[lang][k].trim());
  check(!empty.length, `${lang} : aucune valeur vide`, empty.slice(0, 8).join(', '));
}
// Identiques à dessein : noms propres, ou mots communs aux deux langues.
const SAME_ON_PURPOSE = new Set(['fan.autoApple', 'conn.sessionActive', 'icon.doubleArc', 'set.gauge.claudeWeek', 'set.gauge.openaiWeek']);
const untranslated = LANGS.slice(1).map(l => [l, frKeys.filter(k => !k.startsWith('msg.') && !SAME_ON_PURPOSE.has(k) && dictionaries[l][k] === dictionaries.fr[k] && /[a-zà-ÿ]{4,} [a-zà-ÿ]{3,}/i.test(dictionaries.fr[k]))]);
for (const [lang, same] of untranslated)
  check(same.length === 0, `${lang} : aucune phrase restée en français`, same.slice(0, 8).join(', '));

// ── Clés utilisées par le code ──────────────────────────────────────────────
section('Clés utilisées par le code : toutes définies');
// Lit les arguments de chaque appel t(...) en équilibrant les parenthèses, puis en extrait les
// littéraux de clé. Un littéral suivi de « + » est un préfixe (clé construite) : il suffit qu'au
// moins une clé de ce préfixe existe.
function keysCalledIn(source, opener) {
  const found = { exact: new Set(), prefix: new Set() };
  let from = 0, index;
  while ((index = source.indexOf(opener, from)) !== -1) {
    from = index + opener.length;
    if (index > 0 && /[\w$.]/.test(source[index - 1])) continue;  // l'appel d'une autre fonction (sept(, split()
    let depth = 1, cursor = from;
    while (cursor < source.length && depth) {
      const ch = source[cursor];
      if (ch === '(') depth++; else if (ch === ')') depth--;
      cursor++;
    }
    const args = source.slice(from, cursor - 1);
    for (const m of args.matchAll(/(['"`])((?:[a-z][\w]*\.)+[\w]*)\1(\s*\+)?/g)) {
      (m[3] ? found.prefix : found.exact).add(m[2]);
    }
  }
  return found;
}
const used = { exact: new Set(), prefix: new Set() };
const merge = f => { f.exact.forEach(k => used.exact.add(k)); f.prefix.forEach(k => used.prefix.add(k)); };
for (const file of readdirSync(join(root, 'Resources')).filter(f => /\.(html|js)$/.test(f))) {
  const source = readFileSync(join(root, 'Resources', file), 'utf8');
  merge(keysCalledIn(source, 't('));
  for (const m of source.matchAll(/data-i18n[\w-]*="([\w.]+)"/g)) used.exact.add(m[1]);
}
for (const file of readdirSync(join(root, 'Native')).filter(f => f.endsWith('.m'))) {
  const source = readFileSync(join(root, 'Native', file), 'utf8');
  for (const m of source.matchAll(/TMTP?\(@"([\w.]+)"/g)) used.exact.add(m[1]);
  for (const m of source.matchAll(/@"([a-z]+\.)" stringByAppendingString/g)) used.prefix.add(m[1]);
}
const defined = key => key in dictionaries.fr || (key + '.one') in dictionaries.fr;
const undefinedKeys = [...used.exact].filter(k => !defined(k));
check(used.exact.size > 300, `${used.exact.size} clés lues dans le code`);
check(!undefinedKeys.length, 'chaque clé utilisée existe', undefinedKeys.join(', '));
const deadPrefixes = [...used.prefix].filter(p => !frKeys.some(k => k.startsWith(p)));
check(!deadPrefixes.length, `${used.prefix.size} préfixes de clés construites ont des entrées`, deadPrefixes.join(', '));
const nativeWidgetIds = ['cpu', 'memory', 'gpu', 'network', 'temperature', 'battery', 'disk', 'claudeWeek', 'codexWeek', 'anthropicApi', 'openaiApi'];
check(nativeWidgetIds.every(id => defined('mw.' + id)), 'un libellé mw.* pour chaque widget de la barre des menus');
// Clés construites par le natif des comptes API (fournisseur, type d'alerte, code d'erreur) : le
// lecteur ci-dessus ne les voit pas, elles sont énumérées ici.
const apiNativeKeys = ['anthropic', 'openai'].flatMap(p => ['title', 'body', 'placeholder', 'invalid'].map(k => `api.key.${k}.${p}`))
  .concat(['low', 'empty', 'budget80', 'budget100'].flatMap(k => [`n.api.${k}.title`, `n.api.${k}.body`]))
  .concat(['auth', 'notFound', 'rateLimited', 'server', 'http', 'network', 'malformed', 'noKey'].map(k => `api.err.${k}`));
check(apiNativeKeys.every(defined), `${apiNativeKeys.length} clés construites des comptes API définies`, apiNativeKeys.filter(k => !defined(k)).join(', '));
// Les thèmes écrivent aussi du texte en CSS : il passe par var(--i18n-…), alimentée par les clés css.*.
const themeCSS = ['themes.css', ...readdirSync(join(root, 'Resources', 'themes')).map(f => 'themes/' + f)]
  .map(f => readFileSync(join(root, 'Resources', f), 'utf8')).join('\n');
const cssVars = [...themeCSS.matchAll(/var\(--i18n-([\w-]+)/g)].map(m => 'css.' + m[1].replace(/-/g, '.'));
check(cssVars.length && cssVars.every(defined), `${cssVars.length} textes CSS des thèmes ont leur clé css.*`,
  cssVars.filter(k => !defined(k)).join(', '));
const literalCSS = [...themeCSS.matchAll(/content:\s*"([^"]*)"/g)].map(m => m[1]).filter(s => /\p{L}{3,}/u.test(s) && s !== 'Status  /');
check(!literalCSS.length, 'aucun mot écrit en dur dans un content: CSS', literalCSS.join(' | '));

// ── Bac à sable web ─────────────────────────────────────────────────────────
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
    document: { documentElement: { dataset: {} }, querySelector: () => element(), querySelectorAll: () => [], addEventListener() {} },
    window: {}, setInterval() {}, setTimeout() {}, console,
    Intl, Date, Math, JSON, Number, String, Array, Object, isNaN, parseFloat, parseInt,
  };
  sandbox.window = sandbox;
  sandbox.__STATUS_I18N__ = payload('fr');
  const context = createContext(sandbox);
  runInContext(readFileSync(join(root, 'Resources', 'i18n.js'), 'utf8'), context);
  runInContext(script, context);
  return expression => runInContext(expression, context);
}

// ── Formats ─────────────────────────────────────────────────────────────────
section('Formats de nombre, de pourcentage et de devise selon la langue');
{
  const run = sandboxFor('widget.html');
  const at = lang => { run(`StatusI18n.set(${JSON.stringify(payload(lang))})`); };
  at('fr');
  check(plain(run('StatusI18n.pct(12.5,1)')) === '12,5 %', 'fr : 12,5 %', plain(run('StatusI18n.pct(12.5,1)')));
  check(plain(run("StatusI18n.money(412.8,'EUR')")) === '412,80 €', 'fr : 412,80 €', plain(run("StatusI18n.money(412.8,'EUR')")));
  at('en');
  check(run('StatusI18n.pct(12.5,1)') === '12.5%', 'en : 12.5%', run('StatusI18n.pct(12.5,1)'));
  check(run("StatusI18n.money(412.8,'EUR')") === '€412.80', 'en : €412.80', run("StatusI18n.money(412.8,'EUR')"));
  check(run("StatusI18n.money(1234.5,'USD')") === '$1,234.50', 'en : $1,234.50');
  at('it');
  check(plain(run('StatusI18n.pct(12.5,1)')) === '12,5%', 'it : 12,5%', plain(run('StatusI18n.pct(12.5,1)')));
  check(plain(run("StatusI18n.money(412.8,'EUR')")) === '412,80 €', 'it : 412,80 €');
  at('es');
  check(plain(run('StatusI18n.pct(12.5,1)')) === '12,5 %', 'es : 12,5 %', plain(run('StatusI18n.pct(12.5,1)')));
  check(plain(run("StatusI18n.money(412.8,'EUR')")) === '412,80 €', 'es : 412,80 €');
  at('en');
  check(run("StatusI18n.t('acct.count',{n:1})") === '1 account' && run("StatusI18n.t('acct.count',{n:3})") === '3 accounts', 'pluriels anglais');
  at('fr');
  check(run("StatusI18n.t('acct.count',{n:0})") === '0 compte' && run("StatusI18n.t('acct.count',{n:2})") === '2 comptes', 'pluriels français (0 et 1 au singulier)');
  check(run("StatusI18n.tm('Semaine')") === 'Semaine', 'tm : un libellé français se traduit vers lui-même en français');
  at('en');
  check(run("StatusI18n.label('Semaine')") === 'Week' && run("StatusI18n.label('3 sem.')") === '3 wk', 'libellés de fenêtres de quota traduits',
    `${run("StatusI18n.label('Semaine')")} / ${run("StatusI18n.label('3 sem.')")}`);
  check(run("StatusI18n.tm('Boost terminé · Auto Apple.')") !== 'Boost terminé · Auto Apple.', 'tm : message du service de ventilateurs traduit');
  check(run("StatusI18n.tm('Texte inconnu')") === 'Texte inconnu', 'tm : texte inconnu rendu tel quel');
}

// ── Rendu complet dans chaque langue ────────────────────────────────────────
section('Rendu complet de chaque surface : aucune clé orpheline, aucune valeur cassée');
{
  const now = Date.now() / 1000;
  const win = (windowId, label, usedPercent, resetsAt = now + 90000) => ({ windowId, label, usedPercent, resetsAt, durationMinutes: windowId === 'five_hour' ? 300 : 10080 });
  const accounts = [
    { accountId: 'a1', provider: 'openai', label: 'OpenAI 1', email: 'x@y.invalid', connected: true, plan: 'plus', capturedAt: now - 120, liveSource: true,
      windows: [win('seven_day', 'Semaine', 41)], billing: { status: 'known', nextAt: now + 4 * 86400, plan: 'plus' },
      manualReset: { status: 'available', observedAt: now, count: 2, credits: [{ expiresAt: now + 2 * 86400, title: 'Reset' }, { resetType: 'x' }] },
      extraCredits: { status: 'known', unit: 'money', currency: 'EUR', balance: 12.5, used: 3, monthlyLimit: 50, observedAt: now - 600 } },
    { accountId: 'c1', provider: 'claude', label: 'Claude 1', claudeSource: 'web', connected: true, cookieConfigured: true, orgId: 'o', capturedAt: now - 3000, stale: true, error: 'Session Claude indisponible. Vérifiez votre connexion web et réessayez.',
      windows: [win('five_hour', '5 h', 96, now + 4000), win('seven_day', '7 jours', 19), win('seven_day_scoped_opus', '7 j · Opus', 30)] },
    { accountId: 'c2', provider: 'claude', label: 'Claude 2', claudeSource: 'code', connected: false, windows: [] },
  ];
  const apiAccounts = [
    { accountId: 'p1', provider: 'anthropic', label: 'Anthropic API 1', mode: 'prepaid', keyConfigured: true, hasData: true, todayUSD: 3.2, monthUSD: 41.5,
      remainingUSD: 8.4, referenceUSD: 50, fraction: 0.17, severity: 1, balanceUSD: 50, balanceSetAt: Date.now() - 86400000, updatedAt: Date.now() - 120000, error: '' },
    { accountId: 'p2', provider: 'openai', label: 'OpenAI API 1', mode: 'budget', keyConfigured: true, hasData: true, todayUSD: 0, monthUSD: 120,
      remainingUSD: 80, referenceUSD: 200, fraction: 0.4, severity: 0, budgetUSD: 200, updatedAt: Date.now() - 60000, error: 'api.err.rateLimited' },
    { accountId: 'p3', provider: 'openai', label: 'OpenAI API 2', mode: 'none', keyConfigured: false, hasData: false, todayUSD: 0, monthUSD: 0, error: 'api.err.noKey' },
  ];
  const fans = { version: 2, active: true, verified: true, percent: 80, remainingSeconds: 300, message: 'Boost actif · vitesse vérifiée.', fans: [{ rpm: 2345, mode: 1, maxRPM: 6000 }] };
  const data = {
    accounts, apiAccounts, apiAccountLimit: 5, updatedAt: Date.now(), backoffCount: 2, refreshing: false,
    history: Array.from({ length: 30 }, (_, i) => ({ t: now - (30 - i) * 3600, p: { 'openai:a1:seven_day': 10 + i, 'claude:c1:seven_day': 5 + i } })),
    costs: { asOf: '2026-09-01', fxAsOf: '2026-09-02', eurPerUsd: 0.86, claude: { periods: { d8: { total: 412.8, breakdown: [{ model: 'opus', tokens: 61493255, cost: 412.8 }], prices: { opus: { input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75 } }, unpricedTokens: 2e6 }, d30: { total: 9000 } } } },
    displays: [{ id: 'd1', name: 'Écran interne', kind: 'builtin', available: true, brightness: 60 }, { id: 'd2', name: 'DELL', kind: 'external', available: false }],
    metricsLog: Array.from({ length: 40 }, (_, i) => ({ t: now - (40 - i) * 60, cpu: 10 + i, temp: 50 + i / 4, ram: 40, gpu: 5, batt: 80 })),
    tools: { awake: { active: false }, keyboardLock: { state: 'unlocked' }, lidMode: { authorized: true, fanBoost: fans, message: 'Désactivé.' } },
    prefs: { theme: 'blueprint', language: 'auto', menuBarMetric: 'claude:weekly', accessibilityTrusted: false, brightnessKeys: true, globalShortcut: true,
      menuBarWidgets: ['cpu', 'battery', 'claudeWeek', 'openaiApi'], apiRefreshIntervalSeconds: 600, notificationsAuthorized: false, providerIconStyles: { openai: 'tube', claude: 'grid' }, alerts: {}, quotaRefreshIntervalSeconds: 120, launchAtLogin: true },
  };
  const metrics = { families: [
    { id: 'cpu', now: { total: 42, core0: 30, core1: 50, coreTypes: 'PE' }, series: { total: [10, 20, 30, 42], core0: [1, 2, 3, 4], core1: [1, 2, 3, 4] } },
    { id: 'gpu', now: { usage: 12, renderer: 10, tiler: 5, memInUse: 3e8 }, series: { usage: [1, 2, 3], renderer: [1, 2, 3], tiler: [1, 2, 3] } },
    { id: 'ram', now: { usedPercent: 71, pressureLevel: 2, totalBytes: 3.4e10, usedBytes: 2.4e10, freeBytes: 1e10, appBytes: 1e10, wiredBytes: 4e9, compressedBytes: 2e9, cachedBytes: 5e9, swapUsedBytes: 3e9 }, series: { usedPercent: [60, 65, 71] } },
    { id: 'network', now: { rxBytesPerSec: 2411724, txBytesPerSec: 1024, 'rx:en0': 2411724, 'tx:en0': 1024, rxSessionBytes: 1e9, txSessionBytes: 1e8 }, series: { rxBytesPerSec: [1, 2, 3], txBytesPerSec: [1, 2, 3] } },
    { id: 'disk', now: { usedPercent: 71, totalBytes: 1e12, freeBytes: 2.9e11, readBytesPerSec: 1e6, writeBytesPerSec: 2e6, 'vol:/': 71, 'volTotal:/': 1e12, 'volFree:/': 2.9e11 }, series: { readBytesPerSec: [1, 2, 3], writeBytesPerSec: [1, 2, 3] } },
    { id: 'sensors', now: { tempC: 61, thermalState: 1, dieMaxC: 70, dieAvgC: 60, dieCount: 20, deviceMaxC: 40, deviceAvgC: 35, deviceCount: 4, fan0: 2345 }, series: { tempC: [50, 55, 61], fan0: [2000, 2300, 2345] } },
    { id: 'battery', now: { percent: 80, charging: false, externalConnected: true, healthPercent: 91, cycleCount: 218, powerWatts: -12.5, minutesRemaining: 305, temperatureC: 30, voltageV: 13.1, fullCapacity: 5000, designCapacity: 5500, adapterWatts: 96, conditionOK: true }, series: { percent: [80, 80, 80] } },
    { id: 'system', now: { uptimeSec: 437000, load1: 2.4, load5: 2.1, load15: 1.9, processCount: 600 }, series: { load1: [2, 2.4] } },
  ], processes: [{ name: 'Safari', cpuPercent: 12.5, rssBytes: 1e9, energyWatts: 1.5 }], intervalSeconds: 1 };

  const junk = /undefined|NaN|\[object|null</;
  for (const lang of LANGS) {
    const dash = sandboxFor('dashboard.html'), menu = sandboxFor('menubar.html'), wid = sandboxFor('widget.html');
    const set = run => run(`StatusI18n.set(${JSON.stringify(payload(lang))})`);
    [dash, menu, wid].forEach(set);
    dash(`appData=${JSON.stringify(data)};metricsData=${JSON.stringify(metrics)};settingsTab='accounts'`);
    const out = [];
    out.push(dash('overview(appData)'), dash('displaysView(appData)'));
    for (const group of ['accounts', 'appearance', 'quotas', 'alerts', 'system', 'shortcuts']) out.push(dash(`settingsView(appData,'${group}')`));
    for (const mode of ['charts', 'table', 'day']) { dash(`monitorMode='${mode}'`); out.push(dash('monitorView()')); }
    dash(`expanded.add('cpu');expanded.add('battery');expanded.add('disk');expanded.add('network')`);
    dash(`monitorMode='charts'`); out.push(dash('monitorView()'));
    menu(`lastData=${JSON.stringify(data)}`);
    out.push(menu(`provider('claude','Claude',${JSON.stringify(accounts.filter(a => a.provider === 'claude'))},'claude:weekly')`),
      menu(`provider('openai','OpenAI',${JSON.stringify(accounts.slice(0, 1))},'openai:weekly')`),
      menu(`fanControls(${JSON.stringify(data.tools)})`), menu(`tools(${JSON.stringify(data.tools)})`),
      menu(`brightnessRow(${JSON.stringify(data.displays)})`), menu(`extraCredits(${JSON.stringify(accounts[0])})`),
      menu(`apiCredits(${JSON.stringify(apiAccounts)})`));
    wid(`metrics=${JSON.stringify(metrics)};metrics.prefs={}`);
    for (const id of ['cpu', 'memory', 'gpu', 'network', 'temperature', 'battery', 'disk']) {
      wid(`widgetId='${id}'`);
      out.push(wid(`RENDERERS['${id}']()`));
    }
    const html = out.join('\n');
    const missing = [...new Set([dash, menu, wid].flatMap(run => run('[...StatusI18n.missing]')))];
    check(!missing.length, `${lang} : aucune clé manquante au rendu`, missing.join(', '));
    check(!junk.test(html), `${lang} : aucun undefined/NaN/[object] dans le rendu`, (html.match(new RegExp('.{40}(' + junk.source + ').{20}')) || [''])[0]);
    // Une chaîne française typique ne doit plus apparaître dans les autres langues.
    if (lang !== 'fr') check(!/Aucun compte|restant cette semaine|Moitié gauche|Actualiser|Mesure en cours/.test(html), `${lang} : pas de français résiduel dans le rendu`,
      (html.match(/.{30}(Aucun compte|restant cette semaine|Moitié gauche|Actualiser|Mesure en cours).{20}/) || [''])[0]);
    // La langue s'affiche dans son propre nom, quelle que soit celle de l'interface.
    check(['Français', 'English', 'Italiano', 'Español'].every(n => dash(`settingsView(appData,'appearance')`).includes(n)), `${lang} : sélecteur de langue avec les noms natifs`);
  }
}

process.stdout.write(`\n${failures ? '\x1b[31m' : '\x1b[32m'}${checks} vérifications, ${failures} échec(s)\x1b[0m\n\n`);
process.exit(failures ? 1 : 0);
