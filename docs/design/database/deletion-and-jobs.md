# Database: Account deletion and scheduled jobs

> **Covers:** Two-phase account deletion (6.6) and the scheduled jobs: competition closure, account purge and orphan-file cleanup (8). The introduction to section 6 is in `transactions.md`.
> **Read when:** working on account deletion, the sweeper, closure or file cleanup.
> **Related:** [transactions.md](transactions.md), [amendments.md](amendments.md), [../classes/flows-identity-social.md](../classes/flows-identity-social.md)

### 6.6 Account deletion (W6, D17, D29)

> **Amended by API-4 (section 14.4):** this transaction also deletes the user's sessions.
>
> **Amended by CLS-2 and CLS-7 (section 14.8):** groups are locked in ascending ID order, and an invitation from a deleted inviter is hidden until the purge removes it.

**Phase 1: one quick transaction.**
1. Update the user row: set `deleted_at`, and set the email, password hash, name, birth date, city and photo key to `NULL`. This takes a write lock, so it waits for that user's in-flight ingests.
2. Delete friendships, group memberships and invitations.
3. For each group where the user was the last admin, promote the longest-standing member, or delete the group if it's empty. Lock the group row while doing this.

The email becomes free immediately, and this step can't be undone. The user vanishes from leaderboards at once, through the read-time filter. The authentication design must also reject the user's sessions.

**Phase 2: the sweeper (section 8.2)** deletes files and then the user row, which cascades to runs, scores and remaining references.

**Why a sweeper rather than an event:** the user row is already a durable to-do item, and this keeps a privacy requirement independent of any queue.

| Race | What happens |
|---|---|
| Upload in progress during deletion | The upload holds `FOR SHARE`, so deletion waits. The run then gets purged normally |
| Upload starts just after deletion | Its user lock finds `deleted_at` set, and the upload is refused |
| Join during deletion | Same protection, using the user lock |
| A file stored after the purge | The orphan job removes it, because no matching run exists |
| Failure halfway through the purge | The user row survives as a retry marker, because files are deleted first and the deletions can be repeated |

**Consequences to accept:**
- Ranks in closed competitions can shift, as D17 already accepts.
- Scores are physically removed, unlike the original D17.
- **Data remains in backups until they expire.** Keep backups for a documented period, proposed at 30 days. Restoring one would require running the sweeper again for users deleted after that backup was taken.

---

## 8. Scheduled jobs

Jobs run **inside the application process** for now, so there is no need for a separate worker until the queue milestone. They must stay safe with several application instances.

### 8.1 Competition closure

Runs each minute, as described in section 6.5.

### 8.2 Account purge

Runs each minute, and loops up to a configured batch per tick (CLS-3). API-4 (section 14.4) widens the photo deletion to a prefix:
```sql
SELECT id FROM users WHERE deleted_at IS NOT NULL
LIMIT 1 FOR UPDATE SKIP LOCKED;
```
`SKIP LOCKED` makes instances skip rows another instance is already working on. Then, in order: delete objects under `runs/{user_id}/` and the profile photo, then `DELETE FROM users WHERE id = $1`, then commit.

### 8.3 Orphan-file cleanup

Runs daily. For each object older than 1 day, read the user and hash from its key, then look up `(user_id, file_hash)`. If there's no row, or the row's `file_key` differs, delete the object.

**This job takes no lock.** It works on objects rather than rows, and deleting an object twice is harmless. Age and the per-attempt key keep in-flight uploads safe (section 6.3).

---

