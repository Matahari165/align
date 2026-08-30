#!/usr/bin/env python3
"""Benchmark local et jetable de MediaPipe Pose pour Align.

Le script lit la webcam en memoire, n'enregistre aucune image et n'ecrit aucun
rapport. Les imports lourds restent locaux a ``run_camera`` afin que
``--dry-run`` teste les calculs sans camera ni dependance MediaPipe/OpenCV.
"""

from __future__ import annotations

import argparse
import hashlib
import math
import statistics
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Sequence


LEFT_SHOULDER = 11
RIGHT_SHOULDER = 12
NOSE = 0


@dataclass(frozen=True)
class Point:
    x: float
    y: float


@dataclass
class LossTracker:
    losses: int = 0
    missing_since: float | None = None
    recoveries: list[float] = field(default_factory=list)
    longest_interruption: float = 0.0
    has_seen_present: bool = False

    def update(self, present: bool, now: float) -> None:
        if present:
            self.has_seen_present = True
            if self.missing_since is not None:
                duration = max(0.0, now - self.missing_since)
                self.recoveries.append(duration)
                self.longest_interruption = max(self.longest_interruption, duration)
                self.missing_since = None
            return
        if self.has_seen_present and self.missing_since is None:
            self.losses += 1
            self.missing_since = now

    def finish(self, now: float) -> None:
        if self.missing_since is not None:
            self.longest_interruption = max(
                self.longest_interruption,
                max(0.0, now - self.missing_since),
            )
            self.missing_since = None


@dataclass
class PhaseMetrics:
    name: str
    attempts: int = 0
    both_shoulders: int = 0
    latencies_ms: list[float] = field(default_factory=list)
    jitter_ratios: list[float] = field(default_factory=list)
    shoulder_angles: list[float] = field(default_factory=list)
    head_axis_angles: list[float] = field(default_factory=list)
    inference_errors: int = 0
    losses: LossTracker = field(default_factory=LossTracker)
    previous_shoulders: tuple[Point, Point] | None = None

    def record(
        self,
        now: float,
        latency_ms: float,
        shoulders: tuple[Point, Point] | None,
        nose: Point | None = None,
    ) -> None:
        self.attempts += 1
        self.latencies_ms.append(latency_ms)
        present = shoulders is not None
        self.losses.update(present, now)
        if shoulders is None:
            self.previous_shoulders = None
            return

        self.both_shoulders += 1
        left, right = shoulders
        self.shoulder_angles.append(undirected_angle_degrees(left, right))
        if nose is not None:
            middle = Point((left.x + right.x) / 2, (left.y + right.y) / 2)
            self.head_axis_angles.append(
                math.degrees(math.atan2(nose.x - middle.x, middle.y - nose.y))
            )
        if self.previous_shoulders is not None:
            previous_left, previous_right = self.previous_shoulders
            width = distance(left, right)
            if width > 1e-6:
                displacement = (
                    distance(previous_left, left) + distance(previous_right, right)
                ) / 2
                self.jitter_ratios.append(displacement / width)
        self.previous_shoulders = shoulders

    def record_error(self, now: float, latency_ms: float) -> None:
        self.attempts += 1
        self.inference_errors += 1
        self.latencies_ms.append(latency_ms)
        self.losses.update(False, now)

    def finish(self, now: float) -> None:
        self.losses.finish(now)


@dataclass(frozen=True)
class Phase:
    name: str
    instruction: str


PHASES = (
    Phase("normal", "Assis normalement, reste immobile"),
    Phase("loin", "Recule a une distance confortable, reste immobile"),
    Phase("mac_bas", "Debout, regarde le Mac pose plus bas"),
)


def distance(first: Point, second: Point) -> float:
    return math.hypot(first.x - second.x, first.y - second.y)


def undirected_angle_degrees(first: Point, second: Point) -> float:
    angle = math.degrees(math.atan2(second.y - first.y, second.x - first.x))
    return (angle + 90) % 180 - 90


