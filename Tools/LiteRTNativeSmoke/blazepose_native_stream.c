#define main blazepose_native_single_frame_main
#include "blazepose_native_cli.c"
#undef main

#include <stdint.h>
#include <time.h>
#include <math.h>

#define FRAME_MAGIC 0x414C474EU
#define RESULT_MAGIC 0x52534C54U
#define FRAME_STATUS_TECHNICAL_ERROR 0U
#define FRAME_STATUS_NO_PERSON 1U
#define FRAME_STATUS_DETECTED 2U

typedef struct __attribute__((packed)) {
  uint32_t magic;
  uint32_t width;
  uint32_t height;
  uint64_t frame_id;
} FrameHeader;

typedef struct __attribute__((packed)) {
  uint32_t magic;
  uint32_t status;
  uint64_t frame_id;
  double latency_ms;
  float pose_score;
  float left_x;
  float left_y;
  float left_score;
  float right_x;
  float right_y;
  float right_score;
  float roi_x_center;
  float roi_y_center;
  float roi_width;
  float roi_height;
  float roi_rotation;
  float raw_left_x;
  float raw_left_y;
  float raw_right_x;
  float raw_right_y;
  float face_left_eye_x;
  float face_left_eye_y;
  float face_left_eye_score;
  float face_right_eye_x;
  float face_right_eye_y;
  float face_right_eye_score;
  float face_nose_x;
  float face_nose_y;
  float face_nose_score;
} FrameResult;

_Static_assert(sizeof(FrameHeader) == 20, "FrameHeader protocol changed");
_Static_assert(sizeof(FrameResult) == 124, "FrameResult protocol changed");

