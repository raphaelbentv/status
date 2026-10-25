#import <Cocoa/Cocoa.h>
#include <math.h>

// Jauges natives de 18 points : la partie pleine représente toujours le quota restant.
static NSArray<NSString *> *TMIconDesignIDs(void) {
    return @[@"doubleRing", @"capsules", @"doubleArc", @"boldRing", @"reservoir", @"segments",
             @"hairline", @"thinRing", @"tube", @"grid", @"squircle"];
}
static NSArray<NSString *> *TMIconDesignNames(void) {
    return @[@"Double anneau", @"Capsules", @"Double arc", @"Anneau épais", @"Réservoir", @"5 segments",
             @"Filet", @"Anneau fin", @"Tube", @"Grille", @"Carré"];
}
static void TMDesignArc(NSPoint center, CGFloat radius, CGFloat start, CGFloat end, CGFloat width) {
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p appendBezierPathWithArcWithCenter:center radius:radius startAngle:start endAngle:end clockwise:YES];
    p.lineWidth = width;
    p.lineCapStyle = NSLineCapStyleRound;
    [p stroke];
}
// Cinq styles assortis aux designs de la fenêtre (moderne, dark, neon, bento, widget). Chacun se lit
// en silhouette seule : contour pour la forme, aplat pour le restant, donc sans compter sur la
// couleur. Donnée absente = tiret (ou cases creuses pour la grille), jamais un faux zéro.
static void TMStyledDesign(NSString *style, double value, BOOL known, NSColor *ink) {
    [ink set];
    if ([style isEqual:@"hairline"]) {            // moderne : filet d'un point, barre fine
        NSRect box=NSMakeRect(1.5,5.5,15,7);
        NSBezierPath *frame=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box,0.5,0.5) xRadius:2.5 yRadius:2.5];
        frame.lineWidth=1; [frame stroke];
        if (known && value>0) NSRectFill(NSMakeRect(3.5,7.5,11*value,3));
        if (!known) NSRectFill(NSMakeRect(6.5,8.5,5,1));
    } else if ([style isEqual:@"thinRing"]) {     // dark : anneau très fin
        [[ink colorWithAlphaComponent:0.28] set];
        TMDesignArc(NSMakePoint(9,9),7.3,90,-270,1.3);
        [ink set];
        if (known && value>0) TMDesignArc(NSMakePoint(9,9),7.3,90,90-359.9*value,1.3);
        if (!known) NSRectFill(NSMakeRect(6.5,8.5,5,1));
    } else if ([style isEqual:@"tube"]) {         // neon : tube à contour, cœur plein
        NSRect box=NSMakeRect(1,5.2,16,7.6);
        NSBezierPath *outline=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box,0.6,0.6) xRadius:3.2 yRadius:3.2];
        outline.lineWidth=1.2; [outline stroke];
        if (known && value>0) {
            [[ink colorWithAlphaComponent:0.3] set];
            NSRect halo=NSMakeRect(2.6,6.8,12.8*value,4.4);
            [[NSBezierPath bezierPathWithRoundedRect:halo xRadius:2.2 yRadius:2.2] fill];
            [ink set];
            NSRect core=NSMakeRect(3.4,7.8,11.2*value,2.4);
            [[NSBezierPath bezierPathWithRoundedRect:core xRadius:1.2 yRadius:1.2] fill];
        }
        if (!known) NSRectFill(NSMakeRect(6.5,8.5,5,1));
    } else if ([style isEqual:@"grid"]) {         // bento : 3 × 3 cases, remplies du bas vers le haut
        double cells=value*9;
        for (int i=0;i<9;i++) {
            NSRect cell=NSMakeRect(1.5+(i%3)*5.2,1.5+(i/3)*5.2,4.4,4.4);
            NSBezierPath *path=[NSBezierPath bezierPathWithRoundedRect:cell xRadius:1.2 yRadius:1.2];
            if (!known) { path=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(cell,0.5,0.5) xRadius:1 yRadius:1]; path.lineWidth=1; [ink set]; [path stroke]; continue; }
            double part=MIN(1,MAX(0,cells-i));
            [[ink colorWithAlphaComponent:0.22+0.78*part] set];
            [path fill];
        }
    } else {                                      // widget : carré arrondi qui se remplit
        NSRect box=NSMakeRect(2,2,14,14);
        NSBezierPath *frame=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box,0.6,0.6) xRadius:4 yRadius:4];
        [[ink colorWithAlphaComponent:0.2] set]; [frame fill];
        [ink set]; frame.lineWidth=1.2; [frame stroke];
        if (known && value>0) {
            [NSGraphicsContext saveGraphicsState];
            [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box,0.6,0.6) xRadius:4 yRadius:4] addClip];
            NSRectFill(NSMakeRect(2,2,14,14*value));
            [NSGraphicsContext restoreGraphicsState];
        }
        if (!known) NSRectFill(NSMakeRect(6.5,8.5,5,1.4));
    }
}
// Fractions are REMAINING weekly quota. A missing provider is a dash, never a fake zero.
static NSImage *TMIconDesign(NSString *style, NSNumber *remaining, NSColor *ink) {
    if (![remaining isKindOfClass:NSNumber.class] || !isfinite(remaining.doubleValue)) remaining=nil;
    return [NSImage imageWithSize:NSMakeSize(18, 18) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [ink set];
        NSArray *values = @[remaining ?: NSNull.null, remaining ?: NSNull.null];
        if ([@[@"hairline",@"thinRing",@"tube",@"grid",@"squircle"] containsObject:style]) {
            TMStyledDesign(style, remaining ? MIN(1,MAX(0,remaining.doubleValue)) : 0, remaining!=nil, ink);
            return YES;
        }
        if ([@[@"boldRing",@"reservoir",@"segments"] containsObject:style]) {
            BOOL known=remaining!=nil;
            double value=known ? MIN(1,MAX(0,remaining.doubleValue)) : 0;
            if ([style isEqual:@"boldRing"]) {
                [[ink colorWithAlphaComponent:0.3] set];
                TMDesignArc(NSMakePoint(9,9),6.3,90,-270,3.2);
                [ink set];
                if (known && value>0) TMDesignArc(NSMakePoint(9,9),6.3,90,90-359.9*value,3.2);
            } else if ([style isEqual:@"reservoir"]) {
                NSRect box=NSMakeRect(1,4,16,10);
                NSBezierPath *outline=[NSBezierPath bezierPathWithRoundedRect:box xRadius:3 yRadius:3];
                outline.lineWidth=1.6; [outline stroke];
                if (known && value>0) {
                    [NSGraphicsContext saveGraphicsState];
                    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box,2,2) xRadius:1 yRadius:1] addClip];
                    NSRectFill(NSMakeRect(3,6,12*value,6));
                    [NSGraphicsContext restoreGraphicsState];
                }
            } else {
                for (int i=0;i<5;i++) {
                    [[ink colorWithAlphaComponent:0.25] set];
                    NSRect cell=NSMakeRect(0.5+i*3.5,4,2.7,10);
                    [[NSBezierPath bezierPathWithRoundedRect:cell xRadius:1 yRadius:1] fill];
                    double part=MIN(1,MAX(0,value*5-i));
                    if (known && part>0) {
                        [ink set];
                        [NSGraphicsContext saveGraphicsState];
                        NSRectClip(NSMakeRect(cell.origin.x,cell.origin.y,cell.size.width,cell.size.height*part));
                        [[NSBezierPath bezierPathWithRoundedRect:cell xRadius:1 yRadius:1] fill];
                        [NSGraphicsContext restoreGraphicsState];
                    }
                }
            }
            if (!known) { [ink set]; NSRectFill(NSMakeRect(6,8,6,2)); }
            return YES;
        }

        if ([@[@"doubleRing", @"capsules", @"doubleArc"] containsObject:style]) {
            for (NSUInteger i = 0; i < 2; i++) {
                BOOL known = values[i] != NSNull.null;
                CGFloat value = known ? MIN(1, MAX(0, [values[i] doubleValue])) : 0;
                [[ink colorWithAlphaComponent:0.25] set];
                if ([style isEqualToString:@"capsules"]) {
                    NSRect box = NSMakeRect(i ? 10 : 2, 1.5, 5.5, i ? 12 : 15);
                    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:box xRadius:2.75 yRadius:2.75];
                    outline.lineWidth = 1.2;
                    [ink set]; [outline stroke];
                    NSRect inside = NSInsetRect(box, 1.3, 1.3);
                    if (known && value > 0) {
                        [NSGraphicsContext saveGraphicsState];
                        [[NSBezierPath bezierPathWithRoundedRect:inside xRadius:1.4 yRadius:1.4] addClip];
                        NSRectFill(NSMakeRect(inside.origin.x, inside.origin.y, inside.size.width, inside.size.height * value));
                        [NSGraphicsContext restoreGraphicsState];
                    } else if (!known) NSRectFill(NSMakeRect(box.origin.x + 1.5, NSMidY(box), 2.5, 1));
                } else {
                    BOOL half = [style isEqualToString:@"doubleArc"];
                    NSPoint center = NSMakePoint(9, half ? 4.5 : 9);
                    CGFloat radius = i ? 4.4 : 7.3;
                    CGFloat start = half ? 170 : 82, sweep = half ? 160 : 344;
                    TMDesignArc(center, radius, start, start - sweep, 1.55);
                    [ink set];
                    if (known && value > 0) TMDesignArc(center, radius, start, start - sweep * value, 1.55);
                    else if (!known) TMDesignArc(center, radius, start - sweep / 2 + 7, start - sweep / 2 - 7, 1.55);
                }
            }
        }
        return YES;
    }];
}

// Couleur seule pour distinguer les fournisseurs, sans pictogramme adjacent.
// Dessiner directement avec l’encre évite les effets SourceIn sur les images voisines.
static NSImage *TMProviderGauge(NSString *style, NSNumber *remaining, BOOL openAI) {
    NSColor *ink=openAI ? [NSColor colorWithSRGBRed:0.20 green:0.65 blue:1 alpha:1]
                       : [NSColor colorWithSRGBRed:1 green:0.55 blue:0.28 alpha:1];
    return TMIconDesign(style,remaining,ink);
}
