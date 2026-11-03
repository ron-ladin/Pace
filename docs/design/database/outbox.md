# Database: Deferred Outbox milestone

> **Covers:** The deferred async-scoring design: the Outbox pattern, the relay, and what changes when the milestone is built.
> **Read when:** baseline measurements justify async scoring, or when choosing a queue. Not needed for Phase 1 work.
> **Related:** [transactions.md](transactions.md), [validation.md](validation.md)

## 9. Milestone: async scoring via Outbox + queue (deferred)

**Status:** designed, not part of the initial schema.

**Trigger:** introduce this only after baseline load-test measurements exist, and measure before and after. D9 (queue technology) remains OPEN. This design works with any choice.

**Why deferred:** synchronous scoring is simpler and more strongly consistent, and it gives a baseline. Async processing should show its benefit against that baseline, not by intuition. It remains valuable as a learning goal.

### 9.1 Outbox pattern

The **Outbox pattern** writes an event in the same transaction as the data, and a separate relay publishes it later. A commit can't succeed while its event is lost.

```sql
CREATE TABLE outbox_events (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_type    text NOT NULL,
    event_version smallint NOT NULL DEFAULT 1,
    aggregate_id  uuid NOT NULL,
    payload       jsonb NOT NULL,
    request_id    text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    published_at  timestamptz
);
CREATE INDEX ix_outbox_unpublished ON outbox_events (id) WHERE published_at IS NULL;
```

- **`bigint` is an exception to D24:** these IDs are never exposed, and a smaller key suits a high-churn table.
- **`request_id`:** carries the observability requirement across the async step.
- **The payload holds IDs only:** personal data must not outlive account deletion.
- **Index cost:** small, but it churns constantly. Watch for bloat (dead space left by updates and deletes).

### 9.2 Relay

Poll each second:
```sql
SELECT ... FROM outbox_events
WHERE published_at IS NULL
ORDER BY id LIMIT 100
FOR UPDATE SKIP LOCKED;
-- publish, then UPDATE published_at, then COMMIT
```

- **Delivery:** at least once. A crash between publishing and marking causes a repeat, and recalculation makes repeats harmless.
- **Ordering:** approximate, since IDs can commit out of order. Scoring doesn't depend on order.
- **Retention:** a daily job deletes published rows older than 7 days. Partitioning isn't justified.

**Rejected:**

| Alternative | Why |
|---|---|
| Debezium, which reads the database's change log | Powerful, but too much to operate at this scale |
| `LISTEN/NOTIFY` alone | Missed notifications are lost. It can be added later as a wake-up signal |

### 9.3 Changes when this milestone is built

**Schema, in a new migration:**
- Add `outbox_events`.
- Add `runs.scored_at timestamptz`, setting it for all existing valid runs in the same migration, since they are already scored.
- Add `CREATE INDEX ix_runs_unscored ON runs (received_at) WHERE status = 'valid' AND scored_at IS NULL`.

**Ingest:** the run and a `RunAccepted` event commit together. The run still exists at commit, so the response can stay 201, although its scores update shortly afterward. Freshness is then held to the 30-second target.

**Worker, one transaction per message:**
1. Load the run, and acknowledge the message if the run no longer exists.
2. Run the same scoring steps as section 6.3 (step 4 onward).
3. Set `scored_at` and commit. A crash rolls back, and the message is delivered again.

**Closure must recalculate, never abort.** Under its `FOR UPDATE` lock, closure recalculates scores for participants who have unscored eligible runs, and only then sets `closed_at`. **A stuck message can therefore never block closure forever.** A late duplicate message finds the competition closed and skips it.

**The per-user lock stays:** the join race in section 6.4 still exists with a worker.

**Alert:** on the age of the oldest unscored run.

**Then measure again.** Compare upload latency, freshness and failure behavior against the baseline, and record the result as an ADR.

---

