#include "KnobsKernels.h"

namespace auto_tone {
    // OKLab chroma of a linear sRGB color; the matrices are Björn Ottosson's.
    inline float chroma(float3 c) {
        float3 lms = float3(
            metal::dot(c, float3(0.4122214708, 0.5363325363, 0.0514459929)),
            metal::dot(c, float3(0.2119034982, 0.6806995451, 0.1073969566)),
            metal::dot(c, float3(0.0883024619, 0.2817188376, 0.6299787005)));
        lms = metal::pow(metal::max(lms, float3(0.0)), float3(1.0 / 3.0));
        float a = metal::dot(lms, float3(1.9779984951, -2.4285922050, 0.4505937099));
        float b = metal::dot(lms, float3(0.0259040371, 0.7827717662, -0.8086757660));
        return metal::sqrt(a * a + b * b);
    }
}

extern "C" {
namespace coreimage {

// What Auto Tone histograms, each in 0...1: sRGB-encoded luminance, sRGB-encoded brightest channel,
// and OKLab chroma times `chromaScale`.
float4 auto_tone_measure(sample_t s, float chromaScale) {
    float3 c = s.a > 0.0 ? s.rgb / s.a : float3(0.0);
    float y = knobs::to_gamma(metal::clamp(knobs::luma(c), 0.0, 1.0));
    float m = knobs::to_gamma(metal::clamp(metal::max(c.r, metal::max(c.g, c.b)), 0.0, 1.0));
    float k = metal::clamp(auto_tone::chroma(metal::max(c, float3(0.0))) * chromaScale, 0.0, 1.0);
    return float4(y, m, k, 1.0);
}

}
}
