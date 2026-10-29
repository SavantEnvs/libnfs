#define LLVMFuzzerTestOneInput upstream_reply_one_input
#include "../../fuzzing/libnfs_reply_fuzzer.c"
#undef LLVMFuzzerTestOneInput
#include "aligned_input.h"
MAYHEM_ALIGNED_WRAPPER(upstream_reply_one_input)
