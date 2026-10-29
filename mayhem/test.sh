#!/usr/bin/env bash
#
# mayhem/test.sh — RUN libnfs's own server-less unit tests (built by mayhem/build.sh) and assert their output.
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

T="$SRC/build/test/tests"
[ -x "$T/prog_zdr_alignment" ] || { echo "missing $T/prog_zdr_alignment: mayhem/build.sh did not build the tests" >&2; exit 2; }
# assert()-based tests (prog_nfs4_errno) cannot fail when built with NDEBUG: refuse such a build.
if grep -rqs -e '-DNDEBUG' "$SRC/build/test" --include=flags.make; then
  echo "build/test was compiled with -DNDEBUG: assert()-based tests would pass vacuously" >&2; exit 2
fi
cd "$T"

passed=0; failed=0

# ok <name> <condition-exit-status>
ok() { if [ "$2" -eq 0 ]; then passed=$((passed+1)); echo "ok   $1"; else failed=$((failed+1)); echo "FAIL $1"; fi; }

# unit <prog> <expected PASS lines...>: the program must exit 0 AND print each expected line verbatim.
unit() {
  local prog="$1"; shift
  local out rc=0 miss=0 line
  out=$(timeout 120 "./$prog" 2>&1) || rc=$?
  for line in "$@"; do printf '%s\n' "$out" | grep -qxF "$line" || miss=1; done
  [ "$rc" -eq 0 ] && [ "$miss" -eq 0 ]; ok "$prog" $?
}

unit prog_zdr_alignment "PASS: all ZDR alignment regression cases" \
  "PASS: aligned allocations, boundaries, contents and destruction"
unit prog_zdr_bytes_zero "PASS: all ZDR zero-length byte regression cases" \
  "PASS: truncated headers, payloads and padding are rejected"
unit prog_zdr_maxsize "PASS: all ZDR maxsize regression cases" \
  "PASS: array fields honour maxsize"
unit prog_nfs40_renew "PASS: NFSv4.0 lease renewal"
unit prog_nfs4_errno "PASS: stale filehandle is distinguishable from I/O and pathname errors"
unit prog_nfs4_delay "PASS: all NFSv4.2 DELAY regression cases"
unit prog_reconnect \
  "PASS: disabled and finite reconnect policies fail exactly once at the configured limit" \
  "PASS: cancel/destroy, permanent error, and asynchronous connection failure"
unit prog_service_error "PASS: direct, synchronous and background service diagnostics"

# nfs:// URL parser: known URL -> known server/port/path/file (same cases as tests/test_8010_parse_url_full.sh).
parse_ok() { ./prog_parse_url_full "$@" >/dev/null 2>&1; ok "parse_url $1" $?; }
parse_err() {
  local url="$1" msg="$2" out
  out=$(./prog_parse_url_full "$url" x 0 / / 2>&1); local rc=$?
  [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "$msg"; ok "parse_url rejects $url ($msg)" $?
}
# tests/test_8010_valgrind_parse_url_full.sh is not run: it needs valgrind+libtool, and these URL cases already run above.
parse_ok "nfs://user@127.0.0.1/dir/file" 127.0.0.1 0 /dir /file
parse_ok "nfs://user@127.0.0.1:8000/dir/file" 127.0.0.1 8000 /dir /file
# a mismatching expectation must be reported as a failure by the program itself
out=$(./prog_parse_url_full "nfs://user@127.0.0.1:8000/dir/file" 127.0.0.1 8001 /dir /file 2>&1); rc=$?
[ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "Unexpected port: 8000 (expected: 8001)"; ok "parse_url port mismatch is detected" $?
parse_err "nfs://user@127.0.0.1:-1/dir/file" "Invalid port number"
parse_err "nfs://user@127.0.0.1:65536/dir/file" "Invalid port number"
parse_err "nfs://user@127.0.0.1:invalid/dir/file" "Invalid port number"

emit_ctrf "libnfs-unit" "$passed" "$failed" 0
