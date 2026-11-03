// Démarrage automatique du capot fermé : lecture des transcriptions Claude Code et décisions du pilote.
// Entièrement simulé : aucun pmset, aucun service, aucune transcription réelle.
#import <Foundation/Foundation.h>
#import "StatusLidAuto.h"
static int checks=0,failures=0;
static void Check(BOOL ok, NSString *label) { checks++; if(!ok){failures++; NSLog(@"FAIL: %@",label);} }
static NSData *Lines(NSArray *entries) {
    NSMutableData *data=[NSMutableData data];
    for (id entry in entries) {
        [data appendData:[entry isKindOfClass:NSString.class] ? [entry dataUsingEncoding:NSUTF8StringEncoding]
                                                               : [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil]];
        [data appendBytes:"\n" length:1];
    }
    return data;
}
static NSDictionary *Assistant(id stop) { return @{@"type":@"assistant",@"timestamp":@"2026-11-03T13:05:50.760Z",@"message":@{@"role":@"assistant",@"stop_reason":stop ?: NSNull.null,@"content":@[@{@"type":@"text",@"text":@"ok"}]}}; }
static NSDictionary *User(id content) { return @{@"type":@"user",@"timestamp":@"2026-11-03T13:05:44.739Z",@"message":@{@"role":@"user",@"content":content}}; }
static TMClaudeTurn Turn(NSArray *entries) { return TMClaudeTranscriptTurn(Lines(entries),NULL); }
// Service autorisé, batterie et température correctes, prolongation disponible ; `extra` remplace des clés.
static NSDictionary *Lid(NSDictionary *extra) {
    NSMutableDictionary *lid=[@{@"authorized":@YES,@"controlVersion":@4,@"active":@NO,@"busy":@NO,@"batteryPercent":@80,
        @"thermalState":@0,@"extendSupported":@YES,@"remainingSeconds":@0,@"message":@"Désactivé."} mutableCopy];
    [lid addEntriesFromDictionary:extra ?: @{}];
    return lid;
}
static NSDictionary *Running(double remaining) { return Lid(@{@"active":@YES,@"remainingSeconds":@(remaining),@"message":@"Actif · faible consommation imposée."}); }
static TMLidAutoPilot *Pilot(void) { TMLidAutoPilot *p=[TMLidAutoPilot new]; p.enabled=YES; return p; }
static TMLidAutoCommand Decide(TMLidAutoPilot *p, NSDictionary *lid, BOOL working, double now, NSInteger *minutes) {
    NSInteger ignored; return [p decideWithService:lid working:working now:now minutes:minutes ?: &ignored];
}
static NSString *State(TMLidAutoPilot *p, double now) { return [p snapshot:now][@"state"]; }
// Démarre une session automatique à `now` et la confirme.
static void StartOwned(TMLidAutoPilot *p, double now) { Decide(p,Lid(nil),YES,now,NULL); Decide(p,Running(1800),YES,now+5,NULL); }

