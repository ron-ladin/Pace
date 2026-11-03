# Database Detailed Design (PostgreSQL)

> **Status:** Design approved by the project owner. No application code exists yet. The API design added amendments API-1 to API-6, and the class design added CLS-1 to CLS-8, all in [section 14](#14-amendments-from-the-api-design). Where they differ from an earlier section, section 14 wins.
>
> **Verification status:**
> - **The DDL, constraints, lock behavior and query plans were verified on PostgreSQL 18.6** in a throwaway container. Section 13 has the results and what was not covered.
> - **All performance statements are still predictions** until the data generator and load tests exist. The plan checks show which indexes are used, and they aren't benchmarks.

This document turns the draft data model into the final Phase 1 design. It is driven by the access patterns (section 6 of `ARCHITECTURE.md`) and the non-functional requirements (section 5). The decision IDs (D-numbers) refer to the log in section 10 of `ARCHITECTURE.md`.

**Target version:** PostgreSQL 18.

## Contents

1. [Design summary](#1-design-summary)
2. [Conventions](#2-conventions)
3. [Schema](#3-schema)
4. [Indexes](#4-indexes)
5. [Access pattern map](#5-access-pattern-map)
6. [Transactions and races](#6-transactions-and-races)
7. [Leaderboard queries](#7-leaderboard-queries)
8. [Scheduled jobs](#8-scheduled-jobs)
9. [Milestone: async scoring via Outbox + queue (deferred)](#9-milestone-async-scoring-via-outbox--queue-deferred)
10. [Flyway migrations](#10-flyway-migrations)
11. [Validation plan](#11-validation-plan)
12. [Decisions on identifiers and overlaps](#12-decisions-on-identifiers-and-overlaps)
13. [Verification results](#13-verification-results)
14. [Amendments from the API design](#14-amendments-from-the-api-design)

---

## 1. Design summary

| Topic | Decision |
|---|---|
| Upload | GPX is parsed in the API. One transaction inserts the run and updates scores. The response is 201 |
| Scoring | Recalculated from all eligible runs, never incremented |
| Eligibility | The run started inside the window **and** was received before `closes_at` |
| Grace period | 6 hours by default, configurable, 0 allowed |
| Joining | Runs already inside the window count (backfill) |
| Isolation | `READ COMMITTED`, plus constraints and explicit row locks |
| Account deletion | Two phases: immediate wipe and read-time filter, then physical purge |
| Leaderboards | Plain SQL over one partial index. No Redis until measured |
| Outbox and queue | Designed here but deferred until baseline measurements exist |

---

## 2. Conventions

| Type | Used for | Why | Rejected |
|---|---|---|---|
| `uuid` with `uuidv7()` | Primary keys | See section 12 | `bigint`, UUIDv4 |
| `timestamptz` | All times | Represents an exact moment, whatever the time zone | `timestamp`, which has no zone |
| `integer` | Meters, seconds | No floating-point rounding, and it allows over 2 million km | `numeric`, `double precision` |
| `text` + `CHECK` | Constrained values | A `CHECK` is easy to change in a migration | PostgreSQL enums, where removing a value is hard. `varchar(n)`, which has no advantage over `text` with a length check |
| `bytea` | SHA-256 hashes | 32 bytes, versus 64 for hex text | Hex `text` |

**Names:** tables are plural snake_case. Named constraints and indexes use the prefixes `uq_`, `ix_`, `ck_` and `ex_`. Primary and foreign keys keep PostgreSQL's default names (such as `runs_pkey` and `runs_user_id_fkey`), which are already predictable. A `fk_` prefix would only be needed if we ever had to tell two foreign keys apart by intent.

---

## 3. Schema

### 3.1 `users`

```sql
CREATE TABLE users (
    id             uuid PRIMARY KEY DEFAULT uuidv7(),
    email          text,
    password_hash  text,
    display_name   text CONSTRAINT ck_users_display_name CHECK (char_length(display_name) BETWEEN 1 AND 50),
    birth_date     date,
    city           text,
    photo_key      text,
    run_privacy    text NOT NULL DEFAULT 'private'
                   CONSTRAINT ck_users_run_privacy CHECK (run_privacy IN ('private', 'friends', 'public')),
    time_zone      text NOT NULL DEFAULT 'UTC',
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    deleted_at     timestamptz,
    CONSTRAINT ck_users_active_has_identity CHECK (
        deleted_at IS NOT NULL
        OR (email IS NOT NULL AND password_hash IS NOT NULL AND display_name IS NOT NULL)
    ),
    CONSTRAINT ck_users_deleted_has_no_identity CHECK (
        deleted_at IS NULL
        OR (email IS NULL AND password_hash IS NULL AND display_name IS NULL
            AND birth_date IS NULL AND city IS NULL AND photo_key IS NULL)
    )
);
CREATE UNIQUE INDEX uq_users_email_lower ON users (lower(email));
CREATE INDEX ix_users_deleted ON users (id) WHERE deleted_at IS NOT NULL;
```

- **`lower(email)`:** an expression index gives case-insensitive uniqueness. `citext` would also work, but it adds an extension for one column.
- **`time_zone`:** "this week" in R4 depends on where the user lives.
- **`run_privacy` defaults to `private`:** a user should opt in to sharing, not opt out. See section 7.4 for how this interacts with public competitions.
- **The two `CHECK` constraints:** an active user must have an identity, and a deleted user must have none. The database therefore guarantees the personal-data wipe, instead of relying on application code.

### 3.2 `runs`

```sql
CREATE TABLE runs (
    id             uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id        uuid NOT NULL REFERENCES users ON DELETE CASCADE,
    source         text NOT NULL DEFAULT 'gpx_upload' CONSTRAINT ck_runs_source CHECK (source IN ('gpx_upload')),
    started_at     timestamptz NOT NULL,
    ended_at       timestamptz NOT NULL,
    distance_m     integer NOT NULL CONSTRAINT ck_runs_distance CHECK (distance_m > 0),
    duration_s     integer NOT NULL CONSTRAINT ck_runs_duration CHECK (duration_s BETWEEN 1 AND 604800),
    pace_s_per_km  integer GENERATED ALWAYS AS (round(duration_s * 1000.0 / NULLIF(distance_m, 0))::integer) STORED,
    file_key       text NOT NULL,
    file_hash      bytea NOT NULL CONSTRAINT ck_runs_file_hash CHECK (octet_length(file_hash) = 32),
    status         text NOT NULL CONSTRAINT ck_runs_status CHECK (status IN ('valid', 'invalid')),
    invalid_reason text,
    received_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_runs_time_order CHECK (ended_at > started_at),
    CONSTRAINT ck_runs_invalid_reason CHECK ((status = 'invalid') = (invalid_reason IS NOT NULL)),
    CONSTRAINT uq_runs_user_file_hash UNIQUE (user_id, file_hash),
    CONSTRAINT ex_runs_no_overlap EXCLUDE USING gist (
        user_id WITH =,
        tstzrange(started_at, ended_at, '[)') WITH &&
    ) WHERE (status = 'valid')
);
CREATE INDEX ix_runs_user_started ON runs (user_id, started_at DESC, id DESC);
```

- **No `pending` status:** parsing happens before the insert, so every stored run has its metrics. This removes nullable metric columns and a whole class of half-finished states.
- **`source`:** keeps the adapter abstraction from D11 visible in the data.
- **`pace_s_per_km` is generated:** the database calculates it, so it can't disagree with distance and duration. Whole seconds also make equal displayed paces a real tie (D15). PostgreSQL calculates generated columns **before** checking constraints, so `NULLIF` is needed: without it, a distance of 0 fails with a division-by-zero error (`22012`) instead of `ck_runs_distance`.
- **`duration_s`:** elapsed time in Phase 1. Moving time stays with open question 6. The 7-day limit (604,800 s, D36) keeps the pace within `integer`, even at 1 m. It is a schema-level backstop against generated-column overflow, not a product rule, and the API design will define stricter plausibility thresholds. **The API must reject out-of-range values before the insert.** A database error is only a backstop, and durations of roughly 25 days or more at 1 m overflow the pace with `22003` before the `CHECK` runs.
- **`received_at`:** uses the database clock, so all closure comparisons use one clock. `now()` returns the transaction's start time, slightly after the true arrival because parsing and file storage come first.
- **Route geometry:** deliberately absent, because open question 9 is undecided. A later migration can add it.

**What happens to each kind of upload:**

| Upload | Result | Row stored? | File in object storage? |
|---|---|---|---|
| Malformed or oversized, distance under 1 m, or duration over 7 days | Rejected | No | No, rejected before storage |
| `started_at` or `ended_at` in the future, or `started_at` older than 30 days (configurable) | Rejected | No | No, rejected before storage |
| Duplicate caught by the quick check | Returns the existing run | Existing row | No new file |
| Duplicate that gets past the quick check (concurrent upload) | Returns the existing run | Existing row | Yes, becomes an orphan |
| Overlaps a valid run, rejected at insert | 409 | No | Yes, becomes an orphan |
| Well-formed but implausible | 201 with `status = 'invalid'` and a reason. Never scored | Yes | Yes |
| Valid | 201 and scored | Yes | Yes |

The file is stored **before** the transaction commits, so files rejected at insert remain as orphans until the daily job removes them (section 8.3).

Runs can't be invalidated manually in Phase 1. Rejection is automatic only, so a run's status never changes after insert. Starting plausibility thresholds are in `docs/design/api.md` (D49). Tuning them, and moving versus elapsed time, remain in open question 6.

The 30-day limit also blocks importing older history. **"History import without scoring" is a Phase 2 backlog item** (section 12 of `ARCHITECTURE.md`).

### 3.3 `competitions`

```sql
CREATE TABLE competitions (
    id             uuid PRIMARY KEY DEFAULT uuidv7(),
    creator_id     uuid REFERENCES users ON DELETE SET NULL,
    group_id       uuid REFERENCES groups ON DELETE SET NULL,
    name           text NOT NULL CONSTRAINT ck_competitions_name CHECK (char_length(name) BETWEEN 1 AND 100),
    city           text,
    rule_type      text NOT NULL CONSTRAINT ck_competitions_rule_type
                   CHECK (rule_type IN ('total_distance', 'longest_run', 'fastest_pace')),
    min_distance_m integer CONSTRAINT ck_competitions_min_distance CHECK (min_distance_m > 0),
    visibility     text NOT NULL CONSTRAINT ck_competitions_visibility CHECK (visibility IN ('private', 'public')),
    starts_at      timestamptz NOT NULL,
    ends_at        timestamptz NOT NULL,
    closes_at      timestamptz NOT NULL,
    closed_at      timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_competitions_window CHECK (ends_at > starts_at),
    CONSTRAINT ck_competitions_closes CHECK (closes_at >= ends_at),
    CONSTRAINT ck_competitions_closed CHECK (closed_at IS NULL OR closed_at >= closes_at),
    CONSTRAINT ck_competitions_rule_params CHECK ((rule_type = 'fastest_pace') = (min_distance_m IS NOT NULL))
);
CREATE INDEX ix_competitions_to_close ON competitions (closes_at) WHERE closed_at IS NULL;
CREATE INDEX ix_competitions_group ON competitions (group_id) WHERE group_id IS NOT NULL;
```

- **`min_distance_m` replaces `rule_params` jsonb:** with one parameter, a real column gets type checks and constraints. Phase 2 can add columns or jsonb when it has a need.
- **`closes_at` holds the grace period:** `closes_at = ends_at + grace`, so there is one source of truth. The API accepts a grace period (default 6 hours, 0 allowed) and calculates this value.
- **`closed_at` replaces `status`:** a separate status could disagree with the timestamps.

The phase of a competition comes from its times:

| Phase | Condition | Meaning |
|---|---|---|
| Upcoming | `now() < starts_at` | Users can join and leave |
| Running | `starts_at <= now() < ends_at` | Users can join and leave, and runs count |
| **Finalizing** | `ends_at <= now()` and `closed_at IS NULL` | Late uploads still count. Nobody can join or leave. **The UI must show this state**, so that users know the results can still change |
| Closed | `closed_at IS NOT NULL` | The result is final |

### 3.4 `competition_participants`

```sql
CREATE TABLE competition_participants (
    competition_id   uuid NOT NULL REFERENCES competitions ON DELETE CASCADE,
    user_id          uuid NOT NULL REFERENCES users ON DELETE CASCADE,
    score            integer,
    score_updated_at timestamptz,
    joined_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (competition_id, user_id)
);
CREATE INDEX ix_participants_leaderboard ON competition_participants (competition_id, score, user_id)
    WHERE score IS NOT NULL;
CREATE INDEX ix_participants_user ON competition_participants (user_id, competition_id);
```

- **`score` is `NULL` until a run is eligible:** in `fastest_pace`, 0 would mean a perfect pace. `NULL` means unranked.
- **Units:** meters for distance rules, seconds per km for `fastest_pace`, where lower is better.
- **`score_run_id` was dropped:** no access pattern reads it, and its foreign key would need another index. We can add it if a "best run" link is requested.
- **`score_updated_at`:** useful for debugging and for measuring freshness.
- **No separate results table:** after closure, these scores are the final result. Ranks are calculated on read, because D17 accepts rank shifts, so a stored rank snapshot would soon be wrong. A database trigger guarding closed scores was rejected, because it hides logic and the locks in section 6 already enforce this.

### 3.5 Social tables

```sql
CREATE TABLE friendships (
    user_a       uuid NOT NULL REFERENCES users ON DELETE CASCADE,
    user_b       uuid NOT NULL REFERENCES users ON DELETE CASCADE,
    requested_by uuid NOT NULL,
    status       text NOT NULL CONSTRAINT ck_friendships_status CHECK (status IN ('pending', 'accepted')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    accepted_at  timestamptz,
    PRIMARY KEY (user_a, user_b),
    CONSTRAINT ck_friendships_order CHECK (user_a < user_b),
    CONSTRAINT ck_friendships_requester CHECK (requested_by IN (user_a, user_b)),
    CONSTRAINT ck_friendships_accepted CHECK ((status = 'accepted') = (accepted_at IS NOT NULL))
);
CREATE INDEX ix_friendships_user_b ON friendships (user_b, user_a);

CREATE TABLE groups (
    id         uuid PRIMARY KEY DEFAULT uuidv7(),
    name       text NOT NULL CONSTRAINT ck_groups_name CHECK (char_length(name) BETWEEN 1 AND 100),
    visibility text NOT NULL CONSTRAINT ck_groups_visibility CHECK (visibility IN ('public', 'private')),
    city       text,
    created_by uuid REFERENCES users ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE group_members (
    group_id  uuid NOT NULL REFERENCES groups ON DELETE CASCADE,
    user_id   uuid NOT NULL REFERENCES users ON DELETE CASCADE,
    role      text NOT NULL CONSTRAINT ck_group_members_role CHECK (role IN ('admin', 'member')),
    joined_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (group_id, user_id)
);
CREATE INDEX ix_group_members_user ON group_members (user_id, group_id);

CREATE TABLE group_invitations (
    group_id   uuid NOT NULL REFERENCES groups ON DELETE CASCADE,
    invitee_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
    invited_by uuid NOT NULL REFERENCES users ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (group_id, invitee_id)
);
CREATE INDEX ix_group_invitations_invitee ON group_invitations (invitee_id);

CREATE TABLE competition_invitations (
    competition_id uuid NOT NULL REFERENCES competitions ON DELETE CASCADE,
    invitee_id     uuid NOT NULL REFERENCES users ON DELETE CASCADE,
    invited_by     uuid NOT NULL REFERENCES users ON DELETE CASCADE,
    created_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (competition_id, invitee_id)
);
CREATE INDEX ix_competition_invitations_invitee ON competition_invitations (invitee_id);
```

- **Friendships:** declining or removing a friend deletes the row. If both people send a request at once, the primary key collides, and we treat that as acceptance.
- **Mirrored friendship rows were rejected:** two rows per pair make reads simpler, but the rows can drift apart.
- **Private groups are invitation-only in Phase 1.** There are no join requests and no invite links. A public group or public competition needs no invitation.
- **Accepting an invitation:** one transaction deletes the invitation and inserts the membership.
- **Two invitation tables:** a single table pointing at two different parents can't have a real foreign key.
- **Private competition in a group:** group members may join without an invitation.

### 3.6 Module boundaries

Keep one schema. Foreign keys to `users` are allowed. Writes always go through the module that owns the table. These read-only exceptions are documented:

| Reader | Reads | Why |
|---|---|---|
| `leaderboards` | `competition_participants`, `competitions`, `users` | Ranking needs joins and a read-time filter |
| `competitions` | `runs` | Score recalculation aggregates a user's runs |
| `competitions` | `users` | The participant count and list must hide deleted users (added by CLS-1) |
| `platform` | Lock statements on `users`, `groups`, `competitions`, `competition_participants` | One place holds every row lock and enforces the lock order (added by CLS-1) |

**Rejected:** strict isolation with API calls and copied data. It would add sync bugs we have no measured reason to accept. **The cost:** a future service split would have to replace these joins, and this list keeps that cost visible.

---

## 4. Indexes

A **HOT update** changes a row without touching its indexes. It only applies when no indexed column changes, including columns in a partial index's condition. A score change touches `ix_participants_leaderboard`, so it can't be HOT, and every index on the table gets a new entry. Each write cost below is small at about 860 runs per day. The costs show what would matter if volume grew.

| Index | Serves | Write cost |
|---|---|---|
| `sessions` PK, `ix_sessions_user` (API-1) | R1, revoking sessions | Low. Renewals change no indexed column, so they can be HOT when the page has room |
| `users` PK | R1, joins | Low |
| `uq_users_email_lower` | W6, login | Low, rarely changes |
| `ix_users_deleted` | R2 filter, W6 sweeper | Almost none, nearly empty |
| `runs` PK | R3 (single run), foreign keys | Low. UUIDv7 inserts stay near the right edge of the index |
| `uq_runs_user_file_hash` | W1 duplicates, orphan job | Low |
| `ix_runs_user_started` | R3, R4, W1 and W3 recalculation, W6 cascade | Low |
| `ex_runs_no_overlap` (GiST) | W1 overlaps | Highest per insert on this table, acceptable at this volume |
| `competitions` PK | R2, R5, W1 and W3 locks | Low |
| `ix_competitions_to_close` | W4 scheduler, W1 competition lookup | Tiny, only open competitions |
| `ix_competitions_group` | Listing a group's competitions, `SET NULL` on group delete (W5) | Low |
| `competition_participants` PK | R5, W1, W3, my score in R2 | New entry per score change (not HOT) |
| `ix_participants_leaderboard` | R2 | Old entry replaced per score change |
| `ix_participants_user` | R6, W1 competition lookup, W6 cascade | New entry per score change (not HOT) |
| `friendships` PK, `ix_friendships_user_b` | R7, W5, W6 | Low |
| `group_members` PK, `ix_group_members_user` | R7, W5, W6 | Low |
| Invitation PKs and `invitee` indexes | W3, W5, W6 | Low |

**Deliberately not indexed yet:**

| Candidate | Why not now | When to add it |
|---|---|---|
| Search index (`pg_trgm` GIN), which supports matching inside words | With only thousands of public rows, a sequential scan (reading the whole table) may meet 500 ms | R8 p95 > 500 ms |
| `competitions.creator_id`, `groups.created_by`, invitation `invited_by` | Only the background purge needs them, over small tables | The purge becomes measurably slow |
| Precomputed stats (R4) | A user has only a few hundred runs | R4 p95 > 300 ms |

---

## 5. Access pattern map

| Pattern | Operation | Served by |
|---|---|---|
| R1 | Authenticate request | `sessions` PK and `users` PK, with a `deleted_at IS NULL` check (API-1, section 14.1) |
| R2 | Leaderboard | `ix_participants_leaderboard`, `competition_participants` PK, `ix_users_deleted`, `users` PK |
| R3 | Run history | `ix_runs_user_started`, with keyset pagination (section 7.5) |
| R4 | My stats | `ix_runs_user_started`, `users.time_zone`, `runs` metrics |
| R5 | Competition details and participants | `competitions` PK, `competition_participants` PK |
| R6 | My competitions | `ix_participants_user`, `competitions` PK |
| R7 | Friends and group members | `friendships` PK, `ix_friendships_user_b`, `group_members` PK, `ix_group_members_user` |
| R8 | Search public groups and competitions | `groups`, `competitions` `name` and `city`, by sequential scan until measured |
| W1 | Upload run | `runs` and its constraints, `ix_participants_user`, `ix_competitions_to_close`, `competitions` PK, `competition_participants` PK |
| W2 | Update scores | Runs inside W1's transaction. `ix_runs_user_started` and `competition_participants` PK |
| W3 | Create, join, leave | `competitions`, `competition_participants`, `competition_invitations`, `ix_runs_user_started` |
| W4 | Close competition | `ix_competitions_to_close`, `competitions.closed_at` |
| W5 | Friend and group actions | `friendships`, `groups`, `group_members`, `group_invitations` |
| W6 | Registration, profile, deletion | `users`, `uq_users_email_lower`, `ix_users_deleted`, cascading foreign keys |

The section 11 draft entities map as follows: `users`, `runs`, `competitions`, `competition_participants`, `friendships`, `groups` and `group_members` are all in section 3. `outbox_events` moved to the deferred milestone in section 9.

---

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

### 6.6 Account deletion (W6, D17, D29)

> **Amended by API-4 (section 14.4):** this transaction also deletes the user's sessions.
>
> **Amended by CLS-2 and CLS-7 (section 14.8):** groups are locked in ascending ID order, and an invitation from a deleted inviter is hidden until the purge removes it.

**Phase 1: one quick transaction.**
1. Update the user row: set `deleted_at`, and set the email, password hash, name, birth date, city and photo key to `NULL`. This takes a write lock, so it waits for that user's in-flight ingests.
2. Delete friendships, group memberships and invitations.
3. For each group where the user was the last admin, promote the longest-standing member, or delete the group if it's empty. Lock the group row while doing this.

The email becomes free immediately, and this step can't be undone. The user vanishes from leaderboards at once, through the read-time filter. The authentication design must also reject the user's sessions.

**Phase 2: the sweeper (section 8.2)** deletes files and then the user row, which cascades to runs, scores and remaining references.

**Why a sweeper rather than an event:** the user row is already a durable to-do item, and this keeps a privacy requirement independent of any queue.

| Race | What happens |
|---|---|
| Upload in progress during deletion | The upload holds `FOR SHARE`, so deletion waits. The run then gets purged normally |
| Upload starts just after deletion | Its user lock finds `deleted_at` set, and the upload is refused |
| Join during deletion | Same protection, using the user lock |
| A file stored after the purge | The orphan job removes it, because no matching run exists |
| Failure halfway through the purge | The user row survives as a retry marker, because files are deleted first and the deletions can be repeated |

**Consequences to accept:**
- Ranks in closed competitions can shift, as D17 already accepts.
- Scores are physically removed, unlike the original D17.
- **Data remains in backups until they expire.** Keep backups for a documented period, proposed at 30 days. Restoring one would require running the sweeper again for users deleted after that backup was taken.

---

## 7. Leaderboard queries

### 7.1 Top N

`RANK()` gives tied rows the same rank and skips the following ranks (1, 1, 3), as D15 requires.

```sql
SELECT p.user_id, u.display_name, p.score,
       RANK() OVER (ORDER BY p.score DESC) AS rank
FROM competition_participants p
JOIN users u ON u.id = p.user_id AND u.deleted_at IS NULL
WHERE p.competition_id = $1 AND p.score IS NOT NULL
ORDER BY p.score DESC, p.user_id DESC
LIMIT $2;
```

- **Observed plan (section 13):** `Limit -> Incremental Sort -> WindowAgg -> Nested Loop -> Index Only Scan Backward using ix_participants_leaderboard`. For top 10 of 5,000, it read 11 index rows, because the index already provides the score order and a rank only depends on the rows before it. The small `Incremental Sort` only applies the `user_id` tie-break within equal scores. A long run of tied scores would make it read further, because it must read a whole tied group.
- **`fastest_pace`:** lower is better, so it uses `ASC` on both `ORDER BY` clauses and a forward scan. The Strategy picks the direction.
- **One index for both directions:** a B-tree can be read either way. The partial condition removes `NULL` ordering problems.
- **Tie-breaking by `user_id`:** only makes the list order stable. It doesn't change anyone's rank.
- **Filtering:** deleted users are removed before ranking, so ranks close up automatically (D17).

### 7.2 My rank

First read my score by `(competition_id, user_id)`. The planner may use the primary key or `ix_participants_user`, and either is fine. If the score is `NULL`, I'm unranked. Otherwise:

```sql
SELECT count(*) + 1 AS rank
FROM competition_participants p
WHERE p.competition_id = $1
  AND p.score > $my_score                 -- '<' for fastest_pace
  AND NOT EXISTS (
      SELECT 1 FROM users d
      WHERE d.id = p.user_id AND d.deleted_at IS NOT NULL
  );
```

- **Ties:** counting strictly better scores gives the same result as `RANK()`.
- **Cost:** it reads every better participant, so up to 5,000 index entries in the worst case. This is the query most likely to justify Redis, so we measure it directly.
- **Why `NOT EXISTS`:** deleted rows are purged quickly, so that set is nearly empty and much cheaper than joining all users. The observed plan is a hash anti join over `ix_users_deleted`.
- **Index-only scan:** observed on a freshly vacuumed sample with no heap fetches. Vacuum (PostgreSQL's cleanup of old row versions) won't always have caught up on a busy table, so real runs may need heap fetches. The load test must measure this.

**Rejected:**

| Alternative | Why |
|---|---|
| Rank everyone with a window function, then filter | Always does the worst-case work |
| Stored `rank` column | One score change could rewrite thousands of rows |
| Redis sorted set now | Not justified until measured (D8) |

### 7.3 Consistency

Top N and my rank can be separate statements, and may differ for an instant. That fits the agreed eventual consistency for leaderboard reads, so neither needs a stronger isolation level or a read lock.

### 7.4 Public competitions and privacy (D16)

Anyone can view the top N of a public competition, with the display name and metric only. **Joining a public competition is consent to appear there, even with `run_privacy = 'private'`, and the join UI must say so explicitly.** `run_privacy` continues to control the runs themselves, and routes are never shown on leaderboards.

### 7.5 Run history (R3)

Keyset pagination continues from the last row seen, rather than counting past rows as `OFFSET` does:

```sql
SELECT id, started_at, distance_m, duration_s, pace_s_per_km, status
FROM runs
WHERE user_id = $1 AND (started_at, id) < ($last_started_at, $last_id)
ORDER BY started_at DESC, id DESC
LIMIT 20;
```

`id` is included because invalid runs can share a `started_at`. **`OFFSET` was rejected** because it gets slower on deeper pages and can skip or repeat rows when new runs arrive.

---

## 8. Scheduled jobs

Jobs run **inside the application process** for now, so there is no need for a separate worker until the queue milestone. They must stay safe with several application instances.

### 8.1 Competition closure

Runs each minute, as described in section 6.5.

### 8.2 Account purge

Runs each minute, and loops up to a configured batch per tick (CLS-3). API-4 (section 14.4) widens the photo deletion to a prefix:
```sql
SELECT id FROM users WHERE deleted_at IS NOT NULL
LIMIT 1 FOR UPDATE SKIP LOCKED;
```
`SKIP LOCKED` makes instances skip rows another instance is already working on. Then, in order: delete objects under `runs/{user_id}/` and the profile photo, then `DELETE FROM users WHERE id = $1`, then commit.

### 8.3 Orphan-file cleanup

Runs daily. For each object older than 1 day, read the user and hash from its key, then look up `(user_id, file_hash)`. If there's no row, or the row's `file_key` differs, delete the object.

**This job takes no lock.** It works on objects rather than rows, and deleting an object twice is harmless. Age and the per-attempt key keep in-flight uploads safe (section 6.3).

---

## 9. Milestone: async scoring via Outbox + queue (deferred)

**Status:** designed, not part of the initial schema.

**Trigger:** introduce this only after baseline load-test measurements exist, and measure before and after. D9 (queue technology) remains OPEN. This design works with any choice.

**Why deferred:** synchronous scoring is simpler and more strongly consistent, and it gives a baseline. Async processing should show its benefit against that baseline, not by intuition. It remains valuable as a learning goal.

### 9.1 Outbox pattern

The **Outbox pattern** writes an event in the same transaction as the data, and a separate relay publishes it later. A commit can't succeed while its event is lost.

```sql
CREATE TABLE outbox_events (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_type    text NOT NULL,
    event_version smallint NOT NULL DEFAULT 1,
    aggregate_id  uuid NOT NULL,
    payload       jsonb NOT NULL,
    request_id    text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    published_at  timestamptz
);
CREATE INDEX ix_outbox_unpublished ON outbox_events (id) WHERE published_at IS NULL;
```

- **`bigint` is an exception to D24:** these IDs are never exposed, and a smaller key suits a high-churn table.
- **`request_id`:** carries the observability requirement across the async step.
- **The payload holds IDs only:** personal data must not outlive account deletion.
- **Index cost:** small, but it churns constantly. Watch for bloat (dead space left by updates and deletes).

### 9.2 Relay

Poll each second:
```sql
SELECT ... FROM outbox_events
WHERE published_at IS NULL
ORDER BY id LIMIT 100
FOR UPDATE SKIP LOCKED;
-- publish, then UPDATE published_at, then COMMIT
```

- **Delivery:** at least once. A crash between publishing and marking causes a repeat, and recalculation makes repeats harmless.
- **Ordering:** approximate, since IDs can commit out of order. Scoring doesn't depend on order.
- **Retention:** a daily job deletes published rows older than 7 days. Partitioning isn't justified.

**Rejected:**

| Alternative | Why |
|---|---|
| Debezium, which reads the database's change log | Powerful, but too much to operate at this scale |
| `LISTEN/NOTIFY` alone | Missed notifications are lost. It can be added later as a wake-up signal |

### 9.3 Changes when this milestone is built

**Schema, in a new migration:**
- Add `outbox_events`.
- Add `runs.scored_at timestamptz`, setting it for all existing valid runs in the same migration, since they are already scored.
- Add `CREATE INDEX ix_runs_unscored ON runs (received_at) WHERE status = 'valid' AND scored_at IS NULL`.

**Ingest:** the run and a `RunAccepted` event commit together. The run still exists at commit, so the response can stay 201, although its scores update shortly afterward. Freshness is then held to the 30-second target.

**Worker, one transaction per message:**
1. Load the run, and acknowledge the message if the run no longer exists.
2. Run the same scoring steps as section 6.3 (step 4 onward).
3. Set `scored_at` and commit. A crash rolls back, and the message is delivered again.

**Closure must recalculate, never abort.** Under its `FOR UPDATE` lock, closure recalculates scores for participants who have unscored eligible runs, and only then sets `closed_at`. **A stuck message can therefore never block closure forever.** A late duplicate message finds the competition closed and skips it.

**The per-user lock stays:** the join race in section 6.4 still exists with a worker.

**Alert:** on the age of the oldest unscored run.

**Then measure again.** Compare upload latency, freshness and failure behavior against the baseline, and record the result as an ADR.

---

## 10. Flyway migrations

**Dependency note:** PostgreSQL support may require a separate module in Flyway 10+ (`flyway-database-postgresql`). **Verify this when adding the dependency.**

### 10.1 Naming

- Versioned files: `V0001__enable_extensions.sql`, in `db/migration`.
- **Sequential numbers:** simple for one developer. Switch to timestamps if parallel branches start colliding.

### 10.2 Rules

- **Never edit an applied migration.** Flyway checksums would fail, and environments would drift apart.
- **Forward-only.** Undo migrations are, to our knowledge, a paid feature. A bad change gets a new migration, or a backup restore.
- **Keep seed and synthetic data out of migrations.**
- **Use separate roles:** a migration role owns the schema, and the application role has no DDL rights.
- **Disable `flyway clean` outside local development.**

### 10.3 Safe changes

- **Expand, then contract:** add the new form, move the code, and remove the old form in a later migration.
- **Large tables:** use `CREATE INDEX CONCURRENTLY` in a non-transactional migration, and `ADD CONSTRAINT ... NOT VALID` followed by `VALIDATE`.
- **`lock_timeout`:** set it so a migration fails instead of blocking the app.

At our scale this is mostly practice, because a short lock is harmless with so little traffic. It's worth learning, but not worth slowing down early development.

### 10.4 Initial order

1. `V0001__enable_extensions.sql` (`btree_gist`)
2. `V0002__create_users.sql`
3. `V0003__create_social_tables.sql`
4. `V0004__create_runs.sql`
5. `V0005__create_competitions.sql` (including participants)
6. `V0006__create_invitations.sql`
7. `V0007__create_sessions.sql` (API-1, section 14.1)
8. `V0008__add_city_length_checks.sql` (API-5, section 14.5)

---

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

## 12. Decisions on identifiers and overlaps

### 12.1 D24: UUIDv7

- **Why UUID:** IDs in URLs can't be counted through, and they make a future service split easier. Authorization must still protect every resource, since an ID is not a secret.
- **Why v7 over v4:** v7 starts with a timestamp, so new keys land near each other in the index. Random v4 keys spread writes across the index, causing more page splits and less caching.
- **Honest scale note:** the difference barely matters at 860 runs per day. It wins because it costs nothing, with `uuidv7()` built into version 18.
- **Downside:** an ID reveals its creation time. Public API responses should avoid exposing user IDs where not needed, which the API design will settle.
- **Rejected:** `bigint`, which is smaller, but can be guessed and is awkward to generate outside the database.
- **Learning experiment:** compare v4 and v7 index size and insert speed at 3 million rows.

### 12.2 D25: Overlap exclusion constraint

An **exclusion constraint** is like `UNIQUE`, but it rejects rows that conflict by a rule, here "overlapping times for the same user".

- **Valid runs only:** an invalid run can't block a legitimate one.
- **Why in the database:** "check, then insert" in the application has a race, since two uploads can both pass the check. Only the database can decide this atomically.
- **Boundaries:** ranges are half-open (`[)`), so one run can end exactly when the next starts.
- **Cost:** a GiST index (a tree that supports overlap searches), and the `btree_gist` extension to include `uuid` equality in it.
- **Rejected:** an application-only check, because of that race.

---

## 13. Verification results

**Environment:** PostgreSQL 18.6 (`postgres:18-alpine`) in a throwaway container, since removed. The DDL was extracted directly from section 3 of this document, so the test covered this text and not a separate copy. The scripts and the steps to reproduce the run are in [verification/](verification/README.md).

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

## 14. Amendments from the API design

**Status:** approved with the API design plan. [`docs/design/api.md`](api.md) has the reasoning. Migration files don't exist yet, since there is no application code. The SQL below was applied to a real server, and section 14.7 has the results.

### 14.1 API-1: `sessions` table

Sessions are opaque random tokens, and only their SHA-256 hash is stored (D43).

```sql
-- V0007__create_sessions.sql
CREATE TABLE sessions (
    token_hash bytea PRIMARY KEY
               CONSTRAINT ck_sessions_token_hash CHECK (octet_length(token_hash) = 32),
    user_id    uuid NOT NULL REFERENCES users ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL
);
CREATE INDEX ix_sessions_user ON sessions (user_id);
```

**Lookup on every request (R1):**
```sql
SELECT s.user_id, s.created_at, s.expires_at
FROM sessions s
JOIN users u ON u.id = s.user_id AND u.deleted_at IS NULL
WHERE s.token_hash = $1 AND s.expires_at > now();
```

**Renewal, at most hourly, so ordinary reads don't write:**
```sql
UPDATE sessions
SET expires_at = LEAST(now() + interval '30 days', created_at + interval '90 days')
WHERE token_hash = $1
  AND expires_at < LEAST(now() + interval '30 days', created_at + interval '90 days') - interval '1 hour';
```

- **Why the join stays,** even though account deletion removes sessions: a login that passed its password check just before the deletion can insert a session just after it. The foreign key doesn't stop this, because the user row still exists until the purge. The join makes that session useless.
- **No index on `expires_at`:** the daily cleanup can scan this small table. An index would make every renewal write to the indexes. Without one, a renewal **can** be a HOT update when its page has free space, as section 14.7 shows. It isn't guaranteed. At one renewal per hour per session, the difference is small either way.
- **No `id`, device name or last-seen:** no endpoint needs them yet. Listing sessions can add them later.
- **`ix_sessions_user`:** revoking all sessions (password change, account deletion) and the foreign-key cascade.
- **Rejected:** storing tokens in plain text. A database leak must not give an attacker working sessions.

**Rate-limit state, password-reset tokens and idempotency keys get no tables.** Rate limits live in memory (D53), email flows are deferred (D50), and no `Idempotency-Key` exists (D56).

### 14.2 API-2: duplicate check before parsing (changes section 6.3)

**New order outside the transaction:**
1. Check type and declared size. Spool to a temp file, counting bytes and hashing.
2. **Quick-check `(user_id, file_hash)`. If found, return the existing run.**
3. Parse securely and compute metrics.
4. Reject out-of-range values and bad timestamps. Classify plausibility.
5. Store the file.

**Defect this fixes:** with the old order, a client retrying an accepted upload after its `started_at` passed the 30-day limit got "too old" rather than its own run, which breaks the retry promise. A retry also now avoids parsing again. The check is scoped by `user_id`, so it reveals nothing about other users. The table in section 3.2 still describes the outcomes.

### 14.3 API-3: already-participant check first (changes section 6.4)

Under the user and competition locks, the join first reads `(competition_id, user_id)`. **If the row exists, it returns success**, before the permission, `ends_at` and limit checks.

**Defect this fixes:** with the old order, a double-click on the join that reaches the limit of 10 refuses the second click, because it counts the row the first click just added. Section 6.4 says a double-click succeeds, and the steps as written didn't deliver that. A retry after `ends_at` had the same problem. `ON CONFLICT DO NOTHING` stays as the backstop.

### 14.4 API-4: sessions and photos on deletion (changes sections 6.6 and 8)

- **Section 6.6, phase 1, added step:** `DELETE FROM sessions WHERE user_id = $1`, in the same transaction. This makes revocation immediate.
- **Section 8.2 purge:** delete the `photos/{user_id}/` prefix, not only the key in `photo_key`. A crash between storing a new photo and deleting the old one would otherwise leave a photo behind, and photos are personal data.
- **New daily job:** `DELETE FROM sessions WHERE expires_at < now()`. It takes no explicit lock, and repeating it is harmless.

### 14.5 API-5: city length backstop

```sql
-- V0008__add_city_length_checks.sql
ALTER TABLE users ADD CONSTRAINT ck_users_city CHECK (char_length(city) <= 100);
ALTER TABLE groups ADD CONSTRAINT ck_groups_city CHECK (char_length(city) <= 100);
ALTER TABLE competitions ADD CONSTRAINT ck_competitions_city CHECK (char_length(city) <= 100);
```

The API validates this first, so these constraints should never fire. They exist because these columns are otherwise unbounded, unlike the other text fields a user can set.

### 14.6 API-6: group and competition lifecycle transactions

The API adds transactions that section 6 didn't specify. Lock order extends D33: **user, then group, then competitions sorted by ID, then participants.**

**Group role change, kick and leave:**
1. Lock the group row `FOR UPDATE`. Return 404 if it's gone.
2. Check the caller's role, and read the admin count.
3. Refuse with `last_admin` if an admin demotion or kick would leave no admin. If the last admin leaves, promote the longest-standing member, or delete the group if it's now empty, matching section 6.6.

**Why the lock:** without it, two admins demoting each other at once both see two admins, both proceed, and the group has none. This is **write skew**: each transaction is correct alone, but together they break a rule that neither row holds by itself.

**Create competition:** in one transaction, lock the user row `FOR NO KEY UPDATE`, check the limit of 10 open competitions, insert the competition, then insert the participant and backfill the score (section 6.4, step 5). With `group_id`, lock the group `FOR SHARE` and check that the caller is an admin. Nobody else can see the new competition yet, so it needs no lock of its own.

**Delete competition:**
1. Lock the competition `FOR UPDATE`. This waits for any join holding `FOR SHARE`.
2. Refuse unless the caller is the creator, `now() < starts_at`, and the creator is the only participant.
3. Delete the row. Participants and invitations cascade.

A join waiting on this lock then finds no row, and returns 404. An upload can't conflict, because a run can't be scored in a competition before it starts, and this deletion is refused from `starts_at` on.

### 14.7 Verification

**Environment:** PostgreSQL 18.6 (`postgres:18-alpine`) in a throwaway container. The migration SQL was extracted from this section by [`verification/extract_amendments.js`](verification/extract_amendments.js), and [`verification/07_api_amendments.sql`](verification/07_api_amendments.sql) tested it on the sample from section 13.2. **These checks confirm index use and constraint behavior. They aren't benchmarks**, because the sample was cached, idle and freshly vacuumed.

**What passed (13 of 13 checks):**

| Check | Result |
|---|---|
| Migration SQL applies after the initial schema | Pass |
| Session hash must be 32 bytes, and must reference a real user | Pass |
| City over 100 characters refused in all three tables, and exactly 100 accepted | Pass |
| Lookup finds a live session, and ignores an expired one | Pass |
| A session inserted after account deletion can't authenticate | Pass |
| Purging the user cascades to sessions | Pass |
| Renewal skips a fresh session, extends a stale one, and respects the 90-day cap | Pass |

**Query plans:**

| Query | Observed |
|---|---|
| Session lookup (R1) | `sessions_pkey` and `users_pkey` |
| Revoke all sessions | `ix_sessions_user` |
| Daily session cleanup | Sequential scan, as designed |
| Duplicate quick check (W1) | `uq_runs_user_file_hash` |
| Overlap lookup, for `conflictingRunId` | `ex_runs_no_overlap` |
| Another user's runs, valid only (R3) | `ix_runs_user_started`, with a filter on `status`, and no sort |
| Weekly stats in a time zone (R4) | `ix_runs_user_started` |
| Personal bests (R4) | `ex_runs_no_overlap`, which is the planner's choice, since it holds exactly one user's valid runs |
| Leaderboard deep page, both directions (R2) | `ix_participants_leaderboard`, with the row comparison in the index condition, and no sort |
| Rank of a deep page's first row (R2) | Same index, reading 2,499 rows at the median, with a hash anti join on `ix_users_deleted` |
| Participant count (R5) | `competition_participants_pkey`, reading 4,999 rows, with a merge anti join |
| Participants, keyset (R5) | `competition_participants_pkey` and `users_pkey`, no sort |
| My competitions, active (R6) | `ix_participants_user` and `competitions_pkey`, with a small sort the planner chose over index order. **Not a pure keyset scan.** Fine at a few rows per user, and worth rechecking for a user with hundreds |
| Friends, keyset across both sides (R7) | `friendships_pkey` and `ix_friendships_user_b`, with the filter pushed into both sides, plus a small sort |
| Group members, my groups (R7) | `group_members_pkey`, `ix_group_members_user` |
| User search (R7) | Sequential scan, as designed. It read about 4,900 rows of the 5,000 |
| Competition search (R8) | `ix_competitions_to_close` for open competitions, then a sort |
| A group's competitions | `ix_competitions_group`, then a sort |
| My invitations | Both `invitee` indexes, then a sort, on a sample seeded with invitations |

**HOT updates, measured.** The first version of this design said that renewals would be HOT, because no indexed column changes. The test showed that this is too simple, since HOT also needs free space on the same page:

| Round | Updates | HOT |
|---|---|---|
| First, on tightly packed bulk-loaded pages | 50 | 2 |
| Second, after `VACUUM` reclaimed the old row versions | 50 | 26 |

Real pages won't be as tightly packed as a bulk load, but this sample doesn't show what the real rate would be. A lower `fillfactor` would reserve room on each page, but it isn't justified at one renewal per hour per session.

**Not covered:**
- **Load and latency:** no load test, and no measured p95.
- **Race tests 12 to 16 (section 11.3):** the application doesn't exist yet. Only the "login racing with deletion" filter was checked, by forcing the order in SQL.
- **The API-6 transactions:** described, and not executed. Their lock behavior needs the race tests.
- **Flyway:** the migration files don't exist, so the SQL ran directly with `psql`.

### 14.8 CLS: amendments from the class design

**Status:** approved with the class design plan. [`docs/design/classes.md`](classes.md) has the reasoning. **None of these was run against a server.** They change application behavior and add no DDL, and each needs the race test named below. Schema and migrations are unchanged.

| ID | Change | Why | Proof still needed |
|---|---|---|---|
| CLS-1 | Section 3.6 adds two read exceptions: `competitions` reads `users`, and `platform` holds the lock statements | `participantCount` and the participants list must hide deleted users, because participant rows survive until the purge. See D35 | Architecture test on the named classes |
| CLS-2 | **The lock order, restated.** User, then groups by ascending ID, then competitions by ascending ID, with each competition's participant directly after that competition | Section 6.1's wording said "competitions, then participants", but section 6.3 step 5 alternates c1, p1, c2, p2. Deletion can also touch several groups, and section 6.6 gave them no order, so two deletions could deadlock. **Deletion locks every group where the user is an admin, then counts admins under each lock.** Section 6.6 locked only groups where the user was the last admin, which has a race: if another admin leaves at the same moment, an unlocked read still sees two admins, so the group ends up with none | Race tests 1 to 16, with the `RowLocks` guard on, plus a new test: an admin leaving during another admin's deletion |
| CLS-3 | `transaction_timeout` on **every** write transaction (30 s by default). Closure uses 60 s and the purge 5 minutes. The purge loops up to a batch per tick | It bounds lock waits on join and leave too, which keeps a stale `now()` harmless. One user per minute is too slow after any backlog | Race tests 7 and 9 |
| CLS-4 | Ingest skips a competition whose row is gone, not only one with `closed_at` set | API-6 says an upload can't conflict with deleting a competition. That's slightly wrong: the 2-minute future tolerance (D36) can match a run to a competition about to start | Race test 16, plus a new test with a run inside the tolerance |
| CLS-5 | On `23P01`, ingest re-checks `(user_id, file_hash)` before returning 409 | A concurrent duplicate should raise `23505`, because the unique index is expected to be checked first. That's from memory of how PostgreSQL orders index checks, and wasn't verified, so this is cheap insurance | Race test 1 |
| CLS-6 | Group join, group create and friend request lock the caller's user row `FOR SHARE`, with `deleted_at IS NULL` | **A real gap.** A foreign-key check takes `FOR KEY SHARE`, which doesn't conflict with deletion's `FOR NO KEY UPDATE`. So an in-flight group join could leave a membership after phase 1, and a deleted admin would count toward `last_admin` | New race test: group join against account deletion |
| CLS-7 | `GET /me/invitations` joins the inviter with `deleted_at IS NULL` | **A real gap.** `invited_by` is only removed by the purge. Until then the inviter's name is `NULL`, which would break the required `invitedBy` card. Deleting those rows in phase 1 would need an index on `invited_by`, which section 4 deliberately leaves out | New test: invitation from a deleted inviter |
| CLS-8 | Session renewal is decided from a flag returned by the lookup, and also refreshes the cookie | Section 14.1's renewal statement is safe to run on every request, but it adds a statement to R1 for nothing. See `docs/design/api.md` section 8.3 for the cookie | Controller test on the renewal response |

**Friend requests** also move from catching `23505` to `INSERT ... ON CONFLICT DO NOTHING` plus a locked read. Behavior is the same, and no transaction aborts.
