#include <stddef.h>
#include <stdio.h>

#include "AlignBlazePose.h"

_Static_assert(sizeof(AlignBlazePosePoint) == 16,
               "AlignBlazePosePoint ABI changed");
_Static_assert(sizeof(AlignBlazePoseResult) == 148,
               "AlignBlazePoseResult ABI changed");
_Static_assert(offsetof(AlignBlazePoseResult, nose) == 4, "nose offset");
_Static_assert(offsetof(AlignBlazePoseResult, left_ear) == 20, "left ear offset");
_Static_assert(offsetof(AlignBlazePoseResult, right_ear) == 36, "right ear offset");
_Static_assert(offsetof(AlignBlazePoseResult, left_shoulder) == 52, "left shoulder offset");
_Static_assert(offsetof(AlignBlazePoseResult, right_shoulder) == 68, "right shoulder offset");
_Static_assert(offsetof(AlignBlazePoseResult, left_elbow) == 84, "left elbow offset");
_Static_assert(offsetof(AlignBlazePoseResult, right_elbow) == 100, "right elbow offset");
_Static_assert(offsetof(AlignBlazePoseResult, left_hip) == 116, "left hip offset");
_Static_assert(offsetof(AlignBlazePoseResult, right_hip) == 132, "right hip offset");

int main(void) {
  puts("AlignBlazePoseABIHarness: OK");
  return 0;
}
