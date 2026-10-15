-- Card catalog tables are world-readable through RLS, so the read RPCs don't need SECURITY DEFINER.
-- catalog_info stays definer: it reads t1_private.catalog_packs.
alter function public.search_cards(text, integer) security invoker;
alter function public.card_printings(uuid) security invoker;
create index if not exists catalog_packs_run_idx on t1_private.catalog_packs (run_id);
