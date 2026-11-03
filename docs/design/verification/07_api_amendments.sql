-- Amendments from the API design: database.md section 14, and the query plans the API depends on.
-- Run on the database that 03_plans.sql loaded, after amendments_from_doc.sql.
-- Plans confirm index use only. Timings here are not benchmarks.
\pset pager off
\timing off

CREATE TEMP TABLE results(name text, ok boolean);
CREATE FUNCTION pg_temp.fails_with(stmt text, want text) RETURNS boolean AS $$
BEGIN
  EXECUTE stmt;
  RETURN false;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE = want;
END $$ LANGUAGE plpgsql;

SELECT id AS me FROM users WHERE deleted_at IS NULL ORDER BY id OFFSET 100 LIMIT 1 \gset
SELECT id AS other FROM users WHERE deleted_at IS NULL ORDER BY id OFFSET 200 LIMIT 1 \gset
\set big '''00000000-0000-7000-8000-00000000000b'''

-- ---------- Constraints ----------
INSERT INTO results SELECT 'session hash must be 32 bytes',
  pg_temp.fails_with(format($q$INSERT INTO sessions(token_hash,user_id,expires_at) VALUES ('\x00',%L,now())$q$, :'me'), '23514');
INSERT INTO results SELECT 'session needs a real user',
  pg_temp.fails_with($q$INSERT INTO sessions(token_hash,user_id,expires_at) VALUES (sha256('x'),'00000000-0000-7000-8000-000000000999',now())$q$, '23503');
INSERT INTO results SELECT 'users.city over 100 refused',
  pg_temp.fails_with(format($q$UPDATE users SET city=repeat('x',101) WHERE id=%L$q$, :'me'), '23514');
INSERT INTO results SELECT 'groups.city over 100 refused',
  pg_temp.fails_with($q$INSERT INTO groups(name,visibility,city) VALUES ('g','public',repeat('x',101))$q$, '23514');
INSERT INTO results SELECT 'competitions.city over 100 refused',
  pg_temp.fails_with($q$INSERT INTO competitions(name,city,rule_type,visibility,starts_at,ends_at,closes_at) VALUES ('c',repeat('x',101),'longest_run','public',now(),now()+interval '1 day',now()+interval '1 day')$q$, '23514');
UPDATE users SET city=repeat('x',100) WHERE id=:'me';
INSERT INTO results SELECT 'users.city of 100 accepted', (SELECT char_length(city)=100 FROM users WHERE id=:'me');
UPDATE users SET city=NULL WHERE id=:'me';

-- ---------- Sessions: lookup filter, expiry, renewal, cascade ----------
INSERT INTO sessions(token_hash,user_id,expires_at)
SELECT sha256(id::text::bytea), id, now()+interval '30 days' FROM users WHERE deleted_at IS NULL;
SELECT sha256((:'me')::text::bytea) AS my_hash \gset

INSERT INTO results SELECT 'lookup finds a live session',
  (SELECT count(*)=1 FROM sessions s JOIN users u ON u.id=s.user_id AND u.deleted_at IS NULL WHERE s.token_hash=:'my_hash' AND s.expires_at>now());

UPDATE sessions SET expires_at=now()-interval '1 second' WHERE user_id=:'other';
INSERT INTO results SELECT 'lookup ignores an expired session',
  (SELECT count(*)=0 FROM sessions s JOIN users u ON u.id=s.user_id AND u.deleted_at IS NULL WHERE s.user_id=:'other' AND s.expires_at>now());

-- A session created after deletion (the login race) must not authenticate, even though its row exists.
SELECT id AS victim FROM users WHERE deleted_at IS NULL ORDER BY id OFFSET 300 LIMIT 1 \gset
DELETE FROM sessions WHERE user_id=:'victim';
UPDATE users SET deleted_at=now(), email=NULL, password_hash=NULL, display_name=NULL WHERE id=:'victim';
INSERT INTO sessions(token_hash,user_id,expires_at) VALUES (sha256('race'),:'victim',now()+interval '1 day');
INSERT INTO results SELECT 'a session racing deletion cannot authenticate',
  (SELECT count(*)=0 FROM sessions s JOIN users u ON u.id=s.user_id AND u.deleted_at IS NULL WHERE s.token_hash=sha256('race') AND s.expires_at>now());
