// Shared helpers for plugin kernels. Pixels arrive in linear extended sRGB and may exceed 1.
#pragma once

#include <CoreImage/CoreImage.h>
#include <metal_stdlib>

namespace knobs {
    inline float luma(float3 c) {
        return metal::dot(c, float3(0.2126, 0.7152, 0.0722));
    }

    // sRGB transfer curve, mirrored for negatives so out-of-gamut values survive a round trip.
    inline float to_gamma(float x) {
        float a = metal::abs(x);
        float y = a <= 0.0031308 ? a * 12.92 : 1.055 * metal::pow(a, 1.0 / 2.4) - 0.055;
        return metal::copysign(y, x);
    }

    inline float to_linear(float x) {
        float a = metal::abs(x);
        float y = a <= 0.04045 ? a / 12.92 : metal::pow((a + 0.055) / 1.055, 2.4);
        return metal::copysign(y, x);
    }

    inline float3 to_gamma(float3 c) {
        return float3(to_gamma(c.r), to_gamma(c.g), to_gamma(c.b));
    }

    inline float3 to_linear(float3 c) {
        return float3(to_linear(c.r), to_linear(c.g), to_linear(c.b));
    }
}
