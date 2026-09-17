# Spike MediaPipe Pose

> **Décision de confidentialité :** ce banc d'essai reste un outil de recherche
> et ne doit pas être intégré au produit. MediaPipe Tasks 0.10.35 tente
> d'envoyer des métriques techniques Clearcut à Google et n'expose pas de
> désactivation officielle. Align réutilisera éventuellement les modèles
> BlazePose validés, mais via un runtime local distinct et sans réseau.

Ce banc d'essai compare MediaPipe Pose Landmarker Lite au détecteur corporel
Apple sans modifier le pipeline Swift d'Align. Il utilise uniquement la caméra
locale et la mémoire vive : aucune image, vidéo, coordonnée ou rapport n'est
enregistré.

## Préparation

Créer un environnement Python séparé du projet, puis y installer
`mediapipe==0.10.35` et `opencv-python`. La version MediaPipe 1.0.1 a provoqué
un crash sur le MacBook Air M2 pendant le spike initial ; 0.10.35 est donc la
version de référence vérifiée. Télécharger séparément le modèle officiel
`pose_landmarker_lite.task`. Le modèle n'est pas inclus dans Git et son chemin
est fourni explicitement au lancement. Le script en affiche le nom et le hash,
mais ne peut pas prouver seul qu'un fichier renommé est bien la variante Lite :
il faut utiliser le téléchargement officiel.

```bash
python3 -m venv .venv-mediapipe
.venv-mediapipe/bin/python -m pip install mediapipe==0.10.35 opencv-python
.venv-mediapipe/bin/python Tools/mediapipe_pose_spike.py \
  --model /chemin/absolu/pose_landmarker_lite.task
```

L'environnement temporaire utilisé pendant le développement peut aussi lancer
le test tant qu'il existe encore :

```bash
/private/tmp/align-mediapipe-venv/bin/python Tools/mediapipe_pose_spike.py \
  --model /private/tmp/pose_landmarker_lite.task
```

Appuyer sur Espace pour démarrer puis suivre trois phases de 20 secondes :
position assise normale, position un peu plus éloignée et Mac placé plus bas.
`Q` ou Échap arrête le test. L'aperçu est miroir. Les points verts sont les
deux épaules réellement produites par MediaPipe. La ligne bleue rejoint le nez
au milieu des épaules ; ce milieu est une estimation, pas un repère anatomique
mesuré.

Le rapport terminal indique, pour chaque phase : présence simultanée des deux
épaules, pertes et récupération, jitter entre deux résultats consécutifs et
latence d'inférence. Le modèle est appelé par défaut à 1 Hz, c'est-à-dire une
analyse par seconde, sans file d'attente ; l'aperçu conserve le dernier tracé
pendant au plus 1,2 seconde. Le jitter suppose que la personne reste immobile ; un
vrai mouvement augmente naturellement cette mesure. Le rapport affiche aussi
les angles médians de la ligne des épaules et de l'axe tête-épaules. Il affiche
séparément les erreurs techniques, qui ouvrent une interruption lorsqu'elles
surviennent après une première détection valide. Le rapport affiche enfin
la résolution et la cadence réellement acceptées par la caméra ainsi que le
hash SHA-256 du modèle, afin de rendre deux essais comparables.

## Vérification sans caméra

```bash
python3 Tools/mediapipe_pose_spike.py --dry-run
```

Ce mode vérifie la chronologie des phases, les percentiles, les pertes et le
calcul de jitter sans importer MediaPipe ou OpenCV.

## Décision

Le modèle mérite une intégration Swift ultérieure seulement s'il reconnaît les
deux épaules dans au moins 85 % des analyses en position assise normale, sans
inversion gauche/droite, avec une récupération inférieure à une seconde. Ce
spike ne produit aucun verdict de posture.

Le test réel du 30 août 2026 a atteint 60/60 détections sur les trois cadrages,
avec une latence p95 de 19,9 à 23,1 ms et un jitter médian de 1,9 à 2,3 %.
Le modèle est donc validé qualitativement et quantitativement. Le runtime
MediaPipe Tasks est en revanche rejeté à cause de sa télémétrie.
