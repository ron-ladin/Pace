# API: Contract, mapping and verification

> **Covers:** Contract-first tooling and test strategy (17), the mapping from endpoints to the database (18), coverage of access patterns and requirements (20), verification results (21) and sources (22).
> **Read when:** tracing an endpoint to its tables, checking coverage, or checking what was verified.
> **Related:** [../../api/verification/README.md](../../api/verification/README.md), [endpoints.md](endpoints.md), [../database/indexes-and-queries.md](../database/indexes-and-queries.md)

## 17. Contract, tooling and tests

### 17.1 Contract-first (D52)

`docs/api/openapi.yaml` is a hand-maintained OpenAPI 3.1 file. It is the source of truth, written before the code, because the frontend must be able to start before the backend exists.

**Rejected:** generating it from code with springdoc. It is convenient later, but it makes the contract depend on code that doesn't exist, and it tends to document whatever the code happens to do.

**Structure:** one file with shared `components` for schemas, parameters, headers, responses and error examples. Optional auth is `security: [{}, {sessionCookie: []}]`. Each operation has `x-access-patterns`, so coverage can be checked by a script.

### 17.2 Linting

Spectral (free, open source, and supports OpenAPI 3.1) with `docs/api/.spectral.yaml`, plus Redocly CLI as a second opinion. Project rules require access patterns, explicit security on each operation, declared 429/500/503, Problem Details errors and camelCase properties. `docs/api/verification/check_coverage.mjs` adds schema checks for every example, and checks that this document's tables match the spec.

**CI wiring waits for the infrastructure step** in the order of work. Instructions are in [`docs/api/verification/README.md`](../../api/verification/README.md).

### 17.3 Test strategy (design level)

| Level | Covers | Why here |
|---|---|---|
| Controller tests | Status codes, error shape, cookies, auth rules | Fast, and needs no database |
| Service tests | Business rules, such as thresholds and competition rules | Fast, and needs no HTTP |
| Integration tests, with Testcontainers | Real PostgreSQL 18 and MinIO, including the race tests in database 11.3 | **Mocks can't prove lock behavior** |
| Authorization tests, driven from the matrix | Each row in section 9.2 becomes a test, including 404 versus 403 | The easiest bugs to miss, and the most damaging |
| Hostile fixtures | XXE, billion laughs, truncated GPX, oversized images, spoofed magic bytes | Security requirements need proof |
| CSRF filter tests | Each header combination | It replaces a framework default |
| Contract tests | Real responses checked against `openapi.yaml` | Detects drift between code and spec |

**Drift detection candidates:** Schemathesis, which generates requests from a spec and checks the responses, and `oasdiff` in CI, which flags breaking spec changes. **Neither has been tried yet**, and their OpenAPI 3.1 support should be confirmed with a short test during the vertical slice.

---

## 18. Mapping to the database

Section numbers refer to `database.md`. "Plan" says whether a query plan has been observed, in database 13.2 or 14.7. **A plan confirms index use, not performance.**

