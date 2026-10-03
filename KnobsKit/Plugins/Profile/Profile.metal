#include "KnobsKernels.h"

namespace profile {
    // `domain` is (log2 of the first sample, samples per stop, index of the last sample, slope below
    // the first sample). Below the row the curve runs straight to black; past it, it holds its end.
    static inline float tone(float x, coreimage::sampler lut, float4 domain) {
        float stop = x > 0.0 ? metal::log2(x) : domain.x;
        if (stop <= domain.x) return x * domain.w;
        float position = metal::min((stop - domain.x) * domain.y, domain.z);
        return lut.sample(lut.transform(float2(position + 0.5, 0.5))).r;
    }
}

extern "C" {
namespace coreimage {

// Scene-linear to display: the color matrix, then the curve on the brightest and darkest channel with
// the middle one kept at its relative place between them, as the display roll-off does, so hue holds.
float4 profile_apply(sampler image, sampler lut, float3 red, float3 green, float3 blue, float4 domain) {
    float4 pixel = unpremultiply(image.sample(image.coord()));
    float3 c = float3(metal::dot(red, pixel.rgb), metal::dot(green, pixel.rgb), metal::dot(blue, pixel.rgb));
    float high = metal::max(c.r, metal::max(c.g, c.b));
    float low = metal::min(c.r, metal::min(c.g, c.b));
    float newHigh = profile::tone(high, lut, domain);
    float newLow = profile::tone(low, lut, domain);
    float span = high - low;
    float3 t = span > 1e-6 ? (c - low) / span : float3(0.0);
    return premultiply(float4(newLow + (newHigh - newLow) * t, pixel.a));
}

}
}
