#include "rtmpose_onnx_bridge.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void test_geometry(void) {
  AlignRTMPoseNormalizedCrop crop =
      AlignRTMPoseFaceAnchoredCrop(0.50f, 0.28f, 0.10f, 0.22f, 640, 360);
  /* The helper has no roll argument: changing face roll cannot alter this ROI. */
  AlignRTMPoseNormalizedCrop same =
      AlignRTMPoseFaceAnchoredCrop(0.50f, 0.28f, 0.10f, 0.22f, 640, 360);
  assert(memcmp(&crop, &same, sizeof(crop)) == 0);
  assert(crop.width > 0.0f && crop.height > 0.0f);
  const float pixel_aspect = crop.width * 640.0f / (crop.height * 360.0f);
  assert(fabsf(pixel_aspect - (192.0f / 256.0f)) < 0.0001f);

  /* Two asymmetric source shoulders must round-trip through ROI-local model
   * coordinates without swapping sides or flipping vertical order. */
  const float source_left_x = 0.34f;
  const float source_left_y = 0.64f;
  const float source_right_x = 0.66f;
  const float source_right_y = 0.52f;
  const float local_left_x = (source_left_x - crop.x) / crop.width;
  const float local_left_y = (source_left_y - crop.y) / crop.height;
  const float local_right_x = (source_right_x - crop.x) / crop.width;
  const float local_right_y = (source_right_y - crop.y) / crop.height;
  float projected_left_x = 0.0f;
  float projected_left_y = 0.0f;
  float projected_right_x = 0.0f;
  float projected_right_y = 0.0f;
  AlignRTMPoseProjectPoint(crop, local_left_x, local_left_y,
                           &projected_left_x, &projected_left_y);
  AlignRTMPoseProjectPoint(crop, local_right_x, local_right_y,
                           &projected_right_x, &projected_right_y);
  assert(fabsf(projected_left_x - source_left_x) < 0.00001f);
  assert(fabsf(projected_left_y - source_left_y) < 0.00001f);
  assert(fabsf(projected_right_x - source_right_x) < 0.00001f);
  assert(fabsf(projected_right_y - source_right_y) < 0.00001f);
  assert(projected_left_x < projected_right_x);
  assert(projected_left_y > projected_right_y);

  AlignRTMPoseNormalizedCrop four_three =
      AlignRTMPoseFaceAnchoredCrop(0.50f, 0.28f, 0.16f, 0.22f, 640, 480);
  assert(fabsf(four_three.width * 640.0f /
               (four_three.height * 480.0f) - (192.0f / 256.0f)) < 0.0001f);
  AlignRTMPoseNormalizedCrop left_edge =
      AlignRTMPoseFaceAnchoredCrop(0.03f, 0.12f, 0.16f, 0.22f, 640, 360);
  AlignRTMPoseNormalizedCrop right_edge =
      AlignRTMPoseFaceAnchoredCrop(0.97f, 0.12f, 0.16f, 0.22f, 640, 360);
  assert(left_edge.x == 0.0f);
  assert(right_edge.x + right_edge.width <= 1.0f);
  printf("RTMPose geometry: OK crop=(%.3f,%.3f,%.3f,%.3f)\n", crop.x,
         crop.y, crop.width, crop.height);
}

