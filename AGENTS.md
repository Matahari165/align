# Règles du projet Align

## Produit et première version

- Align est une application macOS strictement personnelle, conçue uniquement pour Jeremy.
- La V1 affiche la caméra, détecte localement quelques points du corps, estime simplement la posture et donne un retour clair.
- Le traitement reste local. Les statistiques avancées, niveaux, XP, classement et fonctions sociales sont hors du premier objectif.
- Align fonctionne principalement depuis la barre des menus, avec une fenêtre simple et évolutive.
- Les modes de posture sont `Automatique`, `Assis` et `Debout`; `Automatique` reste le mode normal.

## Machine et contraintes techniques

- La machine de référence est un MacBook Air M2 avec 8 Go de RAM. Align doit pouvoir rester actif sans ralentissement gênant.
- Privilégie un modèle local léger, une cadence et une résolution modestes, une seule inférence à la fois et une consommation mesurée. N’annonce jamais une performance ou une autonomie sans mesure.
- Sépare acquisition caméra, détection de pose, normalisation, calcul des métriques et affichage.

## Autonomie, délégation et coordination

- L’agent principal reste responsable du périmètre, des décisions finales, de la cohérence, de la vérification et de la synthèse.
- Pour chaque tâche non triviale, évalue les sous-tâches qui bénéficient réellement d’une analyse, recherche, implémentation ou vérification séparée. Si une délégation apporte une valeur claire, utilise au moins un sous-agent **GPT-5.6 Luna `high`**.
- Utilise **Luna `xhigh`** pour une difficulté élevée, un diagnostic ambigu, une revue critique ou une vérification indépendante. Utilise deux, trois ou quatre sous-agents lorsque plusieurs lots sont réellement indépendants et que cela accélère le travail ou améliore la preuve.
- Ne délègue pas une tâche triviale, strictement séquentielle ou trop petite pour justifier le coût de coordination. Ne crée pas de doublons.
- Chaque sous-agent reçoit une mission bornée, son périmètre de fichiers, les invariants à respecter et la preuve attendue. Il ne modifie pas silencieusement le travail d’un autre agent.
- Les agents coordonnent eux-mêmes les dépendances, l’ordre des travaux, les fichiers réservés, les conflits et la reprise après blocage. Ils ne demandent pas à l’utilisateur d’organiser leur travail.

## Git et sauvegardes

- Avant toute modification, inspecte la branche, l’état Git et les changements existants. Préserve tout changement hors périmètre.
- Les agents gèrent eux-mêmes les sauvegardes récupérables, les commits locaux cohérents et l’intégration des lots vérifiés. Un commit peut servir de point de reprise avant une opération risquée.
- Utilise une branche ou un worktree séparé lorsque des tâches parallèles peuvent se chevaucher. Ne réinitialise pas, n’écrase pas et ne supprime pas le travail existant.
- Relis le diff final et vérifie les capacités, permissions et réglages macOS concernés.
- Push, publication, déploiement, dépense, contact d’un tiers et modification d’un service externe exigent une autorisation explicite.

## Données, santé et caméra

- Distingue flux caméra, points de pose, métriques calculées et éventuelles données de santé.
- Ne mets jamais d’image, export de santé, identifiant, clé, jeton, session ou donnée sensible dans le code, Git, les journaux ou les réponses.
- Ne conserve ni n’envoie de flux caméra sans nécessité explicite, consentement clair et justification documentée. Respecte les permissions macOS et rends visible l’utilisation de la caméra.

## Interface et microcopy

- Construis une direction visuelle propre à Align : typographie, palette, densité, formes, icônes et mouvement doivent servir le retour postural. Évite l’AI slop : gradients gratuits, cartes identiques, gros titres décoratifs, interfaces copiées ou styles mélangés sans raison.
- Avant une création ou refonte importante, choisis une direction claire et vérifie-la avec des références pertinentes. Ne remplace pas l’identité d’Align par un thème générique.
- Purge les textes visibles inutiles : sous-titres redondants, phrases évidentes, labels répétés, aide décorative et confirmations bavardes. Garde uniquement ce qui aide à comprendre, décider, agir, attendre, corriger une erreur ou utiliser l’accessibilité.
- Vérifie MacBook Air `1440 × 900`, une fenêtre étroite et une fenêtre redimensionnée. Contrôle contraste, lisibilité, clavier, focus, zones d’interaction et information indépendante de la couleur.

## Développement et définition de terminé

- Utilise SwiftUI et les frameworks Apple existants, avec la solution la plus simple et les dépendances justifiées.
- Après une modification, vérifie les cas pertinents : première permission caméra, refus, caméra indisponible, absence de pose, erreur d’inférence, redimensionnement et fonctionnement en arrière-plan.
- Distingue compilation, tests, rendu macOS, permissions et fonctionnement réel de la caméra. Un build réussi ne prouve pas la précision de posture en conditions réelles.
- Une tâche n’est terminée qu’après implémentation, inspection du résultat, correction des échecs liés à la tâche, vérifications adaptées, relecture du diff et rapport des limites restantes.
- Une demande d’audit, de conseil ou de lecture seule n’autorise aucune modification.

## Communication

- Réponds en français, simplement et directement. Commence par la conclusion utile.
- Pour un audit ou un diagnostic, sépare faits vérifiés, hypothèses, causes écartées et inconnues.
- Ne t’arrête pas après le premier patch si l’objectif inclut l’exécution, l’inspection et la correction.
