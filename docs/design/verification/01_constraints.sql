\set ON_ERROR_STOP on
\pset pager off
CREATE TABLE t_results (id serial, name text, expected text, got text, constraint_name text, pass boolean);

CREATE FUNCTION t(name text, stmt text, expected text, expected_constraint text DEFAULT NULL) RETURNS void AS $$
DECLARE st text := 'OK'; cn text := NULL;
BEGIN
  BEGIN
    EXECUTE stmt;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS st = RETURNED_SQLSTATE, cn = CONSTRAINT_NAME;
  END;
  INSERT INTO t_results(name, expected, got, constraint_name, pass)
  VALUES (name, expected || COALESCE('/' || expected_constraint, ''), st, cn,
          st = expected AND (expected_constraint IS NULL OR cn = expected_constraint));
END $$ LANGUAGE plpgsql;

-- Fixed IDs, ordered so friendships can satisfy user_a < user_b.
INSERT INTO users (id, email, password_hash, display_name) VALUES
 ('00000000-0000-7000-8000-000000000001','a@x.io','h','A'),
 ('00000000-0000-7000-8000-000000000002','b@x.io','h','B'),
 ('00000000-0000-7000-8000-000000000003','c@x.io','h','C');
\set a '''00000000-0000-7000-8000-000000000001'''
\set b '''00000000-0000-7000-8000-000000000002'''
\set c '''00000000-0000-7000-8000-000000000003'''

-- uuidv7
SELECT t('uuidv7 function exists', 'SELECT uuidv7()', 'OK');
WITH g AS (INSERT INTO groups (name, visibility) VALUES ('v7','public') RETURNING id)
INSERT INTO t_results(name, expected, got, pass)
SELECT 'uuidv7 default produces version 7', '7', uuid_extract_version(id)::text, uuid_extract_version(id) = 7
FROM g;

-- users
SELECT t('users: active needs email', $q$INSERT INTO users(password_hash,display_name) VALUES('h','N')$q$, '23514', 'ck_users_active_has_identity');
SELECT t('users: active needs password', $q$INSERT INTO users(email,display_name) VALUES('n@x','N')$q$, '23514', 'ck_users_active_has_identity');
SELECT t('users: active needs name', $q$INSERT INTO users(email,password_hash) VALUES('n@x','h')$q$, '23514', 'ck_users_active_has_identity');
SELECT t('users: empty display name', $q$INSERT INTO users(email,password_hash,display_name) VALUES('n@x','h','')$q$, '23514', 'ck_users_display_name');
SELECT t('users: long display name', format($q$INSERT INTO users(email,password_hash,display_name) VALUES('n@x','h',%L)$q$, repeat('x',51)), '23514', 'ck_users_display_name');
SELECT t('users: bad privacy', $q$INSERT INTO users(email,password_hash,display_name,run_privacy) VALUES('n@x','h','N','secret')$q$, '23514', 'ck_users_run_privacy');
SELECT t('users: email unique, different case', $q$INSERT INTO users(email,password_hash,display_name) VALUES('A@X.IO','h','N')$q$, '23505', 'uq_users_email_lower');
SELECT t('users: deleted must have no identity', $q$INSERT INTO users(email,deleted_at) VALUES('z@x',now())$q$, '23514', 'ck_users_deleted_has_no_identity');
SELECT t('users: two wiped users allowed (NULL emails)', $q$INSERT INTO users(deleted_at) VALUES(now()),(now())$q$, 'OK');
DELETE FROM users WHERE deleted_at IS NOT NULL;

-- runs: helper values
CREATE FUNCTION h(i int) RETURNS bytea AS $$ SELECT sha256(i::text::bytea) $$ LANGUAGE sql IMMUTABLE;

-- generated pace
INSERT INTO runs (user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status)
VALUES (:a,'2026-01-01 08:00Z','2026-01-01 08:25Z',5000,1500,'k1',h(1),'valid');
INSERT INTO t_results(name, expected, got, pass)
SELECT 'generated pace 5000m/1500s = 300', '300', pace_s_per_km::text, pace_s_per_km = 300 FROM runs WHERE file_key='k1';
SELECT t('generated pace cannot be set', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status,pace_s_per_km)
  VALUES(%L,'2026-02-01Z','2026-02-02Z',10,10,'k',%L,'valid',1)$q$, :a::uuid, h(99)), '428C9');