DELETE FROM users WHERE id=:'victim';
INSERT INTO results SELECT 'purging the user cascades to sessions', (SELECT count(*)=0 FROM sessions WHERE user_id=:'victim');

-- Renewal: a fresh session isn't renewed, an hour-stale one is, and the 90-day cap holds.
UPDATE sessions SET expires_at=now()+interval '30 days' WHERE token_hash=:'my_hash';
WITH u AS (UPDATE sessions SET expires_at=LEAST(now()+interval '30 days',created_at+interval '90 days')
  WHERE token_hash=:'my_hash' AND expires_at<LEAST(now()+interval '30 days',created_at+interval '90 days')-interval '1 hour' RETURNING 1)
INSERT INTO results SELECT 'renewal skips a fresh session', (SELECT count(*)=0 FROM u);
UPDATE sessions SET expires_at=now()+interval '29 days' WHERE token_hash=:'my_hash';
WITH u AS (UPDATE sessions SET expires_at=LEAST(now()+interval '30 days',created_at+interval '90 days')
  WHERE token_hash=:'my_hash' AND expires_at<LEAST(now()+interval '30 days',created_at+interval '90 days')-interval '1 hour' RETURNING 1)
INSERT INTO results SELECT 'renewal extends a stale session', (SELECT count(*)=1 FROM u);
UPDATE sessions SET created_at=now()-interval '89 days', expires_at=now()+interval '1 hour' WHERE token_hash=:'my_hash';
UPDATE sessions SET expires_at=LEAST(now()+interval '30 days',created_at+interval '90 days') WHERE token_hash=:'my_hash';
INSERT INTO results SELECT 'renewal respects the 90-day cap',
  (SELECT expires_at <= created_at+interval '90 days' FROM sessions WHERE token_hash=:'my_hash');

-- Invitations are empty in the 03 sample, and a plan on an empty table proves nothing.
INSERT INTO group_invitations(group_id,invitee_id,invited_by)
SELECT g.id, u.id, :'me' FROM (SELECT id FROM groups LIMIT 200) g
CROSS JOIN LATERAL (SELECT id FROM users WHERE deleted_at IS NULL ORDER BY md5(g.id::text||id::text) LIMIT 25) u
ON CONFLICT DO NOTHING;
INSERT INTO competition_invitations(competition_id,invitee_id,invited_by)
SELECT c.id, u.id, :'me' FROM (SELECT id FROM competitions LIMIT 200) c
CROSS JOIN LATERAL (SELECT id FROM users WHERE deleted_at IS NULL ORDER BY md5(c.id::text||id::text) LIMIT 25) u
ON CONFLICT DO NOTHING;

VACUUM ANALYZE sessions;
VACUUM ANALYZE group_invitations;
VACUUM ANALYZE competition_invitations;

-- ---------- HOT check: renewals must not write index entries ----------
SELECT n_tup_hot_upd AS hot_before, n_tup_upd AS upd_before FROM pg_stat_user_tables WHERE relname='sessions' \gset
UPDATE sessions SET expires_at=expires_at+interval '1 second' WHERE user_id IN (SELECT id FROM users WHERE deleted_at IS NULL ORDER BY id LIMIT 50);
SELECT pg_stat_force_next_flush();
\echo ===== HOT updates out of the sampled session updates
SELECT n_tup_upd-:upd_before AS updates, n_tup_hot_upd-:hot_before AS hot FROM pg_stat_user_tables WHERE relname='sessions';

