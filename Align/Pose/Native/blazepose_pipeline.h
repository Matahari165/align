#ifndef ALIGN_BLAZEPOSE_PIPELINE_H_
#define ALIGN_BLAZEPOSE_PIPELINE_H_

#include <stddef.h>

#include "blazepose_geometry.h"

typedef struct {
  float pose_score;
  BlazePoseLandmark left_shoulder;
  BlazePoseLandmark right_shoulder;
  BlazePoseLandmark estimated_neck;
} BlazePoseUpperBody;

typedef enum {
  BLAZEPOSE_PIPELINE_ERROR = 0,
  BLAZEPOSE_PIPELINE_NO_PERSON = 1,
  BLAZEPOSE_PIPELINE_OK = 2,
} BlazePosePipelineStatus;

// Consomme exactement les deux sorties du détecteur LiteRT, retire le
// letterboxing puis construit l'entrée du modèle de repères.
BlazePosePipelineStatus BlazePosePrepareLandmarkInput(
    const float *rgb, size_t width, size_t height,
    const float detector_boxes[2254 * 12],
    const float detector_scores[2254], float landmark_tensor[256 * 256 * 3],
    BlazePoseRoi *roi);

// Consomme les sorties Identity, Identity_1 et Identity_3 du modèle de
// repères. Le cou est explicitement estimé comme milieu des deux épaules : ce
// n'est pas un repère natif BlazePose.
BlazePosePipelineStatus BlazePoseDecodeUpperBody(
    const float raw_landmarks[195], float pose_score,
    const float heatmap[64 * 64 * 39], BlazePoseRoi roi,
    BlazePoseUpperBody *upper_body);

#endif  // ALIGN_BLAZEPOSE_PIPELINE_H_
