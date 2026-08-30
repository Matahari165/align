#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "blazepose_image_tensor.h"
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

#define REQUIRE(call)                                                           \
  do {                                                                          \
    LiteRtStatus status = (call);                                                \
    if (status != kLiteRtStatusOk) {                                             \
      fprintf(stderr, "%s a echoue (LiteRT status %d)\n", #call, status);      \
      return 0;                                                                 \
    }                                                                           \
  } while (0)

static int runner_create(const char *path, NativeRunner *runner) {
  memset(runner, 0, sizeof(*runner));
  REQUIRE(LiteRtCreateEnvironment(0, NULL, &runner->environment));
  REQUIRE(LiteRtCreateModelFromFile(runner->environment, path, &runner->model));
  REQUIRE(LiteRtCreateOptions(&runner->options));
  REQUIRE(LiteRtSetOptionsHardwareAccelerators(runner->options,
                                                kLiteRtHwAcceleratorCpu));
  REQUIRE(LiteRtCreateCompiledModel(runner->environment, runner->model,
                                    runner->options, &runner->compiled));
  REQUIRE(LiteRtGetModelSignature(runner->model, 0, &runner->signature));
  LiteRtParamIndex input_count = 0;
  REQUIRE(LiteRtGetNumSignatureInputs(runner->signature, &input_count));
  REQUIRE(LiteRtGetNumSignatureOutputs(runner->signature,
                                       &runner->output_count));
  if (input_count != 1) return 0;

  LiteRtTensor tensor = NULL;
  LiteRtRankedTensorType tensor_type;
  LiteRtTensorBufferRequirements requirements = NULL;
  REQUIRE(LiteRtGetSignatureInputTensorByIndex(runner->signature, 0, &tensor));
  REQUIRE(LiteRtGetRankedTensorType(tensor, &tensor_type));
  REQUIRE(LiteRtGetCompiledModelInputBufferRequirements(runner->compiled, 0, 0,
                                                         &requirements));
  REQUIRE(LiteRtCreateManagedTensorBufferFromRequirements(
      runner->environment, &tensor_type, requirements, &runner->input));

  runner->outputs = calloc(runner->output_count, sizeof(*runner->outputs));
  if (runner->outputs == NULL) return 0;
  for (LiteRtParamIndex index = 0; index < runner->output_count; ++index) {
    tensor = NULL;
    requirements = NULL;
    REQUIRE(LiteRtGetSignatureOutputTensorByIndex(runner->signature, index,
                                                   &tensor));
    REQUIRE(LiteRtGetRankedTensorType(tensor, &tensor_type));
    REQUIRE(LiteRtGetCompiledModelOutputBufferRequirements(
        runner->compiled, 0, index, &requirements));
    REQUIRE(LiteRtCreateManagedTensorBufferFromRequirements(
        runner->environment, &tensor_type, requirements,
        &runner->outputs[index]));
  }
  return 1;
}

static int runner_invoke(NativeRunner *runner, const float *input,
                         size_t float_count) {
  size_t byte_count = 0;
  void *bytes = NULL;
  REQUIRE(LiteRtGetTensorBufferPackedSize(runner->input, &byte_count));
  if (byte_count != float_count * sizeof(float)) return 0;
  REQUIRE(LiteRtLockTensorBuffer(runner->input, &bytes,
                                 kLiteRtTensorBufferLockModeWrite));
  memcpy(bytes, input, byte_count);
  REQUIRE(LiteRtUnlockTensorBuffer(runner->input));
  REQUIRE(LiteRtRunCompiledModel(runner->compiled, 0, 1, &runner->input,
                                 runner->output_count, runner->outputs));
  return 1;
}

static float *runner_lock_output(NativeRunner *runner, size_t index,
                                 size_t expected_floats) {
  if (index >= runner->output_count) return NULL;
  size_t byte_count = 0;
  void *bytes = NULL;
  if (LiteRtGetTensorBufferPackedSize(runner->outputs[index], &byte_count) !=
          kLiteRtStatusOk ||
      byte_count != expected_floats * sizeof(float) ||
      LiteRtLockTensorBuffer(runner->outputs[index], &bytes,
                             kLiteRtTensorBufferLockModeRead) !=
          kLiteRtStatusOk) {
    return NULL;
  }
  return bytes;
}

static void runner_destroy(NativeRunner *runner) {
  if (runner->outputs != NULL) {
    for (LiteRtParamIndex index = 0; index < runner->output_count; ++index) {
      if (runner->outputs[index] != NULL)
        LiteRtDestroyTensorBuffer(runner->outputs[index]);
    }
    free(runner->outputs);
  }
  if (runner->input != NULL) LiteRtDestroyTensorBuffer(runner->input);
  if (runner->compiled != NULL) LiteRtDestroyCompiledModel(runner->compiled);
  if (runner->options != NULL) LiteRtDestroyOptions(runner->options);
  if (runner->model != NULL) LiteRtDestroyModel(runner->model);
  if (runner->environment != NULL)
    LiteRtDestroyEnvironment(runner->environment);
}

int main(int argc, char **argv) {
  if (argc != 6) {
    fprintf(stderr,
            "Usage: %s detector.tflite landmarks.tflite width height rgb.f32\n",
            argv[0]);
    return 2;
  }
  size_t width = (size_t)strtoul(argv[3], NULL, 10);
  size_t height = (size_t)strtoul(argv[4], NULL, 10);
  size_t image_floats = width * height * 3;
  float *image = malloc(image_floats * sizeof(float));
  float *detector_input = malloc(224 * 224 * 3 * sizeof(float));
  float *landmark_input = malloc(256 * 256 * 3 * sizeof(float));
  if (image == NULL || detector_input == NULL || landmark_input == NULL)
    return 3;
  FILE *file = strcmp(argv[5], "-") == 0 ? stdin : fopen(argv[5], "rb");
  if (file == NULL || fread(image, sizeof(float), image_floats, file) !=
                          image_floats) {
    fprintf(stderr, "Image RGB float32 invalide\n");
    return 4;
  }
  if (file != stdin) fclose(file);

  NativeRunner detector;
  NativeRunner landmarks;
  if (!runner_create(argv[1], &detector) ||
      !runner_create(argv[2], &landmarks))
    return 5;

  if (!BlazePoseBuildDetectorTensor(image, width, height, detector_input)) {
    fprintf(stderr, "Dimensions image invalides\n");
    return 6;
  }
  if (!runner_invoke(&detector, detector_input, 224 * 224 * 3)) return 6;
  float *boxes = runner_lock_output(&detector, 0, 2254 * 12);
  float *scores = runner_lock_output(&detector, 1, 2254);
  BlazePoseRoi roi;
  BlazePosePipelineStatus detected =
      boxes != NULL && scores != NULL
          ? BlazePosePrepareLandmarkInput(image, width, height, boxes, scores,
                                          landmark_input, &roi)
          : BLAZEPOSE_PIPELINE_ERROR;
  if (boxes != NULL) LiteRtUnlockTensorBuffer(detector.outputs[0]);
  if (scores != NULL) LiteRtUnlockTensorBuffer(detector.outputs[1]);
  if (detected != BLAZEPOSE_PIPELINE_OK) {
    puts("Aucune personne detectee");
    runner_destroy(&landmarks);
    runner_destroy(&detector);
    return 7;
  }

  if (!runner_invoke(&landmarks, landmark_input, 256 * 256 * 3)) return 8;
  float *raw = runner_lock_output(&landmarks, 0, 195);
  float *pose_score = runner_lock_output(&landmarks, 1, 1);
  float *heatmap = runner_lock_output(&landmarks, 3, 64 * 64 * 39);
  BlazePoseUpperBody upper_body;
  BlazePosePipelineStatus decoded =
      raw != NULL && pose_score != NULL && heatmap != NULL
          ? BlazePoseDecodeUpperBody(raw, pose_score[0], heatmap, roi,
                                     &upper_body)
          : BLAZEPOSE_PIPELINE_ERROR;
  if (raw != NULL) LiteRtUnlockTensorBuffer(landmarks.outputs[0]);
  if (pose_score != NULL) LiteRtUnlockTensorBuffer(landmarks.outputs[1]);
  if (heatmap != NULL) LiteRtUnlockTensorBuffer(landmarks.outputs[3]);
  if (decoded != BLAZEPOSE_PIPELINE_OK) {
    puts("Pose rejetee par le modele de reperes");
    return 9;
  }

  printf("pose=%.3f gauche=(%.5f,%.5f,%.3f) droite=(%.5f,%.5f,%.3f) "
         "cou_estime=(%.5f,%.5f)\n",
         upper_body.pose_score, upper_body.left_shoulder.x,
         upper_body.left_shoulder.y, upper_body.left_shoulder.visibility,
         upper_body.right_shoulder.x, upper_body.right_shoulder.y,
         upper_body.right_shoulder.visibility, upper_body.estimated_neck.x,
         upper_body.estimated_neck.y);

  runner_destroy(&landmarks);
  runner_destroy(&detector);
  free(image);
  free(detector_input);
  free(landmark_input);
  return 0;
}
