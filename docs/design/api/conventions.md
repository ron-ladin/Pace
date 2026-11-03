# API: Conventions

> **Covers:** Constraints from earlier decisions, REST and JSON conventions, evolution policy, pagination, and HTTP caching.
> **Read when:** designing or changing any endpoint or response shape.
> **Related:** [endpoints.md](endpoints.md), [errors-and-concurrency.md](errors-and-concurrency.md), [../../api/openapi.yaml](../../api/openapi.yaml)

## 2. Constraints

These were decided before this design, and aren't reopened here.

| Constraint | Source |
|---|---|
| PWA client, Spring Boot modular monolith, package-by-feature with web -> service -> persistence layers, and no business logic in controllers | D2, D5, D40 |
| IDs are UUIDv7. Times are `timestamptz`. Distances and durations are integers, and pace is a generated integer | D24, database 2 |
| GPX upload only, with no manual entry, no user deletion of runs and no manual invalidation | D11, D14, D30 |
| Ingest is synchronous: parse in the API, then one transaction inserts the run and rescores | D26, D30 |
| Duplicates return the existing run, overlaps are a conflict, and implausible runs are stored as invalid | D25, database 3.2 |
| Future-dated runs, and runs older than 30 days, are rejected | D36 |
| Eligibility: started in the window, and received before `closes_at`. Grace defaults to 6 hours | D13, D27, D28 |
| Joining backfills the score. Leaving is refused from `ends_at` on | D31, D39 |
| Ties share a rank. Deleted users are filtered at read time | D15, D17 |
| Public top N: display name and metric, and joining is consent to appear there | D16 |
| Private groups are invitation-only. Competitions are separate from groups | D20, D32 |
| Two-phase account deletion, where sessions are revoked immediately | D29 |
| No route geometry is stored, so the API never exposes routes or coordinates | Database 3.2 |
| Zero cost | D4 |
| Leaderboard p95 < 200 ms, other reads < 300 ms, search < 500 ms, upload < 1 s, freshness <= 30 s | D22 |

**Phase 2 and 3 endpoints aren't designed here.** Section 3.8 checks that they will fit.

---

## 3. Conventions

### 3.1 REST, JSON, `/api/v1` (D41)

**Why:** this data maps cleanly onto resources, and everything can be inspected with free tools.

**Rejected:** GraphQL, because flexible client queries make latency targets harder to protect, and it solves a many-clients problem we don't have. gRPC, because browsers can't call it directly.

### 3.2 Same origin (D42)

The PWA and the API are served from one origin through Nginx. **CORS** is the browser rule for calling another origin, and this avoids it entirely, along with preflight requests. Cookies also get simpler. Local development uses a dev-server proxy to keep the same shape.

**Rejected:** an `api.` subdomain, which brings preflights and cookie-scope questions with no benefit for one client.

### 3.3 URLs

- Plural kebab-case nouns, with at most one level of nesting under a parent.
- `/me` is a real sub-tree for the current user's own data, which removes a whole class of "wrong user ID" bugs.
- `/me` under a parent, such as `/groups/{groupId}/members/me`, is a literal path that takes priority over `{userId}`. OpenAPI defines this priority too.

`/auth/*` isn't pure REST. Login and logout aren't really resources, and pretending otherwise (a `/sessions` collection) adds nothing here. The prefix also groups them neatly for rate limits.

### 3.4 JSON

| Rule | Example | Why |
|---|---|---|
| camelCase fields | `startedAt` | JavaScript's convention, and the frontend is the main reader |
| Lowercase snake_case enums, matching the database | `total_distance` | One spelling everywhere, so logs and SQL read the same |
| Units in field names | `distanceMeters`, `paceSecondsPerKm` | A bare `distance` invites km/m bugs, and a contract should not need footnotes |
| RFC 3339 UTC times | `2026-11-03T07:00:00Z` | Unambiguous and sortable |
| Dates as `YYYY-MM-DD` | `birthDate` | A birth date is not a moment in time |

