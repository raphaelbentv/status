#import "StatusI18n.h"
#import "StatusDisplays.h"
#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <objc/message.h>

NSString *const TMKeyboardBacklightIdentifier = @"keyboard";

#pragma mark - Logique pure

double TMClampBrightnessPercent(double percent) {
    if (isnan(percent) || isinf(percent)) return 0;
    return MIN(MAX(percent, 0.0), 100.0);
}

double TMSteppedBrightness(double current, BOOL increase, double stepPercent) {
    double step = fabs(stepPercent);
    return TMClampBrightnessPercent(current + (increase ? step : -step));
}

NSInteger TMPercentFromVCPValue(uint16_t current, uint16_t maximum) {
    if (maximum == 0) return 0;
    double percent = 100.0 * (double)current / (double)maximum;
    return (NSInteger)round(TMClampBrightnessPercent(percent));
}

uint16_t TMVCPValueFromPercent(double percent, uint16_t maximum) {
    if (maximum == 0) return 0;
    double value = round(TMClampBrightnessPercent(percent) / 100.0 * (double)maximum);
    return (uint16_t)MIN(MAX(value, 0.0), (double)maximum);
}

const uint8_t TMDDCBrightnessVCPCode = 0x10;  // VCP MCCS « Luminosité », norme VESA publique.

// Adresses DDC/CI (norme VESA MCCS) : 0x37 en 7 bits, 0x51 comme adresse source virtuelle de
// l'hôte dans une requête, 0x6E comme graine de checksum côté requête (0x37 décalé, bit
// lecture/écriture à 0). Ce format de trame est un standard public ; seul le transport (I2C via
// IOAVService, voir plus bas) est une API privée Apple.
static uint8_t TMDDCChecksum(NSData *bytes, uint8_t seed) {
    uint8_t checksum = seed;
    const uint8_t *bytePtr = bytes.bytes;
    for (NSUInteger i = 0; i < bytes.length; i++) checksum ^= bytePtr[i];
    return checksum;
}

// Format aligné sur m1ddc (référence connue pour fonctionner sur les moniteurs tiers, sources
// vérifiées) : le buffer ne contient PAS l'octet source 0x51 — celui-ci est l'« offset » I2C passé
// en 3ᵉ argument de IOAVService (TMDDCInputAddress). D'où des trames plus courtes que la variante
// initiale, qui, elle, injectait un 0x51 en trop et ne pilotait aucun moniteur.
const uint32_t TMDDCInputAddress = 0x51;  // DEFAULT_INPUT_ADDRESS de m1ddc, passé en offset I2C

// Requête « Get VCP » : [0x82, 0x01, vcp, checksum]. Checksum = 0x6E ^ octets (sans 0x51 ici,
// exactement comme prepareDDCRead de m1ddc).
NSData *TMDDCGetVCPRequest(uint8_t vcpCode) {
    uint8_t p[4] = { 0x82, 0x01, vcpCode, 0 };
    p[3] = 0x6E ^ p[0] ^ p[1] ^ p[2];
    return [NSData dataWithBytes:p length:sizeof(p)];
}

// Requête « Set VCP » : [0x84, 0x03, vcp, valeurMSB, valeurLSB, checksum]. Checksum inclut l'adresse
// source 0x51 (comme prepareDDCWrite de m1ddc — asymétrie assumée avec le Get).
NSData *TMDDCSetVCPRequest(uint8_t vcpCode, uint16_t value) {
    uint8_t p[6] = { 0x84, 0x03, vcpCode, (uint8_t)(value >> 8), (uint8_t)(value & 0xFF), 0 };
    p[5] = 0x6E ^ (uint8_t)TMDDCInputAddress ^ p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4];
    return [NSData dataWithBytes:p length:sizeof(p)];
}

