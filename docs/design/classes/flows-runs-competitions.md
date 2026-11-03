# Classes: Flows: runs and competitions

> **Covers:** The section 8 introduction, and the sequence flows for run ingest, join, leave, closure, leaderboard, and creating and deleting a competition. Flows 8.5 to 8.8, 8.10 and 8.11 are in `flows-identity-social.md`.
> **Read when:** implementing one of these flows.
> **Related:** [flows-identity-social.md](flows-identity-social.md), [persistence.md](persistence.md), [../database/transactions.md](../database/transactions.md)

## 8. Critical flows

Every flow below names its transaction boundary, its locks in order and its failure behavior. **Method names are expected to change, and the order isn't.**

### 8.1 Run ingest

```mermaid
sequenceDiagram
    participant C as RunController
    participant S as RunIngestService
    participant U as UploadSpool
    participant R as RunRepository
    participant G as GpxParser
    participant F as FileStore
    participant T as TransactionRunner
    participant L as RowLocks
    participant SC as ScoringService
    participant E as EligibleRunsReader

    C->>S: ingest(userId, body, length)
    S->>U: from(body, maxBytes)
    U-->>S: path, sha256
    S->>R: findByHash(userId, sha256)
    alt already uploaded
        R-->>S: run
        S-->>C: IngestResult(run, created false)
    else new file
        S->>G: parse(path)
        G-->>S: ParsedRun
        S->>S: RunSanityRules.check, PlausibilityRules.classify
        S->>F: put(key, path)
        S->>T: write(body)
        T->>L: lockActiveUser(userId, SHARE)
        T->>R: insert(newRun)
        opt run is valid
            T->>SC: onRunAccepted(run)
            SC->>SC: findEligibleForRun, sorted by id
            loop each competition, ascending
                SC->>L: lockCompetition(id, SHARE)
                SC->>L: lockParticipant(id, userId)
                SC->>E: sumDistance or maxDistance or minPace
                SC->>SC: updateScoreIfChanged
            end
        end
        T-->>S: committed run
        S-->>C: IngestResult(run, created true)
    end
```

| | |
|---|---|
| **Boundary** | `TransactionRunner.write`, around lock, insert and scoring. Spooling, parsing and storing are outside |
| **Locks, in order** | `FOR SHARE` user. For each competition, ascending: `FOR SHARE` competition, then `FOR UPDATE` participant |
| **Skip rules** | Competition gone or `closed_at` set: skip (CLS-4). Participant gone: skip |
| **Failures** | `23505`: rollback, return 200 with the existing run. `23P01`: rollback, re-check the hash (CLS-5), then 409 with `conflictingRunId`. Storage down: 503 `storage_unavailable`, nothing saved. No active user: 401. Deadlock: retried with the same file key. Timeout: 503, safe to retry. Any stored file with no row becomes an orphan for the daily job |
| **Order of checks** | api 7.2. The temp file is removed by `try-with-resources` |

### 8.2 Join competition, with backfill

```mermaid
sequenceDiagram
    participant C as ParticipationController
    participant S as ParticipationService
    participant T as TransactionRunner
    participant L as RowLocks
    participant CR as CompetitionRepository
    participant P as CompetitionPolicy
    participant PR as ParticipantRepository
    participant SC as ScoringService
    participant I as CompetitionInvitationRepository

    C->>S: join(competitionId, userId, consent)
    S->>T: write(body)
    T->>L: lockActiveUser(userId, NO_KEY_UPDATE)
    T->>L: lockCompetition(competitionId, SHARE)
    T->>PR: find(competitionId, userId)
    alt already a participant
        PR-->>S: existing row
        S-->>C: JoinResult(created false)
    else not yet
        T->>CR: findForViewer(competitionId, userId)
        T->>P: join(viewerRow, groupFacts)
        T->>CR: countOpenForUser(userId)
        T->>PR: insertIfAbsent(competitionId, userId)
        T->>SC: recalculate(competition, userId)
        T->>PR: updateScoreIfChanged(competitionId, userId, score)
        T->>I: delete(competitionId, userId)
        S-->>C: JoinResult(created true)
    end
```

| | |
|---|---|
| **Boundary** | The whole body |
| **Locks, in order** | `FOR NO KEY UPDATE` user, `FOR SHARE` competition. The new participant row needs no lock of its own |
| **Why this lock** | D34: without the per-user lock, ingest and join can both miss a run (database 6.4) |
| **Order of checks** | Participant first (API-3), then 404, consent, `ends_at`, limit. A retry after `ends_at` still gets 200 |
| **Failures** | Hidden or gone: 404. 422 `consent_required`. 409 `competition_join_closed`, `competition_limit_reached`. Racing with a deletion: the lock serializes them, so the join sees no row and returns 404 |

### 8.3 Leave competition

```mermaid
sequenceDiagram
    participant C as ParticipationController
    participant S as ParticipationService
    participant T as TransactionRunner
    participant L as RowLocks
    participant CR as CompetitionRepository
    participant PR as ParticipantRepository

    C->>S: leave(competitionId, userId)
    S->>T: write(body)
    T->>L: lockActiveUser(userId, NO_KEY_UPDATE)
    T->>L: lockCompetition(competitionId, SHARE)
    T->>CR: findForViewer(competitionId, userId)
    alt not a participant
        S-->>C: done, 204, or 404 if hidden
    else canLeaveAt(now) is false
        S-->>C: competition_leave_closed
    else allowed
        T->>PR: delete(competitionId, userId)
        S-->>C: done, 204
    end
```

