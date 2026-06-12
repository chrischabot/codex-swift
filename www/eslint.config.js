import js from "@eslint/js";
import tseslint from "typescript-eslint";
import reactHooks from "eslint-plugin-react-hooks";
import globals from "globals";

// Flat config (ESLint 9). The high-value rule for this codebase is
// react-hooks/exhaustive-deps — it surfaces stale-closure / missing-dependency
// bugs in the many hand-written hook deps. Existing `any`/unused patterns are
// warnings (not errors) so the gate lands green without a repo-wide sweep.
export default tseslint.config(
  { ignores: ["dist/**", "node_modules/**", "*.config.{js,ts}"] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ["src/**/*.{ts,tsx}"],
    languageOptions: { globals: { ...globals.browser } },
    plugins: { "react-hooks": reactHooks },
    rules: {
      "react-hooks/exhaustive-deps": "warn",
      "react-hooks/rules-of-hooks": "error",
      "@typescript-eslint/no-explicit-any": "warn",
      "@typescript-eslint/no-unused-vars": ["warn", { argsIgnorePattern: "^_", varsIgnorePattern: "^_" }],
      // Demoted to warnings: real but not worth blocking the gate on existing
      // code (legit ANSI \x1b regex, redundant !! casts, let→const, expression
      // statements). Triage as follow-up; do not fail CI on them initially.
      "no-control-regex": "warn",
      "no-extra-boolean-cast": "warn",
      "prefer-const": "warn",
      "@typescript-eslint/no-unused-expressions": "warn",
    },
  },
);
