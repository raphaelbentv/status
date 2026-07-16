# Status — pistes de design

## Cadre commun

Le nouveau nom produit est **Status**. La référence visuelle est l’écran actuel `tokenmeter-split.png` : fenêtre macOS sombre, navigation latérale, OpenAI en bleu, Claude en violet, deux compteurs côte à côte et un résumé global. Les propositions ci-dessous conservent la lisibilité native macOS et font évoluer l’information principale vers les **quotas réellement restants**, par fenêtre de temps : session 5 h, semaine, et autres limites éventuellement retournées par le fournisseur.

Données de démonstration communes pour comparer les pistes :

- OpenAI : 62 % disponibles sur 5 h, remise à zéro à 16:40 ; 78 % disponibles cette semaine, remise à zéro dimanche ; connecté.
- Claude : 34 % disponibles sur 5 h, remise à zéro à 15:20 ; 51 % disponibles cette semaine, remise à zéro lundi ; connecté.
- État global : prochaine remise à zéro dans 1 h 18 ; dernière synchronisation aujourd’hui à 14:02.

Dans chaque génération, joindre comme référence visuelle : `/Users/raphaelbentvelzen/Documents/Codex/2026-07-14/fa/work/tokenmeter-split.png`.

---

## Designs de l’application

### 1. Twin Pulse — la continuité, beaucoup plus vivante

**Hiérarchie.** Deux moitiés strictement symétriques, OpenAI à gauche et Claude à droite. Dans chaque moitié, le quota 5 h est le héros ; la semaine et les limites secondaires se lisent sur deux rails plus fins. Le prochain reset et l’état de connexion restent immédiatement visibles. Un bandeau inférieur compare la marge disponible entre fournisseurs.

**Système visuel.** Évolution directe de l’app actuelle : fond graphite natif, séparation centrale très fine, grands anneaux incomplets plus expressifs, bleu cobalt pour OpenAI et violet orchidée pour Claude. Typographie SF Pro, chiffres tabulaires, peu de surfaces, aucun empilement de cartes. Animations lentes des anneaux lors de la synchronisation.

**Interaction clé.** Survoler ou cliquer une fenêtre de quota remplace le mini-historique par une frise jusqu’à sa remise à zéro ; `⌘1` et `⌘2` focalisent un fournisseur, `⌘R` synchronise.

**Prompt ImageGen.**

> Create a realistic, production-quality redesign of the attached existing macOS app screenshot. Product name: “Status”. Target frame 1440 × 1024, native macOS desktop application, dark appearance, French UI, current date anchor 14 July 2026. Preserve the reference app’s elegant split-screen comparison and compact sidebar, but change the primary job from monthly token totals to real quota availability. Build two perfectly balanced vertical halves: OpenAI in cobalt blue on the left and Claude in orchid purple on the right. In each half, make “5 h” the hero quota with a large refined partial circular gauge and a very large remaining percentage; show “62 % disponibles · réinitialisation 16:40” for OpenAI and “34 % disponibles · réinitialisation 15:20” for Claude. Under each hero gauge, show a thin weekly quota rail and one subtle secondary-limit row, plus a restrained seven-day usage sparkline. Top header: “Status”, “Quotas en direct”, last sync “Aujourd’hui, 14:02”, and one subtle refresh control. Bottom comparison strip: “Prochaine remise à zéro dans 1 h 18” and a concise recommendation “OpenAI offre le plus de marge”. Use SF Pro, tabular numerals, graphite base surface, hairline dividers, generous spacing, no nested cards, no gradients except extremely subtle material tint, minimal shadows, authentic macOS sidebar and toolbar proportions. Make the screen focused, highly visual, calm, and immediately scannable. No browser chrome, no marketing content, no feature inventory, no fake logos, no clipped text.

### 2. Time Horizon — les limites comme une ligne du temps

**Hiérarchie.** Les fenêtres de quota structurent l’écran, et non les fournisseurs. Trois colonnes : `5 h`, `Semaine`, `Autres`. OpenAI et Claude sont deux lignes comparables à l’intérieur de chaque colonne. Une règle temporelle horizontale en haut montre les prochains resets, comme un calendrier de disponibilité.

**Système visuel.** Apparence claire ou sombre automatiquement, très proche de Calendrier et Temps d’écran : rails horizontaux, repères temporels, surfaces mates, petites touches de bleu et violet seulement dans les niveaux. Chiffres de disponibilité plus importants que le volume consommé. La densité est plus analytique mais reste calme.

