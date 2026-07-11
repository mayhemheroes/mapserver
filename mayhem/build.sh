#!/usr/bin/env bash
#
# mapserver/mayhem/build.sh — build MapServer's three OSS-Fuzz harnesses as sanitized libFuzzer
# targets (+ standalone reproducers) on top of the org C/C++ base image.
#
# Fuzzed surface (attacker-controlled text/binary fed to MapServer parsers):
#   mapfuzzer    — writes input to a temp <name>.map and runs msLoadMap(): the Mapfile lexer/parser
#                  (src/maplexer.l + src/mapfile.c) over an arbitrary Mapfile.
#   configfuzzer — writes input to a temp <name>.config and runs msLoadConfig(): the CONFIG/ENV/MAPS/
#                  PLUGINS config-file parser (src/mapfile.c msLoadConfig).
#   shapefuzzer  — three files (.shp/.shx/.dbf) concatenated and separated by the 8-byte marker
#                  "deadbeef"; opens them as an in-memory shapefile (msShapefileOpenVirtualFile) and
#                  iterates msSHPReadShape() — the shapefile reader (src/mapshape.c).
#
# Unlike upstream's fuzzers/build.sh (which compiles libxml2 / PROJ / GDAL from source to dodge an
# OSS-Fuzz libc++ ABI clash), the mayhem base uses STOCK clang with libstdc++, so we link the
# DISTRO -dev packages (gdal/proj/libxml2/...) instead — much lighter and the ABI matches.
# We compile the mapserver_static library ITSELF with $SANITIZER_FLAGS so the parsers (not just the
# harness) are instrumented; the optional-deps disabled mirror upstream's fuzz config.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS: -gdwarf-3 forces DWARF ≤ 3 (§6.2 item 10); clang-19's plain -g emits DWARF-5 which
# Mayhem's triage cannot read. Threaded AFTER $SANITIZER_FLAGS so it takes precedence on debug-info.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
export DEBUG_FLAGS
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# ── 1) Configure + build the mapserver_static library WITH sanitizers ──────────────────────────────
# FUZZER=OFF so CMake builds the normal library (the fuzzers themselves we compile/link by hand,
# twice each, to also emit a standalone reproducer). The optional-deps set mirrors upstream
# fuzzers/build.sh: keep the Mapfile / shapefile / config parsers, drop the heavy renderers/db deps.
# -fsanitize=fuzzer-no-link lets the instrumented library carry coverage counters that the libFuzzer
# engine (linked into the harness) consumes; UBSan halts (-fno-sanitize-recover via SANITIZER_FLAGS).
BUILD="$SRC/mayhem-build"
mkdir -p "$BUILD"

COV="-fsanitize=fuzzer-no-link"
cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug \
  -DBUILD_STATIC=ON \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $COV $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $COV $DEBUG_FLAGS" \
  -DWITH_PROTOBUFC=0 -DWITH_FRIBIDI=0 -DWITH_HARFBUZZ=0 -DWITH_CAIRO=0 -DWITH_FCGI=0 \
  -DWITH_GEOS=0 -DWITH_POSTGIS=0 -DWITH_GIF=0 -DWITH_CURL=0 -DWITH_PYTHON=0

# Only the static library — the parsers under test. The mapserv/etc. executables can't link under
# the UBSan config (upstream notes this too) and we don't need them.
ninja -C "$BUILD" -j"$MAYHEM_JOBS" mapserver_static

# CMake names the static target's archive libmapserver_static.a (BUILD_STATIC=ON).
LIBMS="$(find "$BUILD" -name 'libmapserver_static.a' -o -name 'libmapserver.a' | head -1)"
[ -n "$LIBMS" ] || { echo "ERROR: libmapserver static archive not found under $BUILD" >&2; exit 2; }
ls -l "$LIBMS"

# ── 2) Resolve the link line for the distro deps the static lib pulls in ───────────────────────────
# gdal-config knows GDAL's own deps; the rest mirror upstream's explicit -l list. PROJ version macro
# is taken from the installed proj.h so the parser's PROJ_VERSION_MAJOR guards compile correctly.
GDAL_INC="$(gdal-config --cflags 2>/dev/null || echo -I/usr/include/gdal)"
GDAL_LIBS="$(gdal-config --libs 2>/dev/null || echo -lgdal)"
GDAL_DEPLIBS="$(gdal-config --dep-libs 2>/dev/null || true)"
PROJ_MAJOR="$(sed -n 's/^#define PROJ_VERSION_MAJOR[[:space:]]*\([0-9]*\).*/\1/p' \
              /usr/include/proj.h 2>/dev/null | head -1)"
: "${PROJ_MAJOR:=9}"

INC="-I$SRC -I$BUILD $GDAL_INC -DPROJ_VERSION_MAJOR=$PROJ_MAJOR"
# pcre2-posix provides the pcre2_regcomp/regexec/regfree wrappers MapServer links when WITH_PCRE2 is
# auto-enabled (libpcre2-dev present); it in turn needs the pcre2-8 library.
SYSLIBS="-lgdal -lproj -lxml2 -lpng -ljpeg -lfreetype -lz -lsqlite3 -llzma -lpcre2-posix -lpcre2-8 -lm -lpthread -ldl $GDAL_DEPLIBS"

HARNESS_DIR="$SRC/mayhem/harnesses"

# Standalone run-once driver, compiled as C (so its LLVMFuzzerTestOneInput reference stays an
# unmangled C symbol that matches the C harnesses — clang++ would otherwise mangle it).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"

# ── 3) Build each harness twice: libFuzzer (-> /mayhem/<name>) + standalone reproducer ─────────────
for fuzzer in mapfuzzer shapefuzzer configfuzzer; do
  # harness object (C), instrumented for coverage so the engine sees the harness too.
  $CC $SANITIZER_FLAGS $COV $DEBUG_FLAGS $INC -c "$HARNESS_DIR/$fuzzer.c" -o "$BUILD/$fuzzer.o"

  # libFuzzer target -> /mayhem/<name>  (link with clang++ — the lib has C++ objects)
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
      "$BUILD/$fuzzer.o" -o "/mayhem/$fuzzer" \
      "$LIBMS" $SYSLIBS

  # standalone reproducer (run-once, no libFuzzer runtime) -> /mayhem/<name>-standalone
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS \
      "$BUILD/$fuzzer.o" "$BUILD/standalone_main.o" -o "/mayhem/$fuzzer-standalone" \
      "$LIBMS" $SYSLIBS

  echo "built $fuzzer (+ standalone)"
done

# ── 4) Golden Mapfile-parse oracle (consumed by mayhem/test.sh) ────────────────────────────────────
# Built WITHOUT the fuzzer-no-link coverage flag and WITHOUT a fuzzing engine — a plain program that
# asserts semantic parse results over msLoadMap(). Sanitizers stay on so the oracle also catches
# memory errors on the known-good/known-bad inputs.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $INC \
    "$HARNESS_DIR/map_oracle.c" -o "/mayhem/map_oracle" \
    "$LIBMS" $SYSLIBS
echo "built map_oracle"

echo "build.sh complete:"
ls -la /mayhem/mapfuzzer /mayhem/shapefuzzer /mayhem/configfuzzer \
       /mayhem/mapfuzzer-standalone /mayhem/shapefuzzer-standalone /mayhem/configfuzzer-standalone 2>&1 || true
