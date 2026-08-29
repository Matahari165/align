# Benchmarks Align

Ce fichier conserve uniquement des mesures agrégées. Aucune image, vidéo ou coordonnée faciale n’est enregistrée.

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

Prochaine comparaison : cadence visage 5 fois/s lorsque la fenêtre est visible, 2 fois/s en arrière-plan, corps conservé à 1 fois/s.

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
