#include "KnobsKernels.h"

// Window means are stored in half floats, so E[I²] − E[I]² loses precision away from zero. Guides and
// inputs are shifted by `center` first (the filter is invariant to that), and epsilon grows with the
// shifted magnitude so rounding can never leave Σ + εU near singular.

extern "C" {
namespace coreimage {

// Gray guide: (I, I²) for the window means.
float4 guided_gray_moments(sample_t guide, float center) {
    float i = guide.r - center;
    return float4(i, i * i, 0.0, 1.0);
}

// Self-guided gray filter: a in r, b in g, for the unshifted guide.
float4 guided_gray_coefficients(sample_t means, float epsilon, float center) {
    float variance = max(means.g - means.r * means.r, 0.0);
    float a = variance / (variance + epsilon);
    float b = means.r * (1.0 - a) + center * (1.0 - a);
    return float4(a, b, 0.0, 1.0);
}

// Color guide I and input p (in r): thirteen window means packed into four images. Alpha carries data;
// box means and bilinear sampling treat all four channels alike.
float4 guided_color_moments_1(sample_t guide, sample_t input, float3 center) {
    return float4(guide.rgb - center, input.r - 0.5);
}

float4 guided_color_moments_2(sample_t guide, sample_t input, float3 center) {
    float3 i = guide.rgb - center;
    return float4(i * (input.r - 0.5), i.r * i.r);
}

float4 guided_color_moments_3(sample_t guide, float3 center) {
    float3 i = guide.rgb - center;
    return float4(i.r * i.g, i.r * i.b, i.g * i.g, i.g * i.b);
}

float4 guided_color_moments_4(sample_t guide, float3 center) {
    float b = guide.b - center.b;
    return float4(b * b, 0.0, 0.0, 1.0);
}

// a = (Σ + εU)⁻¹ · cov(I, p) by Cramer's rule on the symmetric 3×3 covariance, in rgb; b in alpha,
// for the unshifted guide and input. The clamp only guards against a near-singular Σ left by rounding.
float4 guided_color_coefficients(sample_t m1, sample_t m2, sample_t m3, sample_t m4, float epsilon, float3 center) {
    float3 mean = m1.rgb;
    float meanP = m1.a;
    epsilon += 4e-3 * (m2.a + m3.b + m4.r) / 3.0;
    float3 covariance = m2.rgb - mean * meanP;
    float3 c0 = float3(max(m2.a - mean.r * mean.r, 0.0) + epsilon, m3.r - mean.r * mean.g, m3.g - mean.r * mean.b);
    float3 c1 = float3(c0.y, max(m3.b - mean.g * mean.g, 0.0) + epsilon, m3.a - mean.g * mean.b);
    float3 c2 = float3(c0.z, c1.z, max(m4.r - mean.b * mean.b, 0.0) + epsilon);
    float3 x0 = cross(c1, c2);
    float3 x1 = cross(c2, c0);
    float3 x2 = cross(c0, c1);
    float determinant = max(dot(c0, x0), epsilon * epsilon * epsilon);
    float3 a = clamp(float3(dot(x0, covariance), dot(x1, covariance), dot(x2, covariance)) / determinant, -10.0, 10.0);
    float b = meanP - dot(a, mean) + 0.5 - dot(a, center);
    return float4(a, b);
}

}
}
