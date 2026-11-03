# Classes: Class inventory

> **Covers:** Every class per module, with its kind, visibility and responsibility. Its rows are long, so search for a class name rather than reading it all.
> **Read when:** looking up what a class does, or adding a class. `check_classes.mjs` reads this table.
> **Related:** [modules.md](modules.md), [diagrams.md](diagrams.md), [traceability.md](traceability.md)

## 3. Class inventory

**How to read these tables.** "pub" means `public`, and "pp" means package-private. The Tx column names a transaction boundary, with locks in order. Section 8 has each flow in full. "Errors" lists `ErrorCode` values a method can raise, and every method can also fail with `temporarily_unavailable` or `internal_error`. Trivial getters aren't listed, and neither are method bodies, because there aren't any yet.

### 3.1 `platform`

| Class | Kind, visibility | Responsibility | Key fields | Key methods and errors | Tx, locks | Collaborators |
|---|---|---|---|---|---|---|
| `ErrorCode` | enum, pub | Lists the 34 catalog codes with their status and title | `String code`, `int status`, `String title` | `String typeUri()` | | |
| `ApiException` | class, pub | Represents any expected failure, as a code with optional detail and extensions | `ErrorCode code`, `String detail`, `Map<String,Object> extensions`, `Duration retryAfter` | `static notFound()`, `static forbidden()`, `static validation(List<FieldError>)` | | `ErrorCode` |
| `FieldError` | record, pub | Holds one entry of a Problem's `errors` array | `String field`, `String code`, `String message` | | | |
| `ProblemFactory` | class, pub | Builds every Problem Details body in one place | `Clock clock` | `ProblemDetail build(ErrorCode, String detail, Map ext, String instance)`, `void write(HttpServletResponse, ApiException)` | | MDC |
| `ProblemExceptionHandler` | `@RestControllerAdvice`, pp | Maps every exception that reaches Spring MVC to a Problem | `ProblemFactory factory`, `DbErrors dbErrors` | `@ExceptionHandler` methods for `ApiException`, validation, unreadable body, type mismatch, method not allowed, unsupported media type, `DataAccessException`, `Exception` | | `ProblemFactory`, `DbErrors` |
| `DbErrors` | class, pub | Reads the SQLSTATE and constraint name from a database exception | | `Optional<DbFailure> classify(DataAccessException)`, `boolean isConstraint(DataAccessException, String name)`, `boolean isRetryable(DataAccessException)` | | pgjdbc `PSQLException` |
| `DbFailure` | record, pub | Holds what a failure was | `String sqlState`, `String constraint` | | | |
| `TransactionRunner` | class, pub | Runs a write in a transaction, with a timeout and bounded deadlock retry | `TransactionTemplate template`, `JdbcClient jdbc`, `TxProperties props` | `<T> T write(Supplier<T> body)`, `<T> T write(Duration timeout, Supplier<T> body)`. Errors: `temporarily_unavailable` after retries | Starts or joins | `DbErrors` |
| `RowLocks` | class, pub | Holds every row-lock statement, and enforces the global lock order | `JdbcClient jdbc` | `boolean lockActiveUser(UserId, LockMode)`, `boolean lockGroup(GroupId, LockMode)`, `Optional<LockedCompetition> lockCompetition(CompetitionId, LockMode)`, `boolean lockParticipant(CompetitionId, UserId)` | Requires a running transaction. Takes the lock asked for | `Ids` |
| `LockMode` | enum, pub | Names the three lock strengths used by the design | `SHARE`, `NO_KEY_UPDATE`, `UPDATE` | `String sql()` | | |
| `LockedCompetition` | record, pub | Reports what a competition lock found | `Instant closedAt` (nullable) | | | |
| `TxProperties` | record, pub | Holds the transaction timeout and retry settings | `Duration defaultTimeout`, `int maxRetries`, `Duration minJitter`, `Duration maxJitter` | | | |
| `SecurityConfig` | config, pp | Defines the filter chain, deny-by-default rules and security headers | | `SecurityFilterChain chain(HttpSecurity)` | | Filters below |
| `CsrfOriginFilter` | filter, pp | Rejects unsafe requests that aren't same-origin (D44) | `String allowedOrigin` | `doFilterInternal(...)`. Errors: `csrf_rejected` | | `ProblemFactory` |
| `SessionAuthenticationFilter` | filter, pp | Turns a session cookie into a `Viewer`, and refreshes the cookie when renewed | `SessionAuthenticator authenticator`, `SessionCookies cookies` | `doFilterInternal(...)`. An invalid cookie leaves the viewer anonymous | Autocommit | `SessionAuthenticator`, `SessionCookies`, `TokenHash` |
| `SessionAuthenticator` | interface, pub | Validates a session for the filter (SPI, section 2.3) | | `Optional<AuthenticatedSession> authenticate(byte[] tokenHash)` | | |
| `AuthenticatedSession` | record, pub | Holds who was authenticated, and how long a refreshed cookie should last | `UserId userId`, `Optional<Duration> refreshCookieFor` | | | |
| `TokenHash` | class, pub | Computes the SHA-256 of a raw session token | | `static byte[] of(String rawToken)` | | |
| `SessionCookies` | class, pub | Writes and clears the session cookie | `String name`, `boolean secure` | `void write(HttpServletResponse, String rawToken, Duration maxAge)`, `void clear(HttpServletResponse)`, `Optional<String> read(HttpServletRequest)` | | |
| `ProblemSecurityHandlers` | class, pp | Writes Problems for 401 and 403 raised by Spring Security | `ProblemFactory factory` | `commence(...)`, `handle(...)`. Errors: `unauthenticated` | | `ProblemFactory` |
| `Viewer` | sealed interface, pub | Says who is asking | `Anonymous`, `Authenticated(UserId id)` | `Optional<UserId> userId()` | | |
| `ViewerArgumentResolver` | class, pp | Injects `Viewer` or `Viewer.Authenticated` into controller methods | | `resolveArgument(...)` | | |
| `AccessDecision` | enum, pub | Holds a policy's answer | `ALLOWED`, `HIDDEN`, `FORBIDDEN` | `void enforce()`, `void enforce(ErrorCode forbiddenCode)`. Errors: `not_found`, `forbidden` | | |
| `RequestIdFilter` | filter, pp | Accepts or generates `X-Request-Id`, and sets MDC and the response header | | `doFilterInternal(...)` | | MDC |
| `RequestLogFilter` | filter, pp | Writes one structured log line per request, using the route template | | `doFilterInternal(...)` | | MDC |
| `BodyLimitFilter` | filter, pp | Wraps the request body with a per-route byte limit, and refuses compressed bodies | `Map` of route to limit | `doFilterInternal(...)`. Errors: `payload_too_large`, `unsupported_media_type` | | |
| `Page` | record, pub | Holds one page of results | `List<T> items`, `String nextCursor` | `static <T,C> Page<T> of(List<T> rows, int limit, Function<T,C> cursorOf, CursorCodec)` | | `CursorCodec` |
| `PageRequest` | record, pub | Holds a validated limit and a decoded cursor | `int limit`, `C cursor` | `int fetchSize()` (limit plus one) | | |
| `CursorCodec` | class, pub | Encodes and decodes opaque versioned cursors | `ObjectMapper mapper` | `String encode(C cursor)`, `<C> C decode(String, Class<C>)`. Errors: `invalid_cursor` | | |
| `ClientIpResolver` | class, pub | Finds the client IP, trusting only the configured proxy header | `String trustedHeader` | `String resolve(HttpServletRequest)` | | |
| `JacksonConfig` | config, pp | Sets strict unknown-field rejection and the merge-patch media type | | `@Bean` customizer | | |
| `RateLimiter` | class, pub | Applies a limit through Bucket4j, and fails open | `Map` of class to bandwidths, `Cache` of buckets | `void check(RateLimitClass, String key)`. Errors: `rate_limited` | | Bucket4j |
| `RateLimitClass` | enum, pub | Names the nine classes in api 14.1 | `LOGIN`, `REGISTER`, `UPLOAD`, `FRIEND_INVITE`, `PHOTO_PASSWORD`, `SEARCH`, `OTHER_WRITE`, `OTHER_READ`, `ANONYMOUS_READ` | | | |
| `RateLimit` | annotation, pub | Overrides a controller method's default rate-limit class | `RateLimitClass value` | | | |
| `RateLimitInterceptor` | interceptor, pp | Applies the right limit before the controller method runs | `RateLimiter limiter`, `ClientIpResolver ips` | `preHandle(...)`. Errors: `rate_limited` | | `RateLimiter` |
| `FileStore` | interface, pub | **The one new port:** stores and removes objects | | `void put(String key, Path file, String contentType)`, `InputStream open(String key)`, `void delete(String key)`, `void deletePrefix(String prefix)`, `Stream<StoredObject> listOlderThan(String prefix, Instant cutoff)`. Errors: `storage_unavailable` | | |
| `StoredObject` | record, pub | Describes one stored object | `String key`, `Instant lastModified` | | | |
| `S3FileStore` | class, pp | Implements `FileStore` over the S3 protocol | S3 client, `String bucket` | As `FileStore` | | S3 SDK |
| `JobRunner` | class, pub | Runs a job with logging context, a timer and error capture | `MeterRegistry registry` | `void run(String jobName, Runnable body)` | | MDC |
| `UserId`, `GroupId`, `CompetitionId`, `RunId` | records, pub | Give each kind of ID its own type | `UUID value` | | | |
| `Ids` | class, pub | Compares UUIDs in PostgreSQL's order | | `static int compare(UUID, UUID)` | | |
| `PlatformProperties` | record, pub | Holds origin, body limits, trusted proxy and rate limits | See section 9.9 | | | |

