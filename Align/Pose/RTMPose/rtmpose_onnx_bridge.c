#include "rtmpose_onnx_bridge.h"

#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "onnxruntime_c_api.h"
#include "coreml_provider_factory.h"

enum {
  kInputWidth = 192,
  kInputHeight = 256,
  kOutputX = 384,
  kOutputY = 512
};

typedef const OrtApiBase *(*OrtGetApiBaseFn)(void);

struct AlignRTMPoseRunner {
  void *runtime;
  const OrtApi *api;
  OrtEnv *env;
  OrtSessionOptions *options;
  OrtSession *session;
  OrtAllocator *allocator;
  char *input_name;
  char *output_names[2];
  int used_coreml;
  char last_error[256];
};

static const char *kNames[ALIGN_RTMPOSE_KEYPOINT_COUNT] = {
    "nose",       "left_eye",      "right_eye", "left_ear",
    "right_ear",  "left_shoulder", "right_shoulder", "left_elbow",
    "right_elbow", "left_wrist",   "right_wrist", "left_hip",
    "right_hip",  "left_knee",     "right_knee", "left_ankle",
    "right_ankle", "head",          "neck",        "hip",
    "left_big_toe", "right_big_toe", "left_small_toe", "right_small_toe",
    "left_heel",  "right_heel"
};

static void clear_error(AlignRTMPoseRunner *runner) {
  if (runner != NULL) runner->last_error[0] = '\0';
}

static int fail_status(AlignRTMPoseRunner *runner, OrtStatus *status,
                       const char *context) {
  if (runner == NULL) return 0;
  if (status != NULL) {
    const char *message = runner->api->GetErrorMessage(status);
    snprintf(runner->last_error, sizeof(runner->last_error), "%s: %s",
             context, message != NULL ? message : "ORT status");
    runner->api->ReleaseStatus(status);
  } else {
    snprintf(runner->last_error, sizeof(runner->last_error), "%s", context);
  }
  return 0;
}

static int check_status(AlignRTMPoseRunner *runner, OrtStatus *status,
                        const char *context) {
  return status == NULL ? 1 : fail_status(runner, status, context);
}

static int finite_crop(AlignRTMPoseNormalizedCrop crop) {
  return isfinite(crop.x) && isfinite(crop.y) && isfinite(crop.width) &&
         isfinite(crop.height) && crop.width > 0.0f && crop.height > 0.0f;
}

static float clampf(float value, float low, float high) {
  return value < low ? low : (value > high ? high : value);
}

static float sample_bgra(const uint8_t *bytes, size_t width, size_t height,
                         size_t stride, float x, float y, int channel) {
  x = clampf(x, 0.0f, (float)width - 1.0f);
  y = clampf(y, 0.0f, (float)height - 1.0f);
  const int x0 = (int)floorf(x);
  const int y0 = (int)floorf(y);
  const int x1 = x0 + 1 < (int)width ? x0 + 1 : x0;
  const int y1 = y0 + 1 < (int)height ? y0 + 1 : y0;
  const float fx = x - (float)x0;
  const float fy = y - (float)y0;
  const uint8_t *p00 = bytes + (size_t)y0 * stride + (size_t)x0 * 4;
  const uint8_t *p10 = bytes + (size_t)y0 * stride + (size_t)x1 * 4;
  const uint8_t *p01 = bytes + (size_t)y1 * stride + (size_t)x0 * 4;
  const uint8_t *p11 = bytes + (size_t)y1 * stride + (size_t)x1 * 4;
  const float top = (float)p00[channel] * (1.0f - fx) +
                    (float)p10[channel] * fx;
  const float bottom = (float)p01[channel] * (1.0f - fx) +
                       (float)p11[channel] * fx;
  return top * (1.0f - fy) + bottom * fy;
}

