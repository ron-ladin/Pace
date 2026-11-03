# Database: Flyway migrations

> **Covers:** Flyway naming, rules, safe changes and the initial migration order.
> **Read when:** writing or ordering a migration.
> **Related:** [schema.md](schema.md), [amendments.md](amendments.md)

## 10. Flyway migrations

**Dependency note:** PostgreSQL support may require a separate module in Flyway 10+ (`flyway-database-postgresql`). **Verify this when adding the dependency.**

### 10.1 Naming

- Versioned files: `V0001__enable_extensions.sql`, in `db/migration`.
- **Sequential numbers:** simple for one developer. Switch to timestamps if parallel branches start colliding.

### 10.2 Rules

- **Never edit an applied migration.** Flyway checksums would fail, and environments would drift apart.
- **Forward-only.** Undo migrations are, to our knowledge, a paid feature. A bad change gets a new migration, or a backup restore.
- **Keep seed and synthetic data out of migrations.**
- **Use separate roles:** a migration role owns the schema, and the application role has no DDL rights.
- **Disable `flyway clean` outside local development.**

### 10.3 Safe changes

- **Expand, then contract:** add the new form, move the code, and remove the old form in a later migration.
- **Large tables:** use `CREATE INDEX CONCURRENTLY` in a non-transactional migration, and `ADD CONSTRAINT ... NOT VALID` followed by `VALIDATE`.
- **`lock_timeout`:** set it so a migration fails instead of blocking the app.

At our scale this is mostly practice, because a short lock is harmless with so little traffic. It's worth learning, but not worth slowing down early development.

### 10.4 Initial order

1. `V0001__enable_extensions.sql` (`btree_gist`)
2. `V0002__create_users.sql`
3. `V0003__create_social_tables.sql`
4. `V0004__create_runs.sql`
5. `V0005__create_competitions.sql` (including participants)
6. `V0006__create_invitations.sql`
7. `V0007__create_sessions.sql` (API-1, section 14.1)
8. `V0008__add_city_length_checks.sql` (API-5, section 14.5)

---

