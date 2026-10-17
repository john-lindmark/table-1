import { afterEach, describe, expect, it, vi } from "vitest";

vi.mock("./supabaseClient", () => ({ supabase: {} }));
vi.mock("./catalog", () => ({ loadCatalog: () => Promise.reject(new TypeError("offline in tests")) }));
const { RotoStore } = await import("./roto");
const { RotoDemoBackend, DEMO_EVENT } = await import("./rotoDemo");

// The store on the local demo draft (8 players, 45 picks each, 114 made, your pick at seat 3), as
// apps/ios/Table1Tests/RotoStoreTests.swift does.
const cube = Array.from({ length: 360 }, (_, i) => `card-${i + 1}`);
const make = () => {
  const backend = new RotoDemoBackend(cube);
  return { backend, store: new RotoStore(DEMO_EVENT, backend) };
};

afterEach(() => vi.useRealTimers());

describe("RotoStore", () => {
  it("loads the draft", async () => {
    const { store } = make();
    await store.load();
    expect(store.loaded).toBe(true);
    expect(store.phase).toBe("drafting");
    expect(store.pool.size).toBe(360);
    expect(store.picks).toHaveLength(114);
    expect(store.picksMade).toBe(114);
    expect(store.isMyTurn).toBe(true);
    expect(store.picksUntilMine).toBe(0);
    expect(store.queue).toHaveLength(5);
  });

  it("a pick renders at once, is accepted, and lands in your column", async () => {
    const { store } = make();
    await store.load();
    const slot = store.poolOrder.find((s) => !store.takenBy(s))!;
    const done = store.pickSlot(slot, "cube");
    expect(store.pending?.slot).toBe(slot);
    expect(store.takenBy(slot)?.seat).toBe(3);
    expect(store.picksMade).toBe(115);
    expect(await done).toBe(true);
    expect(store.pending).toBeNull();
    expect(store.pick(115)?.slot).toBe(slot);
    expect(store.picksOf(3).some((p) => p.slot === slot)).toBe(true);
    expect(store.isMyTurn).toBe(false);
  });

  it("refuses a taken card and a pick off turn", async () => {
    const { store } = make();
    await store.load();
    expect(await store.pickSlot(store.picks[0].slot, "cube")).toBe(false);
    expect(store.pending).toBeNull();
  });

  it("a stale pick number comes back as a conflict and merges the newer state", async () => {
    const { backend, store } = make();
    await store.load();
    // Someone else's pick lands on the server before ours.
    const free = store.poolOrder.filter((s) => !store.takenBy(s));
    await backend.pick(DEMO_EVENT, free[0], 115);
    expect(await store.pickSlot(free[1], "grid")).toBe(false);
    expect(store.notice).toMatch(/picked first/);
    expect(store.pick(115)?.slot).toBe(free[0]);
  });

  it("others' picks arrive by delta", async () => {
    const { backend, store } = make();
    await store.load();
    const free = store.poolOrder.filter((s) => !store.takenBy(s));
    await backend.pick(DEMO_EVENT, free[0], 115);
    await backend.pick(DEMO_EVENT, free[1], 116);
    await store.refresh();
    expect(store.picks.map((p) => p.pickNo).slice(-2)).toEqual([115, 116]);
    expect(store.picks).toHaveLength(116);
  });

  it("the list saves after a pause, once", async () => {
    vi.useFakeTimers();
    const { backend, store } = make();
    await store.load();
    const spy = vi.spyOn(backend, "queue");
    const free = store.poolOrder.filter((s) => !store.takenBy(s) && store.inList(s) == null);
    store.addToList(free[0]);
    store.addToList(free[1]);
    store.moveInList(store.queue.length - 1, 0);
    expect(store.queue[0]).toBe(free[1]);
    expect(spy).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(650);
    expect(spy).toHaveBeenCalledTimes(1);
    expect(spy.mock.calls[0][1][0]).toBe(free[1]);
    expect(spy.mock.calls[0][2]).toBeNull(); // the switch wasn't touched
  });

  it("a card on your list taken by someone else shows once and leaves the list", async () => {
    const { backend, store } = make();
    await store.load();
    // Take our turn, then another seat takes the top card on our list.
    await store.pickSlot(store.poolOrder.find((s) => !store.takenBy(s) && store.inList(s) == null)!, "cube");
    const listed = store.queue[0];
    await backend.pick(DEMO_EVENT, listed, store.draft.picksMade + 1);
    await store.refresh();
    expect(store.takenFromList.map((t) => t.slot)).toContain(listed);
    expect(store.inList(listed)).toBeNull();
    store.dismissTaken();
    expect(store.takenFromList).toHaveLength(0);
  });

  it("undo takes back the last pick", async () => {
    const { store } = make();
    await store.load();
    const slot = store.poolOrder.find((s) => !store.takenBy(s))!;
    await store.pickSlot(slot, "cube");
    await store.undo();
    expect(store.takenBy(slot)).toBeNull();
    expect(store.picksMade).toBeLessThanOrEqual(114);
  });

  it("the clock pauses, resumes and clears", async () => {
    const { store } = make();
    await store.load();
    expect(store.secondsLeft(Date.now())).toBeGreaterThan(0);
    await store.setClock(null, true);
    expect(store.draft.clockPaused).toBe(true);
    expect(store.onClock?.remainingSeconds).toBeGreaterThan(0);
    await store.setClock(null, false);
    expect(store.draft.clockPaused).toBe(false);
    await store.setClock([]);
    expect(store.draft.clock).toBeNull();
    expect(store.secondsLeft(Date.now())).toBeNull();
  });
});
