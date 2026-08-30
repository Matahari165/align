#!/usr/bin/env python3
"""Comparaison temporaire MediaPipe/LiteRT sur les mêmes octets RGB.

Aucune frame, image ou coordonnée individuelle n'est enregistrée. Le processus
LiteRT reste vivant pendant toute la session et garde les deux modèles chargés.
"""

from __future__ import annotations

import argparse
import io
import math
import statistics
import struct
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

from mediapipe_pose_spike import Phase, Point, percentile, usable_point


FRAME_HEADER = struct.Struct("<IIIQ")
NATIVE_RESULT = struct.Struct("<IIQd25f")
FRAME_MAGIC = 0x414C474E
RESULT_MAGIC = 0x52534C54
FRAME_STATUS_TECHNICAL_ERROR = 0
FRAME_STATUS_NO_PERSON = 1
FRAME_STATUS_DETECTED = 2
PHASES = (
    Phase("normal_proche", "Assis a ta distance normale, reste immobile"),
    Phase("tres_proche_a", "Rapproche-toi au maximum, reste immobile"),
    Phase("tres_proche_b", "Reste tres proche pour la seconde mesure"),
)
MIN_FACE_SPAN_PX = 12.0
MAX_FACE_RESIDUAL_PX = 12.0
MIN_SIMILARITY_SCALE = 0.85
MAX_SIMILARITY_SCALE = 1.15
MAX_SIMILARITY_ROTATION_DEGREES = 10.0
MIN_AB_ATTEMPTS = 30
MIN_FACE_COVERAGE = 0.80
MIN_TRANSLATION_IMPROVEMENT = 0.20


@dataclass(frozen=True)
class Registration:
    scale: float
    cosine: float
    sine: float
    translation_x: float
    translation_y: float
    residual_px: float


@dataclass(frozen=True)
class NativeShoulders:
    left: Point | None
    right: Point | None
    left_confidence: float
    right_confidence: float

    @property
    def pair(self) -> tuple[Point, Point] | None:
        if self.left is None or self.right is None:
            return None
        return self.left, self.right

    @property
    def state(self) -> str:
        count = int(self.left is not None) + int(self.right is not None)
        return "detected" if count == 2 else "partial" if count == 1 else "lost"


