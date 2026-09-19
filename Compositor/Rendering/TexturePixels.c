#include "TexturePixels.h"
#include <math.h>

static inline uint8_t within(float value, uint8_t alpha) {
    return value <= 0 ? 0 : value >= alpha ? alpha : (uint8_t)(value + 0.5f);
}

void texture_high_pass(uint8_t *rgba, const uint8_t *blurred, size_t width, size_t height, size_t stride) {
    for (size_t y = 0; y < height; ++y) {
        uint8_t *p = rgba + y * stride; const uint8_t *b = blurred + y * stride;
        for (size_t x = 0; x < width; ++x, p += 4, b += 4) {
            uint8_t alpha = p[3];
            if (!alpha) continue;
            // Middle gray, premultiplied like everything else.
            float gray = 128.0f * alpha / 255.0f;
            for (int c = 0; c < 3; ++c) p[c] = within((float)p[c] - (float)b[c] + gray, alpha);
        }
    }
}

void texture_unsharp(uint8_t *rgba, const uint8_t *blurred, size_t width, size_t height, size_t stride,
                     float amount, int threshold) {
    for (size_t y = 0; y < height; ++y) {
        uint8_t *p = rgba + y * stride; const uint8_t *b = blurred + y * stride;
        for (size_t x = 0; x < width; ++x, p += 4, b += 4) {
            uint8_t alpha = p[3];
            if (!alpha) continue;
            for (int c = 0; c < 3; ++c) {
                float difference = (float)p[c] - (float)b[c];
                if (fabsf(difference) < (float)threshold) continue;
                p[c] = within((float)p[c] + difference * amount, alpha);
            }
        }
    }
}

void texture_even_lighting(uint8_t *rgba, const uint8_t *broad, size_t width, size_t height, size_t stride,
                           float strength) {
    double sum[3] = {0, 0, 0}, covered = 0;
    for (size_t y = 0; y < height; ++y) {
        const uint8_t *b = broad + y * stride;
        for (size_t x = 0; x < width; ++x, b += 4) {
            if (!b[3]) continue;
            // Straight color, so a soft edge does not drag the average down.
            for (int c = 0; c < 3; ++c) sum[c] += (double)b[c] * 255.0 / b[3];
            covered += 1;
        }
    }
    if (covered == 0) return;
    float mean[3] = { (float)(sum[0] / covered), (float)(sum[1] / covered), (float)(sum[2] / covered) };
    for (size_t y = 0; y < height; ++y) {
        uint8_t *p = rgba + y * stride; const uint8_t *b = broad + y * stride;
        for (size_t x = 0; x < width; ++x, p += 4, b += 4) {
            uint8_t alpha = p[3];
            if (!alpha || !b[3]) continue;
            float scale = alpha / 255.0f;
            for (int c = 0; c < 3; ++c) {
                float light = (float)b[c] * 255.0f / b[3];
                p[c] = within((float)p[c] - strength * (light - mean[c]) * scale, alpha);
            }
        }
    }
}

void texture_restore_edges(uint8_t *blurred, const uint8_t *original, size_t width, size_t height, size_t stride) {
    for (size_t y = 0; y < height; ++y) {
        uint8_t *p = blurred + y * stride; const uint8_t *o = original + y * stride;
        for (size_t x = 0; x < width; ++x, p += 4, o += 4) {
            uint8_t alpha = o[3];
            if (!alpha || !p[3]) { p[0] = p[1] = p[2] = p[3] = 0; continue; }
            float scale = (float)alpha / (float)p[3];
            for (int c = 0; c < 3; ++c) p[c] = within((float)p[c] * scale, alpha);
            p[3] = alpha;
        }
    }
}

static inline float height_at(const uint8_t *source, size_t width, size_t height, size_t stride, long x, long y, int wrap) {
    long w = (long)width, h = (long)height;
    if (wrap) { x = ((x % w) + w) % w; y = ((y % h) + h) % h; }
    else { x = x < 0 ? 0 : x >= w ? w - 1 : x; y = y < 0 ? 0 : y >= h ? h - 1 : y; }
    const uint8_t *p = source + (size_t)y * stride + (size_t)x * 4;
    if (!p[3]) return 0;
    // Brightness of the straight color, 0–1.
    return (0.2126f * p[0] + 0.7152f * p[1] + 0.0722f * p[2]) / (float)p[3];
}