**Test double:** `InMemoryFileStore` lives in test sources. Integration tests use real MinIO through Testcontainers, and service tests use the in-memory version.

### 3.2 `identity`

| Class | Kind, visibility | Responsibility | Key fields | Key methods and errors | Tx, locks | Collaborators |
|---|---|---|---|---|---|---|
| `UserDirectory` | interface, pub (`api`) | Lets other modules read public user data | | Section 2.4 | | |
| `AccountDeletionParticipant` | interface, pub (`api`) | Lets other modules clean up their rows in the deletion transaction | | `void onAccountDeleted(UserId)` | Caller's | |
| `AccountPurgeParticipant` | interface, pub (`api`) | Lets other modules remove their files during the purge | | `void purgeFiles(UserId)` | Caller's | |
| `UserCard` | record, pub (`api`) | Holds what other users may see of someone | `UserId id`, `String displayName`, `String photoUrl` | `static String photoUrl(UserId, String photoKey)` | | |
| `UserFacts` | record, pub (`api`) | Holds the settings other modules need | `UserId id`, `RunPrivacy runPrivacy`, `ZoneId timeZone`, `String city` | | | |
| `RunPrivacy` | enum, pub (`api`) | Mirrors `ck_users_run_privacy` | `PRIVATE`, `FRIENDS`, `PUBLIC` | | | |
| `AuthController` | controller, pp | Handles registration, login and logout | Services | `register(RegisterRequest, response)`, `login(LoginRequest, request, response)`, `logout(Viewer.Authenticated, request, response)` | | `AccountService`, `AuthService`, `SessionCookies` |
| `MeController` | controller, pp | Handles the current user's account, password, photo and deletion | Services | `get`, `update(UpdateMeRequest)`, `changePassword(ChangePasswordRequest)`, `delete(DeleteAccountRequest)`, `putPhoto(request)`, `deletePhoto()` | | `AccountService`, `PhotoService`, `AccountDeletionService` |
| `UserController` | controller, pp | Handles user search and serving photos | Services | `search(q, limit)`, `photo(userId, photoId)` | | `UserDirectoryService`, `PhotoService` |
| `AccountService` | class, pub | Registers accounts, and edits profile and password | Repositories, `PasswordService` | `RegisteredAccount register(Registration)`. Errors: `email_taken`, `weak_password`, `validation_failed`. `User get(UserId)`, `User update(UserId, ProfilePatch)`. `String changePassword(UserId, byte[] currentSession, String current, String next)`. Errors: `password_incorrect`, `weak_password` | `register`, `changePassword`: no locks, relies on `uq_users_email_lower` and last write wins | `UserRepository`, `SessionService`, `PasswordService` |
| `AuthService` | class, pub | Logs in and out without revealing which accounts exist | Repositories | `LoginResult login(String email, String password, String ip)`. Errors: `invalid_credentials`, `rate_limited`. `void logout(byte[] tokenHash)` | One insert | `UserRepository`, `SessionService`, `PasswordService`, `RateLimiter` |
| `SessionService` | class, pub | Implements `SessionAuthenticator`, and issues and revokes sessions | `SessionRepository`, `IdentityProperties` | `authenticate(byte[])`, `SessionToken issue(UserId)`, `void revokeAll(UserId)`, `void revokeOthers(UserId, byte[] keep)` | Joins the caller's | `SessionRepository` |
| `PasswordService` | class, pub | Hashes under a semaphore, rejects weak passwords, and verifies with a dummy hash when there's no user | `PasswordEncoder encoder`, `Semaphore permits`, `Set<String> commonPasswords` | `String hash(String)`, `boolean verify(String raw, String hash)`, `boolean verifyDummy(String raw)`, `boolean needsRehash(String)`, `void requireStrong(String field, String raw)`. Errors: `weak_password` | Never inside a transaction | Spring `Argon2PasswordEncoder` |
| `PhotoService` | class, pub | Validates and re-encodes photos, stores them, and removes the old file | `FileStore`, `UserRepository` | `String put(UserId, InputStream, String contentType)`. Errors: `image_invalid`, `storage_unavailable`. `void delete(UserId)`, `InputStream open(UserId, UUID photoId)`. Errors: `not_found` | One update, after the store call | `FileStore`, `UserRepository` |
| `UserDirectoryService` | class, pub | Implements `UserDirectory`, and searches by display name | `UserRepository` | `List<UserCard> search(String q, int limit)` | | `UserRepository` |
| `AccountDeletionService` | class, pub | Runs phase 1 of account deletion in one transaction | Repositories, `List<AccountDeletionParticipant>` | `void deletePhase1(UserId, String password)`. Errors: `password_incorrect` | `NO_KEY_UPDATE` user, then participants | `RowLocks`, `TransactionRunner`, `PasswordService` |
| `AccountPurgeJob` | class, pp | Runs phase 2: purges deleted users' files and rows | `UserRepository`, `FileStore`, `List<AccountPurgeParticipant>` | `void runOnce()` | `SKIP LOCKED` claim, one transaction per user, longer timeout | `TransactionRunner`, `JobRunner` |
| `SessionCleanupJob` | class, pp | Deletes expired sessions daily | `SessionRepository` | `void runOnce()` | No explicit lock | `JobRunner` |
| `User` | record, pub (`domain`) | Holds a stored user | `UserId id`, `String email`, `String passwordHash`, `String displayName`, `LocalDate birthDate`, `String city`, `String photoKey`, `RunPrivacy runPrivacy`, `ZoneId timeZone`, `Instant createdAt` | | | |
| `ProfilePatch` | record, pub (`domain`) | Holds which profile fields to change | `Optional` per field, with an inner `Optional` for nullable ones | `static of(UpdateMeRequest fields)`. Errors: `validation_failed` | | |
| `SessionToken` | record, pub (`domain`) | Pairs a raw token with its SHA-256 hash | `String raw`, `byte[] hash` | `static SessionToken generate(SecureRandom)` | | `TokenHash` |
| `UserRepository` | class, pub | Holds the SQL for `users` | `JdbcClient jdbc` | Section 7.2 | | |
| `SessionRepository` | class, pub | Holds the SQL for `sessions` | `JdbcClient jdbc` | Section 7.2 | | |
| `IdentityProperties` | record, pub | Holds session lifetimes, Argon2 parameters and photo limits | See section 9.9 | | | |

