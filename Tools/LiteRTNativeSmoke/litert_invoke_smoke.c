#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "litert/c/litert_compiled_model.h"
#include "litert/c/litert_environment.h"
#include "litert/c/litert_model.h"
#include "litert/c/litert_options.h"
#include "litert/c/litert_tensor_buffer.h"

#define CHECK(call)                                                            \
  do {                                                                         \
    LiteRtStatus status = (call);                                               \
    if (status != kLiteRtStatusOk) {                                            \
      fprintf(stderr, "%s a echoue (LiteRT status %d)\n", #call, status);     \
      return 1;                                                                \
    }                                                                          \
  } while (0)

static int invoke_with_zero_input(const char *path) {
  LiteRtEnvironment environment = NULL;
  LiteRtModel model = NULL;
  LiteRtOptions options = NULL;
  LiteRtCompiledModel compiled_model = NULL;
  LiteRtSignature signature = NULL;

  CHECK(LiteRtCreateEnvironment(0, NULL, &environment));
  CHECK(LiteRtCreateModelFromFile(environment, path, &model));
  CHECK(LiteRtCreateOptions(&options));
  CHECK(LiteRtSetOptionsHardwareAccelerators(options,
                                              kLiteRtHwAcceleratorCpu));
  CHECK(LiteRtCreateCompiledModel(environment, model, options,
                                  &compiled_model));
  CHECK(LiteRtGetModelSignature(model, 0, &signature));

  LiteRtParamIndex input_count = 0;
  LiteRtParamIndex output_count = 0;
  CHECK(LiteRtGetNumSignatureInputs(signature, &input_count));
  CHECK(LiteRtGetNumSignatureOutputs(signature, &output_count));

  LiteRtTensorBuffer *inputs = calloc(input_count, sizeof(*inputs));
  LiteRtTensorBuffer *outputs = calloc(output_count, sizeof(*outputs));
  if (inputs == NULL || outputs == NULL) {
    fprintf(stderr, "Allocation impossible\n");
    return 1;
  }

  for (LiteRtParamIndex index = 0; index < input_count; ++index) {
    LiteRtTensor tensor = NULL;
    LiteRtRankedTensorType tensor_type;
    LiteRtTensorBufferRequirements requirements = NULL;
    CHECK(LiteRtGetSignatureInputTensorByIndex(signature, index, &tensor));
    CHECK(LiteRtGetRankedTensorType(tensor, &tensor_type));
    CHECK(LiteRtGetCompiledModelInputBufferRequirements(
        compiled_model, 0, index, &requirements));
    CHECK(LiteRtCreateManagedTensorBufferFromRequirements(
        environment, &tensor_type, requirements, &inputs[index]));

    size_t byte_count = 0;
    void *bytes = NULL;
    CHECK(LiteRtGetTensorBufferPackedSize(inputs[index], &byte_count));
    CHECK(LiteRtLockTensorBuffer(inputs[index], &bytes,
                                 kLiteRtTensorBufferLockModeWrite));
    memset(bytes, 0, byte_count);
    CHECK(LiteRtUnlockTensorBuffer(inputs[index]));
  }

  for (LiteRtParamIndex index = 0; index < output_count; ++index) {
    LiteRtTensor tensor = NULL;
    LiteRtRankedTensorType tensor_type;
    LiteRtTensorBufferRequirements requirements = NULL;
    CHECK(LiteRtGetSignatureOutputTensorByIndex(signature, index, &tensor));
    CHECK(LiteRtGetRankedTensorType(tensor, &tensor_type));
    CHECK(LiteRtGetCompiledModelOutputBufferRequirements(
        compiled_model, 0, index, &requirements));
    CHECK(LiteRtCreateManagedTensorBufferFromRequirements(
        environment, &tensor_type, requirements, &outputs[index]));
  }

  CHECK(LiteRtRunCompiledModel(compiled_model, 0, input_count, inputs,
                               output_count, outputs));
  printf("%s: invocation CPU reussie, entrees=%llu, sorties=%llu\n", path,
         (unsigned long long)input_count, (unsigned long long)output_count);

  for (LiteRtParamIndex index = 0; index < input_count; ++index) {
    LiteRtDestroyTensorBuffer(inputs[index]);
  }
  for (LiteRtParamIndex index = 0; index < output_count; ++index) {
    LiteRtDestroyTensorBuffer(outputs[index]);
  }
  free(inputs);
  free(outputs);
  LiteRtDestroyCompiledModel(compiled_model);
  LiteRtDestroyOptions(options);
  LiteRtDestroyModel(model);
  LiteRtDestroyEnvironment(environment);
  return 0;
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr,
            "Usage: %s pose_detector.tflite pose_landmarks_detector.tflite\n",
            argv[0]);
    return 2;
  }
  int result = invoke_with_zero_input(argv[1]);
  return result == 0 ? invoke_with_zero_input(argv[2]) : result;
}
