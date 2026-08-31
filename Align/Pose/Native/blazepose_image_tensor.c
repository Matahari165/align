#include "blazepose_image_tensor.h"

#include <math.h>

static float sample_channel_zero(const float *rgb, size_t width, size_t height,
                                 float x, float y, int channel) {
  int x0 = (int)floorf(x);
  int y0 = (int)floorf(y);
  int x1 = x0 + 1;
  int y1 = y0 + 1;
  float fx = x - (float)x0;
  float fy = y - (float)y0;
  float result = 0.0f;
  const int xs[2] = {x0, x1};
  const int ys[2] = {y0, y1};
  const float wx[2] = {1.0f - fx, fx};
  const float wy[2] = {1.0f - fy, fy};
  for (int iy = 0; iy < 2; ++iy) {
    for (int ix = 0; ix < 2; ++ix) {
      if (xs[ix] >= 0 && ys[iy] >= 0 && xs[ix] < (int)width &&
          ys[iy] < (int)height) {
        size_t offset = ((size_t)ys[iy] * width + (size_t)xs[ix]) * 3 +
                        (size_t)channel;
        result += rgb[offset] * wx[ix] * wy[iy];
      }
    }
  }
  return result;
}

static float sample_channel_replicate(const float *rgb, size_t width,
                                      size_t height, float x, float y,
                                      int channel) {
  x = fmaxf(0.0f, fminf((float)width - 1.0f, x));
  y = fmaxf(0.0f, fminf((float)height - 1.0f, y));
  int x0 = (int)floorf(x);
  int y0 = (int)floorf(y);
  int x1 = x0 + 1 < (int)width ? x0 + 1 : x0;
  int y1 = y0 + 1 < (int)height ? y0 + 1 : y0;
  float fx = x - (float)x0;
  float fy = y - (float)y0;
  float top = rgb[((size_t)y0 * width + (size_t)x0) * 3 +
                  (size_t)channel] *
                  (1.0f - fx) +
              rgb[((size_t)y0 * width + (size_t)x1) * 3 +
                  (size_t)channel] *
                  fx;
  float bottom = rgb[((size_t)y1 * width + (size_t)x0) * 3 +
                     (size_t)channel] *
                     (1.0f - fx) +
                 rgb[((size_t)y1 * width + (size_t)x1) * 3 +
                     (size_t)channel] *
                     fx;
  return top * (1.0f - fy) + bottom * fy;
}

int BlazePoseBuildDetectorTensor(const float *rgb, size_t width,
                                 size_t height, float *tensor_224) {
  if (rgb == NULL || tensor_224 == NULL || width == 0 || height == 0) return 0;
  BlazePosePadding padding = BlazePoseDetectorLetterbox(width, height);
  float content_width = 1.0f - padding.left - padding.right;
  float content_height = 1.0f - padding.top - padding.bottom;
  for (int y = 0; y < 224; ++y) {
    for (int x = 0; x < 224; ++x) {
      float u = ((float)x + 0.5f) / 224.0f;
      float v = ((float)y + 0.5f) / 224.0f;
      int inside = u >= padding.left && u <= 1.0f - padding.right &&
                   v >= padding.top && v <= 1.0f - padding.bottom;
      for (int channel = 0; channel < 3; ++channel) {
        float value = 0.0f;
        if (inside) {
          float source_x =
              (u - padding.left) / content_width * (float)width - 0.5f;
          float source_y =
              (v - padding.top) / content_height * (float)height - 0.5f;
          value = sample_channel_zero(rgb, width, height, source_x, source_y,
                                      channel);
        }
        tensor_224[((size_t)y * 224 + (size_t)x) * 3 + (size_t)channel] =
            value * 2.0f - 1.0f;
      }
    }
  }
  return 1;
}

int BlazePoseBuildLandmarkTensor(const float *rgb, size_t width,
                                 size_t height, BlazePoseRoi roi,
                                 float *tensor_256) {
  if (rgb == NULL || tensor_256 == NULL || width == 0 || height == 0 ||
      !isfinite(roi.x_center) || !isfinite(roi.y_center) ||
      !isfinite(roi.width) || !isfinite(roi.height) ||
      !isfinite(roi.rotation) || roi.width <= 0.0f || roi.height <= 0.0f) {
    return 0;
  }
  float cosine = cosf(roi.rotation);
  float sine = sinf(roi.rotation);
  for (int y = 0; y < 256; ++y) {
    for (int x = 0; x < 256; ++x) {
      float local_x = ((float)x + 0.5f) / 256.0f - 0.5f;
      float local_y = ((float)y + 0.5f) / 256.0f - 0.5f;
      // La ROI de DetectionToRoi est carrée en pixels. Rotation et échelles
      // doivent donc être composées dans cet espace, pas dans l'espace
      // normalisé dont les axes diffèrent sur une image non carrée.
      float local_pixel_x = local_x * roi.width * (float)width;
      float local_pixel_y = local_y * roi.height * (float)height;
      float normalized_x = roi.x_center +
          (cosine * local_pixel_x - sine * local_pixel_y) / (float)width;
      float normalized_y = roi.y_center +
          (sine * local_pixel_x + cosine * local_pixel_y) / (float)height;
      float source_x = normalized_x * (float)width - 0.5f;
      float source_y = normalized_y * (float)height - 0.5f;
      for (int channel = 0; channel < 3; ++channel) {
        tensor_256[((size_t)y * 256 + (size_t)x) * 3 + (size_t)channel] =
            sample_channel_replicate(rgb, width, height, source_x, source_y,
                                     channel);
      }
    }
  }
  return 1;
}