// Réponse « Get VCP Feature » (12 octets lus) : [2] opcode 0x02, [3] résultat, [4] code VCP,
// [6-7] maximum, [8-9] courant (gros-boutiste). On valide l'opcode, le code VCP et un maximum
// plausible — assez pour écarter une réponse parasite (un écran Apple, qui ne parle pas DDC, rend
// du charabia dont l'octet [2] n'est pas 0x02) sans dépendre d'une convention de checksum de
// réponse incertaine selon les sources (m1ddc ne la vérifie pas).
BOOL TMDDCParseVCPReply(NSData *reply, uint8_t expectedVCPCode, uint16_t *outCurrent, uint16_t *outMaximum) {
    if (reply.length < 10) return NO;
    const uint8_t *b = reply.bytes;
    if (b[2] != 0x02) return NO;               // pas une réponse « Get VCP Feature »
    if (b[3] != 0x00) return NO;               // le moniteur signale une erreur (VCP non pris en charge…)
    if (b[4] != expectedVCPCode) return NO;    // trame décalée ou corrompue
    uint16_t maximum = (uint16_t)((b[6] << 8) | b[7]);
    uint16_t current = (uint16_t)((b[8] << 8) | b[9]);
    if (maximum == 0 || maximum > 0x2710) return NO;  // 10000 : borne de plausibilité MCCS
    if (outMaximum) *outMaximum = maximum;
    if (outCurrent) *outCurrent = current;
    return YES;
}

#pragma mark - Symboles privés (chargés par dlsym — jamais liés statiquement)

// DisplayServicesGetBrightness/SetBrightness et non CoreDisplay_Display_Get/SetUserBrightness :
// vérifié empiriquement sur la machine de développement (macOS 26/27) que CoreDisplay ment sur
// cette version — get renvoie toujours 1.0 quelle que soit la luminosité réelle, et set n'a aucun
// effet. DisplayServices, lui, lit et écrit correctement (confirmé par relecture indépendante
// après écriture). Voir docs/superpowers/specs/2026-07-23-controle-luminosite-design.md, §Tests.
typedef int (*TMDisplayServicesGetFn)(CGDirectDisplayID, float *);
typedef int (*TMDisplayServicesSetFn)(CGDirectDisplayID, float);
typedef CFTypeRef (*TMIOAVServiceCreateWithServiceFn)(CFAllocatorRef, io_service_t);
typedef IOReturn (*TMIOAVServiceReadI2CFn)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);
typedef IOReturn (*TMIOAVServiceWriteI2CFn)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);

static TMDisplayServicesGetFn TMDisplayServicesGet;
static TMDisplayServicesSetFn TMDisplayServicesSet;
static TMIOAVServiceCreateWithServiceFn TMIOAVServiceCreateWithService;
static TMIOAVServiceReadI2CFn TMIOAVServiceReadI2C;
static TMIOAVServiceWriteI2CFn TMIOAVServiceWriteI2C;

// Best-effort : le framework privé est chargé sans condition, puis chaque symbole est résolu
// indépendamment. Un dlopen qui échoue ou un symbole absent laisse simplement le pointeur à NULL —
// la famille correspondante (interne ou externe) se déclare alors indisponible, exactement comme
// un collecteur du Moniteur qui rendrait nil. Aucun risque de plantage ni d'échec de build si
// Apple renomme ou retire un symbole dans une future version de macOS.
static void TMLoadPrivateDisplaySymbols(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY);
        TMDisplayServicesGet = (TMDisplayServicesGetFn)dlsym(RTLD_DEFAULT, "DisplayServicesGetBrightness");
        TMDisplayServicesSet = (TMDisplayServicesSetFn)dlsym(RTLD_DEFAULT, "DisplayServicesSetBrightness");
        TMIOAVServiceCreateWithService = (TMIOAVServiceCreateWithServiceFn)dlsym(RTLD_DEFAULT, "IOAVServiceCreateWithService");
        TMIOAVServiceReadI2C = (TMIOAVServiceReadI2CFn)dlsym(RTLD_DEFAULT, "IOAVServiceReadI2C");
        TMIOAVServiceWriteI2C = (TMIOAVServiceWriteI2CFn)dlsym(RTLD_DEFAULT, "IOAVServiceWriteI2C");
    });
}

#pragma mark - Identification (API publique uniquement)

static NSString *TMDisplayName(CGDirectDisplayID displayID, BOOL builtin) {
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
        if (number.unsignedIntValue == displayID) return screen.localizedName;
    }
    return builtin ? TMT(@"disp.internal") : TMT(@"disp.external");
}

