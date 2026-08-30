#include <stdio.h>
#include <stdlib.h>

#include "AlignBlazePose.h"

static void expect(int condition, const char *message) {
  if (!condition) {
    fprintf(stderr, "FAIL: %s\n", message);
    exit(1);
  }
}

int main(void) {
  expect(AlignBlazePoseMapShoulderFilterStatus(
             BLAZEPOSE_SHOULDER_FILTER_TECHNICAL_ERROR) ==
             AlignBlazePoseTechnicalError,
         "technicalError doit rester distinct");
  expect(AlignBlazePoseMapShoulderFilterStatus(
             BLAZEPOSE_SHOULDER_FILTER_NO_PERSON) == AlignBlazePoseNoPerson,
         "noPerson ne doit pas devenir technicalError");
  expect(AlignBlazePoseMapShoulderFilterStatus(
             BLAZEPOSE_SHOULDER_FILTER_FILTERED) == AlignBlazePoseDetected,
         "filtered doit publier une détection");
  expect(AlignBlazePoseMapShoulderFilterStatus(
             BLAZEPOSE_SHOULDER_FILTER_STALE) == AlignBlazePoseStale,
         "stale doit rester silencieux et distinct");
  puts("AlignBlazePoseStatusHarness: OK");
  return 0;
}
