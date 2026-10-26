// StatusMachine — identité de la machine, pour les règles qui dépendent du matériel.
//
// Aujourd'hui une seule : un MacBook Air Apple Silicon n'a pas de ventilateur (refroidissement passif).
// Ouvert ou fermé, c'est macOS qui bride le processeur ; il n'y a ni ventilateur à étouffer ni mode de
// refroidissement à part. Le mode « capot fermé » peut donc y rester actif sans limite de durée et sans
// s'arrêter à la première contrainte thermique, ce que les MacBook Pro, eux, ne doivent pas faire.
#import <Foundation/Foundation.h>

// Identifiant de modèle (« Mac16,6 »), lu par sysctl ; nil s'il est illisible.
NSString *TMMachineModel(void);

// Vrai pour un MacBook Air Apple Silicon. Liste fermée d'identifiants : un modèle inconnu — y compris un
// Air plus récent que cette liste — est traité comme un Mac à ventilateurs. L'erreur reste du côté sûr
// (le mode constant n'est pas proposé), et l'interface affiche l'identifiant pour qu'on puisse l'ajouter.
// Les MacBook Air Intel ne sont pas dans la liste : ils ont un ventilateur.
BOOL TMMachineIsFanlessMacBook(NSString *model);

// Les identifiants reconnus, dans l'ordre des générations (pour les tests et la documentation).
NSArray<NSString *> *TMFanlessMacBookModels(void);
