#include "../Saturation/ColorOKLab.h"

extern "C" {
namespace coreimage {

// Split toning in OKLab. Each range's weight comes from lightness (balance bends it, blending widens it);
// its wheel adds chroma in proportion to lightness, so black stays neutral, and its slider scales lightness.
// shape = (balance exponent, shadows end, highlights start, midtones half-width).
float4 color_grading_apply(sample_t s, float4 tintsLow, float4 tintsHigh, float4 lums, float4 shape) {
    float3 c = color_oklab::unpremultiply(s);
    float3 lab = color_oklab::from_linear(c);
    float u = metal::pow(metal::max(metal::saturate(lab.x), 1e-6f), shape.x);
    float shadows = 1.0 - metal::smoothstep(0.0, shape.y, u);
    float highlights = metal::smoothstep(shape.z, 1.0, u);
    float midtones = 1.0 - metal::smoothstep(0.0, shape.w, metal::abs(u - 0.5));

    float2 tint = shadows * tintsLow.xy + midtones * tintsLow.zw + highlights * tintsHigh.xy + tintsHigh.zw;
    float gain = 1.0 + shadows * lums.x + midtones * lums.y + highlights * lums.z + lums.w;
    float3 graded = float3(lab.x * metal::max(gain, 0.0), lab.yz + tint * metal::saturate(lab.x));
    float3 edited = color_oklab::to_linear(color_oklab::fit_gamut(lab, graded));
    return float4(edited * s.a, s.a);
}

}
}
