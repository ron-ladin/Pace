# Classes: Traceability

> **Covers:** Tables from endpoints, access patterns, races, transactions and decisions to their classes.
> **Read when:** finding which classes implement an endpoint, race or decision. `check_classes.mjs` reads these tables.
> **Related:** [inventory.md](inventory.md), [../api/endpoints.md](../api/endpoints.md), [../database/transactions.md](../database/transactions.md)

## 14. Traceability

### 14.1 Endpoints

All 45 operations in `openapi.yaml`. DB refers to `database.md` items.

| Endpoint | Controller method | Service method | Repository method | DB |
|---|---|---|---|---|
| `POST /auth/register` | `AuthController.register` | `AccountService.register` | `UserRepository.insert`, `SessionRepository.insert` | 3.1, 14.1 |
| `POST /auth/login` | `AuthController.login` | `AuthService.login` | `UserRepository.findActiveByEmail`, `SessionRepository.insert` | 14.1 |
| `POST /auth/logout` | `AuthController.logout` | `AuthService.logout` | `SessionRepository.delete` | 14.1 |
| `GET /me` | `MeController.get` | `AccountService.get` | `UserRepository.findActiveById` | 3.1 |
| `PATCH /me` | `MeController.update` | `AccountService.update` | `UserRepository.updateProfile` | 3.1 |
| `PUT /me/password` | `MeController.changePassword` | `AccountService.changePassword` | `UserRepository.updatePassword`, `SessionRepository.deleteAllExcept` | 14.1 |
| `POST /me/deletion` | `MeController.delete` | `AccountDeletionService.deletePhase1` | `UserRepository.wipeForDeletion`, `SessionRepository.deleteAllForUser` | 6.6, 14.4 |
| `PUT /me/photo` | `MeController.putPhoto` | `PhotoService.put` | `UserRepository.updatePhotoKey` | 14.4 |
| `DELETE /me/photo` | `MeController.deletePhoto` | `PhotoService.delete` | `UserRepository.updatePhotoKey` | 14.4 |
| `GET /me/stats` | `StatsController.get` | `StatsService.get` | `RunStatsRepository.periods` | 14.7 |
| `GET /users` | `UserController.search` | `UserDirectoryService.search` | `UserRepository.searchByDisplayName` | 14.7 |
| `GET /users/{userId}` | `UserCardController.get` | `FriendshipService.cardFor` | `FriendshipRepository.exists` | 14.7 |
| `GET /users/{userId}/photos/{photoId}` | `UserController.photo` | `PhotoService.open` | `UserRepository.findActiveById` | 14.7 |
| `GET /users/{userId}/runs` | `RunController.listForUser` | `RunQueryService.listForUser` | `RunRepository.pageValidForViewer` | 7.5 |
| `POST /runs` | `RunController.upload` | `RunIngestService.ingest` | `RunRepository.findByHash`, `RunRepository.insert` | 14.2, 6.3, 6.2 |
| `GET /me/runs` | `RunController.listMine` | `RunQueryService.listMine` | `RunRepository.pageForOwner` | 7.5 |
| `GET /runs/{runId}` | `RunController.get` | `RunQueryService.get` | `RunRepository.findById` | 7.5 |
| `GET /me/friends` | `FriendController.list` | `FriendshipService.list` | `FriendshipRepository.page` | 14.7 |
| `PUT /me/friends/{userId}` | `FriendController.put` | `FriendshipService.request` | `FriendshipRepository.insertIfAbsent`, `FriendshipRepository.accept` | 3.5 |
| `DELETE /me/friends/{userId}` | `FriendController.delete` | `FriendshipService.remove` | `FriendshipRepository.delete` | 3.5 |
| `POST /groups` | `GroupController.create` | `GroupService.create` | `GroupRepository.insert`, `GroupMemberRepository.insertIfAbsent` | 3.5 |
| `GET /groups` | `GroupController.search` | `GroupService.search` | `GroupRepository.searchPublic` | 14.7 |
| `GET /me/groups` | `GroupController.listMine` | `GroupService.listMine` | `GroupMemberRepository.pageForUser` | 14.7 |
| `GET /groups/{groupId}` | `GroupController.get` | `GroupService.get` | `GroupRepository.findForViewer`, `GroupMemberRepository.countMembers` | 3.5 |
| `DELETE /groups/{groupId}` | `GroupController.delete` | `GroupService.delete` | `GroupRepository.deleteById` | 14.6 |
| `GET /groups/{groupId}/members` | `GroupMemberController.list` | `GroupMembershipService.list` | `GroupMemberRepository.pageMembers` | 14.7 |
| `PUT /groups/{groupId}/members/me` | `GroupMemberController.join` | `GroupMembershipService.join` | `GroupMemberRepository.insertIfAbsent`, `GroupInvitationRepository.delete` | 3.5 |
| `DELETE /groups/{groupId}/members/me` | `GroupMemberController.leave` | `GroupMembershipService.leave` | `GroupMemberRepository.delete`, `GroupMemberRepository.findLongestStanding` | 14.6 |
| `PATCH /groups/{groupId}/members/{userId}` | `GroupMemberController.changeRole` | `GroupMembershipService.changeRole` | `GroupMemberRepository.updateRole`, `GroupMemberRepository.countAdmins` | 14.6 |
| `DELETE /groups/{groupId}/members/{userId}` | `GroupMemberController.remove` | `GroupMembershipService.remove` | `GroupMemberRepository.delete`, `GroupMemberRepository.countAdmins` | 14.6 |
| `PUT /groups/{groupId}/invitations/{userId}` | `GroupMemberController.invite` | `GroupMembershipService.invite` | `GroupInvitationRepository.insertIfAbsent` | 3.5 |
| `GET /groups/{groupId}/competitions` | `CompetitionController.listForGroup` | `CompetitionService.listForGroup` | `CompetitionRepository.pageForGroup` | 14.7 |
| `POST /competitions` | `CompetitionController.create` | `CompetitionService.create` | `CompetitionRepository.insert`, `ParticipantRepository.insertIfAbsent` | 14.6, 6.4 |
| `GET /competitions` | `CompetitionController.search` | `CompetitionService.search` | `CompetitionRepository.searchPublic` | 14.7 |
| `GET /me/competitions` | `CompetitionController.listMine` | `CompetitionService.listMine` | `CompetitionRepository.pageForUser` | 14.7 |
| `GET /competitions/{competitionId}` | `CompetitionController.get` | `CompetitionService.get` | `CompetitionRepository.findForViewer`, `ParticipantUsersReader.countActive` | 14.7 |
| `DELETE /competitions/{competitionId}` | `CompetitionController.delete` | `CompetitionService.delete` | `CompetitionRepository.deleteById` | 14.6 |
| `GET /competitions/{competitionId}/participants` | `ParticipationController.list` | `ParticipationService.list` | `ParticipantUsersReader.pageActive` | 14.7 |
| `PUT /competitions/{competitionId}/participants/me` | `ParticipationController.join` | `ParticipationService.join` | `ParticipantRepository.insertIfAbsent`, `EligibleRunsReader.sumDistance` | 14.3, 6.4 |
| `DELETE /competitions/{competitionId}/participants/me` | `ParticipationController.leave` | `ParticipationService.leave` | `ParticipantRepository.delete` | 6.4 |
| `PUT /competitions/{competitionId}/invitations/{userId}` | `InvitationController.invite` | `CompetitionInvitationService.invite` | `CompetitionInvitationRepository.insertIfAbsent` | 3.5 |
| `GET /competitions/{competitionId}/leaderboard` | `LeaderboardController.get` | `LeaderboardService.read` | `LeaderboardReader.topN`, `LeaderboardReader.countBetter` | 7.1, 7.2, 14.7 |
| `GET /me/invitations` | `InvitationController.listMine` | `CompetitionInvitationService.listMine` | `CompetitionInvitationRepository.newestFor`, `GroupInvitationRepository.newestFor` | 14.7 |
| `DELETE /me/invitations/groups/{groupId}` | `GroupMemberController.decline` | `GroupMembershipService.decline` | `GroupInvitationRepository.delete` | 3.5 |
| `DELETE /me/invitations/competitions/{competitionId}` | `InvitationController.decline` | `CompetitionInvitationService.decline` | `CompetitionInvitationRepository.delete` | 3.5 |

