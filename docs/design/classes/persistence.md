# Classes: Persistence design

> **Covers:** The `JdbcClient` choice (D57), repositories, where the SQL lives, `RowLocks` (D61), `TransactionRunner` (D60), keyset pagination, and database errors.
> **Read when:** writing a repository, a transaction or a lock.
> **Related:** [../database/transactions.md](../database/transactions.md), [../database/schema.md](../database/schema.md), [flows-runs-competitions.md](flows-runs-competitions.md)

## 7. Persistence design

### 7.1 Technology: `JdbcClient` with plain SQL (D57)

Spring's `JdbcClient` (since Framework 6.1) with SQL in text blocks inside repository classes, and explicit row mappers to records.

| Option | Fit with our design | Jobs and learning | Verdict |
|---|---|---|---|
| **`JdbcClient`** | Exact. The statements in `database.md` were verified with `EXPLAIN`, and can be used word for word | Teaches SQL and transactions, the project's stated goals. Less visible on a CV | **Chosen** |
| JPA/Hibernate | Poor, see below | Very widely expected | Rejected for Phase 1 |
| Spring Data JDBC | Weak. Its aggregate model doesn't suit lock-then-recalculate flows, and composite IDs only arrived in 4.0 | Niche | Rejected |
| jOOQ open source | Technically good, with compile-time checked SQL. It's Apache-2.0, and the support matrix lists PostgreSQL 18 as its minimum | Niche. Needs code generation against a live database in the build, a toolchain that doesn't exist yet | Runner-up |
| Hybrid: JPA for CRUD, JDBC for the core | Two models in one transaction. JDBC doesn't see unflushed JPA changes, which causes subtle bugs | Teaches JPA only on the easy tables | Rejected |

**Why not JPA here specifically:**
- The core flow is `lock -> read fresh -> recalculate -> update if changed`. The persistence context can hand back a stale object, which is the exact bug database 6.3 designs against. *(From my knowledge. Section 15 marks it to verify.)*
- `FOR NO KEY UPDATE`, which the join lock needs, has no direct JPA lock mode that I could confirm.
- Keyset pagination, `RANK()`, `IS DISTINCT FROM` and `ON CONFLICT` would mostly be native queries, so we'd pay for an ORM and bypass it in the transactions that matter most.

**What you give up, plainly:**
1. **JPA on your CV.** A real cost. A suggested side exercise after the vertical slice: rewrite `social` with JPA on a throwaway branch and compare the two. You'd learn more from that comparison than from using JPA only on easy tables.
2. **Compile-time SQL checks.** A typo fails at test time, so every repository method needs a Testcontainers test. Database 11.3 requires those tests anyway.
3. **Convenience.** You write row mappers by hand.

### 7.2 Repositories

Concrete classes with text-block SQL and private row mappers. **They hold no business rules, and they never call each other.** Why no interfaces: see row I in section 1.2. Mockito can still mock a concrete class where a service test wants it.

**Names are expected to change. The mapping to `database.md` isn't.**

