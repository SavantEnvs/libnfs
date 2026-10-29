# timeo= signed integer overflow in the nfs:// URL parser

`lib/libnfs.c` (`nfs_parse_url`, option `timeo`): `atoi(val) * 100` overflows `int` for
`timeo` >= 21474837 (UBSan: `signed integer overflow: 777777777 * 100`). Reproducer:
`timeo-int-overflow.url` (feed to `/mayhem/libnfs_url_fuzzer-standalone`). Impact: undefined behavior
reachable from any application-supplied URL; the wrapped value may then bypass the "timeo cannot be
less than 100" check. Fix: parse with `strtol` and range-check before multiplying.
Kept out of `testsuite/` because seeds are replayed on every run.
