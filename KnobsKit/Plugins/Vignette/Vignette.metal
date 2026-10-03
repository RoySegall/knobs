#include "KnobsKernels.h"

extern "C" {
namespace coreimage {

// frame: center and half size in working pixels. shape: axis weights, superellipse exponent, 1 / (wx^p + wy^p).
// ramp: where the falloff starts and ends, in units where the corners sit at 1.
float4 vignette_apply(sample_t s, float4 frame, float4 shape, float2 ramp, float amount, float highlights, destination dest) {
    float2 uv = metal::abs((dest.coord() - frame.xy) / frame.zw) * shape.xy;
    float p = shape.z;
    float d = metal::pow((metal::pow(uv.x, p) + metal::pow(uv.y, p)) * shape.w, 1.0 / p);
    float m = metal::smoothstep(ramp.x, ramp.y, d);
    if (amount < 0.0) {
        // Highlight priority: darken like an exposure cut, and spare bright pixels as Highlights rises.
        float factor = metal::exp2(4.0 * amount * m);
        float bright = knobs::to_gamma(metal::max(s.r, metal::max(s.g, s.b)));
        float keep = highlights * metal::smoothstep(0.5, 1.0, bright);
        return float4(s.rgb * metal::mix(factor, 1.0, keep), s.a);
    }
    // Lighten toward white like a screen blend; values already above white stay put.
    float3 g = knobs::to_gamma(s.rgb);
    g = metal::max(g, g + (1.0 - g) * amount * m);
    return float4(knobs::to_linear(g), s.a);
}

}
}