static void build_tensor(const uint8_t *bytes, size_t width, size_t height,
                         size_t stride, AlignRTMPoseNormalizedCrop crop,
                         float *tensor) {
  static const float mean[3] = {123.675f, 116.28f, 103.53f};
  static const float stdev[3] = {58.395f, 57.12f, 57.375f};
  for (int y = 0; y < kInputHeight; ++y) {
    const float sy = crop.y + ((float)y + 0.5f) /
                                  (float)kInputHeight * crop.height;
    for (int x = 0; x < kInputWidth; ++x) {
      const float sx = crop.x + ((float)x + 0.5f) /
                                  (float)kInputWidth * crop.width;
      const float px = sx * (float)width - 0.5f;
      const float py = sy * (float)height - 0.5f;
      for (int channel = 0; channel < 3; ++channel) {
        /* BGRA capture, but the model contract is RGB NCHW. */
        const int bgra_channel = 2 - channel;
        const float value = sample_bgra(bytes, width, height, stride, px, py,
                                        bgra_channel);
        tensor[(size_t)channel * kInputHeight * kInputWidth +
               (size_t)y * kInputWidth + (size_t)x] =
            (value - mean[channel]) / stdev[channel];
      }
    }
  }
}

/* SimCCLabel's official get_simcc_maximum uses the raw maximum value. The
 * ONNX graph already emits the score representation consumed by that decoder;
 * applying a second softmax over 384/512 bins would shrink every confidence
 * to roughly 1/N and reject real keypoints at a 0.20 threshold. */
static float maximum_value(const float *values, size_t count, size_t *argmax) {
  float maximum = -INFINITY;
  size_t index = 0;
  for (size_t i = 0; i < count; ++i) {
    if (isfinite(values[i]) && values[i] > maximum) {
      maximum = values[i];
      index = i;
    }
  }
  if (!isfinite(maximum)) {
    *argmax = 0;
    return 0.0f;
  }
  *argmax = index;
  return maximum;
}

static void update_range(const float *values, size_t count, float *minimum,
                         float *maximum) {
  for (size_t i = 0; i < count; ++i) {
    if (!isfinite(values[i])) continue;
    if (values[i] < *minimum) *minimum = values[i];
    if (values[i] > *maximum) *maximum = values[i];
  }
}

static int output_shape_is(const OrtApi *api, const OrtValue *value,
                           int64_t expected_last) {
  OrtTensorTypeAndShapeInfo *shape = NULL;
  size_t rank = 0;
  int64_t dimensions[3] = {0, 0, 0};
  if (api->GetTensorTypeAndShape(value, &shape) != NULL) return 0;
  if (api->GetDimensionsCount(shape, &rank) != NULL || rank != 3 ||
      api->GetDimensions(shape, dimensions, rank) != NULL ||
      dimensions[0] != 1 || dimensions[1] != ALIGN_RTMPOSE_KEYPOINT_COUNT ||
      dimensions[2] != expected_last) {
    api->ReleaseTensorTypeAndShapeInfo(shape);
    return 0;
  }
  api->ReleaseTensorTypeAndShapeInfo(shape);
  return 1;
}

AlignRTMPoseNormalizedCrop AlignRTMPoseFaceAnchoredCrop(
    float face_center_x, float face_center_y, float face_width,
    float face_height, size_t image_width, size_t image_height) {
  AlignRTMPoseNormalizedCrop crop = {0.0f, 0.0f, 0.0f, 0.0f};
  if (!isfinite(face_center_x) || !isfinite(face_center_y) ||
      !isfinite(face_width) || !isfinite(face_height) || face_width <= 0.0f ||
      face_height <= 0.0f || image_width == 0 || image_height == 0) {
    return crop;
  }
  /* RTMPose-M expects a 192:256 (0.75) pixel rectangle. Start from a
   * face-relative width, then fit both axes to the real image while keeping
   * that aspect. The old 4.2x/full-height rectangle distorted 16:9 frames and
   * made the top-down model place shoulders at the crop edges. */
  const float model_pixel_aspect = 192.0f / 256.0f;
  const float requested_width = clampf(face_width * 2.8f, 0.30f, 1.0f);
  const float requested_height = requested_width * (float)image_width /
                                 (model_pixel_aspect * (float)image_height);
  const float fit_scale = fminf(1.0f, fminf(1.0f / requested_width,
                                             1.0f / requested_height));
  crop.width = requested_width * fit_scale;
  crop.height = requested_height * fit_scale;
  if (crop.width <= 0.0f || crop.height <= 0.0f) {
    return (AlignRTMPoseNormalizedCrop){0.0f, 0.0f, 0.0f, 0.0f};
  }
  /* Keep a small margin above the face; the rectangle remains axis-aligned. */
  const float top_margin = face_height * 0.15f;
  crop.x = clampf(face_center_x - crop.width * 0.5f, 0.0f,
                 1.0f - crop.width);
  crop.y = clampf(face_center_y - face_height * 0.5f - top_margin, 0.0f,
                 1.0f - crop.height);
  return crop;
}