@dataclass
class ComparisonMetrics:
    name: str
    attempts: int = 0
    reference_present: int = 0
    native_present: int = 0
    both_present: int = 0
    both_absent: int = 0
    native_only: int = 0
    reference_only: int = 0
    shoulder_errors_px: list[float] = field(default_factory=list)
    left_dx_px: list[float] = field(default_factory=list)
    left_dy_px: list[float] = field(default_factory=list)
    right_dx_px: list[float] = field(default_factory=list)
    right_dy_px: list[float] = field(default_factory=list)
    swapped_errors_px: list[float] = field(default_factory=list)
    mirrored_errors_px: list[float] = field(default_factory=list)
    mirrored_swapped_errors_px: list[float] = field(default_factory=list)
    shoulder_span_ratios: list[float] = field(default_factory=list)
    shoulder_errors_span_percent: list[float] = field(default_factory=list)
    translated_errors_span_percent: list[float] = field(default_factory=list)
    translation_direct_errors_span_percent: list[float] = field(default_factory=list)
    midpoint_dx_px: list[float] = field(default_factory=list)
    midpoint_dy_px: list[float] = field(default_factory=list)
    roi_center_dx_px: list[float] = field(default_factory=list)
    roi_center_dy_px: list[float] = field(default_factory=list)
    roi_width_px: list[float] = field(default_factory=list)
    roi_height_px: list[float] = field(default_factory=list)
    roi_rotation_degrees: list[float] = field(default_factory=list)
    raw_shoulder_errors_px: list[float] = field(default_factory=list)
    raw_midpoint_dx_px: list[float] = field(default_factory=list)
    raw_midpoint_dy_px: list[float] = field(default_factory=list)
    translated_errors_px: list[float] = field(default_factory=list)
    translation_direct_errors_px: list[float] = field(default_factory=list)
    similarity_errors_px: list[float] = field(default_factory=list)
    registration_translation_px: list[float] = field(default_factory=list)
    similarity_scales: list[float] = field(default_factory=list)
    similarity_rotations_degrees: list[float] = field(default_factory=list)
    similarity_residuals_px: list[float] = field(default_factory=list)
    face_pairs: int = 0
    translation_accepted: int = 0
    similarity_accepted: int = 0
    face_geometry_rejected: int = 0
    translation_residual_rejected: int = 0
    similarity_bounds_rejected: int = 0
    native_invalid_outputs: int = 0
    native_technical_errors: int = 0
    native_no_person: int = 0
    native_low_confidence: int = 0
    native_latencies_ms: list[float] = field(default_factory=list)
    losses: int = 0
    missing_since: float | None = None
    recovery_seconds: list[float] = field(default_factory=list)
    longest_loss: float = 0.0
    has_seen_native: bool = False

    def record(
        self,
        now: float,
        width: int,
        height: int,
        reference: tuple[Point, Point] | None,
        native: tuple[Point, Point] | None,
        native_latency_ms: float,
        native_roi: tuple[float, float, float, float, float] | None = None,
        native_raw: tuple[Point, Point] | None = None,
        reference_face: tuple[Point, Point, Point] | None = None,
        native_face: tuple[Point, Point, Point] | None = None,
        native_status: int = FRAME_STATUS_DETECTED,
    ) -> None:
        if native_status == FRAME_STATUS_TECHNICAL_ERROR:
            self.native_invalid_outputs += 1
            self.native_technical_errors += 1
            return
        if native_status == FRAME_STATUS_NO_PERSON:
            self.native_no_person += 1
        elif native_status == FRAME_STATUS_DETECTED and native is None:
            self.native_low_confidence += 1
        self.attempts += 1
        self.native_latencies_ms.append(native_latency_ms)
        if reference is not None:
            self.reference_present += 1
        if native is not None:
            self.native_present += 1
            self.has_seen_native = True
            if reference is not None and self.missing_since is not None:
                duration = max(0.0, now - self.missing_since)
                self.recovery_seconds.append(duration)
                self.longest_loss = max(self.longest_loss, duration)
                self.missing_since = None
        elif (
            reference is not None
            and self.has_seen_native
            and self.missing_since is None
        ):
            self.losses += 1
            self.missing_since = now

        if reference is not None and native is not None:
            self.both_present += 1
            reference_left, reference_right = reference
            native_left, native_right = native
            signed_pairs = (
                (reference_left, native_left, self.left_dx_px, self.left_dy_px),
                (reference_right, native_right, self.right_dx_px, self.right_dy_px),
            )
            for expected, actual, dx_values, dy_values in signed_pairs:
                dx = (actual.x - expected.x) * width
                dy = (actual.y - expected.y) * height
                dx_values.append(dx)
                dy_values.append(dy)
                self.shoulder_errors_px.append(
                    math.hypot(dx, dy)
                )
            self.swapped_errors_px.extend(
                shoulder_pair_errors(reference, (native_right, native_left), width, height)
            )
            mirrored = (
                Point(1.0 - native_left.x, native_left.y),
                Point(1.0 - native_right.x, native_right.y),
            )
            self.mirrored_errors_px.extend(
                shoulder_pair_errors(reference, mirrored, width, height)
            )
            self.mirrored_swapped_errors_px.extend(
                shoulder_pair_errors(reference, (mirrored[1], mirrored[0]), width, height)
            )
            reference_span = math.hypot(
                (reference_left.x - reference_right.x) * width,
                (reference_left.y - reference_right.y) * height,
            )
            native_span = math.hypot(
                (native_left.x - native_right.x) * width,
                (native_left.y - native_right.y) * height,
            )
            if reference_span > 1e-6:
                self.shoulder_span_ratios.append(native_span / reference_span)
                self.shoulder_errors_span_percent.extend(
                    100.0 * error / reference_span
                    for error in shoulder_pair_errors(
                        reference, native, width, height
                    )
                )
            reference_midpoint = Point(
                (reference_left.x + reference_right.x) * 0.5,
                (reference_left.y + reference_right.y) * 0.5,
            )
            native_midpoint = Point(
                (native_left.x + native_right.x) * 0.5,
                (native_left.y + native_right.y) * 0.5,
            )
            self.midpoint_dx_px.append(
                (native_midpoint.x - reference_midpoint.x) * width
            )
            self.midpoint_dy_px.append(
                (native_midpoint.y - reference_midpoint.y) * height
            )
            if native_roi is not None:
                roi_x, roi_y, roi_width, roi_height, roi_rotation = native_roi
                self.roi_center_dx_px.append((roi_x - reference_midpoint.x) * width)
                self.roi_center_dy_px.append((roi_y - reference_midpoint.y) * height)
                self.roi_width_px.append(roi_width * width)
                self.roi_height_px.append(roi_height * height)
                self.roi_rotation_degrees.append(math.degrees(roi_rotation))
            if native_raw is not None:
                self.raw_shoulder_errors_px.extend(
                    shoulder_pair_errors(reference, native_raw, width, height)
                )
                raw_midpoint = Point(
                    (native_raw[0].x + native_raw[1].x) * 0.5,
                    (native_raw[0].y + native_raw[1].y) * 0.5,
                )
                self.raw_midpoint_dx_px.append(
                    (raw_midpoint.x - reference_midpoint.x) * width
                )
                self.raw_midpoint_dy_px.append(
                    (raw_midpoint.y - reference_midpoint.y) * height
                )
            if reference_face is not None and native_face is not None:
                self.face_pairs += 1
                if not face_geometry_usable(
                    reference_face, native_face, width, height
                ):
                    self.face_geometry_rejected += 1
                    return
                translation = fit_translation(
                    native_face, reference_face, width, height
                )
                similarity = fit_similarity(
                    native_face, reference_face, width, height
                )
                if (translation is not None and
                        translation.residual_px <= MAX_FACE_RESIDUAL_PX):
                    direct_errors = shoulder_pair_errors(
                        reference, native, width, height
                    )
                    translated = apply_registration_to_normalized_pair(
                        native, translation, width, height
                    )
                    self.translated_errors_px.extend(
                        translated_errors := shoulder_pair_errors(
                            reference, translated, width, height
                        )
                    )
                    self.translation_direct_errors_px.extend(direct_errors)
                    if reference_span > 1e-6:
                        self.translation_direct_errors_span_percent.extend(
                            100.0 * error / reference_span
                            for error in direct_errors
                        )
                        self.translated_errors_span_percent.extend(
                            100.0 * error / reference_span
                            for error in translated_errors
                        )
                    self.registration_translation_px.append(
                        math.hypot(
                            translation.translation_x,
                            translation.translation_y,
                        )
                    )
                    self.translation_accepted += 1
                elif translation is not None:
                    self.translation_residual_rejected += 1
                if similarity_acceptable(similarity):
                    fitted = apply_registration_to_normalized_pair(
                        native, similarity, width, height
                    )
                    self.similarity_errors_px.extend(
                        shoulder_pair_errors(reference, fitted, width, height)
                    )
                    self.similarity_scales.append(similarity.scale)
                    self.similarity_rotations_degrees.append(
                        math.degrees(math.atan2(similarity.sine, similarity.cosine))
                    )
                    self.similarity_residuals_px.append(similarity.residual_px)
                    self.similarity_accepted += 1
                elif similarity is not None:
                    self.similarity_bounds_rejected += 1
        elif reference is not None:
            self.reference_only += 1
        elif native is not None:
            self.native_only += 1
        else:
            self.both_absent += 1

    def finish(self, now: float) -> None:
        if self.missing_since is not None:
            self.longest_loss = max(self.longest_loss, now - self.missing_since)
            self.missing_since = None


def read_exact(stream: object, byte_count: int) -> bytes:
    chunks: list[bytes] = []
    remaining = byte_count
    while remaining:
        chunk = stream.read(remaining)
        if not chunk:
            raise RuntimeError("Le processus LiteRT a ferme son flux de sortie.")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def pixel_points(points: tuple[Point, ...], width: int, height: int) -> list[Point]:
    return [Point(point.x * width, point.y * height) for point in points]