static double monotonic_ms(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (double)now.tv_sec * 1000.0 + (double)now.tv_nsec / 1000000.0;
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "Usage: %s detector.tflite landmarks.tflite\n", argv[0]);
    return 2;
  }
  NativeRunner detector;
  NativeRunner landmarks;
  if (!runner_create(argv[1], &detector) ||
      !runner_create(argv[2], &landmarks))
    return 3;

  unsigned char *rgb_bytes = NULL;
  float *image = NULL;
  size_t image_capacity = 0;
  float *detector_input = malloc(224 * 224 * 3 * sizeof(float));
  float *landmark_input = malloc(256 * 256 * 3 * sizeof(float));
  if (detector_input == NULL || landmark_input == NULL) return 4;

  FrameHeader header;
  while (fread(&header, sizeof(header), 1, stdin) == 1) {
    if (header.magic != FRAME_MAGIC || header.width == 0 ||
        header.height == 0 || header.width > 4096 || header.height > 4096) {
      fprintf(stderr, "Entete de frame invalide\n");
      return 5;
    }
    size_t pixel_bytes = (size_t)header.width * header.height * 3;
    if (pixel_bytes > image_capacity) {
      unsigned char *new_rgb = realloc(rgb_bytes, pixel_bytes);
      float *new_image = realloc(image, pixel_bytes * sizeof(float));
      if (new_rgb == NULL || new_image == NULL) return 6;
      rgb_bytes = new_rgb;
      image = new_image;
      image_capacity = pixel_bytes;
    }
    if (fread(rgb_bytes, 1, pixel_bytes, stdin) != pixel_bytes) return 7;
    for (size_t index = 0; index < pixel_bytes; ++index)
      image[index] = (float)rgb_bytes[index] / 255.0f;

    FrameResult result = {.magic = RESULT_MAGIC,
                          .status = FRAME_STATUS_TECHNICAL_ERROR,
                          .frame_id = header.frame_id};
    double started = monotonic_ms();
    int ok = BlazePoseBuildDetectorTensor(image, header.width, header.height,
                                          detector_input);
    if (ok) ok = runner_invoke(&detector, detector_input, 224 * 224 * 3);
    float *boxes = ok ? runner_lock_output(&detector, 0, 2254 * 12) : NULL;
    float *scores = ok ? runner_lock_output(&detector, 1, 2254) : NULL;
    BlazePoseRoi roi = {0};
    BlazePosePipelineStatus prepare_status =
        boxes != NULL && scores != NULL
            ? BlazePosePrepareLandmarkInput(
                  image, header.width, header.height, boxes, scores,
                  landmark_input, &roi)
            : BLAZEPOSE_PIPELINE_ERROR;
    if (boxes != NULL) LiteRtUnlockTensorBuffer(detector.outputs[0]);
    if (scores != NULL) LiteRtUnlockTensorBuffer(detector.outputs[1]);

    ok = ok && prepare_status == BLAZEPOSE_PIPELINE_OK;
    if (prepare_status == BLAZEPOSE_PIPELINE_NO_PERSON) {
      result.status = FRAME_STATUS_NO_PERSON;
    }
    if (ok) ok = runner_invoke(&landmarks, landmark_input, 256 * 256 * 3);
    float *raw = ok ? runner_lock_output(&landmarks, 0, 195) : NULL;
    float *pose_score = ok ? runner_lock_output(&landmarks, 1, 1) : NULL;
    float *heatmap = ok ? runner_lock_output(&landmarks, 3, 64 * 64 * 39) : NULL;
    BlazePoseLandmark raw_left = {0};
    BlazePoseLandmark raw_right = {0};
    if (raw != NULL) {
      BlazePoseLandmark decoded_landmarks[BLAZEPOSE_LANDMARK_COUNT];
      BlazePoseDecodeLandmarks(raw, decoded_landmarks);
      raw_left = BlazePoseProjectLandmark(decoded_landmarks[11], roi,
                                          (float)header.width, (float)header.height);
      raw_right = BlazePoseProjectLandmark(decoded_landmarks[12], roi,
                                           (float)header.width, (float)header.height);
    }
    BlazePoseUpperBody upper_body;
    BlazePoseLandmark refined[BLAZEPOSE_LANDMARK_COUNT];
    BlazePosePipelineStatus decode_status =
        raw != NULL && pose_score != NULL && heatmap != NULL
            ? BlazePoseDecodeUpperBody(raw, pose_score[0], heatmap, roi,
                                       header.width, header.height,
                                       &upper_body)
            : BLAZEPOSE_PIPELINE_ERROR;
    ok = ok && decode_status == BLAZEPOSE_PIPELINE_OK;
    if (decode_status == BLAZEPOSE_PIPELINE_NO_PERSON) {
      result.status = FRAME_STATUS_NO_PERSON;
    }
    if (ok) {
      // Les sorties LiteRT ne sont garanties valides que tant que leurs
      // buffers restent verrouillés. Copie/décode tous les repères de cette
      // frame avant les trois Unlock ci-dessous.
      BlazePoseDecodeLandmarks(raw, refined);
      BlazePoseRefineLandmarksFromHeatmap(refined, heatmap, 64, 64, 39);
    }
    if (raw != NULL) LiteRtUnlockTensorBuffer(landmarks.outputs[0]);
    if (pose_score != NULL) LiteRtUnlockTensorBuffer(landmarks.outputs[1]);
    if (heatmap != NULL) LiteRtUnlockTensorBuffer(landmarks.outputs[3]);

    result.latency_ms = monotonic_ms() - started;
    if (ok) {
      for (int index = 0; index <= 6; ++index) {
        refined[index] = BlazePoseProjectLandmark(
            refined[index], roi, (float)header.width, (float)header.height);
      }
      BlazePoseLandmark left_eye = {0};
      BlazePoseLandmark right_eye = {0};
      float left_score = 1.0f;
      float right_score = 1.0f;
      for (int index = 1; index <= 3; ++index) {
        left_eye.x += refined[index].x / 3.0f;
        left_eye.y += refined[index].y / 3.0f;
        left_score = fminf(left_score, fminf(refined[index].visibility,
                                             refined[index].presence));
      }
      for (int index = 4; index <= 6; ++index) {
        right_eye.x += refined[index].x / 3.0f;
        right_eye.y += refined[index].y / 3.0f;
        right_score = fminf(right_score, fminf(refined[index].visibility,
                                               refined[index].presence));
      }
      result.status = FRAME_STATUS_DETECTED;
      result.pose_score = upper_body.pose_score;
      result.left_x = upper_body.left_shoulder.x;
      result.left_y = upper_body.left_shoulder.y;
      result.left_score = fminf(upper_body.left_shoulder.visibility,
                                upper_body.left_shoulder.presence);
      result.right_x = upper_body.right_shoulder.x;
      result.right_y = upper_body.right_shoulder.y;
      result.right_score = fminf(upper_body.right_shoulder.visibility,
                                 upper_body.right_shoulder.presence);
      result.roi_x_center = roi.x_center;
      result.roi_y_center = roi.y_center;
      result.roi_width = roi.width;
      result.roi_height = roi.height;
      result.roi_rotation = roi.rotation;
      result.raw_left_x = raw_left.x;
      result.raw_left_y = raw_left.y;
      result.raw_right_x = raw_right.x;
      result.raw_right_y = raw_right.y;
      result.face_left_eye_x = left_eye.x;
      result.face_left_eye_y = left_eye.y;
      result.face_left_eye_score = left_score;
      result.face_right_eye_x = right_eye.x;
      result.face_right_eye_y = right_eye.y;
      result.face_right_eye_score = right_score;
      result.face_nose_x = refined[0].x;
      result.face_nose_y = refined[0].y;
      result.face_nose_score =
          fminf(refined[0].visibility, refined[0].presence);
    }
    if (fwrite(&result, sizeof(result), 1, stdout) != 1 || fflush(stdout) != 0)
      return 8;
  }

  free(rgb_bytes);
  free(image);
  free(detector_input);
  free(landmark_input);
  runner_destroy(&landmarks);
  runner_destroy(&detector);
  return ferror(stdin) ? 9 : 0;
}
