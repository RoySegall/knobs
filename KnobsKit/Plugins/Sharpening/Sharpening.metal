#include "KnobsKernels.h"

namespace sharpening {
    // sRGB-encoded luminance. Sharpening works on this so it never shifts color.
    inline float luma(float4 s) {
        return knobs::to_gamma(knobs::luma(s.rgb));
    }

    // Core Image may evaluate a general kernel outside its extent once a later stage moves the image,
    // and the clamped source would smear there. The kernel returns clear outside `bounds` (min xy, max xy).
    inline bool outside(float2 p, float4 bounds) {
        return p.x < bounds.x || p.y < bounds.y || p.x > bounds.z || p.y > bounds.w;
    }
}

extern "C" {
namespace coreimage {

float4 sharpening_luma(sample_t s) {
    float y = sharpening::luma(s);
    return float4(y, y, y, 1.0);
}

// Unsharp mask on luma over a window of up to 7x7, reading luma from the source so it needs no extra pass.
// blur: sigma, or 0 to read `blurred`. texture: damping level. halo: overshoot kept past the 3x3 extremes.
// mask: edge-height ramp (zero turns masking off) and the edge detector's sigma.
float4 sharpening_apply(sampler src, sampler blurred, float4 bounds, float blur, float reach,
                        float gain, float texture, float halo, float3 mask, destination dest) {
    float2 p = dest.coord();
    if (sharpening::outside(p, bounds)) { return 0.0; }
    float4 s = src.sample(src.transform(p));
    float y = sharpening::luma(s);
    bool masked = mask.y > 0.0;
    bool inline_blur = blur > 0.0;
    float blurK = inline_blur ? -0.5 / (blur * blur) : 0.0;
    float edgeK = masked ? -0.5 / (mask.z * mask.z) : 0.0;

    float low = y;
    float high = y;
    float sum = 0.0;
    float total = 0.0;
    float2 gradient = 0.0;
    float edgeTotal = 0.0;
    int n = int(reach);
    for (int j = -n; j <= n; j++) {
        for (int i = -n; i <= n; i++) {
            float2 o = float2(i, j);
            float v = sharpening::luma(src.sample(src.transform(p + o)));
            float r2 = metal::dot(o, o);
            if (r2 <= 2.0) {
                low = metal::min(low, v);
                high = metal::max(high, v);
            }
            if (inline_blur) {
                float w = metal::exp(r2 * blurK);
                sum += w * v;
                total += w;
            }
            if (masked) {
                float w = metal::exp(r2 * edgeK);
                gradient += w * o * v;
                edgeTotal += w;
            }
        }
    }

    float h = y - (inline_blur ? sum / total : blurred.sample(blurred.transform(p)).x);
    float h2 = h * h;
    h *= h2 / (h2 + texture * texture + 1e-12);

    float weight = 1.0;
    if (masked) {
        // Derivative of the Gaussian-smoothed luma, scaled so a step edge reads as its height.
        float slope = metal::length(gradient) / (edgeTotal * mask.z * mask.z);
        weight = metal::smoothstep(mask.x, mask.y, slope * mask.z * 2.5066283);
    }

    float target = y + gain * h * weight;
    float limited = metal::clamp(target, low, high);
    float sharpened = limited + (target - limited) * halo;
    float3 g = knobs::to_gamma(s.rgb) + (sharpened - y);
    return float4(knobs::to_linear(g), s.a);
}

}
}