def face_geometry_usable(
    reference: tuple[Point, ...], native: tuple[Point, ...],
    width: int, height: int,
) -> bool:
    if len(reference) != 3 or len(native) != 3:
        return False
    for face in (reference, native):
        if any(not math.isfinite(point.x) or not math.isfinite(point.y)
               for point in face):
            return False
        pixels = pixel_points(face, width, height)
        if math.hypot(pixels[0].x - pixels[1].x,
                      pixels[0].y - pixels[1].y) < MIN_FACE_SPAN_PX:
            return False
    return True


def similarity_acceptable(registration: Registration | None) -> bool:
    if registration is None:
        return False
    rotation = abs(math.degrees(math.atan2(
        registration.sine, registration.cosine
    )))
    return (
        MIN_SIMILARITY_SCALE <= registration.scale <= MAX_SIMILARITY_SCALE
        and rotation <= MAX_SIMILARITY_ROTATION_DEGREES
        and registration.residual_px <= MAX_FACE_RESIDUAL_PX
    )


def normalized_contract_point(point: Point) -> bool:
    return (math.isfinite(point.x) and math.isfinite(point.y) and
            0.0 <= point.x <= 1.0 and 0.0 <= point.y <= 1.0)


def unit_score(value: float) -> bool:
    return math.isfinite(value) and 0.0 <= value <= 1.0


def fit_translation(
    source: tuple[Point, ...], target: tuple[Point, ...], width: int, height: int
) -> Registration | None:
    if len(source) != len(target) or len(source) < 2:
        return None
    source_px = pixel_points(source, width, height)
    target_px = pixel_points(target, width, height)
    tx = statistics.fmean(t.x - s.x for s, t in zip(source_px, target_px))
    ty = statistics.fmean(t.y - s.y for s, t in zip(source_px, target_px))
    residual = math.sqrt(statistics.fmean(
        (s.x + tx - t.x) ** 2 + (s.y + ty - t.y) ** 2
        for s, t in zip(source_px, target_px)
    ))
    return Registration(1.0, 1.0, 0.0, tx, ty, residual)


def fit_similarity(
    source: tuple[Point, ...], target: tuple[Point, ...], width: int, height: int
) -> Registration | None:
    if len(source) != len(target) or len(source) < 2:
        return None
    source_px = pixel_points(source, width, height)
    target_px = pixel_points(target, width, height)
    source_center = Point(statistics.fmean(p.x for p in source_px),
                          statistics.fmean(p.y for p in source_px))
    target_center = Point(statistics.fmean(p.x for p in target_px),
                          statistics.fmean(p.y for p in target_px))
    dot = cross = energy = 0.0
    for source_point, target_point in zip(source_px, target_px):
        sx, sy = source_point.x - source_center.x, source_point.y - source_center.y
        tx, ty = target_point.x - target_center.x, target_point.y - target_center.y
        dot += sx * tx + sy * ty
        cross += sx * ty - sy * tx
        energy += sx * sx + sy * sy
    magnitude = math.hypot(dot, cross)
    if energy <= 1e-9 or magnitude <= 1e-9:
        return None
    scale, cosine, sine = magnitude / energy, dot / magnitude, cross / magnitude
    translation_x = target_center.x - scale * (
        cosine * source_center.x - sine * source_center.y
    )
    translation_y = target_center.y - scale * (
        sine * source_center.x + cosine * source_center.y
    )
    registration = Registration(
        scale, cosine, sine, translation_x, translation_y, 0.0
    )
    squared = []
    for source_point, target_point in zip(source_px, target_px):
        fitted = apply_registration(source_point, registration)
        squared.append((fitted.x - target_point.x) ** 2 +
                       (fitted.y - target_point.y) ** 2)
    return Registration(scale, cosine, sine, translation_x, translation_y,
                        math.sqrt(statistics.fmean(squared)))


def apply_registration(point: Point, registration: Registration) -> Point:
    return Point(
        registration.scale *
        (registration.cosine * point.x - registration.sine * point.y) +
        registration.translation_x,
        registration.scale *
        (registration.sine * point.x + registration.cosine * point.y) +
        registration.translation_y,
    )


def apply_registration_to_normalized_pair(
    points: tuple[Point, Point], registration: Registration,
    width: int, height: int,
) -> tuple[Point, Point]:
    fitted = [
        apply_registration(Point(point.x * width, point.y * height), registration)
        for point in points
    ]
    return (Point(fitted[0].x / width, fitted[0].y / height),
            Point(fitted[1].x / width, fitted[1].y / height))


