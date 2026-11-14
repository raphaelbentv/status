// Lecture de la section « Réinitialisation de la limite » de la page Utilisation de claude.ai.
//
// Corps d'une fonction asynchrone : TMClaudeSession l'exécute dans la page (callAsyncJavaScript)
// avec l'argument `expectedUsed`, le pourcentage hebdomadaire du relevé JSON. Rien n'est cliqué.
// Retourne { ready:false, why } tant que la page n'est pas lisible, sinon
// { ready:true, section, credits:[{ title, count, expiryText, expiresAt, scope, usable }] }.
//
// Forme réelle d'une ligne (novembre 2026), une feuille de texte par élément :
//   « Réinitialisation Fable » · « Expiration : 9 mars 2027, 08:59 UTC+1 » · une description ·
//   le bouton « Réinitialiser gratuitement » · parfois une note quand le bouton est désactivé.
const RESET_BUTTON = /reset\s+for\s+free|r[ée]initialiser\s+gratuitement/i;
const EXPIRY_LINE = /^(?:expiration|expires?(?:\s+on)?|expire\s+le)\s*:?\s*(.+)$/i;
const MONTHS = { janv: 0, jan: 0, févr: 1, fevr: 1, feb: 1, mars: 2, mar: 2, avr: 3, apr: 3, mai: 4, may: 4,
  juin: 5, jun: 5, juil: 6, jul: 6, août: 7, aout: 7, aug: 7, sept: 8, sep: 8, oct: 9, nov: 10, déc: 11, dec: 11 };
const flat = s => String(s || '').replace(/[-]/g, '').replace(/\s+/g, ' ').trim();

// « 9 mars 2027, 08:59 UTC+1 », « 10 déc., 23:00 UTC+1 », « Dec 10, 11:00 PM GMT+1 » → secondes Unix.
// Avec une heure et son décalage, l'instant est exact ; sinon, la fin de la journée locale.
// Sans année, c'est la prochaine occurrence de la date.
function parseExpiry(text, nowMs) {
  const m = text.match(/(\d{1,2})(?:er)?\s+([a-zéûô]+)\.?(?:,?\s+(\d{4}))?|([a-z]+)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?/i);
  if (!m) return null;
  const day = +(m[1] || m[5]), key = (m[2] || m[4] || '').toLowerCase();
  const month = MONTHS[key] ?? MONTHS[key.slice(0, 4)] ?? MONTHS[key.slice(0, 3)];
  if (month == null || !(day >= 1 && day <= 31)) return null;
  const given = +(m[3] || m[6]) || 0;
  const tm = text.match(/(\d{1,2})\s*[:h]\s*(\d{2})\s*(am|pm)?\s*(?:utc|gmt)\s*(?:([+\-−])\s*(\d{1,2})(?::?(\d{2}))?)?/i);
  const at = year => {
    if (!tm) return new Date(year, month, day, 23, 59, 59).getTime();
    let hour = +tm[1] % 24;
    const half = (tm[3] || '').toLowerCase();
    if (half === 'pm' && hour < 12) hour += 12;
    if (half === 'am' && hour === 12) hour = 0;
    const offset = ((+tm[5] || 0) * 60 + (+tm[6] || 0)) * (tm[4] && tm[4] !== '+' ? -1 : 1);
    return Date.UTC(year, month, day, hour, +tm[2]) - offset * 60000;
  };
  const year = given || new Date(nowMs).getFullYear();
  let ms = at(year);
  if (!given && ms < nowMs - 86400000) ms = at(year + 1);
  return Math.floor(ms / 1000);
}

// Une ligne de crédit. `leaves` : le texte de chaque élément feuille de la ligne, hors bouton ;
// `text` : la ligne entière à plat, repli quand le découpage en feuilles ne donne rien ;
// `unusable` : bouton désactivé ET note explicative présente.
function parseCredit(leaves, text, unusable, nowMs) {
  let title = '', expiry = '';
  const at = leaves.findIndex(s => EXPIRY_LINE.test(s));
  if (at >= 0) {
    expiry = leaves[at].match(EXPIRY_LINE)[1].trim();
    title = leaves.slice(0, at).find(s => !RESET_BUTTON.test(s)) || '';
  } else {
    const exp = text.match(/(?:expiration|expires\s+on|expire\s+le|expires?)\s*:?\s*([^·|]{3,40}?)(?=\s*(?:réinitialiser|reset\s+for|$))/i);
    expiry = exp ? exp[1].trim() : '';
    title = text.split(/expiration|expire/i)[0].replace(RESET_BUTTON, '').trim();
  }
  title = title.slice(0, 60);
  // Une ligne peut porter un effectif (« Réinitialisation Fable · 3 ») : un bouton, plusieurs crédits.
  const cm = title.match(/(?:\s*[·•×]|\s+x)\s*(\d{1,2})$/i), count = cm ? +cm[1] : 1;
  if (cm) title = title.slice(0, cm.index).trim();
  // La portée se lit dans le titre : la description du reset Fable parle elle aussi de limite hebdomadaire.
  const basis = title || text;
  const scope = /fable/i.test(basis) ? 'fable' : /5\s*h|five.hour|session/i.test(basis) ? 'session'
    : /complète|full|hebdo|week/i.test(basis) ? 'weekly' : 'unknown';
  return { title, count, expiryText: expiry, expiresAt: expiry ? parseExpiry(expiry, nowMs) : null, scope, usable: !unusable };
}

