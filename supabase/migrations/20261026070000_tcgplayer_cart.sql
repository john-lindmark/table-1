-- Buy on TCGplayer (contract/tcgplayer-cart-2026-10-26.md): wants (or Missing) as a TCGplayer Mass Entry cart. The
-- server writes the whole link (TCGplayer's card names, set and number, encoding, parts, the affiliate wrapper) so
-- any of it can change without an app update. Settings in t1_private.settings (all optional):
--   tcgplayer.enabled    'true' / 'false'          the Buy on TCGplayer rows show (default true)
--   tcgplayer.massentry  the Mass Entry address the encoded lines follow
--                        (default https://www.tcgplayer.com/massentry?productline=Magic&c=)
--   tcgplayer.link       the link around it: {url} = the Mass Entry address as is, {url_encoded} = encoded, for an
--                        affiliate redirect like https://partner.tcgplayer.com/c/<id>/<ad>/<campaign>?u={url_encoded}
--                        (default {url})
--   tcgplayer.max_url    the longest Mass Entry address in one part (default 6000)

-- encodeURIComponent, byte by byte (UTF-8); also escapes !'()*, which TCGplayer reads the same.
create or replace function t1_private.url_encode(p text)
returns text language sql immutable set search_path = '' as $$
  select coalesce(string_agg(case when (y.c between 48 and 57) or (y.c between 65 and 90) or (y.c between 97 and 122)
                                       or y.c in (45, 46, 95, 126) then chr(y.c)
                                  else '%' || upper(lpad(to_hex(y.c), 2, '0')) end, '' order by y.i), '')
    from (select i, get_byte(x.b, i) c
            from (select convert_to(coalesce(p, ''), 'UTF8') b) x, generate_series(0, length(x.b) - 1) i) y;
$$;

create or replace function t1_private.tcgplayer_setting(p_name text, p_default text)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce((select s.value from t1_private.settings s where s.name = 'tcgplayer.' || p_name), p_default);
$$;

-- p_items: [{oracle_id?, card_id?, qty}], up to 2000 (a card_id alone is that printing; an oracle_id alone is any
-- printing). Returns {enabled, lines, unknown, urls}: one url per part (each adds to the same TCGplayer cart).
-- Lines: "<qty> <name>" or "<qty> <name> [<SET>] <number>" for a printing; the same line twice is summed. Names
-- are TCGplayer's: split cards whole ("Fire // Ice"), every other card with two names by its first (transform,
-- modal, adventure, flip: "Delver of Secrets", "Bonecrusher Giant").
create or replace function public.tcgplayer_cart(p_items jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_base text;
  v_link text;
  v_max integer;
  v_lines text[];
  v_unknown integer;
  v_urls text[] := '{}';
  v_part text := '';
  v_line text;
  v_url text;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if t1_private.tcgplayer_setting('enabled', 'true') <> 'true' then
    return jsonb_build_object('enabled', false, 'lines', 0, 'unknown', 0, 'urls', '[]'::jsonb);
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 2000 then
    raise exception 'p_items: an array of up to 2000 items' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_items) e
              where jsonb_typeof(e) <> 'object' or jsonb_typeof(e -> 'qty') <> 'number'
                 or (e ->> 'qty')::numeric not between 1 and 999 or (e ->> 'qty')::numeric <> floor((e ->> 'qty')::numeric)
                 or coalesce(e ->> 'oracle_id', e ->> 'card_id') is null
                 or (e ->> 'oracle_id') !~ '^[0-9a-f-]{36}$' and e ? 'oracle_id' and e -> 'oracle_id' <> 'null'::jsonb
                 or (e ->> 'card_id') !~ '^[0-9a-f-]{36}$' and e ? 'card_id' and e -> 'card_id' <> 'null'::jsonb) then
    raise exception 'p_items: each {oracle_id or card_id, qty 1-999}' using errcode = '22023';
  end if;
  v_base := t1_private.tcgplayer_setting('massentry', 'https://www.tcgplayer.com/massentry?productline=Magic&c=');
  v_link := t1_private.tcgplayer_setting('link', '{url}');
  v_max := coalesce(nullif(t1_private.tcgplayer_setting('max_url', '6000'), '')::int, 6000);

  with items as (
    select (e ->> 'oracle_id')::uuid oracle_id, (e ->> 'card_id')::uuid card_id, (e ->> 'qty')::int qty
      from jsonb_array_elements(p_items) e
  ), resolved as (
    select i.qty, o.name, o.layout, c.set_code, c.collector_number, (o.oracle_id is null) unknown
      from items i
      left join public.cards c on c.id = i.card_id
      left join public.card_oracles o on o.oracle_id = coalesce(c.oracle_id, case when i.card_id is null then i.oracle_id end)
  ), named as (
    select r.qty, (case when r.layout = 'split' then r.name else split_part(r.name, ' // ', 1) end)
                  || case when r.set_code is not null then ' [' || upper(r.set_code) || '] ' || r.collector_number else '' end key
      from resolved r where not r.unknown
  )
  select array_agg(sum_qty || ' ' || key order by key), (select count(*) from resolved where unknown)
    into v_lines, v_unknown
    from (select n.key, sum(n.qty) sum_qty from named n group by n.key) g;

  foreach v_line in array coalesce(v_lines, '{}') loop
    v_line := t1_private.url_encode(v_line);
    if v_part <> '' and length(v_base) + length(v_part) + 2 + length(v_line) > v_max then
      v_urls := v_urls || (v_base || v_part);
      v_part := '';
    end if;
    v_part := case when v_part = '' then v_line else v_part || '||' || v_line end;
  end loop;
  if v_part <> '' then v_urls := v_urls || (v_base || v_part); end if;

  return jsonb_build_object('enabled', true, 'lines', coalesce(cardinality(v_lines), 0), 'unknown', v_unknown,
    'urls', coalesce((select jsonb_agg(replace(replace(v_link, '{url_encoded}', t1_private.url_encode(u)), '{url}', u) order by n)
                        from unnest(v_urls) with ordinality t(u, n)), '[]'::jsonb));
end $$;

do $$
begin
  revoke execute on function t1_private.url_encode(text) from public;
  revoke execute on function t1_private.tcgplayer_setting(text, text) from public;
  revoke execute on function public.tcgplayer_cart(jsonb) from public, anon;
  grant execute on function public.tcgplayer_cart(jsonb) to authenticated;
end $$;
