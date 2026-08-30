#ifndef ALIGN_BLAZEPOSE_GEOMETRY_H_
#define ALIGN_BLAZEPOSE_GEOMETRY_H_

#include <stddef.h>
#include <stdint.h>

#define BLAZEPOSE_ANCHOR_COUNT 2254
#define BLAZEPOSE_DETECTOR_COORDS 12
#define BLAZEPOSE_LANDMARK_COUNT 39

typedef struct {
  float x;
  float y;
  float width;
  float height;
} BlazePoseAnchor;

typedef struct {
  float x;
  float y;
} BlazePosePoint;

typedef struct {
  float score;
  float x_min;
  float y_min;
  float x_max;
  float y_max;
  BlazePosePoint keypoints[4];
} BlazePoseDetection;

typedef struct {
  float x_center;
  float y_center;
  float width;
  float height;
  float rotation;
} BlazePoseRoi;

typedef struct {
  float x;
  float y;
  float z;
  float visibility;
  float presence;
} BlazePoseLandmark;

typedef struct {
  float left;
  float top;
  float right;
  float bottom;
} BlazePosePadding;

// Filtre adaptatif MediaPipe pour une coordonnee normalisee. Le beta eleve
// preserve les mouvements rapides (par exemple une epaule levee), tandis que
// min_cutoff reduit le tremblement lorsque le point est presque immobile.
typedef struct {
  int initialized;
  double last_timestamp;
  float last_raw;
  float last_filtered;
  float last_filtered_derivative;
} BlazePoseOneEuroFilter;

typedef struct {
  BlazePoseOneEuroFilter left_x;
  BlazePoseOneEuroFilter left_y;
  BlazePoseOneEuroFilter right_x;
  BlazePoseOneEuroFilter right_y;
  int has_timestamp;
  double last_timestamp;
  int has_generation;
  uint64_t generation;
} BlazePoseShoulderFilter;

typedef enum {
  BLAZEPOSE_SHOULDER_FILTER_TECHNICAL_ERROR = -1,
  BLAZEPOSE_SHOULDER_FILTER_NO_PERSON = 0,
  BLAZEPOSE_SHOULDER_FILTER_FILTERED = 1,
  BLAZEPOSE_SHOULDER_FILTER_STALE = 2,
} BlazePoseShoulderFilterStatus;

size_t BlazePoseGenerateAnchors(BlazePoseAnchor *anchors, size_t capacity);

BlazePoseDetection BlazePoseDecodeDetection(const float raw[12], float logit,
                                            BlazePoseAnchor anchor);

BlazePosePadding BlazePoseDetectorLetterbox(size_t image_width,
                                            size_t image_height);

BlazePoseDetection BlazePoseRemoveDetectionLetterbox(
    BlazePoseDetection detection, BlazePosePadding padding);

int BlazePoseSelectBestDetection(const float *raw_boxes, const float *logits,
                                 const BlazePoseAnchor *anchors,
                                 size_t count, float minimum_score,
                                 BlazePoseDetection *detection);

BlazePoseRoi BlazePoseDetectionToRoi(BlazePoseDetection detection,
                                     float image_width, float image_height);

void BlazePoseDecodeLandmarks(const float *raw,
                              BlazePoseLandmark landmarks[39]);

void BlazePoseRefineLandmarksFromHeatmap(
    BlazePoseLandmark landmarks[39], const float *heatmap, size_t height,
    size_t width, size_t channels);

BlazePoseLandmark BlazePoseProjectLandmark(BlazePoseLandmark landmark,
                                           BlazePoseRoi roi);

void BlazePoseResetOneEuroFilter(BlazePoseOneEuroFilter *filter);

float BlazePoseFilterNormalizedCoordinate(BlazePoseOneEuroFilter *filter,
                                          float value,
                                          double timestamp_seconds,
                                          float value_scale);

void BlazePoseResetShoulderFilter(BlazePoseShoulderFilter *filter);

// Filtre les epaules dans les coordonnees normalisees de l'image. Les echelles
// X/Y reproduisent le contrat MediaPipe : coordonnee en pixels divisee par la
// taille moyenne de la ROI en pixels. La rotation ne change pas cette taille.
// Un timestamp non croissant ou un trou superieur a maximum_gap_seconds reset
// les quatre axes avant de traiter le nouvel echantillon.
BlazePoseShoulderFilterStatus BlazePoseFilterShoulders(
                             BlazePoseShoulderFilter *filter,
                             int has_left,
                             BlazePoseLandmark left,
                             int has_right,
                             BlazePoseLandmark right,
                             BlazePoseRoi roi,
                             size_t image_width,
                             size_t image_height,
                             double timestamp_seconds,
                             double maximum_gap_seconds,
                             uint64_t generation,
                             BlazePoseLandmark *filtered_left,
                             BlazePoseLandmark *filtered_right);

#endif  // ALIGN_BLAZEPOSE_GEOMETRY_H_
