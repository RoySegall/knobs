#include "KnobsKernels.h"

namespace noise_reduction {
    // Luma plus blue and red differences, all on sRGB-encoded values: an opponent space where
    // noise is roughly even from shadows to highlights.
    inline float3 to_ycc(float3 linear) {
        float3 g = knobs::to_gamma(linear);
        float y = knobs::luma(g);
        return float3(y, g.b - y, g.r - y);
    }

    inline float3 to_rgb(float y, float2 chroma) {
        float b = chroma.x + y;
        float r = chroma.y + y;
        float g = (y - 0.2126 * r - 0.0722 * b) / 0.7152;
        return knobs::to_linear(float3(r, g, b));
    }

    // Core Image may evaluate a general kernel outside its extent once a later stage moves the image,
    // and clamped inputs would smear there. Kernels return clear outside `bounds` (min xy, max xy).
    inline bool outside(float2 p, float4 bounds) {
        return p.x < bounds.x || p.y < bounds.y || p.x > bounds.z || p.y > bounds.w;
    }

    // 3x3 binomial mean of luma and chroma. Cuts per-pixel noise variance about sevenfold while barely
    // moving edges, so filters compare their taps against this rather than against a noisy center.
    inline float3 guide(coreimage::sampler ycc, float2 p) {
        float3 sum = 0.0;
        for (int j = -1; j <= 1; j++) {
            for (int i = -1; i <= 1; i++) {
                float w = (i == 0 ? 2.0 : 1.0) * (j == 0 ? 2.0 : 1.0);
                sum += w * ycc.sample(ycc.transform(p + float2(i, j))).xyz;
            }
        }
        return sum / 16.0;
    }
}

extern "C" {
namespace coreimage {

float4 noise_reduction_ycc(sample_t s) {
    return float4(noise_reduction::to_ycc(s.rgb), s.a);
}

float4 noise_reduction_rgb(sample_t ycc) {
    return float4(noise_reduction::to_rgb(ycc.x, ycc.yz), ycc.w);
}

// Bilateral filter on luma. Taps are weighed against a 3x3 mean of the center rather than the noisy
// center itself, so a noise spike cannot pick only the neighbors that share its spike.
float4 noise_reduction_luma(sampler ycc, float4 bounds, float step, float taps, float spatial, float range, destination dest) {
    float2 p = dest.coord();
    if (noise_reduction::outside(p, bounds)) { return 0.0; }
    float4 center = ycc.sample(ycc.transform(p));
    float guide = noise_reduction::guide(ycc, p).x;

    float spatialK = -0.5 / (spatial * spatial);
    float rangeK = -0.5 / (range * range);
    float sum = center.x;
    float total = 1.0;
    int n = int(taps);
    for (int j = -n; j <= n; j++) {
        for (int i = -n; i <= n; i++) {
            if (i == 0 && j == 0) { continue; }
            float2 offset = float2(i, j) * step;
            float v = ycc.sample(ycc.transform(p + offset)).x;
            float d = v - guide;
            float w = metal::exp(metal::dot(offset, offset) * spatialK + d * d * rangeK);
            sum += w * v;
            total += w;
        }
    }
    return float4(sum / total, center.yzw);
}

// Box average over factor x factor pixels, origin at zero. Each bilinear tap sits on a pixel corner and
// averages a 2x2 block, so factor / 2 taps per axis cover the block exactly.
float4 noise_reduction_downsample(sampler ycc, float factor, destination dest) {
    float2 q = dest.coord() * factor;
    int n = int(factor * 0.5);
    float4 sum = 0.0;
    for (int j = 0; j < n; j++) {
        for (int i = 0; i < n; i++) {
            float2 o = float2(2 * i - n + 1, 2 * j - n + 1);
            sum += ycc.sample(ycc.transform(q + o));
        }
    }
    return sum / float(n * n);
}

// Cross-bilateral on chroma, run on the box-downsampled image. Taps are weighed by how close their
// color and luma sit to a 3x3 mean of the center, so smoothing stops at color edges as well as luma edges.
// range: chroma and luma thresholds.
float4 noise_reduction_chroma(sampler small, float step, float spatial, float2 range, destination dest) {
    float2 p = dest.coord();
    float4 center = small.sample(small.transform(p));
    float3 guide = noise_reduction::guide(small, p);

    float spatialK = -0.5 / (spatial * spatial);
    float chromaK = -0.5 / (range.x * range.x);
    float lumaK = -0.5 / (range.y * range.y);
    float2 sum = center.yz;
    float total = 1.0;
    for (int j = -3; j <= 3; j++) {
        for (int i = -3; i <= 3; i++) {
            if (i == 0 && j == 0) { continue; }
            float2 offset = float2(i, j) * step;
            float3 v = small.sample(small.transform(p + offset)).xyz;
            float2 dc = v.yz - guide.yz;
            float dy = v.x - guide.x;
            float w = metal::exp(metal::dot(offset, offset) * spatialK + metal::dot(dc, dc) * chromaK + dy * dy * lumaK);
            sum += w * v.yz;
            total += w;
        }
    }
    return float4(center.x, sum / total, center.w);
}

// Joint bilateral upsampling: the four nearest low-res pixels count by bilinear weight and by how well they
// match this pixel's 3x3 luma and color, so color edges stay sharp. `keep` lets an unlike pixel keep its color.
// grid: low-res origin (xy) and factor (z). range: chroma and luma thresholds.
float4 noise_reduction_merge(sampler ycc, sampler filtered, float4 bounds, float3 grid, float2 range,
                             float keep, float strength, destination dest) {
    float2 p = dest.coord();
    if (noise_reduction::outside(p, bounds)) { return 0.0; }
    float4 c = ycc.sample(ycc.transform(p));
    float3 guide = noise_reduction::guide(ycc, p);

    float2 q = (p - grid.xy) / grid.z - 0.5;
    float2 base = metal::floor(q);
    float2 f = q - base;
    float chromaK = -0.5 / (range.x * range.x);
    float lumaK = -0.5 / (range.y * range.y);
    float2 sum = keep * guide.yz;
    float total = keep;
    for (int j = 0; j <= 1; j++) {
        for (int i = 0; i <= 1; i++) {
            float2 texel = grid.xy + (base + float2(i, j) + 0.5) * grid.z;
            float3 v = filtered.sample(filtered.transform(texel)).xyz;
            float2 dc = v.yz - guide.yz;
            float dy = v.x - guide.x;
            float bilinear = (i == 0 ? 1.0 - f.x : f.x) * (j == 0 ? 1.0 - f.y : f.y);
            float w = bilinear * metal::exp(metal::dot(dc, dc) * chromaK + dy * dy * lumaK) + 1e-6;
            sum += w * v.yz;
            total += w;
        }
    }
    float2 chroma = metal::mix(c.yz, sum / total, strength);
    return float4(noise_reduction::to_rgb(c.x, chroma), c.w);
}

}
}
