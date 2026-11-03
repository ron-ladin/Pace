# API: Limits, security and observability

> **Covers:** Rate limits and size limits (14), the security checklist (15), and API observability (16).
> **Read when:** working on rate limiting, a security review, logging or metrics.
> **Related:** [auth.md](auth.md), [upload.md](upload.md), [../classes/cross-cutting.md](../classes/cross-cutting.md)

## 14. Rate limiting and size limits

### 14.1 Limits (D53)

Implemented in the app with Bucket4j (free), using in-memory state. Resetting on restart is fine.

| Class | Limit | Key |
|---|---|---|
| Login | 10 per 15 min, and 30 per 15 min | Email, and IP |
| Register | 5 per hour | IP |
| Upload | 30 per hour, and 100 per day | User |
| Friend requests and invitations | 30 per hour | User |
| Photo, password change | 10 per hour | User |
| Search | 30 per minute | User |
| Other writes | 60 per minute | User |
| Other reads | 300 per minute | User |
| Anonymous reads | 60 per minute | IP |

**These values are my estimates, and all are configurable.** A runner bulk-uploading 30 days of history fits within the upload limit, and a leaderboard polling at 25 s uses about 2.4 reads per minute.

- Over the limit: 429 with `Retry-After`. The IETF `RateLimit` headers aren't final, so they're left out.
- **Client IP comes only from the trusted proxy's header.** Otherwise, anyone could forge it and avoid the limit.
- **Fails open** if the limiter errors, per the degradation NFR.

**Rejected:**
- **A database table,** because a write per request for this is wasteful.
- **Redis,** which isn't justified yet (D8). Bucket4j has adapters, so moving later only changes configuration.

**A known limit:** in-memory limits are per instance. With two instances, the effective limit doubles. That is acceptable, and it is the trigger to move them.

### 14.2 Sizes

| Limit | Value | Enforced by |
|---|---|---|
| JSON body | 64 KB | Nginx and API |
| GPX body | 20 MB | Nginx and API |
| Photo body | 2 MB | Nginx and API |
| URL | 8 KB | Nginx |

---

## 15. Security checklist

| Area | Requirement |
|---|---|
| **Input validation** | At the boundary, with Bean Validation on request types that match the spec. Database constraints stay as the backstop |
| **SQL** | Parameterized queries only. `%` and `_` escaped in search input |
| **HTTPS** | Required, with HSTS. PWA installation and the Geolocation API need a secure context, and so do `Secure` cookies and `Sec-Fetch-Site`. `localhost` is fine for development |
| **Headers** | `X-Content-Type-Options: nosniff`, `Content-Security-Policy: default-src 'self'; frame-ancestors 'none'`, `Referrer-Policy: same-origin`, `Strict-Transport-Security` |
| **Enumeration** | Login is resistant. Registration can't be yet (section 8.5) |
| **ID guessability** | UUIDv7s aren't secrets, and every endpoint checks authorization |
| **Public responses** | Top N: rank, display name and score only. No user IDs, photos or personal details |
| **Secrets in logs** | Never log passwords, tokens, emails, coordinates, GPX contents or query strings |
| **Files** | XXE-safe parsing, and photos always re-encoded |
| **Actuator** | On a separate port, not routed through Nginx |
| **Route privacy zone** | **No API surface in Phase 1,** since no routes are exposed and there is no GPX download endpoint. The NFR applies when maps arrive |

---

## 16. Observability

**`X-Request-Id`:** accepted only if it matches `^[A-Za-z0-9._-]{8,64}$`, to prevent log injection (a client forging log lines through a crafted value). Otherwise, one is generated. It is returned on every response and in every error body, written to every log line, and later carried to `outbox_events.request_id`.

**Structured log fields:** `timestamp`, `level`, `requestId`, `userId`, `method`, `route` (the template, not the URL), `status`, `durationMs`, `errorCode`.

**Never logged:** email, tokens, passwords, coordinates, file contents, query strings.

**Metrics,** with Micrometer and Prometheus:
- `http.server.requests` by route template and status, with histogram buckets at 200 ms, 300 ms, 500 ms and 1 s, matching the targets.
- Upload timers for parse, store and transaction, so a slow upload can be located.
- Counters for ingest outcome (`created`, `duplicate`, `overlap`, `invalid`, each rejection), login outcome and rate-limit rejections.

**No user IDs in metric labels.** Each distinct label value creates a new time series, and that would explode Prometheus's memory use.

**Health endpoints,** on a separate management port:

| Endpoint | Checks | Used for |
|---|---|---|
| `/actuator/health/liveness` | The process only | Restart if it fails |
| `/actuator/health/readiness` | PostgreSQL only | Stop routing traffic if it fails |
| `/actuator/prometheus` | | Metrics scrape |

**A liveness check must not depend on the database,** or a database outage would restart a healthy application in a loop.

**MinIO is deliberately not in readiness.** Otherwise, a storage outage would take reads down too, against the degradation NFR. Uploads return 503 `storage_unavailable` instead, and an alert covers it.

---

