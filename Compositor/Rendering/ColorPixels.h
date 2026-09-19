#ifndef ColorPixels_h
#define ColorPixels_h
#include <stdint.h>
#include <stddef.h>
// The fork's color adjustments, on premultiplied RGBA (4 bytes per pixel, `stride` bytes per row). Each pixel's
// color is taken out of its alpha, adjusted, and put back, so soft edges change like the colors they are; alpha is
// never touched. `kind` and the meaning of `values` are listed in ColorAdjustments.swift beside the settings.
enum {
    COLOR_BLACK_WHITE = 0,   // values: red, green, blue weights (1 = 100%)
    COLOR_THRESHOLD = 1,     // values: level 0–1
    COLOR_POSTERIZE = 2,     // values: levels 2–255
    COLOR_VIBRANCE = 3,      // values: vibrance, saturation (−1–1)
    COLOR_BALANCE = 4,       // values: shadows r,g,b; midtones r,g,b; highlights r,g,b (−1–1); preserve luminosity 0/1
    COLOR_PHOTO_FILTER = 5,  // values: filter color r,g,b (0–1); density 0–1; preserve luminosity 0/1
};
void color_adjust(uint8_t *rgba, size_t width, size_t height, size_t stride, int kind, const float *values);
#endif
