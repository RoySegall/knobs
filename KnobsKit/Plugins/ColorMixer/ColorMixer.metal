#include "../Saturation/ColorOKLab.h"

extern "C" {
namespace coreimage {

// Eight hue bands with smoothstep weights between neighboring centers; any two neighbors sum to one,
// so there are no seams. Values arrive per band: hue shift (degrees), chroma gain - 1, log2 lightness gain.
float4 color_mixer_apply(sample_t s, float4 centersA, float4 centersB, float4 hueA, float4 hueB,
                         float4 satA, float4 satB, float4 lumA, float4 lumB) {
    float centers[8] = { centersA.x, centersA.y, centersA.z, centersA.w, centersB.x, centersB.y, centersB.z, centersB.w };
    float hues[8] = { hueA.x, hueA.y, hueA.z, hueA.w, hueB.x, hueB.y, hueB.z, hueB.w };
    float sats[8] = { satA.x, satA.y, satA.z, satA.w, satB.x, satB.y, satB.z, satB.w };
    float lums[8] = { lumA.x, lumA.y, lumA.z, lumA.w, lumB.x, lumB.y, lumB.z, lumB.w };

    float3 c = color_oklab::unpremultiply(s);
    float3 lab = color_oklab::from_linear(c);
    float chroma = metal::length(lab.yz);
    float hue = metal::atan2(lab.z, lab.y) * (180.0 / M_PI_F);
    hue = hue < 0.0 ? hue + 360.0 : hue;

    // Below the first center the segment is the wrap from the last band back to the first.
    int band = 7;
    for (int index = 0; index < 8; index++) {
        band = hue >= centers[index] ? index : band;
    }
    int next = (band + 1) % 8;
    float start = centers[band];
    float span = metal::fmod(centers[next] - start + 360.0, 360.0);
    float t = metal::fmod(hue - start + 360.0, 360.0) / span;
    float w = metal::smoothstep(0.0, 1.0, t);

    float shift = metal::mix(hues[band], hues[next], w) * (M_PI_F / 180.0);
    float gain = 1.0 + metal::mix(sats[band], sats[next], w);
    // Hue is noise on near-grays, so lightness only follows the bands once there is real color.
    float stops = metal::mix(lums[band], lums[next], w) * metal::smoothstep(0.0, 0.06, chroma);

    float cosine = metal::cos(shift);
    float sine = metal::sin(shift);
    float2 ab = float2(lab.y * cosine - lab.z * sine, lab.y * sine + lab.z * cosine) * metal::max(gain, 0.0);
    float3 edited = color_oklab::to_linear(color_oklab::fit_gamut(lab, float3(lab.x * metal::exp2(stops), ab)));
    return float4(edited * s.a, s.a);
}

}
}