INSERT INTO runs (user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status)
VALUES (:a,'2026-01-02 08:00Z','2026-01-02 08:30Z',3333,1801,'k2',h(2),'valid');
INSERT INTO t_results(name, expected, got, pass)
SELECT 'generated pace rounds 1801/3.333 = 540', '540', pace_s_per_km::text, pace_s_per_km = 540 FROM runs WHERE file_key='k2';

-- edge: implausible runs must be storable as invalid (document section 3.2)
SELECT t('EDGE: implausible 1 m in 1 day is storable as invalid', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status,invalid_reason)
  VALUES(%L,'2026-03-01Z','2026-03-02Z',1,86400,'e1',%L,'invalid','pace')$q$, :a::uuid, h(50)), 'OK');
SELECT t('EDGE: implausible 1 m in exactly 7 days is storable as invalid', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status,invalid_reason)
  VALUES(%L,'2026-03-10Z','2026-03-17Z',1,604800,'e2',%L,'invalid','pace')$q$, :a::uuid, h(51)), 'OK');
SELECT t('EDGE: 8 days hits the duration check', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status,invalid_reason)
  VALUES(%L,'2026-03-20Z','2026-03-28Z',1,691200,'e3',%L,'invalid','pace')$q$, :a::uuid, h(52)), '23514', 'ck_runs_duration');
SELECT t('EDGE: 30 days at 1 m is refused by the overflow backstop (documented)', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status,invalid_reason)
  VALUES(%L,'2026-04-01Z','2026-05-01Z',1,2592000,'e4',%L,'invalid','pace')$q$, :a::uuid, h(53)), '22003');

-- runs: checks
SELECT t('runs: distance 0', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status) VALUES(%L,'2026-02-01Z','2026-02-02Z',0,10,'k',%L,'valid')$q$, :a::uuid, h(3)), '23514', 'ck_runs_distance');
SELECT t('runs: duration 0', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status) VALUES(%L,'2026-02-01Z','2026-02-02Z',10,0,'k',%L,'valid')$q$, :a::uuid, h(3)), '23514', 'ck_runs_duration');
SELECT t('runs: end before start', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status) VALUES(%L,'2026-02-02Z','2026-02-01Z',10,10,'k',%L,'valid')$q$, :a::uuid, h(3)), '23514', 'ck_runs_time_order');
SELECT t('runs: hash not 32 bytes', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status) VALUES(%L,'2026-02-01Z','2026-02-02Z',10,10,'k','\x00','valid')$q$, :a::uuid), '23514', 'ck_runs_file_hash');
SELECT t('runs: bad status', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status) VALUES(%L,'2026-02-01Z','2026-02-02Z',10,10,'k',%L,'pending')$q$, :a::uuid, h(3)), '23514', 'ck_runs_status');
SELECT t('runs: bad source', format($q$INSERT INTO runs(user_id,source,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status) VALUES(%L,'strava','2026-02-01Z','2026-02-02Z',10,10,'k',%L,'valid')$q$, :a::uuid, h(3)), '23514', 'ck_runs_source');
SELECT t('runs: invalid without reason', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status) VALUES(%L,'2026-02-01Z','2026-02-02Z',10,10,'k',%L,'invalid')$q$, :a::uuid, h(3)), '23514', 'ck_runs_invalid_reason');
SELECT t('runs: valid with reason', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status,invalid_reason) VALUES(%L,'2026-02-01Z','2026-02-02Z',10,10,'k',%L,'valid','x')$q$, :a::uuid, h(3)), '23514', 'ck_runs_invalid_reason');
SELECT t('runs: unknown user FK', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status) VALUES(uuidv7(),'2026-02-01Z','2026-02-02Z',10,10,'k',%L,'valid')$q$, h(3)), '23503');

