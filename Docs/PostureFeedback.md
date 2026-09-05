# Interprétation de la posture et rappels

## Mesures proposées

Le suivi visible des épaules est la base de cette étape. Les mesures comparent la position courante à un repère personnel de huit secondes, établi dans le cadrage de travail habituel.

| Indicateur | Ce qui est mesuré | Conditions |
| --- | --- | --- |
| Inclinaison des épaules | Écart angulaire de la ligne entre les épaules | Deux épaules fiables |
| Épaules relevées | Hauteur de chaque épaule par rapport au cou, rapportée à la largeur des épaules | Cou et épaules fiables |
| Tête penchée | Angle de la ligne des yeux par rapport à celle des épaules | Visage et épaules appairés ; correction du format de l'image |
| Tête–épaules | Rapport largeur des épaules / taille apparente du visage | Visage et épaules fiables ; le cou n'est pas nécessaire |
| Proximité apparente | Taille du visage comparée à la calibration ; ×1,25 signifie un visage 25 % plus grand | Visage suffisamment frontal |
| Torse incliné | Inclinaison du torse comparée au repère | Épaules et hanches visibles |
| Clignements estimés | Événements des deux yeux par minute réellement observable | Images suffisamment rapprochées ; les trous ne comptent pas |

Le rapport tête–épaules ne permet pas de distinguer à lui seul une tête avancée d'épaules refermées. Align ne prétend pas mesurer directement la courbure du dos ni une distance en centimètres. Une calibration mémorise une position choisie ; elle ne prouve pas que cette position est idéale.

Les angles tête/épaules sont calculés dans le même espace pixel avant soustraction. Une rotation commune de l'image s'annule dans l'angle relatif. La pente absolue des épaules reste comparée à la calibration : déplacer la caméra demande de refaire le repère.

## Rappels

Les sept observations peuvent déclencher un rappel, uniquement avec une preuve fraîche et de bonne qualité. Les rappels corporels attendent un écart persistant ; le réglage par défaut est Sensible. Un rappel peut revenir après 60 secondes pour le même signal, avec au moins 30 secondes entre signaux différents. Les yeux ont un délai de répétition de 120 secondes. Chaque signal peut être suspendu dans les réglages.

Les clignements utilisent deux approches :

- un rappel pratique après une période prolongée d'yeux ouverts continuellement observés ; le profil Sensible utilise 15 secondes, le profil équilibré 20 secondes et le profil discret 30 secondes. Ce sont des préférences de rappel, pas des normes médicales ;
- une baisse durable par rapport à un repère personnel appris sur trois fenêtres indépendantes d'une minute, chacune comprenant au moins 45 secondes observables.

Le débit brut peut être affiché pendant l'apprentissage, sans dire si la personne cligne assez. Une fermeture des yeux, une preuve invalide ou une interruption du suivi casse le compteur de la longue période d'yeux ouverts.

Une réservation de notification est annulée si la posture revient au repère, si la preuve devient incertaine ou si elle expire pendant l'attente de macOS. Le test de notification des réglages est explicitement identifié et n'entre pas dans les statistiques.

Les rappels demandent le son système, au premier plan comme en arrière-plan. Leur durée dépend du réglage macOS d’Align : le style Persistant les conserve jusqu’à leur fermeture. Les réglages de l’application donnent accès à ce choix. Les messages décrivent l’axe réellement mesuré : une épaule plus haute que l’autre, tête ou buste penchés sur le côté. Le côté gauche/droit n’est pas inventé lorsque la notification ne possède pas cette information.

## Cadence de traitement

Pendant les huit secondes de calibration, le corps est sollicité deux fois par seconde, même en arrière-plan, pour pouvoir réunir les douze mesures nécessaires au repère. Une détection trop lente ou insuffisante peut encore empêcher la calibration d'un indicateur ; il reste alors indisponible.

Le calcul RTMPose du corps s’exécute sur une file de travail distincte de celle du visage. Une seule image corporelle peut être en calcul ; aucune file d’images en retard ne s’accumule. Le résultat garde son heure de capture et le visage appairé à ce moment. Au retour, Align vérifie la génération, le contexte et la fraîcheur avant de le publier. Le débit live des yeux utilise une fenêtre glissante, distincte des fenêtres indépendantes servant à apprendre le repère.

