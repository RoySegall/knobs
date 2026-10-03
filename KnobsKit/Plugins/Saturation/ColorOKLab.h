// OKLab math and gamut handling shared by the color plugins (vibrance, saturation, color mixer, grading).
#pragma once

#include "KnobsKernels.h"

namespace color_oklab {
    // Signed cube root: extended sRGB carries negative channels for colors outside its gamut.
    inline float cbrt_signed(float x) {
        return metal::copysign(metal::pow(metal::max(metal::abs(x), 1e-20f), 1.0f / 3.0f), x);
    }

    inline float3 from_linear(float3 c) {
        float3 lms = float3(
            metal::dot(c, float3(0.4122214708, 0.5363325363, 0.0514459929)),
            metal::dot(c, float3(0.2119034982, 0.6806995451, 0.1073969566)),
            metal::dot(c, float3(0.0883024619, 0.2817188376, 0.6299787005)));
        lms = float3(cbrt_signed(lms.x), cbrt_signed(lms.y), cbrt_signed(lms.z));
        return float3(
            metal::dot(lms, float3(0.2104542553, 0.7936177850, -0.0040720468)),
            metal::dot(lms, float3(1.9779984951, -2.4285922050, 0.4505937099)),
            metal::dot(lms, float3(0.0259040371, 0.7827717662, -0.8086757660)));
    }

    inline float3 to_linear(float3 lab) {
        float3 lms = float3(
            metal::dot(lab, float3(1.0, 0.3963377774, 0.2158037573)),
            metal::dot(lab, float3(1.0, -0.1055613458, -0.0638541728)),
            metal::dot(lab, float3(1.0, -0.0894841775, -1.2914855480)));
        lms = lms * lms * lms;
        return float3(
            metal::dot(lms, float3(4.0767416621, -3.3077115913, 0.2309699292)),
            metal::dot(lms, float3(-1.2684380046, 2.6097574011, -0.3413193965)),
            metal::dot(lms, float3(-0.0041960863, -0.7034186147, 1.7076147010)));
    }

    // Lowest Display P3 channel of the OKLab color at lightness `l`, chroma `chroma` along `k` (hue in LMS terms).
    inline float lowest_p3(float l, float chroma, float3 k) {
        float3 lms = l + chroma * k;
        lms = lms * lms * lms;
        float r = metal::dot(lms, float3(3.1277691544, -2.2571359813, 0.1293668269));
        float g = metal::dot(lms, float3(-1.0910090417, 2.4133317519, -0.3223227102));
        float b = metal::dot(lms, float3(-0.0260108866, -0.5080413103, 1.5340520968));
        return metal::min(r, metal::min(g, b));
    }

    // OKLab chroma at which the ray from gray at lightness `l` along unit hue `dir` leaves Display P3,
    // the gamut export and the screen clip to. Bisection, then one secant step so the edge has no steps.
    inline float edge_chroma(float l, float2 dir) {
        if (l <= 1e-4) {
            return 0.0;
        }
        float3 k = float3(
            metal::dot(dir, float2(0.3963377774, 0.2158037573)),
            metal::dot(dir, float2(-0.1055613458, -0.0638541728)),
            metal::dot(dir, float2(-0.0894841775, -1.2914855480)));
        float low = 0.0;
        float high = 0.6 * metal::max(l, 1.0f);
        float lowValue = l * l * l;
        float highValue = lowest_p3(l, high, k);
        if (highValue >= 0.0) {
            return high;
        }
        for (int step = 0; step < 8; step++) {
            float middle = 0.5 * (low + high);
            float value = lowest_p3(l, middle, k);
            bool inside = value >= 0.0;
            low = inside ? middle : low;
            lowValue = inside ? value : lowValue;
            high = inside ? high : middle;
            highValue = inside ? highValue : value;
        }
        return low + (high - low) * lowValue / (lowValue - highValue);
    }

    // Chroma as a share of the gamut edge: 0 gray, 1 on the edge.
    inline float edge_ratio(float3 lab, float2 dir) {
        float edge = edge_chroma(lab.x, dir);
        return edge > 1e-5 ? metal::length(lab.yz) / edge : 0.0;
    }

    // Share of the gamut edge below which chroma is never touched.
    constant float knee_ratio = 0.8f;

    // Rolls a ratio an edit pushed past the knee toward the edge instead of letting channels clip.
    // Chroma the original already had is kept, so a tiny slider move never jumps; one on or past the edge never grows.
    inline float limit_ratio(float edited, float original) {
        float knee = metal::max(knee_ratio, original);
        if (edited <= knee) {
            return edited;
        }
        float room = metal::max(1.0f, original) - knee;
        if (room <= 1e-5) {
            return knee;
        }
        float d = (edited - knee) / room;
        return knee + room * d / (1.0f + d);
    }

    inline float2 hue_direction(float3 lab) {
        float chroma = metal::length(lab.yz);
        return chroma > 1e-7 ? lab.yz / chroma : float2(1.0, 0.0);
    }

    // Pulls an edited OKLab color back inside the gamut at constant lightness and hue.
    inline float3 fit_gamut(float3 original, float3 edited) {
        float2 dir = hue_direction(edited);
        float edge = edge_chroma(edited.x, dir);
        float chroma = metal::length(edited.yz);
        if (edge <= 1e-5 || chroma <= 1e-7) {
            return edited;
        }
        float ratio = chroma / edge;
        if (ratio <= knee_ratio) {
            return edited;
        }
        float fitted = limit_ratio(ratio, edge_ratio(original, hue_direction(original)));
        return float3(edited.x, edited.yz * (fitted / ratio));
    }

    // Scales chroma at constant lightness and hue; a boost rolls off at the gamut edge.
    inline float3 scale_chroma(float3 lab, float gain) {
        float chroma = metal::length(lab.yz);
        if (chroma <= 1e-7) {
            return lab;
        }
        float2 dir = lab.yz / chroma;
        float target = chroma * gain;
        if (gain > 1.0) {
            float edge = edge_chroma(lab.x, dir);
            target = edge > 1e-5 ? limit_ratio(target / edge, chroma / edge) * edge : target;
        }
        return float3(lab.x, dir * target);
    }

    // Scales a linear color to luminance `y`, which keeps its OKLab hue and its share of the gamut edge.
    inline float3 match_luma(float3 c, float y) {
        float current = knobs::luma(c);
        return (y > 0.0 && current > 1e-6) ? c * (y / current) : c;
    }

    // Saturation of the display-encoded color, 0 gray to 1 on the sRGB edge.
    inline float display_saturation(float3 c) {
        float high = metal::max(c.r, metal::max(c.g, c.b));
        float low = metal::min(c.r, metal::min(c.g, c.b));
        if (high <= 1e-5) {
            return 0.0;
        }
        float encoded = knobs::to_gamma(high);
        return metal::saturate((encoded - knobs::to_gamma(low)) / encoded);
    }

    // Core Image hands kernels premultiplied pixels; color math needs straight ones.
    inline float3 unpremultiply(float4 s) {
        return s.a > 1e-5 ? s.rgb / s.a : s.rgb;
    }
}