### 3.3 `social`

| Class | Kind, visibility | Responsibility | Key fields | Key methods and errors | Tx, locks | Collaborators |
|---|---|---|---|---|---|---|
| `FriendshipLookup` | interface, pub (`api`) | Answers whether two users are friends | | Section 2.4 | | |
| `GroupLookup` | interface, pub (`api`) | Gives other modules a group as this viewer may see it | | Section 2.4 | | |
| `GroupInvitationLookup` | interface, pub (`api`) | Gives `competitions` a user's group invitations, for the merged list | | Section 2.4 | | |
| `GroupFacts` | record, pub (`api`) | Holds a group as one viewer sees it | `GroupId id`, `String name`, `GroupVisibility visibility`, `GroupRole viewerRole` (nullable), `boolean viewerInvited` | | | |
| `GroupInvitationView` | record, pub (`api`) | Holds one group invitation for display | `GroupId groupId`, `String groupName`, `UserId invitedBy`, `Instant createdAt` | | | |
| `GroupRole` | enum, pub (`api`) | Mirrors `ck_group_members_role` | `ADMIN`, `MEMBER` | | | |
| `GroupVisibility` | enum, pub (`api`) | Mirrors `ck_groups_visibility` | `PUBLIC`, `PRIVATE` | | | |
| `FriendController` | controller, pp | Handles friends and friend requests | `FriendshipService` | `list(status, limit, cursor)`, `put(userId)`, `delete(userId)` | | `FriendshipService` |
| `GroupController` | controller, pp | Handles creating, reading, searching and deleting groups | `GroupService` | `create`, `search`, `listMine`, `get`, `delete` | | `GroupService` |
| `GroupMemberController` | controller, pp | Handles joining, leaving, roles, kicks, invitations and declines | `GroupMembershipService` | `list`, `join`, `leave`, `changeRole`, `remove`, `invite`, `decline` | | `GroupMembershipService` |
| `UserCardController` | controller, pp | Handles `GET /users/{userId}`, including `city` for friends | `FriendshipService` | `get(viewer, userId)` | | `FriendshipService` |
| `FriendshipService` | class, pub | Implements `FriendshipLookup`, and applies request, accept and remove | `FriendshipRepository`, `UserDirectory`, `TransactionRunner`, `RowLocks` | `FriendshipResult request(UserId me, UserId other)`. Errors: `not_found`, `friend_self`. `void remove(UserId me, UserId other)`. `Page<Friendship> list(...)`. `UserCardWithCity cardFor(UserId viewer, UserId target)`. Errors: `not_found` | `request`: `SHARE` user (CLS-6), then a locked read of the row | `FriendshipRepository`, `UserDirectory`, `RowLocks` |
| `GroupService` | class, pub | Implements `GroupLookup`, and creates, reads, searches and deletes groups | Repositories, `GroupPolicy` | `GroupDetails create(UserId, NewGroup)`, `GroupDetails get(GroupId, UserId)`. Errors: `not_found`. `void delete(GroupId, UserId)`. Errors: `forbidden`, `not_found`. `Page<Group> search(...)`, `Page<MyGroupRow> listMine(...)` | `create`: `SHARE` user. `delete`: `UPDATE` group | `GroupRepository`, `GroupMemberRepository`, `RowLocks` |
| `GroupMembershipService` | class, pub | Implements `GroupInvitationLookup`, and runs all membership transactions | Repositories, `GroupPolicy` | `JoinResult join(GroupId, UserId)`. Errors: `not_found`. `void leave(GroupId, UserId)`, `Membership changeRole(GroupId, UserId actor, UserId target, GroupRole)`, `void remove(GroupId, UserId actor, UserId target)`. Errors: `forbidden`, `not_found`, `last_admin`. `void invite(GroupId, UserId actor, UserId invitee)`. Errors: `forbidden`, `not_found`, `invitation_not_applicable`. `void decline(GroupId, UserId)`, `Page<MemberRow> list(...)`. Errors: `forbidden`, `not_found` | `join`: `SHARE` user. `leave`, `changeRole`, `remove`: `UPDATE` group | `GroupMemberRepository`, `GroupInvitationRepository`, `RowLocks`, `UserDirectory` |
| `GroupPolicy` | class, pp | Applies the group rows of the matrix in api 9.2, as pure functions | | `AccessDecision see(GroupFacts)`, `seeMembers`, `join`, `manage`, `invite`. `GroupCapabilities capabilities(GroupFacts)` | | |
| `SocialAccountDeletion` | class, pp | Removes a deleted user's friendships, memberships and invitations, and hands over admin | Repositories, `@Order(1)` | `void onAccountDeleted(UserId)` | Caller's. `UPDATE` groups ascending | `RowLocks`, `GroupMemberRepository`, `FriendshipRepository`, `GroupInvitationRepository` |
| `FriendPair` | record, pub (`domain`) | Holds two users in the database's order | `UserId a`, `UserId b` | `static FriendPair of(UserId, UserId)` | | `Ids` |
| `Friendship` | record, pub (`domain`) | Holds a stored friendship, and describes it from one side | `FriendPair pair`, `UserId requestedBy`, `boolean accepted`, `Instant createdAt`, `Instant acceptedAt` | `Direction directionFor(UserId)`, `UserId other(UserId)` | | |
| `Group` | record, pub (`domain`) | Holds a stored group | `GroupId id`, `String name`, `GroupVisibility visibility`, `String city`, `Instant createdAt` | | | |
| `Membership` | record, pub (`domain`) | Holds a stored membership | `GroupId groupId`, `UserId userId`, `GroupRole role`, `Instant joinedAt` | | | |
| `FriendshipRepository`, `GroupRepository`, `GroupMemberRepository`, `GroupInvitationRepository` | classes, pub | Hold the SQL for the social tables | `JdbcClient jdbc` | Section 7.2 | | |