`score` is the one generic field, because its unit depends on the rule. The leaderboard's `scoreUnit` names it.

**Null versus absent:**
- **Null** means the viewer may know this, and there is no value.
- **Absent** means the viewer isn't entitled to the field, or it doesn't apply.

So `userId` is absent in a public top N, while `city` is `null` if the user never set it. The shape stays stable, and the two cases really are different.

**One deliberate exception:** a competition's `group` is `null` both when there is no group and when the viewer can't see it. Using absent there would reveal that a private group exists.

**`PATCH` uses JSON Merge Patch** (RFC 7396): absent means unchanged, and `null` clears the field. Its media type is `application/merge-patch+json`. In Java, plain DTOs can't tell absent from null, so the implementation needs a wrapper for these requests. The class design chooses `JsonNullable` (D65).

### 3.5 Tolerant readers, strict requests

- **Clients ignore unknown response fields**, so adding a field is safe.
- **The server rejects unknown request fields** with 400. This is stricter than Spring's default, and it catches typos and accidental mass-assignment (a client setting a field it was never meant to set).

### 3.6 Open enums

`rule.type`, `invalidReason`, `source` and `scoreUnit` use `x-extensible-enum` rather than `enum`, and clients must handle unknown values.

**Why:** Phase 2 adds rule types. With a closed `enum`, generated clients would break on a new value, and adding one would be a breaking change. Request bodies keep a real `enum`, because the server decides what it accepts.

### 3.7 Evolution policy

| Non-breaking | Breaking |
|---|---|
| New endpoint | Removing or renaming anything |
| New optional request field | A new required request field |
| New response field | Tightening validation |
| New value in an open enum | Changing a type or meaning |
| Loosening an authorization rule | Tightening an authorization rule |

A breaking change needs `/api/v2`, or a deprecated field with `Deprecation` (RFC 9745) and `Sunset` (RFC 8594) headers and **at least 30 days of overlap**.

**Why this matters with only one client:** a PWA service worker keeps old bundles running on phones, so old clients really do exist.

### 3.8 Room for Phase 2 and 3

Checked, not designed:
- `/feed`, `/me/achievements`, `/competitions/{competitionId}/teams` and `/partners` collide with nothing.
- Nested `rule: {type, minDistanceMeters}` leaves room for new rule parameters.
- `source` on runs, and a new content type on `POST /runs`, leave room for live recording.
- A bearer token and SSE can both be added without breaking anything (sections 8.1 and 19).

---

## 6. Pagination, sorting and filtering

### 6.1 Keyset pagination (D47)

**Keyset pagination** continues from the last row seen, rather than counting past rows as `OFFSET` does.

Response shape: `{items, nextCursor}`, where `null` means the last page. Default `limit` is 20, and the maximum is 100.

**Cursor:** base64url JSON with a version field, holding the last row's sort key. It is **opaque by contract**: clients must not parse it, and the server can change it freely. It is not signed, because every query still applies the viewer's authorization, so tampering gains nothing. A cursor that doesn't parse gets 400 `invalid_cursor`. Changing filters while keeping a cursor gives harmless but meaningless results, and the contract tells clients to keep them unchanged.

**Why not `OFFSET`:**
- Deep pages get slower, because the database reads and discards every skipped row.
- A new run arriving between pages shifts everything, so rows repeat or get skipped.

With a keyset, new rows land before the cursor, so nothing is skipped or repeated.

**No total counts in lists:** they'd need a full count on each page. Details endpoints show `participantCount` and `memberCount`, which are cheap once rather than on every page.

**Exceptions, both without a cursor:**
- `GET /me/invitations` returns the newest 100. **That is a cap, not a proof of smallness.** A user with over 100 pending invitations won't see the oldest. Adding `nextCursor` later is non-breaking.
- `GET /users` returns at most 20. If the person isn't there, the client should search for something more specific.

### 6.2 Fixed orders, no `sort` parameter