**No endpoint or requirement lacks a home.**

### 14.2 Access patterns

| Pattern | Owner |
|---|---|
| R1 | `SessionAuthenticationFilter`, `SessionService.authenticate`, `SessionRepository.findValid` |
| R2 | `LeaderboardService.read`, `LeaderboardReader` |
| R3 | `RunQueryService`, `RunRepository` |
| R4 | `StatsService`, `RunStatsRepository` |
| R5 | `CompetitionService.get`, `ParticipationService.list`, `ParticipantUsersReader` |
| R6 | `CompetitionService.listMine`, `CompetitionRepository.pageForUser` |
| R7 | `FriendshipService`, `GroupMembershipService.list`, `GroupService`, `UserDirectoryService` |
| R8 | `GroupService.search`, `CompetitionService.search` |
| W1 | `RunIngestService.ingest` |
| W2 | `ScoringService`, called from ingest, join and create |
| W3 | `CompetitionService`, `ParticipationService`, `CompetitionInvitationService` |
| W4 | `CompetitionClosureJob` |
| W5 | `FriendshipService`, `GroupService`, `GroupMembershipService` |
| W6 | `AccountService`, `PhotoService`, `AccountDeletionService`, `AccountPurgeJob` |

### 14.3 Transactions and races

**Transactions:**

