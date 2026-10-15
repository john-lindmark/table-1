import { useCallback, useEffect, useRef, useState } from "react";
import { Trophy, Clock, TrendingUp, Layers, Zap, RefreshCw } from "lucide-react";
import { api, type AIInsight } from "../lib/api";

const RATE_KEY = "insights_remix_ts";

function getRecentRemixes(): number[] {
  try {
    const raw = sessionStorage.getItem(RATE_KEY);
    const all: number[] = raw ? JSON.parse(raw) : [];
    return all.filter((t) => Date.now() - t < 60_000);
  } catch {
    return [];
  }
}

function recordRemix() {
  const recent = getRecentRemixes();
  recent.push(Date.now());
  try {
    sessionStorage.setItem(RATE_KEY, JSON.stringify(recent));
  } catch {}
}

const MONO = "var(--font-sf-mono)";

const TYPE_CONFIG: Record<
  AIInsight["type"],
  { label: string; Icon: React.ElementType; color: string }
> = {
  player: { label: "Player", Icon: Trophy, color: "#00ffd9" },
  format: { label: "Format", Icon: Layers, color: "#a78bfa" },
  timing: { label: "Timing", Icon: Clock, color: "#f59e0b" },
  trend: { label: "Trend", Icon: TrendingUp, color: "#60a5fa" },
  standout: { label: "Standout", Icon: Zap, color: "#f43f5e" },
};

function SkeletonCard() {
  return (
    <div className="shrink-0 w-[252px] h-[148px] bg-[#f5f5f6] dark:bg-[#282839] flex flex-col gap-[10px] p-[16px]">
      <div className="flex items-center gap-[8px]">
        <div className="size-[10px] rounded-full bg-[#e0e0e6] dark:bg-[#33334a] animate-pulse" />
        <div className="h-[8px] w-[44px] bg-[#e0e0e6] dark:bg-[#33334a] animate-pulse" />
      </div>
      <div className="flex flex-col gap-[6px]">
        <div className="h-[13px] w-full bg-[#e0e0e6] dark:bg-[#33334a] animate-pulse" />
        <div className="h-[13px] w-[75%] bg-[#e0e0e6] dark:bg-[#33334a] animate-pulse" />
      </div>
      <div className="flex flex-col gap-[4px] mt-[2px]">
        <div className="h-[11px] w-full bg-[#e8e8ed] dark:bg-[#2a2a3a] animate-pulse" />
        <div className="h-[11px] w-[85%] bg-[#e8e8ed] dark:bg-[#2a2a3a] animate-pulse" />
        <div className="h-[11px] w-[60%] bg-[#e8e8ed] dark:bg-[#2a2a3a] animate-pulse" />
      </div>
    </div>
  );
}

function InsightCard({ insight }: { insight: AIInsight }) {
  const cfg = TYPE_CONFIG[insight.type] ?? TYPE_CONFIG.standout;
  const { Icon } = cfg;
  return (
    <div
      className="shrink-0 w-[252px] bg-[#f5f5f6] dark:bg-[#282839] flex flex-col gap-[10px] p-[16px]"
      style={{ fontFamily: MONO }}
    >
      <div className="flex items-center gap-[7px]">
        <Icon size={11} style={{ color: cfg.color }} aria-hidden />
        <span className="text-[10px] uppercase tracking-[1px] text-[#545461] dark:text-[#c4c4ca]">
          {cfg.label}
        </span>
      </div>
      <p className="text-[13px] text-[#171725] dark:text-white leading-[18px]">
        {insight.headline}
      </p>
      <p className="text-[11px] text-[#545461] dark:text-[#c4c4ca] leading-[16px]">
        {insight.body}
      </p>
    </div>
  );
}

interface AIInsightsShelfProps {
  eventId: string;
  /** Max regenerations per minute for shared/public pages. Undefined = unlimited. */
  regenerateRateLimit?: number;
  /** Custom fetch function for public pages (no auth). */
  fetchInsights?: (id: string, force?: boolean) => Promise<{ insights: AIInsight[]; generatedAt: string }>;
}

