#include "AlignBlazePose.h"

AlignBlazePoseRunner *AlignBlazePoseCreate(const char *detector_path,
                                           const char *landmarks_path) {
  (void)detector_path;
  (void)landmarks_path;
  return NULL;
}

void AlignBlazePoseDestroy(AlignBlazePoseRunner *runner) { (void)runner; }

AlignBlazePoseResult AlignBlazePoseAnalyzeBGRA(
    AlignBlazePoseRunner *runner, const uint8_t *bytes, size_t width,
    size_t height, size_t bytes_per_row, double timestamp_seconds,
    double maximum_gap_seconds, uint64_t generation) {
  (void)runner; (void)bytes; (void)width; (void)height; (void)bytes_per_row;
  (void)timestamp_seconds; (void)maximum_gap_seconds; (void)generation;
  return (AlignBlazePoseResult){.status = AlignBlazePoseTechnicalError};
}

void AlignBlazePoseResetTracking(AlignBlazePoseRunner *runner) { (void)runner; }
