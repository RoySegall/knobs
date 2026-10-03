#include "ColorOKLab.h"

extern "C" {
namespace coreimage {

// Scales OKLab chroma. Muting keeps luminance, so -100 lands on a gray of equal luminance;
// boosting keeps OKLab lightness, so a deeper blue does not also turn lighter.
float4 saturation_apply(sample_t s, float gain) {
    float3 c = color_oklab::unpremultiply(s);
    float3 edited = color_oklab::to_linear(color_oklab::scale_chroma(color_oklab::from_linear(c), gain));
    edited = gain < 1.0 ? color_oklab::match_luma(edited, knobs::luma(c)) : edited;
    return float4(edited * s.a, s.a);
}

}
}
