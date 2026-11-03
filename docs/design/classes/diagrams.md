# Classes: Class diagrams

> **Covers:** The overview class diagram, and one diagram per module.
> **Read when:** you need the relationships between the classes of one module.
> **Related:** [inventory.md](inventory.md), [modules.md](modules.md)

## 4. Class diagrams

These show relationships only. Section 3 has the fields and methods.

### 4.1 Overview

```mermaid
classDiagram
    class RunController
    class RunIngestService
    class RunAcceptedListener {
        <<interface>>
    }
    class ScoringService
    class ScoringStrategy {
        <<interface>>
    }
    class EligibleRunsReader
    class RowLocks
    class TransactionRunner
    class LeaderboardService
    class CompetitionLookup {
        <<interface>>
    }
    class CompetitionService
    class AccountDeletionService
    class AccountDeletionParticipant {
        <<interface>>
    }
    class SocialAccountDeletion
    class CompetitionsAccountDeletion
    class SessionAuthenticationFilter
    class SessionAuthenticator {
        <<interface>>
    }
    class SessionService

    RunController --> RunIngestService
    RunIngestService --> TransactionRunner
    RunIngestService --> RowLocks
    RunIngestService --> RunAcceptedListener
    RunAcceptedListener <|.. ScoringService
    ScoringService --> ScoringStrategy
    ScoringService --> RowLocks
    ScoringStrategy --> EligibleRunsReader
    LeaderboardService --> CompetitionLookup
    CompetitionLookup <|.. CompetitionService
    AccountDeletionService --> AccountDeletionParticipant
    AccountDeletionParticipant <|.. SocialAccountDeletion
    AccountDeletionParticipant <|.. CompetitionsAccountDeletion
    SessionAuthenticationFilter --> SessionAuthenticator
    SessionAuthenticator <|.. SessionService
```

### 4.2 `platform`

```mermaid
classDiagram
    class ApiException
    class ErrorCode {
        <<enumeration>>
    }
    class ProblemFactory
    class ProblemExceptionHandler
    class ProblemSecurityHandlers
    class DbErrors
    class TransactionRunner
    class RowLocks
    class LockMode {
        <<enumeration>>
    }
    class FileStore {
        <<interface>>
    }
    class S3FileStore
    class RateLimiter
    class RateLimitInterceptor
    class CursorCodec
    class Page
    class SessionAuthenticator {
        <<interface>>
    }
    class SessionAuthenticationFilter
    class CsrfOriginFilter
    class Viewer {
        <<interface>>
    }

    ApiException --> ErrorCode
    ProblemExceptionHandler --> ProblemFactory
    ProblemExceptionHandler --> DbErrors
    ProblemSecurityHandlers --> ProblemFactory
    CsrfOriginFilter --> ProblemFactory
    TransactionRunner --> DbErrors
    RowLocks --> LockMode
    FileStore <|.. S3FileStore
    RateLimitInterceptor --> RateLimiter
    Page --> CursorCodec
    SessionAuthenticationFilter --> SessionAuthenticator
    SessionAuthenticationFilter --> Viewer
```

### 4.3 `identity`

```mermaid
classDiagram
    class AuthController
    class MeController
    class UserController
    class AccountService
    class AuthService
    class SessionService
    class PasswordService
    class PhotoService
    class UserDirectoryService
    class AccountDeletionService
    class AccountPurgeJob
    class SessionCleanupJob
    class UserRepository
    class SessionRepository
    class UserDirectory {
        <<interface>>
    }
    class SessionAuthenticator {
        <<interface>>
    }
    class AccountDeletionParticipant {
        <<interface>>
    }
    class AccountPurgeParticipant {
        <<interface>>
    }

    AuthController --> AccountService
    AuthController --> AuthService
    MeController --> AccountService
    MeController --> PhotoService
    MeController --> AccountDeletionService
    UserController --> UserDirectoryService
    UserController --> PhotoService
    AccountService --> UserRepository
    AccountService --> SessionService
    AccountService --> PasswordService
    AuthService --> UserRepository
    AuthService --> SessionService
    AuthService --> PasswordService
    SessionAuthenticator <|.. SessionService
    SessionService --> SessionRepository
    UserDirectory <|.. UserDirectoryService
    UserDirectoryService --> UserRepository
    PhotoService --> UserRepository
    AccountDeletionService --> UserRepository
    AccountDeletionService --> SessionService
    AccountDeletionService --> AccountDeletionParticipant
    AccountPurgeJob --> UserRepository
    AccountPurgeJob --> AccountPurgeParticipant
    SessionCleanupJob --> SessionRepository
```

### 4.4 `social`

