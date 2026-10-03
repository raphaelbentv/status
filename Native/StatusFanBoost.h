#import <Foundation/Foundation.h>
// Version du protocole ventilateurs exposée dans le snapshot (« fanBoost.version »).
#define TMFanBoostVersion 2
@protocol TMFanBackend
- (NSArray<NSDictionary *> *)fans;
// Prend la main sur thermalmonitord quand le Mac l'exige (Ftst sur M3/M4 Pro/Max). YES sinon.
- (BOOL)unlock;
- (BOOL)setManual:(NSInteger)index rpm:(double)rpm;
- (BOOL)setAutomatic:(NSInteger)index;
// Rend la main à thermalmonitord (Ftst=0). YES si la clé n'existe pas.
- (BOOL)relock;
- (BOOL)savePending:(NSArray *)indices;
- (NSArray *)loadPending;
- (BOOL)clearPending;
@end
@interface TMFanBoost : NSObject
@property (readonly) BOOL active, verified, restorationPending;
@property (readonly) double deadline;
@property (readonly) NSInteger percent;
@property (readonly, copy) NSString *message;
- (instancetype)initWithBackend:(id<TMFanBackend>)backend;
- (void)recover;
- (void)startMinutes:(NSInteger)minutes percent:(NSInteger)percent now:(double)now;
- (void)heartbeat:(double)now;
- (void)tick:(double)now thermal:(NSProcessInfoThermalState)thermal;
- (void)stop:(NSString *)reason;
// Demande explicite « Auto Apple » : remet aussi en automatique un ventilateur resté en manuel
// (boost interrompu, autre outil quitté sans restaurer).
- (void)restoreAll:(NSString *)reason;
- (NSDictionary *)snapshot:(double)now;
@end
@interface TMFanSMCBackend : NSObject <TMFanBackend>
@end
