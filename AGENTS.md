# Align contributor guide

## Product boundaries

- Align is a native macOS posture assistant designed for a single local user.
- Camera frames and derived posture data stay on the device.
- The primary workflow lives in the menu bar, with a compact expandable window.
- `Automatic` is the normal posture mode; seated and standing modes are manual overrides.
- Missing, stale, or low-confidence observations must never trigger corrective feedback.
- A head-to-shoulder ratio is an ambiguous posture signal, not a medical diagnosis.

## Engineering constraints

- Target a MacBook Air with Apple silicon and 8 GB of memory.
- Keep capture, pose inference, signal evaluation, persistence, and presentation separated.
- Allow only one inference of each kind in flight and measure performance before changing cadence or resolution.
- Treat the current RTMPose path as the production pose engine. Experimental engines must be clearly isolated and documented.
- Never add camera frames, health exports, credentials, identifiers, or other sensitive data to source control or logs.

## Git et sauvegardes — IMPORTANT, À CHAQUE TÂCHE

- Règle obligatoire pour chaque agent : toute nouvelle feature, correction ou refactor significatif commence sur une branche dédiée créée depuis `main` à jour. Ne travaille jamais directement sur `main`.
- Avant de modifier, vérifie la branche, l’état Git, les worktrees et les changements existants. Préserve toujours les modifications non liées ; ne change pas de branche et ne supprime rien si un travail non enregistré peut être concerné.
- Un lot cohérent = une branche. Pour le travail parallèle, sépare les worktrees et les fichiers afin d’éviter les conflits. N’utilise jamais `reset`, force push, écrasement d’historique ou rebase destructif sans ordre explicite.
- Avant de sauvegarder, inspecte le diff, les fichiers sensibles et les chemins ajoutés. Crée un commit clair et ciblé, puis vérifie les contrôles pertinents.
- Le workflow normal est : branche → modifications → commit → push de la branche → Pull Request vers `main` → CI verte (`lint`, `typecheck`, tests, build) → merge. Un push n’est pas un merge.
- Ne pousse jamais directement sur `main`. Le push, la PR, le merge, la suppression distante, la publication et le déploiement exigent un ordre explicite.
- Après un merge confirmé, supprime la branche locale et distante seulement si elle ne contient plus de travail unique, n’a pas de worktree actif et n’est pas douteuse. Ne supprime jamais une branche non fusionnée ou en cours ; les commits déjà dans `main` restent conservés.
- Après chaque opération GitHub, vérifie séparément la branche distante, le commit de `main`, la CI et l’état final du dépôt. Si une vérification manque, dis-le clairement.
- N’exécute pas `pnpm install`, `pnpm verify` ou un build Next pendant qu’un serveur `next dev` utilise le même checkout. Pour la vérification complète, utilise `CI=true pnpm verify`.
## Interface

- Use compact, native macOS controls and make the camera preview the main visual element.
- Avoid decorative cards, oversized headings, gratuitous gradients, and duplicated status text.
- Every visible label must help the user understand state, decide, or act.
- Check resizing, keyboard navigation, focus visibility, contrast, and information that must not rely on color alone.


## Publishing

- Do not push, publish releases, rewrite history, or change external services without explicit approval.
- Preserve all third-party notices and do not claim a model licence that is not documented by its distributor.
