-- Part 1: a fast transaction is unaffected, and SET LOCAL does not persist. SHOW prints 0.
BEGIN;
SET LOCAL transaction_timeout = '30s';
SELECT 'fast ok';
COMMIT;
SHOW transaction_timeout;

-- Part 2: the timeout fires during a sleep and terminates the connection.
-- Expected: FATAL "terminating connection due to transaction timeout" after about 1 second,
-- psql exits with code 2, and 'still alive' is never printed.
BEGIN;
SET LOCAL transaction_timeout = '1s';
SELECT pg_sleep(3);
SELECT 'still alive' AS after_sleep;