| DB item | Transaction | Owner | Locks, in order |
|---|---|---|---|
| 6.3 | Ingest | `RunIngestService.ingest`, `ScoringService.onRunAccepted` | `SHARE` user, per competition `SHARE` competition then `UPDATE` participant |
| 6.4 | Join | `ParticipationService.join` | `NO_KEY_UPDATE` user, `SHARE` competition |
| 6.4 | Leave | `ParticipationService.leave` | `NO_KEY_UPDATE` user, `SHARE` competition |
| 6.5 | Closure | `CompetitionClosureJob.runOnce` | `UPDATE` competition |
| 6.6, 14.4 | Deletion, phase 1 | `AccountDeletionService.deletePhase1` | `NO_KEY_UPDATE` user, `UPDATE` groups ascending |
| 8.2, 14.4 | Purge | `AccountPurgeJob.runOnce` | `SKIP LOCKED` user |
| 8.3 | Orphan cleanup | `OrphanFileCleanupJob.runOnce` | None |
| 14.4 | Session cleanup | `SessionCleanupJob.runOnce` | None |
| 14.6 | Group role change | `GroupMembershipService.changeRole` | `UPDATE` group |
| 14.6 | Group kick | `GroupMembershipService.remove` | `UPDATE` group |
| 14.6 | Group leave | `GroupMembershipService.leave` | `UPDATE` group |
| 14.6 | Group delete | `GroupService.delete` | `UPDATE` group |
| 14.6 | Create competition | `CompetitionService.create` | `NO_KEY_UPDATE` user, optional `SHARE` group |
| 14.6 | Delete competition | `CompetitionService.delete` | `UPDATE` competition |
| 3.5 | Accept a group invitation | `GroupMembershipService.join` | `SHARE` user (CLS-6) |
| 3.5 | Accept a competition invitation | `ParticipationService.join` | As join |
| 14.1 | Change password | `AccountService.changePassword` | None. Last write wins |

**Races. Each name below is the exact row name in `database.md` or `api.md`, so a script can check them:**

