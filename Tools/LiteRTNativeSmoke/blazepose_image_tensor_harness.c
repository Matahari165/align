#include "blazepose_image_tensor.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static int near(float left, float right) { return fabsf(left - right) < 1e-4f; }

int main(void) {
  float image[4 * 2 * 3];
  for (size_t index = 0; index < 4 * 2; ++index) {
    image[index * 3] = 0.25f;
    image[index * 3 + 1] = 0.5f;
    image[index * 3 + 2] = 0.75f;
  }
  float *detector = malloc(224 * 224 * 3 * sizeof(float));
  float *landmark = malloc(256 * 256 * 3 * sizeof(float));
  assert(detector != NULL && landmark != NULL);
  assert(BlazePoseBuildDetectorTensor(image, 4, 2, detector));
  assert(!BlazePoseBuildDetectorTensor(image, 0, 2, detector));
  assert(!BlazePoseBuildDetectorTensor(image, 4, 0, detector));
  // Image 2:1 : le quart vertical supérieur est une bande noire normalisée -1.
  assert(near(detector[(10 * 224 + 112) * 3], -1.0f));
  assert(near(detector[(112 * 224 + 112) * 3], -0.5f));
  assert(near(detector[(112 * 224 + 112) * 3 + 1], 0.0f));
  assert(near(detector[(112 * 224 + 112) * 3 + 2], 0.5f));

  BlazePoseRoi full = {.x_center = 0.5f,
                       .y_center = 0.5f,
                       .width = 1.0f,
                       .height = 1.0f,
                       .rotation = 0.0f};
  assert(BlazePoseBuildLandmarkTensor(image, 4, 2, full, landmark));
  assert(near(landmark[(128 * 256 + 128) * 3], 0.25f));
  assert(near(landmark[(128 * 256 + 128) * 3 + 1], 0.5f));
  assert(near(landmark[(128 * 256 + 128) * 3 + 2], 0.75f));
  BlazePoseRoi degenerate = full;
  degenerate.width = 0.0f;
  assert(!BlazePoseBuildLandmarkTensor(image, 4, 2, degenerate, landmark));
  BlazePoseRoi non_finite = full;
  non_finite.rotation = NAN;
  assert(!BlazePoseBuildLandmarkTensor(image, 4, 2, non_finite, landmark));
  assert(!BlazePoseBuildLandmarkTensor(image, 0, 2, full, landmark));

  // Le crop landmarks utilise BORDER_REPLICATE : une ROI depassant chacun
  // des quatre bords recopie les pixels de coin, elle ne cree pas de noir.
  float border_image[2 * 2 * 3] = {
      0.1f, 0.0f, 0.0f, 0.2f, 0.0f, 0.0f,
      0.3f, 0.0f, 0.0f, 0.4f, 0.0f, 0.0f,
  };
  BlazePoseRoi oversized = {.x_center = 0.5f,
                            .y_center = 0.5f,
                            .width = 2.0f,
                            .height = 2.0f,
                            .rotation = 0.0f};
  assert(BlazePoseBuildLandmarkTensor(border_image, 2, 2, oversized,
                                      landmark));
  assert(near(landmark[(0 * 256 + 0) * 3], 0.1f));
  assert(near(landmark[(0 * 256 + 255) * 3], 0.2f));
  assert(near(landmark[(255 * 256 + 0) * 3], 0.3f));
  assert(near(landmark[(255 * 256 + 255) * 3], 0.4f));

  free(detector);
  free(landmark);
  puts("BlazePoseImageTensorHarness: OK");
  return 0;
}
