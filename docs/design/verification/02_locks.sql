-- Lock behaviour and real two-connection race flows, using dblink for the second connection.
-- Run after a fresh schema load (database pace_locks).
\pset pager off
CREATE EXTENSION dblink;
CREATE TABLE l_results (id serial, name text, expected text, got text, pass boolean);
CREATE FUNCTION rec(n text, e text, g text) RETURNS void AS $$
  INSERT INTO l_results(name,expected,got,pass) VALUES (n,e,g,e = g)
$$ LANGUAGE sql;

-- Attempt a statement on this connection; report OK or SQLSTATE. lock_timeout turns a block into 55P03.
CREATE FUNCTION try(stmt text) RETURNS text AS $$
DECLARE st text;
BEGIN
  SET LOCAL lock_timeout = '300ms';
  BEGIN
    EXECUTE stmt;
    RETURN 'OK';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS st = RETURNED_SQLSTATE;
    RETURN st;
  END;
END $$ LANGUAGE plpgsql;

INSERT INTO users(id,email,password_hash,display_name) VALUES
 ('00000000-0000-7000-8000-000000000001','a@x','h','A'),
 ('00000000-0000-7000-8000-000000000002','b@x','h','B');
INSERT INTO competitions(id,name,rule_type,visibility,starts_at,ends_at,closes_at) VALUES
 ('00000000-0000-7000-8000-0000000000c1','C','total_distance','public', now()-interval '1 day', now()+interval '1 day', now()+interval '2 days');
\set ua '''00000000-0000-7000-8000-000000000001'''
\set ub '''00000000-0000-7000-8000-000000000002'''
\set c1 '''00000000-0000-7000-8000-0000000000c1'''

SELECT dblink_connect('A', 'dbname=' || current_database() || ' user=postgres');
SELECT dblink_connect('B', 'dbname=' || current_database() || ' user=postgres');

-- ==== Lock matrix: user row ====
SELECT dblink_exec('A','BEGIN');
SELECT * FROM dblink('A', format('SELECT 1 FROM users WHERE id=%L FOR SHARE', :ua::uuid)) AS t(x text);
SELECT rec('user FOR SHARE vs another FOR SHARE: no block', 'OK', try(format('SELECT 1 FROM users WHERE id=%L FOR SHARE', :ua::uuid)));
SELECT rec('user FOR SHARE vs FOR NO KEY UPDATE: blocks', '55P03', try(format('SELECT 1 FROM users WHERE id=%L FOR NO KEY UPDATE', :ua::uuid)));
SELECT rec('user FOR SHARE vs profile/deletion UPDATE: blocks', '55P03', try(format('UPDATE users SET updated_at=now() WHERE id=%L', :ua::uuid)));
SELECT rec('user FOR SHARE vs FK check: no block', 'OK', try(format('SELECT 1 FROM users WHERE id=%L FOR KEY SHARE', :ua::uuid)));
SELECT dblink_exec('A','COMMIT');

SELECT dblink_exec('A','BEGIN');
SELECT * FROM dblink('A', format('SELECT 1 FROM users WHERE id=%L FOR NO KEY UPDATE', :ua::uuid)) AS t(x text);
SELECT rec('user FOR NO KEY UPDATE vs FK check: no block', 'OK', try(format('SELECT 1 FROM users WHERE id=%L FOR KEY SHARE', :ua::uuid)));
SELECT rec('user FOR NO KEY UPDATE vs FOR SHARE: blocks', '55P03', try(format('SELECT 1 FROM users WHERE id=%L FOR SHARE', :ua::uuid)));
SELECT dblink_exec('A','COMMIT');

-- ==== Lock matrix: competition row ====
SELECT dblink_exec('A','BEGIN');
SELECT * FROM dblink('A', format('SELECT 1 FROM competitions WHERE id=%L FOR SHARE', :c1::uuid)) AS t(x text);
SELECT rec('competition FOR SHARE vs FOR SHARE: no block', 'OK', try(format('SELECT 1 FROM competitions WHERE id=%L FOR SHARE', :c1::uuid)));
SELECT rec('competition FOR SHARE vs closure FOR UPDATE: blocks', '55P03', try(format('SELECT 1 FROM competitions WHERE id=%L FOR UPDATE', :c1::uuid)));
SELECT dblink_exec('A','COMMIT');

SELECT dblink_exec('A','BEGIN');
SELECT * FROM dblink('A', format('SELECT 1 FROM competitions WHERE id=%L FOR UPDATE', :c1::uuid)) AS t(x text);
SELECT rec('closure FOR UPDATE vs FK check: blocks', '55P03', try(format('SELECT 1 FROM competitions WHERE id=%L FOR KEY SHARE', :c1::uuid)));
SELECT dblink_exec('A','COMMIT');

