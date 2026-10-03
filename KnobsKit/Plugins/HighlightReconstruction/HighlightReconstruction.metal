#include "KnobsKernels.h"

// Apple's RAW decoder writes a sensor-clipped pixel as one exact value, the clip white, and pulls
// partly clipped pixels toward it. The work copy finds that plateau; the full-size pass rebuilds
// what it hid from the colors and brightness around it.

namespace highlight_reconstruction {
    // A channel this close to its clip level counts as clipped. The ramp keeps the edge seamless.
    constant float clipStart = 0.9;
    constant float clipEnd = 0.99;
    // Brightness (share of the clip level) over which a color drifting toward the clip white is
    // taken for the decoder's doing. Below it, a near-white sky is left as it is.
    constant float restoreStart = 0.65;
    constant float restoreEnd = 0.8;
    // A pixel exactly the clip white's color is one the decoder whitened, at any brightness above this.
    constant float whitenedStart = 0.45;
    constant float whitenedEnd = 0.6;
    // Pixels darker than this share of the clip level lend their color to the clipped ones.
    constant float sourceStart = 0.5;
    constant float sourceEnd = 0.68;
    // A plateau block is one value to within this share, so smooth unclipped skies don't count.
    constant float flatTolerance = 1e-4;

    inline float max3(float3 c) {
        return metal::max(c.r, metal::max(c.g, c.b));
    }

    inline float min3(float3 c) {
        return metal::min(c.r, metal::min(c.g, c.b));
    }

    // Color at luminance 1, stored as (r, b): green follows from the luminance weights.
    inline float3 chroma(float2 rb) {
        return float3(rb.x, (1.0 - 0.2126 * rb.x - 0.0722 * rb.y) / 0.7152, rb.y);
    }

    // Each channel's share of its clip level; 0 for a channel with no plateau.
    inline float3 share(float3 c, float3 clip) {
        return metal::select(float3(0.0), c / metal::max(clip, 1e-6), clip > 0.0);
    }

    inline float3 flags(float code) {
        float r = metal::fmod(code, 2.0);
        float g = metal::fmod(metal::floor(code / 2.0), 2.0);
        float b = metal::floor(code / 4.0);
        return float3(r, g, b);
    }

    // 1 for a color within rounding of the clip white's: the decoder writes a pixel with any clipped
    // channel exactly that color. Natural colors, even near-white skies, are a percent or more away.
    inline float whitened(float3 own, float3 white) {
        float3 d = own - white;
        return 1.0 - metal::smoothstep(0.003, 0.02, metal::sqrt(metal::dot(d, d)));
    }

    // A pixel centre clamped inside `bounds` (x, y, width, height), so samplers need no clamped copy.
    inline float2 inside(float2 p, float4 bounds) {
        return metal::clamp(p, bounds.xy + 0.5, bounds.xy + bounds.zw - 0.5);
    }

    // Fully clipped: every channel with a plateau is at it, and all three have one.
    inline float fully(float3 clipped, float3 clip) {
        return metal::all(clip > 0.0) ? min3(clipped) : 0.0;
    }
}

extern "C" {
namespace coreimage {

// Work copy: the mean of each factor×factor block. Alpha flags (1 r, 2 g, 4 b) the channels whose
// block is a single value, the signature of a clip plateau. `bounds` is the full-size extent.
float4 highlight_reconstruction_reduce(sampler image, float factor, float4 bounds, destination dest) {
    float2 corner = bounds.xy + (dest.coord() - 0.5) * factor;
    int n = int(factor);
    float3 sum = float3(0.0);
    float3 least = float3(1e30);
    float3 most = float3(-1e30);
    for (int j = 0; j < n; j++) {
        for (int i = 0; i < n; i++) {
            float3 c = image.sample(image.transform(highlight_reconstruction::inside(corner + float2(i, j) + 0.5, bounds))).rgb;
            sum += c;
            least = min(least, c);
            most = max(most, c);
        }
    }
    float3 flat = select(float3(0.0), float3(1.0), most - least <= highlight_reconstruction::flatTolerance * max(abs(most), 1e-3));
    return float4(sum / float(n * n), flat.r + 2.0 * flat.g + 4.0 * flat.b);
}

// Each channel's value where it and its eight neighbours are one flat plateau (rgb), and the brightest
// channel (alpha): what the maximum pyramid reads the clip levels from. A lone flat block, like a
// smooth unclipped sky can make, doesn't count. `bounds` is the work copy's extent.
float4 highlight_reconstruction_top_values(sampler work, float4 bounds, destination dest) {
    float2 p = dest.coord();
    float4 center = work.sample(work.transform(p));
    float3 strong = highlight_reconstruction::flags(center.a);
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float4 n = work.sample(work.transform(highlight_reconstruction::inside(p + float2(i, j), bounds)));
            float3 same = select(float3(0.0), float3(1.0),
                                 abs(n.rgb - center.rgb) <= highlight_reconstruction::flatTolerance * max(abs(center.rgb), 1e-3));
            strong *= highlight_reconstruction::flags(n.a) * same;
        }
    }
    return float4(center.rgb * strong, highlight_reconstruction::max3(center.rgb));
}

