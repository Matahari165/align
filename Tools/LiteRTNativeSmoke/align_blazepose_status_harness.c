#include <assert.h>
#include <stdio.h>

#include "../../Align/Pose/Native/AlignBlazePose.h"

int main(void) {
  BlazePoseShoulderFilter filter = {0};
  BlazePoseLandmark left = {0};
  BlazePoseLandmark right = {0};
  BlazePoseShoulderFilterStatus filtered = BlazePoseFilterShoulders(
      &filter, 0, left, 0, right, (BlazePoseRoi){0}, 640, 480, 1.0, 0.5,
      7, &left, &right);
  assert(filtered == BLAZEPOSE_SHOULDER_FILTER_NO_PERSON);
  assert(AlignBlazePoseMapShoulderFilterStatus(filtered) ==
         AlignBlazePoseNoPerson);
  assert(filter.has_generation && filter.generation == 7);
  assert(filter.has_timestamp && filter.last_timestamp == 1.0);
  puts("AlignBlazePoseStatusHarness: OK noPerson empty ROI");
  return 0;
}
