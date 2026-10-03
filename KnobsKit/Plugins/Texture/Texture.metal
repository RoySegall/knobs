#include "../Shared/PresenceKernels.h"

extern "C" {
namespace coreimage {

// Luminance and its centered square, so one coarse blur also yields the local variance.
float4 texture_moments(sample_t s) {
    float l = presence::perceptual_luma(presence::straight(s));
    return float4(l, (l - 0.5) * (l - 0.5), 0.0, 1.0);
}

// fine - coarse is the medium-fine band: pores, foliage, fabric. Pixel-level noise sits above it.
// The gate falls toward zero where the coarse window holds a real edge, so edges neither ring
// when texture is added nor smear when it is removed.
float4 texture_apply(sample_t s, sample_t fine, sample_t coarse, float amount, float epsilon) {
    float3 c = presence::straight(s);
    float l = presence::perceptual_luma(c);
    float mean = coarse.r;
    float variance = max(coarse.g - (mean - 0.5) * (mean - 0.5), 0.0);
    float gate = epsilon / (variance + epsilon);
    float band = fine.r - mean;
    float delta;
    if (amount >= 0.0) {
        float knee = 0.08;
        delta = amount * 2.0 * gate * knee * tanh(band / knee);
    } else {
        // Smoothing keeps half of the finest detail, so skin doesn't turn plastic.
        delta = amount * gate * (band + 0.5 * (l - fine.r));
    }
    float target = knobs::to_linear(max(l + delta, 0.0));
    return float4(presence::with_luma(c, target) * s.a, s.a);
}

}
}
