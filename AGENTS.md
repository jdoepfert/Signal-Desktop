# AGENTS.md — Signal Desktop

Electron + React + TypeScript desktop client. `pnpm`-only repo (pnpm 11.24, Node 24.21.0 per `.nvmrc`). Never use npm/yarn.

## Setup / build

```sh
pnpm install          # also runs postinstall (acknowledgments + electron app deps)
pnpm run generate     # REQUIRED before start/test/build: protobuf + emoji + rolldown prod + icu-types + compact-locales + styles + db-schema
pnpm start            # runs built bundles, not source directly
```

- App loads `bundles/` output (rolldown), not `ts/` source. After editing, rebuild or run watchers in separate terminals:
  - `pnpm run dev:transpile` (`check:types --watch` + `dev:rolldown` + icu-types + protobuf) for `.ts`
  - `pnpm run dev:styles` for `.scss`
  - Or reload via View > Toggle Developer Tools, then Cmd/Ctrl+R.
- Full release build: `pnpm run generate && pnpm run build`. Linux: `xvfb-run` needed for tests; macOS ad-hoc sign test builds with `SKIP_SIGNING_SCRIPT=1 pnpm run build` then `codesign --force --deep --sign - Signal.app`.

## Verification (in order)

- Gate before PR: `pnpm run ready` (≈ CI: clean-transpile + generate + lint + lint-deps + lint-intl + test-node + test-electron). CONTRIBUTING explicitly requires it to pass.
- `pnpm test` = `test-node` + `test-electron` + `test-lint-intl` + `test-oxlint`.
- Focused runs:
  - Node/unit: `pnpm run test-node` (electron-mocha over `ts/test-node`, `scripts/**/*_test.mjs`). Pass a file/glob or `--grep <pattern>` to focus.
  - Electron/renderer: `pnpm run test-electron` (spawns Electron via `scripts/test-electron.mjs`; extra CLI args are forwarded to the runner, e.g. grep/filter). On Linux prefix with `xvfb-run --auto-servernum`.
  - Mock-server integration: `pnpm run test-mock` (private-CI only job; needs staging/mock setup).
- Lint/typecheck: `pnpm run lint` = `lint-prettier` + `lint-css` + `check:types` (`tsc --noEmit`) + `oxlint` + `lint-knip`. Fix formatting with `pnpm run format` (prettier: `singleQuote`, `arrowParens: avoid`, tailwind plugin). `lint-css` = stylelint on `**/*.scss`.

## Architecture

- `app/main.main.ts` + `app/config.main.js` → Electron main bundle (`bundles/main.js`, `bundles/config.js`).
- `ts/windows/<name>/{preload.preload.ts,app.dom.tsx}` → sandboxed window bundles (`bundles/preload/*`, `bundles/dom/*`). Preload bundles cannot use `require()`; keep them separate (see `rolldown.config.ts`).
- `ts/` is renderer/shared code: `components/`, `state/` (redux), `services/`, `models/`, `sql/`, `textsecure/`, `util/`, `types/`, `workers/`, `test-{node,electron,mock}/`, `test-helpers/`.
- `packages/*` (`mock-server`, `types`, `mute-state-change`, `windows-ucv`, `lame`) + `sticker-creator/` are pnpm workspaces with their own builds.
- Runtime config: `config/<SIGNAL_ENV>.json` (default dev points at staging). Per-profile override: `config/local-<instance>.json` with `NODE_APP_INSTANCE=<instance>`.

## Conventions that break the build if ignored

- **File suffixes are enforced** by `signal-desktop/enforce-file-suffix` (oxlint): name files `.std` (universal), `.node` (Node-only), `.dom` (renderer DOM), `.preload` (Electron preload), `.main` (Electron main) according to APIs used. Importing a Node/Electron-main module from `.std`/`.dom` fails lint. New deps must be categorized in `.oxlint/rules/enforceFileSuffix.mjs` (`NODE_PACKAGES`/`DOM_PACKAGES`/`STD_PACKAGES`).
- **Import boundaries enforced** (`no-restricted-paths`): `ts/util/**` and `ts/types/**` may not import from `ts/components/**`; `scripts/**`/`codemods/**` and `ts/**` may not import each other.
- **License header required** on every file (`lint-license-comments` / `enforce-license-comments`): `// Copyright <year> Signal Messenger, LLC` + `// SPDX-License-Identifier: AGPL-3.0-only`.
- **No `.then()` chains** (`signal-desktop/no-then`): use async/await. Also banned: `for-in` (use `for-of`/iteration helpers), focused/disabled tests (`.only`/`.skip`), `==` except `== null`.
- **Strings**: never hardcode UI copy. Edit only `_locales/en/messages.json`; other locales are generated. Run `pnpm run lint-intl` after touching strings. Styles: Tailwind via `tw()` + SCSS (`stylesheets/manifest.scss`); oxlint `enforce-tw` applies.
- **Knip** (`lint-knip`, `lint-knip:prod`) flags unused exports/deps; entry points are declared in `knip.js`. Tag test-only exports `@testexport` or they fail the prod pass.
- TypeScript is strict (`strict`, `noUncheckedIndexedAccess`, `noUnusedLocals`/`noUnusedParameters`, `noImplicitOverride`). Prefer `value == null` checks (allowed by `eqeqeq` exception) to narrow `null`+`undefined`.
