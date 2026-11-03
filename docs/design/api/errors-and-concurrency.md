# API: Errors and concurrency

> **Covers:** The Problem Details shape, the error catalog and database error mapping (10); idempotency, `PUT` and `DELETE` semantics, and the races the API adds (11).
> **Read when:** adding an error code, handling a database error, or reasoning about retries.
> **Related:** [../../api/components/examples.yaml](../../api/components/examples.yaml), [../classes/cross-cutting.md](../classes/cross-cutting.md), [../database/transactions.md](../database/transactions.md)

## 10. Error model

### 10.1 Shape (D45)

**RFC 9457 Problem Details** is a standard JSON format for HTTP errors, served as `application/problem+json`. Spring has built-in support.

```json
{
  "type": "urn:pace:problem:run_overlap",
  "title": "Run overlaps an existing run",
  "status": 409,
  "detail": "This run overlaps a valid run you already uploaded.",
  "instance": "/api/v1/runs",
  "code": "run_overlap",
  "requestId": "019a4c10-1111-7000-8000-abcdefabcdef",
  "conflictingRunId": "019a3f77-81cd-7e10-a2f4-90b1d3c6e805"
}
```

**Clients should switch on `code`, which is stable.** `title` and `detail` are for people, and can change. `type` is a URN rather than a URL, since we host no documentation pages for errors.

`conflictingRunId` is safe, because it is always the caller's own run.

**Validation errors** add field-level detail:

```json
{
  "code": "validation_failed",
  "errors": [{ "field": "displayName", "code": "too_long", "message": "Must be at most 50 characters." }]
}
```

**400 versus 422:** 400 means the request can't be understood (bad JSON, wrong type, unknown field). 422 means it was understood, but breaks a rule.

**Wrong current password: 403, not 401.** Clients usually treat 401 as "logged out" and redirect to the login page, which would be wrong here, since the session is still valid.

### 10.2 Catalog

| Code | Status | When |
|---|---|---|
| `malformed_request` | 400 | Bad JSON, a wrong type, an unknown field or a malformed UUID |
| `invalid_cursor` | 400 | A cursor that can't be read |
| `invalid_credentials` | 401 | Login with a wrong email or password |
| `unauthenticated` | 401 | No session, or it expired or was revoked |
| `forbidden` | 403 | Can see the resource, but can't do this |
| `csrf_rejected` | 403 | An unsafe request that isn't from our origin |
| `password_incorrect` | 403 | Wrong current password on password change or account deletion |
| `runs_not_visible` | 403 | `run_privacy` hides this user's runs |
| `full_leaderboard_forbidden` | 403 | A cursor sent by someone who isn't participating |
| `not_found` | 404 | Doesn't exist, or the viewer can't see it |
| `method_not_allowed` | 405 | Wrong method on a route. Handled by the framework, so not declared per operation in the spec |
| `email_taken` | 409 | Registering a used email |
| `run_overlap` | 409 | Overlaps a valid run. Includes `conflictingRunId` |
| `last_admin` | 409 | Would leave a group with no admin |
| `invitation_not_applicable` | 409 | Inviting to a public group or competition |
| `competition_limit_reached` | 409 | Already in 10 open competitions |
| `competition_join_closed` | 409 | Joining at or after `endsAt` |
| `competition_leave_closed` | 409 | Leaving at or after `endsAt` (D39) |
| `competition_not_deletable` | 409 | It has started, or has other participants |
| `payload_too_large` | 413 | Over the size limit |
| `unsupported_media_type` | 415 | Wrong `Content-Type`, or a compressed body |
| `validation_failed` | 422 | Field-level rule failures, listed in `errors` |
| `weak_password` | 422 | Too short, or a common password |
| `image_invalid` | 422 | Not a readable JPEG or PNG |
| `friend_self` | 422 | A friend request to yourself |
| `consent_required` | 422 | Joining a public competition without the flag |
| `gpx_malformed` | 422 | Not a usable GPX track (section 7.6) |
| `gpx_out_of_range` | 422 | Distance under 1 m, or duration over 7 days |
| `run_in_future` | 422 | Starts or ends in the future |
| `run_too_old` | 422 | Started more than 30 days ago |
| `rate_limited` | 429 | Over a limit. Includes `Retry-After` |
| `internal_error` | 500 | A bug. Quote the `requestId` |
| `temporarily_unavailable` | 503 | Safe to retry |
| `storage_unavailable` | 503 | Object storage is down. Nothing was saved |

### 10.3 Database errors

