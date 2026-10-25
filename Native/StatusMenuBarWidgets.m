#import "StatusI18n.h"
#import "StatusMenuBarWidgets.h"

#pragma mark - Catalogue

NSArray<NSString *> *TMMenuBarWidgetIDs(void) {
    return @[@"cpu", @"memory", @"gpu", @"network", @"temperature", @"battery", @"disk",
             @"claudeWeek", @"codexWeek", @"anthropicApi", @"openaiApi"];
}

NSString *TMMenuBarWidgetLabel(NSString *widgetId) {
    if (![TMMenuBarWidgetIDs() containsObject:widgetId]) return widgetId;
    return TMT([@"mw." stringByAppendingString:widgetId]);
}

NSArray<NSString *> *TMArrayByMovingItem(NSArray<NSString *> *list, NSString *item, NSInteger delta) {
    if (!list.count || !item || !delta) return list ?: @[];
    NSUInteger from = [list indexOfObject:item];
    if (from == NSNotFound) return list;
    NSInteger to = (NSInteger)from + delta;
    if (to < 0 || to >= (NSInteger)list.count) return list;  // en butée : rien à faire
    NSMutableArray *result = [list mutableCopy];
    [result removeObjectAtIndex:from];
    [result insertObject:item atIndex:(NSUInteger)to];
    return result;
}

#pragma mark - Accès au snapshot

// `now` d'une famille du snapshot, ou nil si la famille n'a pas répondu ce tick.
static NSDictionary *TMFamilyNow(NSDictionary *snapshot, NSString *familyId) {
    for (NSDictionary *family in snapshot[@"families"])
        if ([family[@"id"] isEqual:familyId]) return family[@"now"];
    return nil;
}

static NSArray<NSNumber *> *TMFamilySeries(NSDictionary *snapshot, NSString *familyId, NSString *key) {
    for (NSDictionary *family in snapshot[@"families"])
        if ([family[@"id"] isEqual:familyId]) {
            NSArray *series = family[@"series"][key];
            return [series isKindOfClass:NSArray.class] ? series : @[];
        }
    return @[];
}

// Les deux widgets de consommation hebdomadaire (un par IA) : ils ne lisent pas le moniteur
// système mais les familles quota injectées dans le snapshot par Status.m.
BOOL TMWidgetIsQuota(NSString *widgetId) {
    return [widgetId isEqual:@"claudeWeek"] || [widgetId isEqual:@"codexWeek"];
}

// Crédit des comptes API (un widget par fournisseur) : familles injectées par Status.m, déjà
// calculées (texte en dollars, fraction restante, sévérité) — le moteur ne fait que dessiner.
BOOL TMWidgetIsApi(NSString *widgetId) {
    return [widgetId isEqual:@"anthropicApi"] || [widgetId isEqual:@"openaiApi"];
}

BOOL TMWidgetUsesAccounts(NSString *widgetId) {
    return TMWidgetIsQuota(widgetId) || TMWidgetIsApi(widgetId);
}

static NSNumber *TMNum(id value) { return [value isKindOfClass:NSNumber.class] ? value : nil; }

// Débit en octets/s → texte court (« 74 Ko/s »). Même échelle que les surfaces web.
static NSString *TMFmtRate(double bytesPerSec) {
    const char *units[] = { "o/s", "Ko/s", "Mo/s", "Go/s" };
    int i = 0;
    double v = bytesPerSec;
    while (v >= 1024 && i < 3) { v /= 1024; i++; }
    if (i == 0) return [NSString stringWithFormat:@"%.0f %s", v, units[i]];
    return [NSString stringWithFormat:(v < 10 ? @"%.1f %s" : @"%.0f %s"), v, units[i]];
}

// Durée en minutes → « 2 h 14 » / « 45 min ».
static NSString *TMFmtMinutes(long long minutes) {
    if (minutes <= 0) return @"";
    long long h = minutes / 60, m = minutes % 60;
    return h ? [NSString stringWithFormat:@"%lld h %02lld", h, m] : [NSString stringWithFormat:@"%lld min", m];
}

#pragma mark - Readout (pur)

// Sévérité d'un widget (0 normal, 1 avertissement, 2 critique). Volontairement rare : seuls des
// états réellement anormaux colorent l'icône — un CPU chargé n'est pas une urgence (même
// philosophie que la jauge quota, qui ne teinte qu'en alerte).
static NSInteger TMWidgetSeverity(NSString *widgetId, NSDictionary *snapshot) {
    if ([widgetId isEqual:@"temperature"]) {
        NSNumber *t = TMNum(TMFamilyNow(snapshot, @"sensors")[@"tempC"]);
        if (t) { if (t.doubleValue >= 95) return 2; if (t.doubleValue >= 85) return 1; }
    } else if ([widgetId isEqual:@"battery"]) {
        NSDictionary *b = TMFamilyNow(snapshot, @"battery");
        NSNumber *pct = TMNum(b[@"percent"]);
        BOOL charging = [TMNum(b[@"charging"]) boolValue] || [TMNum(b[@"externalConnected"]) boolValue];
        if (pct && !charging) { if (pct.doubleValue <= 10) return 2; if (pct.doubleValue <= 20) return 1; }
    } else if ([widgetId isEqual:@"memory"]) {
        NSNumber *p = TMNum(TMFamilyNow(snapshot, @"ram")[@"pressureLevel"]);
        if (p) { if (p.intValue >= 4) return 2; if (p.intValue >= 2) return 1; }
    } else if (TMWidgetIsQuota(widgetId)) {
        // Mêmes seuils que la jauge quota (TMSeverityForPercent) : un seul vocabulaire d'urgence
        // dans toute la barre des menus, que le chiffre vienne de la jauge ou d'un widget.
        NSNumber *pct = TMNum(TMFamilyNow(snapshot, widgetId)[@"percent"]);
        if (pct) { if (pct.doubleValue >= 95) return 2; if (pct.doubleValue >= 80) return 1; }
    } else if (TMWidgetIsApi(widgetId)) {
        // Seuils propres au compte (solde sous le seuil d'alerte, budget à 80 %), calculés en amont.
        return MIN(2, MAX(0, TMNum(TMFamilyNow(snapshot, widgetId)[@"severity"]).integerValue));
    }
    return 0;
}

// Arrondi à 1 % : les fractions de détail (parts mémoire, débits) bougent à chaque tick de quelques
// millièmes ; sans cet arrondi la signature de rendu changerait à 1 Hz pour des pixels identiques.
static double TMRound2(double v) { return round(MIN(MAX(v, 0), 1) * 100.0) / 100.0; }

// Débit → 0..1 sur une échelle logarithmique (0 = rien, 1 = 100 Mo/s ou plus). Un débit réseau
// s'étale sur six ordres de grandeur : en linéaire, tout ce qui n'est pas un téléchargement massif
// resterait collé à zéro. Sert aux arcs ↓/↑ et à la sparkline réseau.
double TMWidgetRateFraction(double bytesPerSec) {
    if (!(bytesPerSec > 0)) return 0;
    const double maxRate = 100.0 * 1024 * 1024;
    return MIN(1.0, log10(1.0 + bytesPerSec / 1024.0) / log10(1.0 + maxRate / 1024.0));
}

// Nombre arrondi sans unité (« 43 ») : le chiffre des formes qui le dessinent (anneau chiffré, puce).
static NSString *TMPlain(NSNumber *value) {
    return [NSString stringWithFormat:@"%.0f", round(value.doubleValue)];
}

