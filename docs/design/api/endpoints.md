# API: Endpoint catalog

> **Covers:** The full endpoint catalog with auth, success, errors and access patterns; finding people (D54); and where data lives.
> **Read when:** looking up an endpoint or adding one. `check_coverage.mjs` compares this catalog with the contract.
> **Related:** [../../api/openapi.yaml](../../api/openapi.yaml), [auth.md](auth.md), [contract-and-verification.md](contract-and-verification.md)

## 4. Endpoint catalog

Paths are under `/api/v1`. Auth: **A** = logged in, **O** = optional (anonymous allowed), **N** = none.

**Not repeated in every row:** every endpoint can return 429, 500 and 503. Authenticated endpoints can return 401 `unauthenticated`. Unsafe methods can return 403 `csrf_rejected`. Requests with a body can return 413, 415 and, for JSON, 422 `validation_failed`. Query parameters that parse but break a rule, such as an out-of-range `limit` or an unknown enum value, also return 422 `validation_failed`. Anything with parameters can return 400 `malformed_request`, and with a cursor, 400 `invalid_cursor`.

| Endpoint | Auth | Request | Success | Other errors | Serves |
|---|---|---|---|---|---|
| `POST /auth/register` | N | email, password, displayName, timeZone? | 201 CurrentUser + cookie | 409 `email_taken`, 422 `weak_password` | W6 |
| `POST /auth/login` | N | email, password | 200 CurrentUser + cookie | 401 `invalid_credentials` | R1 |
| `POST /auth/logout` | A | none | 204, clears cookie | | R1 |
| `GET /me` | A | none | 200 CurrentUser | | R1, W6 |
| `PATCH /me` | A | displayName, birthDate, city, timeZone, runPrivacy | 200 CurrentUser | | W6 |
| `PUT /me/password` | A | currentPassword, newPassword | 204, new cookie | 403 `password_incorrect`, 422 `weak_password` | W6 |
| `POST /me/deletion` | A | password | 204, clears cookie | 403 `password_incorrect` | W6 |
| `PUT /me/photo` | A | raw JPEG or PNG | 200 PhotoResponse | 422 `image_invalid` | W6 |
| `DELETE /me/photo` | A | none | 204 | | W6 |
| `GET /me/stats` | A | weeks?, months?, weekStart? | 200 Stats | | R4 |
| `GET /users` | A | q, limit? | 200 list | | R7 |
| `GET /users/{userId}` | A | none | 200 UserCard | 404 `not_found` | R7 |
| `GET /users/{userId}/photos/{photoId}` | A | none | 200 image | 404 `not_found` | R7 |
| `GET /users/{userId}/runs` | A | limit, cursor | 200 list | 403 `runs_not_visible`, 404 `not_found` | R3 |
| `POST /runs` | A | raw GPX | 201 new, or 200 existing | 409 `run_overlap`, 422 `gpx_malformed` `gpx_out_of_range` `run_in_future` `run_too_old`, 503 `storage_unavailable` | W1, W2 |
| `GET /me/runs` | A | limit, cursor | 200 list | | R3 |
| `GET /runs/{runId}` | A | none | 200 Run | 404 `not_found` | R3 |
| `GET /me/friends` | A | status=accepted\|incoming\|outgoing, limit, cursor | 200 list | | R7 |
| `PUT /me/friends/{userId}` | A | none | 201 pending, or 200 accepted/no change | 404 `not_found`, 422 `friend_self` | W5 |
| `DELETE /me/friends/{userId}` | A | none | 204 | | W5 |
| `POST /groups` | A | name, visibility, city? | 201 Group | | W5 |
| `GET /groups` | A | q, city, limit, cursor | 200 list | | R8 |
| `GET /me/groups` | A | limit, cursor | 200 list | | R7 |
| `GET /groups/{groupId}` | A | none | 200 Group | 404 `not_found` | R7 |
| `DELETE /groups/{groupId}` | A | none | 204 | 403 `forbidden`, 404 `not_found` | W5 |
| `GET /groups/{groupId}/members` | A | limit, cursor | 200 list | 403 `forbidden`, 404 `not_found` | R7 |
| `PUT /groups/{groupId}/members/me` | A | none | 201 joined, or 200 already in | 404 `not_found` | W5 |
| `DELETE /groups/{groupId}/members/me` | A | none | 204 | 404 `not_found` | W5 |
| `PATCH /groups/{groupId}/members/{userId}` | A | role | 200 Member | 403 `forbidden`, 404 `not_found`, 409 `last_admin` | W5 |
| `DELETE /groups/{groupId}/members/{userId}` | A | none | 204 | 403 `forbidden`, 404 `not_found`, 409 `last_admin` | W5 |
| `PUT /groups/{groupId}/invitations/{userId}` | A | none | 204 | 403 `forbidden`, 404 `not_found`, 409 `invitation_not_applicable` | W5 |
| `GET /groups/{groupId}/competitions` | A | limit, cursor | 200 list | 404 `not_found` | R5, R6 |
| `POST /competitions` | A | name, rule, visibility, startsAt, endsAt, gracePeriodSeconds?, city?, groupId?, consentToPublicLeaderboard? | 201 Competition | 403 `forbidden`, 404 `not_found`, 409 `competition_limit_reached`, 422 `consent_required` | W2, W3 |
| `GET /competitions` | A | q, city, state, limit, cursor | 200 list | | R8 |
| `GET /me/competitions` | A | status=active\|finished, limit, cursor | 200 list | | R6 |
| `GET /competitions/{competitionId}` | O | none | 200 Competition | 404 `not_found` | R5, W4 |
| `DELETE /competitions/{competitionId}` | A | none | 204 | 403 `forbidden`, 404 `not_found`, 409 `competition_not_deletable` | W3 |
| `GET /competitions/{competitionId}/participants` | A | limit, cursor | 200 list | 403 `forbidden`, 404 `not_found` | R5 |
| `PUT /competitions/{competitionId}/participants/me` | A | consentToPublicLeaderboard? | 201 joined, or 200 already in | 404 `not_found`, 409 `competition_limit_reached` `competition_join_closed`, 422 `consent_required` | W2, W3 |
| `DELETE /competitions/{competitionId}/participants/me` | A | none | 204 | 404 `not_found`, 409 `competition_leave_closed` | W3 |
| `PUT /competitions/{competitionId}/invitations/{userId}` | A | none | 204 | 403 `forbidden`, 404 `not_found`, 409 `invitation_not_applicable` | W3 |
| `GET /competitions/{competitionId}/leaderboard` | O | limit, cursor, If-None-Match | 200 Leaderboard, or 304 | 403 `full_leaderboard_forbidden`, 404 `not_found` | R2 |
| `GET /me/invitations` | A | none (newest 100) | 200 list | | W3, W5 |
| `DELETE /me/invitations/groups/{groupId}` | A | none | 204 | | W5 |
| `DELETE /me/invitations/competitions/{competitionId}` | A | none | 204 | | W3 |