-- ==== SKIP LOCKED sweeper ====
UPDATE users SET deleted_at=now(), email=NULL, password_hash=NULL, display_name=NULL WHERE id=:ub;
SELECT dblink_exec('A','BEGIN');
SELECT * FROM dblink('A', 'SELECT id FROM users WHERE deleted_at IS NOT NULL LIMIT 1 FOR UPDATE SKIP LOCKED') AS t(x text);
SELECT rec('sweeper: second instance skips locked row', '0',
  (SELECT count(*)::text FROM (SELECT id FROM users WHERE deleted_at IS NOT NULL LIMIT 1 FOR UPDATE SKIP LOCKED) s));
SELECT dblink_exec('A','ROLLBACK');
DELETE FROM users WHERE id=:ub;
INSERT INTO users(id,email,password_hash,display_name) VALUES (:ub,'b@x','h','B');

-- ==== Race: two concurrent overlapping uploads. B must block, then fail 23P01 ====
SELECT dblink_exec('A','BEGIN');
SELECT dblink_exec('A', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status)
  VALUES(%L,now()-interval '2 hours',now()-interval '1 hour',5000,3600,'o1',sha256('o1'),'valid')$q$, :ua::uuid));
SELECT dblink_send_query('B', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status)
  VALUES(%L,now()-interval '90 minutes',now()-interval '30 minutes',5000,3600,'o2',sha256('o2'),'valid') RETURNING 1$q$, :ua::uuid));
SELECT pg_sleep(0.5);
SELECT rec('overlap: second insert waits for first commit', '1', dblink_is_busy('B')::text);
SELECT dblink_exec('A','COMMIT');
SELECT pg_sleep(0.3);
SELECT * FROM dblink_get_result('B', false) AS t(x int);
SELECT rec('overlap: second insert fails after first commits', 'exclusion',
  CASE WHEN dblink_error_message('B') LIKE '%ex_runs_no_overlap%' THEN 'exclusion' ELSE dblink_error_message('B') END);
SELECT * FROM dblink_get_result('B', false) AS t(x int);
SELECT rec('overlap: exactly one run stored', '1', (SELECT count(*)::text FROM runs WHERE file_key IN ('o1','o2')));
DELETE FROM runs;

-- ==== Race: duplicate hash, same behaviour ====
SELECT dblink_exec('A','BEGIN');
SELECT dblink_exec('A', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status)
  VALUES(%L,now()-interval '2 hours',now()-interval '1 hour',5000,3600,'d1',sha256('same'),'valid')$q$, :ua::uuid));
SELECT dblink_send_query('B', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status)
  VALUES(%L,now()-interval '20 hours',now()-interval '19 hours',5000,3600,'d2',sha256('same'),'valid') RETURNING 1$q$, :ua::uuid));
SELECT pg_sleep(0.5);
SELECT rec('duplicate: second insert waits for first commit', '1', dblink_is_busy('B')::text);
SELECT dblink_exec('A','COMMIT');
SELECT pg_sleep(0.3);
SELECT * FROM dblink_get_result('B', false) AS t(x int);
SELECT rec('duplicate: second insert fails after first commits', 'unique',
  CASE WHEN dblink_error_message('B') LIKE '%uq_runs_user_file_hash%' THEN 'unique' ELSE dblink_error_message('B') END);
SELECT * FROM dblink_get_result('B', false) AS t(x int);
DELETE FROM runs;

-- ==== Race: lost update. Two non-overlapping uploads scoring the same participant ====
INSERT INTO competition_participants(competition_id,user_id) VALUES (:c1,:ua);
CREATE FUNCTION recalc(cid uuid, uid uuid) RETURNS void AS $$
  UPDATE competition_participants SET score = n.v, score_updated_at = now()
  FROM (SELECT SUM(r.distance_m)::integer v FROM runs r JOIN competitions c ON c.id = cid
        WHERE r.user_id = uid AND r.status='valid' AND r.started_at >= c.starts_at AND r.started_at < c.ends_at AND r.received_at < c.closes_at) n
  WHERE competition_id = cid AND user_id = uid AND score IS DISTINCT FROM n.v
$$ LANGUAGE sql;
SELECT dblink_exec('A','BEGIN');
SELECT dblink_exec('B','BEGIN');
SELECT dblink_exec('A', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status)
  VALUES(%L,now()-interval '5 hours',now()-interval '4 hours',1000,3600,'l1',sha256('l1'),'valid')$q$, :ua::uuid));
