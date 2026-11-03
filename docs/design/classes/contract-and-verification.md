# Classes: Contract consistency and verification

> **Covers:** Library facts to verify (15), DTOs against contract schemas and mismatches found (16), small decisions (17) and verification results (18).
> **Read when:** choosing library versions, writing DTOs, or checking what was verified.
> **Related:** [../verification/README.md](../verification/README.md), [../../api/components/schemas.yaml](../../api/components/schemas.yaml), [inventory.md](inventory.md)

## 15. Library facts to verify

**Nothing here has been used in code.** Check the items marked **verify** when scaffolding starts.

| Fact | Status | Source |
|---|---|---|
| `JdbcClient` since Framework 6.1, with named parameters, `optional()` and `update()` | Confirmed on the page | [Spring docs](https://docs.spring.io/spring-framework/reference/data-access/jdbc/core.html) |
| An `UPDATE` touching a column with only an expression unique index takes `FOR NO KEY UPDATE`, and it conflicts with `FOR SHARE` | Confirmed on the page. So deletion's user lock conflicts with ingest, as database 6.6 assumes, and `lower(email)` doesn't raise it to `FOR UPDATE` | [PostgreSQL docs](https://www.postgresql.org/docs/current/explicit-locking.html) |
| `FOR KEY SHARE` conflicts only with `FOR UPDATE` | Confirmed on the page. It's why CLS-6 is needed | Same |
| jOOQ's open source edition is Apache-2.0, with PostgreSQL 18 as its minimum | From the support matrix. Java baseline **verify** if it's ever reconsidered | [jOOQ matrix](https://www.jooq.org/download/support-matrix) |
| Spring Data JDBC has composite IDs from 4.0 | From the Spring blog. Lock support **verify** | [Spring blog](https://spring.io/blog/2025/07/22/spring-data-jdbc-composite-id/) |
| Hibernate's `PESSIMISTIC_READ` is `FOR SHARE` | From the Hibernate docs. The `FOR NO KEY UPDATE` mapping, and how the persistence context interacts with locked reads: **verify**. Both are from my knowledge | [Hibernate docs](https://docs.hibernate.org/orm/7.2/javadocs/org/hibernate/LockMode.html) |
| Spring Boot 4 defaults to **Jackson 3**, on Framework 7 | From Spring's announcement. **Verify** the current line (4.1.x appeared latest). Imports (`tools.jackson`) and defaults differ from most examples online | [Spring blog](https://spring.io/blog/2025/10/07/introducing-jackson-3-support-in-spring/) |
| `jackson-databind-nullable` supports Jackson 3 and record components | Suggested by release 0.2.13, not stated outright. **Verify with a short test** | [Release notes](https://github.com/OpenAPITools/jackson-databind-nullable/releases/tag/v0.2.13) |
| Strict unknown-field rejection under Jackson 3 and Boot 4 | **Verify:** defaults may differ | |
| HikariCP discards the connection after a `transaction_timeout` `FATAL` | **Verify** with a failure test. The design only assumes that a lost connection maps to 503 | |
| Spring's `Argon2PasswordEncoder` needs BouncyCastle on the classpath | **Verify.** From my knowledge, and api 21.2 flags the same area | |
| MinIO's current community status, and which S3 client to use | **Verify.** `FileStore` keeps it swappable | |
| Spring Boot's structured logging, and Bucket4j's current API | **Verify** | |
| A unique index is checked before an exclusion constraint on insert | **Verify** through race test 1. CLS-5 makes the design safe either way | |
| Spring Security's filter ordering, as drawn in section 9.5 | **Verify** in the vertical slice | |

---

## 16. Consistency with the API contract

### 16.1 DTOs and schemas

Every object schema, with its fields. `check_classes.mjs` compares these lists to `openapi.yaml`, field by field, including `allOf` and nested objects.

| Schema path | Java type | Fields |
|---|---|---|
| Problem | `ProblemDetail`, from `ProblemFactory` | type, title, status, detail, instance, code, requestId, errors, conflictingRunId |
| CurrentUser | `CurrentUserDto` | id, email, displayName, birthDate, city, photoUrl, runPrivacy, timeZone, createdAt |
| UserCard | `UserCardDto`, `UserCardWithCityDto` | id, displayName, photoUrl, city |
| RegisterRequest | `RegisterRequest` | email, password, displayName, timeZone |
| LoginRequest | `LoginRequest` | email, password |
| UpdateMeRequest | `UpdateMeRequest` | displayName, birthDate, city, timeZone, runPrivacy |
| ChangePasswordRequest | `ChangePasswordRequest` | currentPassword, newPassword |
| DeleteAccountRequest | `DeleteAccountRequest` | password |
| PhotoResponse | `PhotoResponse` | photoUrl |
| Run | `RunDto`, `OwnRunDto` | id, source, startedAt, endedAt, distanceMeters, durationSeconds, paceSecondsPerKm, status, invalidReason, receivedAt |
| OwnRun | `OwnRunDto` | id, source, startedAt, endedAt, distanceMeters, durationSeconds, paceSecondsPerKm, status, invalidReason, receivedAt |
| Stats | `StatsDto` | timeZone, weekStart, weeks, months, totals, personalBests |
| Stats.totals | `StatsDto.Totals` | runCount, distanceMeters, durationSeconds |
| Stats.personalBests | `StatsDto.PersonalBests` | longestRun, fastestPace |
| StatsPeriod | `StatsPeriodDto` | startDate, runCount, distanceMeters, durationSeconds |
| Friendship | `FriendshipDto` | user, status, createdAt, acceptedAt |
| CreateGroupRequest | `CreateGroupRequest` | name, visibility, city |
| GroupSummary | `GroupSummaryDto` | id, name, visibility, city |
| MyGroup | `MyGroupDto` | id, name, visibility, city, role, joinedAt |
| Group | `GroupDto` | id, name, visibility, city, createdAt, memberCount, viewer |
| Group.viewer | `GroupDto.Viewer` | isMember, role, invited, canJoin, canInvite, canManage |
| Member | `MemberDto` | user, role, joinedAt |
| ChangeRoleRequest | `ChangeRoleRequest` | role |
| Rule | `RuleDto` | type, minDistanceMeters |
| CreateCompetitionRequest | `CreateCompetitionRequest` | name, city, rule, visibility, startsAt, endsAt, gracePeriodSeconds, groupId, consentToPublicLeaderboard |
| CompetitionSummary | `CompetitionSummaryDto` | id, name, city, rule, visibility, startsAt, endsAt, closesAt, state |
| MyCompetition | `MyCompetitionDto` | id, name, city, rule, visibility, startsAt, endsAt, closesAt, state, myScore, joinedAt |
| Competition | `CompetitionDto` | id, name, city, rule, visibility, startsAt, endsAt, closesAt, state, closedAt, createdAt, createdBy, group, participantCount, viewer |
| Competition.group | `CompetitionDto.GroupRef` | id, name |
| Competition.viewer | `CompetitionDto.Viewer` | isParticipant, invited, canJoin, canLeave, canInvite, canDelete |
| JoinCompetitionRequest | `JoinCompetitionRequest` | consentToPublicLeaderboard |
| Participation | `ParticipationDto` | competitionId, joinedAt, score |
| Participant | `ParticipantDto` | user, score, joinedAt |
| LeaderboardEntry | `TopNEntryDto`, `FullEntryDto` | rank, displayName, score, userId, photoUrl, isMe |
| Leaderboard | `LeaderboardDto` | state, scoreUnit, viewerAccess, asOf, pollIntervalSeconds, entries, me, nextCursor |
| Leaderboard.me | `LeaderboardDto.Me` | rank, score |
| Invitation | `InvitationDto` | type, target, invitedBy, createdAt |
| Invitation.target | `InvitationDto.Target` | id, name |

**Schemas that aren't objects:**

| Schema | Java |
|---|---|
| NextCursor | `String` on `Page` |
| GroupRole | `GroupRole`, via `code()` |
| CompetitionState | `CompetitionState`, via `code()` |
| RuleRequest | `RuleRequest(String type, Integer minDistanceMeters)`. Its `oneOf` is enforced by the `Rule` constructor, so a mismatch is 422 |

**Types:** IDs are `UUID`. Times are `Instant`. `birthDate` and `startDate` are `LocalDate`. Scores, distances and durations on a run are `int` or `Integer`. **Stats totals are `long`,** because `SUM` over a lifetime is `bigint`, and the contract's `integer` allows it. Enum fields in responses are `String` from `code()`, including open enums.

### 16.2 Mismatches found

All were **approved and applied** with this design. The contract was not changed silently.

| # | Finding | Change | Side |
|---|---|---|---|
| 1 | **Sliding sessions couldn't work as specified.** The cookie's `Max-Age` must be renewed with the session, or the browser drops it 30 days after login. No operation documented this `Set-Cookie` | A note in `info.description`, and the design refreshes the cookie on renewal | Spec, api 8.3 |
| 2 | **Out-of-range `limit` had no declared error on 7 operations:** `listUserRuns`, `listMyRuns`, `listMyGroups`, `listGroupMembers`, `listGroupCompetitions`, `listParticipants`, `getLeaderboard`. Others declare 422 for the same thing | 422 `validation_failed` added to these 7. Additive | Spec, api 4 |
| 3 | **`304` omitted `Vary`.** RFC 9110 requires a 304 to include `Vary` if the 200 would | `Vary: Cookie` added | Spec, api 13 |
| 4 | **The `createCompetition` example contradicted itself:** `state: running` with `canDelete: true`, but deletion requires "before it starts" | Example now has `canDelete: false` | Spec |
| 5 | **`Stats.weeks`:** did periods with no runs appear? | All requested periods, with zeros. Documented on the parameters | Spec |
| 6 | **`GET /groups/{groupId}/competitions` by an invitee of a private group:** the matrix didn't say, and no 403 is declared | Public competitions only, documented | Spec |
| 7 | **`pollIntervalSeconds` isn't in the ETag,** so a server-side interval change reaches a client only with the next real data change | Accepted, documented | api 13 |

**No field-name mismatches were found** when the script compared section 16.1 to the spec.

---

## 17. Small decisions

Each can be overturned without touching the structure.

| Decision | Reason |
|---|---|
| An invitee of a private group gets the group's **public** competitions only from `GET /groups/{groupId}/competitions` | They can see the group, but aren't members. No 403 is declared |
| `viewer.canJoin` ignores the limit of 10 | Saves a query on a hot read, and the 409 still protects the rule |
| `GET /users/{userId}/runs` with your own ID returns the `Run` shape, valid runs only | Same behavior as for anyone else. The owner's view is `/me/runs` |
| An old `photoId` returns 404 | Otherwise a replaced photo stays reachable |
| `leave` by a non-participant of a private competition returns 404, not 204 | They can't see it any more, and the spec declares 404 |
| Merged `/me/invitations` runs two queries and merges in Java | Each table stays with its owner |
| Controllers map with static `from(...)` on DTOs | No mapper layer |
| Spring Security stays, with its CSRF off | Deny-by-default, headers and a firewall for free |
| `FileStore` uses an S3 client, not a MinIO-specific one | D7 says S3-compatible |
| `users.updated_at` is set by repositories | No trigger exists, and database 3.4 rejected trigger logic |
| `RequestLogFilter` sits outside Spring Security | So rejected requests are logged too |
| Scheduler pool of 4 threads | A long purge can't delay closure |
| `competition_limit_reached` counts rows with `closed_at IS NULL` | Database 6.4's "open", so a delayed closure counts until it happens |
| Purge batch of 50 per tick | One user per minute is too slow after a backlog, and 50 is an estimate |
| `DbCode` for enums rather than a Jackson or JDBC converter | Explicit, and the test against `CHECK` lists needs it anyway |

---

## 18. Verification

**No code exists, so none of this design has been compiled or run.** Every check below tests consistency between documents. None shows that the design works, performs or avoids deadlocks. The race tests in database 11.3, plus the new ones in section 14.3, are the real proof, and they need the implementation.

### 18.1 What passed

Steps to reproduce: [`verification/README.md`](../verification/README.md).

| Check | Tool | Result |
|---|---|---|
| The module graph has no cycle, and every edge points down the chain | `check_classes.mjs`, with a cyclic negative control | Pass, 6 modules |
| Every inventory row has a kind, visibility and responsibility | `check_classes.mjs` | 150 rows, 161 named types |
| Every operation has a controller, service, repository and existing database item, and each class is in the inventory | `check_classes.mjs` | 45 of 45 |
| Every repository method the endpoint table names is defined in section 7 | `check_classes.mjs` | 62 of 62 |
| Every R1-R8 and W1-W6 pattern has an owner | `check_classes.mjs` | 14 of 14 |
| Every race row in database 6.3 to 6.6 and api 11.4 has an owner | `check_classes.mjs` | 26 of 26 |
| Every required race test has an owner | `check_classes.mjs` | 16 of 16 |
| Every transaction in `database.md` has an owner | `check_classes.mjs` | 17 rows |
| Every decision is in section 14.4, and every cited D-number exists | `check_classes.mjs` | 65 of 65 |
| DTO fields match the schemas, including `allOf` and nested objects | `check_classes.mjs` | 35 schemas, 189 fields |
| Every error code has a named raiser | `check_classes.mjs` | 34 of 34 |
| Diagrams name real classes, and each required flow exists | `check_classes.mjs` | 21 diagrams, 91 participants, 13 flows |
| Mermaid blocks parse | `check_mermaid.mjs` (Mermaid 10.9.1), with a negative control | `classes.md` 21, `ARCHITECTURE.md` 2, `api.md` 2. No failures |
| The amended contract is valid | Spectral 6.17.0 and Redocly CLI 2.73.0 in `node:22-alpine` | No errors, and one Redocly warning |
| The amended contract matches `api.md`, and examples conform | `check_coverage.mjs` | 45 operations, 395 examples, 65 decisions, no failures |
| The SQL extractors still work on the amended `database.md` | `extract_ddl.js`, `extract_amendments.js` | Pass. Section 14.8 adds no DDL, so the schema suites weren't re-run |

**Can the checker fail?** Each of these deliberate defects, applied to a copy of the documents, was caught with exit code 1:

| Defect | Reported as |
|---|---|
| An endpoint row removed | `spec operation has no home` |
| `identity` made to depend on `runs` | `module cycle` |
| A service renamed to an unknown class | `is not in the inventory` |
| A race row removed | `race has no owner` |
| A decision row removed | `is not in the decision table` |
| A DTO field misnamed | `is not in the schema` |
| A new field added to the spec only | `is missing from the table` |
| An error code row removed | `has no raiser` |
| A citation to a D-number that doesn't exist | `is not in the log` |
| A responsibility emptied | `no one-sentence responsibility` |

### 18.2 What wasn't verified

- **Everything about behavior.** No class exists. Whether the lock order prevents deadlocks, whether the guard in `RowLocks` works as a transaction resource, and whether the flows meet their latency targets are all unproven.
- **DTO types.** The script compares field **names**. Java types were checked by reading, and only at the level of section 16.1.
- **Method-level consistency beyond names.** The script checks that a named repository method is defined, and that a class exists. It doesn't check parameters, or that a service method appears in that class's row.
- **CLS-1 to CLS-8.** None was run against a server. Section 14.3 and database 14.8 name the test each one needs.
- **Library facts** marked **verify** in section 15.
- **Hibernate's lock mapping and persistence-context behavior,** which are from my knowledge, and are part of why JPA was rejected. If they're wrong, the case against JPA is weaker, but keyset pagination, `RANK()` and `ON CONFLICT` would still mostly be native queries.
