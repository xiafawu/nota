import { defineConfig, configDefaults } from "vitest/config";

export default defineConfig({
  test: {
    // Extend (don't replace) vitest's built-in excludes so node_modules/dist
    // stay excluded. `.claude/worktrees/` holds stale git-worktree copies of
    // this repo whose test files would otherwise be scanned and run as
    // duplicates, inflating the count and runtime.
    exclude: [...configDefaults.exclude, "**/.claude/**"],
    // Hermetic catalog path — see tests/setup.ts.
    setupFiles: ["tests/setup.ts"],
  },
});
