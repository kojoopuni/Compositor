#include "ColorPixels.h"
#include <math.h>

static inline float clamp01(float v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
static inline float luma(const float *c) { return 0.2126f * c[0] + 0.7152f * c[1] + 0.0722f * c[2]; }
/// Scales a color so its brightness is `target`, without pushing a channel past white.
static void keep_luma(float *c, float target) {
    float now = luma(c);
    if (now <= 0.0001f) { c[0] = c[1] = c[2] = target; return; }
    float scale = target / now;
    for (int i = 0; i < 3; ++i) c[i] = clamp01(c[i] * scale);
}

void color_adjust(uint8_t *rgba, size_t width, size_t height, size_t stride, int kind, const float *v) {
    for (size_t y = 0; y < height; ++y) {
        uint8_t *p = rgba + y * stride;
        for (size_t x = 0; x < width; ++x, p += 4) {
            float alpha = p[3];
            if (alpha == 0) continue;
            float c[3] = { fminf(1, p[0] / alpha), fminf(1, p[1] / alpha), fminf(1, p[2] / alpha) };
            switch (kind) {
            case COLOR_BLACK_WHITE: {
                float gray = clamp01(c[0] * v[0] + c[1] * v[1] + c[2] * v[2]);
                c[0] = c[1] = c[2] = gray;
                break;
            }
            case COLOR_THRESHOLD: {
                float value = luma(c) >= v[0] ? 1 : 0;
                c[0] = c[1] = c[2] = value;
                break;
            }
            case COLOR_POSTERIZE: {
                float steps = fmaxf(1, v[0] - 1);
                for (int i = 0; i < 3; ++i) c[i] = roundf(c[i] * steps) / steps;
                break;
            }
            case COLOR_VIBRANCE: {
                float high = fmaxf(c[0], fmaxf(c[1], c[2])), low = fminf(c[0], fminf(c[1], c[2]));
                // Vibrance reaches for the muted colors and leaves the already vivid ones nearly alone.
                float amount = 1 + v[1] + v[0] * (1 - (high - low));
                float gray = luma(c);
                for (int i = 0; i < 3; ++i) c[i] = clamp01(gray + (c[i] - gray) * fmaxf(0, amount));
                break;
            }
            case COLOR_BALANCE: {
                float light = luma(c);
                float shadows = (1 - light) * (1 - light), highlights = light * light, midtones = fmaxf(0, 1 - shadows - highlights);
                for (int i = 0; i < 3; ++i) c[i] = clamp01(c[i] + 0.5f * (v[i] * shadows + v[3 + i] * midtones + v[6 + i] * highlights));
                if (v[9] > 0.5f) keep_luma(c, light);
                break;
            }
            case COLOR_PHOTO_FILTER: {
                float light = luma(c), tinted[3];
                for (int i = 0; i < 3; ++i) tinted[i] = c[i] * v[i];
                if (v[4] > 0.5f) keep_luma(tinted, light);
                for (int i = 0; i < 3; ++i) c[i] = clamp01(c[i] + (tinted[i] - c[i]) * v[3]);
                break;
            }
            default: break;
            }
            for (int i = 0; i < 3; ++i) p[i] = (uint8_t)fminf(alpha, roundf(c[i] * alpha));
        }
    }
}
