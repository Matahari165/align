#include "blazepose_geometry.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static int near(float left, float right) { return fabsf(left - right) < 1e-5f; }

int main(void) {
  BlazePoseAnchor anchors[BLAZEPOSE_ANCHOR_COUNT];
  assert(BlazePoseGenerateAnchors(anchors, BLAZEPOSE_ANCHOR_COUNT) ==
         BLAZEPOSE_ANCHOR_COUNT);
  assert(near(anchors[0].x, 0.5f / 28.0f));
  assert(near(anchors[0].y, 0.5f / 28.0f));
  assert(near(anchors[1567].x, 27.5f / 28.0f));
  assert(near(anchors[1568].x, 0.5f / 14.0f));
  assert(near(anchors[1959].x, 13.5f / 14.0f));
  assert(near(anchors[1960].x, 0.5f / 7.0f));
  assert(near(anchors[BLAZEPOSE_ANCHOR_COUNT - 1].x, 6.5f / 7.0f));
  assert(near(anchors[BLAZEPOSE_ANCHOR_COUNT - 1].y, 6.5f / 7.0f));

  float raw[12] = {0};
  raw[2] = 112.0f;
  raw[3] = 56.0f;
  raw[4] = 0.0f;
  raw[5] = 0.0f;
  raw[6] = 0.0f;
  raw[7] = -56.0f;
  BlazePoseAnchor center_anchor = {.x = 0.5f,
                                   .y = 0.5f,
                                   .width = 1.0f,
                                   .height = 1.0f};
  BlazePoseDetection detection =
      BlazePoseDecodeDetection(raw, 0.0f, center_anchor);
  assert(near(detection.score, 0.5f));
  assert(near(detection.x_min, 0.25f));
  assert(near(detection.x_max, 0.75f));
  assert(near(detection.y_min, 0.375f));
  assert(near(detection.y_max, 0.625f));

  BlazePoseAnchor non_square_anchor = {
      .x = 0.5f, .y = 0.5f, .width = 2.0f, .height = 0.5f};
  BlazePoseDetection non_square =
      BlazePoseDecodeDetection(raw, 0.0f, non_square_anchor);
  assert(near(non_square.x_min, 0.0f));
  assert(near(non_square.x_max, 1.0f));
  assert(near(non_square.y_min, 0.4375f));
  assert(near(non_square.y_max, 0.5625f));

  BlazePosePadding padding = BlazePoseDetectorLetterbox(640, 480);
  assert(near(padding.top, 0.125f));
  assert(near(padding.bottom, 0.125f));
  BlazePoseDetection unletterboxed =
      BlazePoseRemoveDetectionLetterbox(detection, padding);
  assert(near(unletterboxed.y_min, 1.0f / 3.0f));
  assert(near(unletterboxed.y_max, 2.0f / 3.0f));
  BlazePosePadding portrait = BlazePoseDetectorLetterbox(480, 640);
  assert(near(portrait.left, 0.125f));
  assert(near(portrait.right, 0.125f));
  BlazePosePadding square = BlazePoseDetectorLetterbox(640, 640);
  assert(near(square.left, 0.0f) && near(square.top, 0.0f));

  // Le test ROI continue avec des points déjà exprimés dans l'image source.
  detection = unletterboxed;
  detection.keypoints[0] = (BlazePosePoint){.x = 0.5f, .y = 0.5f};
  detection.keypoints[1] = (BlazePosePoint){.x = 0.5f, .y = 0.25f};

  BlazePoseRoi roi = BlazePoseDetectionToRoi(detection, 640.0f, 480.0f);
  assert(near(roi.x_center, 0.5f));
  assert(near(roi.y_center, 0.5f));
  assert(near(roi.rotation, 0.0f));
  assert(near(roi.width, 0.46875f));
  assert(near(roi.height, 0.625f));
  detection.keypoints[1] = detection.keypoints[0];
  BlazePoseRoi degenerate =
      BlazePoseDetectionToRoi(detection, 640.0f, 480.0f);
  assert(near(degenerate.width, 0.0f));
  assert(near(degenerate.height, 0.0f));
  detection.keypoints[1] = (BlazePosePoint){.x = 0.75f, .y = 0.5f};
  BlazePoseRoi rotated =
      BlazePoseDetectionToRoi(detection, 640.0f, 480.0f);
  assert(near(rotated.rotation, (float)M_PI_2));

  float raw_landmarks[39 * 5] = {0};
  raw_landmarks[11 * 5 + 0] = 64.0f;
  raw_landmarks[11 * 5 + 1] = 128.0f;
  raw_landmarks[11 * 5 + 3] = 0.0f;
  raw_landmarks[11 * 5 + 4] = 2.0f;
  BlazePoseLandmark landmarks[39];
  BlazePoseDecodeLandmarks(raw_landmarks, landmarks);
  assert(near(landmarks[11].x, 0.25f));
  assert(near(landmarks[11].y, 0.5f));
  assert(near(landmarks[11].visibility, 0.5f));
  assert(landmarks[11].presence > 0.88f);
  size_t heatmap_count = 64 * 64 * 39;
  float *heatmap = malloc(heatmap_count * sizeof(float));
  assert(heatmap != NULL);
  for (size_t index = 0; index < heatmap_count; ++index) heatmap[index] = -100.0f;
  heatmap[(32 * 64 + 18) * 39 + 11] = -0.25f;
  heatmap[(32 * 64 + 19) * 39 + 11] = 2.0f;
  landmarks[12].x = 0.5f;
  landmarks[12].y = 0.5f;
  heatmap[(32 * 64 + 32) * 39 + 12] = -0.1f;
  BlazePoseRefineLandmarksFromHeatmap(landmarks, heatmap, 64, 64, 39);
  assert(landmarks[11].x > 18.0f / 64.0f);
  assert(landmarks[11].x < 19.0f / 64.0f);
  assert(near(landmarks[11].y, 32.0f / 64.0f));
  assert(near(landmarks[12].x, 0.5f));
  assert(near(landmarks[12].y, 0.5f));
  landmarks[13].x = NAN;
  landmarks[13].y = INFINITY;
  BlazePoseRefineLandmarksFromHeatmap(landmarks, heatmap, 64, 64, 39);
  assert(isnan(landmarks[13].x));
  assert(isinf(landmarks[13].y));
  free(heatmap);
  BlazePoseLandmark projected = BlazePoseProjectLandmark(landmarks[11], roi, 640, 480);
  assert(projected.x > 0.39f && projected.x < 0.42f);
  assert(near(projected.y, 0.5f));
  landmarks[11].z = 0.4f;
  projected = BlazePoseProjectLandmark(landmarks[11], roi, 640, 480);
  assert(near(projected.z, 0.4f * roi.width));

  // Aller-retour exact d'un point dans une ROI non carree, decalee et
  // tournee. Ce cas reproduit la compression/translation observee en live.
  BlazePoseRoi asymmetric_roi = {
      .x_center = 0.61f,
      .y_center = 0.47f,
      .width = 0.42f,
      .height = 0.68f,
      .rotation = 0.31f,
  };
  BlazePoseLandmark asymmetric_local = {
      .x = 0.19f, .y = 0.73f, .z = 0.2f, .visibility = 0.9f, .presence = 0.8f};
  BlazePoseLandmark asymmetric_full =
      BlazePoseProjectLandmark(asymmetric_local, asymmetric_roi, 640, 480);
  float local_x = asymmetric_local.x - 0.5f;
  float local_y = asymmetric_local.y - 0.5f;
  float cosine = cosf(asymmetric_roi.rotation);
  float sine = sinf(asymmetric_roi.rotation);
  assert(near(asymmetric_full.x,
              asymmetric_roi.x_center + cosine * local_x * asymmetric_roi.width -
                  sine * local_y * asymmetric_roi.height * 480.0f / 640.0f));
  assert(near(asymmetric_full.y,
              asymmetric_roi.y_center + sine * local_x * asymmetric_roi.width *
                  640.0f / 480.0f + cosine * local_y * asymmetric_roi.height));
  // Inversion analytique : le point image complet doit revenir au point crop.
  float full_dx = (asymmetric_full.x - asymmetric_roi.x_center) * 640.0f;
  float full_dy = (asymmetric_full.y - asymmetric_roi.y_center) * 480.0f;
  float recovered_x =
      (cosine * full_dx + sine * full_dy) /
          (asymmetric_roi.width * 640.0f) + 0.5f;
  float recovered_y =
      (-sine * full_dx + cosine * full_dy) /
          (asymmetric_roi.height * 480.0f) + 0.5f;
  assert(near(recovered_x, asymmetric_local.x));
  assert(near(recovered_y, asymmetric_local.y));

  // Contrat pixel exact : DetectionToRoi fabrique un carré en pixels. Sur
  // 640x480, une rotation de 45 degrés ne doit pas être effectuée dans les
  // axes normalisés, qui n'ont pas la même échelle.
  BlazePoseDetection pixel_detection = {0};
  pixel_detection.keypoints[0] = (BlazePosePoint){.x = 0.50f, .y = 0.50f};
  pixel_detection.keypoints[1] =
      (BlazePosePoint){.x = 0.625f, .y = 1.0f / 3.0f};
  BlazePoseRoi pixel_roi = BlazePoseDetectionToRoi(pixel_detection, 640, 480);
  assert(near(pixel_roi.rotation, (float)M_PI_4));
  assert(fabsf(pixel_roi.width * 640.0f - pixel_roi.height * 480.0f) <
         1e-3f);
  BlazePosePoint local_marker = {.x = 0.77f, .y = 0.18f};
  BlazePosePoint crop_source = BlazePoseRoiLocalToImagePoint(
      local_marker, pixel_roi, 640, 480);
  BlazePoseLandmark marker = {
      .x = local_marker.x, .y = local_marker.y, .visibility = 1, .presence = 1};
  BlazePoseLandmark pixel_projected =
      BlazePoseProjectLandmark(marker, pixel_roi, 640, 480);
  assert(fabsf(pixel_projected.x * 640.0f - 438.0f) < 1e-3f);
  assert(fabsf(pixel_projected.y * 480.0f - 230.0f) < 1e-3f);
  assert(near(crop_source.x * 640.0f, pixel_projected.x * 640.0f));
  assert(near(crop_source.y * 480.0f, pixel_projected.y * 480.0f));
  float pixel_dx = (pixel_projected.x - pixel_roi.x_center) * 640.0f;
  float pixel_dy = (pixel_projected.y - pixel_roi.y_center) * 480.0f;
  float pixel_cosine = cosf(pixel_roi.rotation);
  float pixel_sine = sinf(pixel_roi.rotation);
  float recovered_pixel_x =
      (pixel_cosine * pixel_dx + pixel_sine * pixel_dy) /
          (pixel_roi.width * 640.0f) + 0.5f;
  float recovered_pixel_y =
      (-pixel_sine * pixel_dx + pixel_cosine * pixel_dy) /
          (pixel_roi.height * 480.0f) + 0.5f;
  assert(near(recovered_pixel_x, local_marker.x));
  assert(near(recovered_pixel_y, local_marker.y));

  float boxes[2 * 12] = {0};
  float logits[2] = {-3.0f, 3.0f};
  boxes[12 + 2] = 10.0f;
  boxes[12 + 3] = 10.0f;
  BlazePoseAnchor pair[2] = {center_anchor, center_anchor};
  BlazePoseDetection best = {0};
  assert(BlazePoseSelectBestDetection(boxes, logits, pair, 2, 0.5f, &best));
  assert(best.score > 0.95f);

  // Le seuil 0,5 est inclusif, tandis que NaN est rejeté explicitement.
  float boundary_box[12] = {0};
  boundary_box[2] = 22.4f;
  boundary_box[3] = 22.4f;
  float boundary_logit = 0.0f;
  assert(BlazePoseSelectBestDetection(boundary_box, &boundary_logit,
                                      &center_anchor, 1, 0.5f, &best));
  float invalid_logit = NAN;
  assert(!BlazePoseSelectBestDetection(boundary_box, &invalid_logit,
                                       &center_anchor, 1, 0.5f, &best));
  float positive_clipped_logit = 100.0f;
  assert(BlazePoseSelectBestDetection(boundary_box, &positive_clipped_logit,
                                      &center_anchor, 1, 0.5f, &best));
  assert(near(best.score, 1.0f));
  float negative_clipped_logit = -100.0f;
  assert(!BlazePoseSelectBestDetection(boundary_box, &negative_clipped_logit,
                                       &center_anchor, 1, 0.5f, &best));
  float invalid_box[12] = {0};
  invalid_box[0] = NAN;
  invalid_box[2] = 22.4f;
  invalid_box[3] = 22.4f;
  assert(!BlazePoseSelectBestDetection(invalid_box, &boundary_logit,
                                       &center_anchor, 1, 0.5f, &best));

  // Deux boites fortement superposees sont fusionnees par weighted NMS.
  float overlapping_boxes[24] = {0};
  float overlapping_logits[2] = {2.0f, 1.0f};
  for (int index = 0; index < 2; ++index) {
    overlapping_boxes[index * 12 + 0] = index == 0 ? -11.2f : 11.2f;
    overlapping_boxes[index * 12 + 2] = 112.0f;
    overlapping_boxes[index * 12 + 3] = 112.0f;
    for (int point = 0; point < 4; ++point) {
      overlapping_boxes[index * 12 + 4 + point * 2] =
          overlapping_boxes[index * 12 + 0] + (float)point * 5.0f;
      overlapping_boxes[index * 12 + 5 + point * 2] =
          (float)(point + index) * 7.0f;
    }
  }
  BlazePoseDetection decoded0 = BlazePoseDecodeDetection(
      overlapping_boxes, overlapping_logits[0], center_anchor);
  BlazePoseDetection decoded1 = BlazePoseDecodeDetection(
      overlapping_boxes + 12, overlapping_logits[1], center_anchor);
  float total = decoded0.score + decoded1.score;
  assert(BlazePoseSelectBestDetection(overlapping_boxes, overlapping_logits,
                                      pair, 2, 0.5f, &best));
  assert(near(best.score, decoded0.score));
  assert(near(best.x_min,
              (decoded0.x_min * decoded0.score +
               decoded1.x_min * decoded1.score) /
                  total));
  assert(near(best.y_min,
              (decoded0.y_min * decoded0.score +
               decoded1.y_min * decoded1.score) /
                  total));
  assert(near(best.x_max,
              (decoded0.x_max * decoded0.score +
               decoded1.x_max * decoded1.score) /
                  total));
  assert(near(best.y_max,
              (decoded0.y_max * decoded0.score +
               decoded1.y_max * decoded1.score) /
                  total));
  for (int point = 0; point < 4; ++point) {
    assert(near(best.keypoints[point].x,
                (decoded0.keypoints[point].x * decoded0.score +
                 decoded1.keypoints[point].x * decoded1.score) /
                    total));
    assert(near(best.keypoints[point].y,
                (decoded0.keypoints[point].y * decoded0.score +
                 decoded1.keypoints[point].y * decoded1.score) /
                    total));
  }

  // A la frontiere IoU=0,3, la seconde boite n'est pas fusionnee (> strict).
  float threshold_boxes[24] = {0};
  float threshold_logits[2] = {2.0f, 1.0f};
  for (int index = 0; index < 2; ++index) {
    threshold_boxes[index * 12] =
        index == 0 ? 0.0f : 224.0f * (0.5f * 0.7f / 1.3f);
    threshold_boxes[index * 12 + 2] = 112.0f;
    threshold_boxes[index * 12 + 3] = 112.0f;
  }
  BlazePoseDetection threshold_seed = BlazePoseDecodeDetection(
      threshold_boxes, threshold_logits[0], center_anchor);
  assert(BlazePoseSelectBestDetection(threshold_boxes, threshold_logits, pair,
                                      2, 0.5f, &best));
  assert(near(best.x_min, threshold_seed.x_min));
  assert(near(best.x_max, threshold_seed.x_max));

  // Align suit une personne : un second cluster disjoint n'est pas retourne.
  float clustered_boxes[36] = {0};
  float clustered_logits[3] = {3.0f, 2.0f, 2.5f};
  BlazePoseAnchor clusters[3] = {
      {.x = 0.25f, .y = 0.5f, .width = 1.0f, .height = 1.0f},
      {.x = 0.27f, .y = 0.5f, .width = 1.0f, .height = 1.0f},
      {.x = 0.85f, .y = 0.5f, .width = 1.0f, .height = 1.0f},
  };
  for (int index = 0; index < 3; ++index) {
    clustered_boxes[index * 12 + 2] = 44.8f;
    clustered_boxes[index * 12 + 3] = 44.8f;
  }
  assert(BlazePoseSelectBestDetection(clustered_boxes, clustered_logits,
                                      clusters, 3, 0.5f, &best));
  assert(best.x_min < 0.2f);
  assert(best.x_max < 0.4f);

  // A/B synthetique a 2 Hz : le filtre reduit le jitter quasi statique sans
  // ecraser une asymetrie soudaine entre les deux epaules.
  BlazePoseOneEuroFilter left_y = {0};
  BlazePoseOneEuroFilter right_y = {0};
  const float static_left[] = {0.500f, 0.508f, 0.493f, 0.506f, 0.494f};
  const float static_right[] = {0.500f, 0.492f, 0.507f, 0.494f, 0.506f};
  float raw_motion = 0.0f;
  float filtered_motion = 0.0f;
  float previous_filtered_left = static_left[0];
  float previous_filtered_right = static_right[0];
  for (int index = 0; index < 5; ++index) {
    double timestamp = (double)index * 0.5;
    float filtered_left = BlazePoseFilterNormalizedCoordinate(
        &left_y, static_left[index], timestamp, 2.0f);
    float filtered_right = BlazePoseFilterNormalizedCoordinate(
        &right_y, static_right[index], timestamp, 2.0f);
    if (index > 0) {
      raw_motion += fabsf(static_left[index] - static_left[index - 1]) +
                    fabsf(static_right[index] - static_right[index - 1]);
      filtered_motion += fabsf(filtered_left - previous_filtered_left) +
                         fabsf(filtered_right - previous_filtered_right);
    }
    previous_filtered_left = filtered_left;
    previous_filtered_right = filtered_right;
  }
  assert(filtered_motion < raw_motion * 0.9f);

  // Une epaule monte de 0,12 image tandis que l'autre reste stable. Le beta
  // adaptatif doit conserver au moins 90 % de l'ecart dans la frame courante.
  float left_raised = BlazePoseFilterNormalizedCoordinate(
      &left_y, 0.374f, 2.5, 2.0f);
  float right_stable = BlazePoseFilterNormalizedCoordinate(
      &right_y, 0.500f, 2.5, 2.0f);
  assert(right_stable - left_raised >= 0.108f);

  BlazePoseResetOneEuroFilter(&left_y);
  assert(!left_y.initialized);

  // Le filtre compose possede quatre etats independants et calcule son echelle
  // depuis la vraie ROI en pixels, comme MediaPipe.
  BlazePoseShoulderFilter shoulder_filter = {0};
  BlazePoseLandmark left = {.x = 0.30f, .y = 0.50f};
  BlazePoseLandmark right = {.x = 0.70f, .y = 0.50f};
  BlazePoseLandmark filtered_left;
  BlazePoseLandmark filtered_right;
  BlazePoseRoi small_roi = {.width = 0.25f, .height = 0.25f};
  assert(BlazePoseFilterShoulders(
      &shoulder_filter, 1, left, 1, right, small_roi, 640, 480, 10.0, 1.0, 7,
      &filtered_left, &filtered_right));
  assert(near(filtered_left.x, left.x));
  assert(near(filtered_right.y, right.y));
  left.x += 0.01f;
  left.y -= 0.12f;
  right.x -= 0.02f;
  assert(BlazePoseFilterShoulders(
      &shoulder_filter, 1, left, 1, right, small_roi, 640, 480, 10.5, 1.0, 7,
      &filtered_left, &filtered_right));
  assert(filtered_left.y < 0.395f);
  assert(filtered_right.x < 0.70f);
  assert(!near(shoulder_filter.left_x.last_filtered,
               shoulder_filter.left_y.last_filtered));
  assert(!near(shoulder_filter.left_x.last_filtered,
               shoulder_filter.right_x.last_filtered));

  // Une grande ROI lisse davantage la meme petite variation; la rotation ne
  // change pas l'echelle, conformement au calcul MediaPipe de la ROI.
  BlazePoseShoulderFilter large_filter = {0};
  BlazePoseShoulderFilter size_comparison_small = {0};
  BlazePoseShoulderFilter rotated_filter = {0};
  BlazePoseRoi large_roi = {.width = 0.80f, .height = 0.70f};
  BlazePoseRoi rotated_roi = large_roi;
  rotated_roi.rotation = 0.8f;
  left = (BlazePoseLandmark){.x = 0.30f, .y = 0.50f};
  right = (BlazePoseLandmark){.x = 0.70f, .y = 0.50f};
  assert(BlazePoseFilterShoulders(&large_filter, 1, left, 1, right, large_roi,
                                  640, 480, 20.0, 1.0, 8, &filtered_left,
                                  &filtered_right));
  BlazePoseLandmark small_left;
  BlazePoseLandmark small_right;
  assert(BlazePoseFilterShoulders(&size_comparison_small, 1, left, 1, right,
                                  small_roi, 640, 480, 20.0, 1.0, 8,
                                  &small_left, &small_right));
  BlazePoseLandmark rotated_left;
  BlazePoseLandmark rotated_right;
  assert(BlazePoseFilterShoulders(&rotated_filter, 1, left, 1, right,
                                  rotated_roi, 640, 480, 20.0, 1.0, 8,
                                  &rotated_left,
                                  &rotated_right));
  left.x += 0.004f;
  assert(BlazePoseFilterShoulders(&size_comparison_small, 1, left, 1, right,
                                  small_roi, 640, 480, 20.5, 1.0, 8,
                                  &small_left, &small_right));
  assert(BlazePoseFilterShoulders(&large_filter, 1, left, 1, right, large_roi,
                                  640, 480, 20.5, 1.0, 8, &filtered_left,
                                  &filtered_right));
  assert(BlazePoseFilterShoulders(&rotated_filter, 1, left, 1, right,
                                  rotated_roi, 640, 480, 20.5, 1.0, 8,
                                  &rotated_left,
                                  &rotated_right));
  assert(near(filtered_left.x, rotated_left.x));
  assert(small_left.x > filtered_left.x);

  // Timestamp discontinu : les quatre axes repartent de la nouvelle mesure.
  left = (BlazePoseLandmark){.x = 0.15f, .y = 0.20f};
  right = (BlazePoseLandmark){.x = 0.85f, .y = 0.25f};
  assert(BlazePoseFilterShoulders(&large_filter, 1, left, 1, right, large_roi,
                                  640, 480, 22.0, 1.0, 8, &filtered_left,
                                  &filtered_right));
  assert(near(filtered_left.x, left.x));
  assert(near(filtered_left.y, left.y));
  assert(near(filtered_right.x, right.x));
  assert(near(filtered_right.y, right.y));

  // Un resultat partiel ne reutilise jamais l'ancien etat de l'epaule perdue.
  assert(BlazePoseFilterShoulders(&large_filter, 1, left, 0, right, large_roi,
                                  640, 480, 22.5, 1.0, 8, &filtered_left,
                                  &filtered_right));
  assert(large_filter.left_x.initialized && large_filter.left_y.initialized);
  assert(!large_filter.right_x.initialized &&
         !large_filter.right_y.initialized);
  assert(BlazePoseFilterShoulders(&large_filter, 0, left, 0, right, large_roi,
                                  640, 480, 23.0, 1.0, 8, &filtered_left,
                                  &filtered_right) ==
         BLAZEPOSE_SHOULDER_FILTER_NO_PERSON);
  assert(large_filter.has_timestamp && near((float)large_filter.last_timestamp, 23.0f) &&
         large_filter.has_generation && large_filter.generation == 8);
  assert(BlazePoseFilterShoulders(&large_filter, 1, left, 1, right, large_roi,
                                  640, 480, 22.9, 1.0, 8, &filtered_left,
                                  &filtered_right) ==
         BLAZEPOSE_SHOULDER_FILTER_STALE);
  assert(large_filter.has_timestamp && near((float)large_filter.last_timestamp, 23.0f));

  // Une ancienne generation et un timestamp non croissant sont inertes.
  assert(BlazePoseFilterShoulders(&large_filter, 1, left, 1, right, large_roi,
                                  640, 480, 30.0, 1.0, 9, &filtered_left,
                                  &filtered_right));
  assert(BlazePoseFilterShoulders(&large_filter, 1, left, 1, right, large_roi,
                                  640, 480, 30.5, 1.0, 8, &filtered_left,
                                  &filtered_right) ==
         BLAZEPOSE_SHOULDER_FILTER_STALE);
  assert(large_filter.generation == 9 && large_filter.has_timestamp);
  BlazePoseLandmark invalid_left = left;
  invalid_left.x = NAN;
  assert(BlazePoseFilterShoulders(&large_filter, 1, invalid_left, 1, right,
                                  large_roi, 640, 480, 31.0, 1.0, 8,
                                  &filtered_left, &filtered_right) ==
         BLAZEPOSE_SHOULDER_FILTER_STALE);
  assert(large_filter.generation == 9 && large_filter.has_timestamp);
  assert(BlazePoseFilterShoulders(&large_filter, 1, left, 1, right, large_roi,
                                  640, 480, 30.0, 1.0, 9, &filtered_left,
                                  &filtered_right) ==
         BLAZEPOSE_SHOULDER_FILTER_STALE);
  assert(large_filter.has_timestamp && near((float)large_filter.last_timestamp, 30.0f) &&
         large_filter.has_generation && large_filter.generation == 9);
  assert(BlazePoseFilterShoulders(&large_filter, 1, invalid_left, 1, right,
                                  large_roi, 640, 480, 31.0, 1.0, 9,
                                  &filtered_left, &filtered_right) ==
         BLAZEPOSE_SHOULDER_FILTER_TECHNICAL_ERROR);
  assert(large_filter.has_timestamp && near((float)large_filter.last_timestamp, 30.0f));
  assert(BlazePoseFilterShoulders(&large_filter, 1, left, 1, right, large_roi,
                                  640, 480, 29.9, 1.0, 9, &filtered_left,
                                  &filtered_right) ==
         BLAZEPOSE_SHOULDER_FILTER_STALE);

  // Une generation superieure invalide reste autoritaire.
  assert(BlazePoseFilterShoulders(&large_filter, 1, invalid_left, 1, right,
                                  large_roi, 640, 480, 40.0, 1.0, 10,
                                  &filtered_left, &filtered_right) ==
         BLAZEPOSE_SHOULDER_FILTER_TECHNICAL_ERROR);
  assert(large_filter.generation == 10 && !large_filter.has_timestamp);

  assert(BlazePoseFilterShoulders(&large_filter, 0, left, 0, right,
                                  (BlazePoseRoi){0}, 640, 480, 41.0, 1.0, 11,
                                  &filtered_left, &filtered_right) ==
         BLAZEPOSE_SHOULDER_FILTER_NO_PERSON);
  assert(large_filter.generation == 11 && large_filter.has_timestamp &&
         near((float)large_filter.last_timestamp, 41.0f));
  assert(BlazePoseFilterShoulders(&large_filter, 1, left, 1, right, large_roi,
                                  640, 480, 41.2, 1.0, 10, &filtered_left,
                                  &filtered_right) ==
         BLAZEPOSE_SHOULDER_FILTER_STALE);
  assert(large_filter.generation == 11 &&
         near((float)large_filter.last_timestamp, 41.0f));
  assert(BlazePoseFilterShoulders(&large_filter, 1, left, 1, right, large_roi,
                                  640, 480, 40.2, 1.0, 9, &filtered_left,
                                  &filtered_right) ==
         BLAZEPOSE_SHOULDER_FILTER_STALE);
  assert(large_filter.generation == 11 && large_filter.has_timestamp &&
         near((float)large_filter.last_timestamp, 41.0f));
  BlazePoseResetShoulderFilter(&large_filter);
  assert(!large_filter.has_timestamp && !large_filter.left_x.initialized &&
         !large_filter.left_y.initialized && !large_filter.right_x.initialized &&
         !large_filter.right_y.initialized);

  puts("BlazePoseGeometryHarness: OK");
  return 0;
}