**Interaction clé.** Faire glisser la règle temporelle simule l’évolution jusqu’au prochain reset ; cliquer sur `5 h`, `Semaine` ou `Autres` agrandit cette fenêtre et révèle l’historique sans changer de page.

**Prompt ImageGen.**

> Design a production-quality native macOS app named “Status”, grounded in the attached current app screenshot but with a meaningfully different information architecture. Target 1440 × 1024, French UI, dark mode, date anchor 14 July 2026. Organize the dashboard by time horizon instead of provider: a wide horizontal reset timeline across the top, then three aligned columns labeled “5 h”, “Semaine”, and “Autres”. Inside every column compare two clean provider rows, OpenAI blue and Claude purple, using long horizontal availability rails with percentages and precise reset labels. Use these values: OpenAI 62 % available for 5 h, reset 16:40; Claude 34 %, reset 15:20; OpenAI weekly 78 %, reset Sunday; Claude weekly 51 %, reset Monday. The reset timeline should visually place the next reset in 1 h 18 and later weekly reset points, similar in precision and restraint to macOS Calendar or Screen Time. Keep a slim translucent sidebar with “Vue d’ensemble”, “Historique”, “Connexions”, and connected status for both services. Emphasize remaining capacity, not spend. Use SF Pro, tabular numerals, graphite and warm-gray surfaces, hairline grid separators, tiny cobalt and orchid accents, no large circular gauges, no card grid, no excessive rounded containers, no heavy shadows. Include one clear primary action: “Synchroniser”. Make the layout analytical, spacious, and unmistakably macOS. No browser or device frame, no feature inventory, no fake branding, no clipped content.

### 3. Breathing Room — une réponse immédiate : « puis-je continuer ? »

**Hiérarchie.** L’écran commence par une seule réponse globale : `Marge confortable`, `À surveiller` ou `Limite proche`, calculée à partir du quota le plus contraignant. Un grand halo central indique le prochain reset et la durée restante. Les deux fournisseurs sont deux panneaux secondaires latéraux, puis les détails 5 h / semaine sont accessibles en dessous.

**Système visuel.** Plus atmosphérique, inspiré des apps Santé et Météo de macOS : grand espace négatif, halo abstrait discret qui mélange bleu et violet, typographie très ample, matériaux translucides limités aux panneaux fournisseur. La couleur exprime l’urgence ; le reste reste presque monochrome.

**Interaction clé.** Un sélecteur `Maintenant / Aujourd’hui / Cette semaine` fait évoluer le halo et recommande automatiquement le fournisseur offrant la meilleure marge. Cliquer la recommandation ouvre le détail correspondant.

**Prompt ImageGen.**

> Create a polished, production-ready native macOS dashboard for an app called “Status”, using the attached existing split-screen app only as product and color grounding, not as a layout to copy. Target 1440 × 1024, French language, dark appearance, current date 14 July 2026. The primary question is “Can I keep working without hitting an AI quota?”. Create a single spacious hero state reading “Marge à surveiller”, with a large subtle luminous time halo and “Prochaine remise à zéro dans 1 h 18” as the central focal point. The halo should be an elegant restrained blend of OpenAI cobalt and Claude orchid, with no decorative illustration. Directly below, show a segmented control “Maintenant · Aujourd’hui · Cette semaine”. Place two secondary provider panels side by side: OpenAI “62 % sur 5 h · 78 % semaine” and Claude “34 % sur 5 h · 51 % semaine”, each connected and showing the exact next reset. Add one concise recommendation: “Pour le prochain travail long, préférez OpenAI”. Sidebar is minimal and native macOS; toolbar has last sync at 14:02 and one refresh icon. Use SF Pro, oversized but disciplined typography, generous negative space, translucent materials only for the two provider panels, very soft depth, hairline separators, almost monochrome surfaces with color reserved for live quota and urgency. No card wall, no nested cards, no giant logos, no browser chrome, no feature list, no clipped text. Make it feel emotionally calm, premium, and as refined as Apple Weather or Health on macOS.

### 4. Quiet Ledger — la précision avant le spectacle

**Hiérarchie.** Une liste compacte et typographique remplace les jauges. Chaque ligne correspond à un fournisseur et chaque colonne à `5 h`, `Semaine`, `Reset`, `État`. Un grand nombre tout en haut affiche la marge minimale actuelle. L’historique apparaît sous forme de bandes de densité alignées avec les lignes.

**Système visuel.** Monochrome, proche d’Activity Monitor et des réglages système : aucune carte, très peu de rayons, grilles fines, chiffres tabulaires, couleur seulement sur la barre de marge et les alertes. Cette piste est la plus professionnelle et la plus compacte.