| Error | Meaning | Response |
|---|---|---|
| `23505` on `uq_users_email_lower` | Email taken | 409 `email_taken` |
| `23505` on `uq_runs_user_file_hash` | Concurrent duplicate | 200 with the existing run |
| `23505` on the friendship primary key | Both people sent a request at once | Doesn't reach the application: the insert uses `ON CONFLICT DO NOTHING`, then a locked read turns it into an acceptance |
| `23P01` on `ex_runs_no_overlap` | Overlap | 409 `run_overlap` |
| `23503` | The target was deleted meanwhile | 404 `not_found` |
| `40P01` deadlock | Should be rare, given the lock order | Retry the **whole transaction** up to 2 times, with 50 to 200 ms of jitter, then 503 |
| `40001` serialization failure | Not expected under `READ COMMITTED` | Same retry |
| `57014` statement timeout | | 503 `temporarily_unavailable` |
| `transaction_timeout` (`FATAL`) | The connection is terminated (database 6.3) | Treated as a lost connection, discarded from the pool, 503. Don't rely on a specific SQLSTATE |
| `22003`, `23514` | Validation should have caught this | 500 and an alert, since it is a bug |

**Why retries are bounded:** unlimited retries turn a brief problem into a pile-up.

**Why only the whole transaction:** PostgreSQL aborts the transaction on these errors, so retrying one statement can't work. Jitter keeps the two losers from colliding again.

---

## 11. Idempotency and concurrency

### 11.1 Every write (D56)

**Idempotent** means repeating the request has the same effect as doing it once.

| Write | On retry |
|---|---|
| `POST /runs` | Idempotent by file hash |
| Every `PUT` and `DELETE` | Idempotent by design |
| `PATCH /me`, role changes | Same final state |
| `POST /auth/register` | The second attempt gets `email_taken`. A rough edge after a lost response, which logging in resolves |
| `POST /auth/login` | An extra session, which expires |
| `POST /auth/logout` | The second call gets 401, because the session is gone. Harmless |
| `POST /me/deletion` | The second call gets 401, for the same reason |
| `POST /groups`, `POST /competitions` | **Can create duplicates** |

**No `Idempotency-Key` in Phase 1.** An **`Idempotency-Key`** is a client-chosen ID that lets the server recognize a repeated request. It needs a table with stored responses and expiry, to protect two rare actions. Double-clicks are handled by the client disabling the button while the request is in flight. A retry after a lost response could still create a duplicate, and we accept that.

**Recovery:** groups can be deleted, and so can competitions, using `DELETE /competitions/{competitionId}`. That is allowed only for the creator, before `starts_at`, and when they're the only participant. It is needed anyway, because competitions can't be edited, so a wrong date otherwise has no fix.

### 11.2 No optimistic concurrency

**Optimistic concurrency** means sending `If-Match` with a version, so an edit fails if someone else changed the resource first. **We don't need it, because no resource has two editors:**
- A profile has one editor. Last write wins across a user's own devices.
- Competitions can't be edited, because changing rules after people have joined breaks fairness.
- Groups can't be edited in Phase 1. Role changes are protected by a row lock instead (section 11.4).

### 11.3 Joining, leaving and friends use `PUT` and `DELETE`

**The client says "I am a member" rather than "do a join"**, so repeating it is harmless. `PUT` returns 201 if newly joined, and 200 if already in. `POST` isn't offered at all.

**Accepting an invitation is the same `PUT`.** The join transaction already deletes the invitation (database 6.4). Invitations have composite keys and no ID of their own, so this fits the schema.

**Rejected:** an `/invitations/{id}/accept` action, which needs an invented ID, and creates a second way to do the same thing.

**Friends use one row and one verb pair.** `PUT /me/friends/{userId}` means "I want this friendship":

| Current state | Result | Status |
|---|---|---|
| No row | Pending request created | 201 |
| Their pending request | Accepted | 200 |
| My pending request | No change | 200 |
| Already friends | No change | 200 |

`DELETE /me/friends/{userId}` covers decline, cancel and remove, since the schema deletes the row in all three.

**Why:** a simultaneous mutual request stops being a special case, which fits database 3.5.

**Rejected:** separate request, accept and decline endpoints, which need three routes and invented request IDs.

**The cost:** the frontend must read `status` to know what happened, and a stale screen could accept a request while intending to send one. In that case, both people wanted the friendship anyway.

### 11.4 Races the API adds

Database 6 covers ingest, join, closure and deletion. API-3 and API-6 add these:

| Race | What happens |
|---|---|
| Double-click on the join that reaches the limit | The already-participant check runs first (API-3), so both succeed |
| Retry of a join after `ends_at` by a participant | Same check, so 200 |
| Two admins demoting each other at once | The group row lock serializes them, so the second gets `last_admin` |
| The last admin leaves | The longest-standing member is promoted, and an empty group is deleted |
| Demoting yourself as the last admin | 409 `last_admin` |
| Join racing with competition deletion | The lock serializes them. Either the join sees 404, or the deletion sees another participant and refuses |
| Login racing with account deletion | The session lookup joins `users`, so the session can't authenticate (API-1) |

---

