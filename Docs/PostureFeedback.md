# Référence géométrique et rappels Align

## Principe

La posture de production n'est plus comparée à la manière dont la personne
s'est tenue pendant une calibration. Elle est comparée à des axes géométriques
communs à l'image caméra. Un petit déplacement vers l'avant ou vers l'arrière
ne change donc pas, à lui seul, le repère angulaire.

La version active des règles est `universal-geometry-v2`. Les anciennes valeurs
de posture ne sont pas réutilisées. La calibration de huit secondes ne sert
plus qu'à mesurer l'ouverture habituelle de chaque œil pour rendre la détection
des clignements plus fiable.

## Signaux utilisés

| Signal | Référence de production | Écart d'entrée | Retour dans la zone | Durée avant attention |
| --- | --- | ---: | ---: | ---: |
| Torse incliné | Axe entre le milieu des épaules et celui des hanches, 0° = vertical | ±10° | ±6° | 0,8 s sensible · 1 s équilibré · 1,5 s discret |
| Épaules inclinées | Angle de la ligne entre les deux épaules, 0° = horizontale | ±6° | ±3,5° | 1 s sensible/équilibré · 1,5 s discret |
| Épaules relevées | Hauteur perpendiculaire entre la base du cou et la ligne des épaules, divisée par sa largeur | ratio ≤ 0,20 | ratio ≥ 0,23 | 0,8 s sensible · 1 s équilibré · 1,5 s discret |
| Tête inclinée | Différence entre la ligne des yeux et la ligne des épaules | ±10° | ±6° | 0,8 s sensible · 1 s équilibré · 1,5 s discret |
| Proximité apparente | Taille du visage dans l'image, proxy 2D | 0,24 | 0,21 | 2 s continus |
| Main au visage | Distance 2D main–visage | seuil du détecteur | seuil de sortie du détecteur | 2,5 s continus |
| Clignements | Ouverture habituelle de chaque œil + débit personnel appris | ouverture sous 65 % de la référence | ouverture au-dessus de 80 % | rappel yeux ouverts : 15/20/30 s selon sensibilité |

Les angles utilisent une hystérésis : le seuil de sortie est plus proche de
zéro que le seuil d'entrée. Exemple : une inclinaison du torse doit dépasser
10° pendant la durée du profil pour déclencher une attention ; elle doit ensuite
revenir sous 6° pour fermer l'épisode.

La proximité est uniquement une taille apparente du visage dans le cadre. Elle
ne donne pas une distance en centimètres. Elle dépend donc encore du cadrage,
du zoom et de la caméra ; si l'image est mauvaise ou si le visage est trop
tourné, le signal devient indisponible plutôt que d'inventer une mesure.

Le signal « épaules relevées » est maintenant un rappel actif. Il ne compare
plus une élévation à une calibration personnelle : il mesure l'aplatissement du
triangle cou–épaules par sa hauteur perpendiculaire divisée par la largeur de la
base. Le ratio est donc indépendant de la taille du visage dans l'image. La
pente de cette base reste un signal séparé pour repérer une épaule plus haute
que l'autre. Le ratio tête–épaules fermé reste diagnostique, car sa cause peut
être la tête avancée ou les épaules refermées.

Pour ne pas transformer un point d'épaule douteux en alerte, les deux épaules,
la base du cou et la cohérence de la paire doivent être fiables. La mesure est
alors disponible ; sinon elle reste limitée ou indisponible et ne déclenche
pas de rappel.

## Clignements

Le détecteur reconnaît un cycle des deux yeux : ouverture, fermeture, puis
réouverture. Les deux yeux doivent être visibles et cohérents. La fermeture
doit durer au moins 50 ms et au plus 500 ms ; une interruption de suivi de plus
de 350 ms casse le clignement en cours.

Deux références différentes sont utilisées :

- l'ouverture habituelle de l'œil gauche et de l'œil droit est mesurée pendant
  l'initialisation de huit secondes ;
- le débit de clignements est appris automatiquement sur trois fenêtres d'une
  minute, avec au moins 45 secondes réellement observées par fenêtre. Cela
  représente au minimum trois minutes de suivi exploitable, pas trois minutes
  de caméra aveugle.

Quand le débit appris est disponible, une fréquence inférieure à 70 % de cette
cible pendant cinq minutes continues ouvre un épisode de baisse. Il faut ensuite
deux minutes au-dessus du seuil pour le fermer. Indépendamment de cette cible,
un rappel pratique peut apparaître lorsque les deux yeux restent ouverts sans
clignement détecté pendant 15 secondes en mode sensible, 20 secondes en mode
équilibré ou 30 secondes en mode discret. Ce rappel n'est pas une norme
médicale.

## Notifications

Une notification n'est jamais envoyée sur une seule image. Il faut :

1. une observation récente et de bonne qualité ;
2. le maintien de l'écart pendant la durée indiquée ci-dessus ;
3. un signal activé et non suspendu dans les réglages ;
4. l'autorisation des notifications macOS.

Après l'entrée en attention publiée par le moteur, le coordinateur ajoute une
petite durée de confirmation avant de réserver la notification :

- posture, épaules relevées et proximité : 7,5 s en mode sensible, 15 s en mode équilibré,
  22,5 s en mode discret ;
- clignements : 0,5 s, 1 s ou 1,5 s selon ces mêmes profils ;
- main au visage : 0,125 s, 0,25 s ou 0,375 s.

Cela donne, à titre pratique, environ 8,3/16/24 s pour un angle du torse ou de
la tête, 9,5/17/24,5 s pour la proximité, 2,6/2,75/2,9 s pour la main au
visage et 15,5/21/31,5 s pour le rappel « yeux ouverts » — avant d'éventuels
blocages de livraison. Une mesure doit donc d'abord franchir sa durée
géométrique du tableau, puis cette confirmation.
Le coordinateur impose aussi au moins 30 s entre deux signaux différents,
60 s entre deux rappels de posture du même type et 120 s entre deux rappels de
clignements. Ces durées sont des protections anti-spam, pas des seuils de
détection.

Le coordinateur réserve ensuite la livraison. Une réservation est annulée si
la mesure revient dans la zone, si la preuve devient incertaine, si le contexte
caméra change ou si la livraison expire. Les rappels peuvent se répéter selon
le profil de sensibilité, avec les protections de récurrence déjà définies par
le coordinateur.

## Qualité et limites

Le moteur exige des repères suffisants : épaules et hanches pour le torse,
deux épaules pour leur pente, visage et épaules pour la tête, visage frontal
pour la proximité et les yeux pour les clignements. Une mesure trop ancienne,
incomplète ou incohérente devient indisponible ; elle ne déclenche pas de
rappel.

Cette solution élimine la fausse référence personnelle qui signalait une
posture « mauvaise » après un simple changement de position. Elle ne transforme
pas une caméra 2D en mesure anatomique universelle : la précision réelle doit
encore être vérifiée avec la caméra habituelle, plusieurs cadrages et des
observations de faux rappels par heure.
