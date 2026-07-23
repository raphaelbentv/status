#import "StatusDisplays.h"
#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>

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

NSData *TMDDCGetVCPRequest(uint8_t vcpCode) {
    uint8_t payload[] = { 0x51, 0x82, 0x01, vcpCode };
    NSData *body = [NSData dataWithBytes:payload length:sizeof(payload)];
    uint8_t checksum = TMDDCChecksum(body, 0x6E);
    NSMutableData *packet = [body mutableCopy];
    [packet appendBytes:&checksum length:1];
    return packet;
}

NSData *TMDDCSetVCPRequest(uint8_t vcpCode, uint16_t value) {
    uint8_t payload[] = { 0x51, 0x84, 0x03, vcpCode, (uint8_t)(value >> 8), (uint8_t)(value & 0xFF) };
    NSData *body = [NSData dataWithBytes:payload length:sizeof(payload)];
    uint8_t checksum = TMDDCChecksum(body, 0x6E);
    NSMutableData *packet = [body mutableCopy];
    [packet appendBytes:&checksum length:1];
    return packet;
}

// Trame de réponse « Get VCP Feature » (11 octets) :
//   [0] source (0x6E) [1] longueur|0x80 [2] opcode (0x02) [3] résultat [4] code VCP
//   [5] type VCP [6-7] maximum (MSB,LSB) [8-9] courant (MSB,LSB) [10] checksum
// La graine de checksum d'une réponse (0x50) diffère de celle d'une requête (0x6E) par
// convention DDC/CI — direction de transmission inversée. Repli sûr en cas de désaccord : NO,
// jamais une valeur inventée.
BOOL TMDDCParseVCPReply(NSData *reply, uint8_t expectedVCPCode, uint16_t *outCurrent, uint16_t *outMaximum) {
    if (reply.length < 11) return NO;
    const uint8_t *b = reply.bytes;
    NSData *bodyForChecksum = [reply subdataWithRange:NSMakeRange(0, reply.length - 1)];
    if (TMDDCChecksum(bodyForChecksum, 0x50) != b[10]) return NO;
    if (b[2] != 0x02) return NO;              // pas une réponse « Get VCP Feature »
    if (b[3] != 0x00) return NO;              // le moniteur signale une erreur (VCP non pris en charge…)
    if (b[4] != expectedVCPCode) return NO;    // trame décalée ou corrompue
    uint16_t maximum = (uint16_t)((b[6] << 8) | b[7]);
    uint16_t current = (uint16_t)((b[8] << 8) | b[9]);
    if (maximum == 0) return NO;
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
    return builtin ? @"Écran interne" : @"Écran externe";
}

static NSString *TMDisplayIdentifier(CGDirectDisplayID displayID, BOOL builtin) {
    if (builtin) return @"builtin";
    uint32_t vendor = CGDisplayVendorNumber(displayID);
    uint32_t model = CGDisplayModelNumber(displayID);
    uint32_t serial = CGDisplaySerialNumber(displayID);
    if (vendor || model || serial) return [NSString stringWithFormat:@"ext-%u-%u-%u", vendor, model, serial];
    return [NSString stringWithFormat:@"ext-id-%u", displayID];  // repli : stable pour la session, pas au rebranchement
}

// Un service par port de sortie vidéo externe candidat au DDC/CI (Apple Silicon). L'appelant
// possède les io_service_t retournés et doit les libérer.
static NSArray<NSValue *> *TMCopyExternalAVServiceHandles(void) {
    NSMutableArray<NSValue *> *services = [NSMutableArray array];
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) != KERN_SUCCESS)
        return services;
    io_object_t service;
    while ((service = IOIteratorNext(iterator))) {
        [services addObject:[NSValue valueWithPointer:(void *)(uintptr_t)service]];
    }
    IOObjectRelease(iterator);
    return services;
}

#pragma mark - TMDisplay

@implementation TMDisplay {
    CGDirectDisplayID _displayID;
    CFTypeRef _avService;    // +1, écrans externes uniquement ; libéré au dealloc
    uint16_t _ddcMaximum;    // maximum VCP relevé à la détection ; nécessaire pour reconvertir un %
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
        [self refreshFromHardware];
    }
    return self;
}