void texture_normal_map(const uint8_t *source, uint8_t *normal, size_t width, size_t height, size_t stride,
                        float strength, int y_down, int wrap) {
    for (size_t y = 0; y < height; ++y) {
        uint8_t *out = normal + y * stride;
        for (size_t x = 0; x < width; ++x, out += 4) {
            long px = (long)x, py = (long)y;
            #define H(dx, dy) height_at(source, width, height, stride, px + (dx), py + (dy), wrap)
            // Sobel slopes; rows run downward.
            float across = (H(1,-1) + 2 * H(1,0) + H(1,1)) - (H(-1,-1) + 2 * H(-1,0) + H(-1,1));
            float down = (H(-1,1) + 2 * H(0,1) + H(1,1)) - (H(-1,-1) + 2 * H(0,-1) + H(1,-1));
            #undef H
            float nx = -across * strength, ny = (y_down ? -down : down) * strength, nz = 1;
            float length = sqrtf(nx * nx + ny * ny + nz * nz);
            out[0] = (uint8_t)((nx / length * 0.5f + 0.5f) * 255.0f + 0.5f);
            out[1] = (uint8_t)((ny / length * 0.5f + 0.5f) * 255.0f + 0.5f);
            out[2] = (uint8_t)((nz / length * 0.5f + 0.5f) * 255.0f + 0.5f);
            out[3] = 255;
        }
    }
}

static inline float lattice(uint32_t x, uint32_t y, uint32_t seed) {
    uint32_t h = x * 0x9E3779B1u ^ y * 0x85EBCA77u ^ seed * 0xC2B2AE3Du;
    h ^= h >> 15; h *= 0x2C1B3C6Du; h ^= h >> 12; h *= 0x297A2D39u; h ^= h >> 15;
    return (float)(h >> 8) / 16777215.0f;
}

void texture_clouds(uint8_t *rgba, size_t width, size_t height, size_t stride, int cells, uint32_t seed) {
    if (cells < 1) cells = 1;
    for (size_t y = 0; y < height; ++y) {
        uint8_t *p = rgba + y * stride;
        for (size_t x = 0; x < width; ++x, p += 4) {
            float total = 0, weight = 0, amplitude = 1;
            // Each octave's lattice repeats exactly once across the image, which is what makes the result tile.
            for (int octave = 0, count = cells; octave < 6; ++octave, count *= 2, amplitude *= 0.5f) {
                float fx = (float)x / (float)width * (float)count, fy = (float)y / (float)height * (float)count;
                uint32_t ix = (uint32_t)fx, iy = (uint32_t)fy, n = (uint32_t)count;
                float tx = fx - (float)ix, ty = fy - (float)iy;
                tx = tx * tx * (3 - 2 * tx); ty = ty * ty * (3 - 2 * ty);
                uint32_t s = seed + (uint32_t)octave * 101u;
                float top = lattice(ix % n, iy % n, s) * (1 - tx) + lattice((ix + 1) % n, iy % n, s) * tx;
                float bottom = lattice(ix % n, (iy + 1) % n, s) * (1 - tx) + lattice((ix + 1) % n, (iy + 1) % n, s) * tx;
                total += (top * (1 - ty) + bottom * ty) * amplitude;
                weight += amplitude;
            }
            uint8_t value = (uint8_t)(total / weight * 255.0f + 0.5f);
            p[0] = p[1] = p[2] = value; p[3] = 255;
        }
    }
}

void texture_edge_bleed(uint8_t *straight, uint8_t *scratch, size_t width, size_t height, size_t stride, int distance) {
    // scratch: 0 empty, 1 has a color, 2 colored during this pass (so a pass only reads the pass before it).
    for (size_t y = 0; y < height; ++y)
        for (size_t x = 0; x < width; ++x) scratch[y * width + x] = straight[y * stride + x * 4 + 3] ? 1 : 0;
    for (int pass = 0; pass < distance; ++pass) {
        int changed = 0;
        for (size_t y = 0; y < height; ++y) {
            for (size_t x = 0; x < width; ++x) {
                if (scratch[y * width + x]) continue;
                int sum[3] = {0, 0, 0}, count = 0;
                for (int dy = -1; dy <= 1; ++dy) for (int dx = -1; dx <= 1; ++dx) {
                    long nx = (long)x + dx, ny = (long)y + dy;
                    if ((!dx && !dy) || nx < 0 || ny < 0 || nx >= (long)width || ny >= (long)height) continue;
                    if (scratch[(size_t)ny * width + (size_t)nx] != 1) continue;
                    const uint8_t *n = straight + (size_t)ny * stride + (size_t)nx * 4;
                    sum[0] += n[0]; sum[1] += n[1]; sum[2] += n[2]; ++count;
                }
                if (!count) continue;
                uint8_t *p = straight + y * stride + x * 4;
                for (int c = 0; c < 3; ++c) p[c] = (uint8_t)((sum[c] + count / 2) / count);
                scratch[y * width + x] = 2; changed = 1;
            }
        }
        if (!changed) break;
        for (size_t i = 0; i < width * height; ++i) if (scratch[i] == 2) scratch[i] = 1;
    }
}