export function AIInsightsShelf({
  eventId,
  regenerateRateLimit,
  fetchInsights,
}: AIInsightsShelfProps) {
  const [insights, setInsights] = useState<AIInsight[] | null>(null);
  const [generatedAt, setGeneratedAt] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [rateLimited, setRateLimited] = useState(false);
  const [remixesLeft, setRemixesLeft] = useState<number | null>(null);
  const rateLimitTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const doFetch = useCallback(
    (force: boolean) => (fetchInsights ? fetchInsights(eventId, force) : api.getInsights(eventId, force)),
    [eventId, fetchInsights],
  );

  const load = useCallback(
    async (force = false) => {
      // Client-side rate limiting for shared pages.
      if (force && regenerateRateLimit != null) {
        const recent = getRecentRemixes();
        if (recent.length >= regenerateRateLimit) {
          setRateLimited(true);
          // Clear after the oldest entry expires.
          const oldest = Math.min(...recent);
          const cooldownMs = 60_000 - (Date.now() - oldest);
          if (rateLimitTimer.current) clearTimeout(rateLimitTimer.current);
          rateLimitTimer.current = setTimeout(() => {
            setRateLimited(false);
            setRemixesLeft(regenerateRateLimit);
          }, cooldownMs);
          return;
        }
        recordRemix();
        setRemixesLeft(regenerateRateLimit - getRecentRemixes().length);
      }

      setLoading(true);
      setError(null);
      try {
        const data = await doFetch(force);
        setInsights(data.insights);
        setGeneratedAt(data.generatedAt);
      } catch (e) {
        setError(e instanceof Error ? e.message : "Failed to load insights.");
      } finally {
        setLoading(false);
      }
    },
    [doFetch, regenerateRateLimit],
  );

  useEffect(() => {
    load(false);
    // Init remixesLeft counter for public pages.
    if (regenerateRateLimit != null) {
      setRemixesLeft(regenerateRateLimit - getRecentRemixes().length);
    }
    return () => {
      if (rateLimitTimer.current) clearTimeout(rateLimitTimer.current);
    };
  }, [eventId]); // eslint-disable-line react-hooks/exhaustive-deps

  const generatedLabel = generatedAt
    ? new Date(generatedAt).toLocaleString(undefined, {
        month: "short",
        day: "numeric",
        hour: "2-digit",
        minute: "2-digit",
      })
    : null;

  return (
    <div
      className="bg-white dark:bg-[#171725] flex flex-col gap-[12px] py-[14px]"
      style={{ fontFamily: MONO }}
    >
      {/* Header */}
      <div className="flex items-center justify-between px-[16px]">
        <div className="flex items-center gap-[10px]">
          <span className="text-[10px] uppercase tracking-[1.5px] text-[#545461] dark:text-[#c4c4ca]">
            AI Insights
          </span>
          {generatedLabel && !loading && (
            <span className="text-[9px] text-[#545461]/50 dark:text-[#c4c4ca]/40 uppercase tracking-[0.5px]">
              · {generatedLabel}
            </span>
          )}
        </div>
        {!loading && !error && (
          <button
            onClick={() => load(true)}
            disabled={rateLimited}
            className="flex items-center gap-[5px] text-[10px] uppercase tracking-[1px] text-[#545461] dark:text-[#c4c4ca] hover:text-[#171725] dark:hover:text-white transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
            title={rateLimited ? "Rate limit reached — try again in a minute" : undefined}
          >
            <RefreshCw size={9} />
            {rateLimited
              ? "Limit reached"
              : remixesLeft != null
                ? `Regenerate (${remixesLeft} left)`
                : "Regenerate"}
          </button>
        )}
      </div>

      {/* Error state */}
      {error && (
        <div className="px-[16px] flex items-center gap-[12px]">
          <span className="text-[12px] text-[var(--destructive)]">{error}</span>
          <button
            onClick={() => load(false)}
            className="text-[11px] uppercase tracking-[1px] text-[#545461] dark:text-[#c4c4ca] underline"
          >
            Retry
          </button>
        </div>
      )}

      {/* Cards — horizontal scroll strip */}
      {!error && (
        <div
          className="flex gap-[8px] overflow-x-auto px-[16px]"
          style={{ scrollbarWidth: "none", WebkitOverflowScrolling: "touch" } as React.CSSProperties}
        >
          {loading
            ? Array.from({ length: 5 }).map((_, i) => <SkeletonCard key={i} />)
            : insights?.map((insight, i) => <InsightCard key={i} insight={insight} />)}
        </div>
      )}
    </div>
  );
}
