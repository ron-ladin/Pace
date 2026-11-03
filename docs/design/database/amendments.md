# Database: Amendments

> **Covers:** Amendments API-1 to API-6 from the API design and CLS-1 to CLS-8 from the class design, including the migration SQL and its verification. Where they differ from an earlier section, this section wins.
> **Read when:** reading any other database section whose behavior may have been amended, such as sessions, ingest order or deletion.
> **Related:** [schema.md](schema.md), [transactions.md](transactions.md), [../verification/README.md](../verification/README.md)

## 14. Amendments from the API design

**Status:** approved with the API design plan. [`docs/design/api.md`](../api.md) has the reasoning. Migration files don't exist yet, since there is no application code. The SQL below was applied to a real server, and section 14.7 has the results.

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

**Environment:** PostgreSQL 18.6 (`postgres:18-alpine`) in a throwaway container. The migration SQL was extracted from this section by [`verification/extract_amendments.js`](../verification/extract_amendments.js), and [`verification/07_api_amendments.sql`](../verification/07_api_amendments.sql) tested it on the sample from section 13.2. **These checks confirm index use and constraint behavior. They aren't benchmarks**, because the sample was cached, idle and freshly vacuumed.

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

**Status:** approved with the class design plan. [`docs/design/classes.md`](../classes.md) has the reasoning. **None of these was run against a server.** They change application behavior and add no DDL, and each needs the race test named below. Schema and migrations are unchanged.

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