**Interaction clé.** Trier par marge, prochain reset ou fournisseur ; la ligne la plus contrainte remonte automatiquement. Un mode compact réduit la fenêtre en palette flottante sans perdre l’information essentielle.

**Prompt ImageGen.**

> Design a production-quality native macOS utility named “Status”, based on the attached existing app’s purpose and provider colors but radically simplified into a precise typographic ledger. Target 1440 × 1024, French UI, dark mode, date anchor 14 July 2026. At the top, one large metric: “34 % — marge minimale actuelle”, followed by “Claude · fenêtre 5 h · réinitialisation 15:20”. Below, create one elegant full-width table with exactly two main rows, OpenAI and Claude, and columns “5 h”, “Semaine”, “Prochain reset”, “État”. Show OpenAI 62 % / 78 % / 16:40 / Connecté and Claude 34 % / 51 % / 15:20 / Connecté. Use thin inline availability bars inside numeric cells and subtle aligned usage-density strips below each provider row. Add a small disclosure row for “Autres limites” rather than filling the screen with panels. Slim native sidebar: “Quotas”, “Historique”, “Connexions”. Toolbar: “Status”, last sync “14:02”, sort menu “Marge la plus faible”, refresh icon. Visual language inspired by Activity Monitor and System Settings: SF Pro, tabular numerals, charcoal base, precise hairline grid, nearly monochrome, cobalt and orchid used only for data, square-ish 6 px radii, no circular gauges, no card layout, no glassy decoration, no gradients, almost no shadow. Dense but breathable, highly legible, professional, authentic macOS. No browser chrome, no fake logos, no clipped content.

---

## Designs de la barre des menus

Toutes les propositions utilisent une icône template monochrome compatible avec les apparences claire et sombre de macOS. Les couleurs bleu/violet n’apparaissent que dans le popover, jamais comme une icône multicolore permanente dans la barre système.

### A. Dual Arc — deux fournisseurs dans un seul symbole

**Hiérarchie.** L’icône 18 × 18 superpose deux arcs : extérieur pour OpenAI, intérieur pour Claude. Le popover reprend deux anneaux compacts, la fenêtre 5 h en premier, puis la semaine et le prochain reset.

**Système visuel.** Symbole template très simple, épaisseur 1,5 pt, extrémités arrondies. Dans le popover : bleu/violet, fond material macOS, chiffres SF Pro Rounded.

**Interaction clé.** Un clic ouvre le popover ; `⌥` + clic bascule l’affichage de l’icône entre quota 5 h et quota hebdomadaire.

**Prompt ImageGen.**

> Create a production-quality macOS menu bar concept for the app “Status”. Target presentation 900 × 640. Show a realistic crop of the macOS menu bar at the top and its 320 px wide native popover directly below, no desktop clutter. The 18 × 18 template icon is a single elegant dual-arc meter: outer arc represents OpenAI, inner arc represents Claude, monochrome black/white depending on system appearance, 1.5 pt rounded strokes, readable at actual size, no letters and no logo imitation. In the popover, title “Status”, last sync “14:02”, then two compact circular availability meters: OpenAI blue “62 % · 5 h · reset 16:40” and Claude purple “34 % · 5 h · reset 15:20”. Under them, thin weekly rails “78 %” and “51 %”, followed by one footer action “Ouvrir Status”. Native macOS materials, SF Pro, precise alignment, subtle separators, no nested cards, no excessive shadows, no fake system icons, no clipped text. French UI, date anchor 14 July 2026.

### B. Plain Signal — la donnée directement dans la barre

**Hiérarchie.** Un petit pictogramme de jauge suivi de `34 %` affiche la marge la plus faible, donc l’information la plus sûre. Le popover explique immédiatement `Claude · 5 h`, puis compare OpenAI et Claude.

**Système visuel.** Le plus natif et lisible : icône template + chiffres tabulaires, sans capsule permanente. Le texte passe en état d’alerte uniquement via une variante de symbole, pas par couleur système forcée.

**Interaction clé.** Cliquer le pourcentage ouvre le détail de la limite responsable ; un menu secondaire permet de choisir `Plus faible`, `OpenAI`, `Claude` ou `Prochain reset` comme donnée affichée.

**Prompt ImageGen.**

