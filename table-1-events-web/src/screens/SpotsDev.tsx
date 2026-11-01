import { useSearchParams } from "react-router-dom";
import { T1Logo } from "../components/kit";
import { SPOTS, shotUrl } from "../lib/spots";

/**
 * Dev server only: /dev/spots?size=appstore|play|og|feature lays every store spot out as one tile per size, in CSS
 * pixels at half the store's pixel size (tools/spots/shoot.mjs captures each `[data-spot]` at device scale 2:
 * App Store 1320×2868, Play 1080×1920, Open Graph 1200×630, Play feature graphic 1024×500). The look is the app's:
 * mono, uppercase labels, hairlines, no radius, the one accent.
 */
type Size = "appstore" | "play" | "og" | "feature";
const SIZES: Record<Size, [number, number]> = { appstore: [660, 1434], play: [540, 960], og: [600, 315], feature: [512, 250] };

export function SpotsDev() {
  const [params] = useSearchParams();
  const size = (params.get("size") ?? "appstore") as Size;
  const [w, h] = SIZES[size] ?? SIZES.appstore;
  const tiles = SPOTS.spots.filter((s) => s.store);
  return (
    <div className="min-h-[100dvh] bg-t1-ink p-5 flex flex-wrap gap-5 items-start">
      {size === "feature" ? (
        <Feature w={w} h={h} />
      ) : (
        tiles.map((s) => (
          <div key={s.key} data-spot={s.key} style={{ width: w, height: h }} className="relative overflow-hidden bg-t1-bg text-t1-text flex flex-col">
            {size === "og" ? <Wide spot={s} /> : <Tall spot={s} big={size === "appstore"} />}
          </div>
        ))
      )}
    </div>
  );
}

type SpotT = (typeof SPOTS.spots)[number];

/** Portrait: the title and headline on top, the phone shot below, framed by a hairline and bleeding off the bottom. */
function Tall({ spot, big }: { spot: SpotT; big: boolean }) {
  const pad = big ? 48 : 36;
  const src = shotUrl(spot.key);
  return (
    <>
      <div style={{ padding: `${pad}px ${pad}px ${big ? 28 : 20}px` }} className="flex flex-col gap-3">
        <p className="t1-label">{spot.title}</p>
        <h1 className={`${big ? "text-[34px] leading-[42px]" : "text-[28px] leading-[34px]"} font-bold uppercase tracking-[2px]`}>{spot.headline}</h1>
        {big && <p className="text-[15px] leading-[24px] text-t1-muted">{spot.body}</p>}
      </div>
      <div style={{ padding: `0 ${pad}px` }} className="flex-1 min-h-0 flex justify-center">
        <div className="h-full w-full border border-t1-surface border-b-0 overflow-hidden bg-t1-bg">
          {src ? <img src={src} alt="" className="w-full block" /> : <Missing />}
        </div>
      </div>
    </>
  );
}

/** Landscape (1200×630): copy on the left, the top of the shot on the right. */
function Wide({ spot }: { spot: SpotT }) {
  const src = shotUrl(spot.key);
  return (
    <div className="flex h-full">
      <div className="w-[55%] p-8 flex flex-col gap-3 justify-center">
        <T1Logo className="h-5 w-auto self-start mb-2" />
        <p className="t1-label">{spot.title}</p>
        <h1 className="text-[26px] leading-[32px] font-bold uppercase tracking-[2px]">{spot.headline}</h1>
        <p className="text-[12px] leading-[18px] text-t1-muted">{spot.body}</p>
      </div>
      <div className="flex-1 pt-8 pr-8 flex justify-center">
        <div className="w-[220px] border border-t1-surface border-b-0 overflow-hidden">
          {src ? <img src={src} alt="" className="w-full block" /> : <Missing />}
        </div>
      </div>
    </div>
  );
}

/** Play's feature graphic: the mark and the tagline, nothing else. */
function Feature({ w, h }: { w: number; h: number }) {
  return (
    <div data-spot="feature" style={{ width: w, height: h }} className="bg-t1-bg text-t1-text flex items-center gap-10 px-12">
      <T1Logo className="h-[110px] w-auto shrink-0" />
      <div className="flex flex-col gap-2">
        <p className="text-[22px] leading-[28px] font-bold uppercase tracking-[3px]">{SPOTS.product.tagline}</p>
        <p className="t1-label">{SPOTS.store.short_description}</p>
      </div>
    </div>
  );
}

const Missing = () => <div className="p-4 t1-label">No shot yet · tools/spots/run.sh</div>;
