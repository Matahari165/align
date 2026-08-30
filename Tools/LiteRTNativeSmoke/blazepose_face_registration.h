#ifndef ALIGN_BLAZEPOSE_FACE_REGISTRATION_H_
#define ALIGN_BLAZEPOSE_FACE_REGISTRATION_H_

#include <stddef.h>

#include "blazepose_geometry.h"

typedef struct {
  float scale;
  float cosine;
  float sine;
  float translation_x;
  float translation_y;
  float rms_residual;
} BlazePoseRegistration;

// Recalage par translation seulement. Il preserve exactement le vecteur entre
// les deux epaules et ne constitue pas une calibration persistante.
int BlazePoseFitTranslation(const BlazePosePoint *source,
                            const BlazePosePoint *target,
                            const float *weights, size_t count,
                            BlazePoseRegistration *registration);

// Comparateur de diagnostic : similitude 2D least-squares (echelle, rotation,
// translation). Il n'est pas destine a l'integration avant preuve live.
int BlazePoseFitSimilarity(const BlazePosePoint *source,
                           const BlazePosePoint *target,
                           const float *weights, size_t count,
                           BlazePoseRegistration *registration);

BlazePosePoint BlazePoseApplyRegistration(
    BlazePosePoint point, BlazePoseRegistration registration);

#endif  // ALIGN_BLAZEPOSE_FACE_REGISTRATION_H_