// Les tests n'exécutent que les deux fonctions pures ci-dessus.
if (typeof __resetProbeTest !== 'undefined') return { parseExpiry, parseCredit };

if (location.origin !== 'https://claude.ai' ||
    !(location.pathname.startsWith('/settings/usage') || location.hash.startsWith('#settings/usage')))
  return { ready: false, why: 'page' };

const read = () => {
  const body = document.body?.innerText || '';
  if (!/cette semaine|this week/i.test(body)) return { ready: false, why: 'gauges' };
  // Garde de fraîcheur : si la jauge hebdo est lisible, elle doit refléter le relevé JSON.
  const meters = [...document.querySelectorAll('[role=progressbar],[role=meter],progress')];
  const name = e => { const id = e.getAttribute('aria-labelledby');
    return e.getAttribute('aria-label') || (id && document.getElementById(id)?.textContent) || e.parentElement?.textContent || ''; };
  const meter = meters.find(e => /^(cette semaine|this week|weekly usage)\b/i.test(name(e).trim()));
  const used = parseFloat(meter?.getAttribute('aria-valuenow') ?? meter?.value ?? meter?.getAttribute('aria-valuetext'));
  if (meter && Number.isFinite(used) && Math.abs(used - expectedUsed) > 3)
    return { ready: false, why: `meter page=${used} json=${expectedUsed} path=${location.pathname}${location.hash} n=${meters.length} first=${name(meters[0]).trim().slice(0, 24)}` };

  let buttons = [...document.querySelectorAll('button,[role=button]')].filter(b =>
    !b.closest('[aria-hidden=true]') && getComputedStyle(b).display !== 'none' &&
    RESET_BUTTON.test((b.textContent || '') + ' ' + (b.getAttribute('aria-label') || '')));
  buttons = buttons.filter(b => !buttons.some(o => o !== b && b.contains(o)));  // le plus interne seulement
  let waiting = 0;  // boutons désactivés : la page peut encore être en train de les activer
  const credits = buttons.map(b => {
    // La ligne du crédit : le plus petit ancêtre qui porte l'expiration, sans jamais englober le
    // bouton d'un autre crédit. Aucune limite de longueur : la ligne Fable porte une description.
    let row = b.parentElement;
    for (let e = row, n = 0; e && n < 6; n++, e = e.parentElement) {
      if (buttons.some(o => o !== b && e.contains(o))) break;
      row = e;
      if (/expir/i.test(e.innerText || '')) break;
    }
    // Un bouton désactivé reste un crédit détenu. Il n'est annoncé « pas utilisable » que si la page
    // dit pourquoi, par une note placée après le bouton (« Il n'y a pour le moment aucune
    // utilisation de Fable à réinitialiser. ») : un bouton désactivé sans note est l'état d'attente
    // de la page, dont la vue cachée de l'app ne sort pas toujours.
    const disabled = !!b.disabled || b.getAttribute('aria-disabled') === 'true';
    if (disabled) waiting++;
    const text = flat(row?.innerText);
    if (!row || (!/expir/i.test(text) && text.length > 240)) return { title: '', count: 1, scope: 'unknown', usable: true };
    const leafNodes = [...row.querySelectorAll('*')].filter(x => !x.children.length && !b.contains(x) && flat(x.textContent));
    const noted = leafNodes.some(x => b.compareDocumentPosition(x) & Node.DOCUMENT_POSITION_FOLLOWING);
    return parseCredit(leafNodes.map(x => flat(x.textContent)), text, disabled && noted, Date.now());
  });
  return { ready: true, section: /réinitialisation de la limite|limit reset/i.test(body), credits, waiting };
};

// La page est une SPA qui se remplit par morceaux : une lecture n'est retenue que si elle ne bouge
// plus. Les boutons s'affichent d'abord tous désactivés, puis claude.ai active ceux qui sont
// utilisables et annote les autres (constaté : un quart de seconde plus tard dans un navigateur).
// Tant qu'un bouton est désactivé, on attend donc quatre secondes sans changement ; sinon 300 ms.
let last = read();
if (!last.ready) return last;
const started = Date.now();
let since = started;
while (Date.now() - started < 15000) {
  await new Promise(resolve => setTimeout(resolve, 300));
  const next = read();
  if (!next.ready) return next;
  if (JSON.stringify(next) !== JSON.stringify(last)) { last = next; since = Date.now(); continue; }
  if (Date.now() - since >= (last.waiting ? 4000 : 300)) return last;
}
return { ready: false, why: 'moving' };