static NSString *TMDisplayIdentifier(CGDirectDisplayID displayID, BOOL builtin) {
    if (builtin) return @"builtin";
    uint32_t vendor = CGDisplayVendorNumber(displayID);
    uint32_t model = CGDisplayModelNumber(displayID);
    uint32_t serial = CGDisplaySerialNumber(displayID);
    if (vendor || model || serial) return [NSString stringWithFormat:@"ext-%u-%u-%u", vendor, model, serial];
    return [NSString stringWithFormat:@"ext-id-%u", displayID];  // repli : stable pour la session, pas au rebranchement
}

// Un service par port de sortie vidéo EXTERNE candidat au DDC/CI (Apple Silicon). On filtre sur la
// propriété Location == « External » : le registre expose aussi un DCPAVServiceProxy « Embedded »
// (la dalle interne), qu'il ne faut pas apparier à un moniteur externe — sinon le DDC viserait le
// mauvais port. L'appelant possède les io_service_t retournés et doit les libérer.
static NSArray<NSValue *> *TMCopyExternalAVServiceHandles(void) {
    NSMutableArray<NSValue *> *services = [NSMutableArray array];
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) != KERN_SUCCESS)
        return services;
    io_object_t service;
    while ((service = IOIteratorNext(iterator))) {
        CFTypeRef location = IORegistryEntryCreateCFProperty(service, CFSTR("Location"), kCFAllocatorDefault, 0);
        BOOL external = location && CFGetTypeID(location) == CFStringGetTypeID()
                     && CFStringCompare(location, CFSTR("External"), 0) == kCFCompareEqualTo;
        if (location) CFRelease(location);
        if (external) [services addObject:[NSValue valueWithPointer:(void *)(uintptr_t)service]];
        else IOObjectRelease(service);  // Embedded ou sans Location : pas un port externe
    }
    IOObjectRelease(iterator);
    return services;
}

#pragma mark - TMDisplay

// Interne au fichier : le manager a besoin de l'identifiant CoreGraphics pour retrouver l'écran
// sous la souris, mais rien à l'extérieur n'a à connaître ce détail de plomberie.
@interface TMDisplay ()
@property (readonly) CGDirectDisplayID displayID;
@end

@implementation TMDisplay {
    CGDirectDisplayID _displayID;
    BOOL _available;
    NSNumber *_brightnessPercent;
    CFTypeRef _avService;    // +1, écrans externes uniquement ; libéré au dealloc
    uint16_t _ddcMaximum;    // maximum VCP relevé à la détection ; nécessaire pour reconvertir un %
    BOOL _useDisplayServices; // méthode retenue : DisplayServices (Apple) plutôt que DDC/CI (tiers)
    BOOL _ddcWriteOnly;      // DDC pilotable en écriture mais illisible : on n'exige pas la lecture
}

- (instancetype)initWithDisplayID:(CGDirectDisplayID)displayID
                              kind:(TMDisplayKind)kind
                              name:(NSString *)name
                        identifier:(NSString *)identifier
                         avService:(nullable CFTypeRef)avService {
    if ((self = [super init])) {
        _displayID = displayID;
        _kind = kind;
        _name = [name copy];
        _identifier = [identifier copy];
        _avService = avService;
        [self syncFromHardware];
    }
    return self;
}

- (void)dealloc {
    if (_avService) CFRelease(_avService);
}

- (CGDirectDisplayID)displayID { return _displayID; }

// Les touches F1/F2 arrivent sur le thread du tap (voir Status.m), les curseurs et la relecture
// sur le thread principal : l'état d'un écran est donc lu et écrit sous son propre verrou.
- (nullable NSNumber *)brightnessPercent { @synchronized (self) { return _brightnessPercent; } }
- (BOOL)available { @synchronized (self) { return _available; } }

- (void)syncFromHardware { @synchronized (self) { [self lockedSyncFromHardware]; } }

