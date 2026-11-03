# API Detailed Design (Phase 1)

> **Status:** Design approved by the project owner. No application code exists yet.
>
> **The contract itself is [`docs/api/openapi.yaml`](../api/openapi.yaml).** If this document and that file disagree, the file wins, and the disagreement is a bug. This document explains why the contract looks the way it does.
>
> **Performance statements are predictions** until the data generator and load tests exist. Section 21 lists what was verified and what wasn't.

The decision IDs (D-numbers) refer to the log in section 10 of `ARCHITECTURE.md`. "Database 6.3" means section 6.3 of [`database.md`](database.md).

## Section map

This document is split into topic files. Section numbers and headings never changed, so a citation such as "api 7.2" still means the section with that number. Find its file here, and read only that file.

| File | Sections | Read when |
|---|---|---|
| This file | [1 Design summary](#1-design-summary) | You want the design in one screen. |
| [conventions.md](api/conventions.md) | [2 Constraints](api/conventions.md#2-constraints); [3 Conventions](api/conventions.md#3-conventions); [6 Pagination, sorting and filtering](api/conventions.md#6-pagination-sorting-and-filtering); [13 HTTP caching](api/conventions.md#13-http-caching) | Designing or changing any endpoint or response shape. |
| [endpoints.md](api/endpoints.md) | [4 Endpoint catalog](api/endpoints.md#4-endpoint-catalog); [5 Data placement](api/endpoints.md#5-data-placement) | Looking up an endpoint or adding one. `check_coverage.mjs` compares this catalog with the contract. |
| [upload.md](api/upload.md) | [7 Run upload](api/upload.md#7-run-upload) | Working on run ingest, GPX parsing or photo upload. |
| [auth.md](api/auth.md) | [8 Authentication](api/auth.md#8-authentication); [9 Authorization](api/auth.md#9-authorization) | Working on login, sessions, CSRF or who can see what. |
| [errors-and-concurrency.md](api/errors-and-concurrency.md) | [10 Error model](api/errors-and-concurrency.md#10-error-model); [11 Idempotency and concurrency](api/errors-and-concurrency.md#11-idempotency-and-concurrency) | Adding an error code, handling a database error, or reasoning about retries. |
| [competition-semantics.md](api/competition-semantics.md) | [12 Competition and leaderboard semantics](api/competition-semantics.md#12-competition-and-leaderboard-semantics); [19 Polling versus push](api/competition-semantics.md#19-polling-versus-push) | Working on competitions, leaderboard responses or polling. |
| [limits-security-observability.md](api/limits-security-observability.md) | [14 Rate limiting and size limits](api/limits-security-observability.md#14-rate-limiting-and-size-limits); [15 Security checklist](api/limits-security-observability.md#15-security-checklist); [16 Observability](api/limits-security-observability.md#16-observability) | Working on rate limiting, a security review, logging or metrics. |
| [contract-and-verification.md](api/contract-and-verification.md) | [17 Contract, tooling and tests](api/contract-and-verification.md#17-contract-tooling-and-tests); [18 Mapping to the database](api/contract-and-verification.md#18-mapping-to-the-database); [20 Coverage](api/contract-and-verification.md#20-coverage); [21 Verification](api/contract-and-verification.md#21-verification); [22 Sources](api/contract-and-verification.md#22-sources) | Tracing an endpoint to its tables, checking coverage, or checking what was verified. |

---

## 1. Design summary

| Topic | Decision | ID |
|---|---|---|
| Style | REST, JSON, `/api/v1`, camelCase, units in field names | D41 |
| Hosting | PWA and API on one origin, so no CORS | D42 |
| Authentication | Opaque session token, stored hashed, in an `HttpOnly` cookie. No JWT, and no bearer token yet | D43 |
| CSRF | `SameSite=Strict`, plus a server check of `Sec-Fetch-Site` and `Origin`. No tokens | D44 |
| Errors | RFC 9457 Problem Details, with a stable `code` | D45 |
| Hidden resources | Can't see it: 404. Can see it, can't do this: 403 | D46 |
| Pagination | Keyset with an opaque cursor, and one fixed order per list | D47 |
| Upload | Raw body. Duplicate check first. New run 201, existing run 200 | D48 |
| Plausibility | Configurable starting thresholds | D49 |
| Email | Deferred, but **required before opening to the public** | D50 |
| Freshness | Polling every 25 s while visible, with ETags | D51 |
| Contract | Hand-written OpenAPI 3.1, linted | D52 |
| Rate limits | In the app, in memory | D53 |
| Finding people | Display-name search, and run viewing gated by `run_privacy` | D54 |
| Creating a competition | The creator auto-joins. Public competitions need an explicit consent flag | D55 |
| Retries | No `Idempotency-Key`, no `If-Match`. Groups and competitions can't be edited | D56 |

---