### 3.4 `runs`

| Class | Kind, visibility | Responsibility | Key fields | Key methods and errors | Tx, locks | Collaborators |
|---|---|---|---|---|---|---|
| `RunAcceptedListener` | interface, pub (`api`) | Tells interested modules a valid run was stored: **the Outbox seam** | | `void onRunAccepted(AcceptedRun)` | Caller's | |
| `AcceptedRun` | record, pub (`api`) | Holds what scoring needs from a run | `RunId id`, `UserId userId`, `Instant startedAt`, `Instant receivedAt` | | | |
| `RunController` | controller, pp | Handles upload, history and single-run reads | Services | `upload(viewer, request)`, `listMine`, `get(viewer, runId)`, `listForUser(viewer, userId, limit, cursor)` | | `RunIngestService`, `RunQueryService` |
| `StatsController` | controller, pp | Handles personal stats | `StatsService` | `get(viewer, weeks, months, weekStart)` | | `StatsService` |
| `RunIngestService` | class, pub | Runs the upload pipeline in api 7.2 | `RunRepository`, `FileStore`, `GpxParser`, `TransactionRunner`, `RowLocks`, `RunAcceptedListener`, `Clock`, `RunsProperties` | `IngestResult ingest(UserId, InputStream, long declaredLength)`. Errors: `gpx_malformed`, `gpx_out_of_range`, `run_in_future`, `run_too_old`, `run_overlap`, `storage_unavailable`, `payload_too_large` | `SHARE` user, insert, then the listener's locks | `UploadSpool`, `RunSanityRules`, `PlausibilityRules` |
| `RunQueryService` | class, pub | Reads runs and applies visibility | `RunRepository`, `UserDirectory`, `FriendshipLookup`, `RunVisibilityPolicy` | `Page<Run> listMine(...)`, `RunView get(RunId, UserId viewer)`. Errors: `not_found`. `Page<Run> listForUser(UserId viewer, UserId target, ...)`. Errors: `not_found`, `runs_not_visible` | Autocommit | Listed |
| `StatsService` | class, pub | Builds weekly, monthly and personal-best stats, including empty periods | `RunStatsRepository`, `UserDirectory`, `RunsProperties` | `Stats get(UserId, int weeks, int months, DayOfWeek weekStart)` | Autocommit | Listed |
| `RunVisibilityPolicy` | class, pp | Decides who sees a run or a run list (D54) | | `AccessDecision seeList(RunPrivacy, boolean self, boolean friends)`, `AccessDecision seeRun(Run, RunPrivacy, boolean self, boolean friends)` | | |
| `GpxParser` | class, pp | Streams a GPX file into a `ParsedRun` safely, with StAX | `RunsProperties props` | `ParsedRun parse(Path)`. Errors: `gpx_malformed` | | |
| `UploadSpool` | class, `AutoCloseable`, pp | Spools a body to a temp file while counting and hashing, and deletes it on close | `Path file`, `byte[] sha256`, `long bytes` | `static UploadSpool from(InputStream, long maxBytes)`. Errors: `payload_too_large`. `void close()` | | |
| `OrphanFileCleanupJob` | class, pp | Deletes run files with no matching run | `FileStore`, `RunRepository`, `Clock` | `void runOnce()` | No lock (database 8.3) | `JobRunner`, `RunFileKey` |
| `RunsAccountPurge` | class, pp | Deletes a purged user's run files | `FileStore` | `void purgeFiles(UserId)` | Caller's | `FileStore` |
| `ParsedRun` | record, pub (`domain`) | Holds source-neutral output of parsing: **the D11 seam** | `Instant startedAt`, `Instant endedAt`, `RunMetrics metrics`, `boolean hasSpeedJump` | | | |
| `RunMetrics` | record, pub (`domain`) | Holds distance and duration, and computes pace by the database's rounding | `int distanceMeters`, `int durationSeconds` | `int paceSecondsPerKm()` | | |
| `RunSanityRules` | class, pub (`domain`) | Rejects out-of-range, future and too-old runs (D36) | Limits | `void check(ParsedRun, Instant now)`. Errors: `gpx_out_of_range`, `run_in_future`, `run_too_old` | | |
| `PlausibilityRules` | class, pub (`domain`) | Classifies a run as valid or invalid (D49) | Thresholds | `RunVerdict classify(ParsedRun)` | | |
| `RunVerdict` | sealed interface, pub (`domain`) | Holds the classification | `Valid`, `Invalid(InvalidReason reason)` | | | |
| `Run` | record, pub (`domain`) | Holds a stored run | `RunId id`, `UserId userId`, `RunSource source`, `Instant startedAt`, `Instant endedAt`, `int distanceMeters`, `int durationSeconds`, `int paceSecondsPerKm`, `RunStatus status`, `String invalidReason`, `Instant receivedAt` | | | |
| `NewRun` | record, pub (`domain`) | Holds what's inserted for a new run | `UserId userId`, `ParsedRun parsed`, `RunVerdict verdict`, `RunFileKey fileKey`, `byte[] fileHash` | | | |
| `RunStatus`, `RunSource`, `InvalidReason` | enums, pub (`domain`) | Mirror the schema's text values | | | | |
| `RunFileKey` | record, pub (`domain`) | Builds and parses `runs/{user_id}/{sha256}/{attempt_uuid}.gpx` | `UserId userId`, `byte[] sha256`, `UUID attempt` | `String value()`, `static Optional<RunFileKey> parse(String)` | | |
| `IngestResult` | record, pub (`domain`) | Holds the run, and whether it's new, which decides 201 or 200 | `Run run`, `boolean created` | | | |
| `RunRepository`, `RunStatsRepository` | classes, pub | Hold the SQL for `runs` | `JdbcClient jdbc` | Section 7.2 | | |
| `RunsProperties` | record, pub | Holds size limit, trackpoint cap, age limit, tolerance and thresholds | See section 9.9 | | | |

