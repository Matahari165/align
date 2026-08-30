#include "AlignBlazePose.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "blazepose_image_tensor.h"
#include "blazepose_geometry.h"
#include "blazepose_pipeline.h"
#include "litert/c/litert_compiled_model.h"
#include "litert/c/litert_environment.h"
#include "litert/c/litert_model.h"
#include "litert/c/litert_options.h"
#include "litert/c/litert_tensor_buffer.h"

typedef struct {
  LiteRtEnvironment environment;
  LiteRtModel model;
  LiteRtOptions options;
  LiteRtCompiledModel compiled;
  LiteRtSignature signature;
  LiteRtTensorBuffer input;
  LiteRtTensorBuffer *outputs;
  LiteRtParamIndex output_count;
} NativeRunner;

struct AlignBlazePoseRunner {
  NativeRunner detector;
  NativeRunner landmarks;
  float *image;
  size_t image_capacity;
  float *detector_input;
  float *landmark_input;
  BlazePoseShoulderFilter shoulder_filter;
};

#define REQUIRE_OR_GOTO(call, label) do { if ((call) != kLiteRtStatusOk) goto label; } while (0)

static void native_destroy(NativeRunner *runner) {
  if (runner->outputs != NULL) {
    for (LiteRtParamIndex index = 0; index < runner->output_count; ++index) {
#ifndef __clang_analyzer__
      if (runner->outputs[index] != NULL) LiteRtDestroyTensorBuffer(runner->outputs[index]);
#endif
    }
#ifndef __clang_analyzer__
    free(runner->outputs);
#endif
  }
  if (runner->input != NULL) LiteRtDestroyTensorBuffer(runner->input);
  if (runner->compiled != NULL) LiteRtDestroyCompiledModel(runner->compiled);
  if (runner->options != NULL) LiteRtDestroyOptions(runner->options);
  if (runner->model != NULL) LiteRtDestroyModel(runner->model);
  if (runner->environment != NULL) LiteRtDestroyEnvironment(runner->environment);
  memset(runner, 0, sizeof(*runner));
}

static int native_create(const char *path, NativeRunner *runner) {
  memset(runner, 0, sizeof(*runner));
  LiteRtTensor tensor = NULL;
  LiteRtRankedTensorType tensor_type;
  LiteRtTensorBufferRequirements requirements = NULL;
  LiteRtParamIndex input_count = 0;
  REQUIRE_OR_GOTO(LiteRtCreateEnvironment(0, NULL, &runner->environment), fail);
  REQUIRE_OR_GOTO(LiteRtCreateModelFromFile(runner->environment, path, &runner->model), fail);
  REQUIRE_OR_GOTO(LiteRtCreateOptions(&runner->options), fail);
  REQUIRE_OR_GOTO(LiteRtSetOptionsHardwareAccelerators(runner->options, kLiteRtHwAcceleratorCpu), fail);
  REQUIRE_OR_GOTO(LiteRtCreateCompiledModel(runner->environment, runner->model, runner->options, &runner->compiled), fail);
  REQUIRE_OR_GOTO(LiteRtGetModelSignature(runner->model, 0, &runner->signature), fail);
  REQUIRE_OR_GOTO(LiteRtGetNumSignatureInputs(runner->signature, &input_count), fail);
  REQUIRE_OR_GOTO(LiteRtGetNumSignatureOutputs(runner->signature, &runner->output_count), fail);
  if (input_count != 1) goto fail;
  REQUIRE_OR_GOTO(LiteRtGetSignatureInputTensorByIndex(runner->signature, 0, &tensor), fail);
  REQUIRE_OR_GOTO(LiteRtGetRankedTensorType(tensor, &tensor_type), fail);
  REQUIRE_OR_GOTO(LiteRtGetCompiledModelInputBufferRequirements(runner->compiled, 0, 0, &requirements), fail);
  REQUIRE_OR_GOTO(LiteRtCreateManagedTensorBufferFromRequirements(runner->environment, &tensor_type, requirements, &runner->input), fail);
  runner->outputs = calloc(runner->output_count, sizeof(*runner->outputs));
  if (runner->outputs == NULL) goto fail;
  for (LiteRtParamIndex index = 0; index < runner->output_count; ++index) {
    tensor = NULL;
    requirements = NULL;
    REQUIRE_OR_GOTO(LiteRtGetSignatureOutputTensorByIndex(runner->signature, index, &tensor), fail);
    REQUIRE_OR_GOTO(LiteRtGetRankedTensorType(tensor, &tensor_type), fail);
    REQUIRE_OR_GOTO(LiteRtGetCompiledModelOutputBufferRequirements(runner->compiled, 0, index, &requirements), fail);
    REQUIRE_OR_GOTO(LiteRtCreateManagedTensorBufferFromRequirements(runner->environment, &tensor_type, requirements, &runner->outputs[index]), fail);
  }
  return 1;
fail:
  native_destroy(runner);
  return 0;
}

