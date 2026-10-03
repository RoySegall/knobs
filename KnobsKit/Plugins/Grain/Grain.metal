#include "KnobsKernels.h"

namespace grain {
    inline uint hash(uint x) {
        x ^= x >> 16;
        x *= 0x7feb352du;
        x ^= x >> 15;
        x *= 0x846ca68bu;
        x ^= x >> 16;
        return x;
    }

    // One soft dot of a hashed position and signed strength. Strength is the sum of two uniforms, so most
    // dots are faint and few are strong, like the size spread of real grain.
    inline float dot(float2 p, int2 cell, uint h, float radius2) {
        float2 center = float2(cell) + float2(h & 0x1ffu, (h >> 9) & 0x1ffu) * (1.0 / 511.0);
        float strength = float(((h >> 18) & 0x7fu) + (h >> 25)) * (1.0 / 127.0) - 1.0;
        float2 d = p - center;
        float k = metal::max(1.0 - metal::dot(d, d) / radius2, 0.0);
        return strength * k * k;
    }

    // Film-like grain: `count` soft dots per lattice cell, scattered by hash. Jittered dots leave no grid to see,
    // and random strengths keep white noise's low frequencies, so the grain averages down like film grain.
    // Unit variance: count * strength variance (1/6) * the bump's squared integral (pi r^2 / 5) = 1 / norm^2.
    template <int count>
    inline float noise(float2 p, uint seed, float radius, float norm) {
        float2 cell = metal::floor(p);
        float2 f = p - cell;
        int2 c = int2(cell);
        // Only neighbor cells within the dot radius can reach p; most pixels need four to six of the nine.
        int2 from = int2(f.x < radius ? -1 : 0, f.y < radius ? -1 : 0);
        int2 to = int2(f.x > 1.0 - radius ? 1 : 0, f.y > 1.0 - radius ? 1 : 0);
        float radius2 = radius * radius;
        float sum = 0.0;
        for (int j = from.y; j <= to.y; j++) {
            uint row = hash(uint(c.y + j) ^ seed);
            for (int i = from.x; i <= to.x; i++) {
                uint h = hash(uint(c.x + i) ^ row);
                for (int n = 0; n < count; n++) {
                    sum += dot(p, c + int2(i, j), h, radius2);
                    h = h * 747796405u + 2891336453u;
                    h ^= h >> 16;
                }
            }
        }
        return sum * norm;
    }
}

extern "C" {
namespace coreimage {

// Three octaves: fine grain, coarser grain and a slow clumping envelope that roughness mixes in.
// lattice: lattice cells per working pixel for each octave. strength: each octave's level after pixel averaging.
float4 grain_apply(sample_t s, float3 lattice, float3 strength, float amplitude, float roughness, destination dest) {
    float2 p = dest.coord();
    float n = grain::noise<3>(p * lattice.x, 0x2f6b1c3du, 0.65, 2.745) * strength.x;
    if (roughness > 0.0) {
        float coarse = grain::noise<3>(p * lattice.y, 0x9e3779b9u, 0.65, 2.745) * strength.y;
        float clump = grain::noise<1>(p * lattice.z, 0x5bd1e995u, 1.0, 3.090) * strength.z;
        n = (n + 0.7 * roughness * coarse) / metal::sqrt(1.0 + 0.49 * roughness * roughness);
        n *= metal::max(1.0 + 0.35 * roughness * clump, 0.25);
    }

    // Film shows grain most in the midtones and least in deep shadows and clean highlights.
    float3 g = knobs::to_gamma(s.rgb);
    float y = metal::saturate(knobs::luma(g));
    float weight = metal::pow(4.0 * y * (1.0 - y), 0.6);
    g += amplitude * weight * n;
    return float4(knobs::to_linear(g), s.a);
}

}
}
