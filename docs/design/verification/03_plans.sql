-- Synthetic sample at about the target size, to check plan shapes only. Timings here are not benchmarks.
\pset pager off
\timing off
INSERT INTO users(id,email,password_hash,display_name)
SELECT uuidv7(), 'u'||i||'@x', 'h', 'User '||i FROM generate_series(1,5000) i;
UPDATE users SET deleted_at=now(), email=NULL, password_hash=NULL, display_name=NULL
WHERE id IN (SELECT id FROM users ORDER BY id LIMIT 3);

-- 63 runs per user on separate days, about 315,000 rows, all non-overlapping.
INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status)
SELECT u.id, t, t + (d*0.3||' seconds')::interval, d, (d*0.3)::int, 'k', sha256((u.id::text||n)::bytea), 'valid'
FROM (SELECT id FROM users WHERE deleted_at IS NULL) u
CROSS JOIN LATERAL generate_series(1,63) n
CROSS JOIN LATERAL (SELECT now() - (n*5||' days')::interval AS t, 2000 + (random()*18000)::int AS d) x;

INSERT INTO competitions(id,name,rule_type,min_distance_m,visibility,starts_at,ends_at,closes_at,closed_at)
SELECT CASE WHEN i=1 THEN '00000000-0000-7000-8000-00000000000b'::uuid ELSE uuidv7() END,
       'Competition '||i,
       (ARRAY['total_distance','longest_run','fastest_pace'])[1 + i%3],
       CASE WHEN i%3=2 THEN 5000 END, 'public',
       now()-interval '30 days', now()+interval '10 days', now()+interval '10 days 6 hours', NULL
FROM generate_series(1,2000) i;
UPDATE competitions SET starts_at=now()-interval '90 days', ends_at=now()-interval '60 days', closes_at=now()-interval '59 days', closed_at=now()-interval '59 days'
WHERE id IN (SELECT id FROM competitions WHERE id <> '00000000-0000-7000-8000-00000000000b' ORDER BY id LIMIT 1800);

-- One competition with everyone, plus 45,000 small-competition rows.
INSERT INTO competition_participants(competition_id,user_id,score)
SELECT '00000000-0000-7000-8000-00000000000b', id, (random()*200000)::int FROM users;
INSERT INTO competition_participants(competition_id,user_id,score)
SELECT c.id, u.id, (random()*200000)::int
FROM (SELECT id, row_number() OVER (ORDER BY id) r FROM competitions WHERE id <> '00000000-0000-7000-8000-00000000000b') c
CROSS JOIN LATERAL (SELECT id FROM users ORDER BY md5(c.id::text || id::text) LIMIT 22) u;

INSERT INTO groups(name,visibility,city) SELECT 'Group '||i,'public','City '||(i%50) FROM generate_series(1,2000) i;
INSERT INTO group_members(group_id,user_id,role) SELECT g.id,u.id,'member' FROM (SELECT id FROM groups LIMIT 500) g CROSS JOIN LATERAL (SELECT id FROM users ORDER BY md5(g.id::text||id::text) LIMIT 10) u;
INSERT INTO friendships(user_a,user_b,requested_by,status)
SELECT LEAST(a.id,b.id),GREATEST(a.id,b.id),LEAST(a.id,b.id),'pending'
FROM (SELECT id,row_number() OVER (ORDER BY id) r FROM users) a JOIN (SELECT id,row_number() OVER (ORDER BY id) r FROM users) b ON b.r = a.r % 5000 + 1
ON CONFLICT DO NOTHING;
VACUUM ANALYZE;

SELECT 'users' t, count(*) FROM users UNION ALL SELECT 'runs', count(*) FROM runs UNION ALL SELECT 'competitions', count(*) FROM competitions UNION ALL SELECT 'participants', count(*) FROM competition_participants;