- (void)lockedSyncFromHardware {
    TMLoadPrivateDisplaySymbols();

    // 1) DisplayServices d'abord, pour TOUT écran. C'est le canal de l'écran interne — mais aussi
    //    des écrans Apple externes (Studio Display, Pro Display XDR), qui NE parlent PAS DDC/CI :
    //    vérifié sur un Studio Display, DisplayServicesGetBrightness y rend une vraie valeur
    //    propre à l'écran. Tenter DDC sur un écran Apple ne renvoie que du charabia.
    if (TMDisplayServicesGet) {
        float value = -1;
        if (TMDisplayServicesGet(_displayID, &value) == 0 && value >= 0) {
            _useDisplayServices = YES;
            _available = YES;
            _brightnessPercent = @(round(TMClampBrightnessPercent(value * 100.0)));
            return;
        }
    }

    // 2) Repli DDC/CI pour les moniteurs tiers (non-Apple). Format aligné sur m1ddc.
    _useDisplayServices = NO;
    if (_kind == TMDisplayKindBuiltin || !_avService || !TMIOAVServiceWriteI2C) {
        _available = NO; _brightnessPercent = nil; return;
    }

    // Lecture best-effort : certains moniteurs pilotables en écriture ne répondent pas aux lectures
    // DDC. On ne bloque donc PAS le pilotage sur une lecture réussie — si l'IOAVService existe et
    // que les écritures partent, l'écran est déclaré pilotable (curseur actionnable), quitte à
    // partir d'une valeur par défaut faute de lecture. C'est le comportement de MonitorControl.
    _ddcMaximum = 100;        // échelle MCCS par défaut ; corrigée si une lecture réussit
    _ddcWriteOnly = YES;
    _available = YES;
    _brightnessPercent = @50;  // valeur d'attente tant qu'aucune lecture n'a abouti

    if (TMIOAVServiceReadI2C) {
        NSData *request = TMDDCGetVCPRequest(TMDDCBrightnessVCPCode);
        // m1ddc envoie la requête deux fois (certains écrans ignorent la première), puis lit.
        for (int i = 0; i < 2; i++) { usleep(10000); TMIOAVServiceWriteI2C(_avService, 0x37, TMDDCInputAddress, (void *)request.bytes, (uint32_t)request.length); }
        uint8_t replyBuffer[12] = {0};
        usleep(10000);
        if (TMIOAVServiceReadI2C(_avService, 0x37, TMDDCInputAddress, replyBuffer, sizeof(replyBuffer)) == kIOReturnSuccess) {
            uint16_t current, maximum;
            if (TMDDCParseVCPReply([NSData dataWithBytes:replyBuffer length:sizeof(replyBuffer)],
                                   TMDDCBrightnessVCPCode, &current, &maximum)) {
                _ddcMaximum = maximum;
                _ddcWriteOnly = NO;
                _brightnessPercent = @(TMPercentFromVCPValue(current, maximum));
            }
        }
    }
}

- (BOOL)setBrightnessPercent:(double)percent { @synchronized (self) { return [self lockedSetBrightnessPercent:percent]; } }

- (BOOL)lockedSetBrightnessPercent:(double)percent {
    double clamped = TMClampBrightnessPercent(percent);
    if (_useDisplayServices) {
        if (!TMDisplayServicesSet) return NO;
        if (TMDisplayServicesSet(_displayID, (float)(clamped / 100.0)) != 0) return NO;
        _brightnessPercent = @(round(clamped));
        return YES;
    }
    // DDC/CI : écriture répétée deux fois (comme m1ddc), échelle _ddcMaximum.
    if (!_avService || !TMIOAVServiceWriteI2C || _ddcMaximum == 0) return NO;
    NSData *request = TMDDCSetVCPRequest(TMDDCBrightnessVCPCode, TMVCPValueFromPercent(clamped, _ddcMaximum));
    IOReturn result = kIOReturnError;
    for (int i = 0; i < 2; i++) { usleep(10000); result = TMIOAVServiceWriteI2C(_avService, 0x37, TMDDCInputAddress, (void *)request.bytes, (uint32_t)request.length); }
    if (result != kIOReturnSuccess) return NO;
    _brightnessPercent = @(round(clamped));  // optimiste : pas de relecture DDC à chaque écriture
    return YES;
}

@end

#pragma mark - TMKeyboardBacklight

// Rétroéclairage du clavier intégré : KeyboardBrightnessClient (framework privé CoreBrightness),
// le client qu'utilise le Centre de contrôle. Résolu à l'exécution par NSClassFromString — jamais
// lié — comme les symboles d'écran : absent sur une future version de macOS, la ligne disparaît
// simplement. Vérifié sur la machine de développement (macOS 27, M4 Max) : setBrightness:
// forKeyboard: s'applique immédiatement et brightnessForKeyboard: relit la valeur écrite.
// La valeur est relue à chaque instantané (pas de cache) : les touches du clavier, l'atténuation
// automatique et le Centre de contrôle la modifient sans prévenir Status.
@implementation TMKeyboardBacklight {
    id _client;
    unsigned long long _keyboardID;
}

