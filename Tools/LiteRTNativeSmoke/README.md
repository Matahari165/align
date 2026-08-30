# Smoke test LiteRT natif

Ce programme isolé vérifie uniquement que le runtime C officiel LiteRT peut
être lié à un exécutable macOS arm64 et charger les deux modèles BlazePose
extraits du fichier `.task`. Il ne touche ni à la caméra ni au pipeline Swift
d'Align.

Prérequis temporaires, hors du dépôt :

- les en-têtes de `litert_cc_sdk.zip` version 2.2.0 ;
- `libLiteRt.dylib` macOS arm64 version 2.2.0 ;
- `pose_detector.tflite` et `pose_landmarks_detector.tflite`.

Provenance de la preuve du 30 août 2026 :

- release officielle LiteRT `v2.2.0` :
  `https://github.com/google-ai-edge/LiteRT/releases/tag/v2.2.0` ;
- en-têtes : asset officiel `litert_cc_sdk.zip`, SHA-256
  `0aa619c7477fb8d35cb10d7263fcd07958e9b351f988708316c01d9a00a2b0c6` ;
- runtime macOS arm64 : `libLiteRt.dylib` de la wheel officielle PyPI
  `ai-edge-litert==2.2.0`, SHA-256
  `131344a928e6ad56317f8a828d54c11c54c800aa140952f9b9f980af88260b20` ;
- modèle détecteur, SHA-256
  `46837eb883e6ec75b52c5f5ff6a9b78bd35e66c13f95e8c3566c582d146cb1d9` ;
- modèle repères, SHA-256
  `ad6cfd3c903eb31a4ee788b809e45ecf9fa69923b69b9f3f2d9ae616ff433e58`.

Les deux modèles proviennent de l'archive officielle MediaPipe
`pose_landmarker_lite.task` utilisée par le benchmark de référence. Ils ont
été extraits sans conversion ni réentraînement.

L'asset `litert_cc_sdk.zip` 2.2.0 consulté ne contenait pas lui-même le
`libLiteRt.dylib` que son CMake attend. Avant de placer le runtime dans Align,
conserver avec lui la licence Apache-2.0 et les fichiers NOTICE de la release,
ainsi que cette provenance reproductible.

Compilation :

```sh
xcrun clang -std=c17 \
  -I/path/to/litert_cc_sdk \
  Tools/LiteRTNativeSmoke/litert_model_smoke.c \
  -L/path/to/litert-dylibs -lLiteRt \
  -Wl,-rpath,/path/to/litert-dylibs \
  -o /tmp/litert_model_smoke
```

Exécution :

```sh
/tmp/litert_model_smoke \
  /path/to/pose_detector.tflite \
  /path/to/pose_landmarks_detector.tflite
```

Résultat attendu : chaque modèle est chargé et annonce une signature et un
sous-graphe. Cette preuve ne suffit pas encore pour intégrer LiteRT dans
Align : l'étape suivante doit invoquer les deux modèles puis vérifier la
parité `détecteur -> ROI -> repères` avec le benchmark MediaPipe de référence.

Le second programme vérifie aussi que les opérateurs des deux modèles sont
compatibles avec le backend CPU natif, en réalisant une invocation sur une
entrée noire :

```sh
xcrun clang -std=c17 \
  -I/path/to/litert_cc_sdk \
  Tools/LiteRTNativeSmoke/litert_invoke_smoke.c \
  -L/path/to/litert-dylibs -lLiteRt \
  -Wl,-rpath,/path/to/litert-dylibs \
  -o /tmp/litert_invoke_smoke

/tmp/litert_invoke_smoke \
  /path/to/pose_detector.tflite \
  /path/to/pose_landmarks_detector.tflite
```

L'inférence est explicitement demandée sur le backend CPU/XNNPACK. Le runtime
chargé découvre et enregistre aussi localement l'accélérateur Metal au
démarrage, mais ce smoke test ne lui confie pas l'exécution des modèles.

Cette invocation n'est pas encore un test de qualité : une image noire ne
permet pas de vérifier les épaules. La preuve suivante doit reproduire le
prétraitement, le décodage du détecteur et la ROI exigés par BlazePose.

## Géométrie BlazePose

`blazepose_geometry.c` reproduit séparément les formules MediaPipe :

- 2 254 ancres SSD pour l'entrée 224×224 ;
- décodage des 12 valeurs et du score sigmoïde ;
- seuil de score 0,5 puis weighted NMS à IoU 0,3 avant de conserver une
  seule personne ;