def percentile(values: Sequence[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    rank = max(0, min(len(ordered) - 1, math.ceil(fraction * len(ordered)) - 1))
    return ordered[rank]


def current_phase(elapsed: float, phase_seconds: float) -> tuple[int, float] | None:
    if elapsed < 0:
        return 0, phase_seconds
    index = int(elapsed // phase_seconds)
    if index >= len(PHASES):
        return None
    remaining = phase_seconds - (elapsed - index * phase_seconds)
    return index, remaining


def landmark_score(landmark: object) -> float | None:
    scores = []
    for name in ("visibility", "presence"):
        raw = getattr(landmark, name, None)
        if raw is not None:
            try:
                value = float(raw)
            except (TypeError, ValueError):
                continue
            if math.isfinite(value):
                scores.append(value)
    return min(scores) if scores else None


def normalized_point(landmark: object) -> Point | None:
    try:
        point = Point(float(getattr(landmark, "x")), float(getattr(landmark, "y")))
    except (AttributeError, TypeError, ValueError):
        return None
    if not math.isfinite(point.x) or not math.isfinite(point.y):
        return None
    if not 0 <= point.x <= 1 or not 0 <= point.y <= 1:
        return None
    return point


def usable_point(landmarks: Sequence[object], index: int, minimum_score: float) -> Point | None:
    if index < 0 or index >= len(landmarks):
        return None
    landmark = landmarks[index]
    score = landmark_score(landmark)
    if score is None or score < minimum_score:
        return None
    return normalized_point(landmark)


def mirror_pixel(x: float, size: int) -> int:
    return int((1 - x) * max(0, size - 1))


def format_optional(value: float | None, suffix: str = "") -> str:
    return "—" if value is None else f"{value:.1f}{suffix}"


def report(phases: Iterable[PhaseMetrics]) -> str:
    lines = [
        "MediaPipe Pose Landmarker — benchmark local Align",
        "Le milieu des epaules est estime, pas mesure comme une articulation.",
    ]
    for metrics in phases:
        rate = 100 * metrics.both_shoulders / metrics.attempts if metrics.attempts else None
        mean_recovery = (
            statistics.fmean(metrics.losses.recoveries)
            if metrics.losses.recoveries
            else None
        )
        jitter = (
            100 * statistics.median(metrics.jitter_ratios)
            if metrics.jitter_ratios
            else None
        )
        lines.extend(
            [
                "",
                f"Phase {metrics.name}",
                f"  Deux epaules : {metrics.both_shoulders}/{metrics.attempts} "
                f"({format_optional(rate, ' %')})",
                f"  Erreurs d'inference : {metrics.inference_errors}",
                f"  Pertes : {metrics.losses.losses} · interruption max "
                f"{metrics.losses.longest_interruption:.2f} s · recuperation moyenne "
                f"{format_optional(mean_recovery, ' s')}",
                f"  Jitter median : {format_optional(jitter, ' % de la largeur des epaules')}",
                f"  Ligne des epaules mediane : "
                f"{format_optional(statistics.median(metrics.shoulder_angles) if metrics.shoulder_angles else None, ' deg')}",
                f"  Axe tete/epaules median : "
                f"{format_optional(statistics.median(metrics.head_axis_angles) if metrics.head_axis_angles else None, ' deg')}",
                f"  Latence p50/p95/max : "
                f"{format_optional(percentile(metrics.latencies_ms, 0.50), ' ms')} / "
                f"{format_optional(percentile(metrics.latencies_ms, 0.95), ' ms')} / "
                f"{format_optional(max(metrics.latencies_ms) if metrics.latencies_ms else None, ' ms')}",
            ]
        )
    return "\n".join(lines)


def draw_overlay(cv2: object, frame: object, landmarks: Sequence[object], minimum_score: float) -> None:
    height, width = frame.shape[:2]

    def screen_point(index: int) -> tuple[int, int] | None:
        point = usable_point(landmarks, index, minimum_score)
        if point is None:
            return None
        # L'image est retournee horizontalement pour offrir un apercu miroir.
        return mirror_pixel(point.x, width), int(point.y * (height - 1))

    left = screen_point(LEFT_SHOULDER)
    right = screen_point(RIGHT_SHOULDER)
    nose = screen_point(NOSE)
    for point in (left, right):
        if point is not None:
            cv2.circle(frame, point, 7, (70, 220, 70), -1, cv2.LINE_AA)
    if left is None or right is None:
        return

    middle = ((left[0] + right[0]) // 2, (left[1] + right[1]) // 2)
    cv2.line(frame, left, right, (70, 220, 70), 2, cv2.LINE_AA)
    cv2.circle(frame, middle, 5, (0, 190, 255), -1, cv2.LINE_AA)
    cv2.putText(
        frame,
        "milieu estime",
        (middle[0] + 8, middle[1] - 8),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.45,
        (0, 190, 255),
        1,
        cv2.LINE_AA,
    )
    if nose is not None:
        cv2.line(frame, nose, middle, (255, 190, 40), 2, cv2.LINE_AA)


def run_camera(args: argparse.Namespace) -> int:
    try:
        import cv2
        import mediapipe as mp
        from mediapipe.tasks import python as mp_python
        from mediapipe.tasks.python import vision
    except ImportError as error:
        print(
            "Dependance absente. Installe mediapipe et opencv-python dans un "
            "environnement virtuel dedie.",
            file=sys.stderr,
        )
        print(f"Detail : {error}", file=sys.stderr)
        return 2

    model_path = Path(args.model).expanduser().resolve()
    if not model_path.is_file():
        print(f"Modele introuvable : {model_path}", file=sys.stderr)
        return 2
    model_hash = hashlib.sha256(model_path.read_bytes()).hexdigest()

    options = vision.PoseLandmarkerOptions(
        base_options=mp_python.BaseOptions(
            model_asset_path=str(model_path),
            delegate=mp_python.BaseOptions.Delegate.CPU,
        ),
        running_mode=vision.RunningMode.VIDEO,
        num_poses=1,
        min_pose_detection_confidence=args.minimum_score,
        min_pose_presence_confidence=args.minimum_score,
        min_tracking_confidence=args.minimum_score,
        output_segmentation_masks=False,
    )
    capture = cv2.VideoCapture(args.camera_index)
    if not capture.isOpened():
        capture.release()
        print("Camera indisponible ou permission refusee.", file=sys.stderr)
        return 2
    capture.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
    capture.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
    capture.set(cv2.CAP_PROP_FPS, 15)
    actual_width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH))
    actual_height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
    actual_fps = capture.get(cv2.CAP_PROP_FPS)

    metrics = [PhaseMetrics(phase.name) for phase in PHASES]
    started_at: float | None = None
    active_phase_index: int | None = None
    last_timestamp_ms = -1
    last_analysis_at: float | None = None
    latest_landmarks: Sequence[object] | None = None
    latest_landmarks_at: float | None = None
    frames_received = 0
    frames_submitted = 0
    frames_skipped = 0
    analysis_interval = 1 / args.analysis_hz
    print("Aucune image ne sera enregistree. Espace : demarrer · Q : quitter.")

    try:
        with vision.PoseLandmarker.create_from_options(options) as landmarker:
            while True:
                ok, frame = capture.read()
                if not ok:
                    print("Lecture camera interrompue.", file=sys.stderr)
                    for item in metrics:
                        item.finish(time.monotonic())
                    break
                now = time.monotonic()
                mirrored = cv2.flip(frame, 1)

                if started_at is None:
                    cv2.putText(
                        mirrored,
                        "Espace pour demarrer le benchmark",
                        (24, 40),
                        cv2.FONT_HERSHEY_SIMPLEX,
                        0.7,
                        (255, 255, 255),
                        2,
                        cv2.LINE_AA,
                    )
                else:
                    frames_received += 1
                    phase_state = current_phase(now - started_at, args.phase_seconds)
                    if phase_state is None:
                        for item in metrics:
                            item.finish(now)
                        break
                    phase_index, remaining = phase_state
                    if active_phase_index is not None and phase_index != active_phase_index:
                        metrics[active_phase_index].finish(now)
                    active_phase_index = phase_index
                    phase = PHASES[phase_index]
                    analysis_due = last_analysis_at is None or now - last_analysis_at >= analysis_interval
                    if analysis_due:
                        frames_submitted += 1
                        last_analysis_at = now
                        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                        image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
                        timestamp_ms = max(last_timestamp_ms + 1, int(now * 1_000))
                        last_timestamp_ms = timestamp_ms
                        inference_start = time.perf_counter()
                        try:
                            result = landmarker.detect_for_video(image, timestamp_ms)
                            latency_ms = (time.perf_counter() - inference_start) * 1_000
                            landmarks = result.pose_landmarks[0] if result.pose_landmarks else None
                            latest_landmarks = landmarks
                            latest_landmarks_at = now if landmarks is not None else None
                            left = usable_point(landmarks or (), LEFT_SHOULDER, args.minimum_score)
                            right = usable_point(landmarks or (), RIGHT_SHOULDER, args.minimum_score)
                            nose = usable_point(landmarks or (), NOSE, args.minimum_score)
                            shoulders = (left, right) if left is not None and right is not None else None
                            metrics[phase_index].record(now, latency_ms, shoulders, nose)
                        except Exception as error:  # MediaPipe expose plusieurs types d'erreurs runtime.
                            latency_ms = (time.perf_counter() - inference_start) * 1_000
                            metrics[phase_index].record_error(now, latency_ms)
                            latest_landmarks = None
                            latest_landmarks_at = None
                            print(f"Erreur MediaPipe non fatale : {error}", file=sys.stderr)
                    else:
                        frames_skipped += 1

                    if (
                        latest_landmarks is not None
                        and latest_landmarks_at is not None
                        and now - latest_landmarks_at <= max(0.30, analysis_interval * 1.2)
                    ):
                        draw_overlay(cv2, mirrored, latest_landmarks, args.minimum_score)
                    cv2.putText(
                        mirrored,
                        f"{phase_index + 1}/3 {phase.instruction} ({remaining:.0f} s)",
                        (24, 40),
                        cv2.FONT_HERSHEY_SIMPLEX,
                        0.62,
                        (255, 255, 255),
                        2,
                        cv2.LINE_AA,
                    )

                cv2.imshow("Align — MediaPipe Pose Spike", mirrored)
                key = cv2.waitKey(1) & 0xFF
                if key in (ord("q"), 27):
                    if started_at is not None:
                        for item in metrics:
                            item.finish(now)
                    break
                if key == ord(" ") and started_at is None:
                    started_at = now
    finally:
        capture.release()
        cv2.destroyAllWindows()

    if started_at is not None:
        print(
            "\n"
            f"Modele : {model_path.name} · sha256 {model_hash}\n"
            f"Camera demandee 1280x720 @15 fps · recue {actual_width}x{actual_height} "
            f"@{actual_fps:.1f} fps\n"
            f"Frames recues/soumises/ignorees par cadence : "
            f"{frames_received}/{frames_submitted}/{frames_skipped}\n"
            + report(metrics)
        )
    return 0


def run_dry_tests() -> int:
    def check(condition: bool, message: str) -> None:
        if not condition:
            raise AssertionError(message)

    check(percentile([], 0.95) is None, "percentile vide")
    check(percentile([10, 20, 30, 40], 0.50) == 20, "p50")
    check(percentile([10, 20, 30, 40], 0.95) == 40, "p95")
    check(current_phase(0, 20) == (0, 20), "debut phase")
    check(current_phase(19.5, 20) == (0, 0.5), "fin phase")
    check(current_phase(20, 20) == (1, 20), "transition phase")
    check(current_phase(60, 20) is None, "fin benchmark")

    tracker = LossTracker()
    tracker.update(True, 0.0)
    tracker.update(False, 1.0)
    tracker.update(False, 1.5)
    tracker.update(True, 2.0)
    check(tracker.losses == 1, "une perte apres presence")
    check(tracker.recoveries == [1.0], "recuperation apres perte")

    phase = PhaseMetrics("test")
    phase.record(0.0, 10, (Point(0.2, 0.5), Point(0.8, 0.5)))
    phase.record(1.0, 20, (Point(0.21, 0.5), Point(0.81, 0.5)))
    phase.record(2.0, 30, None)
    phase.record(3.0, 40, (Point(0.2, 0.5), Point(0.8, 0.5)))
    phase.finish(3.0)
    check(phase.attempts == 4, "tentatives")
    check(phase.both_shoulders == 3, "presences")
    check(phase.losses.losses == 1, "pertes phase")
    check(phase.losses.recoveries == [1.0], "recuperation phase")
    check(len(phase.jitter_ratios) == 1, "echantillon jitter")
    check(abs(phase.jitter_ratios[0] - (0.01 / 0.6)) < 1e-9, "valeur jitter")
    check("3/4" in report([phase]), "rapport presence")
    first_missing = LossTracker()
    first_missing.update(False, 0.0)
    first_missing.update(True, 1.0)
    check(first_missing.losses == 0, "absence initiale non comptee comme perte")

    class FakeLandmark:
        def __init__(self, x: float, y: float, visibility: float | None = 1.0):
            self.x = x
            self.y = y
            self.visibility = visibility
            self.presence = None

    landmarks = [FakeLandmark(0.5, 0.5) for _ in range(13)]
    check(usable_point(landmarks, LEFT_SHOULDER, 0.5) == Point(0.5, 0.5), "point valide")
    landmarks[LEFT_SHOULDER] = FakeLandmark(math.nan, 0.5)
    check(usable_point(landmarks, LEFT_SHOULDER, 0.5) is None, "NaN rejete")
    check(usable_point([], LEFT_SHOULDER, 0.5) is None, "index absent")
    check(undirected_angle_degrees(Point(0, 0), Point(1, 0)) == 0, "angle horizontal")
    check(mirror_pixel(0, 640) == 639 and mirror_pixel(1, 640) == 0, "miroir aux bords")

    error_phase = PhaseMetrics("error")
    error_phase.record(0.0, 10, (Point(0.2, 0.5), Point(0.8, 0.5)))
    error_phase.record_error(1.0, 20)
    error_phase.record(2.0, 10, (Point(0.2, 0.5), Point(0.8, 0.5)))
    check(error_phase.inference_errors == 1, "erreur separee")
    check(error_phase.losses.losses == 1, "erreur apres presence ouvre une perte")
    check(error_phase.losses.recoveries == [1.0], "recuperation apres erreur")
    print("mediapipe_pose_spike --dry-run: OK")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", help="Chemin local vers pose_landmarker_lite.task")
    parser.add_argument("--camera-index", type=int, default=0)
    parser.add_argument("--phase-seconds", type=float, default=20.0)
    parser.add_argument("--minimum-score", type=float, default=0.5)
    parser.add_argument(
        "--analysis-hz",
        type=float,
        default=1.0,
        help="Nombre d'analyses par seconde (defaut : 1).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Teste les calculs purs sans camera, MediaPipe ni OpenCV.",
    )
    args = parser.parse_args()
    if not args.dry_run and not args.model:
        parser.error("--model est obligatoire hors --dry-run")
    if not math.isfinite(args.phase_seconds) or args.phase_seconds <= 0:
        parser.error("--phase-seconds doit etre fini et strictement positif")
    if not 0 <= args.minimum_score <= 1:
        parser.error("--minimum-score doit etre compris entre 0 et 1")
    if not math.isfinite(args.analysis_hz) or args.analysis_hz <= 0:
        parser.error("--analysis-hz doit etre fini et strictement positif")
    if args.camera_index < 0:
        parser.error("--camera-index ne peut pas etre negatif")
    return args


def main() -> int:
    args = parse_args()
    return run_dry_tests() if args.dry_run else run_camera(args)


if __name__ == "__main__":
    raise SystemExit(main())
