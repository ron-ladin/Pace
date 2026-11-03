-- The timeout also covers lock waits. Start 05_hold_lock.sql in the background first.
-- Expected: FATAL "terminating connection due to transaction timeout" after about 1 second,
-- with the context "while locking tuple", and psql exits with code 2.
BEGIN;
SET LOCAL transaction_timeout = '1s';
SELECT 1 FROM competitions LIMIT 1 FOR SHARE;