- rectangle orienté utilisant les deux points d'alignement, agrandi de 1,25 ;
- décodage des 39 repères de l'entrée 256×256 ;
- raffinement 7×7 des repères par la heatmap 64×64×39, après sigmoïde des
  logits comme dans le calculateur MediaPipe ;
- projection des repères du rectangle orienté vers l'image complète.

```sh
xcrun clang -std=c17 \
  Tools/LiteRTNativeSmoke/blazepose_geometry.c \
  Tools/LiteRTNativeSmoke/blazepose_geometry_harness.c \
  -ITools/LiteRTNativeSmoke -o /tmp/blazepose_geometry_harness
/tmp/blazepose_geometry_harness
```

Le harness est déterministe et ne demande ni runtime LiteRT ni image réelle.

`blazepose_image_tensor.c` ajoute le letterboxing 224×224, la normalisation
[-1, 1] du détecteur et le crop bilinéaire orienté 256×256 des repères. Son
harness emploie une petite image synthétique RGB :

- le détecteur conserve `BORDER_ZERO`, comme son graphe explicite ;
- le crop landmarks utilise `BORDER_REPLICATE`, valeur par défaut du graphe
  MediaPipe : lorsqu'une ROI proche dépasse l'image, le pixel du bord est
  recopié au lieu de créer une grande zone noire.

```sh
xcrun clang -std=c17 \
  Tools/LiteRTNativeSmoke/blazepose_geometry.c \
  Tools/LiteRTNativeSmoke/blazepose_image_tensor.c \
  Tools/LiteRTNativeSmoke/blazepose_image_tensor_harness.c \
  -ITools/LiteRTNativeSmoke -o /tmp/blazepose_image_tensor_harness
/tmp/blazepose_image_tensor_harness
```

Ces étapes sont couvertes par les harnesses synthétiques, puis par la première
comparaison publique décrite plus bas. La parité sur la webcam réelle reste à
mesurer.

`blazepose_pipeline.c` relie ensuite les sorties des deux modèles sans dépendre
de LiteRT : détecteur → letterbox → ROI → entrée 256 → repères/heatmap → image.
Il expose les épaules BlazePose 11/12 et un **cou estimé** comme leur milieu.

```sh
xcrun clang -std=c17 \
  Tools/LiteRTNativeSmoke/blazepose_geometry.c \
  Tools/LiteRTNativeSmoke/blazepose_image_tensor.c \
  Tools/LiteRTNativeSmoke/blazepose_pipeline.c \
  Tools/LiteRTNativeSmoke/blazepose_pipeline_harness.c \
  -ITools/LiteRTNativeSmoke -o /tmp/blazepose_pipeline_harness
/tmp/blazepose_pipeline_harness
```

Pour la comparaison sans stockage, la future façade caméra doit fournir le
même buffer RGB en mémoire aux deux chemins pendant une session explicitement
guidée. Seuls les compteurs agrégés sortent : présence des deux épaules,
différence de coordonnées normalisées, pertes/récupérations et latence. Aucun
pixel ni repère image par image n'est écrit sur disque.

`blazepose_native_cli.c` constitue la preuve de raccordement native : il charge
les deux modèles avec LiteRT C, alimente leurs vrais buffers dans l'ordre
`Identity/Identity_1/Identity_3`, puis imprime seulement les deux épaules et le
cou estimé. Son entrée fichier RGB float32 est réservée au test reproductible ;
la future intégration remplacera ce fichier par le buffer caméra en mémoire.
Le chemin `-` lit directement les pixels sur l'entrée standard et évite même
un fichier temporaire.

## Première parité officielle

Le pipeline natif a été exécuté sur l'image officielle
`pose-detection/test_data/pose.jpg` de Google, 1000×667. Résultat :

| Repère | Natif LiteRT | Référence MediaPipe officielle | Écart |
|---|---:|---:|---:|
| épaule 11 | (541,21 ; 321,06 px) | (545 ; 319 px) | 4,3 px |
| épaule 12 | (457,91 ; 327,32 px) | (453 ; 329 px) | 5,2 px |

Le test TFJS officiel accepte 15 px d'écart par coordonnée sur cette même
image. Les deux épaules natives sont donc dans la tolérance de référence. Cette
preuve utilise une image publique fixe ; elle doit être complétée par les trois
phases webcam déjà définies pour Align.

La conversion de l'image de référence peut être envoyée directement au CLI,
sans écrire les pixels :

