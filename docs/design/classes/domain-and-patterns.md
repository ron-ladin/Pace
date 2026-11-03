# Classes: Domain model and patterns

> **Covers:** The domain model: what is rich, `Competition`, run validation, scoring strategies, typed IDs and enums (5); design patterns used and rejected (6); time handling (11).
> **Read when:** writing domain types or scoring, comparing times, or considering a new pattern.
> **Related:** [persistence.md](persistence.md), [flows-runs-competitions.md](flows-runs-competitions.md)

## 5. Domain model

### 5.1 What's rich and what isn't

**A rich domain object** holds rules as well as data, instead of leaving them to services. It's worth doing only where a rule must always hold, because otherwise it's ceremony.

| Type | Treatment | Why |
|---|---|---|
| `Competition` | **Rich** | Real invariants, used in many flows. Methods take time as a parameter, so tests need no clock |
| `NewCompetition` | **Rich.** Static factory enforces window, grace and rule rules | An invalid object can't exist |
| `Rule` | **Rich, small.** Constructor enforces "`minDistanceMeters` only for `fastest_pace`" | Mirrors `ck_competitions_rule_params` |
| `RunVerdict`, `PlausibilityRules`, `RunSanityRules` | **Rich.** Pure functions | The core of the validation outcome, and easy to test exhaustively |
| `FriendPair` | **Rich, small.** Orders the two IDs | Mirrors `ck_friendships_order` |
| `RunMetrics` | **Value object.** `paceSecondsPerKm()` | Must match the generated column |
| `User`, `Group`, `Run`, `Membership`, `Participant` | **Data only** | No rule to protect. Methods on these would be overkill |

**A rich `User` was considered and rejected.** Its rules (password strength, weak-password list, deletion) all need outside collaborators, and a domain type with injected services is the wrong shape. Those rules belong in `PasswordService` and `AccountDeletionService`.

### 5.2 `Competition`

```java
public CompetitionState stateAt(Instant now) {...}          // closed_at set -> CLOSED; now < startsAt -> UPCOMING;
                                                            // now < endsAt -> RUNNING; otherwise FINALIZING
public boolean canJoinAt(Instant now)  { /* closedAt == null && now < endsAt */ }
public boolean canLeaveAt(Instant now) { /* now < endsAt */ }                    // D39
public boolean isDeletableAt(Instant now, int participants) { /* now < startsAt && participants == 1 */ }
public EligibilityWindow window() {...}
```

**The rules come from database 3.3, D39 and API-6.** `now` always comes from the database (section 11).

**Why eligibility isn't here.** The rule is "`valid`, started inside `[starts_at, ends_at)`, received before `closes_at`" (D27). It's applied by SQL to an aggregate, so a Java method would have no caller. It appears in exactly two statements, one in each direction:

- `EligibleRunsReader`: which runs count for this competition?
- `CompetitionRepository.findEligibleForRun`: which competitions does this run count for?

A test runs the same boundary cases through both, so they can't quietly disagree.

**Close rules** aren't methods either. Closure is `SELECT ... FOR UPDATE`, `closed_at` check and update (database 6.5), so the rule is in `CompetitionClosureJob`.

### 5.3 Run validation outcome

```java
sealed interface RunVerdict permits Valid, Invalid {}
record Valid() implements RunVerdict {}
record Invalid(InvalidReason reason) implements RunVerdict {}
```

`RunSanityRules.check` **throws**, because a failure is a rejection with no stored row. `PlausibilityRules.classify` **returns**, because an implausible run is a legitimate outcome that gets stored. The two types make that difference visible.

**Order, from api 7.5:** `pace_too_fast`, `pace_too_slow`, `gps_speed_jump`, `duration_too_long`. Only one reason is stored, because `invalid_reason` holds one value, so the first match wins. **Expected to change** as open question 6 is tuned.

`gps_speed_jump` can't be judged after parsing without storing every point, which section 7.3 of the API design forbids in spirit. So `GpxParser` applies the speed and distance thresholds while streaming, and `ParsedRun.hasSpeedJump` carries the answer. It's the one threshold the parser has to know.

### 5.4 Scoring strategies

```java
interface ScoringStrategy {
    RuleType ruleType();
    Integer score(EligibleRunsReader runs, Competition competition, UserId user);   // null: no eligible run
}
class FastestPaceStrategy implements ScoringStrategy {
    public Integer score(EligibleRunsReader runs, Competition c, UserId user) {
        return runs.minPace(user, c.window(), c.rule().minDistanceMeters());
    }
}
```

