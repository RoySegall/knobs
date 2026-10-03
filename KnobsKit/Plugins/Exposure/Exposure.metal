#include "KnobsKernels.h"

extern "C" {
namespace coreimage {

float4 exposure_apply(sample_t s, float stops) {
    return float4(s.rgb * exp2(stops), s.a);
}

}
}