| | |
|---|---|
| **Boundary** | The whole body |
| **Locks, in order** | `FOR NO KEY UPDATE` user, `FOR SHARE` competition |
| **Failures** | 409 `competition_leave_closed` from `ends_at` on (D39). Hidden: 404. A scoring transaction that loses the race skips the missing row, with no error (database 6.4) |

### 8.4 Closure scheduler

```mermaid
sequenceDiagram
    participant J as CompetitionClosureJob
    participant R as CompetitionRepository
    participant T as TransactionRunner
    participant L as RowLocks

    J->>R: findDueForClosure(delay)
    R-->>J: competition ids, no lock
    loop each competition, its own transaction
        J->>T: write(timeout, body)
        T->>L: lockCompetition(id, UPDATE)
        alt closed_at already set or row gone
            T-->>J: nothing to do
        else still open
            T->>R: markClosed(id)
            T-->>J: closed
        end
    end
```

| | |
|---|---|
| **Boundary** | One transaction per competition, so one failure can't block others |
| **Locks** | `FOR UPDATE` competition, which **waits** for ingest's `FOR SHARE` (database 6.5). Timeout 60 s |
| **Failures** | Logged and counted, and the next tick retries. A delay is safe, because eligibility uses `closes_at`, not `closed_at`. Two instances: the second waits, sees `closed_at`, and stops |

### 8.9 Leaderboard: top N and my rank

```mermaid
sequenceDiagram
    participant C as LeaderboardController
    participant S as LeaderboardService
    participant L as CompetitionLookup
    participant R as LeaderboardReader
    participant A as RankAssigner
    participant E as LeaderboardEtag

    C->>S: read(competitionId, viewer, limit, cursor)
    S->>L: findForViewer(competitionId, viewer)
    alt hidden or missing
        S-->>C: not_found
    else cursor and viewer is not a participant
        S-->>C: full_leaderboard_forbidden
    else first page
        S->>R: topN(competitionId, direction, limit)
        opt viewer is a participant
            S->>R: findMyScore(competitionId, userId)
            S->>R: countBetter(competitionId, direction, score)
        end
        S-->>C: LeaderboardView
    else deep page
        S->>R: pageAfter(competitionId, direction, cursor, limit)
        S->>R: countBetter(competitionId, direction, firstScore)
        S->>A: assign(rows, firstRowRank)
        S-->>C: LeaderboardView
    end
    C->>E: of(view)
    E-->>C: etag
    alt etag matches If-None-Match
        C-->>C: 304 with ETag, Cache-Control and Vary
    else changed
        C-->>C: 200 with body
    end
```

| | |
|---|---|
| **Boundary** | None. Separate autocommit statements, which may differ for an instant (database 7.3) |
| **Locks** | None |
| **Failures** | 404, 403 `full_leaderboard_forbidden`, 400 `invalid_cursor`. **The queries run even for a 304**, because computing the ETag needs the data (api 13) |

### 8.12 Create competition

```mermaid
sequenceDiagram
    participant C as CompetitionController
    participant S as CompetitionService
    participant N as NewCompetition
    participant T as TransactionRunner
    participant L as RowLocks
    participant G as GroupLookup
    participant R as CompetitionRepository
    participant P as ParticipationService

    C->>S: create(userId, input, consent)
    S->>N: of(input, grace, now, limits)
    S->>S: consent check for public
    S->>T: write(body)
    T->>L: lockActiveUser(userId, NO_KEY_UPDATE)
    opt groupId given
        T->>L: lockGroup(groupId, SHARE)
        T->>G: findForViewer(groupId, viewer)
    end
    T->>R: countOpenForUser(userId)
    T->>R: insert(newCompetition, userId)
    T->>P: joinLocked(competition, userId)
    S-->>C: CompetitionDetails
```

| | |
|---|---|
| **Boundary** | Everything after validation |
| **Locks, in order** | `FOR NO KEY UPDATE` user, optional `FOR SHARE` group. **The new competition needs no lock**, since nobody else can see it yet (API-6) |
| **Failures** | 422 `validation_failed`, `consent_required`. 404 if the group is hidden. 403 if the viewer isn't its admin. 409 `competition_limit_reached` |

### 8.13 Delete competition

```mermaid
sequenceDiagram
    participant C as CompetitionController
    participant S as CompetitionService
    participant T as TransactionRunner
    participant L as RowLocks
    participant R as CompetitionRepository
    participant U as ParticipantUsersReader
    participant P as CompetitionPolicy

    C->>S: delete(competitionId, userId)
    S->>T: write(body)
    T->>L: lockCompetition(competitionId, UPDATE)
    T->>R: findForViewer(competitionId, userId)
    T->>U: countActive(competitionId)
    T->>P: delete(viewerRow, count)
    alt not allowed
        S-->>C: forbidden or competition_not_deletable
    else allowed
        T->>R: deleteById(competitionId)
        S-->>C: done, cascades to participants and invitations
    end
```

| | |
|---|---|
| **Locks** | `FOR UPDATE` competition, which waits for any join holding `FOR SHARE` (API-6) |
| **Failures** | 404, 403, 409 `competition_not_deletable`. A join waiting on this lock then finds no row, and returns 404 |

---