### 3.5 `competitions`

| Class | Kind, visibility | Responsibility | Key fields | Key methods and errors | Tx, locks | Collaborators |
|---|---|---|---|---|---|---|
| `CompetitionLookup` | interface, pub (`api`) | Gives `leaderboards` a competition as this viewer may see it | | Section 2.4 | | |
| `CompetitionFacts` | record, pub (`api`) | Holds what a leaderboard needs to know | `CompetitionId id`, `Rule rule`, `CompetitionVisibility visibility`, `CompetitionState state`, `Instant asOf`, `boolean viewerIsParticipant` | | | |
| `CompetitionState` | enum, pub (`api`) | Names the four derived states | `UPCOMING`, `RUNNING`, `FINALIZING`, `CLOSED` | | | |
| `CompetitionVisibility` | enum, pub (`api`) | Mirrors `ck_competitions_visibility` | `PRIVATE`, `PUBLIC` | | | |
| `RuleType` | enum, pub (`api`) | Mirrors `ck_competitions_rule_type`, and says how scores compare | `TOTAL_DISTANCE`, `LONGEST_RUN`, `FASTEST_PACE`, each with `ScoreDirection`, `ScoreUnit` | | | |
| `ScoreDirection` | enum, pub (`api`) | Says whether higher or lower is better | `HIGHER_IS_BETTER`, `LOWER_IS_BETTER` | `String sqlOrder()` | | |
| `ScoreUnit` | enum, pub (`api`) | Names the unit of a score | `METERS`, `SECONDS_PER_KM` | | | |
| `Rule` | record, pub (`api`) | Holds a rule and its parameter, and enforces that the two match | `RuleType type`, `Integer minDistanceMeters` | Compact constructor. Errors: `validation_failed` | | |
| `CompetitionController` | controller, pp | Handles creating, reading, searching, deleting, and a group's competitions | `CompetitionService` | `create`, `search`, `listMine`, `get`, `delete`, `listForGroup` | | `CompetitionService` |
| `ParticipationController` | controller, pp | Handles join, leave and the participant list | `ParticipationService` | `join`, `leave`, `list` | | `ParticipationService` |
| `InvitationController` | controller, pp | Handles invite, decline, and the merged `/me/invitations` | `CompetitionInvitationService` | `invite`, `decline`, `listMine` | | `CompetitionInvitationService` |
| `CompetitionService` | class, pub | Implements `CompetitionLookup`, and creates, reads, searches and deletes competitions | Repositories, `CompetitionPolicy`, `GroupLookup`, `UserDirectory`, `ParticipationService` | `CompetitionDetails create(UserId, NewCompetition, boolean consent)`. Errors: `consent_required`, `forbidden`, `not_found`, `competition_limit_reached`. `CompetitionDetails get(CompetitionId, Viewer)`. Errors: `not_found`. `void delete(CompetitionId, UserId)`. Errors: `forbidden`, `not_found`, `competition_not_deletable`. `Page<...> search`, `listMine`, `listForGroup` | `create`: `NO_KEY_UPDATE` user, optional `SHARE` group. `delete`: `UPDATE` competition | `RowLocks`, `TransactionRunner` |
| `ParticipationService` | class, pub | Runs the join and leave transactions | Repositories, `CompetitionPolicy`, `ScoringService`, `GroupLookup` | `JoinResult join(CompetitionId, UserId, boolean consent)`. Errors: `not_found`, `consent_required`, `competition_join_closed`, `competition_limit_reached`. `void leave(CompetitionId, UserId)`. Errors: `not_found`, `competition_leave_closed`. `Page<ParticipantRow> list(...)`. Errors: `forbidden`, `not_found`. Package-private `Participant joinLocked(...)`, shared with `create` | `NO_KEY_UPDATE` user, `SHARE` competition | `RowLocks`, `TransactionRunner` |
| `CompetitionInvitationService` | class, pub | Handles invites and declines, and merges both kinds of invitation | `CompetitionInvitationRepository`, `GroupInvitationLookup`, `UserDirectory` | `void invite(CompetitionId, UserId actor, UserId invitee)`. Errors: `forbidden`, `not_found`, `invitation_not_applicable`. `void decline(CompetitionId, UserId)`. `List<InvitationView> listMine(UserId)` | One insert | Listed |
| `CompetitionPolicy` | class, pp | Applies the competition rows of the matrix, and viewer capabilities, as pure functions | | `AccessDecision see(CompetitionViewerRow, GroupFacts)`, `seeParticipants`, `join`, `invite`, `delete`. `CompetitionCapabilities capabilities(...)` | | `Competition` |
| `ScoringService` | class, pub | Implements `RunAcceptedListener`, and recalculates and stores a participant's score | `CompetitionRepository`, `ParticipantRepository`, `EligibleRunsReader`, `ScoringStrategies`, `RowLocks` | `void onRunAccepted(AcceptedRun)`, `Integer recalculate(Competition, UserId)` | Caller's. Per competition, ascending: `SHARE` competition, then `UPDATE` participant | Listed |
| `ScoringStrategy` | interface, pp | Calculates one rule type's score | | `RuleType ruleType()`, `Integer score(EligibleRunsReader, Competition, UserId)` | | |
| `TotalDistanceStrategy` | class, pp | Scores the sum of eligible distances | | As `ScoringStrategy` | | `EligibleRunsReader.sumDistance` |
| `LongestRunStrategy` | class, pp | Scores the longest eligible distance | | As `ScoringStrategy` | | `EligibleRunsReader.maxDistance` |
| `FastestPaceStrategy` | class, pp | Scores the best pace among eligible runs of at least X km | | As `ScoringStrategy` | | `EligibleRunsReader.minPace` |
| `ScoringStrategies` | class, pp | Chooses the strategy for a rule, and fails at startup if one is missing | `Map<RuleType, ScoringStrategy> byType` | `ScoringStrategy forType(RuleType)` | | |
| `CompetitionClosureJob` | class, pp | Finds due competitions, and closes each in its own transaction | `CompetitionRepository`, `RowLocks`, `TransactionRunner`, `CompetitionProperties` | `void runOnce()` | `UPDATE` competition, one transaction each | `JobRunner` |
| `CompetitionsAccountDeletion` | class, pp | Removes a deleted user's competition invitations | `CompetitionInvitationRepository`, `@Order(2)` | `void onAccountDeleted(UserId)` | Caller's | |
| `Competition` | record, rich, pub (`domain`) | Holds the window, and answers state, join and leave questions for a given time | `CompetitionId id`, `UserId creatorId`, `GroupId groupId`, `String name`, `String city`, `Rule rule`, `CompetitionVisibility visibility`, `Instant startsAt`, `endsAt`, `closesAt`, `closedAt`, `createdAt` | `CompetitionState stateAt(Instant)`, `boolean canJoinAt(Instant)`, `boolean canLeaveAt(Instant)`, `boolean isDeletableAt(Instant, int participants)`, `EligibilityWindow window()` | | |
| `EligibilityWindow` | record, pub (`domain`) | Holds the three times the eligibility SQL needs | `Instant startsAt`, `endsAt`, `closesAt` | | | |
| `NewCompetition` | record, rich, pub (`domain`) | Validates creation input, and calculates `closes_at` | Inputs, plus `Instant closesAt` | `static NewCompetition of(..., Duration grace, Instant now, CompetitionProperties limits)`. Errors: `validation_failed` | | |
| `Participant` | record, pub (`domain`) | Holds a participant row | `CompetitionId competitionId`, `UserId userId`, `Integer score`, `Instant joinedAt` | | | |
| `CompetitionRepository`, `ParticipantRepository`, `CompetitionInvitationRepository` | classes, pub | Hold the SQL for the competition tables | `JdbcClient jdbc` | Section 7.2 | | |
| `EligibleRunsReader` | class, pub | Performs the D35 read of `runs`: one aggregate per rule, with one eligibility fragment | `JdbcClient jdbc` | Section 7.2 | | |
| `ParticipantUsersReader` | class, pub | Performs the D35 read of `users`: participant count and list, without deleted users | `JdbcClient jdbc` | Section 7.2 | | |
| `CompetitionStateSql` | class, pub | Holds the SQL form of state filters | | `String predicateFor(Set<CompetitionState>)` | | |
| `CompetitionProperties` | record, pub | Holds grace default and maximum, open limit, closure delay and window limits | See section 9.9 | | | |

