// The Buy screen (contract/buy-2026-11-06.md): a deck, a cube, Wants or Missing as a TCGplayer cart, Moxfield's way:
// the options, the cards to buy by board, price − owned = total, then Buy on TCGplayer. Same screen as iOS and Android.
import { useEffect, useMemo, useState } from "react";
import { Bar, Menu, Notice, Row, Section, SwitchRow } from "../components/kit";
import { errorMessage } from "../lib/api";
import { basicCardIds, coverPrinting, oracleIndexById, tokenIndexes } from "../lib/catalog";
import { liveWants, missingLines, useBinders } from "../lib/binders";
import { BOARD_ORDER, buyCalls, buyMoney, buyRows, buyTotals, cents, mergeAnswers, storeBuy, storedBuy, storedBuyOptions, type BuyLine, type BuyOptions, type BuyRow } from "../lib/buyList";
import { boardTitle, entriesOf, finishOf, type Board } from "../lib/lists";
import { cardOfCatalog, holdings } from "../lib/ownedByCard";
import { usdPrice, usePrices } from "../lib/prices";
import { capture } from "../lib/telemetry";
import { cartDirect, cartMenu, loadWantPrices, tcgplayerCart, useWantPrices, wantPrice, type CartEntry } from "../lib/wantPrices";
import { CardRow, LibScreen, SignedOut, useCatalog, useLibrarySession } from "./Library";
import { useListsData } from "./Lists";

export type BuySource = "wants" | "missing" | { list: string };