-- HOT also needs free space on the same page. The bulk-loaded pages above have none, so the first
-- round moves rows. After vacuum reclaims the old versions, the same rows have room to update in place.
VACUUM sessions;
SELECT n_tup_hot_upd AS hot_before2, n_tup_upd AS upd_before2 FROM pg_stat_user_tables WHERE relname='sessions' \gset
UPDATE sessions SET expires_at=expires_at+interval '1 second' WHERE user_id IN (SELECT id FROM users WHERE deleted_at IS NULL ORDER BY id LIMIT 50);
SELECT pg_stat_force_next_flush();
\echo ===== HOT updates, second round after vacuum
SELECT n_tup_upd-:upd_before2 AS updates, n_tup_hot_upd-:hot_before2 AS hot FROM pg_stat_user_tables WHERE relname='sessions';

-- ---------- Plans ----------
\echo ===== PLAN R1 session lookup
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT s.user_id, s.created_at, s.expires_at FROM sessions s JOIN users u ON u.id=s.user_id AND u.deleted_at IS NULL
WHERE s.token_hash=:'my_hash' AND s.expires_at>now();

\echo ===== PLAN revoke all sessions for a user
EXPLAIN (COSTS OFF) DELETE FROM sessions WHERE user_id=:'me';

\echo ===== PLAN daily session cleanup (scan expected)
EXPLAIN (COSTS OFF) DELETE FROM sessions WHERE expires_at<now();

\echo ===== PLAN W1 duplicate quick check
EXPLAIN (COSTS OFF) SELECT id FROM runs WHERE user_id=:'me' AND file_hash=sha256('x');

\echo ===== PLAN run_overlap lookup for conflictingRunId
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT id FROM runs
WHERE user_id=:'me' AND status='valid'
  AND tstzrange(started_at,ended_at,'[)') && tstzrange(now()-interval '5 days 1 minute', now()-interval '5 days'+interval '1 hour','[)')
LIMIT 1;

\echo ===== PLAN R3 other user runs, valid only
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT id, started_at, distance_m, duration_s, pace_s_per_km FROM runs
WHERE user_id=:'me' AND status='valid' AND (started_at,id) < (now()-interval '100 days','ffffffff-ffff-7fff-bfff-ffffffffffff'::uuid)
ORDER BY started_at DESC, id DESC LIMIT 20;

\echo ===== PLAN R4 stats, weekly totals in a time zone
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT date_trunc('week', started_at AT TIME ZONE 'Asia/Jerusalem') AS wk, count(*), sum(distance_m), sum(duration_s)
FROM runs WHERE user_id=:'me' AND status='valid'
  AND started_at >= now()-interval '12 weeks'
GROUP BY 1 ORDER BY 1 DESC;

\echo ===== PLAN R4 stats, personal bests, heaviest case for one user
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT max(distance_m), min(pace_s_per_km) FILTER (WHERE distance_m>=5000), min(pace_s_per_km) FILTER (WHERE distance_m>=10000)
FROM runs WHERE user_id=:'me' AND status='valid';

SELECT percentile_disc(0.5) WITHIN GROUP (ORDER BY score) AS mid FROM competition_participants WHERE competition_id=:big \gset

\echo ===== PLAN R2 deep page, keyset, descending
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT p.user_id, u.display_name, p.score FROM competition_participants p JOIN users u ON u.id=p.user_id AND u.deleted_at IS NULL
WHERE p.competition_id=:big AND p.score IS NOT NULL AND (p.score,p.user_id) < (:mid,'ffffffff-ffff-7fff-bfff-ffffffffffff'::uuid)
ORDER BY p.score DESC, p.user_id DESC LIMIT 20;

\echo ===== PLAN R2 deep page, keyset, ascending (fastest_pace)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT p.user_id, u.display_name, p.score FROM competition_participants p JOIN users u ON u.id=p.user_id AND u.deleted_at IS NULL
WHERE p.competition_id=:big AND p.score IS NOT NULL AND (p.score,p.user_id) > (:mid,'00000000-0000-7000-8000-000000000000'::uuid)
ORDER BY p.score ASC, p.user_id ASC LIMIT 20;

