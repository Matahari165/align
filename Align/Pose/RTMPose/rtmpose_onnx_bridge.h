#ifndef ALIGN_RTMPOSE_ONNX_BRIDGE_H
#define ALIGN_RTMPOSE_ONNX_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
  ALIGN_RTMPOSE_KEYPOINT_COUNT = 26,
  ALIGN_RTMPOSE_NO_PERSON = 0,
  ALIGN_RTMPOSE_AVAILABLE = 1,
  ALIGN_RTMPOSE_INVALID_INPUT = 2,
  ALIGN_RTMPOSE_ERROR = 3
};

typedef struct {
  float x;
  float y;
  float width;
  float height;
} AlignRTMPoseNormalizedCrop;

/* Content rectangle occupied by the source crop inside the fixed model input.
 * Coordinates are normalized to the model input (x: 0...1, y: 0...1). When
 * the source crop has a different pixel aspect than 192:256, the remaining
 * area is constant black padding rather than a geometric stretch. */
typedef AlignRTMPoseNormalizedCrop AlignRTMPoseModelContentRect;

typedef struct {
  float x;
  float y;
  float confidence;
  int valid;
} AlignRTMPosePoint;

typedef struct {
  int status;
  uint64_t sample_id;
  double timestamp_seconds;
  uint64_t generation;
  AlignRTMPoseNormalizedCrop crop;
  AlignRTMPosePoint points[ALIGN_RTMPOSE_KEYPOINT_COUNT];
  /* Bounded scalar diagnostics; no image/tensor buffer is retained. */
  int valid_count;
  float simcc_min;
  float simcc_max;
  float score_min;
  float score_max;
  float left_shoulder_score;
  float right_shoulder_score;
  int used_coreml;
  char error[256];
} AlignRTMPoseResult;

typedef struct AlignRTMPoseRunner AlignRTMPoseRunner;

/* The model is top-down: Align supplies a face/upper-body crop and a person
 * hint. The bridge never rotates this crop by face roll and never mirrors it. */
AlignRTMPoseRunner *AlignRTMPoseCreate(const char *model_path,
                                       const char *runtime_path,
                                       int use_coreml);
void AlignRTMPoseDestroy(AlignRTMPoseRunner *runner);
void AlignRTMPoseReset(AlignRTMPoseRunner *runner);

int AlignRTMPoseAnalyzeBGRA(
    AlignRTMPoseRunner *runner, const uint8_t *bytes, size_t width,
    size_t height, size_t bytes_per_row, AlignRTMPoseNormalizedCrop crop,
    int person_hint, uint64_t sample_id, double timestamp_seconds,
    uint64_t generation, float confidence_threshold, AlignRTMPoseResult *out);

/* Pure, deterministic crop helper. All parameters and outputs are normalized
 * top-left image coordinates. Roll is intentionally not an input. The face
 * anchor keeps its requested width when the aspect-correct height exceeds the
 * frame; the tensor builder letterboxes that crop instead of shrinking it. */
AlignRTMPoseNormalizedCrop AlignRTMPoseFaceAnchoredCrop(
    float face_center_x, float face_center_y, float face_width,
    float face_height, size_t image_width, size_t image_height);

/* Computes the model-input content rectangle for a source crop. */
AlignRTMPoseModelContentRect AlignRTMPoseModelContentRectForCrop(
    AlignRTMPoseNormalizedCrop crop, size_t image_width, size_t image_height);

/* Maps a model-space point (0...1, top-left) back to the source image. */
void AlignRTMPoseProjectPoint(AlignRTMPoseNormalizedCrop crop,
                              float local_x, float local_y, float *x,
                              float *y);

/* Inverse of the letterbox mapping. Returns zero when the model-space point
 * lies in padding or cannot be projected into the source image. */
int AlignRTMPoseProjectPointWithContent(
    AlignRTMPoseNormalizedCrop crop,
    AlignRTMPoseModelContentRect content,
    float local_x, float local_y, float *x, float *y);

AlignRTMPosePoint AlignRTMPoseResultPointAt(const AlignRTMPoseResult *result,
                                            size_t index);

/* Shared preprocessing for the native Core ML experiment. Caller owns a
 * contiguous Float32 NCHW buffer of 3*256*192 elements. */
int AlignRTMPoseBuildTensor(const uint8_t *bytes, size_t width, size_t height,
                           size_t bytes_per_row, AlignRTMPoseNormalizedCrop crop,
                           float *tensor);

const char *AlignRTMPoseKeypointName(size_t index);
const char *AlignRTMPoseLastError(const AlignRTMPoseRunner *runner);

#ifdef __cplusplus
}
#endif

#endif