-- duplicate hash and overlap
SELECT t('duplicate hash same user = 23505', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status) VALUES(%L,'2026-04-01Z','2026-04-02Z',10,10,'k',%L,'valid')$q$, :a::uuid, h(1)), '23505', 'uq_runs_user_file_hash');
SELECT t('same hash different user allowed', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status) VALUES(%L,'2026-01-01 08:00Z','2026-01-01 08:25Z',5000,1500,'k',%L,'valid')$q$, :b::uuid, h(1)), 'OK');
SELECT t('overlap same user = 23P01', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status) VALUES(%L,'2026-01-01 08:10Z','2026-01-01 08:40Z',5000,1800,'k',%L,'valid')$q$, :a::uuid, h(4)), '23P01', 'ex_runs_no_overlap');
SELECT t('touching run allowed, half-open range', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status) VALUES(%L,'2026-01-01 08:25Z','2026-01-01 08:40Z',2000,900,'k',%L,'valid')$q$, :a::uuid, h(5)), 'OK');
SELECT t('invalid overlapping a valid run allowed', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status,invalid_reason) VALUES(%L,'2026-01-01 08:10Z','2026-01-01 08:20Z',9000,600,'k',%L,'invalid','pace')$q$, :a::uuid, h(6)), 'OK');
SELECT t('two invalid overlapping allowed', format($q$INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status,invalid_reason) VALUES(%L,'2026-01-01 08:10Z','2026-01-01 08:20Z',9000,600,'k',%L,'invalid','pace')$q$, :a::uuid, h(7)), 'OK');

-- competitions
SELECT t('comp: ends before starts', $q$INSERT INTO competitions(name,rule_type,visibility,starts_at,ends_at,closes_at) VALUES('x','longest_run','public','2026-02-02Z','2026-02-01Z','2026-02-03Z')$q$, '23514', 'ck_competitions_window');
SELECT t('comp: closes before ends', $q$INSERT INTO competitions(name,rule_type,visibility,starts_at,ends_at,closes_at) VALUES('x','longest_run','public','2026-02-01Z','2026-02-03Z','2026-02-02Z')$q$, '23514', 'ck_competitions_closes');
SELECT t('comp: grace 0 allowed', $q$INSERT INTO competitions(name,rule_type,visibility,starts_at,ends_at,closes_at) VALUES('x','longest_run','public','2026-02-01Z','2026-02-03Z','2026-02-03Z')$q$, 'OK');
SELECT t('comp: closed before closes_at', $q$INSERT INTO competitions(name,rule_type,visibility,starts_at,ends_at,closes_at,closed_at) VALUES('x','longest_run','public','2026-02-01Z','2026-02-03Z','2026-02-04Z','2026-02-03Z')$q$, '23514', 'ck_competitions_closed');
SELECT t('comp: bad rule', $q$INSERT INTO competitions(name,rule_type,visibility,starts_at,ends_at,closes_at) VALUES('x','streak','public','2026-02-01Z','2026-02-03Z','2026-02-03Z')$q$, '23514', 'ck_competitions_rule_type');
SELECT t('comp: bad visibility', $q$INSERT INTO competitions(name,rule_type,visibility,starts_at,ends_at,closes_at) VALUES('x','longest_run','hidden','2026-02-01Z','2026-02-03Z','2026-02-03Z')$q$, '23514', 'ck_competitions_visibility');
SELECT t('comp: pace needs min distance', $q$INSERT INTO competitions(name,rule_type,visibility,starts_at,ends_at,closes_at) VALUES('x','fastest_pace','public','2026-02-01Z','2026-02-03Z','2026-02-03Z')$q$, '23514', 'ck_competitions_rule_params');
SELECT t('comp: non-pace forbids min distance', $q$INSERT INTO competitions(name,rule_type,visibility,starts_at,ends_at,closes_at,min_distance_m) VALUES('x','longest_run','public','2026-02-01Z','2026-02-03Z','2026-02-03Z',5000)$q$, '23514', 'ck_competitions_rule_params');
SELECT t('comp: min distance 0', $q$INSERT INTO competitions(name,rule_type,visibility,starts_at,ends_at,closes_at,min_distance_m) VALUES('x','fastest_pace','public','2026-02-01Z','2026-02-03Z','2026-02-03Z',0)$q$, '23514', 'ck_competitions_min_distance');
SELECT t('comp: empty name', $q$INSERT INTO competitions(name,rule_type,visibility,starts_at,ends_at,closes_at) VALUES('','longest_run','public','2026-02-01Z','2026-02-03Z','2026-02-03Z')$q$, '23514', 'ck_competitions_name');

