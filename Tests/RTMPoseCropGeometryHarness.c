#include "rtmpose_onnx_bridge.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>

static void expect_close(float actual, float expected, float epsilon) {
  assert(fabsf(actual - expected) <= epsilon);
}

static void test_face_crop_keeps_model_aspect(void) {
  const AlignRTMPoseNormalizedCrop crop =
      AlignRTMPoseFaceAnchoredCrop(0.50f, 0.28f, 0.10f, 0.22f, 1280, 720);
  const float aspect = crop.width * 1280.0f / (crop.height * 720.0f);
  expect_close(aspect, 192.0f / 256.0f, 0.00001f);

  const AlignRTMPoseModelContentRect content =
      AlignRTMPoseModelContentRectForCrop(crop, 1280, 720);
  expect_close(content.x, 0.0f, 0.00001f);
  expect_close(content.y, 0.0f, 0.00001f);
  expect_close(content.width, 1.0f, 0.00001f);
  expect_close(content.height, 1.0f, 0.00001f);
}

static void test_landscape_fallback_is_letterboxed(void) {
  const AlignRTMPoseNormalizedCrop fallback = {0.05f, 0.02f, 0.90f, 0.96f};
  const AlignRTMPoseModelContentRect content =
      AlignRTMPoseModelContentRectForCrop(fallback, 1280, 720);
  const float source_aspect = fallback.width * 1280.0f /
                              (fallback.height * 720.0f);
  const float content_aspect = content.width * 192.0f /
                               (content.height * 256.0f);
  expect_close(source_aspect, 1.6666666f, 0.00001f);
  expect_close(content_aspect, source_aspect, 0.00001f);
  expect_close(content.x, 0.0f, 0.00001f);
  expect_close(content.width, 1.0f, 0.00001f);
  expect_close(content.height, 0.45f, 0.00001f);
  expect_close(content.y, 0.275f, 0.00001f);

  const float local_x = content.x + 0.4f * content.width;
  const float local_y = content.y + 0.7f * content.height;
  float projected_x = 0.0f;
  float projected_y = 0.0f;
  assert(AlignRTMPoseProjectPointWithContent(
      fallback, content, local_x, local_y, &projected_x, &projected_y));
  expect_close(projected_x, fallback.x + 0.4f * fallback.width, 0.00001f);
  expect_close(projected_y, fallback.y + 0.7f * fallback.height, 0.00001f);
  /* A SimCC peak in top padding must never become an anatomical point. */
  assert(!AlignRTMPoseProjectPointWithContent(
      fallback, content, 0.5f, 0.1f, &projected_x, &projected_y));
}

static void test_portrait_fallback_has_side_padding(void) {
  const AlignRTMPoseNormalizedCrop fallback = {0.05f, 0.02f, 0.90f, 0.96f};
  const AlignRTMPoseModelContentRect content =
      AlignRTMPoseModelContentRectForCrop(fallback, 720, 1280);
  expect_close(content.height, 1.0f, 0.00001f);
  expect_close(content.width, 0.703125f, 0.00001f);
  expect_close(content.x, 0.1484375f, 0.00001f);
  expect_close(content.y, 0.0f, 0.00001f);

  float projected_x = 0.0f;
  float projected_y = 0.0f;
  assert(AlignRTMPoseProjectPointWithContent(
      fallback, content, content.x + 0.2f * content.width,
      0.8f, &projected_x, &projected_y));
  expect_close(projected_x, fallback.x + 0.2f * fallback.width, 0.00001f);
  expect_close(projected_y, fallback.y + 0.8f * fallback.height, 0.00001f);
  assert(!AlignRTMPoseProjectPointWithContent(
      fallback, content, 0.05f, 0.5f, &projected_x, &projected_y));
}

int main(void) {
  test_face_crop_keeps_model_aspect();
  test_landscape_fallback_is_letterboxed();
  test_portrait_fallback_has_side_padding();
  puts("RTMPoseCropGeometryHarness: OK");
  return 0;
}