int main(int argc, char **argv) {
  if (argc < 3 || argc > 4) {
    fprintf(stderr, "usage: %s MODEL.onnx libonnxruntime.dylib [coreml]\n",
            argv[0]);
    return 2;
  }
  test_geometry();
  const int use_coreml = argc == 4 && strcmp(argv[3], "coreml") == 0;
  AlignRTMPoseRunner *runner =
      AlignRTMPoseCreate(argv[1], argv[2], use_coreml);
  if (runner == NULL) {
    fprintf(stderr, "RTMPose create failed\n");
    return 1;
  }
  const size_t width = 640;
  const size_t height = 480;
  const size_t stride = width * 4;
  uint8_t *image = calloc(height, stride);
  assert(image != NULL);
  for (size_t y = 0; y < height; ++y) {
    for (size_t x = 0; x < width; ++x) {
      uint8_t *pixel = image + y * stride + x * 4;
      pixel[0] = (uint8_t)(x & 255); /* B */
      pixel[1] = (uint8_t)(y & 255); /* G */
      pixel[2] = (uint8_t)((x + y) & 255); /* R */
      pixel[3] = 255;
    }
  }
  AlignRTMPoseNormalizedCrop crop =
      AlignRTMPoseFaceAnchoredCrop(0.50f, 0.40f, 0.16f, 0.22f, 640, 480);
  AlignRTMPoseResult result;
  int ok = AlignRTMPoseAnalyzeBGRA(
      runner, image, width, height, stride, crop, 1, 42, 12.5, 7, 0.0f,
      &result);
  assert(ok == 1);
  assert(result.status == ALIGN_RTMPOSE_AVAILABLE);
  assert(result.sample_id == 42 && result.generation == 7);
  assert(result.timestamp_seconds == 12.5);
  int valid_count = 0;
  for (size_t i = 0; i < ALIGN_RTMPOSE_KEYPOINT_COUNT; ++i) {
    assert(AlignRTMPoseKeypointName(i) != NULL);
    if (result.points[i].valid) {
      ++valid_count;
      assert(isfinite(result.points[i].x) && isfinite(result.points[i].y));
      assert(result.points[i].x >= 0.0f && result.points[i].x <= 1.0f);
      assert(result.points[i].y >= 0.0f && result.points[i].y <= 1.0f);
    }
  }
  assert(valid_count > 0);
  assert(result.valid_count == valid_count);
  assert(isfinite(result.simcc_min) && isfinite(result.simcc_max));
  assert(isfinite(result.left_shoulder_score) &&
         isfinite(result.right_shoulder_score));
  printf("RTMPose invoke: OK status=available valid=%d/26 provider=%s\n",
         valid_count, result.used_coreml ? "CoreML" : "CPU");
  printf("RTMPose diagnostics: simcc=[%.3f,%.3f] scores=[%.3f,%.3f] "
         "shoulders=[%.3f,%.3f]\n",
         result.simcc_min, result.simcc_max, result.score_min,
         result.score_max, result.left_shoulder_score,
         result.right_shoulder_score);

  /* Exercise repeated calls on the same runner. The production worker keeps
   * one serialized runner alive, so this also guards the reused input tensor
   * and OrtMemoryInfo lifetime introduced for the always-on path. */
  for (uint64_t repeat = 0; repeat < 3; ++repeat) {
    AlignRTMPoseResult repeated;
    ok = AlignRTMPoseAnalyzeBGRA(
        runner, image, width, height, stride, crop, 1, 100 + repeat,
        20.0 + (double)repeat, 7, 0.20f, &repeated);
    assert(ok == 1 && repeated.status == ALIGN_RTMPOSE_AVAILABLE);
    assert(repeated.valid_count > 0);
  }
  printf("RTMPose repeated invoke: OK calls=3\n");

  AlignRTMPoseResult thresholded;
  ok = AlignRTMPoseAnalyzeBGRA(
      runner, image, width, height, stride, crop, 1, 44, 14.5, 7, 0.20f,
      &thresholded);
  assert(ok == 1);
  assert(thresholded.valid_count <= result.valid_count);
  /* The official SimCC decoder uses raw maxima. This assertion is a
   * regression guard: a second softmax would shrink the synthetic model
   * scores below 0.20 and incorrectly turn this call into NO_PERSON. */
  assert(thresholded.status == ALIGN_RTMPOSE_AVAILABLE);
  assert(thresholded.valid_count > 0);
  assert(thresholded.score_max >= 0.20f);
  printf("RTMPose threshold 0.20: status=%s valid=%d/26\n",
         thresholded.status == ALIGN_RTMPOSE_AVAILABLE ? "available" :
                                                          "noPerson",
         thresholded.valid_count);

  memset(&result, 0, sizeof(result));
  ok = AlignRTMPoseAnalyzeBGRA(runner, image, width, height, stride, crop, 0,
                               43, 13.5, 8, 0.0f, &result);
  assert(ok == 1 && result.status == ALIGN_RTMPOSE_NO_PERSON);
  printf("RTMPose noPerson gate: OK\n");

  free(image);
  AlignRTMPoseDestroy(runner);
  return 0;
}