**How the right strategy is chosen:** `ScoringStrategies` receives Spring's `List<ScoringStrategy>`, builds a `Map<RuleType, ScoringStrategy>`, and **fails at startup if any `RuleType` has none**. A missing strategy can't reach production.

**Why the strategy doesn't hold SQL:** D40 keeps SQL in persistence, and each `EligibleRunsReader` method is one statement. That matters, because under READ COMMITTED only a *new* statement sees data committed while the transaction waited for a lock (database 6.3). The strategies are small, and that's fine. Their job is to choose.

**`ScoreDirection` and `ScoreUnit` live on `RuleType`, not the strategy,** because `leaderboards` needs them and shouldn't depend on scoring.

**No write if unchanged** (D18) is the SQL's job: `updateScoreIfChanged` uses `score IS DISTINCT FROM`.

### 5.5 Ranked entries

`RankedEntry(int rank, UserId userId, String displayName, int score, String photoKey)`. `RankAssigner` receives ordered rows and the first row's rank, and applies: a tied row keeps the previous rank, and otherwise the rank is the row's position plus the first rank. This reproduces 1, 1, 3 across page boundaries, because `countBetter` counts strictly better scores.

### 5.6 Typed IDs

`UserId`, `GroupId`, `CompetitionId` and `RunId` are records wrapping a UUID. **They earn their place:** `lockParticipant(CompetitionId, UserId)` can't be called with the arguments swapped, and with bare UUIDs it would compile and quietly lock nothing.

They live in `platform.id`, because `RowLocks` and security need them, and `platform` can't depend on modules.

**Controllers take `UUID` path variables, and wrap them immediately.** Spring's type mismatch then gives the standard 400 `malformed_request`, with no custom converters. DTOs expose `UUID` too, so JSON stays plain.

### 5.7 Enums that map to `CHECK` values

Each enum implements `DbCode { String code(); }`, holding the exact schema text. `DbCodes.parse(Class, String)` converts on read.

**A test compares every enum to the schema's real `CHECK` list**, read from `pg_constraint` in Testcontainers. A migration that changes one without the other fails the build.

| Enum | Schema constraint | Open in the API? |
|---|---|---|
| `RunPrivacy` | `ck_users_run_privacy` | No |
| `RunSource` | `ck_runs_source` | Yes |
| `RunStatus` | `ck_runs_status` | No |
| `FriendshipStatus` (private to `FriendshipRepository`) | `ck_friendships_status` | Mapped to `accepted`, `incoming`, `outgoing` by viewer |
| `GroupVisibility` | `ck_groups_visibility` | No |
| `GroupRole` | `ck_group_members_role` | No |
| `CompetitionVisibility` | `ck_competitions_visibility` | No |
| `RuleType` | `ck_competitions_rule_type` | Yes |

**`invalid_reason` has no `CHECK`**, and reasons will be tuned. `InvalidReason` is used when writing, and reads keep a plain `String`, so old values survive renames, and the open enum in the API stays honest.

### 5.8 Three traps worth knowing

| Trap | What goes wrong | The design's answer |
|---|---|---|
| **Pace rounding** | PostgreSQL rounds exact `numeric`, and Java's `double` doesn't, so plausibility could judge a different pace from the stored one | `RunMetrics` uses integers: `(2000 * duration + distance) / (2 * distance)`. A test compares it against the generated column |
| **UUID order** | Java's `UUID.compareTo` compares *signed* longs, and PostgreSQL compares bytes. UUIDv7 happens to agree today, but relying on that is fragile. `FriendPair` would violate `ck_friendships_order`, and the lock guard would misorder | `Ids.compare` uses `Long.compareUnsigned` |
| **Generated pace and inserts** | A pace written by Java would be refused, since the column is `GENERATED ALWAYS` | `RunRepository.insert` omits it, and reads it back with `RETURNING` |

---

## 6. Design patterns

### 6.1 Used

