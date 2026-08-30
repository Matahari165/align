#include "blazepose_geometry.h"

#include <limits.h>
#include <math.h>
#include <stdlib.h>

static float sigmoid(float value) {
  if (value >= 0.0f) {
    float exponential = expf(-value);
    return 1.0f / (1.0f + exponential);
  }
  float exponential = expf(value);
  return exponential / (1.0f + exponential);
}

static float normalize_radians(float angle) {
  const float two_pi = 2.0f * (float)M_PI;
  return angle - two_pi * floorf((angle + (float)M_PI) / two_pi);
}

static float low_pass_alpha(float cutoff, double elapsed_seconds) {
  if (!isfinite(cutoff) || cutoff <= 0.0f || !isfinite(elapsed_seconds) ||
      elapsed_seconds <= 0.0) {
    return 1.0f;
  }
  const double tau = 1.0 / (2.0 * M_PI * (double)cutoff);
  return (float)(1.0 / (1.0 + tau / elapsed_seconds));
}

size_t BlazePoseGenerateAnchors(BlazePoseAnchor *anchors, size_t capacity) {
  const int strides[] = {8, 16, 32, 32, 32};
  const int input_size = 224;
  size_t count = 0;
  int layer = 0;

  while (layer < 5) {
    int same_stride_layers = 0;
    int cursor = layer;
    while (cursor < 5 && strides[cursor] == strides[layer]) {
      // Chaque couche apporte l'ancre 1:1 et l'ancre interpolee 1:1.
      same_stride_layers += 2;
      ++cursor;
    }
    int feature_size = (input_size + strides[layer] - 1) / strides[layer];
    for (int y = 0; y < feature_size; ++y) {
      for (int x = 0; x < feature_size; ++x) {
        for (int anchor_index = 0; anchor_index < same_stride_layers;
             ++anchor_index) {
          if (count < capacity) {
            anchors[count] = (BlazePoseAnchor){
                .x = ((float)x + 0.5f) / (float)feature_size,
                .y = ((float)y + 0.5f) / (float)feature_size,
                .width = 1.0f,
                .height = 1.0f,
            };
          }
          ++count;
        }
      }
    }
    layer = cursor;
  }
  return count;
}

BlazePoseDetection BlazePoseDecodeDetection(const float raw[12], float logit,
                                            BlazePoseAnchor anchor) {
  const float scale = 224.0f;
  float x_center = raw[0] / scale * anchor.width + anchor.x;
  float y_center = raw[1] / scale * anchor.height + anchor.y;
  float width = raw[2] / scale * anchor.width;
  float height = raw[3] / scale * anchor.height;
  BlazePoseDetection detection = {
      .score = sigmoid(fmaxf(-100.0f, fminf(100.0f, logit))),
      .x_min = x_center - width * 0.5f,
      .y_min = y_center - height * 0.5f,
      .x_max = x_center + width * 0.5f,
      .y_max = y_center + height * 0.5f,
  };
  for (int index = 0; index < 4; ++index) {
    detection.keypoints[index].x =
        raw[4 + index * 2] / scale * anchor.width + anchor.x;
    detection.keypoints[index].y =
        raw[5 + index * 2] / scale * anchor.height + anchor.y;
  }
  return detection;
}

BlazePosePadding BlazePoseDetectorLetterbox(size_t image_width,
                                            size_t image_height) {
  if (image_width == 0 || image_height == 0 || image_width == image_height) {
    return (BlazePosePadding){0};
  }
  if (image_width > image_height) {
    float content = (float)image_height / (float)image_width;
    float pad = (1.0f - content) * 0.5f;
    return (BlazePosePadding){.top = pad, .bottom = pad};
  }
  float content = (float)image_width / (float)image_height;
  float pad = (1.0f - content) * 0.5f;
  return (BlazePosePadding){.left = pad, .right = pad};
}

BlazePoseDetection BlazePoseRemoveDetectionLetterbox(
    BlazePoseDetection detection, BlazePosePadding padding) {
  float x_scale = 1.0f - padding.left - padding.right;
  float y_scale = 1.0f - padding.top - padding.bottom;
  detection.x_min = (detection.x_min - padding.left) / x_scale;
  detection.x_max = (detection.x_max - padding.left) / x_scale;
  detection.y_min = (detection.y_min - padding.top) / y_scale;
  detection.y_max = (detection.y_max - padding.top) / y_scale;
  for (int index = 0; index < 4; ++index) {
    detection.keypoints[index].x =
        (detection.keypoints[index].x - padding.left) / x_scale;
    detection.keypoints[index].y =
        (detection.keypoints[index].y - padding.top) / y_scale;
  }
  return detection;
}

