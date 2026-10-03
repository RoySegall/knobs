#include "../Saturation/ColorOKLab.h"

extern "C" {
namespace coreimage {

// A chroma gain that favors muted colors and spares skin, applied like saturation's.
float4 vibrance_apply(sample_t s, float amount) {
    float3 c = color_oklab::unpremultiply(s);
    float3 lab = color_oklab::from_linear(c);
    float chroma = metal::length(lab.yz);
    float hue = metal::atan2(lab.z, lab.y) * (180.0 / M_PI_F);

    // Skin sits around OKLab hue 45-75 at modest chroma; a vivid orange is not protected.
    float fromSkin = metal::abs(metal::fmod(hue - 60.0 + 540.0, 360.0) - 180.0);
    float skin = (1.0 - metal::smoothstep(12.0, 40.0, fromSkin)) * (1.0 - metal::smoothstep(0.11, 0.2, chroma));
    float protect = 1.0 - 0.7 * skin;

    float saturation = color_oklab::display_saturation(c);
    float muted = 1.0 - saturation;
    float gain = amount > 0.0
        ? 1.0 + amount * 1.5 * muted * muted * protect
        : 1.0 + amount * (0.5 + 0.4 * saturation) * protect;

    float3 edited = color_oklab::to_linear(color_oklab::scale_chroma(lab, gain));
    edited = gain < 1.0 ? color_oklab::match_luma(edited, knobs::luma(c)) : edited;
    return float4(edited * s.a, s.a);
}

}
}