// Répartition de la RAM en parts du total, dans l'ordre app / système (wired) / compressée / cache.
// Champs RÉELS du collecteur (appBytes, wiredBytes, compressedBytes, cachedBytes, totalBytes) ;
// @[] si l'un manque — le dessin retombe alors sur dix segments de charge. Rien n'est déduit ni
// complété : le reste de l'anneau est la mémoire libre.
static NSArray<NSNumber *> *TMMemoryParts(NSDictionary *ram) {
    NSNumber *total = TMNum(ram[@"totalBytes"]);
    if (!total || total.doubleValue <= 0) return @[];
    NSMutableArray *parts = [NSMutableArray array];
    double sum = 0;
    for (NSString *key in @[@"appBytes", @"wiredBytes", @"compressedBytes", @"cachedBytes"]) {
        NSNumber *bytes = TMNum(ram[key]);
        if (!bytes) return @[];
        double share = TMRound2(bytes.doubleValue / total.doubleValue);
        sum += share;
        [parts addObject:@(share)];
    }
    return sum <= 1.04 ? parts : @[];  // incohérent (sommes qui débordent) : mieux vaut ne pas dessiner
}

static NSString *TMPct(NSNumber *value) {
    return value ? [NSString stringWithFormat:@"%.0f %%", round(value.doubleValue)] : @"—";
}

// Gabarits de largeur : le texte le plus large que ce widget puisse afficher. Ils fixent la
// largeur de l'icône une fois pour toutes, indépendamment de la mesure du moment — c'est ce qui
// empêche la rangée de glisser quand « 8 o/s » devient « 999 Mo/s ». Volontairement du texte
// réel plutôt qu'un nombre de caractères : seule une mesure typographique dit la vraie largeur.
static NSDictionary *TMWidgetTemplates(NSString *widgetId) {
    // template = bloc deux lignes dessiné ; valueTemplate = valeur seule (titre système, forme texte).
    if ([widgetId isEqual:@"network"])     return @{ @"template": @"↓ 999 Mo/s", @"valueTemplate": @"↓ 999 Mo/s" };
    if ([widgetId isEqual:@"temperature"]) return @{ @"template": @"100 W", @"valueTemplate": @"100°" };
    if ([widgetId isEqual:@"battery"])     return @{ @"template": @"10 h 00", @"valueTemplate": @"100 %" };
    if (TMWidgetIsApi(widgetId))           return @{ @"template": @"$9,999", @"valueTemplate": @"$9,999" };  // remplacé par celui de la famille
    return @{ @"template": @"100 %", @"valueTemplate": @"100 %" };  // cpu, gpu, memory, disk
}

NSDictionary *TMWidgetReadout(NSString *widgetId, NSDictionary *snapshot) {
    NSDictionary *templates = TMWidgetTemplates(widgetId);
    NSMutableDictionary *r = [@{ @"style": @"pie", @"hasValue": @NO, @"title": @"", @"value": @"",
                                 @"primary": @"", @"secondary": @"", @"fraction": @0,
                                 @"series": @[], @"charging": @NO,
                                 // Champs des formes Anneaux / Console (voir l'en-tête) :
                                 @"widget": widgetId ?: @"", @"numeric": @NO, @"dual": @NO,
                                 @"chipLabel": @"", @"chipValue": @"", @"chipUnit": @"",
                                 @"chipKind": @"reservoir", @"autoScale": @NO,
                                 @"parts": @[], @"rxFraction": @0, @"txFraction": @0,
                                 @"template": templates[@"template"],
                                 @"valueTemplate": templates[@"valueTemplate"],
                                 @"severity": @(TMWidgetSeverity(widgetId, snapshot)) } mutableCopy];

    if ([widgetId isEqual:@"cpu"] || [widgetId isEqual:@"gpu"]) {
        NSString *fam = widgetId, *key = [widgetId isEqual:@"cpu"] ? @"total" : @"usage";
        NSNumber *value = TMNum(TMFamilyNow(snapshot, fam)[key]);
        r[@"style"] = @"bars";
        r[@"numeric"] = @YES; r[@"chipKind"] = @"spark";
        r[@"chipLabel"] = [widgetId isEqual:@"cpu"] ? @"CPU" : @"GPU";
        if (value) {
            r[@"hasValue"] = @YES;
            r[@"title"] = r[@"value"] = TMPct(value);
            r[@"chipValue"] = TMPlain(value); r[@"chipUnit"] = @"%";
            r[@"fraction"] = @(MIN(MAX(value.doubleValue / 100.0, 0), 1));
            r[@"series"] = TMFamilySeries(snapshot, fam, key);
        }
    } else if (TMWidgetIsQuota(widgetId)) {
        // La source contient le consommé ; texte, remplissage et historique affichent le restant.
        // La famille porte le même id que le
        // widget ; absente (aucun compte connecté), l'icône montre son tiret comme les autres.
        NSNumber *value = TMNum(TMFamilyNow(snapshot, widgetId)[@"percent"]);
        r[@"style"] = @"pie";
        r[@"numeric"] = @YES;
        if (value) {
            r[@"hasValue"] = @YES;
            r[@"title"] = r[@"value"] = TMPct(@(100 - MIN(100, MAX(0, value.doubleValue))));
            r[@"chipValue"] = TMPlain(@(100 - MIN(100, MAX(0, value.doubleValue)))); r[@"chipUnit"] = @"%";
            r[@"fraction"] = @(1 - MIN(MAX(value.doubleValue / 100.0, 0), 1));
            NSMutableArray *remainingSeries=[NSMutableArray array];
            for (NSNumber *used in TMFamilySeries(snapshot, widgetId, @"percent"))
                [remainingSeries addObject:@(100 - MIN(100, MAX(0, used.doubleValue)))];
            r[@"series"] = remainingSeries;
        }
    } else if (TMWidgetIsApi(widgetId)) {
        // Reste estimé (ou reste du budget) : texte en dollars, remplissage = part restante.
        NSDictionary *now = TMFamilyNow(snapshot, widgetId);
        NSNumber *fraction = TMNum(now[@"fraction"]);
        NSString *text = [now[@"text"] isKindOfClass:NSString.class] ? now[@"text"] : @"";
        NSString *widest = [now[@"template"] isKindOfClass:NSString.class] ? now[@"template"] : @"";
        r[@"style"] = @"ring";
        if (widest.length) r[@"template"] = r[@"valueTemplate"] = widest;
        if (fraction && text.length) {
            r[@"hasValue"] = @YES;
            r[@"title"] = r[@"value"] = text;
            r[@"fraction"] = @(MIN(MAX(fraction.doubleValue, 0), 1));
        }
    } else if ([widgetId isEqual:@"memory"] || [widgetId isEqual:@"disk"]) {
        NSString *fam = [widgetId isEqual:@"memory"] ? @"ram" : @"disk";
        NSDictionary *famNow = TMFamilyNow(snapshot, fam);
        NSNumber *value = TMNum(famNow[@"usedPercent"]);
        r[@"style"] = @"pie";
        r[@"numeric"] = @YES;
        r[@"chipLabel"] = [widgetId isEqual:@"memory"] ? @"MEM" : @"DSK";
        if (value) {
            r[@"hasValue"] = @YES;
            r[@"title"] = r[@"value"] = TMPct(value);
            r[@"chipValue"] = TMPlain(value); r[@"chipUnit"] = @"%";
            r[@"fraction"] = @(MIN(MAX(value.doubleValue / 100.0, 0), 1));
            r[@"series"] = TMFamilySeries(snapshot, fam, @"usedPercent");
            if ([widgetId isEqual:@"memory"]) r[@"parts"] = TMMemoryParts(famNow);
        }
    } else if ([widgetId isEqual:@"network"]) {
        NSDictionary *net = TMFamilyNow(snapshot, @"network");
        NSNumber *rx = TMNum(net[@"rxBytesPerSec"]), *tx = TMNum(net[@"txBytesPerSec"]);
        r[@"style"] = @"twoLine";
        r[@"dual"] = @YES; r[@"chipLabel"] = TMT(@"shape.chipNet"); r[@"chipKind"] = @"spark";
        if (rx || tx) {
            r[@"hasValue"] = @YES;
            r[@"rxFraction"] = @(TMRound2(TMWidgetRateFraction(rx.doubleValue)));
            r[@"txFraction"] = @(TMRound2(TMWidgetRateFraction(tx.doubleValue)));
            // Série ↓ ramenée à 0..100 sur la même échelle log que les arcs.
            NSMutableArray *rates = [NSMutableArray array];
            for (NSNumber *sample in TMFamilySeries(snapshot, @"network", @"rxBytesPerSec"))
                [rates addObject:@(round(100.0 * TMWidgetRateFraction(sample.doubleValue)))];
            r[@"series"] = rates;
            r[@"primary"] = [@"↓ " stringByAppendingString:TMFmtRate(rx.doubleValue)];
            r[@"secondary"] = [@"↑ " stringByAppendingString:TMFmtRate(tx.doubleValue)];
            r[@"value"] = r[@"primary"];
        }
    } else if ([widgetId isEqual:@"temperature"]) {
        NSNumber *temp = TMNum(TMFamilyNow(snapshot, @"sensors")[@"tempC"]);
        r[@"style"] = @"twoLine";
        r[@"numeric"] = @YES; r[@"chipLabel"] = @"TEMP"; r[@"chipKind"] = @"spark"; r[@"autoScale"] = @YES;
        if (temp) {
            r[@"hasValue"] = @YES;
            r[@"chipValue"] = TMPlain(temp); r[@"chipUnit"] = @"°C";
            r[@"series"] = TMFamilySeries(snapshot, @"sensors", @"tempC");
            r[@"primary"] = r[@"value"] = [NSString stringWithFormat:@"%.0f°", round(temp.doubleValue)];
            r[@"fraction"] = @(MIN(MAX(temp.doubleValue / 100.0, 0), 1));  // 0-100 °C pour l'anneau
            NSNumber *watts = TMNum(TMFamilyNow(snapshot, @"battery")[@"powerWatts"]);
            r[@"secondary"] = watts ? [NSString stringWithFormat:@"%.0f W", round(fabs(watts.doubleValue))] : @"";
        }
    } else if ([widgetId isEqual:@"battery"]) {
        NSDictionary *b = TMFamilyNow(snapshot, @"battery");
        NSNumber *pct = TMNum(b[@"percent"]);
        r[@"style"] = @"battery";
        r[@"numeric"] = @YES; r[@"chipLabel"] = @"BAT";
        if (pct) {
            r[@"chipValue"] = TMPlain(pct); r[@"chipUnit"] = @"%";
            BOOL charging = [TMNum(b[@"charging"]) boolValue];
            BOOL full = [TMNum(b[@"fullyCharged"]) boolValue];
            long long remaining = TMNum(b[@"minutesRemaining"]).longLongValue;
            r[@"hasValue"] = @YES;
            r[@"charging"] = @(charging);
            r[@"fraction"] = @(MIN(MAX(pct.doubleValue / 100.0, 0), 1));
            r[@"secondary"] = r[@"value"] = [NSString stringWithFormat:@"%.0f %%", round(pct.doubleValue)];
            r[@"primary"] = full ? @"Plein" : charging ? @"Charge" : (remaining > 0 ? TMFmtMinutes(remaining) : @"");
        }
    }
    return r;
}

