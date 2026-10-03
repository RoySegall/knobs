#include "../Shared/PresenceKernels.h"

namespace dehaze {
    inline float max3(float3 c) {
        return metal::max(c.r, metal::max(c.g, c.b));
    }

    inline float min3(float3 c) {
        return metal::min(c.r, metal::min(c.g, c.b));
    }

    // Guide for the transmission refinement: encoded, relative to the airlight so exposure doesn't matter.
    inline float3 guide(float3 c, float3 airlight) {
        return knobs::to_gamma(metal::max(c, 0.0) / max3(airlight));
    }
}

extern "C" {
namespace coreimage {

float4 dehaze_min_channel(sample_t s) {
    float m = max(dehaze::min3(s.rgb), 0.0);
    return float4(m, m, m, 1.0);
}

// Color weighted by a soft top slice of the dark channel (the haziest, brightest region), stored
// premultiplied so one area average yields both the weighted color sum and the weight sum.
float4 dehaze_airlight_weighted(sample_t s, sample_t dark, sample_t peak) {
    float x = clamp((dark.r - 0.9 * peak.r) / (0.1 * peak.r + 1e-6), 0.0, 1.0);
    float w = x * x * (3.0 - 2.0 * x);
    return float4(max(s.rgb, 0.0) * w, w);
}

// In a clear scene the top slice is sky, and a blue airlight would push everything whiter than it
// toward yellow, so its saturation is capped; real haze is near neutral.
float4 dehaze_airlight(sample_t average) {
    float3 a = max(average.rgb / max(average.a, 1e-6), 1e-3);
    float y = knobs::luma(a);
    float saturation = 1.0 - dehaze::min3(a) / dehaze::max3(a);
    a = y + (a - y) * min(1.0, 0.1 / max(saturation, 1e-4));
    return float4(max(a, 1e-3), 1.0);
}

float4 dehaze_guide(sample_t s, sample_t airlight) {
    return float4(dehaze::guide(s.rgb, airlight.rgb), 1.0);
}

float4 dehaze_dark_pixel(sample_t s, sample_t airlight) {
    float d = clamp(dehaze::min3(max(s.rgb, 0.0) / airlight.rgb), 0.0, 1.0);
    return float4(d, d, d, 1.0);
}

// Haze density 1 - t at full strength. The dark channel prior fails on sky, which is bright without
// being haze-free: a region whose smoothed color is within `tolerance` of the airlight keeps its
// transmission, so sky gradients, banding and noise aren't stretched.
float4 dehaze_haze(sample_t dark, sample_t smoothGuide, sample_t airlight, float floor, float tolerance) {
    float t = max(1.0 - 0.95 * dark.r, floor);
    float sky = saturate(1.0 - length(smoothGuide.rgb - dehaze::guide(airlight.rgb, airlight.rgb)) / tolerance);
    t = max(t, sky * sky * (3.0 - 2.0 * sky));
    float h = 1.0 - t;
    return float4(h, h, h, 1.0);
}

// refine: guided-filter coefficients (a in rgb, b in alpha) that rebuild the haze density from the
// full-resolution guide. edges: the image clamped to its extent, read around each pixel.
float4 dehaze_apply(sampler image, sampler edges, sampler refine, sampler airlight,
                    float amount, float floor, destination dest) {
    float2 p = dest.coord();
    float4 s = image.sample(image.transform(p));
    float3 c = presence::straight(s);
    float3 air = airlight.sample(airlight.transform(p)).rgb;
    if (amount < 0.0) {
        float3 guide = dehaze::guide(c, air);
        float4 r = refine.sample(refine.transform(p));
        float h = clamp(dot(r.rgb, guide) + r.a, 0.0, 1.0 - floor);
        // Adding haze: a veil everywhere, thicker where the scene is already far away.
        return float4(mix(c, air, -amount * (0.3 + 0.5 * h)) * s.a, s.a);
    }
    // A 3×3 tent from four bilinear taps splits off pixel-level detail. Below the noise level that
    // detail gets at most 2× gain and doesn't modulate the transmission; real edges keep both.
    float4 t0 = edges.sample(edges.transform(p + float2(-0.5, -0.5)));
    float4 t1 = edges.sample(edges.transform(p + float2(0.5, -0.5)));
    float4 t2 = edges.sample(edges.transform(p + float2(-0.5, 0.5)));
    float4 t3 = edges.sample(edges.transform(p + float2(0.5, 0.5)));
    float3 smooth = 0.25 * (presence::straight(t0) + presence::straight(t1) + presence::straight(t2) + presence::straight(t3));
    float3 detail = c - smooth;
    float level = 0.012 * max(knobs::luma(smooth), 0.0) + 5e-4;
    float edge = smoothstep(level, 3.0 * level, length(detail));
    float3 guide = dehaze::guide(mix(smooth, c, edge), air);
    float4 r = refine.sample(refine.transform(p));
    float h = clamp(dot(r.rgb, guide) + r.a, 0.0, 1.0 - floor);

    // Interpolating in log transmission keeps the slider even; the power eases the first half in.
    float t = pow(1.0 - h, pow(amount, 0.8));
    // Boundary constraint: no channel brighter than the airlight is pushed past the ceiling.
    float ceiling = max(1.0, 1.1 * dehaze::max3(air));
    float3 bound = (c - air) / max(ceiling - air, 1e-4);
    t = max(t, min(dehaze::max3(bound), 1.0));

    float gain = 1.0 / t;
    float3 j = air + (smooth - air) * gain + detail * mix(min(gain, 2.0), gain, edge);

    // Soft toe instead of clipping at zero, so recovered shadows keep their separation.
    float3 knee = min(max(c, 0.0), 0.004 * dehaze::max3(air));
    float3 toe = knee * exp(j / max(knee, 1e-6) - 1.0);
    j = select(j, toe, j < knee & c > 0.0);
    return float4(j * s.a, s.a);
}

}
}
