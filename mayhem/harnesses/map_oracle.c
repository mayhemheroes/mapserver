/* map_oracle.c — golden oracle over MapServer's Mapfile-parse path (the same msLoadMap() the
 * mapfuzzer drives). Build-time PATCH-grade check: it asserts SEMANTIC parse results, so a no-op /
 * "always return success" patch to the parser cannot pass.
 *
 *   argv[1] = a known-VALID mapfile   -> msLoadMap() must return non-NULL AND parse known fields
 *                                         (NAME, SIZE, the LAYER's NAME) to the expected values.
 *   argv[2] = a known-MALFORMED file  -> msLoadMap() must return NULL (rejected).
 *
 * Exit 0 iff both hold; nonzero (with a diagnostic) otherwise.
 */
#include <stdio.h>
#include <string.h>

#include "src/mapserver.h"

static int fail(const char *msg) {
  fprintf(stderr, "ORACLE FAIL: %s\n", msg);
  return 1;
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s <valid.map> <malformed.map>\n", argv[0]);
    return 2;
  }

  /* 1) valid mapfile must load and carry the expected parsed values */
  mapObj *map = msLoadMap(argv[1], NULL, NULL);
  if (!map)
    return fail("valid mapfile returned NULL");

  int rc = 0;
  if (!map->name || strcmp(map->name, "OracleMap") != 0) {
    rc = fail("MAP NAME mismatch");
  } else if (map->width != 400 || map->height != 300) {
    rc = fail("MAP SIZE mismatch");
  } else if (map->numlayers != 1) {
    rc = fail("expected exactly 1 LAYER");
  } else if (!GET_LAYER(map, 0)->name ||
             strcmp(GET_LAYER(map, 0)->name, "oracle_layer") != 0) {
    rc = fail("LAYER NAME mismatch");
  }
  msFreeMap(map);
  if (rc) {
    msResetErrorList();
    return rc;
  }

  /* 2) malformed mapfile must be rejected */
  msResetErrorList();
  mapObj *bad = msLoadMap(argv[2], NULL, NULL);
  if (bad) {
    msFreeMap(bad);
    msResetErrorList();
    return fail("malformed mapfile was accepted (expected NULL)");
  }
  msResetErrorList();

  printf("ORACLE OK: valid mapfile parsed + fields verified; malformed rejected\n");
  return 0;
}