#pragma mark - Dessin (AppKit)

// Palette nommée pour les widgets. « auto »/inconnu → nil : l'encre retombe sur le template neutre.
NSColor *TMWidgetNamedColor(NSString *name) {
    static NSDictionary<NSString *, NSColor *> *palette;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        palette = @{
            @"blue":   [NSColor colorWithSRGBRed:0.30 green:0.56 blue:1.00 alpha:1],
            @"green":  [NSColor colorWithSRGBRed:0.30 green:0.82 blue:0.45 alpha:1],
            @"purple": [NSColor colorWithSRGBRed:0.68 green:0.52 blue:1.00 alpha:1],
            @"cyan":   [NSColor colorWithSRGBRed:0.30 green:0.80 blue:0.90 alpha:1],
            @"orange": [NSColor colorWithSRGBRed:1.00 green:0.60 blue:0.20 alpha:1],
            @"amber":  [NSColor colorWithSRGBRed:1.00 green:0.75 blue:0.25 alpha:1],
            @"red":    [NSColor colorWithSRGBRed:1.00 green:0.38 blue:0.35 alpha:1],
            @"pink":   [NSColor colorWithSRGBRed:1.00 green:0.45 blue:0.70 alpha:1],
            @"gray":   [NSColor colorWithSRGBRed:0.62 green:0.66 blue:0.72 alpha:1],
        };
    });
    return palette[name ?: @""];
}

// Encre finale d'un widget : la sévérité prime toujours (ambre/rouge = alerte, quelle que soit la
// couleur choisie) ; sinon la couleur nommée si donnée ; sinon template neutre (macOS l'inverse
// selon le thème de la barre).
static NSColor *TMResolveWidgetInk(NSString *colorName, NSInteger severity, BOOL *outTemplate) {
    if (severity >= 2) { if (outTemplate) *outTemplate = NO; return TMWidgetNamedColor(@"red"); }
    if (severity == 1) { if (outTemplate) *outTemplate = NO; return TMWidgetNamedColor(@"amber"); }
    NSColor *named = TMWidgetNamedColor(colorName);
    if (named) { if (outTemplate) *outTemplate = NO; return named; }
    if (outTemplate) *outTemplate = YES;
    return NSColor.blackColor;
}

static void TMDrawDashLen(NSColor *ink, CGFloat cx, CGFloat cy, CGFloat half) {
    NSBezierPath *dash = [NSBezierPath bezierPath];
    dash.lineWidth = 1.6; dash.lineCapStyle = NSLineCapStyleRound;
    [dash moveToPoint:NSMakePoint(cx - half, cy)];
    [dash lineToPoint:NSMakePoint(cx + half, cy)];
    [[ink colorWithAlphaComponent:0.55] setStroke];
    [dash stroke];
}

static void TMDrawDash(NSColor *ink, CGFloat cx, CGFloat cy) { TMDrawDashLen(ink, cx, cy, 2.4); }

// Image vectorielle : le dessin est rejoué à la résolution réelle de l'écran (pas de bitmap figé
// à l'échelle 1× ou 2×), donc des arcs nets partout. Réservée aux formes qui n'ont pas besoin de
// l'effacement (blend clear) de l'éclair de la pile, dessiné, lui, dans un bitmap.
static NSImage *TMVectorImage(NSSize size, BOOL isTemplate, void (^draw)(void)) {
    NSImage *image = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect dst) {
        draw();
        return YES;
    }];
    image.template = isTemplate;
    return image;
}

static CGFloat TMUnit(double v) { return (CGFloat)(v < 0 ? 0 : v > 1 ? 1 : v); }

// Opacité de la piste (partie « vide ») d'une forme : un peu plus marquée en template, où
// l'opacité est la seule nuance disponible.
static CGFloat TMTrackAlpha(BOOL isTemplate) { return isTemplate ? 0.3 : 0.28; }

// Arc de cercle tracé dans le sens horaire de startDeg à endDeg (degrés AppKit : 0 = est, 90 = midi).
static void TMStrokeArc(NSPoint c, CGFloat radius, CGFloat startDeg, CGFloat endDeg, CGFloat lineWidth,
                        NSLineCapStyle cap, NSColor *color) {
    if (startDeg - endDeg < 0.05) return;
    NSBezierPath *arc = [NSBezierPath bezierPath];
    [arc appendBezierPathWithArcWithCenter:c radius:radius startAngle:startDeg endAngle:endDeg clockwise:YES];
    arc.lineWidth = lineWidth; arc.lineCapStyle = cap;
    [color setStroke];
    [arc stroke];
}

static void TMStrokeCircle(NSPoint c, CGFloat radius, CGFloat lineWidth, NSColor *color) {
    NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - radius, c.y - radius, 2 * radius, 2 * radius)];
    circle.lineWidth = lineWidth;
    [color setStroke];
    [circle stroke];
}

static void TMFillCircle(NSPoint c, CGFloat radius, NSColor *color) {
    [color setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - radius, c.y - radius, 2 * radius, 2 * radius)] fill];
}

