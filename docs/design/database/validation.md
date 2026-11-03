# Database: Validation plan and results

> **Covers:** The load-test and race-test plan, what would justify more components (11), and the verification results on PostgreSQL 18.6 (13).
> **Read when:** planning tests, checking what was verified, or judging a performance claim.
> **Related:** [../verification/README.md](../verification/README.md), [amendments.md](amendments.md)

## 11. Validation plan

Measure first, then add complexity. **The load tests and application race tests below haven't been run yet**, since they need the implementation. Section 13 covers what was checked directly in SQL.

### 11.1 Test setup

- A PostgreSQL 18 container limited to about 2 CPUs and 4 GB. Re-check against the real host's limits when one is chosen.
- A repeatable generator with a fixed seed, then `ANALYZE` (which refreshes the planner's statistics).
- `EXPLAIN (ANALYZE, BUFFERS)` for each query, and p95 latency from a load test.

| Dataset | Users | Runs | Competitions | Participants |
|---|---|---|---|---|
| Target | 5,000 | 315,000 (1 year at 860/day) | 2,000, mostly small, one with 5,000 | About 50,000 |
| Stress | 50,000 | 3,000,000 | 20,000, one with 50,000 | About 500,000 |

Competition counts are estimates, not measured figures. Sizes are deliberately skewed, because a uniform dataset would hide the worst case.

### 11.2 Queries and targets

| Query | Pattern | Target | Plan to check |
|---|---|---|---|
| Top 10 in the 5,000-person competition | R2 | p95 < 200 ms, whole request | Backward index scan, stops early |
| My rank: last place, 5,000 participants | R2 | Same budget | Index scan, heap fetches |
| Run history, deep page | R3 | < 300 ms | Keyset scan, no sort |
| Stats, heaviest user | R4 | < 300 ms | Index range scan |
| Competition with 5,000 participants | R5 | < 300 ms | Primary key, paginated |
| My competitions, 100+ entries | R6 | < 300 ms | `ix_participants_user` |
| Friends and group members | R7 | < 300 ms | Both friendship indexes |
| Search with mid-word match | R8 | < 500 ms | Sequential scan is acceptable if under target |
| User search by display name (added by the API design) | R7 | < 500 ms | Sequential scan is acceptable if under target |
| Session lookup (API-1) | R1 | < 5 ms | `sessions` PK |
| Full upload, 10 competitions | W1, W2 | < 1 s | Time for parse, storage and transaction |
| Join with backfill | W3 | < 300 ms | `ix_runs_user_started` |
| Closure with concurrent uploads | W4 | Not latency-critical | Lock wait time |
| Purge of the heaviest user | W6 | Not latency-critical | Cascade time |

### 11.3 Race tests

Run with parallel threads against real PostgreSQL (for example Testcontainers). A good EXPLAIN says nothing about correctness, so these are **required**:

1. Two identical uploads: exactly one run.
2. Two overlapping uploads with different hashes: exactly one run, and the other gets `23P01`.
3. Two non-overlapping uploads in one competition: the final score includes both.
4. Join and upload at once, many times: the final score always includes the run.
5. Upload just before `closes_at`, with closure running: an acknowledged eligible run always counts.
6. Upload after `closes_at`: scores don't change.
7. Two closers: one closure, no errors.
8. Deletion during upload: no run survives the purge.
9. Two sweepers: each user is purged once, no errors.
10. Join at the competition limit from two connections: the limit holds.
11. Leave at or after `ends_at`: refused, and the participant row remains.
12. Double join on the competition that reaches the limit (API-3): both calls succeed, with one row.
13. Two admins demoting each other at once (API-6): at least one admin remains.
14. Login racing with account deletion (API-1): a session created in the race can't authenticate.
15. Retry of an accepted upload after its `started_at` passes the age limit (API-2): returns the original run.
16. Join racing with competition deletion (API-6): either the join returns 404, or the deletion is refused.

### 11.4 What would justify adding more

All triggers apply only after queries and indexes are tuned, and on the target dataset unless stated.

| Addition | Trigger |
|---|---|
| Redis (leaderboards) | R2 database time p95 > 100 ms (half the budget), or leaderboard queries drive sustained database CPU > 70% |
| Partitioning `runs` | R3/R4 miss 300 ms on the stress dataset with correct plans, or we need to drop old data in bulk |
| Read replica | Primary CPU > 70% sustained, mainly from reads, after indexing and caching are exhausted |
| Precomputed stats | R4 p95 > 300 ms |
| `pg_trgm` | R8 p95 > 500 ms |

**Prediction:** at 5,000 users, none of these triggers will fire. Section 5 of `ARCHITECTURE.md` also allows replication and partitioning as **learning experiments**, which is a good reason to try them locally. They should stay out of the production design unless triggered.

---

## 13. Verification results

**Environment:** PostgreSQL 18.6 (`postgres:18-alpine`) in a throwaway container, since removed. The DDL was extracted directly from section 3 of this document, so the test covered this text and not a separate copy. The scripts and the steps to reproduce the run are in [verification/](../verification/README.md).

### 13.1 What passed

| Check | Result |
|---|---|
| All DDL applies in dependency order | Pass |
| `uuidv7()` works as a default, and produces version 7 | Pass |
| Generated `pace_s_per_km` calculates and rounds correctly, and can't be set directly | Pass |
| Each `CHECK`, unique, foreign-key and cascade rule (72 checks, including the recalculation and rank results below) | 72 of 72 |
| Duplicate hash returns `23505`, and overlap returns `23P01`, each with the expected constraint name | Pass |
| Touching runs and an invalid run overlapping a valid one are accepted | Pass |
| Recalculation: eligibility boundaries, invalid and late runs excluded, `NULL` when no run is eligible | Pass |
| Ties rank 1, 2, 2, 4, deleted users are filtered, and ranks close up | Pass |
| `transaction_timeout` set with `SET LOCAL` fires, also during a lock wait, and doesn't persist | Pass |
| Lock conflicts in section 6.1, and the two-connection race flows below (28 checks) | 28 of 28 |

**Race flows, run with two real connections and a forced order:**
- Concurrent overlapping uploads and concurrent duplicates: the second waits for the first's commit, then fails.
- Two uploads scoring one participant: the final score includes both.
- Join and ingest, in both orders: the later one sees the earlier one's data.
- Closure waits for a scoring transaction, and a scorer that waited on closure then sees `closed_at`. A second closer changes nothing.
- Deletion waits for an in-flight ingest, and an ingest that waited on deletion then finds no active user.
- A second sweeper skips a locked row.

### 13.2 Query plans

Sample: 5,000 users, 314,811 runs, 2,000 competitions and 48,978 participants, freshly vacuumed. **These confirm index use only. They aren't benchmarks**, because the sample was fully cached, idle and vacuumed.

| Query | Observed |
|---|---|
| Top 10 of 5,000, both directions | `ix_participants_leaderboard`, index-only, stops after 11 rows |
| My rank, last place | Same index, index-only, reads 4,999 rows, hash anti join on `ix_users_deleted` |
| My score | `ix_participants_user` (the planner preferred it over the primary key) |
| Run history (R3) | `ix_runs_user_started`, no sort |
| W1 competition lookup | `ix_participants_user`, with `ix_competitions_to_close` |
| Recalculation | `ix_runs_user_started` |
| Closure candidates, sweeper | `ix_competitions_to_close`, `ix_users_deleted` |
| R6, R7 | `ix_participants_user`, both friendship indexes, `ix_group_members_user` |
| R8 search | Sequential scan, as designed |

### 13.3 Defects found and fixed

| Defect | Fix |
|---|---|
| A distance of 0 failed with division by zero (`22012`), because generated columns are calculated before constraints | `NULLIF` in the pace expression, so `ck_runs_distance` now fires |
| An extreme implausible run (1 m in 30 days) overflowed the pace (`22003`), although section 3.2 said it could be stored as `invalid` | `duration_s` limited to 7 days. The API rejects distance under 1 m and duration over 7 days before storage. `22003` remains possible only as a backstop for values the API should already have rejected |
| Three name `CHECK` constraints had no `ck_` name, and the conventions promised `fk_` names that the DDL didn't use | Named the constraints, and corrected the conventions |
| Section 6.3 didn't say that `transaction_timeout` terminates the connection | Documented |
| Section 7.1's predicted plan lacked the `Incremental Sort` | Replaced with the observed plan |

### 13.4 Not covered

- **Load and latency:** no load test, no concurrent traffic, no measured p95, and no vacuum lag or bloat behavior.
- **Application behavior:** the job logic, the leave cutoff (D39), the limit of 10 competitions, GPX parsing, MinIO and the orphan and purge jobs don't exist yet. The race flows used hand-written SQL with a forced order, not the real code under random timing, so the tests in section 11.3 are still required.
- **Timing:** the 60-second closure wait against a real upload near the deadline.
- **Flyway:** the migration files don't exist yet, so neither Flyway itself nor the `flyway-database-postgresql` module was checked. The roles in section 10.2 weren't tested either, since the tests ran as a superuser.
- **The Outbox milestone (section 9):** its SQL wasn't executed, since it isn't part of the initial schema.
- **SQLSTATE of the timeout:** the observed result was `FATAL: terminating connection due to transaction timeout`. The application should treat this as a lost connection, rather than relying on a specific code.

---