\set big '''00000000-0000-7000-8000-00000000000b'''
SELECT id AS me FROM users WHERE deleted_at IS NULL ORDER BY id OFFSET 100 LIMIT 1 \gset
SELECT min(score) AS lowest, percentile_disc(0.5) WITHIN GROUP (ORDER BY score) AS mid FROM competition_participants WHERE competition_id=:big \gset

\echo ===== PLAN R2 top N, DESC
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT p.user_id, u.display_name, p.score, RANK() OVER (ORDER BY p.score DESC) AS rank
FROM competition_participants p JOIN users u ON u.id = p.user_id AND u.deleted_at IS NULL
WHERE p.competition_id = :big AND p.score IS NOT NULL
ORDER BY p.score DESC, p.user_id DESC LIMIT 10;

\echo ===== PLAN R2 top N, ASC (fastest_pace)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT p.user_id, u.display_name, p.score, RANK() OVER (ORDER BY p.score ASC) AS rank
FROM competition_participants p JOIN users u ON u.id = p.user_id AND u.deleted_at IS NULL
WHERE p.competition_id = :big AND p.score IS NOT NULL
ORDER BY p.score ASC, p.user_id ASC LIMIT 10;

\echo ===== PLAN R2 my rank, last place
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT count(*) + 1 AS rank FROM competition_participants p
WHERE p.competition_id = :big AND p.score > :lowest
  AND NOT EXISTS (SELECT 1 FROM users d WHERE d.id = p.user_id AND d.deleted_at IS NOT NULL);

\echo ===== PLAN R2 my score by PK
EXPLAIN (COSTS OFF) SELECT score FROM competition_participants WHERE competition_id=:big AND user_id=:'me';

\echo ===== PLAN R3 keyset history
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT id, started_at, distance_m, duration_s, pace_s_per_km, status FROM runs
WHERE user_id = :'me' AND (started_at, id) < (now() - interval '100 days', 'ffffffff-ffff-7fff-bfff-ffffffffffff'::uuid)
ORDER BY started_at DESC, id DESC LIMIT 20;

\echo ===== PLAN W1 competition lookup
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT c.id FROM competition_participants p JOIN competitions c ON c.id = p.competition_id
WHERE p.user_id = :'me' AND c.closed_at IS NULL AND now()-interval '1 day' >= c.starts_at AND now()-interval '1 day' < c.ends_at AND now() < c.closes_at
ORDER BY c.id;

\echo ===== PLAN W1/W3 recalculation
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT SUM(r.distance_m) FROM runs r
WHERE r.user_id = :'me' AND r.status = 'valid' AND r.started_at >= now()-interval '30 days' AND r.started_at < now()+interval '10 days' AND r.received_at < now()+interval '10 days';

\echo ===== PLAN W4 closure candidates
EXPLAIN (COSTS OFF) SELECT id FROM competitions WHERE closed_at IS NULL AND closes_at <= now() - interval '60 seconds';

\echo ===== PLAN W6 sweeper
EXPLAIN (COSTS OFF) SELECT id FROM users WHERE deleted_at IS NOT NULL LIMIT 1 FOR UPDATE SKIP LOCKED;

\echo ===== PLAN R6 my competitions
EXPLAIN (COSTS OFF) SELECT c.id,c.name,c.closed_at FROM competition_participants p JOIN competitions c ON c.id=p.competition_id WHERE p.user_id=:'me';

\echo ===== PLAN R7 friends
EXPLAIN (COSTS OFF) SELECT user_b FROM friendships WHERE user_a=:'me' UNION ALL SELECT user_a FROM friendships WHERE user_b=:'me';

\echo ===== PLAN R7 my groups
EXPLAIN (COSTS OFF) SELECT group_id FROM group_members WHERE user_id=:'me';

\echo ===== PLAN R8 search (sequential scan expected)
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) SELECT id,name FROM groups WHERE visibility='public' AND name ILIKE '%oup 19%' LIMIT 20;
