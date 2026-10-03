#include "KnobsKernels.h"

extern "C" {
namespace coreimage {

// Looks each channel up in its own column of the curve row, in gamma space. Outside 0...1 (HDR
// highlights, out-of-gamut negatives) the curve continues along its end tangent.
float4 tone_curve_apply(sampler image, sampler lut, float last, float3 low, float3 low_slope, float3 high, float3 high_slope) {
    float4 pixel = unpremultiply(image.sample(image.coord()));
    float3 t = knobs::to_gamma(pixel.rgb);
    float3 x = 0.5 + metal::clamp(t, 0.0, 1.0) * last;
    float3 y = float3(
        lut.sample(lut.transform(float2(x.r, 0.5))).r,
        lut.sample(lut.transform(float2(x.g, 0.5))).g,
        lut.sample(lut.transform(float2(x.b, 0.5))).b
    );
    y = metal::select(y, low + low_slope * t, t < 0.0);
    y = metal::select(y, high + high_slope * (t - 1.0), t > 1.0);
    return premultiply(float4(knobs::to_linear(y), pixel.a));
}

}
}
