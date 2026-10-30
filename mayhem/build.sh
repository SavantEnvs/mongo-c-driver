#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
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

# 1) Build libbson (the fuzzed library) with the sanitizers + SanCov instrumentation + DWARF 3.
#    `-fsanitize=fuzzer-no-link` is what gives the LIBRARY coverage edges (the engine only covers the
#    harness TU); it goes on unconditionally, even when SANITIZER_FLAGS is empty. Build dirs live under
#    the gitignored `cmake-build/` so a `git clean -ffdX` removes all configure state.
FUZZ_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -O1"
FZ="$SRC/cmake-build/fuzz"
cmake -S "$SRC" -B "$FZ" -G Ninja \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_BUILD_TYPE=None \
    -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS" \
    -DENABLE_MONGOC=OFF -DENABLE_TESTS=OFF -DENABLE_STATIC=ON -DENABLE_SHARED=OFF \
    -DENABLE_EXAMPLES=OFF -DENABLE_MAN_PAGES=OFF -DENABLE_HTML_DOCS=OFF
cmake --build "$FZ" --target bson_static -j"$MAYHEM_JOBS"
LIBBSON="$(find "$FZ/src/libbson" -maxdepth 1 -name '*.a' | head -n1)"
INC="-I$SRC/src/libbson/src -I$FZ/src/libbson/src -I$SRC/src/common/src -I$FZ/src/common/src -DBSON_STATIC"

# 2) Each in-tree harness (src/libbson/fuzz/) twice: libFuzzer binary + run-once standalone reproducer.
#    LeakSanitizer is switched off at build time by linking lsan_off.o into every binary.
HDIR="$SRC/src/libbson/fuzz"
OBJ="$SRC/cmake-build/harness-obj"
mkdir -p "$OBJ"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"

build_harness() {   # <name> <source> <compiler> [extra flags...]
  local name="$1" src="$2" cc="$3"; shift 3
  "$cc" $FUZZ_FLAGS $INC "$@" "$src" "$LIBBSON" "$OBJ/lsan_off.o" $LIB_FUZZING_ENGINE -o "$SRC/$name"
  "$cc" $FUZZ_FLAGS $INC "$@" "$src" "$LIBBSON" "$OBJ/lsan_off.o" "$OBJ/standalone_main.o" -o "$SRC/$name-standalone"
}
build_harness fuzz-init-from-json "$HDIR/init-from-json.c" "$CC"
build_harness fuzz-bson-utf8-escape-for-json "$HDIR/utf8-escape-for-json.c" "$CC"
build_harness fuzz-validate "$HDIR/validate.cpp" "$CXX" -std=c++17

# 3) The project's own functional suite with NORMAL flags (clean, independent build). libbson's tests
#    live in test-libmongoc (the `/bson/*` and `/bson_corpus/*` groups need no server); test.sh runs them.
TB="$SRC/cmake-build/tests"
cmake -S "$SRC" -B "$TB" -G Ninja \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
    -DENABLE_TESTS=ON -DENABLE_STATIC=ON -DENABLE_EXAMPLES=OFF -DENABLE_MAN_PAGES=OFF \
    -DENABLE_HTML_DOCS=OFF -DENABLE_SRV=OFF -DENABLE_SASL=OFF -DENABLE_SNAPPY=OFF \
    -DENABLE_ZSTD=OFF -DENABLE_CLIENT_SIDE_ENCRYPTION=OFF
cmake --build "$TB" --target test-libmongoc -j"$MAYHEM_JOBS"
