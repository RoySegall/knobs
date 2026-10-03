#include "../Saturation/ColorOKLab.h"

namespace lens_corrections {
    inline float3 straight(float4 s) {
        return s.a > 0.0 ? s.rgb / s.a : float3(0.0);
    }

    inline float perceptual_luma(float4 s) {
        return knobs::to_gamma(knobs::luma(straight(s)));
    }

    inline float hue_degrees(float3 lab) {
        float hue = metal::atan2(lab.z, lab.y) * (180.0 / M_PI_F);
        return hue < 0.0 ? hue + 360.0 : hue;
    }

    // Chroma relative to lightness: unchanged by exposure, so thresholds hold in shadows and highlights.
    inline float colorfulness(float3 lab) {
        return metal::length(lab.yz) / metal::max(lab.x, 0.05f);
    }

    // Below this colorfulness a hue is noise, so a pixel counts as neutral rather than in a band.
    constant float2 color_ramp = float2(0.015, 0.05);

    // band: hue range start and end in degrees (end >= start), feather in degrees, and 1 when active.
    inline float band_weight(float3 lab, float4 band) {
        float center = 0.5 * (band.x + band.y);
        float reach = 0.5 * (band.y - band.x);
        float distance = metal::abs(metal::fmod(hue_degrees(lab) - center + 900.0, 360.0) - 180.0);
        float hue = 1.0 - metal::smoothstep(reach, reach + band.z, distance);
        return band.w * hue * metal::smoothstep(color_ramp.x, color_ramp.y, colorfulness(lab));
    }
}

extern "C" {
namespace coreimage {

// Mean of a factor x factor block (factor even, or 1), one bilinear tap per 2x2 quad. Output pixel p
// covers source pixels factor * p onward, the convention of a scale transform about the origin.
float4 lens_corrections_reduce(sampler src, float factor, destination dest) {
    float2 center = dest.coord() * factor;
    if (factor < 2.0) {
        return src.sample(src.transform(center));
    }
    int quads = int(factor * 0.5);
    float4 sum = 0.0;
    for (int j = 0; j < quads; j++) {
        for (int i = 0; i < quads; i++) {
            float2 offset = float2(2 * i + 1, 2 * j + 1) - 0.5 * factor;
            sum += src.sample(src.transform(center + offset));
        }
    }
    return sum / float(quads * quads);
}

// Perceptual luma range over the 3x3 neighbourhood: how strong an edge lies within one cell.
float4 lens_corrections_range(sampler color, destination dest) {
    float2 p = dest.coord();
    float high = -1e9;
    float low = 1e9;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float y = lens_corrections::perceptual_luma(color.sample(color.transform(p + float2(i, j))));
            high = metal::max(high, y);
            low = metal::min(low, y);
        }
    }
    float range = high - low;
    return float4(range, range, range, 1.0);
}

// Context around each block of two cells, from a tent-weighted 5x5 neighbourhood of blocks:
// r, g: per band, the colorfulness of band colors away from edges, zero where they cover too little.
// b, a: the mean chroma over lightness of colors outside both bands, faded to neutral where there are few.
float4 lens_corrections_context(sampler color, sampler range, float2 edgeRamp, float4 purple, float4 green, destination dest) {
    float2 center = dest.coord() * 2.0;
    float total = 0.0;
    float2 cover = 0.0;
    float2 colorfulCover = 0.0;
    float3 clean = 0.0;
    for (int j = -2; j <= 2; j++) {
        for (int i = -2; i <= 2; i++) {
            float2 at = center + 2.0 * float2(i, j);
            float weight = float(3 - metal::abs(i)) * float(3 - metal::abs(j));
            float3 lab = color_oklab::from_linear(lens_corrections::straight(color.sample(color.transform(at))));
            // A fringe reaches a cell past its edge's range, so "away" starts one cell further out.
            float near = metal::max(metal::max(range.sample(range.transform(at + float2(-1.0, -1.0))).r,
                                               range.sample(range.transform(at + float2(1.0, -1.0))).r),
                                    metal::max(range.sample(range.transform(at + float2(-1.0, 1.0))).r,
                                               range.sample(range.transform(at + float2(1.0, 1.0))).r));
            float away = 1.0 - metal::smoothstep(edgeRamp.x, edgeRamp.y, near);
            float2 bands = float2(lens_corrections::band_weight(lab, purple), lens_corrections::band_weight(lab, green));
            float2 interior = bands * away * weight;
            float outside = (1.0 - metal::max(bands.x, bands.y)) * weight;
            total += weight;
            cover += interior;
            colorfulCover += interior * lens_corrections::colorfulness(lab);
            clean += float3(lab.yz / metal::max(lab.x, 0.05f), 1.0) * outside;
        }
    }
    float2 colorful = colorfulCover / metal::max(cover, 1e-4f) * metal::smoothstep(0.02, 0.06, cover / total);
    float2 cleanChroma = clean.xy / metal::max(clean.z, 1e-4f) * metal::smoothstep(0.05, 0.2, clean.z / total);
    return float4(colorful, cleanChroma);
}

// Pulls a fringe's chroma toward the color beside it at constant luminance. range and context are the
// kernels above, upsampled. gains: per-band strength (purple, green).
float4 lens_corrections_apply(sample_t s, sample_t range, sample_t context, float2 edgeRamp,
                              float4 purple, float4 green, float2 gains) {
    float edge = metal::smoothstep(edgeRamp.x, edgeRamp.y, range.r);
    if (edge <= 0.0) {
        return s;
    }
    float3 c = lens_corrections::straight(s);
    float3 lab = color_oklab::from_linear(c);

    // A pixel whose color carries on, about as strong, into a region away from edges belongs to an object.
    float colorful = lens_corrections::colorfulness(lab);
    float2 keep = 1.0 - metal::smoothstep(0.35, 0.7, context.rg / metal::max(colorful, 1e-3f));
    float purpleWeight = metal::saturate(gains.x * lens_corrections::band_weight(lab, purple) * edge) * keep.x;
    float greenWeight = metal::saturate(gains.y * lens_corrections::band_weight(lab, green) * edge) * keep.y;
    float weight = metal::max(purpleWeight, greenWeight);
    if (weight <= 0.0) {
        return s;
    }

    // Never adds chroma: the neighbouring color is capped at the pixel's own.
    float chroma = metal::length(lab.yz);
    float2 target = context.ba * metal::max(lab.x, 0.05f);
    float targetChroma = metal::length(target);
    target *= targetChroma > chroma ? chroma / targetChroma : 1.0;
    float2 ab = metal::mix(lab.yz, target, weight);
    float3 edited = color_oklab::match_luma(color_oklab::to_linear(float3(lab.x, ab)), knobs::luma(c));
    return float4(edited * s.a, s.a);
}

}
}