| Repository | Method signature | Database item |
|---|---|---|
| `UserRepository` | `User insert(NewUser)` | 3.1. `23505` on `uq_users_email_lower` |
| | `Optional<User> findActiveById(UserId)` | 3.1, R1 |
| | `Optional<User> findActiveByEmail(String)` | Login, 8.3 of api |
| | `int updateProfile(UserId, ProfilePatch)` | W6 |
| | `int updatePassword(UserId, String hash)` | W6 |
| | `Optional<String> updatePhotoKey(UserId, String newKey)`, returning the old key | 14.4 |
| | `int wipeForDeletion(UserId)` | 6.6 step 1 |
| | `List<UserCard> searchByDisplayName(String q, int limit)` | R7, 14.7 |
| | `List<UserCard> findCards(Collection<UserId>)` | R7, `users` PK |
| | `Optional<UserId> claimDeletedUser()` | **8.2, `FOR UPDATE SKIP LOCKED`** |
| | `int purge(UserId)` | 8.2, cascades |
| `SessionRepository` | `void insert(byte[] hash, UserId, Instant expiresAt)` | 14.1 |
| | `Optional<SessionRow> findValid(byte[] hash)`, with a `needsRenewal` flag | 14.1, R1, CLS-8 |
| | `Duration renew(byte[] hash)` | 14.1 |
| | `int delete(byte[] hash)`, `int deleteAllForUser(UserId)`, `int deleteAllExcept(UserId, byte[])` | 14.1, 14.4 |
| | `int deleteExpired()` | 14.4 |
| `RunRepository` | `Optional<Run> findByHash(UserId, byte[])` | 14.2 |
| | `Run insert(NewRun)` | 3.2, 6.3 step 2 |
| | `Optional<RunId> findOverlappingValid(UserId, Instant, Instant)` | 14.7 |
| | `Optional<Run> findById(RunId)` | R3 |
| | `List<Run> pageForOwner(UserId, PageRequest<RunCursor>)`, `pageValidForViewer(UserId, PageRequest<RunCursor>)` | 7.5, 14.7 |
| | `Optional<String> findFileKey(UserId, byte[] hash)` | 8.3 |
| `RunStatsRepository` | `periods(UserId, ZoneId, ChronoUnit, DayOfWeek, int)`, `totals(UserId)`, `longestRun(UserId)`, `fastestPaces(UserId, int[])` | R4, 14.7 |
| `CompetitionRepository` | `Competition insert(NewCompetition, UserId creator)` | 3.3, 14.6 |
| | `Optional<CompetitionViewerRow> findForViewer(CompetitionId, Optional<UserId>)`, with `now()` | 14.7, D46 |
| | `int deleteById(CompetitionId)` | 14.6 |
| | `List<CompetitionId> findEligibleForRun(UserId, Instant startedAt, Instant receivedAt)` | 6.3 step 4 |
| | `int countOpenForUser(UserId)` | 6.4 step 3 |
| | `List<CompetitionId> findDueForClosure(Duration delay)` | 6.5 |
| | `int markClosed(CompetitionId)` | 6.5 step 3 |
| | `searchPublic(q, city, states, page)`, `pageForGroup(GroupId, boolean all, page)`, `pageForUser(UserId, boolean active, page)` | R8, R5, R6, 14.7 |
| `ParticipantRepository` | `boolean insertIfAbsent(CompetitionId, UserId)` | 6.4 step 4 |
| | `Optional<Participant> find(CompetitionId, UserId)` | 14.3 |
| | `int delete(CompetitionId, UserId)` | 6.4 |
| | `int updateScoreIfChanged(CompetitionId, UserId, Integer)` | 6.2 |
| `EligibleRunsReader` | `Integer sumDistance(UserId, EligibilityWindow)`, `maxDistance(UserId, EligibilityWindow)`, `minPace(UserId, EligibilityWindow, int minDistance)` | 6.2 |
| `ParticipantUsersReader` | `int countActive(CompetitionId)`, `List<ParticipantRow> pageActive(CompetitionId, PageRequest<IdCursor>)` | R5, 14.7, CLS-1 |
| `CompetitionInvitationRepository` | `int insertIfAbsent(CompetitionId, UserId invitee, UserId by)`, `boolean exists(...)`, `int delete(...)`, `int deleteAllForUser(UserId)`, `List<InvitationRow> newestFor(UserId, int)` | 3.5, 6.4, 6.6, CLS-7 |
| `LeaderboardReader` | `List<EntryRow> topN(CompetitionId, ScoreDirection, int limit)` | **7.1, word for word** |
| | `List<EntryRow> pageAfter(CompetitionId, ScoreDirection, LeaderboardCursor, int)` | 14.7 |
| | `Optional<Integer> findMyScore(CompetitionId, UserId)` | 7.2 |
| | `int countBetter(CompetitionId, ScoreDirection, int score)` | 7.2, 14.7 |
| `FriendshipRepository` | `boolean insertIfAbsent(FriendPair, UserId requestedBy)`, `Optional<Friendship> findForUpdate(FriendPair)`, `int accept(FriendPair)`, `int delete(FriendPair)`, `int deleteAllForUser(UserId)`, `boolean exists(FriendPair)`, `page(UserId, status, page)` | 3.5, R7, 14.7 |
| `GroupRepository` | `Group insert(NewGroup, UserId)`, `Optional<GroupViewerRow> findForViewer(GroupId, Optional<UserId>)`, `int deleteById(GroupId)`, `searchPublic(q, city, page)` | 3.5, R7, R8 |
| `GroupMemberRepository` | `boolean insertIfAbsent(GroupId, UserId, GroupRole)`, `Optional<Membership> find(GroupId, UserId)`, `int delete(GroupId, UserId)`, `int updateRole(GroupId, UserId, GroupRole)`, `int countAdmins(GroupId)`, `int countMembers(GroupId)`, `Optional<UserId> findLongestStanding(GroupId)`, `pageMembers(GroupId, page)`, `pageForUser(UserId, page)`, `List<GroupId> groupsWhereAdmin(UserId)`, sorted ascending, `int deleteAllForUser(UserId)` | 14.6, 6.6, R7 |
| `GroupInvitationRepository` | `int insertIfAbsent(GroupId, UserId, UserId)`, `boolean exists(GroupId, UserId)`, `int delete(GroupId, UserId)`, `int deleteAllForUser(UserId)`, `List<GroupInvitationView> newestFor(UserId, int)` | 3.5, 6.6, CLS-7 |

