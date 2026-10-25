#import "StatusUpdater.h"
#import <Cocoa/Cocoa.h>
#import <Sparkle/Sparkle.h>

@implementation TMUpdater {
    SPUStandardUpdaterController *_controller;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    // Sans flux ni clé, démarrer ferait afficher une alerte d'erreur à chaque lancement.
    if ([info[@"SUFeedURL"] length] && [info[@"SUPublicEDKey"] length])
        _controller = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:YES updaterDelegate:nil userDriverDelegate:nil];
    return self;
}

- (BOOL)available { return _controller != nil; }
- (BOOL)canCheckForUpdates { return _controller.updater.canCheckForUpdates; }
- (BOOL)automatic { return _controller.updater.automaticallyChecksForUpdates && _controller.updater.automaticallyDownloadsUpdates; }

- (void)setAutomatic:(BOOL)automatic {
    _controller.updater.automaticallyChecksForUpdates = automatic;
    _controller.updater.automaticallyDownloadsUpdates = automatic;
}

- (void)checkForUpdates {
    // App « accessoire » : sans activation, la fenêtre de Sparkle s'ouvre derrière les autres.
    [NSApp activateIgnoringOtherApps:YES];
    [_controller checkForUpdates:nil];
}

@end