export function BuyScreen({ source, onBack, onCard }: { source: BuySource; onBack: () => void; onCard: (oracleId: string) => void }) {
  const { session, ready, userId } = useLibrarySession();
  const { lists, owned } = useListsData();
  const b = useBinders(userId);
  const { catalog, error: catalogError } = useCatalog();
  const list = typeof source === "object" ? lists.lists.find((l) => l.id === source.list) ?? null : null;
  const family = typeof source === "object" ? (list?.kind === "cube" ? "cube" : "deck") : source;
  const ownsOptions = typeof source === "object";
  const isDeck = list?.kind === "deck";
  const [options, setOptions] = useState<BuyOptions>(() => storedBuyOptions(family));
  const [tokens, setTokens] = useState(() => storedBuy(family, "tokens") ?? false);
  const [busy, setBusy] = useState(false);
  const [fail, setFail] = useState<string | null>(null);
  const [menu, setMenu] = useState<CartEntry[] | null>(null);
  const [boardsOpen, setBoardsOpen] = useState(false);
  useEffect(() => {
    setOptions(storedBuyOptions(family));
    setTokens(storedBuy(family, "tokens") ?? false);
    capture("buy_opened", { from: family });
  }, [family]);
  const held = useMemo(() => holdings(owned, cardOfCatalog(catalog)), [owned, catalog]);
  const wants = useMemo(() => liveWants(), [b.version]);

  // The lines on offer, without prices (filled from the price book below).
  const base = useMemo((): BuyLine[] => {
    if (!catalog) return [];
    if (typeof source === "object") {
      if (!list || list.eventId) return [];
      const basics = basicCardIds(catalog);
      const order = (bd: string) => { const i = BOARD_ORDER.indexOf(bd); return i < 0 ? 9 : i; };
      const entries = entriesOf(list).map((e, i) => ({ e, i })).sort((x, y) => order(x.e.board) - order(y.e.board) || x.i - y.i).map((x) => x.e);
      const out: BuyLine[] = entries.map((e) => ({ cardId: e.cardId, board: e.board, finish: finishOf(e), qty: e.qty, basic: basics.has(e.cardId) }));
      if (list.kind === "deck") {
        // The tokens the main deck, commander and sideboard make, one each, in their catalog printing.
        const seen: number[] = [];
        for (const e of entries) {
          if (e.board === "maybe") continue;
          const p = catalog.printingIndex.get(e.cardId);
          if (p == null) continue;
          for (const t of tokenIndexes(catalog, catalog.pOracle[p])) if (!seen.includes(t)) seen.push(t);
        }
        for (const t of seen) out.push({ cardId: catalog.pId[coverPrinting(catalog, t)], board: "tokens", finish: "nonfoil", qty: 1 });
      }
      return out;
    }
    if (source === "wants") {
      return wants.flatMap((w): BuyLine[] => {
        if (w.cardId) return [{ cardId: w.cardId, oracleId: w.oracleId, board: "main", finish: w.finish ?? "nonfoil", qty: w.qty }];
        const oi = oracleIndexById(catalog, w.oracleId);
        const drawn = wantPrice(w)?.now_card_id ?? (oi < 0 ? null : catalog.pId[coverPrinting(catalog, oi)]);
        return drawn ? [{ cardId: drawn, oracleId: w.oracleId, any: true, board: "main", finish: w.finish ?? "nonfoil", qty: w.qty }] : [];
      });
    }
    return missingLines(lists.lists, owned, basicCardIds(catalog), cardOfCatalog(catalog))
      .map((m) => ({ cardId: m.cardId, board: "main", finish: m.finish, qty: m.short }));
  }, [catalog, source, list, wants, lists.lists, owned]);
  const wp = useWantPrices();
  const priceVersion = usePrices(useMemo(() => [...new Set(base.map((l) => l.cardId))], [base]));
  useEffect(() => {
    if (session && source === "wants") void loadWantPrices(wants);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session, source, b.version]);
  const lines = useMemo(() => base.map((l) => {
    const w = l.any ? wants.find((x) => x.oracleId === l.oracleId && x.cardId == null) : undefined;
    return { ...l, unit: cents((w && wantPrice(w)?.now) ?? usdPrice(l.cardId, l.finish as "nonfoil")) };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }), [base, priceVersion, wants, wp.version]);

  if (!ready) return <LibScreen><div className="flex-1" /></LibScreen>;
  if (!session) return <SignedOut title="Buy" />;

  const effective: BuyOptions = { ...options, boards: new Set(options.boards) };
  if (!ownsOptions) { effective.skipOwned = false; effective.boards = new Set(["main"]); }
  if (tokens && isDeck) effective.boards.add("tokens"); else effective.boards.delete("tokens");
  const rows = buyRows(lines, held, effective);
  const t = buyTotals(rows);
  const boards = BOARD_ORDER.filter((bd) => bd !== "tokens" && lines.some((l) => l.board === bd));
  const title = (bd: string) => source === "wants" ? "Wants" : source === "missing" ? "Missing"
    : bd === "tokens" ? "Tokens" : list ? boardTitle(list.kind, bd as Board, list.format) : bd;

  const setOption = (o: "skipOwned" | "anyPrinting" | "exact", name: string, v: boolean) => {
    setOptions((x) => ({ ...x, [o]: v }));
    storeBuy(family, name, v ? "1" : "0");
    capture("buy_option", { from: family, option: name, on: v });
  };
  const toggleBoard = (bd: string) => {
    const next = new Set(options.boards);
    const on = !next.has(bd);
    if (on) next.add(bd); else next.delete(bd);
    setOptions((x) => ({ ...x, boards: next }));
    storeBuy(family, "boards", [...next].sort().join(","));
    capture("buy_option", { from: family, option: `board_${bd}`, on });
  };

  const buy = async () => {
    const calls = buyCalls(rows, effective.exact);
    if (!calls.length) return;
    setBusy(true);
    setFail(null);
    try {
      const answers = [];
      for (const c of calls) answers.push(await tcgplayerCart(c.items, family, c.products));
      const a = mergeAnswers(answers);
      capture("tcgplayer_cart_opened", { from: family, lines: a.lines, parts: a.urls.length, products: a.products?.length ?? 0,
                                         skip: effective.skipOwned, any: effective.anyPrinting, exact: effective.exact, tokens: effective.boards.has("tokens") });
      const direct = cartDirect(a);
      const m = cartMenu(a);
      if (direct) window.open(direct, "_blank", "noopener");
      else if (!m.length) setFail("Nothing to buy");
      else setMenu(m);
    } catch (e) {
      setFail(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  const row = (r: BuyRow, i: number) => {
    const p = catalog?.printingIndex.get(r.line.cardId) ?? null;
    const oi = p == null || !catalog ? -1 : catalog.pOracle[p];
    const detail = r.line.any ? "Any printing"
      : [p != null && catalog ? `${catalog.pSet[p].toUpperCase()} #${catalog.pCn[p]}` : null, r.line.finish === "nonfoil" ? null : r.line.finish[0].toUpperCase() + r.line.finish.slice(1)]
        .filter(Boolean).join(" · ");
    return (
      <div key={`${r.line.board}|${r.line.cardId}|${r.line.finish}|${i}`} style={{ height: 60 }}>
        <CardRow c={catalog!} p={p} title={oi >= 0 ? catalog!.oName[oi] : "Card not in local data yet"} detail={detail || undefined}
                 finish={r.line.finish as "nonfoil"} note={r.owned > 0 ? `Own ${r.owned} of ${r.line.qty}` : undefined} value={r.buy}
                 onClick={() => oi >= 0 && onCard(catalog!.oId[oi])} />
      </div>
    );
  };

  return (
    <LibScreen>
      <Bar title="Buy" subtitle={list?.name} onBack={onBack} />
      {(catalogError || fail) && <Notice tone="error">{catalogError ?? fail}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {!catalog ? <Row title="Loading the cards…" /> : <>
          <div className="shrink-0 bg-t1-surface px-4 py-5 flex flex-col gap-1.5">
            <span className="text-[34px] leading-[40px] font-semibold tabular-nums text-t1-accent">{buyMoney(t.total)}</span>
            <span className="t1-label">
              {[`${t.cards} cards`, ownsOptions && effective.skipOwned ? `${t.owned} owned` : null, `${t.buy} to buy`, t.unpriced ? `${t.unpriced} unpriced` : null]
                .filter(Boolean).join(" · ")}
            </span>
          </div>
          {ownsOptions && <SwitchRow label="Skip cards I own" on={options.skipOwned} onChange={(v) => setOption("skipOwned", "skip", v)} />}
          {ownsOptions && options.skipOwned &&
            <SwitchRow label="Any printing I own counts" on={options.anyPrinting} onChange={(v) => setOption("anyPrinting", "any", v)} />}
          <SwitchRow label="Exact printings" on={options.exact} onChange={(v) => setOption("exact", "exact", v)} />
          {isDeck && <SwitchRow label="Tokens" on={tokens} onChange={(v) => {
            setTokens(v);
            storeBuy(family, "tokens", v ? "1" : "0");
            capture("buy_option", { from: family, option: "tokens", on: v });
          }} />}
          {ownsOptions && boards.length > 1 &&
            <Row title="Boards" detail={boards.filter((bd) => options.boards.has(bd)).map(title).join(" · ") || "None"} onClick={() => setBoardsOpen(true)} />}
          {BOARD_ORDER.map((bd) => {
            const inBoard = rows.filter((r) => r.line.board === bd);
            if (!inBoard.length) return null;
            const own = inBoard.reduce((n, r) => n + r.owned, 0);
            const buying = inBoard.filter((r) => r.buy > 0);
            return (
              <div key={bd} className="contents">
                <Section title={[title(bd), `${buying.reduce((n, r) => n + r.buy, 0)} to buy`, own ? `${own} owned` : null].filter(Boolean).join(" · ")} />
                {buying.map(row)}
              </div>
            );
          })}
          <Section title="Total" />
          <Row title="Price" value={buyMoney(t.price)} />
          {t.ownedValue > 0 && <Row title="Owned" value={`−${buyMoney(t.ownedValue)}`} />}
          <Row title="Total" value={buyMoney(t.total)} accentValue />
        </>}
      </div>
      <button type="button" onClick={() => void buy()} disabled={busy || t.buy === 0}
              className={`shrink-0 h-[88px] lg:h-[64px] pt-6 lg:pt-0 flex lg:items-center justify-center text-[15px] font-semibold uppercase tracking-[4px] pb-[env(safe-area-inset-bottom)] ${
                busy || t.buy === 0 ? "bg-t1-disabled text-t1-muted" : "bg-t1-surface hover:bg-t1-surface-hover"}`}>
        {busy ? "Opening TCGplayer…" : "Buy on TCGplayer"}
      </button>
      {boardsOpen && (
        <Menu title="Boards" onClose={() => setBoardsOpen(false)}
              items={boards.map((bd) => ({ title: title(bd), detail: options.boards.has(bd) ? "On" : "Off", onClick: () => toggleBoard(bd) }))} />
      )}
      {menu && (
        <Menu title="Buy on TCGplayer" onClose={() => setMenu(null)}
              items={menu.map((e) => ({ title: e.title, detail: e.detail, onClick: () => { window.open(e.url, "_blank", "noopener"); } }))} />
      )}
    </LibScreen>
  );
}
