// Logique de quotas partagée par le tableau de bord et le popover (comme i18n.js : une seule
// copie, pour que les deux surfaces reconnaissent les mêmes fenêtres et ordonnent les mêmes comptes).
// Pur : aucune dépendance au DOM. Exposé en `StatusQuota`.
(function (root) {
  const isSession = w => w && (w.windowId === 'five_hour' || w.durationMinutes === 300 || w.label === '5 h');
  const isWeekly = w => w && (String(w.windowId || '').startsWith('seven_day') || w.durationMinutes === 10080 || w.label === 'Semaine' || w.label === '7 jours');
  const isCodexSpark = w => /spark/i.test(`${w?.windowId || ''} ${w?.label || ''}`);
  const isFable = w => w && (/fable/i.test(w.label || '') || /fable/i.test(w.windowId || ''));
  // Sous-quota hebdo dédié à un modèle (seven_day_scoped_fable) : un compteur à part, qui garde sa
  // carte mais ne pilote aucun chiffre agrégé (jauge, tri, tête d'affiche).
  const isScopedWeekly = w => isWeekly(w) && String(w?.windowId || '').includes('scoped');
  const used = w => w ? Math.max(0, Math.min(100, Math.round(Number(w.usedPercent)))) : null;
  const isConnected = (id, account) => id === 'openai' || ['code', 'web'].includes(account?.claudeSource)
    ? Boolean(account?.connected) : Boolean(account?.cookieConfigured && account?.orgId);
  // Hebdo « général » : ni sous-quota par modèle, ni Spark.
  const isMainWeekly = w => isWeekly(w) && !isScopedWeekly(w) && !isCodexSpark(w);
  // Le max reste voulu entre limites générales (OpenAI en expose plusieurs : afficher la première
  // venue montrerait 1 % pendant que l'autre est à 84 %).
  const mainWeekly = windows => (windows || []).filter(isMainWeekly).sort((a, b) => (used(b) ?? 0) - (used(a) ?? 0))[0] ?? null;
  // Fenêtre mesurée (pourcentage fini) et encore en cours (renouvellement à venir).
  const isLive = w => typeof w.usedPercent === 'number' && Number.isFinite(w.usedPercent) && Number(w.resetsAt) > Date.now() / 1000;
  const usableWindows = account => (account.windows || []).filter(w => isLive(w) && w.usedPercent >= 0 && w.usedPercent <= 100);

  function availability(account) {
    if (!isConnected(account.provider, account) || account.error || account.stale || (account.capturedAt && Date.now() / 1000 - account.capturedAt > 1800)) return null;
    const windows = usableWindows(account), weekly = windows.filter(isMainWeekly);
    if (!weekly.length) return null;
    const week = Math.max(...weekly.map(w => w.usedPercent));
    const session = windows.filter(isSession);
    if (account.provider === 'claude' && !session.length) return null;
    return {remaining: Math.max(0, 100 - week), available: week < 100 && session.every(w => w.usedPercent < 100), reset: Math.min(...weekly.map(w => Number(w.resetsAt)))};
  }
  // Tri par renouvellement : seule compte la date hebdo la plus proche. Une mesure ancienne ou une
  // fenêtre 5 h expirée (compte inactif) ne rend pas cette date moins valide.
  function weeklyReset(account) {
    if (!isConnected(account.provider, account) || account.error) return null;
    const weekly = usableWindows(account).filter(isMainWeekly);
    return weekly.length ? Math.min(...weekly.map(w => Number(w.resetsAt))) : null;
  }
  // Comparateurs partagés : prochain renouvellement d'abord (comptes sans date en dernier, à date
  // égale les données exploitables d'abord) ; ou le plus de volume restant.
  function compareByReset(a, b) {
    const ra = weeklyReset(a), rb = weeklyReset(b);
    if (ra === null || rb === null) return ra !== null ? -1 : rb !== null ? 1 : 0;
    return ra - rb || Number(availability(b) !== null) - Number(availability(a) !== null);
  }
  function compareByRemaining(a, b) {
    const aa = availability(a), bb = availability(b);
    if (!aa || !bb) return aa ? -1 : bb ? 1 : 0;
    return Number(bb.available) - Number(aa.available) || bb.remaining - aa.remaining;
  }
  root.StatusQuota = {isSession, isWeekly, isCodexSpark, isFable, isScopedWeekly, isMainWeekly, used, isConnected,
    mainWeekly, isLive, usableWindows, availability, weeklyReset, compareByReset, compareByRemaining};
})(typeof window !== 'undefined' ? window : globalThis);