**W4 (closure)** is a scheduled job with no endpoint of its own. Clients observe it through `state`, which is why `GET /competitions/{competitionId}` is tagged with it.

**Added beyond the requirements, and why:**

| Endpoint | Why |
|---|---|
| `PUT /me/password` | The only password control there is, with no email reset |
| `GET /users`, `GET /users/{userId}` | Friend requests and invitations need a way to find a person (D54) |
| `GET /users/{userId}/photos/{photoId}` | Photos are in private object storage, so they need a route |
| `GET /users/{userId}/runs` | Without it, `run_privacy` would do nothing in Phase 1 (D54) |
| `GET /groups/{groupId}/competitions` | The database already indexes it (`ix_competitions_group`) |
| `DELETE /competitions/{competitionId}` | The only fix for a mistake, since competitions can't be edited (D56) |
| `DELETE /groups/{groupId}/members/{userId}` | The admin role needs some real power |

**Deliberately left out, all addable without breaking anything:** editing groups or competitions, changing email, revoking invitations, listing a group's invitations, listing sessions.

**No accept endpoint for invitations.** Accepting is the same `PUT` as joining (section 11.3).

### 4.1 Finding people and viewing their data (D54)

**Search:** `GET /users?q=` matches display names, for logged-in users only, with at least 3 characters and at most 20 results. It returns `UserCard`, never email.

**The cost to accept:** anyone with an account can list names. Registration without email verification is cheap, so "logged-in only" is a weak barrier. A later "hide me from search" setting would be non-breaking.

**Rejected:**

| Alternative | Why |
|---|---|
| Exact email lookup | Confirms whether an email is registered, which is the enumeration leak section 8.5 tries to avoid |
| Friend code or link | Best for privacy, but needs a new column and sharing outside the app |
| Shared contexts only | Two friends with nothing in common could never connect |

**`UserCard`:** ID, display name and photo URL, for any logged-in user. `city` appears only on `GET /users/{userId}`, for friends and the user themselves. Birth date and email are never shown to anyone else.

**Runs** follow `run_privacy`: `public` means any logged-in user, `friends` means accepted friends, and `private` means the owner only. **Invalid runs are owner-only**, as are `status`, `invalidReason`, `receivedAt` and stats.

Run dates and times reveal a person's routine, which is why `private` stays the default, and why `public` doesn't extend to logged-out visitors.

---

## 5. Data placement

Ask one question for each piece of data.

| Location | Question it answers | Examples | Never |
|---|---|---|---|
| **Path** | *Which resource?* Identity only | `/competitions/{competitionId}` | Filters, secrets |
| **Query** | *How do I want to view it?* Never changes state | `q`, `city`, `state`, `limit`, `cursor` | Secrets, because URLs end up in logs and browser history |
| **Body** | *What state am I sending?* | Profile fields, GPX file, passwords | Anything on `GET` |
| **Headers** | *What is this request's metadata?* | Cookie, `Content-Type`, `X-Request-Id`, `If-None-Match` | Business data |

**Worked examples:**

| Data | Where | Why |
|---|---|---|
| Competition ID | Path | It says which resource |
| "Only running competitions" | Query | Same resource, different view |
| Search text | Query | Bookmarkable, and it changes no state |
| Consent flag on join | Body | It is state the client asserts |
| Password on account deletion | Body | A secret. This is also why deletion is `POST`: `DELETE` bodies have undefined meaning, and proxies may drop them |
| Session token | Cookie header | Metadata about who is asking, and never visible to JavaScript |
| Filename of a GPX file | Nowhere | The server doesn't use it |

**Filters** use plain names, and multiple values repeat the key: `state=upcoming&state=running`.

**Search parameters** are `q` for free text, plus named filters such as `city`. Matching is case-insensitive substring, and `%` and `_` in the input are escaped.

**Access logs record the route template, not the query string**, so `q=` searches for people's names stay out of logs.

---