static int native_invoke(NativeRunner *runner, const float *input, size_t count) {
  size_t byte_count = 0;
  void *bytes = NULL;
  if (LiteRtGetTensorBufferPackedSize(runner->input, &byte_count) != kLiteRtStatusOk ||
      byte_count != count * sizeof(float) ||
      LiteRtLockTensorBuffer(runner->input, &bytes, kLiteRtTensorBufferLockModeWrite) != kLiteRtStatusOk)
    return 0;
  memcpy(bytes, input, byte_count);
  if (LiteRtUnlockTensorBuffer(runner->input) != kLiteRtStatusOk) return 0;
  return LiteRtRunCompiledModel(runner->compiled, 0, 1, &runner->input,
                                runner->output_count, runner->outputs) == kLiteRtStatusOk;
}

static float *lock_output(NativeRunner *runner, size_t index, size_t expected) {
  size_t byte_count = 0;
  void *bytes = NULL;
  if (index >= runner->output_count ||
      LiteRtGetTensorBufferPackedSize(runner->outputs[index], &byte_count) != kLiteRtStatusOk ||
      byte_count != expected * sizeof(float) ||
      LiteRtLockTensorBuffer(runner->outputs[index], &bytes, kLiteRtTensorBufferLockModeRead) != kLiteRtStatusOk)
    return NULL;
  return bytes;
}

AlignBlazePoseRunner *AlignBlazePoseCreate(const char *detector_path,
                                           const char *landmarks_path) {
  AlignBlazePoseRunner *runner = calloc(1, sizeof(*runner));
  if (runner == NULL) return NULL;
  runner->detector_input = malloc(224 * 224 * 3 * sizeof(float));
  runner->landmark_input = malloc(256 * 256 * 3 * sizeof(float));
  if (runner->detector_input == NULL || runner->landmark_input == NULL ||
      !native_create(detector_path, &runner->detector) ||
      !native_create(landmarks_path, &runner->landmarks)) {
    AlignBlazePoseDestroy(runner);
    return NULL;
  }
  return runner;
}

void AlignBlazePoseDestroy(AlignBlazePoseRunner *runner) {
  if (runner == NULL) return;
  native_destroy(&runner->landmarks);
  native_destroy(&runner->detector);
  free(runner->image);
  free(runner->detector_input);
  free(runner->landmark_input);
  free(runner);
}

