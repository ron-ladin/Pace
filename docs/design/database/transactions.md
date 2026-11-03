# Database: Transactions and races

> **Covers:** Isolation and lock order, scoring by recalculation, and the ingest, join, leave and closure transactions with their races. Section 6.6 is in `deletion-and-jobs.md`.
> **Read when:** writing a write transaction, taking a lock, or reasoning about a race.
> **Related:** [deletion-and-jobs.md](deletion-and-jobs.md), [amendments.md](amendments.md), [../classes/persistence.md](../classes/persistence.md)

## 6. Transactions and races

### 6.1 Isolation level

**Isolation** controls what a transaction can see of other running transactions.

**Decision:** `READ COMMITTED` (the default, where each statement sees the latest committed data), plus constraints and explicit row locks.

| Rejected | Why |
|---|---|
| `SERIALIZABLE` | Needs retry logic around every transaction, and our conflicts are few and known |
| `REPEATABLE READ` | Its fixed snapshot would break the "lock, then read fresh data" pattern used for scoring |

> **Restated by CLS-2 (section 14.8):** the precise order includes groups, and each participant follows its own competition.

**Lock order, always:** user row, then competitions sorted by ID, then participants. A consistent order prevents most deadlocks (two transactions each waiting for the other). Retry on `40P01` in case one still occurs.

**The locks used:**

| Lock | Blocks | Used for |
|---|---|---|
| `FOR SHARE` | Writers, not other sharers | Ingest on the user row, and on the competition |
| `FOR NO KEY UPDATE` | Sharers and other writers, but not foreign-key checks | Join on the user row |
| `FOR UPDATE` | Everything, including foreign-key checks | Closure on the competition, scoring on the participant |

### 6.2 Scoring by recalculation

The old rule was `new score = old score + run`. It only stays correct if every run is applied exactly once and in order. Recalculating from runs is **idempotent** (repeating it changes nothing) and independent of order. The join backfill needs the same calculation, and so would the deferred async worker.

```sql
SELECT SUM(r.distance_m)   -- total_distance. The Strategy chooses this one expression:
       -- longest_run:     MAX(r.distance_m)
       -- fastest_pace:    MIN(r.pace_s_per_km) FILTER (WHERE r.distance_m >= $min_distance_m)
FROM runs r
WHERE r.user_id = $user_id
  AND r.status = 'valid'
  AND r.started_at >= $starts_at AND r.started_at < $ends_at
  AND r.received_at < $closes_at;
```

Eligibility is the `WHERE` clause. `SUM` returns `bigint`, which is converted to `integer` when stored. If no run is eligible, the result is `NULL`. The update only runs if the value changed:

```sql
UPDATE competition_participants
SET score = $new_score, score_updated_at = now()
WHERE competition_id = $competition_id AND user_id = $user_id
  AND score IS DISTINCT FROM $new_score;
```

The Strategy pattern stays, as does "no write if unchanged".

**Rejected:** incremental updates with a ledger of applied runs. It reads less per run, but adds a table and only saves reading a user's few runs inside one window.

### 6.3 Ingesting a run (W1, W2)

> **Amended by API-2 (section 14.2):** the duplicate check moves to right after hashing, before parsing and timestamp checks. The full order of validation steps is in `docs/design/api.md`.
>
> **Amended by CLS-3, CLS-4 and CLS-5 (section 14.8):** the timeout covers every write transaction, a competition row that's gone is skipped, and `23P01` re-checks the hash.

**Outside the transaction:**
1. Check size and type, and hash the file.
2. Parse securely, protecting against XXE, and compute metrics.
3. Reject malformed files and bad timestamps. Classify plausibility as valid or invalid.
4. Quick-check `(user_id, file_hash)`. If found, return the existing run.
5. Store the file at `runs/{user_id}/{sha256}/{attempt_uuid}.gpx`.

**Transaction** (`SET LOCAL transaction_timeout = '30s'`):
1. `SELECT ... FROM users WHERE id = $1 AND deleted_at IS NULL FOR SHARE`. Refuse if no row.
2. Insert the run. On `23505` or `23P01`, the transaction aborts.
3. If invalid, skip to commit.
4. Find this user's eligible open competitions, sorted by ID:
   ```sql
   SELECT c.id
   FROM competition_participants p
   JOIN competitions c ON c.id = p.competition_id
   WHERE p.user_id = $user_id
     AND c.closed_at IS NULL
     AND $started_at >= c.starts_at AND $started_at < c.ends_at
     AND $received_at < c.closes_at
   ORDER BY c.id;
   ```
5. For each competition:
   1. Lock the competition `FOR SHARE`, and skip it if `closed_at` is now set.
   2. Lock the participant row `FOR UPDATE`, and skip if the row is gone (the user left).
   3. Recalculate in a **separate statement**.
   4. Update if changed.
6. Commit and return **201 Created** with the run.

**What the timeout does:** `transaction_timeout` covers lock waits as well as running time, and when it fires PostgreSQL **terminates the connection** (`FATAL`), rather than only aborting the transaction. The connection pool must discard and replace that connection, and the request fails without an acknowledgment, so the client can safely retry. The setting doesn't persist past the transaction when set with `SET LOCAL`.