### 7.3 Where the SQL lives

In a `private static final String` text block next to the method that uses it, with named parameters only. Database 7.1 and 6.2's statements are copied word for word, because they're what the plans verified. **Parameters are always bound, never concatenated** (api 15). The one exception to "no string building" is `ASC` or `DESC`, which comes only from `ScoreDirection.sqlOrder()`, an enum, and never from input.

**Eligibility has one fragment**, in `EligibleRunsReader`:

```sql
r.user_id = :userId AND r.status = 'valid'
  AND r.started_at >= :startsAt AND r.started_at < :endsAt
  AND r.received_at < :closesAt
```

### 7.4 `RowLocks`: the lock-order helper (D61)

```java
public class RowLocks {
    public boolean lockActiveUser(UserId id, LockMode mode);       // false: missing or deleted
    public boolean lockGroup(GroupId id, LockMode mode);           // false: missing
    public Optional<LockedCompetition> lockCompetition(CompetitionId id, LockMode mode);  // empty: missing
    public boolean lockParticipant(CompetitionId c, UserId u);     // FOR UPDATE. false: missing
}
```

**The global order** is a tuple compared lexicographically, using `Ids.compare`:

```text
(0, user) < (1, group ascending) < (2, competition ascending, 0) < (2, same competition, 1, participant)
```

**Each call compares against the last lock taken in this transaction**, stored as a Spring transaction resource, so it's discarded with the transaction. Going backward throws `IllegalStateException`, which is a 500 and a failed test. Taking the same row again is allowed. Skipping levels is allowed. **Every flow has an integration test, so a violation fails CI before it can deadlock in production.**

**Requires a transaction.** `RowLocks` refuses to run outside one, since an autocommit lock would be released at once and protect nothing.

**Beyond the guard:** a test scans the source tree and fails on `FOR SHARE`, `FOR UPDATE` or `FOR NO KEY UPDATE` outside `RowLocks`. The only allowed exception is `UserRepository.claimDeletedUser`, whose `SKIP LOCKED` never waits and so can't deadlock.

