#include "KnobsKernels.h"

extern "C" {
namespace coreimage {

// Maps scene values into display range without per-channel clipping. Above the knee a rational
// shoulder bends the brightest and darkest channel (keeping the middle one between them, so hue
// holds) and lands `white` on 1. At white 1 it is the identity below 1.
// Pixels outside `bounds` come back clear: Core Image may evaluate an upstream neighbour-sampling
// kernel past its extent once the result is moved, which smears edge pixels around the photo.
float4 display_rolloff(sample_t s, float knee, float white, float4 bounds, destination dest) {
    float2 p = dest.coord();
    if (p.x < bounds.x || p.y < bounds.y || p.x > bounds.x + bounds.z || p.y > bounds.y + bounds.w) {
        return float4(0.0);
    }
    float high = metal::max(s.r, metal::max(s.g, s.b));
    if (high <= knee) return s;
    float low = metal::min(s.r, metal::min(s.g, s.b));
    float span = high - low;
    float3 t = span > 1e-6 ? (s.rgb - low) / span : float3(0.0);
    float scale = (white - 1.0) / ((1.0 - knee) * (white - knee));
    float newHigh = knee + (high - knee) / (1.0 + (high - knee) * scale);
    float newLow = low <= knee ? low : knee + (low - knee) / (1.0 + (low - knee) * scale);
    float3 c = newLow + (newHigh - newLow) * t;
    // Anything still past white goes toward white instead of clipping one channel.
    float over = metal::max(c.r, metal::max(c.g, c.b));
    if (over > 1.0) {
        c = metal::mix(c / over, float3(1.0), metal::saturate((over - 1.0) * 0.5));
    }
    return float4(c, s.a);
}

}
}
