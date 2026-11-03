# Design Verification

Most of these scripts check the schema in [`../database.md`](../database.md) against a real PostgreSQL 18 server. The results of the last run are in section 13 of that document. `check_classes.mjs` is different: it checks [`../classes.md`](../classes.md) against the contract and the other documents, and its results are in section 18 of that document.

> **These scripts are temporary.** They are meant to become automated tests (Testcontainers) during implementation. They use hand-written SQL in a forced order, so they don't replace the application race tests in section 11.3 of the design. They also aren't benchmarks.

## Files

| File | Purpose |
|---|---|
| `extract_ddl.js` | Extracts the DDL from section 3 of `database.md`, so the tests cover the document's own text |
| `01_constraints.sql` | Constraints, `uuidv7()`, generated pace, error codes, cascades, recalculation rules, rank results |
| `02_locks.sql` | Lock conflicts and race flows, using `dblink` for extra connections |
| `03_plans.sql` | Loads a synthetic sample at about the target size, and prints query plans |
| `04_transaction_timeout.sql` | `transaction_timeout` with `SET LOCAL`, during a sleep |
| `05_hold_lock.sql`, `06_timeout_lock_wait.sql` | `transaction_timeout` during a lock wait |
| `extract_amendments.js` | Extracts the migration SQL from section 14 of `database.md` |
| `07_api_amendments.sql` | The API design's amendments and query plans, run after `03_plans.sql` on the same database |
| `check_mermaid.mjs` | Parses the Mermaid diagrams in a Markdown file |
| `check_classes.mjs` | Checks `classes.md`: module graph, inventory, traceability of endpoints, patterns, races, transactions and decisions, DTO fields against schemas, error codes and diagram class names |

## Requirements

Docker and Node.js (the last run used Node 16). The container publishes no ports and is removed at the end.

## Reproduce the run

Run all commands from the **repository root**. They work in PowerShell and in a POSIX shell. In Git Bash on Windows, first run `export MSYS_NO_PATHCONV=1`, so that container paths aren't rewritten.

### 1. Generate the DDL and start the container

```sh
node docs/design/verification/extract_ddl.js docs/design/database.md docs/design/verification/ddl_from_doc.sql
docker run -d --name pace-db-verify -e POSTGRES_PASSWORD=verify-only postgres:18-alpine
docker exec pace-db-verify pg_isready -U postgres
```

Repeat `pg_isready` until it reports `accepting connections`. Then copy the scripts in, and check the version:

```sh
docker cp docs/design/verification pace-db-verify:/tmp/v
docker exec pace-db-verify psql -U postgres -Atc "select version()"
```

### 2. Create three fresh databases

Run this pair of commands for each of `pace_c`, `pace_locks` and `pace_plans`. This example is for `pace_c`:

```sh
docker exec pace-db-verify psql -U postgres -c "CREATE DATABASE pace_c"
docker exec pace-db-verify psql -U postgres -d pace_c -q -v ON_ERROR_STOP=1 -f /tmp/v/ddl_from_doc.sql
```

### 3. Run the scripts, in this order

```sh
docker exec pace-db-verify psql -U postgres -d pace_c -q -At -f /tmp/v/01_constraints.sql
docker exec pace-db-verify psql -U postgres -d pace_locks -q -At -f /tmp/v/02_locks.sql
docker exec pace-db-verify psql -U postgres -d pace_plans -q -f /tmp/v/03_plans.sql
docker exec pace-db-verify psql -U postgres -d pace_locks -At -f /tmp/v/04_transaction_timeout.sql
```

Then run these two within 5 seconds of each other. `docker exec -d` keeps the first one in the background:

```sh
docker exec -d pace-db-verify psql -U postgres -d pace_locks -f /tmp/v/05_hold_lock.sql
docker exec pace-db-verify psql -U postgres -d pace_locks -At -f /tmp/v/06_timeout_lock_wait.sql
```