- (void)dealloc {
    if (_avService) CFRelease(_avService);
}

- (void)refreshFromHardware {
    TMLoadPrivateDisplaySymbols();
    if (_kind == TMDisplayKindBuiltin) {
        if (!TMDisplayServicesGet) { _available = NO; _brightnessPercent = nil; return; }
        float value = -1;
        if (TMDisplayServicesGet(_displayID, &value) != 0 || value < 0) { _available = NO; _brightnessPercent = nil; return; }
        _available = YES;
        _brightnessPercent = @(round(TMClampBrightnessPercent(value * 100.0)));
        return;
    }
    if (!_avService || !TMIOAVServiceReadI2C || !TMIOAVServiceWriteI2C) { _available = NO; _brightnessPercent = nil; return; }
    NSData *request = TMDDCGetVCPRequest(TMDDCBrightnessVCPCode);
    IOReturn writeResult = TMIOAVServiceWriteI2C(_avService, 0x37, 0, (void *)request.bytes, (uint32_t)request.length);
    if (writeResult != kIOReturnSuccess) { _available = NO; _brightnessPercent = nil; return; }
    // La norme DDC/CI impose un délai minimal de ~40 ms entre l'envoi d'une requête et la lecture
    // de sa réponse — le moniteur a besoin de ce temps pour la préparer. Lire immédiatement
    // échouerait sur beaucoup d'écrans. `rescan` est appelé sur le thread principal, donc ce
    // sommeil le bloque le temps de sonder chaque externe ; c'est assumé : les rescans sont rares
    // (lancement, branchement/débranchement, réveil), pas une boucle continue, et seul le premier
    // écran externe non-DDC coûte ce délai. L'écran interne, lui, n'attend jamais.
    usleep(40000);
    uint8_t replyBuffer[11] = {0};
    IOReturn readResult = TMIOAVServiceReadI2C(_avService, 0x37, 0, replyBuffer, sizeof(replyBuffer));
    NSData *reply = [NSData dataWithBytes:replyBuffer length:sizeof(replyBuffer)];
    uint16_t current, maximum;
    if (readResult != kIOReturnSuccess || !TMDDCParseVCPReply(reply, TMDDCBrightnessVCPCode, &current, &maximum)) {
        _available = NO; _brightnessPercent = nil; return;
    }
    _ddcMaximum = maximum;
    _available = YES;
    _brightnessPercent = @(TMPercentFromVCPValue(current, maximum));
}

- (BOOL)setBrightnessPercent:(double)percent {
    double clamped = TMClampBrightnessPercent(percent);
    if (_kind == TMDisplayKindBuiltin) {
        if (!TMDisplayServicesSet) return NO;
        if (TMDisplayServicesSet(_displayID, (float)(clamped / 100.0)) != 0) return NO;
        _brightnessPercent = @(round(clamped));
        return YES;
    }
    if (!_avService || !TMIOAVServiceWriteI2C || _ddcMaximum == 0) return NO;
    NSData *request = TMDDCSetVCPRequest(TMDDCBrightnessVCPCode, TMVCPValueFromPercent(clamped, _ddcMaximum));
    IOReturn result = TMIOAVServiceWriteI2C(_avService, 0x37, 0, (void *)request.bytes, (uint32_t)request.length);
    if (result != kIOReturnSuccess) return NO;
    _brightnessPercent = @(round(clamped));  // optimiste : pas de relecture DDC à chaque écriture (coût I2C)
    return YES;
}

@end

#pragma mark - TMDisplayManager

@implementation TMDisplayManager

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
    _displays = displays;
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
    return result;
}

- (nullable TMDisplay *)displayWithIdentifier:(NSString *)identifier {
    for (TMDisplay *display in self.displays) if ([display.identifier isEqualToString:identifier]) return display;
    return nil;
}

- (void)stepAllByPercent:(double)stepPercent increase:(BOOL)increase {
    for (TMDisplay *display in self.displays) {
        if (!display.available || !display.brightnessPercent) continue;
        double next = TMSteppedBrightness(display.brightnessPercent.doubleValue, increase, stepPercent);
        [display setBrightnessPercent:next];
    }
}

@end