-- social
SELECT t('friend: order enforced', format($q$INSERT INTO friendships(user_a,user_b,requested_by,status) VALUES(%L,%L,%L,'pending')$q$, :b::uuid, :a::uuid, :a::uuid), '23514', 'ck_friendships_order');
SELECT t('friend: self not allowed', format($q$INSERT INTO friendships(user_a,user_b,requested_by,status) VALUES(%L,%L,%L,'pending')$q$, :a::uuid, :a::uuid, :a::uuid), '23514', 'ck_friendships_order');
SELECT t('friend: outsider requester', format($q$INSERT INTO friendships(user_a,user_b,requested_by,status) VALUES(%L,%L,%L,'pending')$q$, :a::uuid, :b::uuid, :c::uuid), '23514', 'ck_friendships_requester');
SELECT t('friend: bad status', format($q$INSERT INTO friendships(user_a,user_b,requested_by,status) VALUES(%L,%L,%L,'blocked')$q$, :a::uuid, :b::uuid, :a::uuid), '23514', 'ck_friendships_status');
SELECT t('friend: accepted needs time', format($q$INSERT INTO friendships(user_a,user_b,requested_by,status) VALUES(%L,%L,%L,'accepted')$q$, :a::uuid, :b::uuid, :a::uuid), '23514', 'ck_friendships_accepted');
SELECT t('friend: pending must not have time', format($q$INSERT INTO friendships(user_a,user_b,requested_by,status,accepted_at) VALUES(%L,%L,%L,'pending',now())$q$, :a::uuid, :b::uuid, :a::uuid), '23514', 'ck_friendships_accepted');
SELECT t('group: bad visibility', $q$INSERT INTO groups(name,visibility) VALUES('g','hidden')$q$, '23514', 'ck_groups_visibility');
SELECT t('group: empty name', $q$INSERT INTO groups(name,visibility) VALUES('','public')$q$, '23514', 'ck_groups_name');

-- cascades (user a owns or appears in everything; user c survives)
INSERT INTO groups(id,name,visibility,created_by) VALUES ('00000000-0000-7000-8000-0000000000a1','G','private',:a);
INSERT INTO group_members(group_id,user_id,role) VALUES ('00000000-0000-7000-8000-0000000000a1',:a,'admin'),('00000000-0000-7000-8000-0000000000a1',:c,'member');
SELECT t('member: bad role', format($q$INSERT INTO group_members(group_id,user_id,role) VALUES('00000000-0000-7000-8000-0000000000a1',%L,'owner')$q$, :b::uuid), '23514', 'ck_group_members_role');
INSERT INTO competitions(id,creator_id,group_id,name,rule_type,visibility,starts_at,ends_at,closes_at)
VALUES ('00000000-0000-7000-8000-0000000000c1',:a,'00000000-0000-7000-8000-0000000000a1','C','longest_run','private','2026-01-01Z','2026-02-01Z','2026-02-01 06:00Z');
INSERT INTO competition_participants(competition_id,user_id,score) VALUES ('00000000-0000-7000-8000-0000000000c1',:a,5000),('00000000-0000-7000-8000-0000000000c1',:c,1);
INSERT INTO friendships(user_a,user_b,requested_by,status) VALUES (:a,:c,:a,'pending');
INSERT INTO group_invitations(group_id,invitee_id,invited_by) VALUES ('00000000-0000-7000-8000-0000000000a1',:b,:a);
INSERT INTO competition_invitations(competition_id,invitee_id,invited_by) VALUES ('00000000-0000-7000-8000-0000000000c1',:b,:a);

DELETE FROM users WHERE id = :a;

INSERT INTO t_results(name, expected, got, pass)
SELECT x.n, '0', x.c::text, x.c = 0 FROM (VALUES
 ('cascade: runs', (SELECT count(*) FROM runs WHERE user_id=:a)),
 ('cascade: participants', (SELECT count(*) FROM competition_participants WHERE user_id=:a)),
 ('cascade: friendships', (SELECT count(*) FROM friendships WHERE user_a=:a OR user_b=:a)),
 ('cascade: memberships', (SELECT count(*) FROM group_members WHERE user_id=:a)),
 ('cascade: group invitations by inviter', (SELECT count(*) FROM group_invitations WHERE invited_by=:a)),
 ('cascade: competition invitations by inviter', (SELECT count(*) FROM competition_invitations WHERE invited_by=:a)),
 ('set null: competition creator', (SELECT count(*) FROM competitions WHERE creator_id=:a)),
 ('set null: group creator', (SELECT count(*) FROM groups WHERE created_by=:a))
) x(n,c);
INSERT INTO t_results(name, expected, got, pass)
SELECT 'other participant survives', '1', count(*)::text, count(*) = 1 FROM competition_participants WHERE user_id=:c;

