-- Meta builds one at a time (bug #18): t1-meta-build posted every format's build at once and the edge runtime
-- refused to boot most of the burst (503 BOOT_ERROR), so those formats' packs missed the cycle. meta_build() now
-- queues; meta_build_next() keeps one build in flight and retries a failed one up to three times.
\ir _helpers.sql

delete from net.requests;
delete from t1_private.meta_build_queue;
select t1_private.meta_build();
select pg_temp.eq('meta_build queues every enabled format and sends nothing',
  (select count(*) from t1_private.meta_build_queue) || '/' || (select count(*) from net.requests),
  (select count(*) from t1_private.meta_formats where enabled) || '/0');

select t1_private.meta_build_next();
select t1_private.meta_build_next();
select pg_temp.eq('one build in flight at a time, the first format first',
  (select string_agg(body->>'format', ',') from net.requests where url like '%/meta-sync'),
  (select format from t1_private.meta_formats where enabled order by ord limit 1));

-- The first build answers 200: it leaves the queue and the next format goes.
select id as first_req from net.requests order by id desc limit 1 \gset
insert into net._http_response (id, status_code, timed_out) values (:first_req, 200, false);
select t1_private.meta_build_next();
select pg_temp.eq('a built format leaves the queue and the next one is sent',
  (select count(*) from t1_private.meta_build_queue where format = (select body->>'format' from net.requests where id = :first_req))
    || '/' || (select body->>'format' from net.requests order by id desc limit 1),
  '0/' || (select format from t1_private.meta_formats where enabled order by ord offset 1 limit 1));

-- The second build fails to boot: it goes back with one try used, and the third format goes before it.
select id as second_req, body->>'format' as second_format from net.requests order by id desc limit 1 \gset
insert into net._http_response (id, status_code, timed_out, content)
values (:second_req, 503, false, '{"code":"BOOT_ERROR"}');
select t1_private.meta_build_next();
select pg_temp.eq('a failed build is queued again behind formats not yet tried',
  (select request_id is null and tries = 1 from t1_private.meta_build_queue where format = :'second_format')::text
    || '/' || (select body->>'format' <> :'second_format' from net.requests order by id desc limit 1)::text,
  'true/true');

-- A build with no answer after 5 minutes counts as failed.
update t1_private.meta_build_queue set asked_at = now() - interval '6 minutes' where request_id is not null;
select t1_private.meta_build_next();
select pg_temp.eq('a build with no answer for 5 minutes is retried later, one still in flight',
  (select count(*) from t1_private.meta_build_queue where request_id is not null)::text, '1');

-- Three failed tries: the format waits for the next queue.
delete from t1_private.meta_build_queue;
insert into t1_private.meta_build_queue (format, tries) values ('modern', 2);
delete from net.requests;
select t1_private.meta_build_next();
select id as third_req from net.requests order by id desc limit 1 \gset
insert into net._http_response (id, status_code, timed_out) values (:third_req, 503, false);
select t1_private.meta_build_next();
select pg_temp.eq('three failed tries take the format off the queue',
  (select count(*) from t1_private.meta_build_queue) || '/' || (select count(*) from net.requests), '0/1');

-- meta_build by hand while one is in flight keeps that one's place.
insert into t1_private.meta_build_queue (format, request_id, asked_at, tries) values ('modern', 999999, now(), 1);
select t1_private.meta_build();
select pg_temp.eq('queueing again keeps a build in flight',
  (select request_id || ':' || tries from t1_private.meta_build_queue where format = 'modern'), '999999:1');

delete from t1_private.meta_build_queue;
delete from net.requests;
delete from net._http_response;
