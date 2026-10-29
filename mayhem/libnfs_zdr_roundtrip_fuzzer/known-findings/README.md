# `assert((zdrs->pos & 0x03) == 0)` reachable from a crafted reply

`libnfs_zdr_u_int` (`lib/libnfs-zdr.c:174`) asserts that the ZDR position is 4-byte aligned. A short
payload whose opaque/string field ends inside its XDR padding leaves the position unaligned, and the next
`u_int` decode (e.g. the array count in `libnfs_zdr_array`) aborts. Reproducer:
`zdr-pos-misaligned-assert.bin` (feed to the matching `*-standalone` binary). Impact: a server reply can
abort an assert-enabled client (DoS); with `NDEBUG` the misaligned read proceeds instead. Kept out of
`testsuite/` because seeds are replayed on every run.
