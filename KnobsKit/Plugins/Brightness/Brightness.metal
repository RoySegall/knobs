#include "KnobsKernels.h"

extern "C" {
namespace coreimage {

// A power curve on the brightest channel in gamma space, applied as a ratio so hue and saturation
// hold. Past white it continues with the curve's slope at 1, so highlights above 1 stay ordered.
float4 brightness_apply(sample_t s, float gamma) {
    float high = metal::max(s.r, metal::max(s.g, s.b));
    if (high <= 0.0) return s;
    float g = knobs::to_gamma(high);
    float curved = g <= 1.0 ? metal::pow(g, gamma) : 1.0 + (g - 1.0) * gamma;
    float target = knobs::to_linear(curved);
    return float4(s.rgb * (target / high), s.a);
}

}
}