\echo ===== PLAN R2 rank of a deep page first row
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT count(*)+1 FROM competition_participants p WHERE p.competition_id=:big AND p.score > :mid
  AND NOT EXISTS (SELECT 1 FROM users d WHERE d.id=p.user_id AND d.deleted_at IS NOT NULL);

\echo ===== PLAN R5 participant count
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT count(*) FROM competition_participants p WHERE p.competition_id=:big
  AND NOT EXISTS (SELECT 1 FROM users d WHERE d.id=p.user_id AND d.deleted_at IS NOT NULL);

\echo ===== PLAN R5 participants, keyset on user_id
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT p.user_id, u.display_name, u.photo_key, p.score, p.joined_at FROM competition_participants p JOIN users u ON u.id=p.user_id AND u.deleted_at IS NULL
WHERE p.competition_id=:big AND p.user_id > :'me' ORDER BY p.user_id LIMIT 20;

\echo ===== PLAN R6 my competitions, keyset, active
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT c.id, c.name, p.score FROM competition_participants p JOIN competitions c ON c.id=p.competition_id
WHERE p.user_id=:'me' AND c.closed_at IS NULL AND p.competition_id < 'ffffffff-ffff-7fff-bfff-ffffffffffff'
ORDER BY p.competition_id DESC LIMIT 20;

\echo ===== PLAN R7 friends, keyset across both sides
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT other_id FROM (
  SELECT user_b AS other_id FROM friendships WHERE user_a=:'me' AND status='pending' AND requested_by<>:'me'
  UNION ALL
  SELECT user_a FROM friendships WHERE user_b=:'me' AND status='pending' AND requested_by<>:'me'
) f WHERE other_id > '00000000-0000-7000-8000-000000000000' ORDER BY other_id LIMIT 20;

\echo ===== PLAN R7 group members, keyset
EXPLAIN (COSTS OFF)
SELECT m.user_id, m.role FROM group_members m WHERE m.group_id=(SELECT id FROM groups LIMIT 1) AND m.user_id > :'me' ORDER BY m.user_id LIMIT 20;

\echo ===== PLAN R7 my groups, keyset
EXPLAIN (COSTS OFF)
SELECT group_id FROM group_members WHERE user_id=:'me' AND group_id < 'ffffffff-ffff-7fff-bfff-ffffffffffff' ORDER BY group_id DESC LIMIT 20;

\echo ===== PLAN R7 user search (sequential scan expected)
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT id, display_name, photo_key FROM users WHERE deleted_at IS NULL AND display_name ILIKE '%ser 49%' LIMIT 20;

\echo ===== PLAN R8 competition search, public, not closed (sequential scan or PK expected)
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT id, name FROM competitions WHERE visibility='public' AND closed_at IS NULL AND name ILIKE '%tion 19%' ORDER BY id DESC LIMIT 20;

\echo ===== PLAN R5/R6 a group competitions
EXPLAIN (COSTS OFF) SELECT id FROM competitions WHERE group_id=(SELECT id FROM groups LIMIT 1) ORDER BY id DESC LIMIT 20;

\echo ===== PLAN W3/W5 my invitations
EXPLAIN (COSTS OFF)
SELECT * FROM (
  SELECT 'group' AS type, group_id AS id, invited_by, created_at FROM group_invitations WHERE invitee_id=:'me'
  UNION ALL
  SELECT 'competition', competition_id, invited_by, created_at FROM competition_invitations WHERE invitee_id=:'me'
) i ORDER BY created_at DESC LIMIT 100;

\echo ===== RESULTS
SELECT name, ok FROM results;
SELECT count(*) AS total, count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE ok IS NOT TRUE) AS failed FROM results;
