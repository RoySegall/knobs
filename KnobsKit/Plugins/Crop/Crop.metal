#include "KnobsKernels.h"

namespace crop {
    // Catmull-Rom weights for the four taps around a sample that sits t of the way from tap 1 to tap 2.
    inline float4 catmull_rom(float t) {
        float t2 = t * t;
        float t3 = t2 * t;
        return float4(
            -0.5 * t3 + t2 - 0.5 * t,
            1.5 * t3 - 2.5 * t2 + 1.0,
            -1.5 * t3 + 2.0 * t2 + 0.5 * t,
            0.5 * t3 - 0.5 * t2
        );
    }
}

extern "C" {
namespace coreimage {

// Catmull-Rom through an affine output-to-source map; merging the middle taps into bilinear fetches
// makes 16 taps cost 9. Clamping to the fetched range stops halos and negative HDR values.
// `masked` fades pixels off the source rect `bounds` to clear over one antialiased pixel.
float4 crop_resample(sampler src, float3 row0, float3 row1, float4 bounds, float masked, float2 size, destination dest) {
    // Core Image may run a general kernel past its extent when compositing it; stay clear there.
    float2 c = dest.coord();
    if (c.x < 0.0 || c.y < 0.0 || c.x > size.x || c.y > size.y) {
        return float4(0.0);
    }
    float3 d = float3(c, 1.0);
    float2 p = float2(dot(row0, d), dot(row1, d));
    float2 base = floor(p - 0.5) + 0.5;
    float2 f = p - base;
    float4 wx = crop::catmull_rom(f.x);
    float4 wy = crop::catmull_rom(f.y);
    float3 weightX = float3(wx.x, wx.y + wx.z, wx.w);
    float3 weightY = float3(wy.x, wy.y + wy.z, wy.w);
    float3 offsetX = float3(-1.0, wx.z / weightX.y, 2.0);
    float3 offsetY = float3(-1.0, wy.z / weightY.y, 2.0);

    // Sampler space is affine in working space, so three transforms place every fetch.
    float2 origin = src.transform(base);
    float2 stepX = src.transform(base + float2(1.0, 0.0)) - origin;
    float2 stepY = src.transform(base + float2(0.0, 1.0)) - origin;

    float4 sum = float4(0.0);
    float4 low = float4(1e30);
    float4 high = float4(-1e30);
    for (int j = 0; j < 3; j++) {
        float4 row = float4(0.0);
        for (int i = 0; i < 3; i++) {
            float4 tap = src.sample(origin + offsetX[i] * stepX + offsetY[j] * stepY);
            row += tap * weightX[i];
            low = min(low, tap);
            high = max(high, tap);
        }
        sum += row * weightY[j];
    }
    sum = clamp(sum, low, high);

    if (masked > 0.5) {
        float2 inside = min(p - bounds.xy, bounds.xy + bounds.zw - p);
        sum *= saturate(inside.x + 0.5) * saturate(inside.y + 0.5);
    }
    return sum;
}

}
}
