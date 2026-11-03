# Database: Indexes and queries

> **Covers:** Every index and why it exists, the map from access patterns to indexes, the leaderboard queries, and run history.
> **Read when:** adding an index, writing a read query, or working on leaderboards.
> **Related:** [schema.md](schema.md), [validation.md](validation.md), [../api/competition-semantics.md](../api/competition-semantics.md)

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