// Maximum over each 8×8 block.
float4 highlight_reconstruction_max8(sampler image, float4 bounds, destination dest) {
    float2 corner = bounds.xy + (dest.coord() - 0.5) * 8.0;
    float4 most = float4(-1e30);
    for (int j = 0; j < 8; j++) {
        for (int i = 0; i < 8; i++) {
            float2 p = highlight_reconstruction::inside(corner + float2(i, j) + 0.5, bounds);
            most = max(most, image.sample(image.transform(p)));
        }
    }
    return most;
}

// Clip level per channel (rgb): the brightest plateau value, if it sits near the top of the photo,
// else 0. Alpha is 1 only with a plateau, so a photo with nothing clipped comes back untouched.
float4 highlight_reconstruction_levels(sample_t top) {
    float3 level = top.rgb;
    float3 clip = select(float3(0.0), level, (level >= 0.8 * top.a) & (level > 1e-3));
    return float4(clip, any(clip > 0.0) ? 1.0 : 0.0);
}

// Push-pull seeds. Color: the chroma and log luminance of clearly unclipped pixels, weighted toward
// the brighter ones, which are likelier to continue into the clipped area. Premultiplied by weight.
float4 highlight_reconstruction_seed_color(sample_t work, sample_t levels) {
    float3 c = max(work.rgb, 0.0);
    float3 clip = levels.rgb;
    float top = highlight_reconstruction::max3(highlight_reconstruction::share(c, clip));
    float luminance = knobs::luma(c);
    float3 rgb = c / max(luminance, 1e-4);
    float valid = 1.0 - smoothstep(highlight_reconstruction::sourceStart, highlight_reconstruction::sourceEnd, top);
    if (all(clip > 0.0)) {
        // A bright pixel well away from the clip white still has its hue: a good source short of the clip,
        // and the only one when the clipped object's unclipped parts are bright too.
        float3 white = clip / knobs::luma(clip);
        float colored = smoothstep(0.08, 0.2, metal::length(rgb - white)) * (1.0 - smoothstep(0.95, 1.0, top));
        valid = max(valid, colored) * (1.0 - highlight_reconstruction::whitened(rgb, white));
    }
    float weight = luminance > 1e-4 ? valid * top * top * top * top : 0.0;
    float2 rb = clamp(float2(rgb.r, rgb.b), 0.0, 4.0);
    return float4(rb * weight, weight, metal::log2(max(luminance, 1e-4)) * weight);
}

// Push-pull seed for depth: how fully clipped each block is.
float4 highlight_reconstruction_seed_clip(sample_t work, sample_t levels) {
    float3 clip = levels.rgb;
    float3 clipped = smoothstep(highlight_reconstruction::clipStart, highlight_reconstruction::clipEnd,
                                highlight_reconstruction::share(work.rgb, clip));
    return float4(highlight_reconstruction::fully(clipped, clip), 0.0, 0.0, 1.0);
}

// 4× box reduction: four bilinear taps, each on the corner four source pixels share.
float4 highlight_reconstruction_down4(sampler image, float4 bounds, destination dest) {
    float2 corner = bounds.xy + (dest.coord() - 0.5) * 4.0;
    // Taps stay a pixel inside the edge, so a partial block averages edge pixels instead of clear ones.
    float2 low = bounds.xy + min(float2(1.0), 0.5 * bounds.zw);
    float2 high = bounds.xy + max(bounds.zw - 1.0, 0.5 * bounds.zw);
    float4 sum = image.sample(image.transform(clamp(corner + float2(1.0, 1.0), low, high)))
        + image.sample(image.transform(clamp(corner + float2(3.0, 1.0), low, high)))
        + image.sample(image.transform(clamp(corner + float2(1.0, 3.0), low, high)))
        + image.sample(image.transform(clamp(corner + float2(3.0, 3.0), low, high)));
    return 0.25 * sum;
}

// Pull step, coarse to fine: this level's unclipped color and luminance where it has some, else the
// coarser estimate. Depth counts the scales at which the pixel is inside a clipped area, each only
// where every finer one agrees, so it is 0 at the edge and climbs with the log of the distance in.
float4 highlight_reconstruction_pull(sample_t seed, sample_t clip, sample_t coarse, float depthWeight, float trust) {
    float weight = seed.b;
    float3 own = float3(seed.r, seed.g, seed.a) / max(weight, 1e-6);
    float confidence = trust * smoothstep(0.0, 0.003, weight);
    float3 estimate = mix(coarse.rgb, own, confidence);
    float depth = smoothstep(0.5, 1.0, clip.r) * (depthWeight + coarse.a);
    return float4(estimate, depth);
}