| Endpoint | Query or transaction | Index | Plan | Note |
|---|---|---|---|---|
| Any authenticated request | 14.1 | `sessions_pkey`, `users_pkey` | Observed | R1 |
| `POST /auth/register` | Insert user, session | `uq_users_email_lower` | Index by design | Argon2id takes most of the time, deliberately |
| `POST /auth/login` | Read user, insert session | `uq_users_email_lower` | Index by design | Same |
| `POST /auth/logout` | Delete by token hash | `sessions_pkey` | Observed | |
| `GET /me` | User by ID | `users_pkey` | Observed | |
| `PATCH /me` | Update by ID | `users_pkey` | Observed | |
| `PUT /me/password` | Update user, revoke sessions | `ix_sessions_user` | Observed | |
| `POST /me/deletion` | 6.6 and 14.4 | `ix_sessions_user`, foreign keys | Observed | |
| `PUT /me/photo` | Store file, update user | `users_pkey` | Observed | Object storage dominates |
| `DELETE /me/photo` | Update user, delete file | `users_pkey` | Observed | |
| `GET /me/stats` | Aggregates in the user's time zone | `ix_runs_user_started`, `ex_runs_no_overlap` | Observed | Planner picks. Reads all of one user's runs for personal bests |
| `GET /users` | `display_name ILIKE` | None | Observed | **Sequential scan** |
| `GET /users/{userId}` | By ID, plus friendship check | `users_pkey`, `friendships_pkey` | Observed | |
| `GET /users/{userId}/photos/{photoId}` | By ID, then object storage | `users_pkey` | Observed | |
| `GET /users/{userId}/runs` | 7.5, `status = 'valid'` | `ix_runs_user_started`, `friendships_pkey` | Observed | |
| `POST /runs` | 14.2, 6.3, 6.2 | `uq_runs_user_file_hash`, `ex_runs_no_overlap`, `ix_participants_user`, `ix_competitions_to_close`, `ix_runs_user_started` | Observed | Includes the overlap lookup |
| `GET /me/runs` | 7.5 | `ix_runs_user_started` | Observed | |
| `GET /runs/{runId}` | By ID, then a privacy check | `runs_pkey`, `friendships_pkey` | By design | |
| `GET /me/friends` | `UNION ALL` of both sides | `friendships_pkey`, `ix_friendships_user_b` | Observed | Keyset filter reaches both sides |
| `PUT /me/friends/{userId}` | Insert or update by key | `friendships_pkey` | By design | |
| `DELETE /me/friends/{userId}` | Delete by key | `friendships_pkey` | By design | |
| `POST /groups` | Insert group and admin | `group_members_pkey` | By design | |
| `GET /groups` | `name`, `city ILIKE` | None | Observed | **Sequential scan** |
| `GET /me/groups` | Keyset on `group_id` | `ix_group_members_user` | Observed | |
| `GET /groups/{groupId}` | By ID, plus `memberCount` | `groups_pkey`, `group_members_pkey` | By design | A count, on details only |
| `DELETE /groups/{groupId}` | Delete, with `SET NULL` on competitions | `groups_pkey`, `ix_competitions_group` | By design | Admin check under the lock |
| `GET /groups/{groupId}/members` | Keyset on `user_id` | `group_members_pkey` | Observed | |
| `PUT /groups/{groupId}/members/me` | Insert, delete invitation | `group_members_pkey`, `group_invitations_pkey` | By design | |
| `DELETE /groups/{groupId}/members/me` | 14.6 | `group_members_pkey` | By design | Group row lock |
| `PATCH /groups/{groupId}/members/{userId}` | 14.6 | `group_members_pkey` | By design | Group row lock |
| `DELETE /groups/{groupId}/members/{userId}` | 14.6 | `group_members_pkey` | By design | Group row lock |
| `PUT /groups/{groupId}/invitations/{userId}` | Insert with `ON CONFLICT` | `group_invitations_pkey` | By design | |
| `GET /groups/{groupId}/competitions` | By group, small sort | `ix_competitions_group` | Observed | |
| `POST /competitions` | 14.6, 6.4 step 5 | `ix_participants_user`, `ix_runs_user_started` | Observed | Limit check and backfill |
| `GET /competitions` | `name`, `city ILIKE` | `ix_competitions_to_close`, or none | Observed | The planner used the partial index for open competitions |
| `GET /me/competitions` | Keyset on `competition_id` | `ix_participants_user`, `competitions_pkey` | Observed | **Filter applied after the join**, with a small sort. Few rows per user. No rank here, which would be one count query per row |
| `GET /competitions/{competitionId}` | By ID, plus viewer lookups and `participantCount` | `competitions_pkey`, `competition_participants_pkey` | Observed | The count reads up to 5,000 index entries |
| `DELETE /competitions/{competitionId}` | 14.6 | `competitions_pkey` | By design | |
| `GET /competitions/{competitionId}/participants` | Keyset on `user_id` | `competition_participants_pkey`, `users_pkey` | Observed | |
| `PUT /competitions/{competitionId}/participants/me` | 14.3, 6.4 | `competition_participants_pkey`, `ix_participants_user`, `ix_runs_user_started` | Observed | |
| `DELETE /competitions/{competitionId}/participants/me` | 6.4 | `competition_participants_pkey` | By design | |
| `PUT /competitions/{competitionId}/invitations/{userId}` | Insert with `ON CONFLICT` | `competition_invitations_pkey` | By design | |
| `GET /competitions/{competitionId}/leaderboard` | 7.1, 7.2, keyset | `ix_participants_leaderboard`, `ix_users_deleted`, `competition_participants_pkey` | Observed | **Slowest read:** up to 5,000 index entries for `me` |
| `GET /me/invitations` | Both tables, sort, limit 100 | `ix_group_invitations_invitee`, `ix_competition_invitations_invitee` | Observed | |
| `DELETE /me/invitations/groups/{groupId}` | Delete by key | `group_invitations_pkey` | By design | |
| `DELETE /me/invitations/competitions/{competitionId}` | Delete by key | `competition_invitations_pkey` | By design | |

"By design" means a simple key lookup that wasn't run separately.

**Endpoints with no efficient index, by design:** `GET /users`, `GET /groups` and, for mid-word matches, `GET /competitions` scan sequentially. This follows "measure first": `pg_trgm` is the existing trigger if p95 passes 500 ms (database 11.4).

**A data-quality limit:** city is free text, so "Tel Aviv" and "tel-aviv" won't match each other. Accepted for Phase 1.

---

## 20. Coverage

### 20.1 Access patterns

