#include "blazepose_face_registration.h"

#include <math.h>

static int valid_inputs(const BlazePosePoint *source,
                        const BlazePosePoint *target, const float *weights,
                        size_t count, BlazePoseRegistration *registration,
                        float *weight_sum) {
  if (source == NULL || target == NULL || registration == NULL ||
      count < 2) {
    return 0;
  }
  *weight_sum = 0.0f;
  size_t positive_weights = 0;
  for (size_t index = 0; index < count; ++index) {
    float weight = weights == NULL ? 1.0f : weights[index];
    if (!isfinite(source[index].x) || !isfinite(source[index].y) ||
        !isfinite(target[index].x) || !isfinite(target[index].y) ||
        !isfinite(weight) || weight < 0.0f) {
      return 0;
    }
    *weight_sum += weight;
    if (weight > 0.0f) ++positive_weights;
  }
  return isfinite(*weight_sum) && *weight_sum > 0.0f && positive_weights >= 2;
}

static float residual(const BlazePosePoint *source,
                      const BlazePosePoint *target, const float *weights,
                      size_t count, float weight_sum,
                      BlazePoseRegistration registration) {
  float squared = 0.0f;
  for (size_t index = 0; index < count; ++index) {
    float weight = weights == NULL ? 1.0f : weights[index];
    BlazePosePoint fitted =
        BlazePoseApplyRegistration(source[index], registration);
    float dx = fitted.x - target[index].x;
    float dy = fitted.y - target[index].y;
    squared += weight * (dx * dx + dy * dy);
  }
  return sqrtf(squared / weight_sum);
}

int BlazePoseFitTranslation(const BlazePosePoint *source,
                            const BlazePosePoint *target,
                            const float *weights, size_t count,
                            BlazePoseRegistration *registration) {
  float weight_sum = 0.0f;
  if (!valid_inputs(source, target, weights, count, registration,
                    &weight_sum)) {
    return 0;
  }
  float translation_x = 0.0f;
  float translation_y = 0.0f;
  for (size_t index = 0; index < count; ++index) {
    float weight = weights == NULL ? 1.0f : weights[index];
    translation_x += weight * (target[index].x - source[index].x);
    translation_y += weight * (target[index].y - source[index].y);
  }
  BlazePoseRegistration candidate = (BlazePoseRegistration){
      .scale = 1.0f,
      .cosine = 1.0f,
      .sine = 0.0f,
      .translation_x = translation_x / weight_sum,
      .translation_y = translation_y / weight_sum,
  };
  candidate.rms_residual =
      residual(source, target, weights, count, weight_sum, candidate);
  if (!isfinite(candidate.translation_x) ||
      !isfinite(candidate.translation_y) ||
      !isfinite(candidate.rms_residual)) {
    return 0;
  }
  *registration = candidate;
  return 1;
}

int BlazePoseFitSimilarity(const BlazePosePoint *source,
                           const BlazePosePoint *target,
                           const float *weights, size_t count,
                           BlazePoseRegistration *registration) {
  float weight_sum = 0.0f;
  if (!valid_inputs(source, target, weights, count, registration,
                    &weight_sum)) {
    return 0;
  }
  BlazePosePoint source_center = {0};
  BlazePosePoint target_center = {0};
  for (size_t index = 0; index < count; ++index) {
    float weight = weights == NULL ? 1.0f : weights[index];
    source_center.x += weight * source[index].x;
    source_center.y += weight * source[index].y;
    target_center.x += weight * target[index].x;
    target_center.y += weight * target[index].y;
  }
  source_center.x /= weight_sum;
  source_center.y /= weight_sum;
  target_center.x /= weight_sum;
  target_center.y /= weight_sum;

  float dot = 0.0f;
  float cross = 0.0f;
  float source_energy = 0.0f;
  for (size_t index = 0; index < count; ++index) {
    float weight = weights == NULL ? 1.0f : weights[index];
    float sx = source[index].x - source_center.x;
    float sy = source[index].y - source_center.y;
    float tx = target[index].x - target_center.x;
    float ty = target[index].y - target_center.y;
    dot += weight * (sx * tx + sy * ty);
    cross += weight * (sx * ty - sy * tx);
    source_energy += weight * (sx * sx + sy * sy);
  }
  float magnitude = sqrtf(dot * dot + cross * cross);
  if (!isfinite(magnitude) || source_energy <= 1e-12f || magnitude <= 1e-12f) {
    return 0;
  }
  float scale = magnitude / source_energy;
  float cosine = dot / magnitude;
  float sine = cross / magnitude;
  BlazePoseRegistration candidate = (BlazePoseRegistration){
      .scale = scale,
      .cosine = cosine,
      .sine = sine,
      .translation_x =
          target_center.x - scale *
                                (cosine * source_center.x -
                                 sine * source_center.y),
      .translation_y =
          target_center.y - scale *
                                (sine * source_center.x +
                                 cosine * source_center.y),
  };
  candidate.rms_residual =
      residual(source, target, weights, count, weight_sum, candidate);
  if (!isfinite(candidate.scale) || candidate.scale <= 0.0f ||
      !isfinite(candidate.cosine) || !isfinite(candidate.sine) ||
      !isfinite(candidate.translation_x) ||
      !isfinite(candidate.translation_y) ||
      !isfinite(candidate.rms_residual)) {
    return 0;
  }
  *registration = candidate;
  return 1;
}

BlazePosePoint BlazePoseApplyRegistration(
    BlazePosePoint point, BlazePoseRegistration registration) {
  return (BlazePosePoint){
      .x = registration.scale *
               (registration.cosine * point.x -
                registration.sine * point.y) +
           registration.translation_x,
      .y = registration.scale *
               (registration.sine * point.x +
                registration.cosine * point.y) +
           registration.translation_y,
  };
}