DELETE FROM groups WHERE id='00000000-0000-7000-8000-0000000000a1';
INSERT INTO t_results(name, expected, got, pass)
SELECT 'group delete nulls competition.group_id, keeps competition', '1', count(*)::text, count(*) = 1
FROM competitions WHERE id='00000000-0000-7000-8000-0000000000c1' AND group_id IS NULL;

-- recalculation expressions and rank semantics
INSERT INTO users(id,email,password_hash,display_name) VALUES
 ('00000000-0000-7000-8000-000000000011','u1@x','h','U1'),('00000000-0000-7000-8000-000000000012','u2@x','h','U2'),
 ('00000000-0000-7000-8000-000000000013','u3@x','h','U3'),('00000000-0000-7000-8000-000000000014','u4@x','h','U4'),
 ('00000000-0000-7000-8000-000000000015','u5@x','h','U5');
\set u1 '''00000000-0000-7000-8000-000000000011'''
INSERT INTO runs(user_id,started_at,ended_at,distance_m,duration_s,file_key,file_hash,status,invalid_reason,received_at) VALUES
 (:u1,'2026-05-01 08:00Z','2026-05-01 08:30Z',4000,1800,'r1',h(101),'valid',NULL,'2026-05-01 09:00Z'),    -- too short for pace rule, 450 s/km
 (:u1,'2026-05-02 08:00Z','2026-05-02 08:30Z',6000,1800,'r2',h(102),'valid',NULL,'2026-05-02 09:00Z'),    -- 300 s/km
 (:u1,'2026-05-03 08:00Z','2026-05-03 08:40Z',5000,1500,'r3',h(103),'valid',NULL,'2026-05-03 09:00Z'),    -- 300 s/km
 (:u1,'2026-05-04 08:00Z','2026-05-04 08:01Z',50000,60,'r4',h(104),'invalid','pace','2026-05-04 09:00Z'), -- invalid: ignored
 (:u1,'2026-05-05 08:00Z','2026-05-05 08:30Z',7000,1800,'r5',h(105),'valid',NULL,'2026-06-10 09:00Z'),    -- received after closes_at: ignored
 (:u1,'2026-04-30 08:00Z','2026-04-30 08:30Z',9000,1800,'r6',h(106),'valid',NULL,'2026-05-01 09:00Z'),    -- before window: ignored
 (:u1,'2026-06-01 00:00Z','2026-06-01 00:30Z',8000,1800,'r7',h(107),'valid',NULL,'2026-06-01 01:00Z');    -- exactly ends_at: ignored
CREATE TEMP TABLE w AS SELECT :u1::uuid u, '2026-05-01Z'::timestamptz s, '2026-06-01Z'::timestamptz e, '2026-06-01 06:00Z'::timestamptz c;
INSERT INTO t_results(name, expected, got, pass)
SELECT 'recalc total_distance', '15000', v::text, v = 15000 FROM (SELECT SUM(r.distance_m) v FROM runs r, w WHERE r.user_id=w.u AND r.status='valid' AND r.started_at>=w.s AND r.started_at<w.e AND r.received_at<w.c) q;
INSERT INTO t_results(name, expected, got, pass)
SELECT 'recalc longest_run', '6000', v::text, v = 6000 FROM (SELECT MAX(r.distance_m) v FROM runs r, w WHERE r.user_id=w.u AND r.status='valid' AND r.started_at>=w.s AND r.started_at<w.e AND r.received_at<w.c) q;
INSERT INTO t_results(name, expected, got, pass)
SELECT 'recalc fastest_pace with min distance', '300', v::text, v = 300 FROM (SELECT MIN(r.pace_s_per_km) FILTER (WHERE r.distance_m >= 5000) v FROM runs r, w WHERE r.user_id=w.u AND r.status='valid' AND r.started_at>=w.s AND r.started_at<w.e AND r.received_at<w.c) q;
INSERT INTO t_results(name, expected, got, pass)
SELECT 'recalc no eligible run is NULL', 'NULL', COALESCE(v::text,'NULL'), v IS NULL FROM (SELECT MIN(r.pace_s_per_km) FILTER (WHERE r.distance_m >= 99999) v FROM runs r, w WHERE r.user_id=w.u AND r.status='valid' AND r.started_at>=w.s AND r.started_at<w.e AND r.received_at<w.c) q;