| Pattern | Operation | Endpoints |
|---|---|---|
| R1 | Authenticate request | Every authenticated endpoint. Sessions are created by `POST /auth/login` and `POST /auth/register`, and removed by `POST /auth/logout` |
| R2 | Leaderboard, top N and my rank | `GET /competitions/{competitionId}/leaderboard` |
| R3 | My run history | `GET /me/runs`, `GET /runs/{runId}`, and for others, `GET /users/{userId}/runs` |
| R4 | My stats | `GET /me/stats` |
| R5 | Competition details and participants | `GET /competitions/{competitionId}`, `GET /competitions/{competitionId}/participants`, `GET /groups/{groupId}/competitions` |
| R6 | My competitions | `GET /me/competitions`, `GET /groups/{groupId}/competitions` |
| R7 | Friends and group members | `GET /me/friends`, `GET /groups/{groupId}/members`, `GET /me/groups`, `GET /groups/{groupId}`, `GET /users`, `GET /users/{userId}`, `GET /users/{userId}/photos/{photoId}` |
| R8 | Search public groups and competitions | `GET /groups`, `GET /competitions` |
| W1 | Upload run | `POST /runs` |
| W2 | Update scores | Inside `POST /runs`, `PUT /competitions/{competitionId}/participants/me` and `POST /competitions` |
| W3 | Create, join, leave competition | `POST /competitions`, `PUT /competitions/{competitionId}/participants/me`, `DELETE /competitions/{competitionId}/participants/me`, `DELETE /competitions/{competitionId}`, `PUT /competitions/{competitionId}/invitations/{userId}`, `GET /me/invitations`, `DELETE /me/invitations/competitions/{competitionId}` |
| W4 | Close competition | No endpoint: a scheduled job. Observed through `state` on `GET /competitions/{competitionId}` |
| W5 | Friend requests, group actions | `PUT /me/friends/{userId}`, `DELETE /me/friends/{userId}`, `POST /groups`, `DELETE /groups/{groupId}`, `PUT /groups/{groupId}/members/me`, `DELETE /groups/{groupId}/members/me`, `PATCH /groups/{groupId}/members/{userId}`, `DELETE /groups/{groupId}/members/{userId}`, `PUT /groups/{groupId}/invitations/{userId}`, `GET /me/invitations`, `DELETE /me/invitations/groups/{groupId}` |
| W6 | Registration, profile, deletion | `POST /auth/register`, `GET /me`, `PATCH /me`, `PUT /me/password`, `PUT /me/photo`, `DELETE /me/photo`, `POST /me/deletion` |

### 20.2 Phase 1 functional requirements

From section 4 of `ARCHITECTURE.md`.

| Requirement | Endpoints |
|---|---|
| Register | `POST /auth/register` |
| Log in | `POST /auth/login` |
| Log out | `POST /auth/logout` |
| Edit profile: display name, photo, birth date, city | `PATCH /me`, `PUT /me/photo`, `DELETE /me/photo` |
| Set run privacy | `PATCH /me`, with `runPrivacy` |
| Delete account | `POST /me/deletion` |
| Upload a GPX file | `POST /runs` |
| Compute distance, duration and pace | `POST /runs`, section 7.6 |
| Reject duplicates | `POST /runs` returns the existing run with 200 |
| Reject overlapping runs | `POST /runs` returns 409 `run_overlap` |
| Reject future runs | `POST /runs` returns 422 `run_in_future` |
| Reject runs older than the limit | `POST /runs` returns 422 `run_too_old` |
| Store implausible runs as invalid | `POST /runs` returns 201 with `status: invalid` |
| View history | `GET /me/runs`, `GET /runs/{runId}` |
| Personal stats | `GET /me/stats` |
| Users cannot delete runs | No endpoint, by design (D14) |
| Send a friend request | `PUT /me/friends/{userId}` |
| Accept a friend request | `PUT /me/friends/{userId}` |
| Decline a friend request | `DELETE /me/friends/{userId}` |
| Remove a friend | `DELETE /me/friends/{userId}` |
| Create a public or private group | `POST /groups` |
| Group roles | `PATCH /groups/{groupId}/members/{userId}`, `DELETE /groups/{groupId}/members/{userId}`, `PUT /groups/{groupId}/invitations/{userId}` |
| Search public groups by name and area | `GET /groups` |
| Create a competition | `POST /competitions` |
| Join a competition | `PUT /competitions/{competitionId}/participants/me` |
| Leave a competition | `DELETE /competitions/{competitionId}/participants/me` returns 409 from `endsAt` on (D39) |
| Backfill on join | `PUT /competitions/{competitionId}/participants/me` returns the backfilled `score` (D31) |
| Public top N consent | `PUT /competitions/{competitionId}/participants/me`, `GET /competitions/{competitionId}/leaderboard` (D16, D55) |
| Leaderboard updates after each run | `POST /runs` scores synchronously, read by `GET /competitions/{competitionId}/leaderboard` (D26) |
| Finalizing state | `state` on `GET /competitions/{competitionId}` and `GET /competitions/{competitionId}/leaderboard` |
| Final result | `state: closed` on `GET /competitions/{competitionId}` (D17) |
| Rule types | `rule` on `POST /competitions`: `total_distance`, `longest_run`, `fastest_pace` |
| Run evaluated against all active competitions | Inside `POST /runs` (D19) |

