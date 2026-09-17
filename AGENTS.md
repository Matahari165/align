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

## Interface

- Use compact, native macOS controls and make the camera preview the main visual element.
- Avoid decorative cards, oversized headings, gratuitous gradients, and duplicated status text.
- Every visible label must help the user understand state, decide, or act.
- Check resizing, keyboard navigation, focus visibility, contrast, and information that must not rely on color alone.

## Development workflow

- Inspect the branch and working tree before editing, and preserve unrelated work.
- Prefer the smallest change that solves the problem; do not add dependencies without a clear benefit.
- Keep generated files, local Xcode state, and personal data out of Git.
- Run the relevant harnesses and a Release build after substantive changes.
- Distinguish static checks, compilation, deterministic harnesses, real camera behavior, and measured performance.
- A successful build does not prove posture accuracy, notification delivery, or all-day resource usage.
- Review the final diff and document anything that could not be verified.

## Publishing

- Do not push, publish releases, rewrite history, or change external services without explicit approval.
- Preserve all third-party notices and do not claim a model licence that is not documented by its distributor.
