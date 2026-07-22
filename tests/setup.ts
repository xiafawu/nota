import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

// Hermetic catalog: point every test at a nonexistent cache file inside a
// fresh temp dir so the effective catalog is always the baked snapshot,
// never the developer's real ~/.nota/models-catalog.json. Individual tests
// that exercise cache reading override this with their own fixture path.
process.env.NOTA_CATALOG_PATH = path.join(
  mkdtempSync(path.join(tmpdir(), "nota-test-catalog-")),
  "models-catalog.json",
);