---

## 21. Verification

**Performance claims remain predictions until load tests exist.** Nothing below measures latency under load.

### 21.1 What passed

Steps to reproduce: [`docs/api/verification/README.md`](../../api/verification/README.md) and [`verification/README.md`](../verification/README.md).

| Check | Tool | Result |
|---|---|---|
| The contract is valid OpenAPI 3.1 | Spectral 6.17.0 and Redocly CLI 2.73.0, in a `node:22-alpine` container | Pass, with no errors. One warning remains, listed below |
| Project lint rules | Spectral, with a broken copy of the spec as a negative control | Pass. Each of the 5 project rules fired on its deliberate defect |
| Every example conforms to its schema | `check_coverage.mjs` (Ajv), and Spectral's example rules | 395 of 395. Negative controls were rejected |
| Every operation has an auth rule, success response and error cases | `check_coverage.mjs` | 45 of 45 |
| Every R1-R8 and W1-W6 pattern is covered | `check_coverage.mjs` | 14 of 14 |
| Every Phase 1 requirement row names an endpoint | `check_coverage.mjs` | 33 of 33 |
| Section 4 matches the spec on auth, success, errors and patterns | `check_coverage.mjs` | 45 of 45 |
| Section 10.2 matches the spec | `check_coverage.mjs` | 34 codes. `method_not_allowed` is framework-level, and deliberately not in the spec |
| Every D-number, index and endpoint cited here exists | `check_coverage.mjs` | Pass |
| Mermaid diagrams parse | `check_mermaid.mjs` | Pass, with a negative control |
| Schema amendments and query plans | PostgreSQL 18.6, see database 14.7 | 13 of 13 checks, and the plans listed there |
| The original schema suites still pass | `01_constraints.sql`, `02_locks.sql` | 72 of 72, and 28 of 28 |
| OWASP Argon2id parameters | Read on the OWASP page | Confirmed: 19 MiB, t=2, p=1 |

**Remaining linter warning:** `info-license` (Redocly): the spec has no `license` field. This is left as it is, because the project has no license yet, and inventing one in the spec would be wrong. Choosing a license is the project owner's decision.

### 21.2 What wasn't verified

- **Any behavior.** No application exists, so nothing here shows that an implementation will conform. The checks cover the contract's consistency only.
- **Latency.** No load test has run. The plans confirm index use on an idle, cached and freshly vacuumed sample. `participantCount` and "my rank" reading about 5,000 index entries are the first things to measure.
- **My estimates:** the plausibility thresholds, rate limits, the 20 MB limit, the 60-second dwell time and the 10x peak. None comes from real data.
- **Tools named for later:** Schemathesis, `oasdiff`, Bucket4j and ArchUnit weren't run. Their availability and OpenAPI 3.1 support should be confirmed when they're adopted.
- **The `Sec-Fetch-Site` filter in real browsers,** including installed PWAs and the `__Host-` cookie on `localhost`.
- **Free email limits,** which come from third-party comparisons that disagree with each other.
- **Spring specifics,** such as its Argon2 defaults and JSON Merge Patch handling, come from my knowledge rather than a check against the version we'll use.

---

## 22. Sources

**Read directly:**
- [OWASP Password Storage Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html): Argon2id minimum parameters and the bcrypt 72-byte limit.
- [OWASP CSRF Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html): Fetch Metadata, `Origin` fallback, and `SameSite` as defense in depth.

**From search results, not read in full. Re-check before relying on them:**
- [Spectral](https://github.com/stoplightio/spectral/): OpenAPI 3.1 support.
- [A modern approach to preventing CSRF in Go](https://alexedwards.net/blog/preventing-csrf-in-go), and [CSRF Protection via Headers in Go 1.25](https://www.calhoun.io/csrf-protection-via-headers-in-go-125/): how `CrossOriginProtection` works, and its HTTP downgrade gap.
- [Resend free tier](https://automationatlas.io/answers/resend-free-tier-explained-2026/), [Brevo free plan](https://costbench.com/software/email-api/brevo-transactional/free-plan/) and [email API free tiers compared](https://cli.nylas.com/guides/email-api-free-tiers-compared): third-party comparisons, which disagree on Brevo's limit.