- (instancetype)init {
    if ((self = [super init])) {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY);
        Class clientClass = NSClassFromString(@"KeyboardBrightnessClient");
        SEL idsSelector = NSSelectorFromString(@"copyKeyboardBacklightIDs");
        if (!clientClass || ![clientClass instancesRespondToSelector:idsSelector]
            || ![clientClass instancesRespondToSelector:NSSelectorFromString(@"brightnessForKeyboard:")]
            || ![clientClass instancesRespondToSelector:NSSelectorFromString(@"setBrightness:forKeyboard:")]) return self;
        id client = [clientClass new];
        id (*copyIDs)(id, SEL) = (void *)objc_msgSend;
        NSArray *ids = copyIDs(client, idsSelector);
        if (![ids isKindOfClass:NSArray.class]) return self;
        // Le clavier intégré d'abord : c'est lui qu'on règle depuis le Mac ; un clavier externe
        // rétroéclairé n'est retenu qu'à défaut.
        BOOL (*isBuiltIn)(id, SEL, unsigned long long) = (void *)objc_msgSend;
        SEL builtInSelector = NSSelectorFromString(@"isKeyboardBuiltIn:");
        NSNumber *chosen = nil;
        for (NSNumber *candidate in ids) {
            if (![candidate isKindOfClass:NSNumber.class]) continue;
            if (!chosen) chosen = candidate;
            if ([client respondsToSelector:builtInSelector] && isBuiltIn(client, builtInSelector, candidate.unsignedLongLongValue)) { chosen = candidate; break; }
        }
        if (!chosen) return self;
        _client = client;
        _keyboardID = chosen.unsignedLongLongValue;
    }
    return self;
}

- (BOOL)available { return _client != nil; }

- (nullable NSNumber *)brightnessPercent {
    if (!_client) return nil;
    float (*get)(id, SEL, unsigned long long) = (void *)objc_msgSend;
    float value = get(_client, NSSelectorFromString(@"brightnessForKeyboard:"), _keyboardID);
    if (isnan(value) || value < 0) return nil;
    return @(round(TMClampBrightnessPercent(value * 100.0)));
}

- (BOOL)setBrightnessPercent:(double)percent {
    if (!_client) return NO;
    BOOL (*set)(id, SEL, float, unsigned long long) = (void *)objc_msgSend;
    return set(_client, NSSelectorFromString(@"setBrightness:forKeyboard:"),
               (float)(TMClampBrightnessPercent(percent) / 100.0), _keyboardID);
}

@end

#pragma mark - TMDisplayManager

@implementation TMDisplayManager {
    NSArray<TMDisplay *> *_displays;
}

- (NSArray<TMDisplay *> *)displays { @synchronized (self) { return _displays ?: @[]; } }

- (instancetype)init {
    if ((self = [super init])) _keyboard = [TMKeyboardBacklight new];
    return self;
}

- (void)rescan {
    TMLoadPrivateDisplaySymbols();
    uint32_t maxDisplays = 16;
    CGDirectDisplayID ids[16];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(maxDisplays, ids, &count) != kCGErrorSuccess) count = 0;

    // Appariement par ordre d'énumération : correct sans ambiguïté avec un seul écran externe (le
    // cas courant). Avec plusieurs, l'ordre entre CGGetActiveDisplayList et DCPAVServiceProxy
    // n'est pas garanti correspondre à l'agencement physique — limite documentée dans le design,
    // faute de pouvoir la lever de façon vérifiable sans matériel de test.
    NSArray<NSValue *> *avHandles = TMIOAVServiceCreateWithService ? TMCopyExternalAVServiceHandles() : @[];
    NSUInteger avIndex = 0;
    NSMutableArray<TMDisplay *> *displays = [NSMutableArray arrayWithCapacity:count];
    for (uint32_t i = 0; i < count; i++) {
        BOOL builtin = CGDisplayIsBuiltin(ids[i]);
        CFTypeRef avService = NULL;
        if (!builtin && avIndex < avHandles.count) {
            io_service_t rawService = (io_service_t)(uintptr_t)[avHandles[avIndex] pointerValue];
            avIndex++;
            if (TMIOAVServiceCreateWithService) avService = TMIOAVServiceCreateWithService(kCFAllocatorDefault, rawService);
            IOObjectRelease(rawService);
        }
        TMDisplay *display = [[TMDisplay alloc] initWithDisplayID:ids[i]
                                                              kind:builtin ? TMDisplayKindBuiltin : TMDisplayKindExternal
                                                              name:TMDisplayName(ids[i], builtin)
                                                        identifier:TMDisplayIdentifier(ids[i], builtin)
                                                         avService:avService];
        [displays addObject:display];
    }
    // Les services non appariés (plus de ports détectés que d'écrans actifs) restent inutilisés :
    // libérés ici, faute de TMDisplay pour en prendre possession.
    for (NSUInteger i = avIndex; i < avHandles.count; i++) {
        io_service_t rawService = (io_service_t)(uintptr_t)[avHandles[i] pointerValue];
        IOObjectRelease(rawService);
    }
    @synchronized (self) { _displays = displays; }
}