// Texte posé par sa ligne de base (et non par sa boîte typographique) : c'est ce qui permet de
// centrer un chiffre sur la hauteur de ses chiffres plutôt que sur celle de la police.
static void TMDrawTextAt(NSString *text, NSFont *font, NSColor *color, CGFloat x, CGFloat baseline,
                         NSTextAlignment alignment, CGFloat kern) {
    if (!text.length) return;
    NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: color,
                             NSKernAttributeName: @(kern) };
    NSSize size = [text sizeWithAttributes:attrs];
    CGFloat left = alignment == NSTextAlignmentCenter ? x - size.width / 2
                 : alignment == NSTextAlignmentRight ? x - size.width : x;
    [text drawAtPoint:NSMakePoint(left, baseline + font.descender) withAttributes:attrs];
}

static CGFloat TMTextWidth(NSString *text, NSFont *font, CGFloat kern) {
    if (!text.length) return 0;
    return [text sizeWithAttributes:@{ NSFontAttributeName: font, NSKernAttributeName: @(kern) }].width;
}

// Deux lignes de texte monospace empilées. La largeur est celle du gabarit du widget (pire cas),
// jamais celle du texte courant : sinon l'icône respire à chaque mesure et pousse ses voisines.
// Le texte est calé à droite dans cette largeur, ce qui aligne les unités d'une ligne à l'autre.
static NSImage *TMDrawTwoLine(NSString *top, NSString *bottom, NSString *widthTemplate, NSColor *ink, BOOL isTemplate) {
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:8.5 weight:NSFontWeightMedium];
    NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: ink };
    NSSize topSize = [top sizeWithAttributes:attrs], botSize = [bottom sizeWithAttributes:attrs];
    CGFloat reserved = widthTemplate.length ? [widthTemplate sizeWithAttributes:attrs].width : 0;
    CGFloat w = ceil(MAX(MAX(topSize.width, botSize.width), reserved)) + 2, h = 18;
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(MAX(w, 12), h)];
    [image lockFocus];
    [top drawAtPoint:NSMakePoint(w - 1 - topSize.width, h - topSize.height - 0.5) withAttributes:attrs];
    [bottom drawAtPoint:NSMakePoint(w - 1 - botSize.width, 0.5) withAttributes:attrs];
    [image unlockFocus];
    image.template = isTemplate;
    return image;
}

// Histogramme : les dix derniers échantillons en barres verticales (plus récent à droite, échelle
// 0-100), bouts arrondis, posées sur une ligne de base de 1 pt. Même cellule 26 × 18 qu'avant.
static NSImage *TMDrawBars(NSArray<NSNumber *> *series, NSColor *ink, BOOL isTemplate) {
    const CGFloat w = 26, h = 18;
    return TMVectorImage(NSMakeSize(w, h), isTemplate, ^{
        const NSUInteger slots = 10;
        const CGFloat barW = 1.5, pitch = 2.6, x0 = (w - ((slots - 1) * pitch + barW)) / 2;
        const CGFloat floorY = 2.0, top = 16.0;  // boîte optique de 14 pt dans les 18 pt
        [[ink colorWithAlphaComponent:0.55] setFill];
        [[NSBezierPath bezierPathWithRect:NSMakeRect(x0 - 0.5, floorY, (slots - 1) * pitch + barW + 1, 1)] fill];
        NSArray<NSNumber *> *pts = series.count > slots ? [series subarrayWithRange:NSMakeRange(series.count - slots, slots)] : series;
        if (pts.count < 1) { TMDrawDash(ink, w / 2, h / 2 + 0.5); return; }
        [ink setFill];
        NSUInteger first = slots - pts.count;  // série courte : alignée à droite, le plus récent reste au bord
        for (NSUInteger i = 0; i < pts.count; i++) {
            CGFloat v = TMUnit(pts[i].doubleValue / 100.0);
            CGFloat barH = MAX(barW, v * (top - floorY - 1.0));
            NSRect bar = NSMakeRect(x0 + (first + i) * pitch, floorY + 1.0, barW, barH);
            [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:barW / 2 yRadius:barW / 2] fill];
        }
    });
}

// Camembert cerclé : anneau de 1 pt, disque faible, secteur franc. Même boîte optique (15 pt) que
// l'anneau, donc les deux s'alignent sur la grille de 18 pt quand ils se côtoient.
static NSImage *TMDrawPie(double fraction, BOOL hasValue, NSColor *ink, BOOL isTemplate) {
    const CGFloat side = 18, ringRadius = 7.0, radius = 5.6;
    return TMVectorImage(NSMakeSize(side, side), isTemplate, ^{
        NSPoint c = NSMakePoint(side / 2, side / 2);
        TMStrokeCircle(c, ringRadius, 1.0, [ink colorWithAlphaComponent:isTemplate ? 0.6 : 0.5]);
        TMFillCircle(c, radius, [ink colorWithAlphaComponent:isTemplate ? 0.25 : 0.28]);
        if (!hasValue) { TMDrawDash(ink, c.x, c.y); return; }
        double f = TMUnit(fraction);
        if (f <= 0) return;
        NSBezierPath *wedge = [NSBezierPath bezierPath];
        [wedge moveToPoint:c];
        [wedge appendBezierPathWithArcWithCenter:c radius:radius startAngle:90 endAngle:90 - f * 360 clockwise:YES];
        [wedge closePath];
        [ink setFill];
        [wedge fill];
    });
}

// Pile de batterie horizontale + deux lignes de texte (état / pourcentage), éclair si en charge.
static NSImage *TMDrawBattery(double fraction, BOOL charging, BOOL hasValue, NSString *top, NSString *bottom,
                              NSString *widthTemplate, NSColor *ink, BOOL isTemplate) {
    const CGFloat cellW = 17, cellH = 9, nub = 1.6, h = 18;
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:8 weight:NSFontWeightMedium];
    NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: ink };
    CGFloat reserved = widthTemplate.length ? [widthTemplate sizeWithAttributes:attrs].width : 0;
    CGFloat textW = ceil(MAX(MAX([top sizeWithAttributes:attrs].width, [bottom sizeWithAttributes:attrs].width), reserved));
    CGFloat w = cellW + nub + (textW > 0 ? textW + 4 : 0) + 1;
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
    [image lockFocus];

    CGFloat y = (h - cellH) / 2;
    NSRect body = NSMakeRect(0.5, y, cellW, cellH);
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:body xRadius:1.5 yRadius:1.5];
    outline.lineWidth = 1;
    [ink setStroke]; [outline stroke];
    [ink setFill];
    NSRect tip = NSMakeRect(NSMaxX(body), y + cellH / 2 - 1.8, nub, 3.6);
    [[NSBezierPath bezierPathWithRect:tip] fill];
    if (hasValue) {
        NSRect fill = NSInsetRect(body, 1.6, 1.6);
        fill.size.width *= MIN(MAX(fraction, 0), 1);
        [[NSBezierPath bezierPathWithRect:fill] fill];
    } else {
        TMDrawDash(ink, NSMidX(body), NSMidY(body));
    }
    if (charging) {  // éclair « découpé » dans la pile : un trou (blend clear) le rend visible sur
                     // une image template comme en couleur, quel que soit le fond.
        NSBezierPath *bolt = [NSBezierPath bezierPath];
        CGFloat bx = NSMidX(body), by = NSMidY(body);
        [bolt moveToPoint:NSMakePoint(bx + 1, by + 3)];
        [bolt lineToPoint:NSMakePoint(bx - 2, by - 0.2)];
        [bolt lineToPoint:NSMakePoint(bx + 0.2, by - 0.2)];
        [bolt lineToPoint:NSMakePoint(bx - 1, by - 3)];
        [bolt lineToPoint:NSMakePoint(bx + 2, by + 0.2)];
        [bolt lineToPoint:NSMakePoint(bx - 0.2, by + 0.2)];
        [bolt closePath];
        NSGraphicsContext *ctx = NSGraphicsContext.currentContext;
        [ctx saveGraphicsState];
        CGContextSetBlendMode(ctx.CGContext, kCGBlendModeClear);
        [bolt fill];
        [ctx restoreGraphicsState];
    }
    if (textW > 0) {
        CGFloat right = cellW + nub + 4 + textW;  // bord droit du bloc texte, fixe
        [top drawAtPoint:NSMakePoint(right - [top sizeWithAttributes:attrs].width, h - [top sizeWithAttributes:attrs].height) withAttributes:attrs];
        [bottom drawAtPoint:NSMakePoint(right - [bottom sizeWithAttributes:attrs].width, 0) withAttributes:attrs];
    }
    [image unlockFocus];
    image.template = isTemplate;
    return image;
}

