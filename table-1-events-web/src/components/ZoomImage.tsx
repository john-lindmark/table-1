import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { capture } from "../lib/telemetry";
import { STEP_ZOOM, fitView, previewHint, fitted, pan, toggle, zoomTo, type Size, type View } from "../lib/zoom";
import { Bar } from "./kit";

/** The preview of a made picture (deck image, top 100): a click opens it full screen to zoom. The picture is a plain
    image, not inside a button, so a long press on a phone or a right-click gets the browser's own image menu (copy,
    save, share; contract/deck-image-2026-10-20.md § Long press). */
export function ZoomablePreview({ src, alt, title, subtitle, screen }: { src: string; alt: string; title: string; subtitle?: string; screen: string }) {
  const [open, setOpen] = useState(false);
  const zoom = () => { setOpen(true); capture("image_zoomed", { screen }); };
  return (
    <>
      <div className="block w-full">
        <img src={src} alt={alt} onClick={zoom} onContextMenu={() => capture("image_menu", { screen })}
             className="w-full h-auto block cursor-zoom-in" style={{ WebkitTouchCallout: "default" }} />
        <button type="button" onClick={zoom} aria-label={`${alt}. Open to zoom`}
                className="block w-full text-left t1-label bg-t1-surface px-4 py-2 mt-px">{previewHint()}</button>
      </div>
      {open && <ZoomImage src={src} alt={alt} title={title} subtitle={subtitle} screen={screen} onClose={() => setOpen(false)} />}
    </>
  );
}

/** Full screen: wheel or pinch zooms around the pointer, drag pans, double-click toggles 3×, + − 0 on a keyboard,
    Esc closes this view only. */
export function ZoomImage({ src, alt, title, subtitle, screen, onClose }: { src: string; alt: string; title: string; subtitle?: string; screen?: string; onClose: () => void }) {
  const boxRef = useRef<HTMLDivElement>(null);
  const [box, setBox] = useState<Size>({ w: 0, h: 0 });
  const [img, setImg] = useState<Size>({ w: 0, h: 0 });
  const [view, setView] = useState<View>({ s: 1, x: 0, y: 0 });
  const pointers = useRef(new Map<number, { x: number; y: number }>());
  const pinch = useRef<{ d: number; s: number } | null>(null);
  const fit = fitted(box, img);

  useLayoutEffect(() => {
    const el = boxRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setBox({ w: el.clientWidth, h: el.clientHeight }));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  // A new box or picture starts fitted.
  useEffect(() => { setView(fitView(box, fit)); }, [box.w, box.h, img.w, img.h]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const c = { x: box.w / 2, y: box.h / 2 };
      if (e.key === "Escape") onClose();
      else if (e.key === "+" || e.key === "=") setView((v) => zoomTo(v, v.s * 1.5, c.x, c.y, box, fit));
      else if (e.key === "-") setView((v) => zoomTo(v, v.s / 1.5, c.x, c.y, box, fit));
      else if (e.key === "0") setView(fitView(box, fit));
      else return;
      // The image screen under this one closes on Esc too: only this view should.
      e.preventDefault();
      e.stopImmediatePropagation();
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [box.w, box.h, fit.w, fit.h, onClose]);

  // Wheel (and trackpad pinch, which arrives as ctrl+wheel) zooms; React's wheel listener is passive, so attach here.
  useEffect(() => {
    const el = boxRef.current;
    if (!el) return;
    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      const r = el.getBoundingClientRect();
      const k = Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.002));
      setView((v) => zoomTo(v, v.s * k, e.clientX - r.left, e.clientY - r.top, box, fit));
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
  }, [box.w, box.h, fit.w, fit.h]);

  const local = (e: { clientX: number; clientY: number }) => {
    const r = boxRef.current!.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  };
  const spread = () => {
    const [a, b] = [...pointers.current.values()];
    return { d: Math.hypot(a.x - b.x, a.y - b.y), cx: (a.x + b.x) / 2, cy: (a.y + b.y) / 2 };
  };
  const down = (e: React.PointerEvent) => {
    e.currentTarget.setPointerCapture(e.pointerId);
    pointers.current.set(e.pointerId, local(e));
    if (pointers.current.size === 2) pinch.current = { d: spread().d, s: view.s };
  };
  const move = (e: React.PointerEvent) => {
    const before = pointers.current.get(e.pointerId);
    if (!before) return;
    const p = local(e);
    pointers.current.set(e.pointerId, p);
    if (pointers.current.size >= 2 && pinch.current) {
      const s = spread();
      const start = pinch.current;
      if (start.d > 0) setView((v) => zoomTo(v, start.s * (s.d / start.d), s.cx, s.cy, box, fit));
    } else if (pointers.current.size === 1) {
      setView((v) => pan(v, p.x - before.x, p.y - before.y, box, fit));
    }
  };
  const up = (e: React.PointerEvent) => {
    pointers.current.delete(e.pointerId);
    if (pointers.current.size < 2) pinch.current = null;
  };

  const zoomed = view.s > 1.01;
  return (
    <div className="fixed inset-0 z-[60] bg-t1-bg text-t1-text flex flex-col gap-px" role="dialog" aria-modal="true" aria-label={`${title}, zoom`}>
      <Bar title={title} subtitle={subtitle} onBack={onClose} right={
        <div className="flex gap-4">
          <button type="button" className="t1-label text-t1-text hover:text-t1-accent" aria-label="Zoom out"
                  onClick={() => setView((v) => zoomTo(v, v.s / 1.5, box.w / 2, box.h / 2, box, fit))}>−</button>
          <button type="button" className="t1-label text-t1-text hover:text-t1-accent" aria-label="Zoom in"
                  onClick={() => setView((v) => zoomTo(v, v.s * 1.5, box.w / 2, box.h / 2, box, fit))}>+</button>
        </div>
      } />
      <div ref={boxRef} className={`relative flex-1 min-h-0 overflow-hidden select-none touch-none ${zoomed ? "cursor-grab active:cursor-grabbing" : "cursor-zoom-in"}`}
           onPointerDown={down} onPointerMove={move} onPointerUp={up} onPointerCancel={up}
           onDoubleClick={(e) => { const p = local(e); setView((v) => toggle(v, p.x, p.y, box, fit)); }}>
        <img src={src} alt={alt} draggable={false} style={{ WebkitTouchCallout: "default", width: fit.w || undefined, height: fit.h || undefined, transform: `translate(${view.x}px, ${view.y}px) scale(${view.s})` }}
             onContextMenu={() => screen && capture("image_menu", { screen: `${screen}_zoom` })}
             onLoad={(e) => setImg({ w: e.currentTarget.naturalWidth, h: e.currentTarget.naturalHeight })}
             className="absolute top-0 left-0 max-w-none origin-top-left" />
      </div>
      <p className="shrink-0 t1-label bg-t1-surface px-4 py-2">
        {zoomed ? `${Math.round(view.s * 100)}% · drag to look around · double-click to fit` : `Scroll, pinch or double-click to zoom (${STEP_ZOOM}×)`}
      </p>
    </div>
  );
}