int BlazePoseSelectBestDetection(const float *raw_boxes, const float *logits,
                                 const BlazePoseAnchor *anchors,
                                 size_t count, float minimum_score,
                                 BlazePoseDetection *detection) {
  BlazePoseDetection *candidates =
      calloc(count == 0 ? 1 : count, sizeof(BlazePoseDetection));
  if (candidates == NULL) return 0;
  size_t candidate_count = 0;
  for (size_t index = 0; index < count; ++index) {
    if (!isfinite(logits[index])) continue;
    BlazePoseDetection candidate = BlazePoseDecodeDetection(
        raw_boxes + index * BLAZEPOSE_DETECTOR_COORDS, logits[index],
        anchors[index]);
    if (!isfinite(candidate.score) || !isfinite(candidate.x_min) ||
        !isfinite(candidate.y_min) || !isfinite(candidate.x_max) ||
        !isfinite(candidate.y_max) || candidate.score < minimum_score ||
        candidate.x_max < candidate.x_min || candidate.y_max < candidate.y_min) {
      continue;
    }
    int keypoints_are_finite = 1;
    for (int point = 0; point < 4; ++point) {
      if (!isfinite(candidate.keypoints[point].x) ||
          !isfinite(candidate.keypoints[point].y)) {
        keypoints_are_finite = 0;
        break;
      }
    }
    if (keypoints_are_finite) candidates[candidate_count++] = candidate;
  }
  if (candidate_count == 0) {
    free(candidates);
    return 0;
  }

  size_t seed_index = 0;
  for (size_t index = 1; index < candidate_count; ++index) {
    if (candidates[index].score > candidates[seed_index].score) {
      seed_index = index;
    }
  }
  BlazePoseDetection seed = candidates[seed_index];
  float seed_area = (seed.x_max - seed.x_min) * (seed.y_max - seed.y_min);
  float total_weight = 0.0f;
  BlazePoseDetection weighted = {.score = seed.score};
  for (size_t index = 0; index < candidate_count; ++index) {
    BlazePoseDetection candidate = candidates[index];
    float intersection_width =
        fmaxf(0.0f, fminf(seed.x_max, candidate.x_max) -
                         fmaxf(seed.x_min, candidate.x_min));
    float intersection_height =
        fmaxf(0.0f, fminf(seed.y_max, candidate.y_max) -
                         fmaxf(seed.y_min, candidate.y_min));
    float intersection = intersection_width * intersection_height;
    float candidate_area =
        (candidate.x_max - candidate.x_min) *
        (candidate.y_max - candidate.y_min);
    float union_area = seed_area + candidate_area - intersection;
    float iou = union_area > 0.0f ? intersection / union_area : 0.0f;
    if (index != seed_index && iou <= 0.3f) continue;
    float weight = candidate.score;
    total_weight += weight;
    weighted.x_min += candidate.x_min * weight;
    weighted.y_min += candidate.y_min * weight;
    weighted.x_max += candidate.x_max * weight;
    weighted.y_max += candidate.y_max * weight;
    for (int point = 0; point < 4; ++point) {
      weighted.keypoints[point].x += candidate.keypoints[point].x * weight;
      weighted.keypoints[point].y += candidate.keypoints[point].y * weight;
    }
  }
  if (total_weight <= 0.0f) {
    free(candidates);
    return 0;
  }
  weighted.x_min /= total_weight;
  weighted.y_min /= total_weight;
  weighted.x_max /= total_weight;
  weighted.y_max /= total_weight;
  for (int point = 0; point < 4; ++point) {
    weighted.keypoints[point].x /= total_weight;
    weighted.keypoints[point].y /= total_weight;
  }
  *detection = weighted;
  free(candidates);
  return 1;
}

BlazePoseRoi BlazePoseDetectionToRoi(BlazePoseDetection detection,
                                     float image_width, float image_height) {
  BlazePosePoint center = detection.keypoints[0];
  BlazePosePoint scale = detection.keypoints[1];
  float dx = (scale.x - center.x) * image_width;
  float dy = (scale.y - center.y) * image_height;
  float box_size = 2.0f * sqrtf(dx * dx + dy * dy);
  float rotation = normalize_radians((float)M_PI_2 - atan2f(-dy, dx));
  return (BlazePoseRoi){
      .x_center = center.x,
      .y_center = center.y,
      .width = box_size / image_width * 1.25f,
      .height = box_size / image_height * 1.25f,
      .rotation = rotation,
  };
}

