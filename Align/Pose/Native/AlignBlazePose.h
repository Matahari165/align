#ifndef ALIGN_BLAZEPOSE_H
#define ALIGN_BLAZEPOSE_H

#include <stddef.h>
#include <stdint.h>

typedef struct AlignBlazePoseRunner AlignBlazePoseRunner;

typedef enum {
  AlignBlazePoseTechnicalError = 0,
  AlignBlazePoseNoPerson = 1,
  AlignBlazePoseDetected = 2,
} AlignBlazePoseStatus;

typedef struct {
  AlignBlazePoseStatus status;
  float left_x;
  float left_y;
  float left_confidence;
  float right_x;
  float right_y;
  float right_confidence;
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
