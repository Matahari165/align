#include "blazepose_face_registration.h"

#include <assert.h>
#include <float.h>
#include <math.h>
#include <stdio.h>

static int near(float left, float right) { return fabsf(left - right) < 1e-5f; }

int main(void) {
  BlazePosePoint face[3] = {{.x = 0.4f, .y = 0.4f},
                            {.x = 0.6f, .y = 0.4f},
                            {.x = 0.5f, .y = 0.5f}};
  BlazePosePoint translated[3];
  for (int index = 0; index < 3; ++index) {
    translated[index] = (BlazePosePoint){.x = face[index].x + 0.05f,
                                         .y = face[index].y - 0.02f};
  }
  BlazePoseRegistration translation;
  assert(BlazePoseFitTranslation(face, translated, NULL, 3, &translation));
  assert(near(translation.translation_x, 0.05f));
  assert(near(translation.translation_y, -0.02f));
  assert(near(translation.rms_residual, 0.0f));
  BlazePosePoint left = {.x = 0.3f, .y = 0.7f};
  BlazePosePoint right = {.x = 0.7f, .y = 0.7f};
  BlazePosePoint fitted_left = BlazePoseApplyRegistration(left, translation);
  BlazePosePoint fitted_right = BlazePoseApplyRegistration(right, translation);
  assert(near(fitted_right.x - fitted_left.x, right.x - left.x));
  assert(near(fitted_right.y - fitted_left.y, right.y - left.y));

  const float angle = 0.2f;
  BlazePoseRegistration expected = {.scale = 1.1f,
                                    .cosine = cosf(angle),
                                    .sine = sinf(angle),
                                    .translation_x = -0.03f,
                                    .translation_y = 0.04f};
  BlazePosePoint similar[3];
  for (int index = 0; index < 3; ++index) {
    similar[index] = BlazePoseApplyRegistration(face[index], expected);
  }
  BlazePoseRegistration similarity;
  assert(BlazePoseFitSimilarity(face, similar, NULL, 3, &similarity));
  assert(near(similarity.scale, expected.scale));
  assert(near(similarity.cosine, expected.cosine));
  assert(near(similarity.sine, expected.sine));
  assert(near(similarity.translation_x, expected.translation_x));
  assert(near(similarity.translation_y, expected.translation_y));
  assert(near(similarity.rms_residual, 0.0f));

  BlazePosePoint degenerate[2] = {{.x = 0.5f, .y = 0.5f},
                                  {.x = 0.5f, .y = 0.5f}};
  assert(!BlazePoseFitSimilarity(degenerate, degenerate, NULL, 2,
                                 &similarity));
  BlazePosePoint invalid[2] = {{.x = NAN, .y = 0.0f},
                               {.x = 0.0f, .y = 0.0f}};
  assert(!BlazePoseFitTranslation(invalid, degenerate, NULL, 2,
                                  &translation));
  BlazePoseRegistration sentinel = {.scale = 7.0f,
                                    .cosine = 6.0f,
                                    .sine = 5.0f,
                                    .translation_x = 4.0f,
                                    .translation_y = 3.0f,
                                    .rms_residual = 2.0f};
  translation = sentinel;
  assert(!BlazePoseFitTranslation(invalid, degenerate, NULL, 2,
                                  &translation));
  assert(near(translation.scale, sentinel.scale));
  assert(near(translation.translation_x, sentinel.translation_x));
  assert(near(translation.rms_residual, sentinel.rms_residual));
  BlazePosePoint extreme_source[2] = {{.x = FLT_MAX, .y = 0.0f},
                                      {.x = FLT_MAX, .y = 1.0f}};
  BlazePosePoint extreme_target[2] = {{.x = -FLT_MAX, .y = 0.0f},
                                      {.x = -FLT_MAX, .y = 1.0f}};
  translation = sentinel;
  assert(!BlazePoseFitTranslation(extreme_source, extreme_target, NULL, 2,
                                  &translation));
  assert(near(translation.scale, sentinel.scale));
  assert(near(translation.translation_x, sentinel.translation_x));
  float one_anchor_weight[2] = {1.0f, 0.0f};
  assert(!BlazePoseFitTranslation(face, translated, one_anchor_weight, 2,
                                  &translation));

  puts("BlazePoseFaceRegistrationHarness: OK");
  return 0;
}
