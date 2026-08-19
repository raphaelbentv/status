#import "StatusMenuBarWidgets.h"

#pragma mark - Catalogue

NSArray<NSString *> *TMMenuBarWidgetIDs(void) {
    return @[@"cpu", @"memory", @"gpu", @"network", @"temperature", @"battery", @"disk"];
}

NSString *TMMenuBarWidgetLabel(NSString *widgetId) {
    NSDictionary *labels = @{
        @"cpu": @"CPU", @"memory": @"Mémoire", @"gpu": @"GPU", @"network": @"Réseau",
        @"temperature": @"Température", @"battery": @"Batterie", @"disk": @"Disque",
    };
    return labels[widgetId] ?: widgetId;
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
    }
    return 0;
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
    return @{ @"template": @"100 %", @"valueTemplate": @"100 %" };  // cpu, gpu, memory, disk
}

NSDictionary *TMWidgetReadout(NSString *widgetId, NSDictionary *snapshot) {
    NSDictionary *templates = TMWidgetTemplates(widgetId);
    NSMutableDictionary *r = [@{ @"style": @"pie", @"hasValue": @NO, @"title": @"", @"value": @"",
                                 @"primary": @"", @"secondary": @"", @"fraction": @0,
                                 @"series": @[], @"charging": @NO,
                                 @"template": templates[@"template"],
                                 @"valueTemplate": templates[@"valueTemplate"],
                                 @"severity": @(TMWidgetSeverity(widgetId, snapshot)) } mutableCopy];

    if ([widgetId isEqual:@"cpu"] || [widgetId isEqual:@"gpu"]) {
        NSString *fam = widgetId, *key = [widgetId isEqual:@"cpu"] ? @"total" : @"usage";
        NSNumber *value = TMNum(TMFamilyNow(snapshot, fam)[key]);
        r[@"style"] = @"bars";
        if (value) {
            r[@"hasValue"] = @YES;
            r[@"title"] = r[@"value"] = TMPct(value);
            r[@"fraction"] = @(MIN(MAX(value.doubleValue / 100.0, 0), 1));
            r[@"series"] = TMFamilySeries(snapshot, fam, key);
        }
    } else if ([widgetId isEqual:@"memory"] || [widgetId isEqual:@"disk"]) {
        NSString *fam = [widgetId isEqual:@"memory"] ? @"ram" : @"disk";
        NSNumber *value = TMNum(TMFamilyNow(snapshot, fam)[@"usedPercent"]);
        r[@"style"] = @"pie";
        if (value) {
            r[@"hasValue"] = @YES;
            r[@"title"] = r[@"value"] = TMPct(value);
            r[@"fraction"] = @(MIN(MAX(value.doubleValue / 100.0, 0), 1));
            r[@"series"] = TMFamilySeries(snapshot, fam, @"usedPercent");
        }
    } else if ([widgetId isEqual:@"network"]) {
        NSDictionary *net = TMFamilyNow(snapshot, @"network");
        NSNumber *rx = TMNum(net[@"rxBytesPerSec"]), *tx = TMNum(net[@"txBytesPerSec"]);
        r[@"style"] = @"twoLine";
        if (rx || tx) {
            r[@"hasValue"] = @YES;
            r[@"primary"] = [@"↓ " stringByAppendingString:TMFmtRate(rx.doubleValue)];
            r[@"secondary"] = [@"↑ " stringByAppendingString:TMFmtRate(tx.doubleValue)];
            r[@"value"] = r[@"primary"];
        }
    } else if ([widgetId isEqual:@"temperature"]) {
        NSNumber *temp = TMNum(TMFamilyNow(snapshot, @"sensors")[@"tempC"]);
        r[@"style"] = @"twoLine";
        if (temp) {
            r[@"hasValue"] = @YES;
            r[@"primary"] = r[@"value"] = [NSString stringWithFormat:@"%.0f°", round(temp.doubleValue)];
            r[@"fraction"] = @(MIN(MAX(temp.doubleValue / 100.0, 0), 1));  // 0-100 °C pour l'anneau
            NSNumber *watts = TMNum(TMFamilyNow(snapshot, @"battery")[@"powerWatts"]);
            r[@"secondary"] = watts ? [NSString stringWithFormat:@"%.0f W", round(fabs(watts.doubleValue))] : @"";
        }
    } else if ([widgetId isEqual:@"battery"]) {
        NSDictionary *b = TMFamilyNow(snapshot, @"battery");
        NSNumber *pct = TMNum(b[@"percent"]);
        r[@"style"] = @"battery";
        if (pct) {
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

static void TMDrawDash(NSColor *ink, CGFloat cx, CGFloat cy) {
    NSBezierPath *dash = [NSBezierPath bezierPath];
    dash.lineWidth = 1.6; dash.lineCapStyle = NSLineCapStyleRound;
    [dash moveToPoint:NSMakePoint(cx - 2.4, cy)];
    [dash lineToPoint:NSMakePoint(cx + 2.4, cy)];
    [[ink colorWithAlphaComponent:0.55] setStroke];
    [dash stroke];
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

// Histogramme : les derniers échantillons en barres verticales, plus récent à droite, échelle 0-100.
static NSImage *TMDrawBars(NSArray<NSNumber *> *series, NSColor *ink, BOOL isTemplate) {
    const CGFloat w = 26, h = 18, pad = 1;
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
    [image lockFocus];
    NSArray<NSNumber *> *pts = series.count > 17 ? [series subarrayWithRange:NSMakeRange(series.count - 17, 17)] : series;
    if (pts.count < 1) { TMDrawDash(ink, w / 2, h / 2); }
    else {
        CGFloat plotW = w - 2 * pad, plotH = h - 2 * pad;
        CGFloat slot = plotW / pts.count, barW = MAX(1, slot - 0.6);
        [ink setFill];
        for (NSUInteger i = 0; i < pts.count; i++) {
            CGFloat v = MIN(MAX(pts[i].doubleValue, 0), 100) / 100.0;
            CGFloat barH = MAX(0.8, v * plotH);
            NSRect bar = NSMakeRect(pad + i * slot, pad, barW, barH);
            [[NSBezierPath bezierPathWithRect:bar] fill];
        }
    }
    [image unlockFocus];
    image.template = isTemplate;
    return image;
}

// Camembert : disque plein proportionnel, sur une piste faible.
static NSImage *TMDrawPie(double fraction, BOOL hasValue, NSColor *ink, BOOL isTemplate) {
    const CGFloat side = 18, radius = 6.6;
    NSPoint c = NSMakePoint(side / 2, side / 2);
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(side, side)];
    [image lockFocus];
    NSBezierPath *track = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - radius, c.y - radius, 2 * radius, 2 * radius)];
    [[ink colorWithAlphaComponent:isTemplate ? 0.25 : 0.28] setFill];
    [track fill];
    if (!hasValue) { TMDrawDash(ink, c.x, c.y); }
    else if (fraction > 0) {
        NSBezierPath *wedge = [NSBezierPath bezierPath];
        [wedge moveToPoint:c];
        [wedge appendBezierPathWithArcWithCenter:c radius:radius startAngle:90 endAngle:90 - MIN(MAX(fraction, 0), 1) * 360 clockwise:YES];
        [wedge closePath];
        [ink setFill];
        [wedge fill];
    }
    [image unlockFocus];
    image.template = isTemplate;
    return image;
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

// Anneau (piste faible + arc de fraction, part de midi, sens horaire) — comme la jauge quota.
static NSImage *TMDrawRing(double fraction, BOOL hasValue, NSColor *ink, BOOL isTemplate) {
    const CGFloat side = 18, radius = 6.3, lineWidth = 2.0;
    NSPoint c = NSMakePoint(side / 2, side / 2);
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(side, side)];
    [image lockFocus];
    NSBezierPath *track = [NSBezierPath bezierPath];
    [track appendBezierPathWithArcWithCenter:c radius:radius startAngle:0 endAngle:360];
    track.lineWidth = lineWidth;
    [[ink colorWithAlphaComponent:isTemplate ? 0.3 : 0.28] setStroke];
    [track stroke];
    if (!hasValue) { TMDrawDash(ink, c.x, c.y); }
    else if (fraction > 0) {
        NSBezierPath *arc = [NSBezierPath bezierPath];
        [arc appendBezierPathWithArcWithCenter:c radius:radius startAngle:90 endAngle:90 - MIN(MAX(fraction, 0), 1) * 360 clockwise:YES];
        arc.lineWidth = lineWidth; arc.lineCapStyle = NSLineCapStyleRound;
        [ink setStroke]; [arc stroke];
    }
    [image unlockFocus];
    image.template = isTemplate;
    return image;
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

// Dessin selon la forme choisie. Une forme qui ne peut pas représenter la donnée retombe sur la
// forme naturelle du widget (readout[@"style"]).
NSImage *TMWidgetImageStyled(NSDictionary *readout, NSString *shape, NSString *colorName) {
    BOOL isTemplate = YES;
    NSColor *ink = TMResolveWidgetInk(colorName, [readout[@"severity"] integerValue], &isTemplate);
    BOOL hasValue = [readout[@"hasValue"] boolValue];
    if (!shape.length) shape = readout[@"style"];

    if ([shape isEqual:@"bars"])
        return TMDrawBars(hasValue ? readout[@"series"] : @[], ink, isTemplate);
    if ([shape isEqual:@"graph"])
        return TMDrawGraph(hasValue ? readout[@"series"] : @[], ink, isTemplate);
    if ([shape isEqual:@"ring"])
        return TMDrawRing([readout[@"fraction"] doubleValue], hasValue, ink, isTemplate);
    if ([shape isEqual:@"pie"])
        return TMDrawPie([readout[@"fraction"] doubleValue], hasValue, ink, isTemplate);
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
