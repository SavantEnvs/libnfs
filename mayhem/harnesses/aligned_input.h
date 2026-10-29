/* Upstream's ZDR harnesses decode in place from `data + 1`, which is misaligned for 3 of 4 inputs;
 * libnfs's real receive buffers are malloc'd and 4-byte aligned, and libnfs_zdr_u_int loads uint32_t
 * straight from the buffer. Hand the upstream harness a copy placed so that data + 1 is aligned,
 * with the allocation ending exactly at the payload end (ASan still catches overreads). */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define MAYHEM_ALIGNED_WRAPPER(upstream)                                          \
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)                      \
{                                                                                 \
	uint8_t *buf = (uint8_t *)malloc(size + 3);                               \
	int rc;                                                                   \
	if (buf == NULL)                                                          \
		return 0;                                                         \
	if (size)                                                                 \
		memcpy(buf + 3, data, size);                                      \
	rc = upstream(buf + 3, size);                                             \
	free(buf);                                                                \
	return rc;                                                                \
}
