// Traduction partagée par les quatre surfaces web (dashboard, menubar, widget, picker).
//
// Le natif injecte `window.__STATUS_I18N__ = {lang, locale, dict, reverse}` avant le chargement
// de la page (WKUserScript), à partir de Resources/i18n/<langue>.json — la même source que le
// natif. Au changement de langue, il rappelle `StatusI18n.set(payload)` : la page se redessine
// via les écouteurs `StatusI18n.onChange`, sans rechargement.
//
// t('clé', {n:3})  → substitue {n}. Si la clé a des variantes `clé.one` / `clé.other` et que
// params.n existe, la variante est choisie selon la règle plurielle de la langue.
(function (root) {
  const listeners = [];
  const state = { lang: 'fr', locale: 'fr-FR', dict: {}, reverse: {} };
  const load = p => { if (p && p.dict) { state.lang = p.lang || 'fr'; state.locale = p.locale || 'fr-FR'; state.dict = p.dict; state.reverse = p.reverse || {}; formatters.clear(); cssStrings(); } };
  // Textes posés par les thèmes en CSS (`content:`) : les clés `css.a.b` deviennent des variables
  // `--i18n-a-b` sur <html>, lues par `content:var(--i18n-a-b,"repli")`.
  function cssStrings() {
    const html = root.document && root.document.documentElement;
    if (!html || !html.style) return;
    for (const key in state.dict)
      if (key.startsWith('css.')) html.style.setProperty('--i18n-' + key.slice(4).replace(/\./g, '-'), JSON.stringify(state.dict[key]));
  }
  const formatters = new Map();
  // Clés demandées mais absentes du dictionnaire : relevées pour les tests plutôt que perdues.
  const missing = new Set();

  const plural = n => state.lang === 'fr' ? (n < 2 ? 'one' : 'other') : (n === 1 ? 'one' : 'other');
  function t(key, params) {
    let s;
    if (params && typeof params.n === 'number') s = state.dict[key + '.' + plural(Math.abs(params.n))];
    if (s === undefined) s = state.dict[key];
    if (s === undefined) { missing.add(key); return key; }
    return params ? s.replace(/\{(\w+)\}/g, (m, k) => params[k] === undefined ? m : params[k]) : s;
  }
  // Texte produit par le natif ou un service en français (messages d'erreur, états) : traduit
  // s'il est référencé dans le dictionnaire, sinon rendu tel quel.
  const tm = s => (s != null && state.reverse[s]) ? t(state.reverse[s]) : s;

  // Libellés de fenêtres de quota produits par le natif en français canonique (« Semaine »,
  // « 3 j », « 7 j · Opus »…). L'identifiant reste français pour les clés d'historique ; seul
  // l'affichage est traduit.
  function label(l) {
    if (l == null) return l;
    let m;
    if (state.reverse[l]) return tm(l);
    if ((m = /^(\d+) sem\.$/.exec(l))) return t('q.weeksN', {n: +m[1]});
    if ((m = /^(\d+) j$/.exec(l))) return m[1] + ' ' + t('unit.day');
    if ((m = /^(\d+) h$/.exec(l))) return m[1] + ' ' + t('unit.hour');
    if ((m = /^7 j · (.+)$/.exec(l))) return t('q.sevenDaysModel', {model: m[1] === 'modèle' ? t('q.model') : m[1]});
    return l;
  }

  const nf = (opts) => {
    const k = JSON.stringify(opts);
    if (!formatters.has(k)) formatters.set(k, new Intl.NumberFormat(state.locale, opts));
    return formatters.get(k);
  };
  // Nombre localisé : 12,5 (fr, it, es) / 12.5 (en). `digits` fixe le nombre de décimales.
  const num = (v, digits) => nf(digits == null ? {maximumFractionDigits: 20} : {minimumFractionDigits: digits, maximumFractionDigits: digits}).format(v);
  const numMax = (v, max) => nf({maximumFractionDigits: max}).format(v);
  // Pourcentage : « 12,5 % » (fr, avec espace insécable fine), « 12.5% » (en), « 12,5% » (it, es).
  const pct = (v, digits = 0) => nf({style: 'percent', minimumFractionDigits: digits, maximumFractionDigits: digits}).format(v / 100);
  const money = (v, currency, digits = 2) => nf({style: 'currency', currency, currencyDisplay: 'narrowSymbol', minimumFractionDigits: digits, maximumFractionDigits: digits}).format(v);
  // Date/heure : options Intl.DateTimeFormat, toujours dans la langue de l'interface.
  const date = (v, opts) => new Intl.DateTimeFormat(state.locale, opts).format(v instanceof Date ? v : new Date(v));

  function apply(rootEl) {
    const doc = rootEl || (root.document && root.document.documentElement);
    if (!doc || !doc.querySelectorAll) return;
    if (root.document && root.document.documentElement) root.document.documentElement.lang = state.lang;
    for (const [attr, prop] of [['data-i18n', 'textContent'], ['data-i18n-html', 'innerHTML'], ['data-i18n-placeholder', 'placeholder'], ['data-i18n-title', 'title'], ['data-i18n-aria', 'ariaLabel']]) {
      doc.querySelectorAll('[' + attr + ']').forEach(el => {
        const v = t(el.getAttribute(attr));
        if (prop === 'ariaLabel') el.setAttribute('aria-label', v); else el[prop] = v;
      });
    }
  }
  function set(p) {
    load(p);
    apply();
    listeners.forEach(f => { try { f(state.lang); } catch (e) { console.error(e); } });
  }
  load(root.__STATUS_I18N__);
  root.t = t;
  root.StatusI18n = {t, tm, label, missing, num, numMax, pct, money, date, apply, set, onChange: f => listeners.push(f),
    get lang() { return state.lang; }, get locale() { return state.locale; }, get dict() { return state.dict; }};
})(typeof window !== 'undefined' ? window : globalThis);
