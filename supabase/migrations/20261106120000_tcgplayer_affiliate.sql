-- TCGplayer affiliate link (contract/tcgplayer-cart-2026-10-26.md § Affiliate link). John's Impact tracking link
-- wraps every cart and product link, tagged with where the click came from:
--   {platform}  ios / android / web / unknown, from the Supabase library's x-client-info header (no app update)
--   {from}      wants / missing / card / deck / … sent by apps as p_from (from the builds after 2026-11-06), else unknown
-- Impact's redirect refuses a link over ~8,200 characters (checked 2026-11-06: 8,218 redirected exactly, 8,272 → 400),
-- so parts are now also cut by the finished link's length, tcgplayer.max_link (default 8000), as well as the Mass
-- Entry address's own tcgplayer.max_url (6000).

create or replace function t1_private.client_platform()
returns text language sql stable set search_path = '' as $$
  select case
    when h like 'supabase-swift/%' then 'ios'
    when h like 'supabase-kt/%' then 'android'
    when h like 'supabase-js%' then 'web'
    else 'unknown' end
    from (select coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-client-info', '') h) x;
$$;

drop function if exists public.tcgplayer_cart(jsonb, boolean);
create function public.tcgplayer_cart(p_items jsonb, p_products boolean default false, p_from text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_base text;
  v_product text;
  v_link text;
  v_max integer;
  v_max_link integer;
  v_enc boolean;
  v_fixed integer;
  v_base_enc integer;
  v_raw integer := 0;
  v_part_enc integer := 0;
  v_line_raw integer;
  v_line_enc integer;
  v_lines text[];
  v_unknown integer;
  v_products jsonb;
  v_urls text[] := '{}';
  v_part text := '';
  v_line text;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if t1_private.tcgplayer_setting('enabled', 'true') <> 'true' then
    return jsonb_build_object('enabled', false, 'lines', 0, 'unknown', 0, 'urls', '[]'::jsonb, 'products', '[]'::jsonb);
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
  v_product := t1_private.tcgplayer_setting('product', 'https://www.tcgplayer.com/product/');
  v_link := replace(replace(t1_private.tcgplayer_setting('link', '{url}'),
                            '{platform}', t1_private.client_platform()),
                    '{from}', case when p_from ~ '^[a-z][a-z0-9-]{0,23}$' then p_from else 'unknown' end);
  v_max := coalesce(nullif(t1_private.tcgplayer_setting('max_url', '6000'), '')::int, 6000);
  v_max_link := coalesce(nullif(t1_private.tcgplayer_setting('max_link', '8000'), '')::int, 8000);
  v_enc := position('{url_encoded}' in v_link) > 0;
  v_fixed := length(v_link) - case when v_enc then length('{url_encoded}') when position('{url}' in v_link) > 0 then length('{url}') else 0 end;
  v_base_enc := length(t1_private.url_encode(v_base));

  with items as (
    select (e ->> 'oracle_id')::uuid oracle_id, (e ->> 'card_id')::uuid card_id, (e ->> 'qty')::int qty
      from jsonb_array_elements(p_items) e
  ), r as (
    select i.qty, c.id card_id, case when o.layout = 'split' then o.name else split_part(o.name, ' // ', 1) end name,
           c.set_code, c.collector_number, case when p_products then coalesce(t.product_id, t.etched_product_id) end product_id,
           o.oracle_id is null unknown
      from items i
      left join public.cards c on c.id = i.card_id
      left join public.card_oracles o on o.oracle_id = coalesce(c.oracle_id, case when i.card_id is null then i.oracle_id end)
      left join t1_private.card_tcgplayer t on t.card_id = c.id
  )
  select (select array_agg(g.qty || ' ' || g.name order by g.name)
            from (select r.name, sum(r.qty) qty from r where not r.unknown and r.product_id is null group by r.name) g),
         (select count(*) from r where r.unknown),
         (select coalesce(jsonb_agg(jsonb_build_object('card_id', g.card_id, 'name', g.name, 'set', upper(g.set_code),
                                                       'number', g.collector_number, 'qty', g.qty,
                                                       'url', replace(replace(v_link, '{url_encoded}', t1_private.url_encode(v_product || g.product_id)),
                                                                      '{url}', v_product || g.product_id))
                                    order by g.name, g.set_code, g.collector_number), '[]'::jsonb)
            from (select r.card_id, r.name, r.set_code, r.collector_number, r.product_id, sum(r.qty) qty
                    from r where r.product_id is not null
                   group by r.card_id, r.name, r.set_code, r.collector_number, r.product_id) g)
    into v_lines, v_unknown, v_products;

  -- A line is ASCII once encoded ('%XX' and unreserved characters), so encoding it again for the wrapper only turns
  -- each '%' into '%25'; '||' becomes '%7C%7C'. Lengths add up, so no part is encoded twice to measure it.
  foreach v_line in array coalesce(v_lines, '{}') loop
    v_line := t1_private.url_encode(v_line);
    v_line_raw := length(v_line);
    v_line_enc := v_line_raw + 2 * (v_line_raw - length(replace(v_line, '%', '')));
    if v_part <> '' and (length(v_base) + v_raw + 2 + v_line_raw > v_max
                         or v_fixed + case when v_enc then v_base_enc + v_part_enc + 6 + v_line_enc
                                           else length(v_base) + v_raw + 2 + v_line_raw end > v_max_link) then
      v_urls := v_urls || (v_base || v_part);
      v_part := '';
      v_raw := 0;
      v_part_enc := 0;
    end if;
    if v_part = '' then
      v_part := v_line; v_raw := v_line_raw; v_part_enc := v_line_enc;
    else
      v_part := v_part || '||' || v_line; v_raw := v_raw + 2 + v_line_raw; v_part_enc := v_part_enc + 6 + v_line_enc;
    end if;
  end loop;
  if v_part <> '' then v_urls := v_urls || (v_base || v_part); end if;

  return jsonb_build_object('enabled', true, 'lines', coalesce(cardinality(v_lines), 0), 'unknown', v_unknown,
    'urls', coalesce((select jsonb_agg(replace(replace(v_link, '{url_encoded}', t1_private.url_encode(u)), '{url}', u) order by n)
                        from unnest(v_urls) with ordinality t(u, n)), '[]'::jsonb),
    'products', v_products);
end $$;

-- John's TCGplayer tracking link from Impact (partner 8048898, ad 1780961, campaign 21018, property 9068666),
-- checked in a browser 2026-11-06: it lands on the exact Mass Entry address with Impact's click id.
insert into t1_private.settings (name, value)
values ('tcgplayer.link', 'https://partner.tcgplayer.com/c/8048898/1780961/21018?subId1={platform}&subId2={from}&partnerpropertyid=9068666&u={url_encoded}')
on conflict (name) do update set value = excluded.value;

do $$
begin
  revoke execute on function t1_private.client_platform() from public, anon, authenticated;
  revoke execute on function public.tcgplayer_cart(jsonb, boolean, text) from public, anon;
  grant execute on function public.tcgplayer_cart(jsonb, boolean, text) to authenticated;
end $$;