AlignBlazePoseResult AlignBlazePoseAnalyzeBGRA(AlignBlazePoseRunner *runner,
                                               const uint8_t *bytes,
                                               size_t width, size_t height,
                                               size_t bytes_per_row,
                                               double timestamp_seconds,
                                               double maximum_gap_seconds,
                                               uint64_t generation) {
  AlignBlazePoseResult result = {.status = AlignBlazePoseTechnicalError};
  if (runner == NULL || bytes == NULL || width == 0 || height == 0 ||
      bytes_per_row < width * 4 || width > 4096 || height > 4096) return result;
  size_t floats = width * height * 3;
  if (floats > runner->image_capacity) {
    float *resized = realloc(runner->image, floats * sizeof(float));
    if (resized == NULL) return result;
    runner->image = resized;
    runner->image_capacity = floats;
  }
  for (size_t y = 0; y < height; ++y) {
    const uint8_t *row = bytes + y * bytes_per_row;
    for (size_t x = 0; x < width; ++x) {
      size_t destination = (y * width + x) * 3;
      runner->image[destination] = row[x * 4 + 2] / 255.0f;
      runner->image[destination + 1] = row[x * 4 + 1] / 255.0f;
      runner->image[destination + 2] = row[x * 4] / 255.0f;
    }
  }
  if (!BlazePoseBuildDetectorTensor(runner->image, width, height, runner->detector_input) ||
      !native_invoke(&runner->detector, runner->detector_input, 224 * 224 * 3)) return result;
  float *boxes = lock_output(&runner->detector, 0, 2254 * 12);
  float *scores = lock_output(&runner->detector, 1, 2254);
  BlazePoseRoi roi = {0};
  BlazePosePipelineStatus prepared = boxes != NULL && scores != NULL
      ? BlazePosePrepareLandmarkInput(runner->image, width, height, boxes, scores,
                                     runner->landmark_input, &roi)
      : BLAZEPOSE_PIPELINE_ERROR;
  if (boxes != NULL) LiteRtUnlockTensorBuffer(runner->detector.outputs[0]);
  if (scores != NULL) LiteRtUnlockTensorBuffer(runner->detector.outputs[1]);
  if (prepared == BLAZEPOSE_PIPELINE_NO_PERSON) {
    BlazePoseResetShoulderFilter(&runner->shoulder_filter);
    result.status = AlignBlazePoseNoPerson;
    return result;
  }
  if (prepared != BLAZEPOSE_PIPELINE_OK ||
      !native_invoke(&runner->landmarks, runner->landmark_input, 256 * 256 * 3)) return result;
  float *raw = lock_output(&runner->landmarks, 0, 195);
  float *pose_score = lock_output(&runner->landmarks, 1, 1);
  float *heatmap = lock_output(&runner->landmarks, 3, 64 * 64 * 39);
  BlazePoseUpperBody upper = {0};
  BlazePosePipelineStatus decoded = raw != NULL && pose_score != NULL && heatmap != NULL
      ? BlazePoseDecodeUpperBody(raw, pose_score[0], heatmap, roi, &upper)
      : BLAZEPOSE_PIPELINE_ERROR;
  if (raw != NULL) LiteRtUnlockTensorBuffer(runner->landmarks.outputs[0]);
  if (pose_score != NULL) LiteRtUnlockTensorBuffer(runner->landmarks.outputs[1]);
  if (heatmap != NULL) LiteRtUnlockTensorBuffer(runner->landmarks.outputs[3]);
  if (decoded == BLAZEPOSE_PIPELINE_NO_PERSON) {
    BlazePoseResetShoulderFilter(&runner->shoulder_filter);
    result.status = AlignBlazePoseNoPerson;
    return result;
  }
  if (decoded != BLAZEPOSE_PIPELINE_OK) return result;
  const float left_confidence =
      fminf(upper.left_shoulder.visibility, upper.left_shoulder.presence);
  const float right_confidence =
      fminf(upper.right_shoulder.visibility, upper.right_shoulder.presence);
  const int has_left = left_confidence >= 0.5f;
  const int has_right = right_confidence >= 0.5f;
  BlazePoseLandmark filtered_left = upper.left_shoulder;
  BlazePoseLandmark filtered_right = upper.right_shoulder;
  const int filtered = BlazePoseFilterShoulders(
      &runner->shoulder_filter, has_left, upper.left_shoulder, has_right,
      upper.right_shoulder, roi, width, height, timestamp_seconds,
      maximum_gap_seconds, generation, &filtered_left, &filtered_right);
  if (!has_left && !has_right) {
    result.status = AlignBlazePoseNoPerson;
    return result;
  }
  if (!filtered) {
    return result;
  }
  result.status = AlignBlazePoseDetected;
  result.left_x = filtered_left.x;
  result.left_y = filtered_left.y;
  result.left_confidence = has_left ? left_confidence : 0.0f;
  result.right_x = filtered_right.x;
  result.right_y = filtered_right.y;
  result.right_confidence = has_right ? right_confidence : 0.0f;
  return result;
}

void AlignBlazePoseResetTracking(AlignBlazePoseRunner *runner) {
  if (runner != NULL) BlazePoseResetShoulderFilter(&runner->shoulder_filter);
}