| Rejected | Why |
|---|---|
| **Staged builder** (`locks.user().group().competitions()`, where each step's return type offers only later steps) | Elegant and compile-time, but it can't check sort order inside a loop, and ingest would have to pass a token across a module boundary |
| **Locks in each module's repository, with only a guard** | Keeps SQL with its owner, but "one place" then becomes a convention |

**The cost:** `platform` knows four table names, and a lock returns only minimal facts, so the owning module reads the row in a following statement. That's a little more work per lock, and it's correct under READ COMMITTED, because the read sees what the lock waited for. It's documented as a D35 exception.

**`SKIP LOCKED`** appears only in the sweeper (database 8.2). Closure deliberately waits rather than skipping (database 6.5).

### 7.5 `TransactionRunner` (D60)

```java
public <T> T write(Supplier<T> body);                     // default timeout, 30 s
public <T> T write(Duration timeout, Supplier<T> body);   // jobs
```

| Situation | Behavior |
|---|---|
| **Outermost call** | Begins READ COMMITTED, runs `SET LOCAL transaction_timeout`, runs the body, commits. On `40P01` or `40001`, retries the **whole** transaction up to 2 times with 50 to 200 ms of jitter, then `temporarily_unavailable` |
| **Nested call** | Joins the running transaction, and never retries, because a retry must restart everything |
| **Reads** | Single-statement reads use autocommit and need no runner. Database 7.3 accepts this for leaderboards |

**Why not `@Transactional`.** It's what most Spring code uses, and you should know it. Three things make it wrong here:
1. Retry has to wrap the transaction, and that depends on the order of two AOP proxies.
2. Calling a `@Transactional` method from the same class silently skips the proxy, so there's no transaction. This is the most common Spring transaction bug.
3. `SET LOCAL` has to run first inside the transaction, in every flow.

**The critical rule:** the body can run more than once, so nothing non-transactional goes inside it. The file-store call happens before `write`, and the same key is used across retries.

**CLS-3 applies the timeout to every write transaction**, not only ingest, because the 30-second bound on lock waits should cover join and leave too.

### 7.6 Keyset pagination and rank queries

**Keyset:** a repository receives `PageRequest<C>` with a typed cursor record, fetches `limit + 1` rows and returns them. `Page.of(...)` trims the extra row, and encodes the last visible row's key as `nextCursor` only if there was an extra one. `CursorCodec` is the only code that knows the wire format (base64url JSON with a version).

**Leaderboards:**

| Case | Statements |
|---|---|
| First page | `LeaderboardReader.topN`, using database 7.1's `RANK()`. Then `findMyScore`, and `countBetter` if the viewer has a score |
| Deep page | `pageAfter`, then `countBetter` for the first row's score, then `RankAssigner` |
| Top N viewer | `topN` with `limit` capped at N. No `me`, and a cursor returns 403 |

**Why two paths, when one would do:** the first page's plan was observed reading 11 rows for the top 10. `RANK()` on a deep page would have to read everything before it, so the deep path uses a count instead.

### 7.7 Database errors become domain results

The class that expects a failure handles it. Anything else goes to `ProblemExceptionHandler`.

| SQLSTATE | Handled in | Result |
|---|---|---|
| `23505` `uq_users_email_lower` | `AccountService.register` | `email_taken` |
| `23505` `uq_runs_user_file_hash` | `RunIngestService`, after rollback | 200 with the existing run |
| `23P01` `ex_runs_no_overlap` | `RunIngestService`, after rollback | Re-check the hash (CLS-5), then 409 with `conflictingRunId` |
| `23503` | `ProblemExceptionHandler` | `not_found` |
| `40P01`, `40001` | `TransactionRunner` | Retry, then `temporarily_unavailable` |
| `57014`, lost connection | `ProblemExceptionHandler` | `temporarily_unavailable`, with `Retry-After` |
| `22003`, `23514` | `ProblemExceptionHandler` | `internal_error` and an alert: a bug |

**`transaction_timeout` is treated as a lost connection, with no dependence on a specific SQLSTATE** (database 13.4). The connection is terminated, and the pool must replace it. Section 15 marks this for a failure test.

**A simplification:** friend requests use `INSERT ... ON CONFLICT DO NOTHING` and then a locked read, instead of catching `23505` and retrying (database 14.8). Behavior is the same, and no transaction aborts.

---