```sh
python3 -c 'import cv2,sys; im=cv2.cvtColor(cv2.imread(sys.argv[1]),cv2.COLOR_BGR2RGB); sys.stdout.buffer.write((im.astype("float32")/255).tobytes())' \
  /path/to/pose.jpg | \
  /tmp/blazepose_native_cli detector.tflite landmarks.tflite 1000 667 -
```

Pour une comparaison caméra future, un seul callback transforme la frame en
RGB une fois, puis passe le même pointeur mémoire à la référence et au pipeline
natif. Les résultats sont comparés immédiatement et jetés ; seuls les agrégats
restent en mémoire jusqu'à l'affichage du rapport.

## Comparaison webcam same-frame préparée

`blazepose_native_stream.c` garde les deux modèles chargés et lit plusieurs
frames RGB `uint8` sur un même flux. Le script
`Tools/mediapipe_litert_same_frame.py` donne exactement le même tableau RGB à
MediaPipe et à ce processus natif. Il n'affiche à la fin que des agrégats par
phase : présence des épaules, écarts, latence et pertes/récupérations.
Chaque réponse distingue explicitement `detected`, `noPerson` et
`technicalError`. Une erreur LiteRT, un buffer absent ou une sortie non finie
est compté séparément et n'entre jamais dans les taux de présence/absence.

### Test visuel très proche, 25 secondes

Le mode visuel ouvre la caméra localement et affiche directement les deux
épaules reconnues séparément et l'état `DETECTE`, `PARTIEL`, `PERDU` ou
`ERREUR LITERT`. La ligne et le `CENTRE ESTIME` ne s'affichent que lorsque les
deux épaules sont présentes. La preview et les repères sont miroir ensemble une seule fois.
Il n'enregistre aucune image, aucune coordonnée et n'utilise pas le réseau.

```sh
/private/tmp/align-mediapipe-venv/bin/python \
  Tools/mediapipe_litert_same_frame.py \
  --visual-live \
  --native-stream /tmp/blazepose_native_stream_strict \
  --detector /private/tmp/pose_detector.tflite \
  --landmarks /private/tmp/pose_landmarks_detector.tflite \
  --analysis-hz 5 \
  --visual-seconds 25
```

Rester à la distance la plus proche réellement utilisée. Bouger légèrement
les épaules permet de vérifier que `G` suit l'épaule anatomique gauche et `D`
la droite. La fenêtre se ferme seule ; `Q` ou Échap permet de quitter avant.

Le protocole court priorise désormais le problème réel : `normal_proche`,
`tres_proche_a`, puis `tres_proche_b`. Avec 9 secondes par phase, 2 secondes de
stabilisation exclues et 5 Hz, chaque phase fournit environ 35 analyses utiles,
pour une durée totale de 27 secondes.

```sh
python3 Tools/mediapipe_litert_same_frame.py --dry-run
```

Si les deux chemins détectent les épaules mais divergent géométriquement, le
rapport ajoute uniquement des **agrégats** : décalages médians signés `dx/dy`
pour chaque épaule, erreur directe, après échange gauche/droite, après miroir,
après miroir + échange, et ratio de largeur des épaules. Une valeur `dx`
positive signifie que le point natif est plus à droite que la référence ; une
valeur `dy` positive signifie qu'il est plus bas. Aucune coordonnée de frame
n'est affichée ou écrite.

Le diagnostic géométrique retire le suivi temporel MediaPipe de la comparaison
et utilise les trois phases proches définies ci-dessus :

```sh
python3 Tools/mediapipe_litert_same_frame.py \
  --native-stream /tmp/blazepose_native_stream \
  --detector /path/to/pose_detector.tflite \
  --landmarks /path/to/pose_landmarks_detector.tflite \
  --mediapipe-model /path/to/pose_landmarker_lite.task \
  --reference-mode image --analysis-hz 5 --phase-seconds 9 \
  --warmup-seconds 2
```

Interprétation : si le mode `image` réduit fortement l'écart, le suivi/ROI
temporel de la référence explique l'essentiel de la différence. Si la variante
miroir ou échange devient nettement meilleure, le repère gauche/droite est en
cause. Si `dx/dy` reste cohérent et que le ratio de largeur s'écarte de 1, le
crop/échelle est la piste prioritaire. Le letterbox, les centres de pixels
(`+0,5/-0,5`) et la projection ROI du chemin natif restent couverts par les
harnesses synthétiques et par l'image officielle fixe.

