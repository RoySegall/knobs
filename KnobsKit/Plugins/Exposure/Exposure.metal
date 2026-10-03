#include "KnobsKernels.h"

namespace exposure {
    // Above the knee, a rational shoulder lands the pushed source white (`white`) on 1 with slope 1
    // at the knee. At a gain of 1 it is the identity, so the slider stays continuous.
    static inline float shoulder(float m, float white) {
        const float knee = 0.6;
        if (m <= knee) return m;
        float over = m - knee;
        return knee + over / (1.0 + over * (white - 1.0) / ((1.0 - knee) * (white - knee)));
    }
}

extern "C" {
namespace coreimage {

// A pushed bitmap has nothing above its white, so plain gain would clip each channel on its own and
// shift hue (skin turns yellow). The shoulder curves the brightest and darkest channel and keeps the
// middle one in place between them, like Adobe's RGB tone curve, so highlights fade toward white.
float4 exposure_apply(sample_t s, float stops) {
    float gain = metal::exp2(stops);
    float3 c = s.rgb * gain;
    if (gain <= 1.0) return float4(c, s.a);
    float high = metal::max(c.r, metal::max(c.g, c.b));
    float low = metal::min(c.r, metal::min(c.g, c.b));
    float newHigh = exposure::shoulder(high, gain);
    float newLow = exposure::shoulder(low, gain);
    float span = high - low;
    float3 t = span > 1e-6 ? (c - low) / span : float3(0.0);
    return float4(newLow + (newHigh - newLow) * t, s.a);
}

}
}