INSERT INTO competitions(id,name,rule_type,visibility,starts_at,ends_at,closes_at) VALUES ('00000000-0000-7000-8000-0000000000c2','R','total_distance','public','2026-05-01Z','2026-06-01Z','2026-06-01 06:00Z');
INSERT INTO competition_participants(competition_id,user_id,score) VALUES
 ('00000000-0000-7000-8000-0000000000c2','00000000-0000-7000-8000-000000000011',500),
 ('00000000-0000-7000-8000-0000000000c2','00000000-0000-7000-8000-000000000012',500),
 ('00000000-0000-7000-8000-0000000000c2','00000000-0000-7000-8000-000000000013',300),
 ('00000000-0000-7000-8000-0000000000c2','00000000-0000-7000-8000-000000000014',900),
 ('00000000-0000-7000-8000-0000000000c2','00000000-0000-7000-8000-000000000015',NULL);

CREATE FUNCTION top_ranks() RETURNS text AS $$
  SELECT string_agg(display_name || '=' || rank, ',' ORDER BY rank, display_name) FROM (
    SELECT p.user_id, u.display_name, p.score, RANK() OVER (ORDER BY p.score DESC) AS rank
    FROM competition_participants p JOIN users u ON u.id = p.user_id AND u.deleted_at IS NULL
    WHERE p.competition_id = '00000000-0000-7000-8000-0000000000c2' AND p.score IS NOT NULL
    ORDER BY p.score DESC, p.user_id DESC LIMIT 10) x
$$ LANGUAGE sql;
CREATE FUNCTION my_rank(s int) RETURNS bigint AS $$
  SELECT count(*) + 1 FROM competition_participants p
  WHERE p.competition_id = '00000000-0000-7000-8000-0000000000c2' AND p.score > s
    AND NOT EXISTS (SELECT 1 FROM users d WHERE d.id = p.user_id AND d.deleted_at IS NOT NULL)
$$ LANGUAGE sql;

INSERT INTO t_results(name, expected, got, pass) SELECT 'top N ties: 900=1, 500=2,2, 300=4, NULL excluded', 'U4=1,U1=2,U2=2,U3=4', top_ranks(), top_ranks() = 'U4=1,U1=2,U2=2,U3=4';
INSERT INTO t_results(name, expected, got, pass) SELECT 'my rank tied = 2', '2', my_rank(500)::text, my_rank(500) = 2;
INSERT INTO t_results(name, expected, got, pass) SELECT 'my rank last = 4', '4', my_rank(300)::text, my_rank(300) = 4;
UPDATE users SET deleted_at=now(), email=NULL, password_hash=NULL, display_name=NULL WHERE id='00000000-0000-7000-8000-000000000014';
INSERT INTO t_results(name, expected, got, pass) SELECT 'deleted leader filtered, ranks close up', 'U1=1,U2=1,U3=3', top_ranks(), top_ranks() = 'U1=1,U2=1,U3=3';
INSERT INTO t_results(name, expected, got, pass) SELECT 'my rank after deletion = 1', '1', my_rank(500)::text, my_rank(500) = 1;
INSERT INTO t_results(name, expected, got, pass) SELECT 'wiped email can re-register', 'OK', 'OK', true WHERE (SELECT count(*) FROM users WHERE lower(email)='u4@x') = 0;

SELECT name, expected, got, constraint_name, pass FROM t_results WHERE NOT pass ORDER BY id;
SELECT count(*) AS total, count(*) FILTER (WHERE pass) AS passed, count(*) FILTER (WHERE NOT pass) AS failed FROM t_results;