def native_frame(
    process: subprocess.Popen[bytes], frame_id: int, rgb: object
) -> tuple[
    NativeShoulders | None,
    float,
    tuple[float, float, float, float, float] | None,
    tuple[Point, Point] | None,
    tuple[Point, Point, Point] | None,
    int,
]:
    height, width = rgb.shape[:2]
    payload = memoryview(rgb).cast("B")
    process.stdin.write(FRAME_HEADER.pack(FRAME_MAGIC, width, height, frame_id))
    process.stdin.write(payload)
    process.stdin.flush()
    values = NATIVE_RESULT.unpack(read_exact(process.stdout, NATIVE_RESULT.size))
    (magic, status, returned_id, latency_ms, _pose, lx, ly, ls, rx, ry, rs,
     roi_x, roi_y, roi_width, roi_height, roi_rotation,
     raw_lx, raw_ly, raw_rx, raw_ry,
     eye_lx, eye_ly, eye_ls, eye_rx, eye_ry, eye_rs,
     nose_x, nose_y, nose_score) = values
    if magic != RESULT_MAGIC or returned_id != frame_id:
        raise RuntimeError("Reponse LiteRT desynchronisee.")
    if not math.isfinite(latency_ms) or latency_ms < 0.0:
        return None, 0.0, None, None, None, FRAME_STATUS_TECHNICAL_ERROR
    if status not in (FRAME_STATUS_TECHNICAL_ERROR, FRAME_STATUS_NO_PERSON,
                      FRAME_STATUS_DETECTED):
        return None, latency_ms, None, None, None, FRAME_STATUS_TECHNICAL_ERROR
    if status == FRAME_STATUS_TECHNICAL_ERROR:
        return None, latency_ms, None, None, None, FRAME_STATUS_TECHNICAL_ERROR
    if status == FRAME_STATUS_NO_PERSON:
        return None, latency_ms, None, None, None, FRAME_STATUS_NO_PERSON
    shoulders = (Point(lx, ly), Point(rx, ry))
    raw_shoulders = (Point(raw_lx, raw_ly), Point(raw_rx, raw_ry))
    face_points = (Point(eye_lx, eye_ly), Point(eye_rx, eye_ry),
                   Point(nose_x, nose_y))
    roi_valid = (
        math.isfinite(roi_x) and math.isfinite(roi_y) and
        math.isfinite(roi_width) and math.isfinite(roi_height) and
        math.isfinite(roi_rotation) and
        roi_width > 0.0 and roi_height > 0.0
    )
    scores_valid = all(unit_score(score) for score in (
        _pose, ls, rs, eye_ls, eye_rs, nose_score
    ))
    if (not roi_valid or not scores_valid or
            not all(math.isfinite(point.x) and math.isfinite(point.y)
                    for point in shoulders)):
        return None, latency_ms, None, None, None, FRAME_STATUS_TECHNICAL_ERROR
    left = shoulders[0] if ls >= 0.5 and normalized_contract_point(shoulders[0]) else None
    right = shoulders[1] if rs >= 0.5 and normalized_contract_point(shoulders[1]) else None
    native_shoulders = NativeShoulders(left, right, ls, rs)
    face = None
    if (min(eye_ls, eye_rs, nose_score) >= 0.5 and
            all(normalized_contract_point(point) for point in face_points)):
        face = face_points
    raw = raw_shoulders if all(
        normalized_contract_point(point) for point in raw_shoulders
    ) else None
    return (native_shoulders, latency_ms,
            (roi_x, roi_y, roi_width, roi_height, roi_rotation),
            raw, face, FRAME_STATUS_DETECTED)


def format_report(metrics: list[ComparisonMetrics]) -> str:
    lines = [
        "Comparaison same-frame MediaPipe / LiteRT BlazePose",
        "Aucune image ni coordonnee frame par frame n'a ete conservee.",
    ]
    for item in metrics:
        rate = 100 * item.native_present / item.attempts if item.attempts else 0
        agreement = (
            100 * (item.both_present + item.both_absent) / item.attempts
            if item.attempts
            else 0
        )
        mean_recovery = (
            statistics.fmean(item.recovery_seconds)
            if item.recovery_seconds
            else None
        )
        lines.extend(
            [
                "",
                f"Phase {item.name}",
                f"  Reference / natif / les deux : {item.reference_present} / "
                f"{item.native_present} / {item.both_present} sur {item.attempts}",
                f"  Taux natif : {rate:.1f} % · accord de presence : {agreement:.1f} %",
                f"  Reference seule : {item.reference_only} · natif seul : {item.native_only}",
                "  Ecart epaules p50/p95/max : "
                f"{optional(percentile(item.shoulder_errors_px, .5), ' px')} / "
                f"{optional(percentile(item.shoulder_errors_px, .95), ' px')} / "
                f"{optional(max(item.shoulder_errors_px) if item.shoulder_errors_px else None, ' px')}",
                "  Decalage median signe gauche dx/dy : "
                f"{optional(median(item.left_dx_px), ' px')} / "
                f"{optional(median(item.left_dy_px), ' px')}",
                "  Decalage median signe droite dx/dy : "
                f"{optional(median(item.right_dx_px), ' px')} / "
                f"{optional(median(item.right_dy_px), ' px')}",
                "  Ecart p50 direct / echange / miroir / miroir+echange : "
                f"{optional(percentile(item.shoulder_errors_px, .5), ' px')} / "
                f"{optional(percentile(item.swapped_errors_px, .5), ' px')} / "
                f"{optional(percentile(item.mirrored_errors_px, .5), ' px')} / "
                f"{optional(percentile(item.mirrored_swapped_errors_px, .5), ' px')}",
                "  Ratio median largeur epaules natif/reference : "
                f"{optional(median(item.shoulder_span_ratios), '')}",
                "  Milieu epaules natif-reference dx/dy median : "
                f"{optional(median(item.midpoint_dx_px), ' px')} / "
                f"{optional(median(item.midpoint_dy_px), ' px')}",
                "  Centre ROI natif-reference milieu epaules dx/dy median : "
                f"{optional(median(item.roi_center_dx_px), ' px')} / "
                f"{optional(median(item.roi_center_dy_px), ' px')}",
                "  ROI native largeur/hauteur/rotation medianes : "
                f"{optional(median(item.roi_width_px), ' px')} / "
                f"{optional(median(item.roi_height_px), ' px')} / "
                f"{optional(median(item.roi_rotation_degrees), ' deg')}",
                "  Ecart epaules p50 brut / apres heatmap : "
                f"{optional(percentile(item.raw_shoulder_errors_px, .5), ' px')} / "
                f"{optional(percentile(item.shoulder_errors_px, .5), ' px')}",
                "  Milieu brut natif-reference dx/dy median : "
                f"{optional(median(item.raw_midpoint_dx_px), ' px')} / "
                f"{optional(median(item.raw_midpoint_dy_px), ' px')}",
                "  Ecart p50 direct / translation visage / similitude visage : "
                f"{optional(percentile(item.shoulder_errors_px, .5), ' px')} / "
                f"{optional(percentile(item.translated_errors_px, .5), ' px')} / "
                f"{optional(percentile(item.similarity_errors_px, .5), ' px')}",
                "  Ecart p95 direct / translation visage : "
                f"{optional(percentile(item.shoulder_errors_px, .95), ' px')} / "
                f"{optional(percentile(item.translated_errors_px, .95), ' px')}",
                "  Ecart p95 direct / translation (% largeur epaules) : "
                f"{optional(percentile(item.shoulder_errors_span_percent, .95), ' %')} / "
                f"{optional(percentile(item.translated_errors_span_percent, .95), ' %')}",
                "  Recalage median translation / echelle / rotation / residu : "
                f"{optional(median(item.registration_translation_px), ' px')} / "
                f"{optional(median(item.similarity_scales), '')} / "
                f"{optional(median(item.similarity_rotations_degrees), ' deg')} / "
                f"{optional(median(item.similarity_residuals_px), ' px')}",
                "  Recalage atomique visage paires / translation / similitude : "
                f"{item.face_pairs} / {item.translation_accepted} / "
                f"{item.similarity_accepted}",
                "  Rejets geometrie / residu translation / bornes similitude : "
                f"{item.face_geometry_rejected} / "
                f"{item.translation_residual_rejected} / "
                f"{item.similarity_bounds_rejected}",
                f"  Sorties natives hors contrat rejetees : {item.native_invalid_outputs}",
                f"  Erreurs techniques natives exclues des taux : {item.native_technical_errors}",
                "  NoPerson / detection sous seuil : "
                f"{item.native_no_person} / {item.native_low_confidence}",
                f"  Gate A/B translation : {translation_gate(item)}",
                "  Latence native p50/p95/max : "
                f"{optional(percentile(item.native_latencies_ms, .5), ' ms')} / "
                f"{optional(percentile(item.native_latencies_ms, .95), ' ms')} / "
                f"{optional(max(item.native_latencies_ms) if item.native_latencies_ms else None, ' ms')}",
                f"  Pertes natives : {item.losses} · interruption max "
                f"{item.longest_loss:.2f} s · recuperation moyenne "
                f"{optional(mean_recovery, ' s')}",
            ]
        )
    return "\n".join(lines)