// What the coarsest level falls back on where nothing near is unclipped: the clip white, or neutral
// when only some channels have a clip level.
float4 highlight_reconstruction_fallback(sample_t levels) {
    float3 clip = levels.rgb;
    float3 rgb = all(clip > 0.0) ? clip / knobs::luma(clip) : float3(1.0);
    float luminance = knobs::luma(all(clip > 0.0) ? clip : float3(highlight_reconstruction::max3(clip)));
    return float4(rgb.r, rgb.b, metal::log2(max(luminance, 1e-4)) - 1.0, 0.0);
}

// fieldImage: surrounding chroma (rg), surrounding log2 luminance (b) and depth (a), upsampled.
// levelImage: the clip levels (rgb) and 1 in alpha when there is a plateau. Every mask is decided here
// from the full-size pixel, so the soft fields never move an edge.
float4 highlight_reconstruction_apply(sampler image, sampler fieldImage, sampler levelImage, float maxRise, float4 bounds,
                                      destination dest) {
    float2 p = dest.coord();
    float4 s = image.sample(image.transform(p));
    float4 levels = levelImage.sample(levelImage.transform(p));
    if (levels.a <= 0.0) return s;
    float3 clip = levels.rgb;
    float3 c = s.rgb;
    float3 q = highlight_reconstruction::share(c, clip);
    float top = highlight_reconstruction::max3(q);
    if (top < highlight_reconstruction::whitenedStart) return s;

    float4 fields = fieldImage.sample(fieldImage.transform(p));
    float3 clipped = smoothstep(highlight_reconstruction::clipStart, highlight_reconstruction::clipEnd, q);
    float full = highlight_reconstruction::fully(clipped, clip);
    float3 surround = highlight_reconstruction::chroma(fields.rg);

    // 1. A channel stuck at its clip level, one exact value across its neighbours, is refit from the
    // others with the surrounding color. A channel that only passes near the level is the decoder's
    // blend toward white, which step 2 undoes.
    float3 stuck = 1.0 - smoothstep(0.003, 0.012, abs(q - 1.0));
    for (int k = 0; k < 4; k++) {
        float2 offset = k == 0 ? float2(2.0, 0.0) : k == 1 ? float2(-2.0, 0.0) : k == 2 ? float2(0.0, 2.0) : float2(0.0, -2.0);
        float3 n = image.sample(image.transform(highlight_reconstruction::inside(p + offset, bounds))).rgb;
        stuck *= 1.0 - smoothstep(1e-4, 4e-4, abs(n - c) / max(c, 1e-3));
    }
    float3 open = 1.0 - stuck;
    float fit = dot(open, surround);
    float3 rebuilt = c;
    if (fit > 1e-3 && highlight_reconstruction::max3(stuck) > 0.0) {
        float3 target = surround * (dot(open, c) / fit);
        rebuilt = c + stuck * max(target - c, 0.0) * (1.0 - full);
    }

    float3 result = rebuilt;
    if (all(clip > 0.0)) {
        float luminance = max(knobs::luma(rebuilt), 1e-6);
        float3 own = rebuilt / luminance;
        float3 white = clip / knobs::luma(clip);
        // 2. Undo the decoder's pull toward the clip white, keeping luminance. A color off the line from
        // the surroundings to the clip white is the pixel's own, not a blend, and is left alone.
        float3 toward = white - surround;
        float span = dot(toward, toward);
        float pulled = span > 1e-5 ? saturate(dot(own - surround, toward) / span) : 0.0;
        float3 off = own - (surround + pulled * toward);
        float onLine = 1.0 - smoothstep(0.25, 0.6, metal::sqrt(dot(off, off) / max(span, 1e-5)));
        float restore = max(
            pulled * onLine * smoothstep(highlight_reconstruction::restoreStart, highlight_reconstruction::restoreEnd, top),
            highlight_reconstruction::whitened(own, white) * smoothstep(highlight_reconstruction::whitenedStart, highlight_reconstruction::whitenedEnd, top));
        // 3. A fully clipped pixel takes the surrounding color, fading to the clip white with depth, and
        // climbs toward the middle as far as the surroundings sit below the clip level.
        float depth = saturate(fields.a);
        float3 target = mix(surround, white, full * (0.5 + 0.5 * smoothstep(0.0, 1.0, depth)));
        float3 color = max(own + restore * (target - white), 0.0);
        float climb = clamp(metal::log2(knobs::luma(clip)) - fields.b, 0.0, maxRise);
        result = color * luminance * metal::exp2(climb * depth * full);
    }
    return float4(result, s.a);
}

}
}
