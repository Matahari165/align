#ifndef ALIGN_BLAZEPOSE_IMAGE_TENSOR_H_
#define ALIGN_BLAZEPOSE_IMAGE_TENSOR_H_

#include <stddef.h>

#include "blazepose_geometry.h"

// RGB entre 0 et 1, ordre top-left, lignes contiguës.
int BlazePoseBuildDetectorTensor(const float *rgb, size_t width,
                                 size_t height, float *tensor_224);

// Crop orienté de l'image source vers 256×256, RGB entre 0 et 1.
int BlazePoseBuildLandmarkTensor(const float *rgb, size_t width,
                                 size_t height, BlazePoseRoi roi,
                                 float *tensor_256);

#endif  // ALIGN_BLAZEPOSE_IMAGE_TENSOR_H_