// Anneau (piste faible + arc de fraction, part de midi, sens horaire, bouts ronds) — comme la
// jauge quota. Rayon extérieur 7,5 pt, identique à celui du camembert.
static NSImage *TMDrawRing(double fraction, BOOL hasValue, NSColor *ink, BOOL isTemplate) {
    const CGFloat side = 18, radius = 6.4, lineWidth = 2.2;
    return TMVectorImage(NSMakeSize(side, side), isTemplate, ^{
        NSPoint c = NSMakePoint(side / 2, side / 2);
        TMStrokeCircle(c, radius, lineWidth, [ink colorWithAlphaComponent:TMTrackAlpha(isTemplate)]);
        if (!hasValue) { TMDrawDash(ink, c.x, c.y); return; }
        double f = TMUnit(fraction);
        if (f > 0) TMStrokeArc(c, radius, 90, 90 - f * 360, lineWidth, NSLineCapStyleRound, ink);
    });
}

// Jauge horizontale : une piste en gélule et son remplissage, bouts arrondis. La forme la plus
// littérale pour « combien il reste », et la seule qui se lise sans convention (l'anneau demande
// de savoir qu'il part de midi, le camembert qu'il tourne dans le sens horaire).
static NSImage *TMDrawBar(double fraction, BOOL hasValue, NSColor *ink, BOOL isTemplate) {
    const CGFloat w = 22, h = 18, barH = 8;
    return TMVectorImage(NSMakeSize(w, h), isTemplate, ^{
        NSRect track = NSMakeRect(0.5, (h - barH) / 2, w - 1, barH);
        NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:track xRadius:barH / 2 yRadius:barH / 2];
        outline.lineWidth = 1;
        [[ink colorWithAlphaComponent:isTemplate ? 0.45 : 0.5] setStroke];
        [outline stroke];
        if (!hasValue) { TMDrawDash(ink, NSMidX(track), NSMidY(track)); return; }
        double f = TMUnit(fraction);
        if (f <= 0) return;
        // Gélule pleine longueur rognée à la fraction : la tête est toujours arrondie, la queue du
        // remplissage coupée net, comme un liquide qui monte dans un tube.
        NSRect fill = NSInsetRect(track, 1.7, 1.7);
        [NSGraphicsContext saveGraphicsState];
        [[NSBezierPath bezierPathWithRect:NSMakeRect(fill.origin.x, fill.origin.y, fill.size.width * f, fill.size.height)] addClip];
        [ink setFill];
        [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:fill.size.height / 2 yRadius:fill.size.height / 2] fill];
        [NSGraphicsContext restoreGraphicsState];
    });
}

// Courbe (ligne) de la série récente, échelle fixe 0-100 + point terminal — comme la sparkline.
static NSImage *TMDrawGraph(NSArray<NSNumber *> *series, NSColor *ink, BOOL isTemplate) {
    const CGFloat w = 26, h = 18, pad = 2;
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
    [image lockFocus];
    if (series.count < 2) { TMDrawDash(ink, w / 2, h / 2); }
    else {
        NSUInteger n = series.count; CGFloat plotW = w - 2 * pad, plotH = h - 2 * pad;
        NSBezierPath *line = [NSBezierPath bezierPath];
        line.lineWidth = 1.3; line.lineJoinStyle = NSLineJoinStyleRound;
        for (NSUInteger i = 0; i < n; i++) {
            CGFloat x = pad + (CGFloat)i / (n - 1) * plotW;
            CGFloat y = pad + MIN(MAX(series[i].doubleValue, 0), 100) / 100.0 * plotH;
            if (i == 0) [line moveToPoint:NSMakePoint(x, y)]; else [line lineToPoint:NSMakePoint(x, y)];
        }
        [ink setStroke]; [line stroke];
        CGFloat lx = pad + plotW, ly = pad + MIN(MAX(series.lastObject.doubleValue, 0), 100) / 100.0 * plotH;
        [ink setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(lx - 1.5, ly - 1.5, 3, 3)] fill];
    }
    [image unlockFocus];
    image.template = isTemplate;
    return image;
}

// Texte seul : la valeur en gros (« 43 % », « 50° »), à la largeur réservée du widget.
static NSImage *TMDrawText(NSString *text, NSString *widthTemplate, NSColor *ink, BOOL isTemplate) {
    if (!text.length) text = @"—";
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: ink };
    NSSize size = [text sizeWithAttributes:attrs];
    CGFloat reserved = widthTemplate.length ? [widthTemplate sizeWithAttributes:attrs].width : 0;
    CGFloat w = ceil(MAX(size.width, reserved)) + 2, h = 18;
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(MAX(w, 12), h)];
    [image lockFocus];
    [text drawAtPoint:NSMakePoint(w - 1 - size.width, (h - size.height) / 2) withAttributes:attrs];
    [image unlockFocus];
    image.template = isTemplate;
    return image;
}

#pragma mark - Famille Anneaux

// Tout vit sur la même grille que l'anneau historique : cellule de 18 pt, centre (9, 9), rayon
// extérieur ≤ 8 pt, départ à midi dans le sens horaire, traits de 1,8 à 2,6 pt. Chaque forme se lit
// en monochrome (alpha seul) et en couleur ; « pas de valeur » = piste faible + tiret.

// Anneau avec le chiffre au centre : la valeur est dans l'image, donc pas de titre système.
static NSImage *TMDrawRingValue(double fraction, BOOL hasValue, NSString *digits, NSColor *ink, BOOL isTemplate) {
    const CGFloat side = 18, radius = 7.1, lineWidth = 1.8;
    return TMVectorImage(NSMakeSize(side, side), isTemplate, ^{
        NSPoint c = NSMakePoint(side / 2, side / 2);
        TMStrokeCircle(c, radius, lineWidth, [ink colorWithAlphaComponent:TMTrackAlpha(isTemplate)]);
        if (!hasValue || !digits.length) { TMDrawDashLen(ink, c.x, c.y, 2.0); return; }
        double f = TMUnit(fraction);
        if (f > 0) TMStrokeArc(c, radius, 90, 90 - f * 360, lineWidth, NSLineCapStyleRound, ink);
        // Le chiffre le plus large (« 100 ») garde ses chiffres dans le vide de l'anneau : corps réduit.
        NSFont *font = [NSFont monospacedDigitSystemFontOfSize:digits.length >= 3 ? 5.6 : 7.2 weight:NSFontWeightSemibold];
        TMDrawTextAt(digits, font, ink, c.x, c.y - font.capHeight / 2, NSTextAlignmentCenter, -0.1);
    });
}

// Anneau segmenté. Mémoire avec ses parts (app / système / compressée / cache, du plus au moins
// opaque ; le reste est la mémoire libre) ; sinon dix segments allumés selon la charge.
static NSImage *TMDrawSegments(double fraction, BOOL hasValue, NSArray<NSNumber *> *parts, NSColor *ink, BOOL isTemplate) {
    const CGFloat side = 18, radius = 6.8, lineWidth = 2.6;
    return TMVectorImage(NSMakeSize(side, side), isTemplate, ^{
        NSPoint c = NSMakePoint(side / 2, side / 2);
        NSColor *faint = [ink colorWithAlphaComponent:TMTrackAlpha(isTemplate)];
        if (hasValue && parts.count == 4) {
            TMStrokeCircle(c, radius, lineWidth, [ink colorWithAlphaComponent:0.16]);
            const CGFloat alphas[4] = { 1.0, 0.7, 0.46, 0.26 }, gap = 3.0;
            double at = 0;
            for (NSUInteger i = 0; i < 4; i++) {
                double span = TMUnit(parts[i].doubleValue) * 360;
                if (span > 0.5) {
                    double start = 90 - at - (span > gap + 1 ? gap / 2 : 0);
                    double end = 90 - at - span + (span > gap + 1 ? gap / 2 : 0);
                    TMStrokeArc(c, radius, start, end, lineWidth, NSLineCapStyleButt, [ink colorWithAlphaComponent:alphas[i]]);
                }
                at += span;
            }
            return;
        }
        NSInteger lit = hasValue ? (NSInteger)round(TMUnit(fraction) * 10) : 0;
        for (NSInteger i = 0; i < 10; i++) {
            CGFloat start = 90 - 5 - i * 36;
            TMStrokeArc(c, radius, start, start - 26, lineWidth, NSLineCapStyleButt, i < lit ? ink : faint);
        }
        if (!hasValue) TMDrawDash(ink, c.x, c.y);
    });
}