int main(void){@autoreleasepool{
    // ── Transcriptions ──
    Check(Turn(@[User(@"Corrige le test"),Assistant(@"end_turn")])==TMClaudeTurnIdle,@"réponse terminée : au repos");
    Check(Turn(@[User(@"Corrige le test")])==TMClaudeTurnWorking,@"invite envoyée : au travail");
    Check(Turn(@[Assistant(@"tool_use")])==TMClaudeTurnWorking,@"outil en attente : au travail");
    Check(Turn(@[Assistant(nil)])==TMClaudeTurnWorking,@"réponse sans raison d'arrêt : encore en cours");
    Check(Turn(@[Assistant(@"tool_use"),User(@[@{@"type":@"tool_result",@"content":@"ok"}])])==TMClaudeTurnWorking,@"résultat d'outil : le modèle reprend");
    Check(Turn(@[Assistant(@"tool_use"),User(@[@{@"type":@"text",@"text":@"[Request interrupted by user for tool use]"}])])==TMClaudeTurnIdle,@"interruption : au repos");
    Check(Turn(@[Assistant(@"end_turn"),User(@"<command-name>/model</command-name>")])==TMClaudeTurnIdle,@"commande locale : au repos");
    NSArray *metadata=@[@{@"type":@"system",@"subtype":@"stop_hook_summary"},@{@"type":@"last-prompt",@"leafUuid":@"x"},@{@"type":@"custom-title",@"customTitle":@"t"}];
    Check(Turn([@[Assistant(@"end_turn")] arrayByAddingObjectsFromArray:metadata])==TMClaudeTurnIdle,@"métadonnées ajoutées après la fin du tour ignorées");
    NSMutableDictionary *side=[Assistant(@"tool_use") mutableCopy]; side[@"isSidechain"]=@YES;
    Check(Turn(@[Assistant(@"end_turn"),side])==TMClaudeTurnIdle,@"sous-agent ignoré");
    NSMutableDictionary *meta=[User(@"caveat") mutableCopy]; meta[@"isMeta"]=@YES;
    Check(Turn(@[Assistant(@"end_turn"),meta])==TMClaudeTurnIdle,@"message méta ignoré");
    Check(Turn(@[@"{\"type\":\"user\",\"mess",Assistant(@"end_turn")])==TMClaudeTurnIdle&&Turn(@[@"tronqué\"}"])==TMClaudeTurnUnknown,@"ligne tronquée ignorée");
    double at=0; TMClaudeTranscriptTurn(Lines(@[Assistant(@"tool_use")]),&at);
    Check(fabs(at-1793711150.760)<0.01,@"heure de la dernière entrée lue");

    NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *project=[root stringByAppendingPathComponent:@"-Users-x-Dev-app"];
    [NSFileManager.defaultManager createDirectoryAtPath:[project stringByAppendingPathComponent:@"session/subagents"] withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *transcript=[project stringByAppendingPathComponent:@"a.jsonl"];
    [Lines(@[Assistant(@"end_turn")]) writeToFile:transcript atomically:YES];
    [Lines(@[Assistant(@"tool_use")]) writeToFile:[project stringByAppendingPathComponent:@"session/subagents/agent.jsonl"] atomically:YES];
    double now=1793711150.760+60;
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate:[NSDate dateWithTimeIntervalSince1970:now-30]} ofItemAtPath:transcript error:nil];
    Check(!TMClaudeCodeWorking(@[root],now),@"dossier : session au repos, sous-agents non lus");
    [Lines(@[User(@"go"),Assistant(@"tool_use")]) writeToFile:transcript atomically:YES];
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate:[NSDate dateWithTimeIntervalSince1970:now-30]} ofItemAtPath:transcript error:nil];
    Check(TMClaudeCodeWorking(@[root,@"/nonexistent"],now),@"dossier : session en plein tour détectée");
    Check(!TMClaudeCodeWorking(@[root],now+46*60),@"tour abandonné depuis 45 min : plus compté");
    [@"pas du json" writeToFile:transcript atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate:[NSDate dateWithTimeIntervalSince1970:now-30]} ofItemAtPath:transcript error:nil];
    Check(TMClaudeCodeWorking(@[root],now)&&!TMClaudeCodeWorking(@[root],now+180),@"format inconnu : seule une écriture récente compte");
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];


    // ── Pilote ──
    NSInteger minutes=0; TMLidAutoPilot *p=[TMLidAutoPilot new];
    Check(Decide(p,Lid(nil),YES,1000,NULL)==TMLidAutoNone&&[State(p,1000) isEqual:@"off"],@"désactivé par défaut : rien");
    p=Pilot();
    Check(Decide(p,Lid(nil),NO,1000,NULL)==TMLidAutoNone&&[State(p,1000) isEqual:@"idle"],@"sans travail : rien");
    Check(Decide(p,Lid(nil),YES,1000,&minutes)==TMLidAutoStart&&minutes==30,@"travail détecté : session de 30 min");
    Check(Decide(p,Lid(@{@"busy":@YES}),YES,1001,NULL)==TMLidAutoNone,@"réponse attendue : aucune commande");
    Check(Decide(p,Running(1800),YES,1005,NULL)==TMLidAutoNone&&p.owns&&[State(p,1005) isEqual:@"running"],@"session confirmée : à nous");
    Check(Decide(p,Running(700),YES,2100,NULL)==TMLidAutoNone,@"plus de 10 min restantes : pas de prolongation");
    Check(Decide(p,Running(500),YES,2300,&minutes)==TMLidAutoExtend&&minutes==30,@"moins de 10 min : prolongée de 30 min");
    Check(Decide(p,Running(495),YES,2305,NULL)==TMLidAutoNone,@"prolongation non répétée dans la minute");
    Check(Decide(p,Running(1700),NO,2400,NULL)==TMLidAutoNone&&[State(p,2400) isEqual:@"stopping"]&&[[p snapshot:2400][@"stopInSeconds"] isEqual:@205],@"fin du travail : délai de grâce");
    Check(Decide(p,Running(1500),YES,2600,NULL)==TMLidAutoNone&&[State(p,2600) isEqual:@"running"],@"reprise pendant le délai : continue");
    Check(Decide(p,Running(1400),NO,2700,NULL)==TMLidAutoNone,@"moins de 5 min sans travail : pas encore");
    Check(Decide(p,Running(1100),NO,2900,NULL)==TMLidAutoStop,@"5 min sans travail : arrêt");
    Decide(p,Lid(@{@"message":@"Arrêt demandé."}),NO,2905,NULL);
    Check(!p.owns&&[[p snapshot:2905][@"cooldownSeconds"] isEqual:@0]&&Decide(p,Lid(nil),YES,2910,NULL)==TMLidAutoStart,@"notre arrêt : aucun délai, redémarrage dès le retour du travail");

    p=Pilot();
    Check(Decide(p,Running(900),YES,1000,NULL)==TMLidAutoNone&&[State(p,1000) isEqual:@"manual"],@"session manuelle : laissée telle quelle");
    Check(Decide(p,Running(100),YES,1800,NULL)==TMLidAutoNone,@"session manuelle : jamais prolongée");
    Check(Decide(p,Running(50),NO,9000,NULL)==TMLidAutoNone&&!p.owns,@"session manuelle : jamais arrêtée, même sans travail");
    p.enabled=NO;
    Check(Decide(p,Running(40),NO,9010,NULL)==TMLidAutoNone,@"désactivation : la session manuelle continue");
    p=Pilot(); Decide(p,Running(900),YES,1000,NULL);
    Check(Decide(p,Lid(@{@"message":@"Durée terminée."}),YES,1900,&minutes)==TMLidAutoStart,@"session manuelle terminée à échéance : relais automatique");

    p=Pilot(); Decide(p,Running(900),YES,1000,NULL); p.enabled=NO; p.enabled=YES;
    Check(Decide(p,Lid(@{@"message":@"Batterie à 30 % ou moins."}),YES,1000,NULL)==TMLidAutoStart,@"réactivation : une fin de session vue avant n'est pas comptée");
    p=Pilot(); StartOwned(p,1000);
    p.enabled=NO;
    Check(Decide(p,Running(1500),YES,1300,NULL)==TMLidAutoStop,@"désactivation : notre session s'arrête");

    // Arrêt de sécurité : délai, puis cause disparue.
    p=Pilot(); StartOwned(p,1000);
    Check(Decide(p,Lid(@{@"message":@"Batterie à 30 % ou moins.",@"batteryPercent":@30}),YES,1500,NULL)==TMLidAutoNone&&[State(p,1500) isEqual:@"cooldown"],@"arrêt de sécurité : délai avant tout nouvel essai");
    Check(Decide(p,Lid(@{@"batteryPercent":@80}),YES,1500+599,NULL)==TMLidAutoNone,@"délai de 10 min respecté même si la cause a disparu");
    Check(Decide(p,Lid(@{@"batteryPercent":@33}),YES,1500+600,NULL)==TMLidAutoNone&&[State(p,2100) isEqual:@"waiting"],@"batterie sous 35 % : pas de relance");
    Check(Decide(p,Lid(@{@"batteryPercent":@80,@"thermalState":@1}),YES,2110,NULL)==TMLidAutoNone,@"pression thermique : pas de relance");
    Check(Decide(p,Lid(@{@"batteryPercent":@80,@"thermalState":@1,@"fanlessMac":@YES}),YES,2120,NULL)==TMLidAutoStart,@"MacBook Air : seule la contrainte critique bloque");
    p=Pilot();
    Check(Decide(p,Lid(@{@"batteryPercent":@-1}),YES,1000,NULL)==TMLidAutoNone,@"batterie illisible : pas de démarrage");

    // Trois échecs : pause jusqu'à la fin du travail, sans boucle.
    p=Pilot(); double t=1000;
    for (int i=0;i<3;i++) { StartOwned(p,t); Decide(p,Lid(@{@"message":@"Les réglages d’énergie ont changé ou ne sont plus lisibles."}),YES,t+60,NULL); t+=60+600; }
    Check(Decide(p,Lid(nil),YES,t,NULL)==TMLidAutoNone&&[State(p,t) isEqual:@"paused"],@"trois arrêts de sécurité : pause");
    Decide(p,Lid(nil),NO,t+10,NULL);
    Check(Decide(p,Lid(nil),NO,t+10+300,NULL)==TMLidAutoNone&&Decide(p,Lid(nil),YES,t+10+300+600,NULL)==TMLidAutoStart,@"pause levée après la fin du travail");

    p=Pilot(); Decide(p,Lid(nil),YES,1000,NULL);
    Check(Decide(p,Lid(@{@"message":@"Impossible de lire les réglages, ou veille déjà bloquée par un autre outil."}),YES,1005,NULL)==TMLidAutoNone&&[State(p,1005) isEqual:@"cooldown"],@"démarrage refusé : délai, pas de boucle");
    p=Pilot(); Decide(p,Lid(nil),YES,1000,NULL);
    Check(Decide(p,Lid(@{@"unconfirmed":@YES}),YES,1012,NULL)==TMLidAutoNone,@"réponse non confirmée : attente");
    Check(Decide(p,Running(1790),YES,1020,NULL)==TMLidAutoNone&&p.owns,@"session confirmée plus tard : toujours à nous");

    // Arrêt manuel : pas de relance avant la fin du travail en cours.
    p=Pilot(); StartOwned(p,1000);
    [p userStopped];
    Decide(p,Lid(@{@"message":@"Arrêt demandé."}),YES,1100,NULL);
    Check(Decide(p,Lid(nil),YES,1200,NULL)==TMLidAutoNone&&[State(p,1200) isEqual:@"paused"],@"arrêt à la main : pas de relance pendant le travail");
    Decide(p,Lid(nil),NO,1300,NULL); Decide(p,Lid(nil),NO,1500,NULL);
    Check(Decide(p,Lid(nil),YES,1510,NULL)==TMLidAutoStart,@"arrêt à la main : relance au travail suivant");

    // Plafond de 240 min par épisode de travail.
    double base=1000, cap=base+240*60, deadline=base+1800;
    p=Pilot(); StartOwned(p,base);
    for (t=base+60;t<cap;t+=60) { NSInteger m=0;
        if (Decide(p,Running(deadline-t),YES,t,&m)==TMLidAutoExtend) deadline=MIN(t+m*60,cap); }
    Check(deadline==cap,@"prolongations jusqu'au plafond de 240 min, pas au-delà");
    Check(Decide(p,Running(30),YES,cap-30,NULL)==TMLidAutoNone,@"au plafond : plus de prolongation");
    Decide(p,Lid(@{@"message":@"Durée terminée."}),YES,cap,NULL);
    Check(Decide(p,Lid(nil),YES,cap+5,NULL)==TMLidAutoNone&&[State(p,cap+5) isEqual:@"paused"],@"plafond atteint : pas de relance pendant le même travail");

    // Ancien service sans prolongation : une seule session bornée au plafond.
    p=Pilot();
    Check(Decide(p,Lid(@{@"extendSupported":@NO}),YES,1000,&minutes)==TMLidAutoStart&&minutes==240&&[[p snapshot:1000][@"legacy"] isEqual:@YES],@"ancien service : session unique de 240 min");
    Decide(p,Lid(@{@"active":@YES,@"remainingSeconds":@100,@"extendSupported":@NO}),YES,1005,NULL);
    Check(Decide(p,Lid(@{@"active":@YES,@"remainingSeconds":@100,@"extendSupported":@NO}),YES,1010,NULL)==TMLidAutoNone,@"ancien service : jamais de prolongation");

    p=Pilot();
    Check(Decide(p,Lid(@{@"authorized":@NO}),YES,1000,NULL)==TMLidAutoNone&&[State(p,1000) isEqual:@"unavailable"],@"service non autorisé : rien");
    Check(Decide(p,Lid(@{@"restorationPending":@YES}),YES,1000,NULL)==TMLidAutoNone,@"restauration en attente : rien");
    Check(Decide(p,Lid(@{@"controlVersion":@3}),YES,1000,NULL)==TMLidAutoNone,@"service inconnu : rien");

    printf("lid-auto: %d checks, %d failures\n",checks,failures);
    return failures?1:0;
}}
