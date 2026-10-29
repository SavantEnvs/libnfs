#define LLVMFuzzerTestOneInput upstream_roundtrip_one_input
#include "../../fuzzing/libnfs_zdr_roundtrip_fuzzer.c"
#undef LLVMFuzzerTestOneInput
#include "aligned_input.h"
MAYHEM_ALIGNED_WRAPPER(upstream_roundtrip_one_input)
