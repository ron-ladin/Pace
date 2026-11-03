# Database: Schema

> **Covers:** Naming and type conventions, the DDL and rules of every table, module boundaries, and the UUIDv7 and overlap-constraint decisions (D24, D25).
> **Read when:** reading or changing tables, columns or constraints. Check `amendments.md` too, because section 14 overrides earlier sections.
> **Related:** [amendments.md](amendments.md), [indexes-and-queries.md](indexes-and-queries.md), [migrations.md](migrations.md)

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

