# API: Competition and leaderboard semantics

> **Covers:** Derived state, what each viewer sees, ranks and ties, consent, creator auto-join and freshness metadata (12); polling versus push (19).
> **Read when:** working on competitions, leaderboard responses or polling.
> **Related:** [../database/indexes-and-queries.md](../database/indexes-and-queries.md), [../classes/flows-runs-competitions.md](../classes/flows-runs-competitions.md)

## 12. Competition and leaderboard semantics

### 12.1 Derived state

`state` is computed on every read, using the database clock and the rules in database 3.3. The query selects `now()` with the row, and `Competition.stateAt(now)` applies the rule in Java, so there is one copy of it. Search filters on `state` need the same rule in SQL, and a test keeps the two in agreement (`docs/design/classes.md`). **It is never stored**, so it can't disagree with the timestamps.

| `state` | Condition | Runs count? | Join or leave? | Results |
|---|---|---|---|---|
| `upcoming` | `now() < starts_at` | Not yet | Yes | None |
| `running` | `starts_at <= now() < ends_at` | Yes | Yes | Changing |
| `finalizing` | `ends_at <= now()`, and `closed_at IS NULL` | Late uploads, if received before `closes_at` | No | **May still change** |
| `closed` | `closed_at IS NOT NULL` | No | No | Final, except D17 |

`finalizing` also covers the short gap between `closes_at` and the job setting `closed_at`. No new runs count during that gap, and showing "finalizing" there is still honest, since the result isn't declared final yet. **The client must display this state**, so users know results can still change.

**Viewer capabilities:** details endpoints include `viewer: {isParticipant, invited, canJoin, canLeave, canInvite, canDelete}`, and a similar object on groups. **Why:** a frontend that may be AI-generated shouldn't re-implement these rules, because it would get them subtly wrong. They are absent for logged-out visitors.

### 12.2 What each viewer sees

| Viewer | Details | Leaderboard | `userId`, photo | `me` | Participants list |
|---|---|---|---|---|---|
| Anonymous, public competition | Yes, without `createdBy` or `viewer` | Top N | No | `null` | No |
| Logged in, not participating | Yes | Top N | No | `null` | No (403, or 404 if private) |
| Participant | Yes | Full, paged | Yes | Yes | Yes |
| Participant, no eligible run | Yes | Full, paged, without them | Yes | `{rank: null, score: null}` | Yes, with `score: null` |

`viewerAccess` is `top_n` or `full`, so the client doesn't need to infer it. A `top_n` viewer sending a cursor gets 403 `full_leaderboard_forbidden`, and `limit` is capped at N (default 10, configurable).

**The two lists are different on purpose.** The leaderboard holds ranked participants, served by a partial index that excludes `NULL` scores. `/participants` holds everyone, including people with no eligible run.

### 12.3 Ranks and ties

Ties share a rank: 1, 1, 3 (D15). Among equal scores, entries are ordered by `user_id`, which only makes the list stable and doesn't affect anyone's rank.

**Deleted users never appear, and ranks close up** (D17). Lists show deleted users as absent, not as "Deleted user". A deleted competition creator appears as `createdBy: null`.

`scoreUnit` is `meters` or `seconds_per_km`. For `fastest_pace`, a lower score is better, and the server has already applied the direction, so clients just display entries in order.

### 12.4 Consent (D55, amends D16)

Public competitions require `consentToPublicLeaderboard: true`, both when joining and when creating (since the creator auto-joins). Without it: 422 `consent_required`.

**Why in the API as well as the UI:** the rule becomes visible in the contract, and an AI-built frontend can't skip it by accident.

Consent isn't stored as its own value, because `joined_at` already records when it happened. The flag proves the client presented the choice, not that a human read it, so the UI wording still matters.

### 12.5 Creator auto-join (D55)

`POST /competitions` runs the join steps in the same transaction (API-6). This counts toward the limit of 10 open competitions, and the creator can leave until `ends_at`.

**Why:** the competition then appears in `GET /me/competitions` with no new index. An organizer who doesn't run can leave, and their competition continues.

**Rejected:** an explicit join, which would need an index on `creator_id` and a "created by me" list, both deliberately left out of the database design.

### 12.6 Freshness metadata

`asOf` is the time the data was read. It is truthful, because scoring is synchronous, and it can become a snapshot time if Redis or async scoring arrives.

**Rejected:**
- **`lastUpdatedAt`,** which sounds friendlier, but needs `MAX(score_updated_at)`. That reads every participant's row, and no index serves it.
- **A version column on `competitions`,** which every score change would update, conflicting with the `FOR SHARE` locks that ingest takes.

---

## 19. Polling versus push

**Decision: polling (D51).**

**The numbers,** using the 5,000-user estimates. The dwell time and peak factor are my assumptions.

| Quantity | Value |
|---|---|
| Leaderboard views per day | 10,000 |
| Assumed time on screen | 60 s |
| Polling every 25 s | About 3 requests per view |
| Leaderboard requests per day | **About 30,000** |
| Average | **0.35 requests/s** |
| Peak, assuming 10x | **About 3.5 requests/s** |
| Effect on R1 | Raises it from about 30,000 to about **50,000 requests/day** |
| Score changes | 860 runs/day, or **one every 100 s across all competitions** |

**SSE would hold about 7 concurrent connections on average, and about 70 at peak, which is also cheap.** So capacity doesn't decide this, and it would be misleading to say polling won on load.

**What does decide it:**
- A 30-second target doesn't need push.
- Scores change so rarely that most polls return 304.
- SSE adds reconnect handling, proxy timeouts and buffering settings, and later, pub/sub across instances.
- Polling already works with what the design has.

**Client rules:**
- Poll only while the tab is visible, and only while `pollIntervalSeconds` isn't `null`.
- Send the last `ETag` in `If-None-Match`.

**`pollIntervalSeconds` is in the response**, so the server can slow old PWA bundles without a client release. 25 s, rather than 30, leaves room for jitter inside the 30-second target.

**Freshness:** with synchronous scoring, the worst-case staleness a viewer sees is one poll interval. That meets D22.

**SSE remains a good learning milestone.** It can be added beside polling without breaking anything.

---

