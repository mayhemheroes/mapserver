#!/usr/bin/env bash
#
# mapserver/mayhem/test.sh — RUN the golden Mapfile-parse oracle (built by mayhem/build.sh) and emit
# a CTRF summary. exit 0 iff the oracle passes.
#
# Oracle path (NOT a no-op stub): /mayhem/map_oracle exercises the same msLoadMap() Mapfile parser the
# mapfuzzer fuzzes. It is a PATCH-grade golden check — it asserts SEMANTIC parse results:
#   * a known-good Mapfile must load AND yield the expected NAME / SIZE / LAYER NAME, and
#   * a known-malformed Mapfile must be REJECTED (msLoadMap -> NULL).
# A parser regression (or a "make it always succeed / always fail" patch) breaks one of these, so the
# oracle fails. This script only RUNS the pre-built binary; it never compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

ORACLE=/mayhem/map_oracle
VALID="$SRC/mayhem/oracle/valid.map"
BAD="$SRC/mayhem/oracle/malformed.map"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

if [ ! -x "$ORACLE" ]; then
  echo "missing $ORACLE — run mayhem/build.sh first" >&2
  emit_ctrf "mapfile-oracle" 0 1 0; exit 2
fi
if [ ! -f "$VALID" ] || [ ! -f "$BAD" ]; then
  echo "missing oracle fixtures ($VALID / $BAD)" >&2
  emit_ctrf "mapfile-oracle" 0 1 0; exit 2
fi

echo "=== running mapfile parse oracle ==="
# ASan leak detection off: msLoadMap on the malformed input intentionally aborts mid-parse and some
# partially-built objects are not freed by design — that is not the property under test here.
#
# Anti-reward-hacking (§6.3): capture stdout and assert the expected ORACLE OK: line is present.
# A neutered binary that exits(0) without printing anything fails this grep even if exit code is 0.
ORACLE_OUT=$(ASAN_OPTIONS="detect_leaks=0:${ASAN_OPTIONS:-}" "$ORACLE" "$VALID" "$BAD" 2>&1)
ORACLE_RC=$?
echo "$ORACLE_OUT"

if [ $ORACLE_RC -ne 0 ]; then
  echo "oracle FAILED (exit $ORACLE_RC)" >&2
  emit_ctrf "mapfile-oracle" 0 1 0; exit 1
fi

# Verify the oracle actually printed its success marker — exit(0)-only neuters won't pass this.
if ! echo "$ORACLE_OUT" | grep -q "ORACLE OK:"; then
  echo "oracle FAILED: expected 'ORACLE OK:' in output but got none" >&2
  emit_ctrf "mapfile-oracle" 0 1 0; exit 1
fi

emit_ctrf "mapfile-oracle" 1 0 0
