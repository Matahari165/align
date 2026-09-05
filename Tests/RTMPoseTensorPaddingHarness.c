/* Include the bridge implementation in this focused native harness so the
 * private tensor builder can be checked without adding a production API. */
#include "../Align/Pose/RTMPose/rtmpose_onnx_bridge.c"

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static void expect_close(float actual, float expected, float epsilon) {
  assert(fabsf(actual - expected) <= epsilon);
}

static float tensor_value(const float *tensor, int channel, int x, int y) {
  return tensor[(size_t)channel * kInputHeight * kInputWidth +
                (size_t)y * kInputWidth + (size_t)x];
}

static void test_landscape_padding_and_sampling(void) {
  const size_t width = 16;
  const size_t height = 9;
  const size_t stride = width * 4;
  uint8_t image[height * stride];
  for (size_t pixel = 0; pixel < width * height; ++pixel) {
    image[pixel * 4 + 0] = 10;  /* B */
    image[pixel * 4 + 1] = 20;  /* G */
    image[pixel * 4 + 2] = 30;  /* R */
    image[pixel * 4 + 3] = 255;
  }

  float *tensor = calloc((size_t)3 * kInputWidth * kInputHeight,
                         sizeof(float));
  assert(tensor != NULL);
  const AlignRTMPoseNormalizedCrop crop = {0.0f, 0.0f, 1.0f, 1.0f};
  build_tensor(image, width, height, stride, crop, tensor);

  /* The 16:9 source is letterboxed vertically into the 192:256 input. */
  expect_close(tensor_value(tensor, 0, 96, 0),
               -123.675f / 58.395f, 0.00001f);
  expect_close(tensor_value(tensor, 1, 96, 0),
               -116.28f / 57.12f, 0.00001f);
  expect_close(tensor_value(tensor, 2, 96, 0),
               -103.53f / 57.375f, 0.00001f);

  /* A point in the content samples the same source color, with no aspect
   * stretch or channel swap. */
  expect_close(tensor_value(tensor, 0, 96, 128),
               (30.0f - 123.675f) / 58.395f, 0.00001f);
  expect_close(tensor_value(tensor, 1, 96, 128),
               (20.0f - 116.28f) / 57.12f, 0.00001f);
  expect_close(tensor_value(tensor, 2, 96, 128),
               (10.0f - 103.53f) / 57.375f, 0.00001f);
  free(tensor);
}

static void test_matching_aspect_has_no_padding(void) {
  const size_t width = 12;
  const size_t height = 16;
  const size_t stride = width * 4;
  uint8_t image[height * stride];
  for (size_t pixel = 0; pixel < width * height; ++pixel) {
    image[pixel * 4 + 0] = 10;
    image[pixel * 4 + 1] = 20;
    image[pixel * 4 + 2] = 30;
    image[pixel * 4 + 3] = 255;
  }

  float *tensor = calloc((size_t)3 * kInputWidth * kInputHeight,
                         sizeof(float));
  assert(tensor != NULL);
  const AlignRTMPoseNormalizedCrop crop = {0.0f, 0.0f, 1.0f, 1.0f};
  build_tensor(image, width, height, stride, crop, tensor);
  expect_close(tensor_value(tensor, 0, 96, 0),
               (30.0f - 123.675f) / 58.395f, 0.00001f);
  free(tensor);
}

int main(void) {
  test_landscape_padding_and_sampling();
  test_matching_aspect_has_no_padding();
  puts("RTMPoseTensorPaddingHarness: OK");
  return 0;
}