| Pattern | Problem | Why this | Alternatives |
|---|---|---|---|
| **Strategy** (required, D18) | Each rule scores differently, and more are coming | **Open/Closed Principle:** a new rule is a new class, and no existing scoring code changes | `switch`, where every new rule edits old code. Enum with behavior, which can't take injected dependencies in Phase 2 |
| **Registry** (`ScoringStrategies`) | Choosing a strategy, safely | Startup fails if a rule has no strategy | Lookup at call time, which fails only when that rule's first run arrives |
| **Dependency inversion / SPI** | Upward calls with no cycles | The lower module states what it needs, and knows nothing about who provides it | Spring events, a shared module |
| **Execute-around** (`TransactionRunner`) | Setup, timeout and retry around a body | Can't be forgotten or misordered | `@Transactional` plus AOP retry, with fragile ordering |
| **Policy** (per module) | Matrix rules, used for both enforcement and viewer flags | Pure functions take facts and return `ALLOWED`, `HIDDEN` or `FORBIDDEN`, so the matrix in api 9.2 becomes a table-driven test without Spring. **Single Responsibility Principle:** services orchestrate, and policies decide | Checks inside services, which then drift from viewer flags |
| **Facade** (`api/` interfaces) | Keeping a module's surface small | **Interface Segregation Principle:** `FriendshipLookup` has one method, because `runs` needs one thing | One big module service |
| **Value object, static factory** | Invalid states | Plain Java, and records make it cheap | Builders, not needed with records |
| **Resource acquisition** (`UploadSpool`, `AutoCloseable`) | The temp file must always be deleted | `try-with-resources` makes it automatic (api 7.3) | `finally` in the service, which is easy to get wrong |

### 6.2 Considered and rejected as overkill

| Pattern | Why not |
|---|---|
| **State pattern for competitions** | The state is derived from timestamps, and behavior is a few conditionals. One enum and four methods are enough. State objects suit stored state with many transitions |
| **CQRS** (separate read and write models) | `LeaderboardReader` is simply a read-only class. Nothing here needs separate models or stores |
| **Domain events and a bus** | D26 defers asynchronous work, and direct calls show the order |
| **Generic `BaseRepository`** | Hides SQL, and no two tables share enough to justify it |
| **Mapper classes, MapStruct** | Static `from(...)` on each DTO is shorter, explicit, and has no annotation processor |
| **Command objects** | No queueing, undo or replay. Method calls do the job |
| **Specification** | Eligibility and search are SQL, so composable Java predicates would have nothing to act on |
| **Saga** | One database and one transaction. The file-before-commit order (database 6.3) plus cleanup jobs already covers object storage |
| **Decorator around `FileStore` for metrics** | A timer at the call site is one line |
| **Staged builder for locks** | See section 7.4 |

---

## 11. Time (D63)

**The rule:** anything compared against a stored competition or session time uses the **database clock**. Coarse validation of client input uses **`java.time.Clock`**.

| Flow | "Now" comes from | Why |
|---|---|---|
| `received_at`, `closed_at`, `joined_at`, `score_updated_at` | `now()` in SQL | Database 3.2: one clock for closure |
| Session expiry and renewal | `now()` in SQL | Database 14.1 |
| Competition `state`, join, leave and delete rules | `now()` selected with the row, passed to `Competition` | One clock, and one copy of the rule |
| `asOf` on leaderboards | The same selected `now()` | Api 12.6 |
| Closure candidates | `now() - closure delay` in SQL | Database 6.5 |
| State filters in search | `now()` in SQL | Must run in `WHERE` |
| GPX future and age checks | `Clock` | Coarse, and it runs before any database call that would return time |
| Competition creation window checks | `Clock` | Input validation |
| Orphan-file age | `Clock`, against the object's timestamp | Object storage's clock anyway |
| Rate limiting | Bucket4j's own time source | D53 |
| HTTP `Date` header | The server's | Standard |

**No custom time port.** Domain methods take `now`, and `Clock` is already an interface.

### Inconsistencies found

| # | Finding | Assessment |
|---|---|---|
| 1 | **Database 6.3 doesn't say which clock the sanity checks use.** They run before the transaction | Application clock. The 2-minute tolerance makes normal skew harmless. No invariant depends on these checks being exact |
| 2 | **`now()` is the transaction's start time, so it goes stale during a lock wait.** A leave could pass `now() < ends_at` a few seconds after `ends_at` | Harmless, and bounded by the timeout that CLS-3 adds to every write. Accepted. `clock_timestamp()` would be precise, but would mix two times in one transaction |
| 3 | **API-6 says an upload can't conflict with deleting a competition,** because a run can't be scored before it starts. The 2-minute tolerance makes that slightly untrue | The locks still make it safe, provided ingest skips a competition row that's gone (CLS-4) |
| 4 | **A skew between the application and database clocks** can make a just-validated `endsAt` already past | No harm: the competition would simply be `finalizing`, or the state rule runs on the database's time. Not worth a check |

**Closure is safe by construction:** the candidate query uses `closes_at <= now() - 60 s`, and an ingest transaction lasts at most 30 s, so `closed_at >= closes_at` always holds (`ck_competitions_closed`).

---

