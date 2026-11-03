# Database Detailed Design (PostgreSQL)

> **Status:** Design approved by the project owner. No application code exists yet. The API design added amendments API-1 to API-6, and the class design added CLS-1 to CLS-8, all in [section 14](database/amendments.md#14-amendments-from-the-api-design). Where they differ from an earlier section, section 14 wins.
>
> **Verification status:**
> - **The DDL, constraints, lock behavior and query plans were verified on PostgreSQL 18.6** in a throwaway container. Section 13 has the results and what was not covered.
> - **All performance statements are still predictions** until the data generator and load tests exist. The plan checks show which indexes are used, and they aren't benchmarks.

This document turns the draft data model into the final Phase 1 design. It is driven by the access patterns (section 6 of `ARCHITECTURE.md`) and the non-functional requirements (section 5). The decision IDs (D-numbers) refer to the log in section 10 of `ARCHITECTURE.md`.

**Target version:** PostgreSQL 18.

## Section map

This document is split into topic files. Section numbers and headings never changed, so a citation such as "database 6.3" still means the section with that number. Find its file here, and read only that file.

| File | Sections | Read when |
|---|---|---|
| This file | [1 Design summary](#1-design-summary) | You want the design in one screen. |
| [schema.md](database/schema.md) | [2 Conventions](database/schema.md#2-conventions); [3 Schema](database/schema.md#3-schema); [12 Decisions on identifiers and overlaps](database/schema.md#12-decisions-on-identifiers-and-overlaps) | Reading or changing tables, columns or constraints. Check `amendments.md` too, because section 14 overrides earlier sections. |
| [indexes-and-queries.md](database/indexes-and-queries.md) | [4 Indexes](database/indexes-and-queries.md#4-indexes); [5 Access pattern map](database/indexes-and-queries.md#5-access-pattern-map); [7 Leaderboard queries](database/indexes-and-queries.md#7-leaderboard-queries) | Adding an index, writing a read query, or working on leaderboards. |
| [transactions.md](database/transactions.md) | [6 Transactions and races](database/transactions.md#6-transactions-and-races) (introduction, 6.1, 6.2, 6.3, 6.4, 6.5) | Writing a write transaction, taking a lock, or reasoning about a race. |
| [deletion-and-jobs.md](database/deletion-and-jobs.md) | [6.6 Account deletion (W6, D17, D29)](database/deletion-and-jobs.md#66-account-deletion-w6-d17-d29); [8 Scheduled jobs](database/deletion-and-jobs.md#8-scheduled-jobs) | Working on account deletion, the sweeper, closure or file cleanup. |
| [outbox.md](database/outbox.md) | [9 Milestone: async scoring via Outbox + queue (deferred)](database/outbox.md#9-milestone-async-scoring-via-outbox--queue-deferred) | Baseline measurements justify async scoring, or when choosing a queue. Not needed for Phase 1 work. |
| [migrations.md](database/migrations.md) | [10 Flyway migrations](database/migrations.md#10-flyway-migrations) | Writing or ordering a migration. |
| [validation.md](database/validation.md) | [11 Validation plan](database/validation.md#11-validation-plan); [13 Verification results](database/validation.md#13-verification-results) | Planning tests, checking what was verified, or judging a performance claim. |
| [amendments.md](database/amendments.md) | [14 Amendments from the API design](database/amendments.md#14-amendments-from-the-api-design) | Reading any other database section whose behavior may have been amended, such as sessions, ingest order or deletion. |

---

## 1. Design summary

| Topic | Decision |
|---|---|
| Upload | GPX is parsed in the API. One transaction inserts the run and updates scores. The response is 201 |
| Scoring | Recalculated from all eligible runs, never incremented |
| Eligibility | The run started inside the window **and** was received before `closes_at` |
| Grace period | 6 hours by default, configurable, 0 allowed |
| Joining | Runs already inside the window count (backfill) |
| Isolation | `READ COMMITTED`, plus constraints and explicit row locks |
| Account deletion | Two phases: immediate wipe and read-time filter, then physical purge |
| Leaderboards | Plain SQL over one partial index. No Redis until measured |
| Outbox and queue | Designed here but deferred until baseline measurements exist |

---

