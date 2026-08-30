#include <stdio.h>

#include "litert/c/litert_environment.h"
#include "litert/c/litert_model.h"

static int inspect_model(LiteRtEnvironment environment, const char *path) {
  LiteRtModel model = NULL;
  LiteRtStatus status = LiteRtCreateModelFromFile(environment, path, &model);
  if (status != kLiteRtStatusOk) {
    fprintf(stderr, "Impossible de charger %s (LiteRT status %d)\n", path,
            status);
    return 1;
  }

  LiteRtParamIndex signature_count = 0;
  LiteRtParamIndex subgraph_count = 0;
  status = LiteRtGetNumModelSignatures(model, &signature_count);
  if (status == kLiteRtStatusOk) {
    status = LiteRtGetNumModelSubgraphs(model, &subgraph_count);
  }
  if (status != kLiteRtStatusOk) {
    fprintf(stderr, "Impossible de lire la structure de %s (LiteRT status %d)\n",
            path, status);
    LiteRtDestroyModel(model);
    return 1;
  }

  printf("%s: charge, signatures=%llu, sous-graphes=%llu\n", path,
         (unsigned long long)signature_count,
         (unsigned long long)subgraph_count);
  LiteRtDestroyModel(model);
  return 0;
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr,
            "Usage: %s pose_detector.tflite pose_landmarks_detector.tflite\n",
            argv[0]);
    return 2;
  }

  LiteRtEnvironment environment = NULL;
  LiteRtStatus status = LiteRtCreateEnvironment(0, NULL, &environment);
  if (status != kLiteRtStatusOk) {
    fprintf(stderr, "Impossible de creer l'environnement LiteRT (status %d)\n",
            status);
    return 3;
  }

  int result = inspect_model(environment, argv[1]);
  if (result == 0) {
    result = inspect_model(environment, argv[2]);
  }
  LiteRtDestroyEnvironment(environment);
  return result;
}
