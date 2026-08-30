#ifndef ALIGN_BLAZEPOSE_H
#define ALIGN_BLAZEPOSE_H

#include <stddef.h>
#include <stdint.h>

#include "blazepose_geometry.h"

typedef struct AlignBlazePoseRunner AlignBlazePoseRunner;

typedef enum {
  AlignBlazePoseTechnicalError = 0,
  AlignBlazePoseNoPerson = 1,
  AlignBlazePoseDetected = 2,
  AlignBlazePoseStale = 3,
} AlignBlazePoseStatus;

static inline AlignBlazePoseStatus AlignBlazePoseMapShoulderFilterStatus(
    BlazePoseShoulderFilterStatus status) {
  switch (status) {
    case BLAZEPOSE_SHOULDER_FILTER_NO_PERSON:
      return AlignBlazePoseNoPerson;
    case BLAZEPOSE_SHOULDER_FILTER_FILTERED:
      return AlignBlazePoseDetected;
    case BLAZEPOSE_SHOULDER_FILTER_STALE:
      return AlignBlazePoseStale;
    case BLAZEPOSE_SHOULDER_FILTER_TECHNICAL_ERROR:
    default:
      return AlignBlazePoseTechnicalError;
  }
}

typedef struct {
  float x;
  float y;
  float confidence;
  int valid;
} AlignBlazePosePoint;

typedef struct {
  AlignBlazePoseStatus status;
  AlignBlazePosePoint nose;
  AlignBlazePosePoint left_ear;
  AlignBlazePosePoint right_ear;
  AlignBlazePosePoint left_shoulder;
  AlignBlazePosePoint right_shoulder;
  AlignBlazePosePoint left_elbow;
  AlignBlazePosePoint right_elbow;
  AlignBlazePosePoint left_hip;
  AlignBlazePosePoint right_hip;
} AlignBlazePoseResult;

AlignBlazePoseRunner *AlignBlazePoseCreate(const char *detector_path,
                                           const char *landmarks_path);
void AlignBlazePoseDestroy(AlignBlazePoseRunner *runner);
AlignBlazePoseResult AlignBlazePoseAnalyzeBGRA(AlignBlazePoseRunner *runner,
                                               const uint8_t *bytes,
                                               size_t width, size_t height,
                                               size_t bytes_per_row,
                                               double timestamp_seconds,
                                               double maximum_gap_seconds,
                                               uint64_t generation);
void AlignBlazePoseResetTracking(AlignBlazePoseRunner *runner);

#endif