- (NSArray<NSDictionary *> *)snapshot {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:self.displays.count];
    for (TMDisplay *display in self.displays) {
        [result addObject:@{
            @"id": display.identifier,
            @"name": display.name,
            @"kind": display.kind == TMDisplayKindBuiltin ? @"builtin" : @"external",
            @"available": @(display.available),
            @"brightness": display.brightnessPercent ?: [NSNull null],
        }];
    }
    // Le rétroéclairage du clavier suit les écrans, sous la même forme : les deux surfaces web lui
    // dessinent un curseur sans code dédié. Omis quand le Mac n'en a pas (Mac de bureau).
    NSNumber *keyboardBrightness = self.keyboard.brightnessPercent;
    if (self.keyboard.available && keyboardBrightness) {
        [result addObject:@{
            @"id": TMKeyboardBacklightIdentifier,
            @"name": @"Clavier",
            @"kind": @"keyboard",
            @"available": @YES,
            @"brightness": keyboardBrightness,
        }];
    }
    return result;
}

- (BOOL)setBrightnessPercent:(double)percent forIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:TMKeyboardBacklightIdentifier]) return [self.keyboard setBrightnessPercent:percent];
    TMDisplay *display = [self displayWithIdentifier:identifier];
    return display ? [display setBrightnessPercent:percent] : NO;
}

- (nullable TMDisplay *)displayWithIdentifier:(NSString *)identifier {
    for (TMDisplay *display in self.displays) if ([display.identifier isEqualToString:identifier]) return display;
    return nil;
}

- (void)stepExternalDisplaysByPercent:(double)stepPercent increase:(BOOL)increase {
    for (TMDisplay *display in self.displays) {
        if (display.kind != TMDisplayKindExternal || !display.available || !display.brightnessPercent) continue;
        double next = TMSteppedBrightness(display.brightnessPercent.doubleValue, increase, stepPercent);
        [display setBrightnessPercent:next];
    }
}

// Position lue sur un CGEvent vierge plutôt que NSEvent.mouseLocation : appelable depuis le thread
// du tap clavier, et déjà dans le repère CoreGraphics (origine en haut à gauche) qu'attend
// CGGetDisplaysWithPoint — plus de retournement depuis le repère Cocoa.
- (nullable TMDisplay *)displayUnderMouse {
    CGEventRef probe = CGEventCreate(NULL);
    if (!probe) return nil;
    CGPoint point = CGEventGetLocation(probe);
    CFRelease(probe);
    CGDirectDisplayID ids[8];
    uint32_t count = 0;
    if (CGGetDisplaysWithPoint(point, 8, ids, &count) != kCGErrorSuccess || count == 0) return nil;
    for (TMDisplay *display in self.displays) if (display.displayID == ids[0]) return display;
    return nil;
}

- (nullable TMDisplay *)builtinDisplay {
    for (TMDisplay *display in self.displays) if (display.kind == TMDisplayKindBuiltin) return display;
    return nil;
}

- (void)syncBuiltinDisplaysFromHardware {
    for (TMDisplay *display in self.displays) {
        if (display.kind == TMDisplayKindBuiltin) [display syncFromHardware];
    }
}

@end