### 3.6 `leaderboards`

| Class | Kind, visibility | Responsibility | Key fields | Key methods and errors | Tx, locks | Collaborators |
|---|---|---|---|---|---|---|
| `LeaderboardController` | controller, pp | Handles the endpoint, including ETag and 304 | `LeaderboardService`, `LeaderboardEtag` | `get(viewer, competitionId, limit, cursor, ifNoneMatch)` | | `LeaderboardService`, `LeaderboardEtag` |
| `LeaderboardService` | class, pub | Builds one screen: entries, `me`, state and paging | `CompetitionLookup`, `LeaderboardReader`, `RankAssigner`, `LeaderboardProperties` | `LeaderboardView read(CompetitionId, Viewer, int limit, String cursor)`. Errors: `not_found`, `full_leaderboard_forbidden`, `invalid_cursor` | Autocommit (database 7.3) | Listed |
| `RankAssigner` | class, pp | Assigns tied ranks across a page, given the first row's rank | | `List<RankedEntry> assign(List<EntryRow>, int firstRowRank)` | | |
| `LeaderboardEtag` | class, pp | Hashes state, entries, `me` and `nextCursor`, and never `asOf` | | `String of(LeaderboardView)` | | |
| `LeaderboardView` | record, pub (`service`) | Holds one leaderboard screen | `CompetitionFacts facts`, `ViewerAccess access`, `List<RankedEntry> entries`, `MyStanding me`, `String nextCursor`, `boolean firstPage`, `Integer pollIntervalSeconds` | | | |
| `LeaderboardReader` | class, pub | Performs the D35 reads: top N, deep page, my score, count of better scores | `JdbcClient jdbc` | Section 7.2 | | |
| `LeaderboardProperties` | record, pub | Holds top N and poll interval | See section 9.9 | | | |