Le protocole expose également, seulement sous forme de médianes par phase, le
centre, la taille et la rotation de la ROI native. Le centre est rapporté par
rapport au milieu des épaules de référence. Cela permet de vérifier si un biais
commun aux deux épaules se déplace avec la ROI du détecteur, sans afficher ni
conserver les coordonnées d'une frame particulière.

Il compare enfin l'erreur médiane des épaules **brutes** du modèle landmarks à
celle des épaules raffinées par la heatmap officielle (fenêtre 7×7, seuil 0,5).
Cela indique si la heatmap réduit ou amplifie le biais lorsque la ROI devient
très grande, sans désactiver cette étape ni modifier arbitrairement les points.

## Recalage expérimental sur le visage Apple

`blazepose_face_registration.c` est un composant géométrique pur et encore
isolé. Il prépare deux variantes pour un futur A/B sur la même frame :

- **translation seule** entre ancres faciales communes fiables (priorité aux
  centres des deux yeux) ; elle préserve exactement longueur et angle de la
  ligne des épaules ;
- similitude 2D (translation, rotation, échelle), uniquement comme comparateur
  tant que son bénéfice n'est pas prouvé.

Ce recalage n'est ni une calibration utilisateur ni un offset mémorisé. Il doit
être recalculé sur la même frame et la même génération, refusé si les ancres
sont absentes ou incohérentes, et ne doit jamais conserver de coordonnées.
Le comparateur vérifie l'identifiant retourné avant d'associer les résultats,
puis accepte le recalage seulement si les deux paires d'yeux mesurent au moins
12 px, si le résidu facial ne dépasse pas 12 px et, pour la similitude, si
l'échelle reste entre 0,85 et 1,15 et la rotation sous 10 degrés. Le rapport
compte les recalages acceptés et chaque catégorie de rejet.
Une phase A/B reste inconclusive sous 30 analyses utiles et sous 80 % de couverture
faciale. La translation passe seulement si elle réduit l'erreur médiane des
épaules d'au moins 20 % sans dégrader le p95. La similitude reste un témoin de
diagnostic : elle ne peut pas, à elle seule, autoriser une intégration.
Le gate géométrique doit être lancé avec `--reference-mode image` pour comparer
deux inférences indépendantes sur les mêmes octets. Le mode `video`, qui garde
un suivi temporel côté MediaPipe, constitue un test comportemental séparé.

```sh
xcrun clang -std=c17 -Wall -Wextra -Werror -Wconversion -Wshadow -pedantic \
  Tools/LiteRTNativeSmoke/blazepose_face_registration.c \
  Tools/LiteRTNativeSmoke/blazepose_face_registration_harness.c \
  -ITools/LiteRTNativeSmoke -o /tmp/blazepose_face_registration_harness
/tmp/blazepose_face_registration_harness
```

Le harness prouve l'invariance du vecteur des épaules sous translation, la
récupération exacte d'une similitude synthétique et le rejet des ancres
dégénérées ou non finies. Aucun de ces recalages n'est encore branché dans
Align.

Le comparateur same-frame expose maintenant les centres BlazePose des yeux
(moyenne des repères 1–3 et 4–6) et le nez 0, avec leur confiance. Il calcule
dans l'espace pixel, uniquement en mémoire, trois erreurs agrégées : épaules
directes, après translation faciale et après similitude faciale. Le premier A/B
emploie les mêmes repères MediaPipe des deux côtés pour valider la géométrie
indépendamment d'Apple Vision. Le branchement Apple ne sera envisagé qu'après
ce test, avec des ancres de même sémantique et provenant strictement de la même
frame.

Le protocole persistant a été testé hors caméra avec deux envois successifs de
l'image officielle : les modèles ne sont chargés qu'une fois, les coordonnées
sont identiques entre les deux appels, et la latence native observée est passée
d'environ 36 ms au premier appel à 27 ms au second sur le Mac M2. Ces valeurs
sont seulement une preuve technique, pas encore un benchmark webcam.

Attention : le chemin de référence requiert temporairement
`mediapipe==0.10.35`, qui peut tenter d'envoyer des métriques Clearcut. Pour le
test de comparaison, couper la connexion Internet du Mac. Le pipeline LiteRT
natif lui-même n'utilise pas MediaPipe Tasks.

Confidentialité : le test n'utilise ni caméra, ni image personnelle, ni donnée
utilisateur. L'unique image réelle est l'image de test publique de Google ; les
pixels transformés sont transmis en mémoire et ne sont pas écrits dans le
dépôt.