> Design a production-ready macOS menu bar status item for “Status”, presented at 900 × 640 with a true-scale menu bar crop and an open 320 px popover. The persistent menu bar item is extremely native and legible: a tiny monochrome meter template glyph followed by tabular text “34 %”, with no pill background. It represents the lowest remaining quota across providers. The popover begins with a strong explanation “34 % disponibles”, then “Claude · fenêtre 5 h” and “Réinitialisation à 15:20”. Below, compare two clean rows: OpenAI blue 62 % and Claude purple 34 %, each with a thin availability rail; a smaller weekly section shows 78 % and 51 %. Add a compact display preference menu labeled “Afficher : marge la plus faible” and footer actions “Synchroniser” and “Ouvrir Status”. Use authentic macOS menu typography, vibrancy material, hairline row separators, SF Pro tabular numerals, no decorative card stack, no gradients, no large logos, no clipped labels. French UI, current date anchor 14 July 2026.

### C. Reset Clock — le temps avant la respiration suivante

**Hiérarchie.** La barre affiche un petit cadran + `1 h 18`, soit le temps avant la prochaine remise à zéro, indépendamment du fournisseur. Le popover montre une mini-frise chronologique des resets, puis les pourcentages restants.

**Système visuel.** Cadran/compte à rebours monochrome inspiré de Timer ; frise légère dans le popover, bleu et violet uniquement sur les événements. Très différent d’un compteur de consommation classique.

**Interaction clé.** Cliquer un événement de reset crée une notification facultative 10 minutes avant ; un switch discret active ou désactive ce rappel.

**Prompt ImageGen.**

> Create an elegant, production-quality macOS menu bar direction for “Status”, target presentation 900 × 640. Show the actual-size menu bar item and an open 340 px popover. The menu bar item is a minimal monochrome reset-clock template icon followed by “1 h 18”, communicating time until the next quota reset rather than usage; no pill background, no provider letters. The popover’s hero reads “Prochaine remise à zéro” and “Claude · aujourd’hui à 15:20”. Beneath it, show a refined horizontal reset timeline with three chronological events: Claude 15:20 in orchid purple, OpenAI 16:40 in cobalt blue, and weekly resets later; then two concise rows showing remaining 5 h quota, OpenAI 62 % and Claude 34 %. Include a native checkbox or switch “Me prévenir 10 min avant” and footer action “Voir tous les quotas”. Use authentic macOS menu materials, SF Pro and tabular numerals, subtle separators, excellent compact spacing, color only in timeline events, no circular dashboard gauges, no card grid, no gradients, no fake logos, no clipped text. French UI, date anchor 14 July 2026.

### D. Split Bars — la lecture instantanée sans chiffres

**Hiérarchie.** L’icône se compose de deux micro-barres verticales : OpenAI à gauche, Claude à droite. Leur hauteur représente la marge restante ; un petit point apparaît sous la barre la plus contrainte. Le popover développe la même grammaire en deux colonnes.

**Système visuel.** Icône template géométrique de 16 × 16, identifiable même sans texte. Popover plus graphique, avec deux colonnes très simples et de grands pourcentages.

**Interaction clé.** Le survol système/tooltip révèle `OpenAI 62 % · Claude 34 %`; cliquer une colonne dans le popover ouvre directement son détail dans l’app.

**Prompt ImageGen.**

> Design a distinctive but authentic macOS menu bar concept for the utility “Status”, presented at 900 × 640 with a realistic menu bar crop and open 320 px popover. The persistent 16 × 16 monochrome template icon contains exactly two narrow rounded vertical bars: left bar at roughly 62 % height for OpenAI, right bar at roughly 34 % height for Claude, plus one tiny constraint dot under the shorter right bar. It must remain crisp and understandable at true menu-bar size, with no letters, numbers, color, or logo imitation. The popover expands the same visual grammar into two clean vertical columns: OpenAI in cobalt blue with a large “62 %”, Claude in orchid purple with “34 %”; label both “5 h” with reset times 16:40 and 15:20. Below, show two thin weekly bars, 78 % and 51 %, and a centered footer “Mis à jour à 14:02 · Ouvrir Status”. Native macOS vibrancy, SF Pro, ample compact spacing, thin divider between columns, no card stack, no multiple badges, no shadows beyond the system popover, no clipped text. French UI, current date 14 July 2026.

---

## Recommandation de combinaison

Pour une première version à la fois spectaculaire et immédiatement exploitable : **Twin Pulse** pour la fenêtre principale et **Plain Signal** pour la barre des menus. Cette paire conserve la comparaison côte à côte demandée, rend les quotas 5 h/semaine évidents, et garde la barre système très lisible même sur un écran chargé.