void BlazePoseDecodeLandmarks(const float *raw,
                              BlazePoseLandmark landmarks[39]) {
  for (int index = 0; index < BLAZEPOSE_LANDMARK_COUNT; ++index) {
    const float *values = raw + index * 5;
    landmarks[index] = (BlazePoseLandmark){
        .x = values[0] / 256.0f,
        .y = values[1] / 256.0f,
        .z = values[2] / 256.0f,
        .visibility = sigmoid(values[3]),
        .presence = sigmoid(values[4]),
    };
  }
}

void BlazePoseRefineLandmarksFromHeatmap(
    BlazePoseLandmark landmarks[39], const float *heatmap, size_t height,
    size_t width, size_t channels) {
  if (heatmap == NULL || channels != BLAZEPOSE_LANDMARK_COUNT || height == 0 ||
      width == 0 || height > (size_t)INT_MAX || width > (size_t)INT_MAX) {
    return;
  }
  const int radius = 3;  // kernel MediaPipe 7×7.
  for (size_t landmark_index = 0; landmark_index < channels;
       ++landmark_index) {
    float scaled_x = landmarks[landmark_index].x * (float)width;
    float scaled_y = landmarks[landmark_index].y * (float)height;
    if (!isfinite(scaled_x) || !isfinite(scaled_y) || scaled_x < 0.0f ||
        scaled_y < 0.0f || scaled_x >= (float)width ||
        scaled_y >= (float)height) {
      continue;
    }
    int center_x = (int)scaled_x;
    int center_y = (int)scaled_y;
    int width_int = (int)width;
    int height_int = (int)height;
    int begin_x = center_x - radius < 0 ? 0 : center_x - radius;
    int begin_y = center_y - radius < 0 ? 0 : center_y - radius;
    int end_x = width_int - center_x <= radius
                    ? width_int
                    : center_x + radius + 1;
    int end_y = height_int - center_y <= radius
                    ? height_int
                    : center_y + radius + 1;
    float sum = 0.0f;
    float weighted_x = 0.0f;
    float weighted_y = 0.0f;
    float maximum = 0.0f;
    for (int y = begin_y; y < end_y; ++y) {
      for (int x = begin_x; x < end_x; ++x) {
        size_t offset = ((size_t)y * width + (size_t)x) * channels +
                        landmark_index;
        float confidence = sigmoid(heatmap[offset]);
        sum += confidence;
        weighted_x += (float)x * confidence;
        weighted_y += (float)y * confidence;
        if (confidence > maximum) maximum = confidence;
      }
    }
    if (maximum >= 0.5f && sum > 0.0f) {
      landmarks[landmark_index].x = weighted_x / (float)width / sum;
      landmarks[landmark_index].y = weighted_y / (float)height / sum;
    }
  }
}

BlazePoseLandmark BlazePoseProjectLandmark(BlazePoseLandmark landmark,
                                           BlazePoseRoi roi) {
  float x = landmark.x - 0.5f;
  float y = landmark.y - 0.5f;
  float cosine = cosf(roi.rotation);
  float sine = sinf(roi.rotation);
  landmark.x = (cosine * x - sine * y) * roi.width + roi.x_center;
  landmark.y = (sine * x + cosine * y) * roi.height + roi.y_center;
  landmark.z *= roi.width;
  return landmark;
}

void BlazePoseResetOneEuroFilter(BlazePoseOneEuroFilter *filter) {
  if (filter != NULL) *filter = (BlazePoseOneEuroFilter){0};
}

float BlazePoseFilterNormalizedCoordinate(BlazePoseOneEuroFilter *filter,
                                          float value,
                                          double timestamp_seconds,
                                          float value_scale) {
  if (filter == NULL || !isfinite(value) || !isfinite(timestamp_seconds) ||
      !isfinite(value_scale) || value_scale <= 0.0f) {
    return value;
  }
  if (!filter->initialized || timestamp_seconds <= filter->last_timestamp) {
    *filter = (BlazePoseOneEuroFilter){
        .initialized = 1,
        .last_timestamp = timestamp_seconds,
        .last_raw = value,
        .last_filtered = value,
    };
    return value;
  }

  const double elapsed = timestamp_seconds - filter->last_timestamp;
  const float derivative =
      (value - filter->last_raw) / (float)elapsed * value_scale;
  const float derivative_alpha = low_pass_alpha(1.0f, elapsed);
  const float filtered_derivative =
      derivative_alpha * derivative +
      (1.0f - derivative_alpha) * filter->last_filtered_derivative;

  // Parametres officiels PoseLandmarkFiltering pour les landmarks normalises.
  const float cutoff = 0.05f + 80.0f * fabsf(filtered_derivative);
  const float alpha = low_pass_alpha(cutoff, elapsed);
  const float filtered =
      alpha * value + (1.0f - alpha) * filter->last_filtered;
  filter->last_timestamp = timestamp_seconds;
  filter->last_raw = value;
  filter->last_filtered = filtered;
  filter->last_filtered_derivative = filtered_derivative;
  return filtered;
}