SELECT dblink_exec('B', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status)
  VALUES(%L,now()-interval '3 hours',now()-interval '2 hours',2000,3600,'l2',sha256('l2'),'valid')$q$, :ua::uuid));
SELECT * FROM dblink('A', format('SELECT 1 FROM competition_participants WHERE competition_id=%L AND user_id=%L FOR UPDATE', :c1::uuid, :ua::uuid)) AS t(x text);
SELECT dblink_send_query('B', format('SELECT 1 FROM competition_participants WHERE competition_id=%L AND user_id=%L FOR UPDATE', :c1::uuid, :ua::uuid));
SELECT pg_sleep(0.5);
SELECT rec('lost update: B waits on the participant lock', '1', dblink_is_busy('B')::text);
SELECT * FROM dblink('A', format('SELECT recalc(%L,%L)', :c1::uuid, :ua::uuid)) AS t(x text);
SELECT dblink_exec('A','COMMIT');
SELECT pg_sleep(0.3);
SELECT * FROM dblink_get_result('B') AS t(x int);
SELECT * FROM dblink_get_result('B') AS t(x int);
SELECT * FROM dblink('B', format('SELECT recalc(%L,%L)', :c1::uuid, :ua::uuid)) AS t(x text);
SELECT dblink_exec('B','COMMIT');
SELECT rec('lost update: final score includes both runs', '3000',
  (SELECT score::text FROM competition_participants WHERE competition_id=:c1 AND user_id=:ua));
DELETE FROM competition_participants; DELETE FROM runs;

-- ==== Race: join versus ingest. The per-user lock must make the later one see the earlier ====
SELECT dblink_exec('A','BEGIN');
SELECT * FROM dblink('A', format('SELECT 1 FROM users WHERE id=%L AND deleted_at IS NULL FOR SHARE', :ua::uuid)) AS t(x text);
SELECT dblink_exec('A', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status)
  VALUES(%L,now()-interval '5 hours',now()-interval '4 hours',1000,3600,'j1',sha256('j1'),'valid')$q$, :ua::uuid));
SELECT dblink_exec('B','BEGIN');
SELECT dblink_send_query('B', format('SELECT 1 FROM users WHERE id=%L AND deleted_at IS NULL FOR NO KEY UPDATE', :ua::uuid));
SELECT pg_sleep(0.5);
SELECT rec('join waits for in-flight ingest of same user', '1', dblink_is_busy('B')::text);
SELECT dblink_exec('A','COMMIT');
SELECT pg_sleep(0.3);
SELECT * FROM dblink_get_result('B') AS t(x int);
SELECT * FROM dblink_get_result('B') AS t(x int);
SELECT dblink_exec('B', format('INSERT INTO competition_participants(competition_id,user_id) VALUES(%L,%L) ON CONFLICT DO NOTHING', :c1::uuid, :ua::uuid));
SELECT * FROM dblink('B', format('SELECT recalc(%L,%L)', :c1::uuid, :ua::uuid)) AS t(x text);
SELECT dblink_exec('B','COMMIT');
SELECT rec('join backfill counts the run committed while it waited', '1000',
  (SELECT score::text FROM competition_participants WHERE competition_id=:c1 AND user_id=:ua));
DELETE FROM competition_participants; DELETE FROM runs;

-- Reverse order: join holds the lock, ingest waits, then must find the new participant.
SELECT dblink_exec('A','BEGIN');
SELECT * FROM dblink('A', format('SELECT 1 FROM users WHERE id=%L FOR NO KEY UPDATE', :ua::uuid)) AS t(x text);
SELECT dblink_exec('A', format('INSERT INTO competition_participants(competition_id,user_id) VALUES(%L,%L)', :c1::uuid, :ua::uuid));
SELECT dblink_exec('B','BEGIN');
SELECT dblink_send_query('B', format('SELECT 1 FROM users WHERE id=%L AND deleted_at IS NULL FOR SHARE', :ua::uuid));
SELECT pg_sleep(0.5);
SELECT rec('ingest waits for in-flight join of same user', '1', dblink_is_busy('B')::text);
SELECT dblink_exec('A','COMMIT');
SELECT pg_sleep(0.3);
SELECT * FROM dblink_get_result('B') AS t(x int);
SELECT * FROM dblink_get_result('B') AS t(x int);
SELECT rec('ingest then sees the new participant in its lookup', '1',
  (SELECT n::text FROM dblink('B', format('SELECT count(*) FROM competition_participants WHERE user_id=%L', :ua::uuid)) AS t(n bigint)));