// Cadran de 240°, ouvert en bas, avec une aiguille courte et un moyeu. Centré optiquement : la
// partie ouverte pèse moins, donc le centre géométrique est remonté vers le bas de la cellule.
static NSImage *TMDrawDial(double fraction, BOOL hasValue, NSColor *ink, BOOL isTemplate) {
    const CGFloat side = 18, radius = 7.2, lineWidth = 2.0, sweep = 240;
    return TMVectorImage(NSMakeSize(side, side), isTemplate, ^{
        NSPoint c = NSMakePoint(side / 2, 7.4);
        TMStrokeArc(c, radius, 210, 210 - sweep, lineWidth, NSLineCapStyleRound, [ink colorWithAlphaComponent:TMTrackAlpha(isTemplate)]);
        if (!hasValue) { TMDrawDashLen(ink, c.x, c.y + 1.2, 2.0); return; }
        double f = TMUnit(fraction);
        if (f > 0) TMStrokeArc(c, radius, 210, 210 - f * sweep, lineWidth, NSLineCapStyleRound, ink);
        double angle = (210 - f * sweep) * M_PI / 180.0;
        NSBezierPath *needle = [NSBezierPath bezierPath];
        [needle moveToPoint:c];
        [needle lineToPoint:NSMakePoint(c.x + cos(angle) * 4.4, c.y + sin(angle) * 4.4)];
        needle.lineWidth = 1.4; needle.lineCapStyle = NSLineCapStyleRound;
        [ink setStroke];
        [needle stroke];
        TMFillCircle(c, 1.5, ink);
    });
}

// Deux arcs concentriques (↓ extérieur, ↑ intérieur, échelle logarithmique) puis le texte deux
// lignes, calé à droite dans la largeur du pire cas (« ↓ 999 Mo/s ») comme la forme « 2 lignes ».
static NSImage *TMDrawDualArc(NSDictionary *readout, NSColor *ink, BOOL isTemplate) {
    const CGFloat side = 18, h = 18, outer = 7.2, inner = 4.3, lineWidth = 1.8, gutter = 3;
    BOOL hasValue = [readout[@"hasValue"] boolValue];
    NSString *top = hasValue ? readout[@"primary"] : @"—", *bottom = hasValue ? readout[@"secondary"] : @"";
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:8.5 weight:NSFontWeightMedium];
    NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: ink };
    NSString *widthTemplate = readout[@"template"];
    CGFloat textW = ceil(MAX(MAX([top sizeWithAttributes:attrs].width, [bottom sizeWithAttributes:attrs].width),
                             widthTemplate.length ? [widthTemplate sizeWithAttributes:attrs].width : 0));
    CGFloat w = side + gutter + textW + 1;
    double rx = [readout[@"rxFraction"] doubleValue], tx = [readout[@"txFraction"] doubleValue];
    return TMVectorImage(NSMakeSize(w, h), isTemplate, ^{
        NSPoint c = NSMakePoint(side / 2, side / 2);
        NSColor *faint = [ink colorWithAlphaComponent:TMTrackAlpha(isTemplate)];
        TMStrokeCircle(c, outer, lineWidth, faint);
        TMStrokeCircle(c, inner, lineWidth, faint);
        if (hasValue) {
            if (rx > 0) TMStrokeArc(c, outer, 90, 90 - TMUnit(rx) * 360, lineWidth, NSLineCapStyleRound, ink);
            if (tx > 0) TMStrokeArc(c, inner, 90, 90 - TMUnit(tx) * 360, lineWidth, NSLineCapStyleRound, ink);
        } else {
            TMDrawDashLen(ink, c.x, c.y, 1.4);
        }
        NSSize topSize = [top sizeWithAttributes:attrs], botSize = [bottom sizeWithAttributes:attrs];
        [top drawAtPoint:NSMakePoint(w - 1 - topSize.width, h - topSize.height - 0.5) withAttributes:attrs];
        [bottom drawAtPoint:NSMakePoint(w - 1 - botSize.width, 0.5) withAttributes:attrs];
    });
}

// Anneau fin + moyeu central (le plateau d'un disque) : l'arc dit le remplissage, le moyeu et son
// liseré distinguent la forme du simple anneau, même en monochrome.
static NSImage *TMDrawHub(double fraction, BOOL hasValue, NSColor *ink, BOOL isTemplate) {
    const CGFloat side = 18, radius = 6.8, lineWidth = 1.6;
    return TMVectorImage(NSMakeSize(side, side), isTemplate, ^{
        NSPoint c = NSMakePoint(side / 2, side / 2);
        TMStrokeCircle(c, radius, lineWidth, [ink colorWithAlphaComponent:TMTrackAlpha(isTemplate)]);
        TMStrokeCircle(c, 3.9, 0.8, [ink colorWithAlphaComponent:0.4]);
        if (!hasValue) { TMDrawDashLen(ink, c.x, c.y, 1.5); return; }
        double f = TMUnit(fraction);
        if (f > 0) TMStrokeArc(c, radius, 90, 90 - f * 360, lineWidth, NSLineCapStyleRound, ink);
        TMFillCircle(c, 2.1, ink);
    });
}

#pragma mark - Famille Console

// La puce : 18 pt de haut, deux niveaux de texte à gauche (micro-étiquette en capitales, valeur
// tabulaire dessous) et un graphique intégré à droite — sparkline pour ce qui varie (CPU, GPU, réseau,
// température), réservoir pour ce qui se remplit (mémoire, disque, batterie ; « puce + jauge »
// impose le réservoir horizontal). La largeur est celle du pire cas (« 100 % », « ↓ 999 Mo/s »),
// jamais celle de la mesure du moment : la puce ne saute pas quand le chiffre change de longueur.

// Éclair de 3 × 5 pt (batterie en charge), centré sur (x, y).
static void TMFillBolt(CGFloat x, CGFloat y, NSColor *color) {
    NSBezierPath *bolt = [NSBezierPath bezierPath];
    [bolt moveToPoint:NSMakePoint(x + 0.9, y + 2.5)];
    [bolt lineToPoint:NSMakePoint(x - 1.5, y - 0.2)];
    [bolt lineToPoint:NSMakePoint(x - 0.1, y - 0.2)];
    [bolt lineToPoint:NSMakePoint(x - 0.9, y - 2.5)];
    [bolt lineToPoint:NSMakePoint(x + 1.5, y + 0.2)];
    [bolt lineToPoint:NSMakePoint(x + 0.1, y + 0.2)];
    [bolt closePath];
    [color setFill];
    [bolt fill];
}

