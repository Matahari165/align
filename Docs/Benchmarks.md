# Benchmarks Align

Ce fichier conserve uniquement des mesures agrégées. Aucune image, vidéo ou coordonnée faciale n’est enregistrée.

## Protocole always-on — 5 septembre 2026

La politique actuelle vise une capture à 20 images/s, avec analyse visage à
10 Hz, mains à 2 Hz et RTMPose à 1 Hz après un mouvement puis 0,2 Hz au repos. La calibration conserve
RTMPose à 2 Hz pour rassembler sa référence sans ralentissement. Les analyses
ne sont pas réduites par ce changement de capture : vingt images/s
permettent un rythme régulier de deux images par échéance faciale et
conservent la qualité temporelle des signaux. La segmentation reste réservée
au benchmark.

L'affichage des overlays et indicateurs est plafonné à 4 Hz sans réduire les
cadences d'analyse ni d'alerte. L'aperçu vidéo est déconnecté lorsque la fenêtre
n'est pas réellement visible. RTMPose reste sur le chemin CPU vérifié : le test
Core ML/Neural Engine est désactivé, car le fournisseur actuel provoque une
exception système avant qu'un repli automatique soit possible. Il est déchargé après
120 secondes sans visage. L'historique reste agrégé en mémoire, puis est
publié et sauvegardé au maximum une fois par heure et systématiquement lors de
la fermeture normale de l'application.

Le réglage « Analyse du corps » permet de remplacer RTMPose-M par BlazePose
Lite pendant l'exécution. Le moteur précédent est détruit avant l'activation du
suivant : les deux modèles ne restent jamais chargés ensemble. Le mode Léger
réduit le coût attendu du corps, au prix d'épaules potentiellement moins stables.
Le suivi Vision du visage et des clignements ne change pas.

Mesure reproductible, à effectuer sur la même machine et en Release :

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project Align.xcodeproj -scheme Align -configuration Release \
-derivedDataPath /private/tmp/align-release-derived CODE_SIGNING_ALLOWED=NO build

