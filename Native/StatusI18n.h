#import <Foundation/Foundation.h>

// Langues proposées dans Réglages. « auto » suit la langue du système (repli : français).
extern NSArray<NSString *> *TMSupportedLanguages(void);

// Code effectif (fr, en, it, es) : STATUS_LANGUAGE (tests) > préférence `language` > système.
extern NSString *TMLanguage(void);
extern NSString *TMLocaleIdentifier(void);

// Traduction d'une clé de Resources/i18n/<langue>.json, `{nom}` remplacé par params[@"nom"].
// Si params contient « n », la variante `clé.one` / `clé.other` est choisie quand elle existe.
// Clé inconnue : la clé elle-même, pour que l'oubli se voie.
extern NSString *TMT(NSString *key);
extern NSString *TMTP(NSString *key, NSDictionary *params);

// Texte français produit par un service ou une bibliothèque sans accès au dictionnaire (démon
// privilégié, pont Claude) : traduit s'il correspond à une clé `msg.*`, sinon rendu tel quel.
extern NSString *TMTranslateFR(NSString *text);

// Charge à nouveau la langue effective (après changement de préférence).
extern void TMI18nReload(void);

// Charge utile envoyée aux pages web : {lang, locale, dict, reverse}.
extern NSDictionary *TMI18nPayload(void);