```mermaid
classDiagram
    class FriendController
    class GroupController
    class GroupMemberController
    class UserCardController
    class FriendshipService
    class GroupService
    class GroupMembershipService
    class GroupPolicy
    class SocialAccountDeletion
    class FriendshipRepository
    class GroupRepository
    class GroupMemberRepository
    class GroupInvitationRepository
    class FriendPair
    class FriendshipLookup {
        <<interface>>
    }
    class GroupLookup {
        <<interface>>
    }
    class GroupInvitationLookup {
        <<interface>>
    }
    class AccountDeletionParticipant {
        <<interface>>
    }

    FriendController --> FriendshipService
    UserCardController --> FriendshipService
    GroupController --> GroupService
    GroupMemberController --> GroupMembershipService
    FriendshipLookup <|.. FriendshipService
    GroupLookup <|.. GroupService
    GroupInvitationLookup <|.. GroupMembershipService
    AccountDeletionParticipant <|.. SocialAccountDeletion
    FriendshipService --> FriendshipRepository
    FriendshipService --> FriendPair
    GroupService --> GroupRepository
    GroupService --> GroupMemberRepository
    GroupService --> GroupPolicy
    GroupMembershipService --> GroupMemberRepository
    GroupMembershipService --> GroupInvitationRepository
    GroupMembershipService --> GroupPolicy
    SocialAccountDeletion --> GroupMemberRepository
    SocialAccountDeletion --> FriendshipRepository
    SocialAccountDeletion --> GroupInvitationRepository
```

### 4.5 `runs`

```mermaid
classDiagram
    class RunController
    class StatsController
    class RunIngestService
    class RunQueryService
    class StatsService
    class RunVisibilityPolicy
    class GpxParser
    class UploadSpool
    class OrphanFileCleanupJob
    class RunsAccountPurge
    class ParsedRun
    class RunMetrics
    class RunSanityRules
    class PlausibilityRules
    class RunVerdict {
        <<interface>>
    }
    class RunRepository
    class RunStatsRepository
    class RunAcceptedListener {
        <<interface>>
    }
    class AccountPurgeParticipant {
        <<interface>>
    }

    RunController --> RunIngestService
    RunController --> RunQueryService
    StatsController --> StatsService
    RunIngestService --> UploadSpool
    RunIngestService --> GpxParser
    RunIngestService --> RunSanityRules
    RunIngestService --> PlausibilityRules
    RunIngestService --> RunRepository
    RunIngestService --> RunAcceptedListener
    GpxParser --> ParsedRun
    ParsedRun --> RunMetrics
    PlausibilityRules --> RunVerdict
    RunQueryService --> RunRepository
    RunQueryService --> RunVisibilityPolicy
    StatsService --> RunStatsRepository
    OrphanFileCleanupJob --> RunRepository
    AccountPurgeParticipant <|.. RunsAccountPurge
```

### 4.6 `competitions`

```mermaid
classDiagram
    class CompetitionController
    class ParticipationController
    class InvitationController
    class CompetitionService
    class ParticipationService
    class CompetitionInvitationService
    class CompetitionPolicy
    class ScoringService
    class ScoringStrategy {
        <<interface>>
    }
    class TotalDistanceStrategy
    class LongestRunStrategy
    class FastestPaceStrategy
    class ScoringStrategies
    class CompetitionClosureJob
    class CompetitionsAccountDeletion
    class Competition
    class NewCompetition
    class CompetitionRepository
    class ParticipantRepository
    class CompetitionInvitationRepository
    class EligibleRunsReader
    class ParticipantUsersReader
    class CompetitionLookup {
        <<interface>>
    }
    class RunAcceptedListener {
        <<interface>>
    }
    class AccountDeletionParticipant {
        <<interface>>
    }

    CompetitionController --> CompetitionService
    ParticipationController --> ParticipationService
    InvitationController --> CompetitionInvitationService
    CompetitionLookup <|.. CompetitionService
    RunAcceptedListener <|.. ScoringService
    AccountDeletionParticipant <|.. CompetitionsAccountDeletion
    CompetitionService --> ParticipationService
    CompetitionService --> CompetitionRepository
    CompetitionService --> CompetitionPolicy
    CompetitionService --> NewCompetition
    ParticipationService --> ParticipantRepository
    ParticipationService --> ScoringService
    ParticipationService --> CompetitionPolicy
    ParticipationService --> ParticipantUsersReader
    CompetitionInvitationService --> CompetitionInvitationRepository
    ScoringService --> ScoringStrategies
    ScoringStrategies --> ScoringStrategy
    ScoringStrategy <|.. TotalDistanceStrategy
    ScoringStrategy <|.. LongestRunStrategy
    ScoringStrategy <|.. FastestPaceStrategy
    ScoringStrategy --> EligibleRunsReader
    ScoringService --> ParticipantRepository
    ScoringService --> CompetitionRepository
    CompetitionClosureJob --> CompetitionRepository
    CompetitionPolicy --> Competition
```

### 4.7 `leaderboards`

```mermaid
classDiagram
    class LeaderboardController
    class LeaderboardService
    class RankAssigner
    class LeaderboardEtag
    class LeaderboardReader
    class CompetitionLookup {
        <<interface>>
    }

    LeaderboardController --> LeaderboardService
    LeaderboardController --> LeaderboardEtag
    LeaderboardService --> CompetitionLookup
    LeaderboardService --> LeaderboardReader
    LeaderboardService --> RankAssigner
```

---