Tools/align-process-metrics.sh <PID> 300 2 > /private/tmp/align-process.csv
```

Le script ne lance ni n’arrête Align : il échantillonne uniquement le PID
fourni. Il donne le CPU `ps` (pourcentage d’un CPU logique) et le RSS en MiB,
puis la moyenne, le maximum et la dérive observés. Pour une comparaison A/B,
mesurer séparément : caméra arrêtée, fenêtre visible, fenêtre masquée et
calibration, après 30 secondes d’échauffement. Compléter ces mesures par
`Diagnostics` : callbacks, tentatives visage, résultats valides, inférences
RTMPose et âges des résultats.

**FAIT — historique, non comparable directement au code actuel :** une mesure
courte à 15 images/s et visage à 2 Hz en arrière-plan donnait 11,94 % CPU et
59,6 Mio RSS. Le code courant garde ensuite le visage à 10 Hz pour ne pas
perdre les clignements ; il faut donc refaire la mesure avec le protocole
ci-dessus. Aucune mesure actuelle de batterie, Energy Impact ou caméra réelle
n’est disponible dans ce dépôt.

Le benchmark conserve aussi, uniquement en mémoire, les angles `roll`, `yaw`
et `pitch` issus de l’observation faciale primaire déjà produite par
`VNDetectFaceLandmarksRequest`. Le rapport copiable donne par phase le nombre
d’échantillons présents, la moyenne, les bornes et l’écart-type en degrés.
Ces valeurs décrivent une observation d’orientation et ne constituent pas un
verdict de posture. Sur le SDK utilisé, `VNFaceObservation.pitch` peut rester
`nil` : `VNDetectFaceLandmarksRequest` ne garantit pas le calcul du pitch,
contrairement à une requête de rectangles faciaux adaptée ; Align expose donc
`nil` sans lancer de requête Vision supplémentaire.

## 29 août 2026 — Reconnaissance Vision et ressources

### Machine et version

- MacBook Air M2, 8 Go de RAM.
- Version testée : commit `12ccb83` (`Add local vision benchmark and adaptive cadence`).
- Une seule instance d’Align active.
- Caméra intégrée, capture 720p à 15 images/s.
- Visage analysé jusqu’à 5 fois/s ; corps environ 1 fois/s, avec accélération temporaire possible à 2 fois/s.

### Séquence guidée actuelle — 60 secondes

La séquence actuelle comporte 11 phases : position neutre (10 s), tête à
gauche (5 s), tête à droite (5 s), regard vers le haut (5 s), regard vers le
bas (5 s), visage rapproché (5 s), visage éloigné (5 s), écran légèrement
incliné vers soi sans bouger la tête (5 s), écran légèrement éloigné sans
bouger la tête (5 s), visage masqué (5 s), puis retour neutre (5 s).

### Mesure historique — benchmark guidé de 50 secondes

- Visage : 230 tentatives, 214 succès, soit 93,0 % globalement.
- Landmarks : présents lors des 214 détections réussies.
- Durée visage : moyenne 22,1 ms ; maximum 94,7 ms.
- Corps complet (cou et deux épaules) : 0 succès sur 46 tentatives dans ce cadrage rapproché.
- Durée corps : moyenne 16,2 ms ; maximum 30,9 ms.
- Overlay : 1 perte ; interruption maximale 1,08 s ; récupération moyenne 1,08 s.

Résultats par étape :

- Position neutre : 100 %.
- Tête à gauche : 100 %.
- Tête à droite : 100 %.
- Regard vers le haut : 100 %.
- Regard vers le bas : 100 %.
- Visage rapproché : 100 %.
- Visage éloigné : 100 %.
- Visage masqué : absence correctement observée 47,8 % du temps ; le visage ou une partie reconnaissable est resté détecté 52,2 % du temps.
- Retour neutre : overlay visible 78,3 % du temps ; récupération mesurée à 1,08 s.

Interprétation : les sept situations où le visage devait rester visible ont toutes obtenu 100 %. Le taux global de 93 % inclut volontairement la phase où le visage était masqué ; les résultats par étape sont donc la référence pour comparer les prochaines versions.

### CPU et mémoire

Mesure de référence avant séparation des cadences :

- CPU moyen : 19,84 % ; plage observée 15,7–23,8 %.
- Mémoire : environ 45–46 Mio.

Mesure version `12ccb83`, fenêtre visible avant benchmark, 10 échantillons espacés de 2 s :

- CPU moyen : 21,98 % ; plage 18,4–26,2 %.
- Mémoire : environ 56–63 Mio.

Fenêtre de mesure de 60 s autour du benchmark, 30 échantillons espacés de 2 s :

- CPU moyen : 19,89 % ; plage 12,5–29,1 %.
- Mémoire moyenne : 55,4 Mio ; plage 50,1–64,2 Mio.
- Cette fenêtre a commencé avant le clic de démarrage et s’est terminée pendant l’étape 8 : elle représente l’utilisation autour du benchmark, pas exactement ses 50 secondes seules.

Fenêtre réduite, suivi toujours actif, 10 échantillons espacés de 2 s :

- CPU moyen : 18,64 % ; plage 13,9–25,7 %.
- Mémoire : environ 63–67 Mio.

### Objectifs pour la suite

- CPU moyen en arrière-plan : 15 % ou moins.
- CPU en pause : moins de 1 % et caméra arrêtée.
- Mémoire : moins de 100 Mio et dérive inférieure à 10 Mio sur 30 minutes.
- Visage détecté : au moins 95 % lorsque le visage doit être visible.
- Récupération après occultation : 1 seconde ou moins.
- Aucun ancien overlay visible plus de 0,25 seconde.

Ancienne piste non adoptée : réduire le visage à 5 fois/s au premier plan et
2 fois/s en arrière-plan. Les essais de clignement ont montré que cette perte
temporelle pouvait manquer un événement court ; le protocole courant conserve
donc 10 Hz et réduit d’abord la cadence de capture inutilisée.

## 29 août 2026 — Cadence réduite en arrière-plan

Version testée : branche `feature/background-performance`, après ajout d’une cadence faciale automatique de 2 analyses/s lorsque Align n’est pas au premier plan. La capture reste à 720p/15 images/s et le corps reste analysé environ 1 fois/s.

Mesure réelle en arrière-plan, une seule instance, 10 échantillons espacés de 2 s :

- CPU moyen : 11,94 % ; plage 8,8–17,5 %.
- Mémoire moyenne : 59,6 Mio ; plage 55,8–63,5 Mio.
- Comparaison avec la mesure précédente fenêtre réduite : 18,64 % → 11,94 %, soit une baisse d’environ 35,9 %.
- Objectif CPU arrière-plan inférieur ou égal à 15 % : atteint sur cette mesure courte de 20 secondes.

Limites : cette mesure courte ne remplace pas encore le contrôle de 10 minutes ni le test de dérive mémoire sur 30 minutes. La consommation en pause complète reste à mesurer après arrêt manuel de la caméra.

## 29 août 2026 — Orientation faciale native Vision

Séquence guidée de 60 secondes, 11 phases. Les angles proviennent de la même `VNFaceObservation` que les landmarks ; aucune requête Vision supplémentaire.

- Visage : 265 succès sur 281 tentatives, soit 94,3 % globalement.
- Toutes les neuf phases où le visage devait rester visible : conformité 100 %.
- Durée visage : moyenne 27,2 ms ; maximum 85,0 ms.
- Corps complet : 0 succès sur 57 tentatives dans le cadrage utilisé.
- Récupération après masquage : 1,87 s.

Résultats d’orientation :

- `pitch` : jamais fourni, sur aucune phase.
- `yaw` : réagit à gauche/droite, mais de façon grossière et instable. Gauche : moyenne +37,2°, plage 0–90°. Droite : moyenne -15,0°, plage -45–90°.
- `roll` : généralement bloqué à 0°. Une valeur aberrante de -180° est apparue pendant la récupération après masquage.
- Inclinaison de l’écran vers soi puis loin de soi : `roll` et `yaw` sont restés à 0°, `pitch` absent.

Décision : ne pas utiliser directement ces propriétés natives pour produire un verdict de posture. Elles restent utiles comme diagnostic de développement. La prochaine expérimentation doit dériver des mesures géométriques depuis les landmarks visage déjà fiables et vérifier séparément leur sensibilité aux mouvements de tête et de l’écran.

## Instrumentation géométrique dérivée des landmarks

Cette expérimentation ajoute FaceGeometrySignal, calculé uniquement à partir
des polylines faciales déjà extraites par la même requête
VNDetectFaceLandmarksRequest. Elle ne lance aucune requête Vision
supplémentaire et ne produit aucun verdict de posture.

Les métriques transportées sont des scalaires optionnels et finis :

- eyeLineRollDegrees est l’angle de l’axe joignant les centres médians des
  deux yeux. Comme cet axe n’a pas de sens d’orientation, il est ramené dans
  [-90°, 90°). Le repère de capture actuel a y vers le bas.
- yawProxy est le déplacement horizontal médian du nez par rapport au milieu
  des yeux, divisé par la distance interoculaire. Un déplacement vers la droite
  est positif.
- pitchProxy est le déplacement vertical médian du nez par rapport au milieu
  des yeux, divisé par une longueur faciale. Un déplacement vers le bas est
  positif dans le repère actuel.
- interocularDistance et faceLength sont conservées pour contrôler les
  changements de distance à l’écran et la qualité de la normalisation ; elles
  ne sont pas des verdicts.

La longueur faciale privilégie la longueur du chemin medianLine, plus proche
de l’axe central du visage. Si cette région manque, le fallback faceContour
utilise une étendue verticale robuste (quantiles 10–90 % pour les contours
denses), plutôt qu’une longueur d’arc dépendante du nombre de points et de la
forme de la mâchoire. Une distance inférieure au seuil minimal est ignorée.

Le benchmark ne persiste aucune image, coordonnée ou polyligne. Les agrégats
restent en mémoire et exposent, par phase, n, moyenne, minimum, maximum et
écart-type. Le rapport compare explicitement tête gauche/droite, tête
haut/bas, écran vers/loin et visage près/loin, avec les échelles
interoculaire et faciale pour distinguer mouvement de tête et simple
rapprochement de l’écran.

## 29 août 2026 — Segmentation de personne pour la silhouette cou-épaules

Prototype local fondé sur `VNGeneratePersonSegmentationRequest`, qualité
rapide, masque monochrome et cadence maximale d'environ une tentative par
seconde. Le masque est réduit immédiatement à un contour compact puis libéré ;
aucune image ni aucun masque n'est enregistré.

Première mesure réelle sur MacBook Air M2 8 Go, fenêtre visible et caméra
active :

- 19 échéances, 18 requêtes Vision réellement exécutées et 18 contours valides ;
- durée p95 affichée pour la segmentation : 2 287 ms ;
- CPU après échauffement, neuf échantillons utiles sur environ 10 secondes :
  moyenne 20,4 %, plage 14,3–22,5 % ;
- mémoire résidente : 204–205 Mio ;
- référence antérieure en arrière-plan sans segmentation : environ 11,94 % CPU
  et 59,6 Mio.

Les objectifs provisoires n'ont pas été atteints : p95 inférieur ou égal à
500 ms et mémoire inférieure à 100 Mio. Une fraîcheur visuelle de 0,30 s est
également incompatible avec une requête qui prend parfois plus de deux
secondes : le contour peut être correct mais trop intermittent.

Décision : ne pas exécuter cette segmentation en continu. La conserver
uniquement comme diagnostic déclenché explicitement pendant un benchmark, afin
d'évaluer la qualité visuelle sans imposer ce coût au suivi quotidien. Pour le
signal permanent cou-épaules, comparer ensuite une approche plus légère avant
toute activation en arrière-plan.

## 29 août 2026 — Validation réelle du cou et des épaules

La détection corporelle légère utilise toujours
`VNDetectHumanBodyPoseRequest`, sans requête supplémentaire. Le diagnostic
sépare désormais le cou, l'épaule gauche et l'épaule droite, avec un seuil de
confiance de 0,35 et un mapping explicite vers les noms d'articulations Apple.

Deux cadrages réels ont été comparés :

- cadrage habituel devant le Mac, puis cadrage légèrement plus large : visage
  détecté avec 47 points, mais aucune observation corporelle (`corps 0`,
  `0/3`) ;
- cadrage large montrant la tête, le torse et idéalement les hanches : une
  observation corporelle (`corps 1`) et les trois repères reconnus (`3/3`).

Dernier échantillon du cadrage large :

- 9 522 frames reçues et 1 872 analyses faciales cumulées ;
- un visage, 47 points faciaux ;
- cou : confiance 0,63 ;
- épaule gauche : confiance 0,60 ;
- épaule droite : confiance 0,65 ;
- segmentation non demandée.

Conclusion : la détection corporelle Apple et le mapping des trois
articulations fonctionnent. L'échec dans le cadrage quotidien vient du fait que
Vision exige une portion du corps beaucoup plus large que celle visible devant
un Mac à distance normale. Cette piste reste utile comme signal opportuniste
quand le cadrage le permet, mais ne peut pas être la seule base du suivi
quotidien. Ne pas augmenter la cadence ou la résolution sans preuve : cela
répéterait surtout plus souvent une requête vide et augmenterait le coût.

## 30 août 2026 — Spike MediaPipe Pose Landmarker Lite

Prototype Python isolé, exécuté localement avec MediaPipe `0.10.35` et le
modèle officiel `pose_landmarker_lite.task`. Le pipeline Swift d'Align n'a pas
été modifié. La caméra a fourni 1 745 frames en 1280×720 à 30 images/s ; le
modèle n'en a analysé que 60, à 1 Hz, sans enregistrer d'image, de vidéo ou de
coordonnée.

Résultats, 20 analyses par cadrage :

- assis à distance normale : deux épaules reconnues 20/20 (100 %), aucune
  perte, jitter médian 1,9 % de la largeur des épaules, latence p95 23,1 ms ;
- assis plus loin : 20/20 (100 %), aucune perte, jitter 2,3 %, latence p95
  20,0 ms ;
- debout avec le Mac plus bas : 20/20 (100 %), aucune perte, jitter 2,2 %,
  latence p95 19,9 ms.

Comparaison indicative avec Apple sur le benchmark précédent : Apple Body Pose
avait fourni les trois repères cou-épaules 3/26 fois en plein cadre et 0/26 dans
la ROI. Les populations ne sont pas appariées image par image, mais l'écart est
suffisamment important pour poursuivre MediaPipe comme candidat principal.

Limites : le test MediaPipe mesure deux épaules ; son « milieu du cou » est une
estimation entre elles, pas une articulation observée. La précision visuelle du
tracé doit encore être confirmée pendant un essai réel. Le journal a aussi montré une
tentative de télémétrie technique `portable_clearcut_uploader` ; l'envoi a
échoué pendant ce test, mais MediaPipe Tasks ne peut pas être considéré comme
strictement sans réseau tant que cette télémétrie n'est pas désactivée ou que
les modèles ne sont pas exécutés par un autre runtime local.
