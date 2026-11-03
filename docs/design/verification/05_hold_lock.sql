-- Background helper for 06_timeout_lock_wait.sql: holds a row lock on a competition for 5 seconds.
-- Needs the competition row that 02_locks.sql leaves in the pace_locks database.
BEGIN;
SELECT 1 FROM competitions LIMIT 1 FOR UPDATE;
SELECT pg_sleep(5);
COMMIT;
