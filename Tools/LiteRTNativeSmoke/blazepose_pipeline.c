#include "blazepose_pipeline.h"

#include "blazepose_image_tensor.h"

#include <math.h>

BlazePosePipelineStatus BlazePosePrepareLandmarkInput(
    const float *rgb, size_t width, size_t height,
    const float detector_boxes[2254 * 12],
    const float detector_scores[2254], float landmark_tensor[256 * 256 * 3],
    BlazePoseRoi *roi) {
  if (rgb == NULL || detector_boxes == NULL || detector_scores == NULL ||
      landmark_tensor == NULL || roi == NULL || width == 0 || height == 0) {
    return BLAZEPOSE_PIPELINE_ERROR;
  }
  for (size_t index = 0; index < 2254 * 12; ++index) {
    if (!isfinite(detector_boxes[index])) return BLAZEPOSE_PIPELINE_ERROR;
  }
  for (size_t index = 0; index < 2254; ++index) {
    if (!isfinite(detector_scores[index])) return BLAZEPOSE_PIPELINE_ERROR;
  }
  BlazePoseAnchor anchors[BLAZEPOSE_ANCHOR_COUNT];
  if (BlazePoseGenerateAnchors(anchors, BLAZEPOSE_ANCHOR_COUNT) !=
      BLAZEPOSE_ANCHOR_COUNT) {
    return BLAZEPOSE_PIPELINE_ERROR;
  }
  BlazePoseDetection detection = {0};
  if (!BlazePoseSelectBestDetection(
          detector_boxes, detector_scores, anchors, BLAZEPOSE_ANCHOR_COUNT,
          0.5f, &detection)) {
    return BLAZEPOSE_PIPELINE_NO_PERSON;
  }
  detection = BlazePoseRemoveDetectionLetterbox(
      detection, BlazePoseDetectorLetterbox(width, height));
  *roi = BlazePoseDetectionToRoi(detection, (float)width, (float)height);
  return BlazePoseBuildLandmarkTensor(rgb, width, height, *roi,
                                      landmark_tensor)
             ? BLAZEPOSE_PIPELINE_OK
             : BLAZEPOSE_PIPELINE_ERROR;
}

BlazePosePipelineStatus BlazePoseDecodeUpperBody(
    const float raw_landmarks[195], float pose_score,
    const float heatmap[64 * 64 * 39], BlazePoseRoi roi,
    BlazePoseUpperBody *upper_body) {
  if (raw_landmarks == NULL || heatmap == NULL || upper_body == NULL ||
      !isfinite(pose_score) || !isfinite(roi.x_center) ||
      !isfinite(roi.y_center) || !isfinite(roi.width) ||
      !isfinite(roi.height) || !isfinite(roi.rotation)) {
    return BLAZEPOSE_PIPELINE_ERROR;
  }
  for (size_t index = 0; index < 195; ++index) {
    if (!isfinite(raw_landmarks[index])) return BLAZEPOSE_PIPELINE_ERROR;
  }
  for (size_t index = 0; index < 64 * 64 * 39; ++index) {
    if (!isfinite(heatmap[index])) return BLAZEPOSE_PIPELINE_ERROR;
  }
  if (pose_score < 0.5f) return BLAZEPOSE_PIPELINE_NO_PERSON;
  BlazePoseLandmark landmarks[BLAZEPOSE_LANDMARK_COUNT];
  BlazePoseDecodeLandmarks(raw_landmarks, landmarks);
  BlazePoseRefineLandmarksFromHeatmap(landmarks, heatmap, 64, 64, 39);
  BlazePoseLandmark nose = BlazePoseProjectLandmark(landmarks[0], roi);
  BlazePoseLandmark left_ear = BlazePoseProjectLandmark(landmarks[7], roi);
  BlazePoseLandmark right_ear = BlazePoseProjectLandmark(landmarks[8], roi);
  BlazePoseLandmark left = BlazePoseProjectLandmark(landmarks[11], roi);
  BlazePoseLandmark right = BlazePoseProjectLandmark(landmarks[12], roi);
  BlazePoseLandmark left_elbow = BlazePoseProjectLandmark(landmarks[13], roi);
  BlazePoseLandmark right_elbow = BlazePoseProjectLandmark(landmarks[14], roi);
  BlazePoseLandmark left_hip = BlazePoseProjectLandmark(landmarks[23], roi);
  BlazePoseLandmark right_hip = BlazePoseProjectLandmark(landmarks[24], roi);
  BlazePoseLandmark neck = {
      .x = (left.x + right.x) * 0.5f,
      .y = (left.y + right.y) * 0.5f,
      .z = (left.z + right.z) * 0.5f,
      .visibility = left.visibility < right.visibility ? left.visibility
                                                       : right.visibility,
      .presence = left.presence < right.presence ? left.presence
                                                 : right.presence,
  };
  *upper_body = (BlazePoseUpperBody){
      .pose_score = pose_score,
      .nose = nose,
      .left_ear = left_ear,
      .right_ear = right_ear,
      .left_shoulder = left,
      .right_shoulder = right,
      .left_elbow = left_elbow,
      .right_elbow = right_elbow,
      .left_hip = left_hip,
      .right_hip = right_hip,
      .estimated_neck = neck,
  };
  return BLAZEPOSE_PIPELINE_OK;
}
