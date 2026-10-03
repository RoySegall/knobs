#include "KnobsKernels.h"

namespace contrast {
    // Rational S-curve in gamma space: slope `slope` at the pivot, 1 / slope at black and white.
    // Past both ends it goes straight and never steeper than 1, so out-of-gamut colors don't grow.
    static inline float curve(float g, float slope) {
        // Linear 0.18 in sRGB gamma: the curve turns around photographic mid-gray.
        const float pivot = 0.4613;
        float outside = metal::min(1.0, 1.0 / slope);
        if (g <= 0.0) return g * outside;
        if (g >= 1.0) return 1.0 + (g - 1.0) * outside;
        float k = slope - 1.0;
        if (g < pivot) {
            float u = g / pivot;
            return pivot * u / (k * (1.0 - u) + 1.0);
        }
        float u = (1.0 - g) / (1.0 - pivot);
        return 1.0 - (1.0 - pivot) * u / (k * (1.0 - u) + 1.0);
    }

    static inline float tone(float x, float slope) {
        return knobs::to_linear(curve(knobs::to_gamma(x), slope));
    }
}

extern "C" {
namespace coreimage {

// Curves the brightest and darkest channel and keeps the middle one at the same relative place
// between them, as Adobe's RGB tone curve does, so hue holds while saturation follows the curve.
float4 contrast_apply(sample_t s, float slope) {
    float3 c = s.rgb;
    float high = metal::max(c.r, metal::max(c.g, c.b));
    float low = metal::min(c.r, metal::min(c.g, c.b));
    float newHigh = contrast::tone(high, slope);
    float newLow = contrast::tone(low, slope);
    float span = high - low;
    float3 t = span > 1e-6 ? (c - low) / span : float3(0.0);
    return float4(newLow + (newHigh - newLow) * t, s.a);
}

}
}