Une interruption des yeux supérieure à 350 ms casse le clignement en cours mais conserve les portions valides de la fenêtre glissante ; elle ne remet plus tout le débit à zéro. Le temps manquant n’est jamais compté. Une absence longue casse aussi l’épisode courant, mais les observations encore âgées de moins d’une minute restent utilisables au retour et les plus anciennes sortent naturellement de la fenêtre. Pendant la collecte, le rail affiche les secondes réellement observées sur les 45 nécessaires ; une donnée périmée ne garde pas une fausse progression. Une réacquisition dans le même contexte caméra ne supprime donc ni la cible personnelle ni les secondes valides déjà acquises.

## Évolution et vérification

Les statistiques suivent les épisodes, les rappels et les retours au repère, par heure réellement observée. L'inclinaison des épaules est sélectionnée par défaut. Les périodes sans observation restent inconnues. Les comparaisons entre périodes sont suspendues si les règles ou la sensibilité ont changé.

Vérifications automatiques pertinentes :

- calcul angulaire sur des repères faciaux réellement transformés, dans une image non carrée ;
- calibration indépendante sans hanches et ratio tête–épaules sans cou ;
- rejet de points pauvres, d'un visage trop tourné, de données périmées et d'une ancienne génération ;
- apprentissage sur fenêtres indépendantes et conservation de la fraîcheur des valeurs affichées ;
- répétition des rappels, équité entre signaux et annulation des livraisons asynchrones devenues invalides ;
- conservation des anciennes données et absence de comparaison trompeuse entre règles différentes.

La compilation et ces scénarios ne prouvent pas l'exactitude anatomique. La validation réelle doit vérifier séparément le cadrage habituel, la stabilité pendant le travail, la disponibilité des yeux et l'apparition des notifications macOS. Pour mesurer objectivement les progrès, comparer quelques gestes identifiés au départ et des périodes de travail neutres, puis relever les faux rappels par heure observée et le délai de retour au repère.

## Vérification locale du 5 septembre 2026

- Compilation Release et contrôle du modèle RTMPose embarqué : réussis.
- Quatorze harnesses de calcul, temporalité, continuité visage, affichage, historique et alertes : réussis.
- Test du worker réel avec une inférence simulée bloquante : réussi. Il vérifie que la file du visage reste disponible, qu'une seconde frame n'est pas mise en attente, qu'une ancienne activation ne publie rien et qu'un calcul expiré est rejeté. Commande : `sh Tests/UpperBodyInferenceWorkerHarness.sh`. Le script extrait le worker de production ; son implémentation n'est pas dupliquée dans le test.
- Interface à trois puis deux colonnes : vérifiée dans l'application.
- Calibration réelle sur la dernière Release : 16 mesures utilisables pour les épaules, la tête penchée et le rapport tête–épaules ; 69 mesures faciales. Ces trois indicateurs et la proximité sont affichés dans le cadrage courant. Le cou et les hanches insuffisamment fiables laissent les deux autres mesures corporelles indisponibles.
- Le taux de clignements a été observé à 10,6/min après séparation du calcul du corps et du visage ; ce relevé vérifie le fonctionnement de l'affichage, pas l'exactitude du comptage.
- Notification de test : présente dans le centre de notifications macOS. Deux rappels réels d'inclinaison des épaules ont également été enregistrés pendant l'observation naturelle.

Ces résultats ne constituent pas une mesure de précision des clignements contre un comptage humain, ni une validation médicale de posture.

### Retour utilisateur : son, durée et clignements

- macOS Align vérifié sur Persistant, puis son activé dans les réglages système après ajout de l’autorisation sonore. Rappel de test envoyé et présent dans le centre de notifications. La sortie audio n’a pas été mesurée acoustiquement.
- Après correction des interruptions, l’application a affiché la progression `23/45 s`, puis les débits estimés `13,0/min`, `8,9/min` et `15,6/min` en usage naturel. Le repère personnel était encore en apprentissage.
- Tests de reprise après interruption, expiration de progression, affichage et notifications : réussis. Empreintes des sept fichiers du nouveau logo inchangées.
