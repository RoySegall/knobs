#include "../Shared/PresenceKernels.h"

extern "C" {
namespace coreimage {

// coefficients: the guided filter's a (r) and b (g), so a * l + b is the edge-aware base.
// small: luminance from the copy the filter was solved on. Detail finer than its pixels gets only
// part of the gain, so clarity works on structure and leaves pixel noise to texture and sharpening.
float4 clarity_apply(sample_t s, sample_t coefficients, sample_t small, float amount) {
    float3 c = presence::straight(s);
    float l = presence::perceptual_luma(c);
    float a = coefficients.r;
    float b = coefficients.g;
    float structure = mix(small.r, l, 0.4);
    float knee = 0.25;
    // Where the window straddles a strong edge (a near 1) the residual is mostly the edge itself.
    float detail = sqrt(saturate(1.0 - a)) * knee * tanh(((1.0 - a) * structure - b) / knee);
    // Midtones get the full effect; deep shadows and highlights are protected.
    float base = a * l + b;
    float weight = smoothstep(0.0, 0.35, base) * (1.0 - smoothstep(0.7, 1.05, base));
    float gain = amount >= 0.0 ? 1.3 * amount : 0.9 * amount;
    float target = knobs::to_linear(max(l + gain * weight * detail, 0.0));
    return float4(presence::with_luma(c, target) * s.a, s.a);
}

}
}
