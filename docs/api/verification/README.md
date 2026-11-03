# API Contract Verification

These checks cover [`../openapi.yaml`](../openapi.yaml) and its match with [`../../design/api.md`](../../design/api.md). The results of the last run are in section 21 of that document.

> They check the contract and the documents, not behavior, because no application code exists yet. Contract tests against the real application are designed in section 17 of `api.md`.

## Files

| File | Purpose |
|---|---|
| `../.spectral.yaml` | Spectral rules: the standard OpenAPI set, plus project rules for access patterns, explicit security, declared 429/500/503, Problem Details errors and camelCase |
| `check_coverage.mjs` | Every operation is complete, every example conforms to its schema, every R/W pattern and Phase 1 requirement is mapped, the catalog and error tables in `api.md` match the spec, and D-numbers, indexes and endpoints all resolve |

## Requirements

Docker and Node.js. Spectral needs Node 22 or later, and Redocly CLI 2 needs Node 20.19 or later, so the linters run in a `node:22-alpine` container. `check_coverage.mjs` also runs on Node 16.

## Run

Run all commands from the **repository root**. In Git Bash on Windows, first run `export MSYS_NO_PATHCONV=1`, so that container paths aren't rewritten, and use `$(pwd -W)` in place of `$(pwd)`.

### 1. Lint

```sh
docker run --rm -v "$(pwd)/docs/api:/spec:ro" node:22-alpine sh -c '
  cd /tmp &&
  npm install --silent --no-audit --no-fund --ignore-scripts @stoplight/spectral-cli@6 @redocly/cli@2 &&
  ./node_modules/.bin/spectral lint /spec/openapi.yaml --ruleset /spec/.spectral.yaml;
  ./node_modules/.bin/redocly lint /spec/openapi.yaml'
```

### 2. Coverage and examples

Install the dependencies **outside the repository**, then pass that directory to the script. Replace `<temp-dir>` with a new empty directory:

```sh
npm install --prefix <temp-dir> --ignore-scripts --no-audit --no-fund yaml@2 ajv@8 ajv-formats@3
node docs/api/verification/check_coverage.mjs <temp-dir> .
```

### 3. Mermaid

```sh
npm install --prefix <temp-dir> --ignore-scripts --no-audit --no-fund mermaid@10.9.1 jsdom@20.0.3
node docs/design/verification/check_mermaid.mjs <temp-dir> docs/design/api.md
node docs/design/verification/check_mermaid.mjs <temp-dir> ARCHITECTURE.md
```

## Expected results

| Step | Expected |
|---|---|
| Spectral | No errors, and exit code 0 |
| Redocly | `Your API description is valid`. One warning remains, `info-license`, because the project has no license yet |
| `check_coverage.mjs` | `PASS` on every line, then `failed=0` and exit code 0 |
| `check_mermaid.mjs` | `PASS` for each block and the negative control, then `failed=0` |

The file `openapi.yaml` was first written by a throwaway script, so that repeated parts stayed consistent. **It is hand-maintained from now on**, and no generator exists in this repository.