void BlazePoseResetShoulderFilter(BlazePoseShoulderFilter *filter) {
  if (filter != NULL) *filter = (BlazePoseShoulderFilter){0};
}

static void reset_shoulder_samples(BlazePoseShoulderFilter *filter) {
  const int has_generation = filter->has_generation;
  const uint64_t generation = filter->generation;
  BlazePoseResetShoulderFilter(filter);
  filter->has_generation = has_generation;
  filter->generation = generation;
}

int BlazePoseFilterShoulders(BlazePoseShoulderFilter *filter,
                             int has_left,
                             BlazePoseLandmark left,
                             int has_right,
                             BlazePoseLandmark right,
                             BlazePoseRoi roi,
                             size_t image_width,
                             size_t image_height,
                             double timestamp_seconds,
                             double maximum_gap_seconds,
                             uint64_t generation,
                             BlazePoseLandmark *filtered_left,
                             BlazePoseLandmark *filtered_right) {
  if (filter == NULL) return 0;
  // Un callback ancien est totalement inerte, meme si son payload est invalide.
  if (filter->has_generation && generation < filter->generation) return 0;
  if (filtered_left == NULL || filtered_right == NULL ||
      image_width == 0 || image_height == 0 || !isfinite(timestamp_seconds) ||
      !isfinite(maximum_gap_seconds) || maximum_gap_seconds <= 0.0 ||
      !isfinite(roi.width) || !isfinite(roi.height) || roi.width <= 0.0f ||
      roi.height <= 0.0f ||
      (has_left && (!isfinite(left.x) || !isfinite(left.y))) ||
      (has_right && (!isfinite(right.x) || !isfinite(right.y)))) {
    reset_shoulder_samples(filter);
    return 0;
  }
  if (!filter->has_generation || generation > filter->generation) {
    BlazePoseResetShoulderFilter(filter);
    filter->has_generation = 1;
    filter->generation = generation;
  }

  if (!has_left && !has_right) {
    reset_shoulder_samples(filter);
    *filtered_left = (BlazePoseLandmark){0};
    *filtered_right = (BlazePoseLandmark){0};
    return 0;
  }

  if (filter->has_timestamp && timestamp_seconds <= filter->last_timestamp) {
    reset_shoulder_samples(filter);
    return 0;
  }
  if (filter->has_timestamp &&
      timestamp_seconds - filter->last_timestamp > maximum_gap_seconds) {
    reset_shoulder_samples(filter);
  }

  const float object_scale =
      (roi.width * (float)image_width + roi.height * (float)image_height) *
      0.5f;
  if (!isfinite(object_scale) || object_scale <= 0.0f) return 0;
  const float x_value_scale = (float)image_width / object_scale;
  const float y_value_scale = (float)image_height / object_scale;

  *filtered_left = left;
  if (has_left) {
    filtered_left->x = BlazePoseFilterNormalizedCoordinate(
        &filter->left_x, left.x, timestamp_seconds, x_value_scale);
    filtered_left->y = BlazePoseFilterNormalizedCoordinate(
        &filter->left_y, left.y, timestamp_seconds, y_value_scale);
  } else {
    BlazePoseResetOneEuroFilter(&filter->left_x);
    BlazePoseResetOneEuroFilter(&filter->left_y);
  }
  *filtered_right = right;
  if (has_right) {
    filtered_right->x = BlazePoseFilterNormalizedCoordinate(
        &filter->right_x, right.x, timestamp_seconds, x_value_scale);
    filtered_right->y = BlazePoseFilterNormalizedCoordinate(
        &filter->right_y, right.y, timestamp_seconds, y_value_scale);
  } else {
    BlazePoseResetOneEuroFilter(&filter->right_x);
    BlazePoseResetOneEuroFilter(&filter->right_y);
  }
  filter->has_timestamp = 1;
  filter->last_timestamp = timestamp_seconds;
  return 1;
}
