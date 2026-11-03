# Class Design (Phase 1 backend)

> **Status:** Design approved by the project owner. **No code exists, so nothing in this document has been compiled or run.** The design is checked for consistency against the other documents (section 18), and that says nothing about whether it works. The race tests in [`database.md`](database.md) section 11.3 remain the real proof.
>
> **What's firm and what isn't:** module boundaries, callback interfaces, `TransactionRunner`, `RowLocks`, the policy approach and the persistence choice are decisions. Method names, parameter lists, how repository methods are grouped, DTO factory details and job batch sizes are **expected to change during implementation**, and changing them needs no new decision.

The decision IDs (D-numbers) refer to the log in section 10 of [`ARCHITECTURE.md`](../../ARCHITECTURE.md). "Database 6.3" means section 6.3 of [`database.md`](database.md), and "api 7.2" means section 7.2 of [`api.md`](api.md). CLS-1 to CLS-8 are the amendments in database 14.8.

## Section map

This document is split into topic files. Section numbers and headings never changed, so a citation such as "classes 8.1" still means the section with that number. Find its file here, and read only that file.

| File | Sections | Read when |
|---|---|---|
| This file | [1 Summary and disagreements](#1-summary-and-disagreements); [1.1 The design in one screen](#11-the-design-in-one-screen); [1.2 Where this design disagrees with earlier decisions or leanings](#12-where-this-design-disagrees-with-earlier-decisions-or-leanings) | You want the design in one screen, or the earlier decisions it disagrees with. |
| [modules.md](classes/modules.md) | [2 Module map](classes/modules.md#2-module-map); [13 Package and file layout](classes/modules.md#13-package-and-file-layout) | Deciding where code goes, or adding a dependency between modules. |
| [inventory.md](classes/inventory.md) | [3 Class inventory](classes/inventory.md#3-class-inventory) | Looking up what a class does, or adding a class. `check_classes.mjs` reads this table. |
| [diagrams.md](classes/diagrams.md) | [4 Class diagrams](classes/diagrams.md#4-class-diagrams) | You need the relationships between the classes of one module. |
| [domain-and-patterns.md](classes/domain-and-patterns.md) | [5 Domain model](classes/domain-and-patterns.md#5-domain-model); [6 Design patterns](classes/domain-and-patterns.md#6-design-patterns); [11 Time (D63)](classes/domain-and-patterns.md#11-time-d63) | Writing domain types or scoring, comparing times, or considering a new pattern. |
| [persistence.md](classes/persistence.md) | [7 Persistence design](classes/persistence.md#7-persistence-design) | Writing a repository, a transaction or a lock. |
| [flows-runs-competitions.md](classes/flows-runs-competitions.md) | [8 Critical flows](classes/flows-runs-competitions.md#8-critical-flows) (introduction, 8.1, 8.2, 8.3, 8.4, 8.9, 8.12, 8.13) | Implementing one of these flows. |
| [flows-identity-social.md](classes/flows-identity-social.md) | [8.5 Account deletion, phase 1](classes/flows-identity-social.md#85-account-deletion-phase-1); [8.6 Account deletion, phase 2 (the sweeper)](classes/flows-identity-social.md#86-account-deletion-phase-2-the-sweeper); [8.7 Login](classes/flows-identity-social.md#87-login); [8.8 Session validation and CSRF, on every request](classes/flows-identity-social.md#88-session-validation-and-csrf-on-every-request); [8.10 Group role change, kick and leave](classes/flows-identity-social.md#810-group-role-change-kick-and-leave); [8.11 Group create, join and delete](classes/flows-identity-social.md#811-group-create-join-and-delete) | Implementing one of these flows. |
| [cross-cutting.md](classes/cross-cutting.md) | [9 Cross-cutting design](classes/cross-cutting.md#9-cross-cutting-design); [10 Scheduled jobs](classes/cross-cutting.md#10-scheduled-jobs); [12 Extension points](classes/cross-cutting.md#12-extension-points) | Working on `platform` code, a scheduled job, or planning an extension. |
| [traceability.md](classes/traceability.md) | [14 Traceability](classes/traceability.md#14-traceability) | Finding which classes implement an endpoint, race or decision. `check_classes.mjs` reads these tables. |
| [contract-and-verification.md](classes/contract-and-verification.md) | [15 Library facts to verify](classes/contract-and-verification.md#15-library-facts-to-verify); [16 Consistency with the API contract](classes/contract-and-verification.md#16-consistency-with-the-api-contract); [17 Small decisions](classes/contract-and-verification.md#17-small-decisions); [18 Verification](classes/contract-and-verification.md#18-verification) | Choosing library versions, writing DTOs, or checking what was verified. |

**Terms used in this document**

| Term | Meaning |
|---|---|
| **Module** | A top-level feature package, such as `runs`. Inside one running application, but with enforced boundaries |
| **Layer** | A sub-package inside a module, such as `web` or `persistence` |
| **Port** | An interface at a boundary with something external, such as object storage |
| **SPI** (service provider interface) | An interface that a lower module defines and a higher module implements |
| **Dependency inversion** | Making a high-level and a low-level part both depend on an abstraction, instead of one on the other. The D in SOLID |
| **Execute-around** | A method that does setup and teardown around a function you pass in |
| **Value object** | An immutable type defined only by its values, such as `RunMetrics` |
| **Typed ID** | A small record that wraps a UUID, so the compiler can tell a `UserId` from a `RunId` |
| **DTO** (data transfer object) | A record whose only purpose is to carry data across the HTTP boundary |
| **Persistence context** | Hibernate's per-transaction cache of loaded objects |

---

## 1. Summary and disagreements

### 1.1 The design in one screen

| Topic | Decision | ID |
|---|---|---|
| Data access | `JdbcClient` with plain SQL. No ORM | D57 |
| Modules | A strict chain: `leaderboards -> competitions -> runs -> social -> identity -> platform` | D58 |
| Inside a module | `api`, `web`, `service`, `persistence`, `domain` | D58 |
| Upward calls | Callback interfaces owned by the lower module | D59 |
| Transactions | `TransactionRunner`, an execute-around helper in the service layer | D60 |
| Locks | Every row lock goes through `RowLocks`, which checks the order at run time | D61 |
| Domain | Rich where invariants exist, plain records elsewhere | D62 |
| Time | The database clock for stored times, `java.time.Clock` for input validation | D63 |
| Errors | One `ErrorCode` enum, one `ApiException`, one `ProblemFactory` | D64 |
| Response shapes | Separate records per shape, `JsonNullable` for three-state fields | D65 |

### 1.2 Where this design disagrees with earlier decisions or leanings

| # | Decision or leaning | Position | Why |
|---|---|---|---|
| A | Package-private by default, so the compiler enforces module boundaries | **Can't work with D40's sub-packages** | Java package-private doesn't cross sub-packages, so a `service` class used by `web` has to be `public`. ArchUnit enforces boundaries instead. Package-private still applies inside one layer |
| B | D40's layout: `web`, `service`, `persistence` | **Incomplete, so extended by D58** | Repositories must return domain types, but `persistence` can't depend on `service`. Other modules also need a visible public surface. So `domain/` and `api/` are added |
| C | Modules call each other only through public service interfaces | **Holds, but four calls must go up the chain** | Those would create cycles, so they use callback interfaces (section 2.3) |
| D | D35 lists two read exceptions | **Two more were needed** | Hiding deleted users from `participantCount` requires `competitions` to read `users`. `RowLocks` also touches other modules' tables, for locks only |
| E | Ports for clock, password hasher, and maybe the GPX parser | **Only one new port: `FileStore`** | `java.time.Clock` and Spring's `PasswordEncoder` already are interfaces. The parser is pure, so tests use the real one, including with hostile files |
| F | D11's "source adapter abstraction" | **The seam is the `ParsedRun` record** | Live recording won't parse a file at all. An interface with one implementation and no second caller is speculation, and extracting one later takes minutes |
| G | The rich domain covers eligibility | **No Java `isEligible` method** | Eligibility is a SQL `WHERE` clause over an aggregate. A Java copy would be unused, or could disagree with it |
| H | Value objects for distance, duration and pace | **Overkill, except `RunMetrics`** | Field names already carry units. Typed IDs do earn their place, since most methods take two UUIDs and swapping them compiles silently |
| I | Repository "interfaces" | **Concrete classes** | Each has one implementation, and tests run them against real PostgreSQL. An interface here protects against a swap we don't expect, which is D40's own argument against Hexagonal |
| J | `@Transactional` (implied by "transaction boundaries in the service layer") | **`TransactionRunner` for writes** | Retry has to wrap the transaction, and `SET LOCAL` has to run inside it. The boundary is still in the service layer |
| K | A lock helper that makes violations impossible | **A run-time guard plus a source-scan test** | A compile-time staged builder can't check sort order inside a loop, and it would have to pass a token across modules |
| L | D33: "competitions sorted, then participants" | **The wording didn't match the design** | Database 6.3 alternates c1, p1, c2, p2. D33 is restated, including groups (CLS-2) |
| M | api 9.1: one query for "missing" and "hidden" | **Softened** | A private competition tied to a group needs a second statement into `social` |
| N | api 12.1: `state` is computed in SQL | **Computed in Java, from a database-supplied `now()`** | SQL `CASE` plus Java would be two copies of the rule. State filters still need SQL, and a test keeps the two in agreement |
| O | Three scheduled jobs | **Four** | API-4 added daily session cleanup |

**Accepted without changes:** separate DTOs, constructor injection only, immutability by default, one policy per module, one error-mapping point, one lock helper, and Strategy for scoring.

---