### 3a. Check the API design's amendments

Steps 1 to 3 test the original schema. This one tests the API design's amendments, on a separate database with the amendments applied **before** the sample is loaded:

```sh
node docs/design/verification/extract_amendments.js docs/design/database.md docs/design/verification/amendments_from_doc.sql
docker cp docs/design/verification/amendments_from_doc.sql pace-db-verify:/tmp/v/amendments_from_doc.sql
docker exec pace-db-verify psql -U postgres -c "CREATE DATABASE pace_api"
docker exec pace-db-verify psql -U postgres -d pace_api -q -v ON_ERROR_STOP=1 -f /tmp/v/ddl_from_doc.sql
docker exec pace-db-verify psql -U postgres -d pace_api -q -v ON_ERROR_STOP=1 -f /tmp/v/amendments_from_doc.sql
docker exec pace-db-verify psql -U postgres -d pace_api -q -f /tmp/v/03_plans.sql
docker exec pace-db-verify psql -U postgres -d pace_api -q -f /tmp/v/07_api_amendments.sql
```

### 4. Check the Mermaid diagrams

Install the parser **outside the repository**, then pass that directory to the script. Replace `<temp-dir>` with a new empty directory:

```sh
npm install --prefix <temp-dir> --ignore-scripts --no-audit --no-fund mermaid@10.9.1 jsdom@20.0.3
node docs/design/verification/check_mermaid.mjs <temp-dir> ARCHITECTURE.md
```

### 4a. Check the class design

This needs Node.js only, with no container. Replace `<temp-dir>` with a new empty directory. It checks consistency between documents, because no code exists for it to check:

```sh
npm install --prefix <temp-dir> --ignore-scripts --no-audit --no-fund yaml@2 mermaid@10.9.1 jsdom@20.0.3
node docs/design/verification/check_classes.mjs <temp-dir> .
node docs/design/verification/check_mermaid.mjs <temp-dir> docs/design/classes.md
```

### 5. Clean up

```sh
docker rm -f pace-db-verify
```

Also delete the generated `docs/design/verification/ddl_from_doc.sql` and `amendments_from_doc.sql`, and optionally remove the image with `docker rmi postgres:18-alpine`.

## Expected results

| Step | Expected |
|---|---|
| DDL | Applies with no errors, exit code 0 |
| `01_constraints.sql` | The last line is `72\|72\|0` (total, passed, failed). Any failure prints above it as a row ending in `\|f` |
| `02_locks.sql` | The last line is `28\|28\|0`, with no `ERROR` lines. Each check prints a row ending in `\|t` |
| `03_plans.sql` | The plans in section 13.2 of the design. Timings vary, and they aren't meaningful |
| `07_api_amendments.sql` | The last line is `13 \| 13 \| 0` (total, passed, failed), with no `ERROR` lines. The plans in section 14.7 of the design. The HOT counts vary with page layout |
| `04_transaction_timeout.sql` | Prints `fast ok` and `0`, then `FATAL: terminating connection due to transaction timeout` after about 1 second. Exit code 2, and `still alive` is never printed |
| `06_timeout_lock_wait.sql` | The same `FATAL` after about 1 second, with `while locking tuple` in the context. Exit code 2 |
| `check_mermaid.mjs` | `PASS` for each block and the negative control, then `failed=0`, exit code 0 |
| `check_classes.mjs` | `PASS` on every line, then `failed=0`, exit code 0 |

**The `FATAL` and exit code 2 in steps 04 and 06 are the correct result.** They show that the timeout terminates the connection.

`02_locks.sql` prints a `NOTICE` for each expected constraint failure, which is also correct.

Row counts in `03_plans.sql` vary slightly, because the sample uses random values and no fixed seed. The last run had 5,000 users, 314,811 runs, 2,000 competitions and 48,978 participants. The validation plan in section 11.1 of the design requires a seeded generator, which this sample doesn't replace.