| Source | Race | Handled by |
|---|---|---|
| DB 6.3 | Same file twice, or a client retry | `RunRepository.findByHash`, then `uq_runs_user_file_hash` in `RunIngestService` |
| DB 6.3 | Same activity from another device | `ex_runs_no_overlap` in `RunIngestService` |
| DB 6.3 | Two overlapping uploads at once | `ex_runs_no_overlap`, plus the hash re-check |
| DB 6.3 | Two non-overlapping uploads at once | `RowLocks.lockParticipant` in `ScoringService` |
| DB 6.3 | File stored, then transaction fails | `OrphanFileCleanupJob` |
| DB 6.3 | Crash after commit, before response | `RunRepository.findByHash` on retry |
| DB 6.3 | API crash before commit | `OrphanFileCleanupJob` |
| DB 6.4 | Double-click on join | `RowLocks.lockActiveUser`, `ParticipantRepository.find` |
| DB 6.4 | Join while closing | `RowLocks.lockCompetition` in both flows, then `Competition.canJoinAt` |
| DB 6.4 | Reaching the competition limit from two tabs | `RowLocks.lockActiveUser`, then `CompetitionRepository.countOpenForUser` |
| DB 6.5 | Upload began before `closes_at`, and hasn't committed | `RowLocks.lockCompetition` with `UPDATE` in `CompetitionClosureJob` |
| DB 6.5 | Upload received after `closes_at` | `CompetitionRepository.findEligibleForRun`, `EligibleRunsReader` |
| DB 6.5 | Two application instances | `CompetitionClosureJob`, rechecks `closedAt` under the lock |
| DB 6.5 | Scheduler down | Eligibility uses `closes_at`, plus the overdue gauge |
| DB 6.6 | Upload in progress during deletion | `RowLocks.lockActiveUser` in both flows |
| DB 6.6 | Upload starts just after deletion | `RowLocks.lockActiveUser` returns false, so `unauthenticated` |
| DB 6.6 | Join during deletion | `RowLocks.lockActiveUser` returns false |
| DB 6.6 | A file stored after the purge | `OrphanFileCleanupJob` |
| DB 6.6 | Failure halfway through the purge | `AccountPurgeJob`: the row is the retry marker |
| api 11.4 | Double-click on the join that reaches the limit | `ParticipationService.join` checks the participant first |
| api 11.4 | Retry of a join after `ends_at` by a participant | `ParticipationService.join` checks the participant first |
| api 11.4 | Two admins demoting each other at once | `RowLocks.lockGroup` in `GroupMembershipService` |
| api 11.4 | The last admin leaves | `GroupMembershipService.leave` |
| api 11.4 | Demoting yourself as the last admin | `GroupMembershipService.changeRole` |
| api 11.4 | Join racing with competition deletion | `RowLocks.lockCompetition` in both flows |
| api 11.4 | Login racing with account deletion | `SessionRepository.findValid` joins `users` |

**New races this design found, each needing a test:**

| Race | Handled by |
|---|---|
| An admin leaves while another admin's account is deleted, and each sees the other as an admin | `SocialAccountDeletion` locks **every** group where the user is an admin, then counts under the lock (CLS-2) |
| A group join by a user being deleted | `RowLocks.lockActiveUser` with `SHARE` (CLS-6) |
| An invitation from a deleted inviter | `newestFor` joins `users` (CLS-7) |
| A concurrent duplicate raising `23P01` | `RunIngestService` re-checks the hash (CLS-5) |
| A run inside the future tolerance, while the competition is deleted | `ScoringService` skips a missing competition (CLS-4) |

**Required race tests, database 11.3:**

| # | Test | Owner under test |
|---|---|---|
| 1 | Two identical uploads | `RunIngestService` |
| 2 | Two overlapping uploads with different hashes | `RunIngestService` |
| 3 | Two non-overlapping uploads in one competition | `ScoringService` |
| 4 | Join and upload at once | `ParticipationService`, `RunIngestService` |
| 5 | Upload just before `closes_at`, with closure running | `RunIngestService`, `CompetitionClosureJob` |
| 6 | Upload after `closes_at` | `ScoringService` |
| 7 | Two closers | `CompetitionClosureJob` |
| 8 | Deletion during upload | `AccountDeletionService`, `RunIngestService` |
| 9 | Two sweepers | `AccountPurgeJob` |
| 10 | Join at the competition limit from two connections | `ParticipationService` |
| 11 | Leave at or after `ends_at` | `ParticipationService` |
| 12 | Double join on the competition that reaches the limit | `ParticipationService` |
| 13 | Two admins demoting each other at once | `GroupMembershipService` |
| 14 | Login racing with account deletion | `SessionRepository` |
| 15 | Retry of an accepted upload after its `started_at` passes the age limit | `RunIngestService` |
| 16 | Join racing with competition deletion | `ParticipationService`, `CompetitionService` |

### 14.4 Decisions

Every decision in the log. "None" means it has no consequence in the backend's class design.

