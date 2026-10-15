-- Table 1 Events V1: extensions. All are available on the project; none were installed before.
create extension if not exists postgis with schema extensions;
create extension if not exists pgmq;
create extension if not exists pg_cron;

select pgmq.create('notify');
