# Classes: Cross-cutting design

> **Covers:** Request IDs, metrics, exceptions, validation placement, the security filter chain, sessions, the rate limiter, ETags, configuration and absent versus null (9); scheduled jobs (10); extension points (12).
> **Read when:** working on `platform` code, a scheduled job, or planning an extension.
> **Related:** [modules.md](modules.md), [../api/errors-and-concurrency.md](../api/errors-and-concurrency.md), [../database/deletion-and-jobs.md](../database/deletion-and-jobs.md)

## 9. Cross-cutting design

### 9.1 Request ID and logging context

`RequestIdFilter` runs first. It accepts `X-Request-Id` only if it matches `^[A-Za-z0-9._-]{8,64}$`, and otherwise generates one, to prevent log injection (api 16). It sets MDC `requestId` and the response header, and clears MDC in `finally`. **MDC** (Mapped Diagnostic Context) is a per-thread map that the logger adds to every line, which is how the ID gets into every log line with no extra code.

`SessionAuthenticationFilter` adds MDC `userId`. Jobs use `job-<name>-<uuid>` as their ID (section 10).

`RequestLogFilter` writes one line per request: `method`, `route` (from Spring's best-matching-pattern attribute, or `unmatched`), `status`, `durationMs`, `errorCode`. **It never logs the query string, email, tokens, passwords, coordinates or file contents** (api 15).

Structured JSON logging uses Spring Boot's built-in support (section 15). No logging abstraction of our own.

### 9.2 Metrics hooks

| Metric | Source | Note |
|---|---|---|
| `http.server.requests` | Spring Boot, by configuration | Histogram buckets at 200 ms, 300 ms, 500 ms and 1 s, by route template |
| `pace.ingest.step` (timer) | `RunIngestService` | `step` is `parse`, `store` or `transaction` |
| `pace.ingest.outcome` (counter) | `RunIngestService` | `created`, `duplicate`, `overlap`, `invalid`, and each rejection |
| `pace.login.outcome` (counter) | `AuthService` | |
| `pace.ratelimit.rejected` (counter) | `RateLimiter` | By class |
| `pace.job.duration`, `pace.job.last_success` | `JobRunner` | By job |
| `pace.competition.overdue_closures` (gauge) | `CompetitionClosureJob` | The alert in database 6.5 |

`MeterRegistry` is used directly, with no wrapper classes. **No user IDs in labels** (api 16). Actuator runs on a separate port by configuration.

### 9.3 Exceptions and Problem Details (D64)

**One path:** a service throws `ApiException(ErrorCode, ...)`, `ProblemExceptionHandler` catches it, and `ProblemFactory` writes the body. Exceptions raised in filters take the same `ProblemFactory` through `ProblemSecurityHandlers` and `CsrfOriginFilter`, because filters run outside Spring MVC and `@RestControllerAdvice` can't see them.

`ProblemFactory` builds `type` as `urn:pace:problem:<code>`, `instance` from the path with no query string, and adds `requestId` from MDC.

**Rejected:** one exception class per code, which is 34 classes with no behavior. `ApiException` carries extensions such as `conflictingRunId` as data.

**Where each code is raised:**

| Code | Raised by |
|---|---|
| `malformed_request` | `ProblemExceptionHandler`, for an unreadable body, a type mismatch or an unknown field |
| `invalid_cursor` | `CursorCodec.decode` |
| `invalid_credentials` | `AuthService.login` |
| `unauthenticated` | `ProblemSecurityHandlers`, and `RunIngestService` when the user was deleted mid-upload |
| `forbidden` | `AccessDecision.enforce`, from `GroupPolicy` and `CompetitionPolicy` |
| `csrf_rejected` | `CsrfOriginFilter` |
| `password_incorrect` | `AccountService.changePassword`, `AccountDeletionService.deletePhase1` |
| `runs_not_visible` | `RunVisibilityPolicy`, through `RunQueryService.listForUser` |
| `full_leaderboard_forbidden` | `LeaderboardService.read` |
| `not_found` | `AccessDecision.enforce`, services, and `ProblemExceptionHandler` on a foreign-key failure |
| `method_not_allowed` | `ProblemExceptionHandler`, from Spring MVC |
| `email_taken` | `AccountService.register` |
| `run_overlap` | `RunIngestService.ingest` |
| `last_admin` | `GroupMembershipService` |
| `invitation_not_applicable` | `GroupMembershipService.invite`, `CompetitionInvitationService.invite` |
| `competition_limit_reached` | `ParticipationService.joinLocked` |
| `competition_join_closed` | `ParticipationService.joinLocked` |
| `competition_leave_closed` | `ParticipationService.leave` |
| `competition_not_deletable` | `CompetitionService.delete` |
| `payload_too_large` | `BodyLimitFilter`, `UploadSpool` |
| `unsupported_media_type` | `ProblemExceptionHandler`, `BodyLimitFilter` for compressed bodies, `RunController` |
| `validation_failed` | `ProblemExceptionHandler` for Bean Validation, plus `NewCompetition` and `Rule` |
| `weak_password` | `PasswordService.requireStrong` |
| `image_invalid` | `PhotoService.put` |
| `friend_self` | `FriendshipService.request` |
| `consent_required` | `ParticipationService.joinLocked`, `CompetitionService.create` |
| `gpx_malformed` | `GpxParser.parse` |
| `gpx_out_of_range` | `RunSanityRules.check` |
| `run_in_future` | `RunSanityRules.check` |
| `run_too_old` | `RunSanityRules.check` |
| `rate_limited` | `RateLimiter.check` |
| `internal_error` | `ProblemExceptionHandler`, for anything unexpected |
| `temporarily_unavailable` | `TransactionRunner`, `ProblemExceptionHandler` |
| `storage_unavailable` | `S3FileStore`, as `ApiException` |

### 9.4 Validation placement

| Layer | Checks | Example | Failure |
|---|---|---|---|
| **`web`** | Shape: types, unknown fields, ranges from the spec | `displayName` length, `limit` range | 400, 422 `validation_failed` |
| **`service` and `domain`** | Rules needing state, the clock or several fields | `NewCompetition` window, `RunSanityRules`, policies | 422, 403, 404, 409 |
| **Database** | The backstop. Should never fire for validated input | `ck_users_city`, `ck_runs_duration` | 500 and an alert |

**Request enum fields are `String` with `@Pattern`,** so an unknown value is 422 rather than 400. It parses, and breaks a rule (api 10.1). Query parameters follow the same rule, which is why the 7 list operations gained a declared 422 (section 16.2).

**A malformed path UUID is 400**, from Spring's type mismatch.

**Why validate twice:** the web layer gives good error messages, and the database is the only place immune to races and bugs. Neither replaces the other.

### 9.5 Security filter chain

**Spring Security stays, with its CSRF off.** It gives deny-by-default authorization, security headers and a request firewall for free, and it's worth learning. **Rejected:** plain servlet filters, which would mean rewriting those parts and getting them wrong.

```text
RequestIdFilter -> RequestLogFilter
  -> Spring Security: headers, CsrfOriginFilter, SessionAuthenticationFilter, authorization
  -> BodyLimitFilter -> DispatcherServlet -> RateLimitInterceptor -> controller
```

| Rule | Routes |
|---|---|
| Public | `POST /auth/register`, `POST /auth/login` |
| Optional | `GET /competitions/{competitionId}`, `GET /competitions/{competitionId}/leaderboard` |
| Authenticated | **Everything else, by default** |

Headers come from api 15. `CsrfOriginFilter` needs its own tests, because it replaces a framework default and a mistake fails silently (api 8.4).

### 9.6 Sessions and current-user resolution

`platform` owns the filter, but `identity` owns the table, so `SessionAuthenticator` connects them (section 2.3). A controller just declares `Viewer` or `Viewer.Authenticated` as a parameter, and `ViewerArgumentResolver` supplies it. A controller that declares `Viewer.Authenticated` can't run for an anonymous viewer.

**Renewal (CLS-8):** `SessionRepository.findValid` returns a `needsRenewal` flag computed in the same statement. Only when it's true does `renew` run, and the filter writes a new `Set-Cookie`. **Otherwise the browser would drop the cookie 30 days after login, however active the user is.**

**`SessionToken.generate`** uses 256 bits from `SecureRandom`, encoded as base64url. Only the SHA-256 is stored (D43).

### 9.7 Rate limiter

`RateLimitInterceptor` runs after authentication and before the controller, so the key can be the user. The class comes from `@RateLimit` if present, otherwise from the method: `GET` is `OTHER_READ`, or `ANONYMOUS_READ` with no user, and anything else is `OTHER_WRITE`.

| Class | Key | Where |
|---|---|---|
| `LOGIN` | IP, and email | IP in the interceptor. **Email in `AuthService`, because the body isn't parsed yet in the interceptor** |
| `REGISTER` | IP | Interceptor |
| `UPLOAD`, `FRIEND_INVITE`, `PHOTO_PASSWORD`, `SEARCH`, `OTHER_WRITE`, `OTHER_READ` | User | Interceptor |
| `ANONYMOUS_READ` | IP | Interceptor |

**Fails open** (D53): any limiter error is logged, and the request continues. The IP comes only from `ClientIpResolver`. Limits are per instance (api 14.1).

**A known small deviation:** a `consumes` mismatch is rejected during Spring's handler mapping, before the interceptor runs, so it isn't rate-limited. `POST /runs` declares no `consumes` and checks the type in `RunController`, to keep the order in api 7.2.

### 9.8 ETag and conditional requests

`LeaderboardEtag.of(view)` serializes `state`, `entries`, `me` and `nextCursor` to JSON, and returns a quoted SHA-256. `LeaderboardController` compares it with `If-None-Match`, and returns 304 with `ETag`, `Cache-Control: private, no-cache` and `Vary: Cookie`.

**Not `ShallowEtagHeaderFilter`,** which hashes the whole body including `asOf`, so it would never match (api 13). `viewerAccess` isn't in the hash, because a change of access always changes `me`.

Every other endpoint is `no-store`, and photos are `private, max-age=31536000, immutable`. Controllers set these through one small helper in `platform.web`.

### 9.9 Configuration properties

One immutable `@ConfigurationProperties` record per module, validated at startup. **Rejected:** one global properties class, which would make every module depend on every setting. **Starting values come from the design documents, and they're all configurable.**

| Property | Default | Class | Used by |
|---|---|---|---|
| `pace.platform.origin` | none, required | `PlatformProperties` | `CsrfOriginFilter` |
| `pace.platform.trusted-proxy-header` | `X-Real-IP` | `PlatformProperties` | `ClientIpResolver` |
| `pace.platform.body-limit.json` | 64 KB | `PlatformProperties` | `BodyLimitFilter` |
| `pace.platform.rate-limits.*` | api 14.1 | `PlatformProperties` | `RateLimiter` |
| `pace.tx.default-timeout` | 30 s | `TxProperties` | `TransactionRunner` |
| `pace.tx.max-retries` | 2 | `TxProperties` | `TransactionRunner` |
| `pace.tx.jitter` | 50 to 200 ms | `TxProperties` | `TransactionRunner` |
| `pace.jobs.enabled` | `true` | `PlatformProperties` | All jobs |
| `pace.identity.session.sliding` | 30 days | `IdentityProperties` | `SessionRepository` |
| `pace.identity.session.absolute` | 90 days | `IdentityProperties` | `SessionRepository` |
| `pace.identity.session.renewal-interval` | 1 hour | `IdentityProperties` | `SessionRepository` |
| `pace.identity.cookie.name`, `.secure` | `__Host-pace_session`, `true` | `IdentityProperties` | `SessionCookies` |
| `pace.identity.argon2.*` | 19 MiB, t=2, p=1 | `IdentityProperties` | `PasswordService` |
| `pace.identity.argon2.max-concurrent` | 4 | `IdentityProperties` | `PasswordService` |
| `pace.identity.photo.max-bytes`, `.size` | 2 MB, 512 | `IdentityProperties` | `PhotoService`, `BodyLimitFilter` |
| `pace.identity.purge.batch`, `.timeout` | 50, 5 min | `IdentityProperties` | `AccountPurgeJob` |
| `pace.runs.max-upload-bytes` | 20 MB | `RunsProperties` | `UploadSpool`, `BodyLimitFilter` |
| `pace.runs.max-trackpoints` | 200,000 | `RunsProperties` | `GpxParser` |
| `pace.runs.max-age` | **30 days** (D36) | `RunsProperties` | `RunSanityRules` |
| `pace.runs.future-tolerance` | 2 min | `RunsProperties` | `RunSanityRules` |
| `pace.runs.max-duration` | **7 days** (D36) | `RunsProperties` | `RunSanityRules` |
| `pace.runs.plausibility.*` | 150 and 1,800 s/km, 15 m/s, 50 m, 48 h (D49) | `RunsProperties` | `PlausibilityRules`, `GpxParser` |
| `pace.runs.orphan.min-age` | 1 day | `RunsProperties` | `OrphanFileCleanupJob` |
| `pace.runs.stats.pace-distances` | 1K, 5K, 10K, half, marathon | `RunsProperties` | `StatsService` |
| `pace.competitions.grace-default` | **6 hours** (D28) | `CompetitionProperties` | `NewCompetition` |
| `pace.competitions.grace-max` | 72 hours | `CompetitionProperties` | `NewCompetition` |
| `pace.competitions.max-open` | **10** | `CompetitionProperties` | `ParticipationService` |
| `pace.competitions.max-backdate` | 30 days | `CompetitionProperties` | `NewCompetition` |
| `pace.competitions.max-window` | 366 days | `CompetitionProperties` | `NewCompetition` |
| `pace.competitions.closure-delay` | 60 s | `CompetitionProperties` | `CompetitionClosureJob` |
| `pace.competitions.closure-timeout` | 60 s | `CompetitionProperties` | `CompetitionClosureJob` |
| `pace.leaderboards.top-n` | **10** (D16) | `LeaderboardProperties` | `LeaderboardService` |
| `pace.leaderboards.poll-interval` | 25 s (D51) | `LeaderboardProperties` | `LeaderboardService` |

**`max-age` and `max-backdate` are separate on purpose.** Both start at 30 days, but one limits run files, and the other limits competition windows.

### 9.10 Absent versus null in responses (D65)

The contract separates absent ("you aren't entitled to this") from null ("no value"). Plain Java records can't express that, so:

| Shape | Answer | Example |
|---|---|---|
| Two shapes with different field sets | **Two records** | `RunDto`, `OwnRunDto`. `TopNEntryDto`, `FullEntryDto`. `UserCardDto`, `UserCardWithCityDto` |
| A field with three states: absent, null, value | **`JsonNullable<T>`** | `Competition.createdBy`, `Leaderboard.me` |
| Object that's absent or present, never null | `@JsonInclude(NON_NULL)` | `Competition.viewer` |

**`JsonNullable` also solves `PATCH /me`** (api 3.4): `UpdateMeRequest` fields are `JsonNullable<String>` and so on, so "absent means unchanged" works. Its Jackson 3 and record support needs a short test (section 15).

**Rejected:** a `Map` for `PATCH` (no type checks), and one big DTO with `NON_NULL` (`photoUrl` for a full viewer can really be null, and that would drop it).

---

## 10. Scheduled jobs

Jobs run inside the application process for now (D26).

| Job class | Schedule | Across instances | Timeout | Observability |
|---|---|---|---|---|
| `CompetitionClosureJob` | Every minute | Waits on `FOR UPDATE`, and the second sees `closed_at` | 60 s | Overdue gauge |
| `AccountPurgeJob` | Every minute, up to 50 users per tick | `SKIP LOCKED` | 5 min | Purged count, alert on backlog |
| `OrphanFileCleanupJob` | Daily | No lock, repeating is harmless | Not in a transaction | Deleted count |
| `SessionCleanupJob` | Daily | No lock, repeating is harmless | Default | Deleted count |

**Structure.** Each job has a public `runOnce()` doing one tick's work. A thin `@Scheduled` method calls it through `JobRunner`. **Tests call `runOnce()` directly**, with scheduling turned off by `pace.jobs.enabled=false`, so no test has to wait for a timer.

**`JobRunner`** sets MDC `requestId` to `job-<name>-<uuid>`, records a timer and last-success time, catches and logs every exception, and returns. An exception must never kill the scheduler, and the next tick retries.

**`fixedDelay`, not `fixedRate`:** the next run starts after the last one ends, so runs can't overlap inside one instance.

**The thread pool** has 4 threads by configuration, so a long purge can't delay closure.

**Why no ShedLock** (a library that keeps a job on one instance): every job is already safe to run on several instances at once.

**Error handling, per job:**
- **Closure:** one transaction per competition, and a failure is logged and retried at the next tick.
- **Purge:** the row is the retry marker.
- **Orphans:** one object's failure is logged, and the scan continues.

**Testing with a fixed clock.** `OrphanFileCleanupJob` compares object age against the injected `Clock`, so tests use `Clock.fixed`. Closure compares in SQL with the database's `now()`, so its tests seed rows relative to real time, for example `closes_at = now() - interval '2 minutes'`. **Mocking the database clock isn't possible, and it isn't needed.**

**Seam:** when the worker of the deferred queue milestone arrives, the same classes move to it unchanged.

---

## 12. Extension points

**Seams only. None of this is built now.**

### Outbox and queue (database 9)

**The seam is `RunAcceptedListener`.** Today, `ScoringService` implements it and scores inside the ingest transaction. At the milestone:

1. A new implementation writes `outbox_events` in that same transaction.
2. A worker calls `ScoringService.rescoreForRun(run)`, the same scoring steps that run today.
3. `CompetitionClosureJob` gains the recalculation that database 9.3 requires under its lock.

`RunIngestService` doesn't change. The 201 stays, because D48 deliberately doesn't return affected competitions.

### A new competition type (Phase 2)

1. Add a `RuleType` value, with its `ScoreDirection` and `ScoreUnit`.
2. Migrate `ck_competitions_rule_type`. The enum test fails until you do.
3. Add one strategy class. Startup fails until you do.
4. If it needs a new aggregate, add one `EligibleRunsReader` method. **Area coverage or streaks** may need a different read, or a new column, which is fine, because the strategy decides.
5. Add the rule's parameters to `Rule` and `RuleRequest`.

**Team vs team** is the one that doesn't fit, since it changes who a participant is. It'll need its own design step.

### Route geometry

Add a field to `ParsedRun`, a migration, and a new endpoint that applies the privacy zone (open question 9, api 15). `GpxParser` already streams each point, so collecting a polyline is local to it.

### History import without scoring (backlog)

Add a `RunSource` value, and an ingest path that skips the listener and the age check.

**A catch to record now:** skipping the listener isn't enough. Scoring recalculates from *all* eligible runs. An imported run that falls inside a long competition's window would be counted by that user's next recalculation. **`EligibleRunsReader` must also exclude that source**, and `findEligibleForRun` needs no change, since import never calls it.

### Email flows (D50)

A new `EmailSender` port in `identity` only, plus `EmailVerificationService` and `PasswordResetService`. Registration's response gains `emailVerifiedAt`, which is additive. Password-reset tokens get a table with the same hash-only rule as sessions. Registration moves to the "we've sent you an email" response, which ends the enumeration exception in api 8.5.

### Other room left

| Future | Seam |
|---|---|
| Live recording | A new caller of the ingest steps, starting from `ParsedRun`, plus a `RunSource` value |
| Redis leaderboards | `LeaderboardReader` is the only class to change |
| Bearer tokens | A second filter next to `SessionAuthenticationFilter`, using the same `SessionAuthenticator` |
| Service split | `api/` interfaces become clients, and section 2.5 lists the joins to replace |

---

