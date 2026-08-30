#include "blazepose_pipeline.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static int near(float left, float right) { return fabsf(left - right) < 1e-4f; }

int main(void) {
  float image[4 * 2 * 3];
  for (size_t index = 0; index < 4 * 2 * 3; ++index) image[index] = 0.5f;
  float *boxes = calloc(2254 * 12, sizeof(float));
  float *scores = malloc(2254 * sizeof(float));
  float *landmark_input = malloc(256 * 256 * 3 * sizeof(float));
  assert(boxes != NULL && scores != NULL && landmark_input != NULL);
  for (size_t index = 0; index < 2254; ++index) scores[index] = -10.0f;
  scores[0] = 10.0f;
  // Deux points d'alignement distincts et une boîte positive.
  boxes[2] = 40.0f;
  boxes[3] = 40.0f;
  boxes[6] = 0.0f;
  boxes[7] = -40.0f;
  BlazePoseRoi roi;
  assert(BlazePosePrepareLandmarkInput(image, 0, 2, boxes, scores,
                                       landmark_input, &roi) ==
         BLAZEPOSE_PIPELINE_ERROR);
  assert(BlazePosePrepareLandmarkInput(image, 4, 2, boxes, scores,
                                       landmark_input, &roi) ==
         BLAZEPOSE_PIPELINE_OK);
  assert(roi.width > 0.0f && roi.height > 0.0f);
  boxes[6] = 0.0f;
  boxes[7] = 0.0f;
  assert(BlazePosePrepareLandmarkInput(image, 4, 2, boxes, scores,
                                       landmark_input, &roi) ==
         BLAZEPOSE_PIPELINE_ERROR);
  boxes[7] = -40.0f;
  assert(BlazePosePrepareLandmarkInput(image, 4, 2, boxes, scores,
                                       landmark_input, &roi) ==
         BLAZEPOSE_PIPELINE_OK);

  float raw_landmarks[195] = {0};
  float heatmap[64 * 64 * 39] = {0};
  raw_landmarks[11 * 5] = 96.0f;
  raw_landmarks[11 * 5 + 1] = 128.0f;
  raw_landmarks[11 * 5 + 3] = 4.0f;
  raw_landmarks[11 * 5 + 4] = 4.0f;
  raw_landmarks[12 * 5] = 160.0f;
  raw_landmarks[12 * 5 + 1] = 128.0f;
  raw_landmarks[12 * 5 + 3] = 4.0f;
  raw_landmarks[12 * 5 + 4] = 4.0f;
  BlazePoseUpperBody upper_body;
  assert(BlazePoseDecodeUpperBody(raw_landmarks, 0.49f, heatmap, roi,
                                  &upper_body) ==
         BLAZEPOSE_PIPELINE_NO_PERSON);
  assert(BlazePoseDecodeUpperBody(raw_landmarks, NAN, heatmap, roi,
                                  &upper_body) == BLAZEPOSE_PIPELINE_ERROR);
  raw_landmarks[0] = NAN;
  assert(BlazePoseDecodeUpperBody(raw_landmarks, 0.9f, heatmap, roi,
                                  &upper_body) == BLAZEPOSE_PIPELINE_ERROR);
  raw_landmarks[0] = 0.0f;
  assert(BlazePoseDecodeUpperBody(raw_landmarks, 0.9f, heatmap, roi,
                                  &upper_body) == BLAZEPOSE_PIPELINE_OK);
  assert(near(upper_body.estimated_neck.x,
              (upper_body.left_shoulder.x + upper_body.right_shoulder.x) /
                  2.0f));
  assert(near(upper_body.estimated_neck.y,
              (upper_body.left_shoulder.y + upper_body.right_shoulder.y) /
                  2.0f));
  assert(upper_body.estimated_neck.visibility > 0.98f);

  free(boxes);
  free(scores);
  free(landmark_input);
  puts("BlazePosePipelineHarness: OK");
  return 0;
}
