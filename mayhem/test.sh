#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
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

# libbson's own known-answer suite (BSON/JSON/UTF-8/validation/corpus round-trips with asserted values)
# lives in test-libmongoc; the `/bson/*` and `/bson_corpus/*` groups need no MongoDB server.
RUNNER="$SRC/cmake-build/tests/src/libmongoc/test-libmongoc"
[ -x "$RUNNER" ] || { echo "missing $RUNNER — mayhem/build.sh must build it" >&2; emit_ctrf "test-libmongoc" 0 1 0; exit 1; }

passed=0 failed=0 skipped=0
for group in '/bson/*' '/bson_corpus/*'; do
  out="$("$RUNNER" --no-fork -l "$group" 2>&1)"; rc=$?
  p=$(grep -c '"status": "pass"' <<<"$out"); f=$(grep -c '"status": "fail"' <<<"$out"); s=$(grep -c '"status": "skip"' <<<"$out")
  [ "$rc" -eq 0 ] || { echo "$out" | tail -20 >&2; [ "$f" -gt 0 ] || f=1; }   # a crash/abort mid-group counts as a failure
  passed=$((passed+p)); failed=$((failed+f)); skipped=$((skipped+s))
done
# Guard against a neutered/empty runner: the suite must actually have executed its known-answer tests.
if [ "$passed" -lt 400 ]; then echo "only $passed tests passed (expected >= 400)" >&2; failed=$((failed+1)); fi

emit_ctrf "test-libmongoc" "$passed" "$failed" "$skipped"