SELECT dblink_exec('B','ROLLBACK');
DELETE FROM competition_participants;

-- ==== Race: closure waits for an ingest holding FOR SHARE ====
UPDATE competitions SET starts_at=now()-interval '3 days', ends_at=now()-interval '2 days', closes_at=now()-interval '1 day' WHERE id=:c1;
SELECT dblink_exec('A','BEGIN');
SELECT * FROM dblink('A', format('SELECT 1 FROM competitions WHERE id=%L FOR SHARE', :c1::uuid)) AS t(x text);
SELECT dblink_exec('B','BEGIN');
SELECT dblink_send_query('B', format('SELECT 1 FROM competitions WHERE id=%L FOR UPDATE', :c1::uuid));
SELECT pg_sleep(0.5);
SELECT rec('closure FOR UPDATE waits for the scoring transaction', '1', dblink_is_busy('B')::text);
SELECT dblink_exec('A','COMMIT');
SELECT pg_sleep(0.3);
SELECT * FROM dblink_get_result('B') AS t(x int);
SELECT * FROM dblink_get_result('B') AS t(x int);
SELECT dblink_exec('B', format('UPDATE competitions SET closed_at=now() WHERE id=%L AND closed_at IS NULL', :c1::uuid));
-- A scorer now waiting on the competition must, after the lock, see closed_at set.
SELECT dblink_send_query('A', format('SELECT closed_at IS NOT NULL FROM competitions WHERE id=%L FOR SHARE', :c1::uuid));
SELECT pg_sleep(0.5);
SELECT rec('scorer waits for an in-flight closure', '1', dblink_is_busy('A')::text);
SELECT dblink_exec('B','COMMIT');
SELECT pg_sleep(0.3);
SELECT rec('scorer sees closed_at after waiting, so it skips', 'true',
  (SELECT x::text FROM dblink_get_result('A') AS t(x boolean)));
SELECT * FROM dblink_get_result('A') AS t(x boolean);

-- Second closer does nothing.
SELECT rec('second closer: zero rows updated', 'UPDATE 0',
  dblink_exec('A', format('UPDATE competitions SET closed_at=now() WHERE id=%L AND closed_at IS NULL', :c1::uuid)));

-- ==== Race: account deletion versus ingest ====
-- Deletion waits for an in-flight ingest.
SELECT dblink_exec('A','BEGIN');
SELECT * FROM dblink('A', format('SELECT 1 FROM users WHERE id=%L AND deleted_at IS NULL FOR SHARE', :ua::uuid)) AS t(x text);
SELECT dblink_send_query('B', format('UPDATE users SET deleted_at=now(), email=NULL, password_hash=NULL, display_name=NULL WHERE id=%L RETURNING 1', :ua::uuid));
SELECT pg_sleep(0.5);
SELECT rec('deletion waits for in-flight ingest', '1', dblink_is_busy('B')::text);
SELECT dblink_exec('A','COMMIT');
SELECT pg_sleep(0.3);
SELECT * FROM dblink_get_result('B') AS t(x int);
SELECT * FROM dblink_get_result('B') AS t(x int);
-- Restore, then the reverse: an ingest waiting on a deletion must find no active user.
UPDATE users SET deleted_at=NULL, email='a@x', password_hash='h', display_name='A' WHERE id=:ua;
SELECT dblink_exec('A','BEGIN');
SELECT dblink_exec('A', format('UPDATE users SET deleted_at=now(), email=NULL, password_hash=NULL, display_name=NULL WHERE id=%L', :ua::uuid));
SELECT dblink_send_query('B', format('SELECT 1 FROM users WHERE id=%L AND deleted_at IS NULL FOR SHARE', :ua::uuid));
SELECT pg_sleep(0.5);
SELECT rec('ingest waits for in-flight deletion', '1', dblink_is_busy('B')::text);
SELECT dblink_exec('A','COMMIT');
SELECT pg_sleep(0.3);
SELECT rec('ingest then finds no active user, so it refuses', '0',
  (SELECT count(*)::text FROM dblink_get_result('B') AS t(x int)));
SELECT * FROM dblink_get_result('B') AS t(x int);

SELECT dblink_disconnect('A'); SELECT dblink_disconnect('B');

SELECT name, expected, got, pass FROM l_results ORDER BY id;
SELECT count(*) AS total, count(*) FILTER (WHERE pass) AS passed, count(*) FILTER (WHERE NOT pass) AS failed FROM l_results;
