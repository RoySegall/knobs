// Helpers shared by the texture, clarity and dehaze kernels.
#pragma once

#include "KnobsKernels.h"

namespace presence {
    // Kernels work on straight color and premultiply on the way out, so a pixel outside the image
    // (alpha 0) stays clear even where Core Image evaluates the kernel past its extent.
    inline float3 straight(float4 s) {
        return s.a > 0.0 ? s.rgb / s.a : float3(0.0);
    }

    // Local contrast is measured on sRGB-encoded luminance so it reads evenly from shadows to highlights.
    inline float perceptual_luma(float3 c) {
        return knobs::to_gamma(knobs::luma(c));
    }

    // Moves a pixel to linear luminance `target`, keeping its chromaticity. The gain is capped so a
    // near-black pixel gets a neutral lift instead of amplified chroma noise.
    inline float3 with_luma(float3 c, float target) {
        float y = knobs::luma(c);
        if (y <= 1e-5) {
            return c + (target - y);
        }
        float gain = metal::clamp(target / y, 0.0, 4.0);
        return c * gain + (target - y * gain);
    }
}