| ID | Where it's realized |
|---|---|
| D1 | The whole design: Java records, sealed types, Spring Boot |
| D2 | None here: the client. `SessionCookies` assumes a browser |
| D3 | None here: runtime |
| D4 | Section 15: only free libraries |
| D5 | Module chain and `api/` packages (section 2) |
| D6 | `JdbcClient` repositories (section 7) |
| D7 | `FileStore`, `RunRepository` (which stores only the key) |
| D8 | None now. `LeaderboardReader` is the single class to change (section 12) |
| D9 | None now: open |
| D10 | `RunAcceptedListener` seam (section 12) |
| D11 | `ParsedRun`, `RunSource` |
| D12 | None: no sport type exists in the model |
| D13 | `EligibleRunsReader`, `CompetitionRepository.findEligibleForRun` |
| D14 | No delete method on `RunRepository`. `PlausibilityRules` |
| D15 | `LeaderboardReader.topN`, `RankAssigner` |
| D16 | `LeaderboardService`, `TopNEntryDto`, `LeaderboardProperties` |
| D17 | `LeaderboardReader`, `ParticipantUsersReader` filter deleted users |
| D18 | `ScoringStrategy`, `ParticipantRepository.updateScoreIfChanged` |
| D19 | `CompetitionRepository.findEligibleForRun`, `ScoringService.onRunAccepted` |
| D20 | Separate `social` and `competitions` modules. `Competition.groupId` |
| D21 | None now: phasing (section 12) |
| D22 | Metrics (section 9.2) |
| D23 | None here: scale |
| D24 | `UserId`, `GroupId`, `CompetitionId`, `RunId`. Database generates IDs |
| D25 | `RunIngestService` handles `23P01` |
| D26 | `RunIngestService` scoring inside its transaction. `RunAcceptedListener` seam |
| D27 | `ScoringService.recalculate`, `EligibleRunsReader` |
| D28 | `NewCompetition`, `CompetitionProperties` |
| D29 | `AccountDeletionService`, `AccountPurgeJob` |
| D30 | `GpxParser`, `RunVerdict`. No pending status exists |
| D31 | `ParticipationService.joinLocked` |
| D32 | `GroupPolicy`, `GroupMembershipService.join` |
| D33 | `RowLocks`, `TransactionRunner` |
| D34 | `ParticipationService.join`, `RunIngestService` lock the user row |
| D35 | Section 2.5, each exception in one class |
| D36 | `RunSanityRules`, `RunsProperties` |
| D37 | Layout in section 13. Roles are configuration |
| D38 | Section 6.2 and "no interfaces until needed" |
| D39 | `Competition.canLeaveAt`, `ParticipationService.leave` |
| D40 | Section 2.6, ArchUnit |
| D41 | DTOs, `JacksonConfig`, enum codes |
| D42 | `CsrfOriginFilter` configured origin. No CORS configuration |
| D43 | `SessionService`, `SessionToken`, `SessionCookies`, `TokenHash` |
| D44 | `CsrfOriginFilter` |
| D45 | `ErrorCode`, `ProblemFactory` |
| D46 | `AccessDecision`, policies |
| D47 | `CursorCodec`, `Page`, `PageRequest` |
| D48 | `RunController`, `UploadSpool`, `IngestResult` |
| D49 | `PlausibilityRules`, `GpxParser`, `RunsProperties` |
| D50 | Section 12: deferred |
| D51 | `LeaderboardEtag`, `LeaderboardProperties` |
| D52 | Section 16: DTOs follow the contract |
| D53 | `RateLimiter`, `RateLimitInterceptor` |
| D54 | `RunVisibilityPolicy`, `UserDirectoryService.search`, `FriendshipService.cardFor` |
| D55 | `CompetitionService.create`, `ParticipationService.joinLocked` |
| D56 | No update method on `CompetitionRepository` or `GroupRepository`. `CompetitionService.delete` |
| D57 | Section 7.1 |
| D58 | Sections 2.2, 2.6 |
| D59 | Section 2.3 |
| D60 | `TransactionRunner` |
| D61 | `RowLocks` |
| D62 | Section 5 |
| D63 | Section 11 |
| D64 | `ErrorCode`, `ApiException`, `ProblemFactory` |
| D65 | Section 9.10 |

---