**Why it's safe to do this synchronously:** a runner is limited to 10 open competitions (configurable, enforced at join), so one upload touches few rows. The total time must still be measured against the 1-second target.

**Why the recalculation is a separate statement:** under `READ COMMITTED`, a new statement sees data committed while the transaction waited for the lock. A single `UPDATE ... SET score = (subquery)` would keep the subquery's older snapshot.

| Race or failure | Without protection | What happens |
|---|---|---|
| Same file twice, or a client retry | Double-counted run | `uq_runs_user_file_hash` raises `23505`. Return the existing run, so retries are safe |
| Same activity from another device | Double-counted distance | The hash differs, but `ex_runs_no_overlap` raises `23P01`. Return 409 |
| Two overlapping uploads at once | Both pass an application check | The constraint makes the second wait, then fail |
| Two non-overlapping uploads at once | **Lost update**: one calculation overwrites the other | The participant lock orders them, and the second sees the first's committed run |
| File stored, then transaction fails | Unused file | Harmless orphan, removed by the daily job |
| Crash after commit, before response | Client doesn't know | The retry hits `23505` and gets the existing run |
| API crash before commit | Nothing was acknowledged | The client retries. Any stored file is an orphan |

**File before commit:** the opposite order could acknowledge a run whose file was never stored, breaking the durability requirement.

**Why each attempt gets its own file key:** a shared key would let the orphan job delete a file at the same moment a retry reuses it. With a per-attempt key, the job can compare the key against the stored `file_key`, and an in-flight attempt can never lose a committed file.

### 6.4 Joining and leaving (W3)

> **Amended by API-3 (section 14.3):** step 3 first checks whether the user is already a participant, and if so, returns success. Group and competition lifecycle transactions are in API-6 (section 14.6).

**Join transaction:**
1. Lock the user row `FOR NO KEY UPDATE`, with `deleted_at IS NULL`.
2. Lock the competition `FOR SHARE`.
3. Check permission or invitation, `closed_at IS NULL`, `now() < ends_at`, and the limit of 10 open competitions.
4. Insert with `ON CONFLICT DO NOTHING`. If nothing was inserted, return success.
5. Recalculate the score (backfill), update it if not `NULL`, and delete any invitation.

**Why the per-user lock matters.** Without it, this order loses a run:

1. The join calculates its score before the run commits, so the run isn't counted.
2. The run's competition lookup doesn't see the uncommitted participant, so the run isn't scored there.
3. Both commit, and neither counted the run.

With the lock, ingest and join for the same user can't overlap, so whichever runs second sees the first. Only that user's own actions wait. Concurrent uploads by one user can still run together, because `FOR SHARE` locks don't conflict.

**Rejected:** `SERIALIZABLE` for this one flow. It needs retry handling, whereas the lock explains itself and costs little.

| Race | What happens |
|---|---|
| Double-click on join | The user lock serializes them, and `ON CONFLICT DO NOTHING` succeeds once |
| Join while closing | The locks conflict, and the join sees `closed_at` set or `ends_at` passed, and is refused |
| Reaching the competition limit from two tabs | The user lock makes the count accurate |

**Leaving (D39):** lock the user and the competition, refuse if `now() >= ends_at`, and delete the participant row. Rejoining before `ends_at` recalculates the score. A leaving user who is still in a scoring transaction causes no error, because scoring skips a missing row.

**Why leaving stops at `ends_at`:** otherwise a user could wait for the final standings during the grace period, and leave to avoid a poor placement. Requiring this rule in the application, under the competition lock, is enough. A user who wants to disappear entirely can still delete their account (section 6.6).

### 6.5 Closing versus a late upload (W4, D13)

**Finding candidates (no lock):**
```sql
SELECT id FROM competitions
WHERE closed_at IS NULL AND closes_at <= now() - interval '60 seconds';
```

**Closing each one, in its own transaction:**
1. `SELECT closed_at FROM competitions WHERE id = $1 FOR UPDATE`. This **waits** for ingest transactions holding `FOR SHARE`.
2. If `closed_at` is already set, stop.
3. Set `closed_at = now()`.

No check for unscored runs is needed, because scoring commits together with the run, so unscored valid runs can't exist.

**Why this waits instead of using `SKIP LOCKED`:** `SKIP LOCKED` would also work, delaying closure to a later tick, but waiting is simpler to reason about. The wait is short, because ingest transactions are time-limited and new uploads received after `closes_at` no longer lock this competition.

| Race | Without protection | What happens |
|---|---|---|
| Upload began before `closes_at`, and hasn't committed | Closure misses an eligible run | Ingest can't last more than 30 s, and closure starts at least 60 s after `closes_at`. The `FOR UPDATE` lock also waits for it |
| Upload received after `closes_at` | Result changes after the deadline | The run is stored and may count elsewhere, but it isn't eligible here |
| Two application instances | Double closure | The second waits, sees `closed_at` set, and stops |
| Scheduler down | Competition stays open longer | Safe. New uploads are still ineligible, because eligibility uses `closes_at` rather than `closed_at`. Alert on overdue closures |

**Final results stay final:** once `closed_at` is set, scoring refuses to change scores, because it rechecks `closed_at` under its lock. The one exception is account deletion, which D17 accepts.

