#ifndef TexturePixels_h
#define TexturePixels_h
#include <stdint.h>
#include <stddef.h>
// Pixel work for the texture filters. Every image is premultiplied RGBA, 4 bytes per pixel and `stride` bytes
// per row; a color channel never exceeds its pixel's alpha, and alpha itself is left as it was unless said.

// High Pass: keeps only the detail finer than the blur that made `blurred`, on middle gray.
void texture_high_pass(uint8_t *rgba, const uint8_t *blurred, size_t width, size_t height, size_t stride);

// Unsharp Mask: pushes each pixel away from `blurred` by `amount` (1 is 100%), where they differ by at least
// `threshold` levels.
void texture_unsharp(uint8_t *rgba, const uint8_t *blurred, size_t width, size_t height, size_t stride,
                     float amount, int threshold);

// Even Lighting: takes `strength` (0–1) of the difference between `broad`, a very blurred copy, and the
// image's average color out of every pixel, flattening broad light and shade while keeping detail.
void texture_even_lighting(uint8_t *rgba, const uint8_t *broad, size_t width, size_t height, size_t stride,
                           float strength);

// A blur fades a layer's edges as transparency is mixed in. This undoes the fade: `blurred` has its color
// divided by its own blurred alpha and is given `original`'s alpha, so the inside is soft and the outline solid.
void texture_restore_edges(uint8_t *blurred, const uint8_t *original, size_t width, size_t height, size_t stride);

// Height to Normal Map: reads brightness as height (white is high) and writes a tangent-space normal map,
// opaque. `strength` scales the slopes. `y_down` flips green for engines that expect it (Unreal, DirectX);
// otherwise green points up (Godot, Unity, Blender, OpenGL). `wrap` reads across the edges, for tiling textures.
void texture_normal_map(const uint8_t *source, uint8_t *normal, size_t width, size_t height, size_t stride,
                        float strength, int y_down, int wrap);

// Clouds: soft gray noise that tiles, opaque. `cells` is the number of large features across the image; the same
// `seed` always gives the same clouds.
void texture_clouds(uint8_t *rgba, size_t width, size_t height, size_t stride, int cells, uint32_t seed);
#endif