def optional(value: float | None, suffix: str) -> str:
    return "—" if value is None else f"{value:.2f}{suffix}"


def median(values: list[float]) -> float | None:
    return statistics.median(values) if values else None


def translation_gate(metrics: ComparisonMetrics) -> str:
    if metrics.attempts < MIN_AB_ATTEMPTS:
        return f"INCONCLUSIF (minimum {MIN_AB_ATTEMPTS} analyses)"
    if metrics.both_present == 0:
        return "INCONCLUSIF (aucune paire d'epaules commune)"
    reference_rate = metrics.reference_present / metrics.attempts
    native_when_reference = (
        metrics.both_present / metrics.reference_present
        if metrics.reference_present else 0.0
    )
    if reference_rate < 0.80:
        return f"INCONCLUSIF (reference presente {100 * reference_rate:.0f} %)"
    if native_when_reference < 0.90:
        return ("ECHEC (natif present sur "
                f"{100 * native_when_reference:.0f} % des references)")
    coverage = metrics.translation_accepted / metrics.both_present
    if coverage < MIN_FACE_COVERAGE:
        return f"ECHEC (couverture visage {100 * coverage:.0f} %)"
    direct_p50 = percentile(metrics.translation_direct_errors_px, .5)
    translated_p50 = percentile(metrics.translated_errors_px, .5)
    direct_p95 = percentile(metrics.translation_direct_errors_px, .95)
    translated_p95 = percentile(metrics.translated_errors_px, .95)
    if None in (direct_p50, translated_p50, direct_p95, translated_p95):
        return "INCONCLUSIF (metriques incompletes)"
    assert direct_p50 is not None and translated_p50 is not None
    assert direct_p95 is not None and translated_p95 is not None
    target = direct_p50 * (1.0 - MIN_TRANSLATION_IMPROVEMENT)
    direct_ratio = percentile(
        metrics.translation_direct_errors_span_percent, .95
    )
    translated_ratio = percentile(metrics.translated_errors_span_percent, .95)
    normalized_non_degraded = (
        direct_ratio is not None and translated_ratio is not None and
        translated_ratio <= direct_ratio
    )
    if (translated_p50 <= target and translated_p95 <= direct_p95 and
            normalized_non_degraded):
        return ("PASSE (p50 -20 %, p95 non degrade; p95 "
                f"{optional(direct_ratio, ' %')} -> "
                f"{optional(translated_ratio, ' %')} largeur epaules)")
    return ("ECHEC (benefice insuffisant ou p95 degrade; "
            "p95 "
            f"{optional(percentile(metrics.translation_direct_errors_span_percent, .95), ' %')} "
            "largeur epaules)")


def shoulder_pair_errors(
    reference: tuple[Point, Point],
    candidate: tuple[Point, Point],
    width: int,
    height: int,
) -> list[float]:
    return [
        math.hypot((actual.x - expected.x) * width,
                   (actual.y - expected.y) * height)
        for expected, actual in zip(reference, candidate)
    ]