// Sparkline de la série récente dans `box` : trait, léger remplissage dessous, point terminal.
// Échelle fixe 0-100, ou ajustée à la série (température : 12 °C minimum de plage pour qu'un
// capteur stable ne devienne pas un électrocardiogramme).
static void TMDrawChipSpark(NSArray<NSNumber *> *series, BOOL autoScale, BOOL hasValue, NSRect box, NSColor *ink, BOOL isTemplate) {
    NSArray<NSNumber *> *pts = series.count > 18 ? [series subarrayWithRange:NSMakeRange(series.count - 18, 18)] : series;
    if (!hasValue || pts.count < 2) {
        NSBezierPath *flat = [NSBezierPath bezierPath];
        [flat moveToPoint:NSMakePoint(NSMinX(box), NSMidY(box))];
        [flat lineToPoint:NSMakePoint(NSMaxX(box), NSMidY(box))];
        flat.lineWidth = 1.2; flat.lineCapStyle = NSLineCapStyleRound;
        [[ink colorWithAlphaComponent:0.4] setStroke];
        [flat stroke];
        return;
    }
    double lo = 0, hi = 100;
    if (autoScale) {
        lo = HUGE_VAL; hi = -HUGE_VAL;
        for (NSNumber *v in pts) { lo = MIN(lo, v.doubleValue); hi = MAX(hi, v.doubleValue); }
        double span = MAX(hi - lo, 12), mid = (hi + lo) / 2;
        lo = mid - span / 2; hi = mid + span / 2;
    }
    CGFloat inset = 1.2;  // le point terminal ne déborde pas de la boîte
    NSRect plot = NSInsetRect(box, inset, inset);
    NSBezierPath *line = [NSBezierPath bezierPath];
    line.lineWidth = 1.2; line.lineJoinStyle = NSLineJoinStyleRound; line.lineCapStyle = NSLineCapStyleRound;
    CGFloat lastX = 0, lastY = 0;
    for (NSUInteger i = 0; i < pts.count; i++) {
        CGFloat x = NSMinX(plot) + (CGFloat)i / (pts.count - 1) * NSWidth(plot);
        CGFloat y = NSMinY(plot) + TMUnit((pts[i].doubleValue - lo) / (hi - lo)) * NSHeight(plot);
        if (i == 0) [line moveToPoint:NSMakePoint(x, y)]; else [line lineToPoint:NSMakePoint(x, y)];
        lastX = x; lastY = y;
    }
    NSBezierPath *area = [line copy];
    [area lineToPoint:NSMakePoint(lastX, NSMinY(box))];
    [area lineToPoint:NSMakePoint(NSMinX(plot), NSMinY(box))];
    [area closePath];
    [[ink colorWithAlphaComponent:isTemplate ? 0.22 : 0.2] setFill];
    [area fill];
    [ink setStroke];
    [line stroke];
    TMFillCircle(NSMakePoint(lastX, lastY), 1.3, ink);
}

// Réservoir : contour, remplissage de bas en haut (vertical) ou de gauche à droite (horizontal).
static void TMDrawChipReservoir(double fraction, BOOL hasValue, BOOL horizontal, NSRect box, NSColor *ink, BOOL isTemplate) {
    CGFloat radius = horizontal ? NSHeight(box) / 2 : 2.0;
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box, 0.5, 0.5) xRadius:radius yRadius:radius];
    outline.lineWidth = 1;
    [[ink colorWithAlphaComponent:isTemplate ? 0.6 : 0.55] setStroke];
    [outline stroke];
    if (!hasValue) { TMDrawDashLen(ink, NSMidX(box), NSMidY(box), horizontal ? 2.4 : 1.4); return; }
    double f = TMUnit(fraction);
    if (f <= 0) return;
    NSRect inner = NSInsetRect(box, 1.8, 1.8);
    NSRect cut = horizontal ? NSMakeRect(inner.origin.x, inner.origin.y, inner.size.width * f, inner.size.height)
                            : NSMakeRect(inner.origin.x, inner.origin.y, inner.size.width, inner.size.height * f);
    [NSGraphicsContext saveGraphicsState];
    [[NSBezierPath bezierPathWithRect:cut] addClip];
    [ink setFill];
    CGFloat r = horizontal ? inner.size.height / 2 : 1.0;
    [[NSBezierPath bezierPathWithRoundedRect:inner xRadius:r yRadius:r] fill];
    [NSGraphicsContext restoreGraphicsState];
}

static NSImage *TMDrawChip(NSDictionary *readout, BOOL withBar, NSColor *ink, BOOL isTemplate) {
    const CGFloat h = 18, gap = 4, left = 0.5;
    BOOL hasValue = [readout[@"hasValue"] boolValue], dual = [readout[@"dual"] boolValue];
    NSString *label = readout[@"chipLabel"], *value = readout[@"chipValue"], *unit = readout[@"chipUnit"];
    BOOL spark = !withBar && [readout[@"chipKind"] isEqual:@"spark"];
    BOOL charging = [readout[@"charging"] boolValue];

    NSFont *labelFont = [NSFont systemFontOfSize:5.8 weight:NSFontWeightSemibold];
    NSFont *valueFont = [NSFont monospacedDigitSystemFontOfSize:9.5 weight:NSFontWeightSemibold];
    NSFont *unitFont = [NSFont systemFontOfSize:6.5 weight:NSFontWeightMedium];
    NSFont *rateFont = [NSFont monospacedDigitSystemFontOfSize:8.5 weight:NSFontWeightMedium];
    NSFont *upFont = [NSFont monospacedDigitSystemFontOfSize:5.8 weight:NSFontWeightMedium];
    const CGFloat labelKern = 0.5;

    // Largeur du pire cas, mesurée sur du texte réel (les gabarits du readout).
    CGFloat labelW = TMTextWidth(label, labelFont, labelKern) + (charging ? 5 : 0);
    CGFloat textW;
    if (dual) {
        NSString *template = readout[@"template"];
        NSString *upTemplate = [@"↑" stringByAppendingString:[template length] > 1 ? [template substringFromIndex:1] : @""];
        textW = MAX(TMTextWidth(template, rateFont, 0), labelW + 4 + TMTextWidth(upTemplate, upFont, 0));
    } else {
        textW = MAX(labelW, TMTextWidth(@"100", valueFont, 0) + 1 + TMTextWidth(unit, unitFont, 0));
    }
    textW = ceil(textW);
    CGFloat graphW = withBar ? 15 : spark ? 17 : 8;
    CGFloat w = left + textW + gap + graphW + 0.5;

    NSString *top = hasValue && dual ? readout[@"secondary"] : @"";
    NSString *rate = hasValue && dual ? readout[@"primary"] : @"";
    double fraction = dual ? [readout[@"rxFraction"] doubleValue] : [readout[@"fraction"] doubleValue];
    NSArray<NSNumber *> *series = readout[@"series"];
    BOOL autoScale = [readout[@"autoScale"] boolValue];

    return TMVectorImage(NSMakeSize(w, h), isTemplate, ^{
        const CGFloat labelBase = 11.4, valueBase = 2.6;
        NSColor *dim = [ink colorWithAlphaComponent:0.62];
        TMDrawTextAt(label, labelFont, dim, left, labelBase, NSTextAlignmentLeft, labelKern);
        if (charging) TMFillBolt(left + labelW - 1.6, labelBase + 2.1, dim);
        if (dual) {
            TMDrawTextAt(top, upFont, dim, left + textW, labelBase, NSTextAlignmentRight, 0);
            TMDrawTextAt(hasValue ? rate : @"—", rateFont, ink, left, valueBase, NSTextAlignmentLeft, 0);
        } else if (hasValue && value.length) {
            TMDrawTextAt(value, valueFont, ink, left, valueBase, NSTextAlignmentLeft, 0);
            TMDrawTextAt(unit, unitFont, [ink colorWithAlphaComponent:0.7],
                         left + TMTextWidth(value, valueFont, 0) + 1, valueBase, NSTextAlignmentLeft, 0);
        } else {
            TMDrawTextAt(@"—", valueFont, [ink colorWithAlphaComponent:0.6], left, valueBase, NSTextAlignmentLeft, 0);
        }
        CGFloat gx = left + textW + gap;
        if (spark) {
            TMDrawChipSpark(series, autoScale, hasValue, NSMakeRect(gx, 3, graphW, 12), ink, isTemplate);
        } else if (withBar) {
            TMDrawChipReservoir(fraction, hasValue, YES, NSMakeRect(gx, 5.5, graphW, 7), ink, isTemplate);
        } else {
            TMDrawChipReservoir(fraction, hasValue, NO, NSMakeRect(gx, 3, graphW, 12), ink, isTemplate);
        }
    });
}