void AlignRTMPoseProjectPoint(AlignRTMPoseNormalizedCrop crop, float local_x,
                              float local_y, float *x, float *y) {
  if (x != NULL) *x = crop.x + local_x * crop.width;
  if (y != NULL) *y = crop.y + local_y * crop.height;
}

AlignRTMPosePoint AlignRTMPoseResultPointAt(const AlignRTMPoseResult *result,
                                            size_t index) {
  AlignRTMPosePoint point = {0.0f, 0.0f, 0.0f, 0};
  if (result != NULL && index < ALIGN_RTMPOSE_KEYPOINT_COUNT)
    point = result->points[index];
  return point;
}

AlignRTMPoseRunner *AlignRTMPoseCreate(const char *model_path,
                                       const char *runtime_path,
                                       int use_coreml) {
  if (model_path == NULL || runtime_path == NULL) return NULL;
  AlignRTMPoseRunner *runner = calloc(1, sizeof(*runner));
  if (runner == NULL) return NULL;
  runner->runtime = dlopen(runtime_path, RTLD_NOW | RTLD_LOCAL);
  if (runner->runtime == NULL) {
    snprintf(runner->last_error, sizeof(runner->last_error),
             "dlopen runtime: %s", dlerror());
    free(runner);
    return NULL;
  }
  OrtGetApiBaseFn get_api =
      (OrtGetApiBaseFn)dlsym(runner->runtime, "OrtGetApiBase");
  if (get_api == NULL) {
    snprintf(runner->last_error, sizeof(runner->last_error),
             "runtime missing OrtGetApiBase");
    dlclose(runner->runtime);
    free(runner);
    return NULL;
  }
  const OrtApiBase *base = get_api();
  runner->api = base != NULL ? base->GetApi(ORT_API_VERSION) : NULL;
  if (runner->api == NULL) {
    snprintf(runner->last_error, sizeof(runner->last_error),
             "runtime API version %d unavailable", ORT_API_VERSION);
    dlclose(runner->runtime);
    free(runner);
    return NULL;
  }
  if (!check_status(runner,
                    runner->api->CreateEnv(ORT_LOGGING_LEVEL_WARNING,
                                           "AlignRTMPose", &runner->env),
                    "CreateEnv") ||
      !check_status(runner, runner->api->DisableTelemetryEvents(runner->env),
                    "DisableTelemetryEvents") ||
      !check_status(runner, runner->api->CreateSessionOptions(&runner->options),
                    "CreateSessionOptions") ||
      !check_status(runner,
                    runner->api->SetIntraOpNumThreads(runner->options, 2),
                    "SetIntraOpNumThreads") ||
      !check_status(runner,
                    runner->api->SetSessionGraphOptimizationLevel(
                        runner->options, ORT_ENABLE_ALL),
                    "SetSessionGraphOptimizationLevel")) {
    AlignRTMPoseDestroy(runner);
    return NULL;
  }
  if (use_coreml) {
    typedef OrtStatus *(*AppendCoreMLFn)(OrtSessionOptions *, uint32_t);
    AppendCoreMLFn append_coreml = (AppendCoreMLFn)dlsym(
        runner->runtime, "OrtSessionOptionsAppendExecutionProvider_CoreML");
    if (append_coreml == NULL ||
        !check_status(runner,
                      append_coreml(runner->options,
                                    COREML_FLAG_ONLY_ENABLE_DEVICE_WITH_ANE |
                                        COREML_FLAG_CREATE_MLPROGRAM |
                                        COREML_FLAG_ONLY_ALLOW_STATIC_INPUT_SHAPES),
                      "AppendExecutionProvider_CoreML")) {
      if (runner->last_error[0] == '\0')
        snprintf(runner->last_error, sizeof(runner->last_error),
                 "CoreML execution provider unavailable");
      AlignRTMPoseDestroy(runner);
      return NULL;
    }
    runner->used_coreml = 1;
  }
  if (!check_status(runner,
                    runner->api->CreateSession(runner->env, model_path,
                                               runner->options, &runner->session),
                    "CreateSession") ||
      !check_status(runner,
                    runner->api->GetAllocatorWithDefaultOptions(
                        &runner->allocator),
                    "GetAllocatorWithDefaultOptions") ||
      !check_status(runner,
                    runner->api->SessionGetInputName(runner->session, 0,
                                                    runner->allocator,
                                                    &runner->input_name),
                    "SessionGetInputName")) {
    AlignRTMPoseDestroy(runner);
    return NULL;
  }
  size_t output_count = 0;
  if (!check_status(runner,
                    runner->api->SessionGetOutputCount(runner->session,
                                                       &output_count),
                    "SessionGetOutputCount") ||
      output_count != 2 ||
      !check_status(runner,
                    runner->api->SessionGetOutputName(runner->session, 0,
                                                      runner->allocator,
                                                      &runner->output_names[0]),
                    "SessionGetOutputName[0]") ||
      !check_status(runner,
                    runner->api->SessionGetOutputName(runner->session, 1,
                                                      runner->allocator,
                                                      &runner->output_names[1]),
                    "SessionGetOutputName[1]")) {
    AlignRTMPoseDestroy(runner);
    return NULL;
  }
  clear_error(runner);
  return runner;
}