def run_camera(args: argparse.Namespace) -> int:
    try:
        import cv2
        import mediapipe as mp
        from mediapipe.tasks import python as mp_python
        from mediapipe.tasks.python import vision
    except ImportError as error:
        print(f"Dependance absente : {error}", file=sys.stderr)
        return 2

    for path in (args.native_stream, args.detector, args.landmarks, args.mediapipe_model):
        if not Path(path).expanduser().is_file():
            print(f"Fichier introuvable : {path}", file=sys.stderr)
            return 2

    native = subprocess.Popen(
        [args.native_stream, args.detector, args.landmarks],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    running_mode = (
        vision.RunningMode.IMAGE
        if args.reference_mode == "image"
        else vision.RunningMode.VIDEO
    )
    options = vision.PoseLandmarkerOptions(
        base_options=mp_python.BaseOptions(
            model_asset_path=args.mediapipe_model,
            delegate=mp_python.BaseOptions.Delegate.CPU,
        ),
        running_mode=running_mode,
        num_poses=1,
        min_pose_detection_confidence=args.minimum_score,
        min_pose_presence_confidence=args.minimum_score,
        min_tracking_confidence=args.minimum_score,
    )
    capture = cv2.VideoCapture(args.camera_index)
    if not capture.isOpened():
        native.terminate()
        return 2
    metrics = [ComparisonMetrics(phase.name) for phase in PHASES]
    started_at: float | None = None
    last_analysis = -math.inf
    timestamp_ms = -1
    frame_id = 0
    active_phase_index: int | None = None

    try:
        with vision.PoseLandmarker.create_from_options(options) as reference:
            while True:
                ok, bgr = capture.read()
                if not ok:
                    break
                now = time.monotonic()
                preview = cv2.flip(bgr, 1)
                if started_at is None:
                    text = "Espace : demarrer · Q : quitter"
                else:
                    elapsed = now - started_at
                    phase_index = int(elapsed // args.phase_seconds)
                    phase = None
                    if phase_index < len(PHASES):
                        remaining = args.phase_seconds - (
                            elapsed - phase_index * args.phase_seconds
                        )
                        phase = (phase_index, remaining)
                    if phase is None:
                        break
                    phase_index, remaining = phase
                    if active_phase_index != phase_index:
                        if active_phase_index is not None:
                            metrics[active_phase_index].finish(now)
                        active_phase_index = phase_index
                    text = f"{PHASES[phase_index].instruction} · {remaining:.0f} s"
                    phase_elapsed = args.phase_seconds - remaining
                    if (phase_elapsed >= args.warmup_seconds and
                            now - last_analysis >= 1 / args.analysis_hz):
                        last_analysis = now
                        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
                        rgb = rgb.copy(order="C")
                        timestamp_ms = max(timestamp_ms + 1, int(now * 1000))
                        mp_image = mp.Image(
                            image_format=mp.ImageFormat.SRGB, data=rgb
                        )
                        if args.reference_mode == "image":
                            result = reference.detect(mp_image)
                        else:
                            result = reference.detect_for_video(
                                mp_image, timestamp_ms
                            )
                        reference_shoulders = None
                        reference_face = None
                        if result.pose_landmarks:
                            landmarks = result.pose_landmarks[0]
                            left = usable_point(landmarks, 11, args.minimum_score)
                            right = usable_point(landmarks, 12, args.minimum_score)
                            if left is not None and right is not None:
                                reference_shoulders = (left, right)
                            left_eye_parts = [
                                usable_point(landmarks, index, args.minimum_score)
                                for index in (1, 2, 3)
                            ]
                            right_eye_parts = [
                                usable_point(landmarks, index, args.minimum_score)
                                for index in (4, 5, 6)
                            ]
                            nose = usable_point(landmarks, 0, args.minimum_score)
                            if (all(point is not None for point in left_eye_parts) and
                                    all(point is not None for point in right_eye_parts) and
                                    nose is not None):
                                left_eye = Point(
                                    statistics.fmean(point.x for point in left_eye_parts),
                                    statistics.fmean(point.y for point in left_eye_parts),
                                )
                                right_eye = Point(
                                    statistics.fmean(point.x for point in right_eye_parts),
                                    statistics.fmean(point.y for point in right_eye_parts),
                                )
                                reference_face = (left_eye, right_eye, nose)
                        (native_observation, latency, native_roi, native_raw,
                         native_face, native_status) = native_frame(
                            native, frame_id, rgb
                        )
                        native_shoulders = (
                            native_observation.pair
                            if native_observation is not None else None
                        )
                        metrics[phase_index].record(
                            now, rgb.shape[1], rgb.shape[0], reference_shoulders,
                            native_shoulders, latency, native_roi, native_raw,
                            reference_face, native_face,
                            native_status,
                        )
                        frame_id += 1
                cv2.putText(preview, text, (24, 40), cv2.FONT_HERSHEY_SIMPLEX,
                            .65, (255, 255, 255), 2, cv2.LINE_AA)
                cv2.imshow("Align — comparaison same-frame", preview)
                key = cv2.waitKey(1) & 0xFF
                if key in (ord("q"), 27):
                    break
                if key == ord(" ") and started_at is None:
                    started_at = now
    finally:
        finished = time.monotonic()
        for item in metrics:
            item.finish(finished)
        capture.release()
        cv2.destroyAllWindows()
        if native.stdin:
            native.stdin.close()
        native.wait(timeout=5)
    print(format_report(metrics))
    return 0


def run_visual_live(args: argparse.Namespace) -> int:
    try:
        import cv2
    except ImportError as error:
        print(f"Dependance absente : {error}", file=sys.stderr)
        return 2

    for path in (args.native_stream, args.detector, args.landmarks):
        if not Path(path).expanduser().is_file():
            print(f"Fichier introuvable : {path}", file=sys.stderr)
            return 2

    native = subprocess.Popen(
        [args.native_stream, args.detector, args.landmarks],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    capture = cv2.VideoCapture(args.camera_index)
    if not capture.isOpened():
        native.terminate()
        return 2

    started = time.monotonic()
    last_analysis = -math.inf
    frame_id = 0
    latest_shoulders: NativeShoulders | None = None
    latest_at = -math.inf
    status = "PERDU"
    status_color = (40, 70, 230)
    try:
        while time.monotonic() - started < args.visual_seconds:
            ok, bgr = capture.read()
            if not ok:
                status = "ERREUR CAMERA"
                status_color = (40, 70, 230)
                break
            now = time.monotonic()
            if now - last_analysis >= 1.0 / args.analysis_hz:
                last_analysis = now
                rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB).copy(order="C")
                (observation, _, _, _, _, native_status) = native_frame(
                    native, frame_id, rgb
                )
                frame_id += 1
                if native_status == FRAME_STATUS_TECHNICAL_ERROR:
                    latest_shoulders = None
                    status = "ERREUR LITERT"
                    status_color = (40, 70, 230)
                elif observation is None or observation.state == "lost":
                    latest_shoulders = None
                    status = "PERDU"
                    status_color = (40, 70, 230)
                else:
                    latest_shoulders = observation
                    latest_at = now
                    if observation.state == "partial":
                        status = "PARTIEL"
                        status_color = (40, 180, 240)
                    else:
                        status = "DETECTE"
                        status_color = (220, 210, 40)

            if now - latest_at > 0.8:
                latest_shoulders = None
                if status in ("DETECTE", "PARTIEL"):
                    status = "PERDU"
                    status_color = (40, 70, 230)

            preview = cv2.flip(bgr, 1)
            height, width = preview.shape[:2]
            if latest_shoulders is not None:
                left_px = (visual_mirrored_pixel(latest_shoulders.left, width, height)
                           if latest_shoulders.left is not None else None)
                right_px = (visual_mirrored_pixel(latest_shoulders.right, width, height)
                            if latest_shoulders.right is not None else None)
                if left_px is not None:
                    cv2.circle(preview, left_px, 9, (255, 170, 60), -1,
                               cv2.LINE_AA)
                    cv2.putText(preview, "G", (left_px[0] + 12, left_px[1] - 8),
                                cv2.FONT_HERSHEY_SIMPLEX, .6, (255, 170, 60), 2,
                                cv2.LINE_AA)
                if right_px is not None:
                    cv2.circle(preview, right_px, 9, (90, 120, 255), -1,
                               cv2.LINE_AA)
                    cv2.putText(preview, "D", (right_px[0] + 12, right_px[1] - 8),
                                cv2.FONT_HERSHEY_SIMPLEX, .6, (90, 120, 255), 2,
                                cv2.LINE_AA)
                if left_px is not None and right_px is not None:
                    center_px = (
                        (left_px[0] + right_px[0]) // 2,
                        (left_px[1] + right_px[1]) // 2,
                    )
                    cv2.line(preview, left_px, right_px, (80, 220, 255), 4,
                             cv2.LINE_AA)
                    cv2.circle(preview, center_px, 8, (80, 220, 255), 2,
                               cv2.LINE_AA)
                    cv2.putText(preview, "CENTRE ESTIME",
                                (center_px[0] + 12, center_px[1] - 8),
                                cv2.FONT_HERSHEY_SIMPLEX, .48,
                                (80, 220, 255), 1, cv2.LINE_AA)
            remaining = max(0, math.ceil(args.visual_seconds - (now - started)))
            cv2.rectangle(preview, (16, 14), (330, 78), (15, 18, 22), -1)
            cv2.putText(preview, status, (30, 43), cv2.FONT_HERSHEY_SIMPLEX,
                        .75, status_color, 2, cv2.LINE_AA)
            cv2.putText(preview, f"Tres proche · {remaining} s · Q pour quitter",
                        (30, 67), cv2.FONT_HERSHEY_SIMPLEX, .46,
                        (235, 235, 235), 1, cv2.LINE_AA)
            cv2.imshow("Align LiteRT — epaules en direct", preview)
            if cv2.waitKey(1) & 0xFF in (ord("q"), 27):
                break
    finally:
        capture.release()
        cv2.destroyAllWindows()
        if native.stdin:
            native.stdin.close()
        try:
            native.wait(timeout=5)
        except subprocess.TimeoutExpired:
            native.terminate()
            native.wait(timeout=2)
    return 0


def visual_mirrored_pixel(point: Point, width: int, height: int) -> tuple[int, int]:
    return (
        int(round((1.0 - point.x) * max(0, width - 1))),
        int(round(point.y * max(0, height - 1))),
    )


def dry_run() -> int:
    packed = NATIVE_RESULT.pack(
        RESULT_MAGIC, FRAME_STATUS_DETECTED, 7, 21.5, 0.9,
        0.40, 0.50, 0.95, 0.60, 0.50, 0.96,
        0.50, 0.60, 0.80, 1.00, 0.0,
        0.41, 0.50, 0.59, 0.50,
        0.42, 0.40, 0.9, 0.58, 0.40, 0.9, 0.50, 0.48, 0.9,
    )
    assert len(packed) == NATIVE_RESULT.size == 124
    metrics = ComparisonMetrics("synthetique")
    metrics.record(
        1.0, 1000, 500, (Point(.41, .50), Point(.59, .50)),
        (Point(.40, .50), Point(.60, .50)), 21.5,
        (.50, .60, .80, 1.00, 0.0),
        (Point(.41, .50), Point(.59, .50)),
        (Point(.43, .40), Point(.59, .40), Point(.51, .48)),
        (Point(.42, .40), Point(.58, .40), Point(.50, .48)),
    )
    metrics.record(2.0, 1000, 500, (Point(.41, .50), Point(.59, .50)), None, 22)
    metrics.record(
        3.0, 1000, 500, (Point(.41, .50), Point(.59, .50)),
        (Point(.40, .50), Point(.60, .50)), 20,
        (.50, .60, .80, 1.00, 0.0),
        (Point(.41, .50), Point(.59, .50)),
        (Point(.43, .40), Point(.59, .40), Point(.51, .48)),
        (Point(.42, .40), Point(.58, .40), Point(.50, .48)),
    )
    metrics.finish(3.0)
    assert metrics.both_present == 2 and metrics.losses == 1
    assert metrics.recovery_seconds == [1.0]
    assert math.isclose(percentile(metrics.shoulder_errors_px, .95), 10.0)
    assert math.isclose(median(metrics.left_dx_px) or 0.0, -10.0)
    assert math.isclose(median(metrics.right_dx_px) or 0.0, 10.0)
    assert percentile(metrics.shoulder_errors_px, .5) < percentile(
        metrics.swapped_errors_px, .5
    )
    assert median(metrics.midpoint_dx_px) is not None
    assert math.isclose(median(metrics.midpoint_dx_px), 0.0)
    assert math.isclose(median(metrics.roi_center_dy_px) or 0.0, 50.0)
    assert math.isclose(percentile(metrics.raw_shoulder_errors_px, .5), 0.0)
    assert percentile(metrics.translated_errors_px, .5) < percentile(
        metrics.shoulder_errors_px, .5
    )
    synthetic_source = (Point(.4, .4), Point(.6, .4), Point(.5, .5))
    synthetic_target = (Point(.41, .4), Point(.61, .4), Point(.51, .5))
    translation = fit_translation(synthetic_source, synthetic_target, 1000, 500)
    similarity = fit_similarity(synthetic_source, synthetic_target, 1000, 500)
    assert translation is not None and similarity is not None
    assert math.isclose(translation.translation_x, 10.0)
    assert math.isclose(similarity.scale, 1.0)
    assert similarity.residual_px < 1e-9
    assert metrics.face_pairs == 2
    assert metrics.translation_accepted == 2
    assert metrics.similarity_accepted == 2
    assert translation_gate(metrics).startswith("INCONCLUSIF")
    gate_metrics = ComparisonMetrics("gate")
    for index in range(MIN_AB_ATTEMPTS):
        gate_metrics.record(
            float(index), 1000, 500,
            (Point(.41, .50), Point(.59, .50)),
            (Point(.40, .50), Point(.58, .50)), 1.0,
            reference_face=(Point(.43, .40), Point(.59, .40), Point(.51, .48)),
            native_face=(Point(.42, .40), Point(.58, .40), Point(.50, .48)),
        )
    assert translation_gate(gate_metrics).startswith("PASSE")
    assert len(gate_metrics.translation_direct_errors_px) == len(
        gate_metrics.translated_errors_px
    )
    rejected = ComparisonMetrics("rejets")
    rejected.record(
        1.0, 1000, 500, (Point(.4, .5), Point(.6, .5)),
        (Point(.4, .5), Point(.6, .5)), 1.0,
        reference_face=(Point(.499, .4), Point(.501, .4), Point(.5, .45)),
        native_face=(Point(.499, .4), Point(.501, .4), Point(.5, .45)),
    )
    assert rejected.face_pairs == 1 and rejected.face_geometry_rejected == 1
    excessive_target = tuple(
        Point(.5 + 1.4 * (point.x - .5), point.y)
        for point in synthetic_source
    )
    excessive = fit_similarity(synthetic_source, excessive_target, 1000, 500)
    assert excessive is not None and not similarity_acceptable(excessive)
    phase_loss = ComparisonMetrics("phase_loss")
    phase_loss.record(1.0, 1000, 500, (Point(.4, .5), Point(.6, .5)),
                      (Point(.4, .5), Point(.6, .5)), 1.0)
    phase_loss.record(2.0, 1000, 500, (Point(.4, .5), Point(.6, .5)),
                      None, 1.0)
    phase_loss.finish(3.0)
    assert math.isclose(phase_loss.longest_loss, 1.0)

    class FakeRgb(bytearray):
        shape = (1, 1, 3)

    class FakeProcess:
        def __init__(self, result: bytes) -> None:
            self.stdin = io.BytesIO()
            self.stdout = io.BytesIO(result)

    invalid_values = list(NATIVE_RESULT.unpack(packed))
    invalid_values[5] = math.nan
    invalid_process = FakeProcess(NATIVE_RESULT.pack(*invalid_values))
    invalid_frame = native_frame(invalid_process, 7, FakeRgb(b"\0\0\0"))
    assert invalid_frame[-1] == FRAME_STATUS_TECHNICAL_ERROR
    technical = ComparisonMetrics("technical")
    technical.record(1.0, 1, 1, None, None, invalid_frame[1],
                     native_status=invalid_frame[-1])
    assert technical.native_technical_errors == 1
    assert technical.attempts == 0 and technical.both_absent == 0
    technical_values = list(NATIVE_RESULT.unpack(packed))
    technical_values[1] = FRAME_STATUS_TECHNICAL_ERROR
    technical_process = FakeProcess(NATIVE_RESULT.pack(*technical_values))
    technical_frame = native_frame(
        technical_process, 7, FakeRgb(b"\0\0\0")
    )
    assert technical_frame[-1] == FRAME_STATUS_TECHNICAL_ERROR
    no_person_values = list(NATIVE_RESULT.unpack(packed))
    no_person_values[1] = FRAME_STATUS_NO_PERSON
    no_person_process = FakeProcess(NATIVE_RESULT.pack(*no_person_values))
    no_person_frame = native_frame(
        no_person_process, 7, FakeRgb(b"\0\0\0")
    )
    no_person = ComparisonMetrics("no_person")
    no_person.record(1.0, 1, 1, None, no_person_frame[0],
                     no_person_frame[1], native_status=no_person_frame[-1])
    assert no_person.native_no_person == 1
    assert no_person.attempts == 1 and no_person.both_absent == 1
    partial_values = list(NATIVE_RESULT.unpack(packed))
    partial_values[5] = -0.10  # épaule gauche finie mais hors image.
    partial_process = FakeProcess(NATIVE_RESULT.pack(*partial_values))
    partial_frame = native_frame(partial_process, 7, FakeRgb(b"\0\0\0"))
    assert partial_frame[-1] == FRAME_STATUS_DETECTED
    assert partial_frame[0] is not None
    assert partial_frame[0].state == "partial"
    assert partial_frame[0].left is None and partial_frame[0].right is not None
    assert visual_mirrored_pixel(Point(0.25, 0.40), 1001, 501) == (750, 200)
    print("MediaPipeLiteRTSameFrame dry-run: OK")
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--dry-run", action="store_true")
    result.add_argument("--visual-live", action="store_true")
    result.add_argument("--visual-seconds", type=float, default=25.0)
    result.add_argument("--native-stream")
    result.add_argument("--detector")
    result.add_argument("--landmarks")
    result.add_argument("--mediapipe-model")
    result.add_argument("--camera-index", type=int, default=0)
    result.add_argument("--analysis-hz", type=float, default=5.0)
    result.add_argument("--phase-seconds", type=float, default=9.0)
    result.add_argument("--warmup-seconds", type=float, default=2.0)
    result.add_argument("--minimum-score", type=float, default=0.5)
    result.add_argument(
        "--reference-mode", choices=("video", "image"), default="video",
        help="image desactive le suivi temporel MediaPipe pour le diagnostic.",
    )
    return result


def main() -> int:
    args = parser().parse_args()
    if args.dry_run:
        return dry_run()
    if args.visual_live:
        required = (args.native_stream, args.detector, args.landmarks)
        if any(value is None for value in required) or args.visual_seconds <= 0:
            print("Les chemins LiteRT et une duree positive sont requis.",
                  file=sys.stderr)
            return 2
        return run_visual_live(args)
    required = (args.native_stream, args.detector, args.landmarks, args.mediapipe_model)
    if any(value is None for value in required):
        print("Les quatre chemins de runtime/modeles sont requis.", file=sys.stderr)
        return 2
    if (args.analysis_hz <= 0 or args.phase_seconds <= 0 or
            args.warmup_seconds < 0 or args.warmup_seconds >= args.phase_seconds):
        return 2
    return run_camera(args)


if __name__ == "__main__":
    raise SystemExit(main())