Each list has one fixed order, chosen because an index serves it. **A free `sort` parameter would promise orders we can't serve efficiently.**

| List | Order | Why |
|---|---|---|
| Run history | `started_at DESC, id DESC` | `ix_runs_user_started` |
| Leaderboard | `score, user_id`, direction by rule | `ix_participants_leaderboard` |
| Participants | `user_id` | Primary key |
| Group members | `user_id` | Primary key |
| My competitions | `competition_id DESC` | UUIDv7 sorts by creation time |
| My groups | `group_id DESC` | Same |
| Friends | The other user's ID | Both friendship indexes |
| Searches | `id DESC` | Newest first |

**The honest cost:** participants and members appear in an order that means nothing to people. Alphabetical order would need a sort, and we'd accept that only when someone asks.

### 6.3 Leaderboards

One request serves the whole screen, because R2 is one screen:

```json
{
  "state": "running",
  "scoreUnit": "meters",
  "viewerAccess": "full",
  "asOf": "2026-11-03T10:00:00Z",
  "pollIntervalSeconds": 25,
  "entries": [
    { "rank": 1, "displayName": "Noa Peretz", "score": 42000, "userId": "...", "photoUrl": null, "isMe": false },
    { "rank": 1, "displayName": "Amir Cohen", "score": 42000, "userId": "...", "photoUrl": null, "isMe": false },
    { "rank": 3, "displayName": "Dana Levi", "score": 31000, "userId": "...", "photoUrl": "...", "isMe": true }
  ],
  "me": { "rank": 3, "score": 31000 },
  "nextCursor": null
}
```

**Rejected:** a separate "my rank" endpoint, which would cost a second request for every screen and every poll.

- `limit` defaults to 10 here. For top N viewers it is capped at N.
- `me` appears on the first page only, because it can cost up to 5,000 index entries.
- **Deep pages** find the rank of their first row with the same count query as "my rank" (database 7.2), then assign ranks within the page. No rank goes in the cursor, because the count stays correct even as scores change.
- **Scores can move between pages.** A user could appear twice or be missed when paging during a score change. Eventual consistency allows this (database 7.3).

---

## 13. HTTP caching

There is no server-side cache (D8).

| Class | `Cache-Control` | ETag |
|---|---|---|
| Leaderboard | `private, no-cache` | Yes |
| Photos | `private, max-age=31536000, immutable` | No |
| Everything else | `no-store` | No |

**`no-cache` versus `no-store`,** which are easy to confuse: `no-cache` may be stored but must be revalidated before use, and `no-store` must not be stored at all.

**An ETag** is a fingerprint of the content. The client sends it back in `If-None-Match`, and gets 304 Not Modified if nothing changed.

**Details that matter:**
- **The leaderboard ETag is a hash of `state`, `entries`, `me` and `nextCursor`, and not `asOf`.** `asOf` changes on every request, so including it means the ETag would never match. Spring's `ShallowEtagHeaderFilter` hashes the whole body, so it can't be used here. After a 304, the response `Date` header says how fresh the data is.
- **A 304 saves bandwidth, not database work,** because the queries still run to compute the hash. It is worth keeping because most polls won't have changed (section 19) and phones pay for data, but it doesn't reduce database load.
- **`pollIntervalSeconds` isn't in the ETag either,** so a server-side change to the interval reaches a client with the next real data change. That's acceptable, because `state` is in the ETag, so the change to `null` on closure always arrives.
- **`private` and `Vary: Cookie`,** because the response depends on the viewer. A 304 repeats `Vary`, as RFC 9110 requires.
- **Closed leaderboards can't be `immutable`,** because D17 allows rank shifts when an account is deleted.
- **Everything else is `no-store`.** Simpler is safer: personal data on a shared phone shouldn't linger in the browser cache, and these endpoints aren't hot.

**The service worker must not cache `/api/`.** A PWA's service worker is a second cache, which ignores these headers unless it's written to respect them. **This is easy to get wrong, and would break both freshness and privacy.** It is stated in the contract for that reason.

---