// Forme réellement dessinée : celle demandée si elle sait représenter la donnée de ce widget, sinon
// la forme naturelle du readout. Les formes historiques passent telles quelles (inchangées pour les
// utilisateurs existants) ; les formes ajoutées exigent les champs du readout qu'elles dessinent.
NSString *TMWidgetResolvedShape(NSDictionary *readout, NSString *shape) {
    NSString *natural = [readout[@"style"] isKindOfClass:NSString.class] ? readout[@"style"] : @"";
    if (![shape isKindOfClass:NSString.class] || !shape.length) return natural;
    static NSSet<NSString *> *legacy, *needsFraction;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        legacy = [NSSet setWithArray:@[@"bars", @"graph", @"ring", @"pie", @"bar", @"text", @"twoLine", @"battery"]];
        needsFraction = [NSSet setWithArray:@[@"segments", @"dial", @"hub"]];
    });
    if ([legacy containsObject:shape]) return shape;
    BOOL numeric = [readout[@"numeric"] boolValue], dual = [readout[@"dual"] boolValue];
    BOOL chip = [readout[@"chipLabel"] isKindOfClass:NSString.class] && [readout[@"chipLabel"] length];
    if ([shape isEqual:@"ringValue"]) return numeric ? shape : natural;
    if ([needsFraction containsObject:shape]) return dual ? natural : shape;  // le réseau n'a pas de fraction
    if ([shape isEqual:@"dualArc"]) return dual ? shape : natural;
    if ([shape isEqual:@"chip"] || [shape isEqual:@"chipBar"]) return chip ? shape : natural;
    return natural;  // forme inconnue
}

// Les formes qui portent leur texte dans l'image n'ont pas de titre système à côté : le chiffre
// y serait dit deux fois.
BOOL TMWidgetShapeCarriesText(NSDictionary *readout, NSString *shape) {
    static NSSet<NSString *> *carrying;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        carrying = [NSSet setWithArray:@[@"text", @"twoLine", @"battery", @"ringValue", @"dualArc", @"chip", @"chipBar"]];
    });
    return [carrying containsObject:TMWidgetResolvedShape(readout, shape)];
}

NSDictionary *TMWidgetRenderSignature(NSDictionary *readout, NSString *shape, NSString *colorName) {
    NSString *resolved = TMWidgetResolvedShape(readout, shape);
    // Chaque champ de détail n'entre dans la signature que si la forme choisie le dessine : la série
    // glisse à chaque tick, les débits et les parts mémoire bougent de quelques % — alors que les
    // pixels, eux, ne changent que quand une valeur affichée change.
    BOOL sparkChip = [resolved isEqual:@"chip"] && [readout[@"chipKind"] isEqual:@"spark"];
    BOOL usesSeries = [resolved isEqual:@"bars"] || [resolved isEqual:@"graph"] || [shape isEqual:@"spark"] || sparkChip;
    NSMutableDictionary *signature = [readout mutableCopy] ?: [NSMutableDictionary dictionary];
    if (!usesSeries) [signature removeObjectForKey:@"series"];
    if (![resolved isEqual:@"segments"]) [signature removeObjectForKey:@"parts"];
    if (![resolved isEqual:@"dualArc"]) { [signature removeObjectForKey:@"rxFraction"]; [signature removeObjectForKey:@"txFraction"]; }
    signature[@"shape"] = resolved;
    signature[@"color"] = colorName ?: @"";
    return signature;
}

NSImage *TMWidgetImageStyled(NSDictionary *readout, NSString *shape, NSString *colorName) {
    BOOL isTemplate = YES;
    NSColor *ink = TMResolveWidgetInk(colorName, [readout[@"severity"] integerValue], &isTemplate);
    return TMWidgetImageWithInk(readout, shape, isTemplate ? nil : ink);
}

// Même dessin, encre déjà résolue : la jauge quota choisit la sienne autrement (identité du
// fournisseur affiché, qui n'est pas un nom de palette), et n'a pas à repasser par la table.
NSImage *TMWidgetImageWithInk(NSDictionary *readout, NSString *shape, NSColor *inkOrNil) {
    BOOL isTemplate = inkOrNil == nil;
    NSColor *ink = inkOrNil ?: NSColor.blackColor;
    BOOL hasValue = [readout[@"hasValue"] boolValue];
    shape = TMWidgetResolvedShape(readout, shape);

    if ([shape isEqual:@"bars"])
        return TMDrawBars(hasValue ? readout[@"series"] : @[], ink, isTemplate);
    if ([shape isEqual:@"graph"])
        return TMDrawGraph(hasValue ? readout[@"series"] : @[], ink, isTemplate);
    if ([shape isEqual:@"ring"])
        return TMDrawRing([readout[@"fraction"] doubleValue], hasValue, ink, isTemplate);
    if ([shape isEqual:@"pie"])
        return TMDrawPie([readout[@"fraction"] doubleValue], hasValue, ink, isTemplate);
    if ([shape isEqual:@"bar"])
        return TMDrawBar([readout[@"fraction"] doubleValue], hasValue, ink, isTemplate);
    double fraction = [readout[@"fraction"] doubleValue];
    if ([shape isEqual:@"ringValue"])
        return TMDrawRingValue(fraction, hasValue, readout[@"chipValue"], ink, isTemplate);
    if ([shape isEqual:@"segments"])
        return TMDrawSegments(fraction, hasValue, readout[@"parts"], ink, isTemplate);
    if ([shape isEqual:@"dial"])
        return TMDrawDial(fraction, hasValue, ink, isTemplate);
    if ([shape isEqual:@"hub"])
        return TMDrawHub(fraction, hasValue, ink, isTemplate);
    if ([shape isEqual:@"dualArc"])
        return TMDrawDualArc(readout, ink, isTemplate);
    if ([shape isEqual:@"chip"] || [shape isEqual:@"chipBar"])
        return TMDrawChip(readout, [shape isEqual:@"chipBar"], ink, isTemplate);
    NSString *textTemplate = readout[@"template"], *valueTemplate = readout[@"valueTemplate"];
    if ([shape isEqual:@"text"])
        return TMDrawText(hasValue ? readout[@"value"] : @"—", valueTemplate, ink, isTemplate);
    if ([shape isEqual:@"battery"])
        return TMDrawBattery([readout[@"fraction"] doubleValue], [readout[@"charging"] boolValue], hasValue,
                             readout[@"primary"], readout[@"secondary"], textTemplate, ink, isTemplate);
    // twoLine (défaut réseau/température/batterie-texte)
    if (!hasValue) return TMDrawTwoLine(@"—", @"", textTemplate, ink, isTemplate);
    return TMDrawTwoLine(readout[@"primary"], readout[@"secondary"], textTemplate, ink, isTemplate);
}

// Crénage plutôt que bourrage d'espaces : la chaîne reste exactement le texte lisible (VoiceOver,
// copie), et le complément de largeur se pose après le dernier caractère. Un espace inséré aurait
// été une largeur fixe imposée par la police, jamais la valeur exacte manquante.
NSAttributedString *TMTitleWithReservedWidth(NSString *text, NSString *widthTemplate,
                                             NSDictionary<NSAttributedStringKey, id> *attributes) {
    NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:text ?: @"" attributes:attributes];
    if (!widthTemplate.length || !text.length) return title;
    CGFloat have = [text sizeWithAttributes:attributes].width;
    CGFloat want = [widthTemplate sizeWithAttributes:attributes].width;
    if (want - have > 0.01)
        [title addAttribute:NSKernAttributeName value:@(want - have) range:NSMakeRange(text.length - 1, 1)];
    return title;
}

// Rendu par défaut : forme naturelle, couleur auto. Sert aux tests et au premier tick.
NSImage *TMWidgetImage(NSDictionary *readout) {
    return TMWidgetImageStyled(readout, readout[@"style"], nil);
}
