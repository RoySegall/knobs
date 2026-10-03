#include "PresenceKernels.h"

extern "C" {
namespace coreimage {

float4 presence_luminance(sample_t s) {
    float l = presence::perceptual_luma(presence::straight(s));
    return float4(l, l, l, 1.0);
}

}
}
