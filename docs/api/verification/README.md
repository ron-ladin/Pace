# API Contract Verification

These checks cover the contract, whose root is [`../openapi.yaml`](../openapi.yaml), and its match with [`../../design/api.md`](../../design/api.md). The results of the last run are in section 21 of that document.

> They check the contract and the documents, not behavior, because no application code exists yet. Contract tests against the real application are designed in section 17 of `api.md`.

## Files

| File | Purpose |
|---|---|
| `../.spectral.yaml` | Spectral rules: the standard OpenAPI set, plus project rules for access patterns, explicit security, declared 429/500/503, Problem Details errors and camelCase |
| `check_coverage.mjs` | Every operation is complete, every example conforms to its schema, every R/W pattern and Phase 1 requirement is mapped, the catalog and error tables in `api.md` match the spec, D-numbers, indexes and endpoints all resolve, and the bundle keeps every component |
| `load_spec.cjs` | Assembles the split contract in-process for `check_coverage.mjs` and `check_classes.mjs`, so they never read a stale bundle |

## Requirements

Docker and Node.js. Spectral needs Node 22 or later, and Redocly CLI 2 needs Node 20.19 or later, so the linters run in a `node:22-alpine` container. `check_coverage.mjs` also runs on Node 16.

## Run

Run all commands from the **repository root**. In Git Bash on Windows, first run `export MSYS_NO_PATHCONV=1`, so that container paths aren't rewritten, and use `$(pwd -W)` in place of `$(pwd)`.

### 1. Bundle

The contract is split into `openapi.yaml`, `paths/` and `components/`. This produces the single file for tools and the frontend. **The bundle is generated and not committed**, and `docs/api/dist/` is ignored by git. Regenerate it after changing the contract:

```sh
docker run --rm -v "$(pwd)/docs/api:/spec" node:22-alpine sh -c '
  cd /tmp &&
  npm install --silent --no-audit --no-fund --ignore-scripts @redocly/cli@2 &&
  ./node_modules/.bin/redocly bundle /spec/openapi.yaml --output /spec/dist/openapi.bundled.yaml'
```

### 2. Lint

Spectral lints the **bundle**, because it reports false errors on the split root. Redocly lints both:

```sh
docker run --rm -v "$(pwd)/docs/api:/spec:ro" node:22-alpine sh -c '
  cd /tmp &&
  npm install --silent --no-audit --no-fund --ignore-scripts @stoplight/spectral-cli@6 @redocly/cli@2 &&
  ./node_modules/.bin/spectral lint /spec/dist/openapi.bundled.yaml --ruleset /spec/.spectral.yaml;
  ./node_modules/.bin/redocly lint /spec/openapi.yaml;
  ./node_modules/.bin/redocly lint /spec/dist/openapi.bundled.yaml'
```

### 3. Coverage and examples

Install the dependencies **outside the repository**, then pass that directory to the script. Replace `<temp-dir>` with a new empty directory:

```sh
npm install --prefix <temp-dir> --ignore-scripts --no-audit --no-fund yaml@2 ajv@8 ajv-formats@3
node docs/api/verification/check_coverage.mjs <temp-dir> .
```

### 4. Mermaid

```sh
npm install --prefix <temp-dir> --ignore-scripts --no-audit --no-fund mermaid@10.9.1 jsdom@20.0.3
node docs/design/verification/check_mermaid.mjs <temp-dir> docs/design/api.md
node docs/design/verification/check_mermaid.mjs <temp-dir> ARCHITECTURE.md
```

## Expected results

| Step | Expected |
|---|---|
| Bundle | `Created a bundle`, and the file `docs/api/dist/openapi.bundled.yaml` exists |
| Spectral | No errors, and exit code 0 |
| Redocly | `Your API description is valid` for both files. One warning remains on each, `info-license`, because the project has no license yet |
| `check_coverage.mjs` | `PASS` on every line, then `failed=0` and exit code 0 |
| `check_mermaid.mjs` | `PASS` for each block and the negative control, then `failed=0` |

The file `openapi.yaml` was first written by a throwaway script, so that repeated parts stayed consistent. **It is hand-maintained from now on**, and no generator exists in this repository. That still holds now that it is split: edit the files in `paths/` and `components/` by hand.