`leaderboards` has no policy class. Access comes entirely from `CompetitionLookup`, and the only rule of its own, "a cursor requires full access", is one line in the service.

### 3.7 DTOs and small service records

**DTOs** are records in each module's `web` package, with a static `from(...)` factory. Section 16.1 maps each to its schema. They're public because Jackson and controllers need them.

| Module | Request records | Response records |
|---|---|---|
| `identity` | `RegisterRequest`, `LoginRequest`, `UpdateMeRequest`, `ChangePasswordRequest`, `DeleteAccountRequest` | `CurrentUserDto`, `UserCardDto`, `PhotoResponse` |
| `social` | `CreateGroupRequest`, `ChangeRoleRequest` | `UserCardWithCityDto`, `FriendshipDto`, `GroupSummaryDto`, `MyGroupDto`, `GroupDto`, `MemberDto` |
| `runs` | none | `RunDto`, `OwnRunDto`, `StatsDto`, `StatsPeriodDto` |
| `competitions` | `RuleRequest`, `CreateCompetitionRequest`, `JoinCompetitionRequest` | `RuleDto`, `CompetitionSummaryDto`, `MyCompetitionDto`, `CompetitionDto`, `ParticipationDto`, `ParticipantDto`, `InvitationDto` |
| `leaderboards` | none | `LeaderboardDto`, `TopNEntryDto`, `FullEntryDto` |

**Small records returned by services** (in `service`, or `domain` where a repository produces them): `RegisteredAccount`, `LoginResult`, `Registration`, `FriendshipResult`, `GroupDetails`, `GroupCapabilities`, `NewGroup`, `MyGroupRow`, `MemberRow`, `JoinResult`, `RunView`, `Stats`, `CompetitionDetails`, `CompetitionCapabilities`, `CompetitionViewerRow`, `ParticipantRow`, `MyCompetitionRow`, `InvitationView`, `RankedEntry`, `EntryRow`, `MyStanding`, `ViewerAccess`. Each one exists to carry one method's result, so they aren't listed separately. **A boolean `created` on `JoinResult`, `FriendshipResult` and `IngestResult` is what decides 201 or 200**, so controllers hold no logic for it.

**Cursor records** (one per list, private to the repository that uses it): `RunCursor(Instant startedAt, UUID id)`, `LeaderboardCursor(int score, UUID userId)`, and `IdCursor(UUID id)` for lists ordered by one ID.

---

