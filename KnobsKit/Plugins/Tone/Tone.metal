#include "KnobsKernels.h"

namespace tone {
    static inline float log_luminance(float3 c) {
        return metal::log2(metal::max(knobs::luma(c), 1.0 / 16384.0));
    }

    // Stops to add where the smoothed log2 luminance is `base`. Highlights compress or stretch the
    // range above mid-gray around mid-gray; shadows add exposure that fades out toward mid-gray.
    static inline float shift(float base, float highlights, float shadows) {
        const float middle = -2.474;
        float bright = metal::smoothstep(middle, 0.0, base) * (base - middle);
        float dark = 1.0 - metal::smoothstep(-6.5, -1.5, base);
        return highlights * bright + shadows * dark;
    }

    // Whites and blacks in sRGB gamma. Past each knee a curve moves the far end most and meets the
    // identity with matching slope, so mid-tones hold. Stretching stops at 0 and 1: beyond them values
    // only shift, so out-of-gamut colors don't grow.
    static inline float ends(float g, float whites, float blacks) {
        const float whiteKnee = 0.5;
        const float blackKnee = 0.3;
        if (g > whiteKnee) {
            float u = (g - whiteKnee) / (1.0 - whiteKnee);
            if (whites < 0.0) return whiteKnee + (1.0 - whiteKnee) * u / (1.0 - whites * u);
            float inside = metal::min(u, 1.0);
            return whiteKnee + (1.0 - whiteKnee) * (inside + whites * inside * inside) + metal::max(g - 1.0, 0.0);
        }
        if (g < blackKnee) {
            float u = (blackKnee - g) / blackKnee;
            if (blacks > 0.0) return blackKnee * (1.0 - u / (1.0 + blacks * u));
            // Crushed blacks clip at zero; already-negative values are left alone.
            return g < 0.0 ? g : metal::max(blackKnee * (1.0 - u + blacks * u * u), 0.0);
        }
        return g;
    }

    static inline float ends_linear(float x, float whites, float blacks) {
        return knobs::to_linear(ends(knobs::to_gamma(x), whites, blacks));
    }

    // Curves the brightest and darkest channel and keeps the middle one at the same relative place
    // between them, as Adobe's RGB tone curve does, so hue holds.
    static inline float3 apply_ends(float3 c, float whites, float blacks) {
        if (whites == 0.0 && blacks == 0.0) return c;
        float high = metal::max(c.r, metal::max(c.g, c.b));
        float low = metal::min(c.r, metal::min(c.g, c.b));
        float newHigh = ends_linear(high, whites, blacks);
        float newLow = ends_linear(low, whites, blacks);
        float span = high - low;
        float3 t = span > 1e-6 ? (c - low) / span : float3(0.0);
        return newLow + (newHigh - newLow) * t;
    }
}

extern "C" {
namespace coreimage {

float4 tone_log_luminance(sample_t s) {
    return float4(tone::log_luminance(s.rgb), 0.0, 0.0, 1.0);
}

// Squared distance from the local mean. Blurred, it stands in for the window variance; unlike
// E[L²] - E[L]², it survives half-float intermediates.
float4 tone_deviation(sample_t luminance, sample_t mean) {
    float d = luminance.r - mean.r;
    return float4(d * d, 0.0, 0.0, 1.0);
}

// Self-guided filter coefficients: flat areas take the local mean, strong edges keep the pixel.
// Epsilon shrinks where variance is far above texture level, so a window that is mostly the
// other side of a big edge can't drag the base across it (a halo).
float4 tone_coefficients(sample_t mean, sample_t variance, float epsilon) {
    const float edgeVariance = 0.5;
    float v = variance.r;
    float a = v / (v + epsilon * edgeVariance / (v + edgeVariance));
    return float4(a, mean.r * (1.0 - a), 0.0, 1.0);
}

float4 tone_apply(sample_t s, sample_t coefficients, float highlights, float shadows, float whites, float blacks) {
    float base = coefficients.r * tone::log_luminance(s.rgb) + coefficients.g;
    float3 c = s.rgb * metal::exp2(tone::shift(base, highlights, shadows));
    return float4(tone::apply_ends(c, whites, blacks), s.a);
}

float4 tone_ends(sample_t s, float whites, float blacks) {
    return float4(tone::apply_ends(s.rgb, whites, blacks), s.a);
}

}
}
