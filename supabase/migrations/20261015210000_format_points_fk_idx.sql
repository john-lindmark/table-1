-- Covering index for format_points' foreign key (oracle deletes cascade through it); flagged by the performance advisor.
create index if not exists format_points_oracle_idx on public.format_points (oracle_id);