void AlignRTMPoseDestroy(AlignRTMPoseRunner *runner) {
  if (runner == NULL) return;
  if (runner->api != NULL) {
    if (runner->input_name != NULL && runner->allocator != NULL)
      (void)runner->api->AllocatorFree(runner->allocator, runner->input_name);
    for (int i = 0; i < 2; ++i)
      if (runner->output_names[i] != NULL && runner->allocator != NULL)
        (void)runner->api->AllocatorFree(runner->allocator,
                                         runner->output_names[i]);
    if (runner->session != NULL) runner->api->ReleaseSession(runner->session);
    if (runner->options != NULL)
      runner->api->ReleaseSessionOptions(runner->options);
    if (runner->env != NULL) runner->api->ReleaseEnv(runner->env);
  }
  if (runner->runtime != NULL) dlclose(runner->runtime);
  free(runner);
}

void AlignRTMPoseReset(AlignRTMPoseRunner *runner) {
  if (runner != NULL) clear_error(runner);
}

int AlignRTMPoseAnalyzeBGRA(
    AlignRTMPoseRunner *runner, const uint8_t *bytes, size_t width,
    size_t height, size_t bytes_per_row, AlignRTMPoseNormalizedCrop crop,
    int person_hint, uint64_t sample_id, double timestamp_seconds,
    uint64_t generation, float confidence_threshold, AlignRTMPoseResult *out) {
  if (out == NULL) return 0;
  memset(out, 0, sizeof(*out));
  out->status = ALIGN_RTMPOSE_INVALID_INPUT;
  out->sample_id = sample_id;
  out->timestamp_seconds = timestamp_seconds;
  out->generation = generation;
  out->crop = crop;
  out->used_coreml = runner != NULL ? runner->used_coreml : 0;
  if (runner == NULL || bytes == NULL || width == 0 || height == 0 ||
      bytes_per_row < width * 4 || !finite_crop(crop) ||
      !isfinite(timestamp_seconds) || !isfinite(confidence_threshold) ||
      confidence_threshold < 0.0f || confidence_threshold > 1.0f) {
    if (runner != NULL) snprintf(out->error, sizeof(out->error), "%s",
                                 "invalid input");
    return 0;
  }
  if (!person_hint) {
    out->status = ALIGN_RTMPOSE_NO_PERSON;
    return 1;
  }
  clear_error(runner);
  float *tensor = malloc((size_t)3 * kInputWidth * kInputHeight * sizeof(float));
  if (tensor == NULL) {
    out->status = ALIGN_RTMPOSE_ERROR;
    snprintf(out->error, sizeof(out->error), "tensor allocation failed");
    return 0;
  }
  build_tensor(bytes, width, height, bytes_per_row, crop, tensor);
  const int64_t shape[4] = {1, 3, kInputHeight, kInputWidth};
  OrtMemoryInfo *memory = NULL;
  OrtValue *input = NULL;
  OrtValue *outputs[2] = {NULL, NULL};
  int ok = check_status(runner,
                        runner->api->CreateCpuMemoryInfo(OrtArenaAllocator,
                                                         OrtMemTypeDefault,
                                                         &memory),
                        "CreateCpuMemoryInfo") &&
           check_status(runner,
                        runner->api->CreateTensorWithDataAsOrtValue(
                            memory, tensor,
                            (size_t)3 * kInputWidth * kInputHeight * sizeof(float),
                            shape, 4, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
                            &input),
                        "CreateTensorWithDataAsOrtValue");
  if (ok) {
    const OrtValue *inputs[1] = {input};
    ok = check_status(runner,
                      runner->api->Run(runner->session, NULL,
                                       (const char *const *)&runner->input_name,
                                       inputs, 1,
                                       (const char *const *)runner->output_names,
                                       2, outputs),
                      "Run");
  }
  if (ok) {
    ok = output_shape_is(runner->api, outputs[0], kOutputX) &&
         output_shape_is(runner->api, outputs[1], kOutputY);
    if (!ok) snprintf(runner->last_error, sizeof(runner->last_error),
                      "unexpected SimCC output shape");
  }
  if (ok) {
    float *x_values = NULL;
    float *y_values = NULL;
    ok = check_status(runner,
                      runner->api->GetTensorMutableData(outputs[0],
                                                        (void **)&x_values),
                      "GetTensorMutableData(simcc_x)") &&
         check_status(runner,
                      runner->api->GetTensorMutableData(outputs[1],
                                                        (void **)&y_values),
                      "GetTensorMutableData(simcc_y)");
    if (ok) {
      out->simcc_min = INFINITY;
      out->simcc_max = -INFINITY;
      update_range(x_values,
                   (size_t)ALIGN_RTMPOSE_KEYPOINT_COUNT * kOutputX,
                   &out->simcc_min, &out->simcc_max);
      update_range(y_values,
                   (size_t)ALIGN_RTMPOSE_KEYPOINT_COUNT * kOutputY,
                   &out->simcc_min, &out->simcc_max);
      out->score_min = INFINITY;
      out->score_max = -INFINITY;
      out->left_shoulder_score = 0.0f;
      out->right_shoulder_score = 0.0f;
      int valid_count = 0;
      for (size_t point = 0; point < ALIGN_RTMPOSE_KEYPOINT_COUNT; ++point) {
        size_t x_index = 0;
        size_t y_index = 0;
        const float x_conf = maximum_value(x_values + point * kOutputX,
                                           kOutputX, &x_index);
        const float y_conf = maximum_value(y_values + point * kOutputY,
                                           kOutputY, &y_index);
        const float confidence = fminf(x_conf, y_conf);
        const float local_x = ((float)x_index * 0.5f) / (float)kInputWidth;
        const float local_y = ((float)y_index * 0.5f) / (float)kInputHeight;
        AlignRTMPosePoint *dst = &out->points[point];
        AlignRTMPoseProjectPoint(crop, local_x, local_y, &dst->x, &dst->y);
        dst->confidence = confidence;
        dst->valid = isfinite(dst->x) && isfinite(dst->y) &&
                     isfinite(confidence) && confidence >= confidence_threshold &&
                     dst->x >= 0.0f && dst->x <= 1.0f && dst->y >= 0.0f &&
                     dst->y <= 1.0f;
        if (dst->valid) ++valid_count;
        if (isfinite(confidence)) {
          if (confidence < out->score_min) out->score_min = confidence;
          if (confidence > out->score_max) out->score_max = confidence;
        }
        if (point == 5) out->left_shoulder_score = confidence;
        if (point == 6) out->right_shoulder_score = confidence;
      }
      out->valid_count = valid_count;
      out->status = valid_count > 0 ? ALIGN_RTMPOSE_AVAILABLE
                                    : ALIGN_RTMPOSE_NO_PERSON;
    }
  }
  if (!ok) {
    out->status = ALIGN_RTMPOSE_ERROR;
    snprintf(out->error, sizeof(out->error), "%s",
             runner->last_error[0] != '\0' ? runner->last_error : "inference failed");
  }
  if (outputs[0] != NULL) runner->api->ReleaseValue(outputs[0]);
  if (outputs[1] != NULL) runner->api->ReleaseValue(outputs[1]);
  if (input != NULL) runner->api->ReleaseValue(input);
  if (memory != NULL) runner->api->ReleaseMemoryInfo(memory);
  free(tensor);
  return ok;
}

const char *AlignRTMPoseKeypointName(size_t index) {
  return index < ALIGN_RTMPOSE_KEYPOINT_COUNT ? kNames[index] : NULL;
}

const char *AlignRTMPoseLastError(const AlignRTMPoseRunner *runner) {
  return runner != NULL ? runner->last_error : "runner unavailable";
}
