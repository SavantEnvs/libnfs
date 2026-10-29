#!/usr/bin/env bash
#
# mayhem/build.sh — build libnfs (sanitized) + its three libFuzzer harnesses + the clean test build.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# libnfs invokes every ZDR (de)coder through the variadic `zdrproc_t` pointer type, so UBSan's
# -fsanitize=function flags the library's own dispatch on EVERY input (and aborts under halting).
# Only that one check is relaxed; ASan and all other UBSan checks stay on and halting.
RELAX_FLAGS="-fno-sanitize=function"

# Fuzz stack lives under build/ (gitignored upstream, so `git clean -ffdX` removes it). The harnesses
# are in-tree upstream (fuzzing/); the sanitized static libnfs is instrumented with SanCov via
# -fsanitize=fuzzer-no-link so Mayhem sees coverage inside the library, not only the harness TU.
FUZZ_BUILD="$SRC/build/fuzz"
rm -rf "$FUZZ_BUILD"
cmake -S "$SRC" -B "$FUZZ_BUILD" -G "Unix Makefiles" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_BUILD_TYPE= -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_C_FLAGS="-O1 $SANITIZER_FLAGS $RELAX_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
cmake --build "$FUZZ_BUILD" -j"$MAYHEM_JOBS" --target nfs

INCS=(-I"$SRC/include" -I"$SRC/include/nfsc" -I"$SRC/nfs" -I"$SRC/mount" -I"$SRC/nlm" -I"$SRC/rquota"
      -I"$SRC/portmap" -I"$SRC/nfs4" -I"$FUZZ_BUILD" -I"$FUZZ_BUILD/include" -I"$SRC/fuzzing")
LIBNFS="$FUZZ_BUILD/lib/libnfs.a"
[ -f "$LIBNFS" ] || LIBNFS=$(find "$FUZZ_BUILD" -name libnfs.a | head -1)

# Leak sanitizer hook (SPEC §6.2 item 15).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZ_BUILD/lsan_off.o"

# reply + roundtrip go through mayhem/harnesses/ wrappers (aligned input copy); url is upstream's file.
for h in libnfs_reply_fuzzer libnfs_url_fuzzer libnfs_zdr_roundtrip_fuzzer; do
  src="$SRC/mayhem/harnesses/$h.c"; [ -f "$src" ] || src="$SRC/fuzzing/$h.c"
  $CC -std=gnu11 -O1 $SANITIZER_FLAGS $RELAX_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "${INCS[@]}" \
      "$src" "$LIBNFS" "$FUZZ_BUILD/lsan_off.o" -lpthread -o "/mayhem/$h"
  $CC -std=gnu11 -O1 $SANITIZER_FLAGS $RELAX_FLAGS $DEBUG_FLAGS "${INCS[@]}" "$STANDALONE_FUZZ_MAIN" \
      "$src" "$LIBNFS" "$FUZZ_BUILD/lsan_off.o" -lpthread -o "/mayhem/$h-standalone"
done

# Test suite: separate build with the project's NORMAL flags (no sanitizers, no -gdwarf-3, no SanCov).
# RelWithDebInfo's default adds -DNDEBUG, which compiles out the assert() checks that tests/prog_nfs4_errno.c
# (and the library) rely on, so its flags are overridden to "-O2 -g": the asserts stay live, as in upstream CI.
TEST_BUILD="$SRC/build/test"
rm -rf "$TEST_BUILD"
env -u CFLAGS -u LDFLAGS cmake -S "$SRC" -B "$TEST_BUILD" -G "Unix Makefiles" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_C_FLAGS_RELWITHDEBINFO="-O2 -g" -DBUILD_SHARED_LIBS=OFF \
  -DENABLE_TESTS=ON -DCMAKE_C_FLAGS="$COVERAGE_FLAGS"
cmake --build "$TEST_BUILD" -j"$MAYHEM_JOBS"
