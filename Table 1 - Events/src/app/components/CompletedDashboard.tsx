import { useMemo, useState } from "react";
import { Settings, Printer, Link } from "lucide-react";
import type { EventState, Pairing, Team } from "../lib/types";
import { computeScores, countDraws, resolvePairings, roundWinsByTeam } from "../lib/scoring";
import type { PairingResolution } from "../lib/scoring";
import { AIInsightsShelf } from "./AIInsightsShelf";
import type { AIInsight } from "../lib/api";

const MONO = "var(--font-sf-mono)";

export interface CompletedDashboardProps {
  event: EventState;
  onOpenSettings?: () => void;
  onBack?: () => void;
  onSignOut?: () => void;
  /** When true: no nav controls, public-facing view */
  isPublic?: boolean;
  /** Custom fetch function for insights (public pages skip auth). */
  fetchInsights?: (id: string, force?: boolean) => Promise<{ insights: AIInsight[]; generatedAt: string }>;
}

// ─── derived types ─────────────────────────────────────────────────────────────

interface FormatRoundStats {
  formatId: string;
  formatName: string;
  aWins: number;
  bWins: number;
  drawCount: number;
}

interface RoundStats {
  roundNumber: number;
  recordedAt: string;
  aTotal: number;
  bTotal: number;
  winner: "a" | "b" | "tie";
  formats: FormatRoundStats[];
  resolutions: Record<string, PairingResolution>;
  pairings: Pairing[];
}

interface FormatEventStats {
  formatId: string;
  formatName: string;
  aTotal: number;
  bTotal: number;
  aRoundsWon: number;
  bRoundsWon: number;
  tiedRounds: number;
  drawnMatchups: number;
}

// ─── helpers ──────────────────────────────────────────────────────────────────

function formatElapsed(durationSeconds: number, completedAtSeconds: number | null | undefined): string | null {
  if (completedAtSeconds == null) return null;
  const elapsed = Math.max(0, durationSeconds - completedAtSeconds);
  const m = Math.floor(elapsed / 60);
  const s = elapsed % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}

// ─── read-only grid sub-components ────────────────────────────────────────────

function ReadOnlyWinDots({ count, onWinner }: { count: number; onWinner: boolean }) {
  if (count <= 0) return null;
  return (
    <>
      {Array.from({ length: count }).map((_, i) => (
        <div
          key={i}
          className={onWinner ? "bg-[#171725] shrink-0 size-[8px]" : "bg-[#00ffd9] shrink-0 size-[8px]"}
        />
      ))}
    </>
  );
}

function ReadOnlyPlayerCell({
  name,
  isWinner,
  gameWins,
  align,
}: {
  name: string;
  isWinner: boolean;
  gameWins: number;
  align: "left" | "right";
}) {
  return (
    <div className={`flex-[1_0_0] min-w-px ${isWinner ? "bg-[#00ffd9]" : "bg-[#f5f5f6] dark:bg-[#282839]"}`}>
      <div className={`flex items-center gap-[6px] px-[16px] py-[12px] ${align === "right" ? "flex-row-reverse" : "flex-row"}`}>
        <p
          className={`[word-break:break-word] flex-[1_0_0] leading-[16px] min-w-px text-[12px] tracking-[0.2px] ${align === "right" ? "text-right" : "text-left"} ${isWinner ? "text-[#171725]" : "text-[#171725] dark:text-white"}`}
          style={{ fontFamily: MONO }}
        >
          {name}
        </p>
        <ReadOnlyWinDots count={gameWins} onWinner={isWinner} />
      </div>
    </div>
  );
}

function RoundFormatColumn({
  fmt,
  pairings,
  resolutions,
  playerName,
  teamA,
  teamB,
  timerDurationSeconds,
  fmtStats,
}: {
  fmt: { id: string; name: string };
  pairings: Pairing[];
  resolutions: Record<string, PairingResolution>;
  playerName: (id: string) => string;
  teamA: Team;
  teamB: Team;
  timerDurationSeconds: number;
  fmtStats: FormatRoundStats;
}) {
  const fmtWinner =
    fmtStats.aWins > fmtStats.bWins ? teamA : fmtStats.bWins > fmtStats.aWins ? teamB : null;

  return (
    <div className="flex flex-[1_0_0] flex-col gap-px items-start min-w-px">
      {/* Format column header */}
      <div className="bg-[#f5f5f6] dark:bg-[#282839] w-full px-[16px] py-[8px] flex items-center gap-[8px]">
        <p
          className="[word-break:break-word] flex-[1_0_0] min-w-px leading-[16px] text-[#545461] dark:text-[#c4c4ca] text-[12px] tracking-[0.2px]"
          style={{ fontFamily: MONO }}
        >
          {fmt.name}
        </p>
        {/* Round-level format score */}
        <div className="flex items-center gap-[4px] shrink-0">
          <span
            className="tabular-nums text-[11px]"
            style={{
              fontFamily: MONO,
              color: fmtWinner?.id === teamA.id ? "#00a88f" : "#545461",
              fontWeight: fmtWinner?.id === teamA.id ? 700 : 400,
            }}
          >
            {fmtStats.aWins}
          </span>
          <span className="text-[9px] text-[#cbced4] dark:text-[#545461]">—</span>
          <span
            className="tabular-nums text-[11px]"
            style={{
              fontFamily: MONO,
              color: fmtWinner?.id === teamB.id ? "#00a88f" : "#545461",
              fontWeight: fmtWinner?.id === teamB.id ? 700 : 400,
            }}
          >
            {fmtStats.bWins}
          </span>
        </div>
      </div>

      {/* Matchup rows */}
      <div className="flex flex-col gap-px items-start w-full">
        {pairings.map((pair) => {
          const res = resolutions[pair.id];
          const aWinner = res?.winner === "a" && res?.status === "decisive";
          const bWinner = res?.winner === "b" && res?.status === "decisive";
          const isDraw = res?.status === "draw";
          const matchTime = formatElapsed(timerDurationSeconds, pair.completedAtSeconds);

          return (
            <div key={pair.id} className="flex flex-col gap-px w-full">
              <div className="flex gap-px items-stretch w-full">
                <ReadOnlyPlayerCell
                  name={playerName(pair.teamAPlayerId)}
                  isWinner={aWinner}
                  gameWins={pair.teamAGameWins ?? 0}
                  align="left"
                />
                <ReadOnlyPlayerCell
                  name={playerName(pair.teamBPlayerId)}
                  isWinner={bWinner}
                  gameWins={pair.teamBGameWins ?? 0}
                  align="right"
                />
              </div>
              {/* Match time + draw indicator */}
              {(matchTime || isDraw) && (
                <div className="w-full flex items-center justify-center gap-[6px] py-[3px] bg-white dark:bg-[#171725]">
                  {isDraw && (
                    <span
                      className="text-[9px] uppercase tracking-[1px] text-[#545461] dark:text-[#c4c4ca]"
                      style={{ fontFamily: MONO }}
                    >
                      Draw
                    </span>
                  )}
                  {matchTime && (
                    <span
                      className="text-[9px] tabular-nums text-[#545461]/60 dark:text-[#c4c4ca]/50"
                      style={{ fontFamily: MONO }}
                    >
                      {isDraw ? "·" : ""} {matchTime}
                    </span>
                  )}
                </div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

function RoundHeader({ rs, teamA, teamB }: { rs: RoundStats; teamA: Team; teamB: Team }) {
  const roundWinner = rs.winner === "a" ? teamA : rs.winner === "b" ? teamB : null;
  const recordedTime = new Date(rs.recordedAt).toLocaleTimeString(undefined, {
    hour: "2-digit",
    minute: "2-digit",
  });

  return (
    <div
      className="bg-[#171725] dark:bg-[#0d0d19] w-full px-[16px] py-[10px] flex items-center gap-[12px]"
      style={{ fontFamily: MONO }}
    >
      <span className="text-white text-[12px] uppercase tracking-[1px] shrink-0">
        Round {rs.roundNumber}
      </span>
      <div className="flex items-center gap-[6px] shrink-0">
        <span
          className="tabular-nums text-[13px] leading-none"
          style={{
            color: rs.winner === "a" ? "#00ffd9" : "rgba(255,255,255,0.35)",
            fontWeight: rs.winner === "a" ? 700 : 400,
          }}
        >
          {rs.aTotal}
        </span>
        <span className="text-white/20 text-[10px]">—</span>
        <span
          className="tabular-nums text-[13px] leading-none"
          style={{
            color: rs.winner === "b" ? "#00ffd9" : "rgba(255,255,255,0.35)",
            fontWeight: rs.winner === "b" ? 700 : 400,
          }}
        >
          {rs.bTotal}
        </span>
      </div>
      {roundWinner && (
        <span className="text-[#00ffd9] text-[11px] uppercase tracking-[1px] shrink-0">
          {roundWinner.name}
        </span>
      )}
      {!roundWinner && (
        <span className="text-white/30 text-[11px] uppercase tracking-[1px] shrink-0">Tie</span>
      )}
      <div className="flex-[1_0_0] min-w-px" />
      <span className="text-white/25 text-[10px] shrink-0">{recordedTime}</span>
    </div>
  );
}

function RoundResultGrid({
  rs,
  event,
  playerName,
  timerDurationSeconds,
}: {
  rs: RoundStats;
  event: EventState;
  playerName: (id: string) => string;
  timerDurationSeconds: number;
}) {
  const teamA = event.teams[0];
  const teamB = event.teams[1];

  return (
    <div className="flex flex-col gap-px shrink-0">
      <RoundHeader rs={rs} teamA={teamA} teamB={teamB} />
      <div className="flex gap-px items-start w-full">
        {event.formats.map((fmt) => {
          const fmtPairings = rs.pairings.filter((p) => p.formatId === fmt.id);
          const fmtStats = rs.formats.find((f) => f.formatId === fmt.id)!;
          return (
            <RoundFormatColumn
              key={fmt.id}
              fmt={fmt}
              pairings={fmtPairings}
              resolutions={rs.resolutions}
              playerName={playerName}
              teamA={teamA}
              teamB={teamB}
              timerDurationSeconds={timerDurationSeconds}
              fmtStats={fmtStats}
            />
          );
        })}
      </div>
    </div>
  );
}

function FormatRecordBar({
  formatSummary,
  teamA,
  teamB,
}: {
  formatSummary: FormatEventStats[];
  teamA: Team;
  teamB: Team;
}) {
  return (
    <div className="shrink-0 flex gap-px">
      {formatSummary.map((fs) => {
        const winner = fs.aTotal > fs.bTotal ? teamA : fs.bTotal > fs.aTotal ? teamB : null;
        return (
          <div
            key={fs.formatId}
            className="flex-[1_0_0] min-w-px bg-[#f5f5f6] dark:bg-[#282839] px-[16px] py-[18px] flex flex-col gap-[6px]"
          >
            <p
              className="text-[9px] uppercase tracking-[1.5px] text-[#545461] dark:text-[#c4c4ca] truncate"
              style={{ fontFamily: MONO }}
            >
              {fs.formatName}
            </p>
            <div className="flex items-baseline gap-[8px]">
              <span
                className="tabular-nums leading-none"
                style={{
                  fontFamily: MONO,
                  fontWeight: 700,
                  fontSize: "clamp(22px, 3vw, 40px)",
                  color: winner?.id === teamA.id ? "#00a88f" : "#545461",
                }}
              >
                {fs.aTotal}
              </span>
              <span className="text-[#cbced4] dark:text-[#545461]" style={{ fontSize: "clamp(14px, 2vw, 20px)" }}>
                —
              </span>
              <span
                className="tabular-nums leading-none"
                style={{
                  fontFamily: MONO,
                  fontWeight: 700,
                  fontSize: "clamp(22px, 3vw, 40px)",
                  color: winner?.id === teamB.id ? "#00a88f" : "#545461",
                }}
              >
                {fs.bTotal}
              </span>
            </div>
            <p
              className="text-[11px] truncate"
              style={{ fontFamily: MONO, color: winner ? "#00a88f" : "#545461" }}
            >
              {winner ? winner.name : "Tied"}
              {fs.drawnMatchups > 0 && (
                <span className="text-[#545461] dark:text-[#c4c4ca]">
                  {" "}· {fs.drawnMatchups}D
                </span>
              )}
            </p>
          </div>
        );
      })}
    </div>
  );
}

// ─── main component ────────────────────────────────────────────────────────────

export function CompletedDashboard({
  event,
  onOpenSettings,
  onBack,
  onSignOut,
  isPublic = false,
  fetchInsights,
}: CompletedDashboardProps) {
  const teamA = event.teams[0];
  const teamB = event.teams[1];

  // ── lookups ──────────────────────────────────────────────────────────────────
  const playerName = useMemo(() => {
    const map = new Map(event.players.map((p) => [p.id, p.name]));
    return (id: string) => map.get(id) ?? "—";
  }, [event.players]);

  const playerTeamId = useMemo(() => {
    const map = new Map(event.players.map((p) => [p.id, p.teamId]));
    return (id: string) => map.get(id) ?? "";
  }, [event.players]);

  // ── final scores ─────────────────────────────────────────────────────────────
  const scores = computeScores(event);
  const aFinal = scores[teamA.id]?.total ?? 0;
  const bFinal = scores[teamB.id]?.total ?? 0;
  const isTie = aFinal === bFinal;
  const winner = isTie ? null : aFinal > bFinal ? teamA : teamB;
  const margin = Math.abs(aFinal - bFinal);

  const totalDraws = useMemo(
    () => event.recordedRounds.reduce((n, r) => n + countDraws(r.pairings), 0),
    [event.recordedRounds],
  );
  const totalMatches = useMemo(
    () => event.recordedRounds.reduce((n, r) => n + r.pairings.length, 0),
    [event.recordedRounds],
  );

  // ── per-round stats ───────────────────────────────────────────────────────────
  const roundStats = useMemo((): RoundStats[] => {
    return event.recordedRounds.map((round) => {
      const resolutions = resolvePairings(round.pairings, event.players);
      const byTeam = roundWinsByTeam(round.pairings, event.players);
      const aW = byTeam[teamA.id] ?? 0;
      const bW = byTeam[teamB.id] ?? 0;

      const formats = event.formats.map((fmt) => {
        const fp = round.pairings.filter((p) => p.formatId === fmt.id);
        let fmtA = 0, fmtB = 0, draws = 0;
        for (const p of fp) {
          const res = resolutions[p.id];
          if (!res) continue;
          if (res.status === "draw") { draws++; continue; }
          if (res.winner === null) continue;
          const wTeam = playerTeamId(res.winner === "a" ? p.teamAPlayerId : p.teamBPlayerId);
          if (wTeam === teamA.id) fmtA++;
          else fmtB++;
        }
        return { formatId: fmt.id, formatName: fmt.name, aWins: fmtA, bWins: fmtB, drawCount: draws };
      });

      return {
        roundNumber: round.roundNumber,
        recordedAt: round.recordedAt,
        aTotal: aW,
        bTotal: bW,
        winner: aW > bW ? "a" : bW > aW ? "b" : "tie",
        formats,
        resolutions,
        pairings: round.pairings,
      };
    });
  }, [event.recordedRounds, event.players, event.formats, teamA.id, playerTeamId]);

  // ── event-level format summary (for record bar) ───────────────────────────────
  const formatSummary = useMemo((): FormatEventStats[] => {
    return event.formats.map((fmt) => {
      let aTotal = 0, bTotal = 0, aRoundsWon = 0, bRoundsWon = 0, tiedRounds = 0, drawnMatchups = 0;
      for (const rs of roundStats) {
        const fs = rs.formats.find((f) => f.formatId === fmt.id);
        if (!fs) continue;
        aTotal += fs.aWins;
        bTotal += fs.bWins;
        drawnMatchups += fs.drawCount;
        if (fs.aWins > fs.bWins) aRoundsWon++;
        else if (fs.bWins > fs.aWins) bRoundsWon++;
        else tiedRounds++;
      }
      return { formatId: fmt.id, formatName: fmt.name, aTotal, bTotal, aRoundsWon, bRoundsWon, tiedRounds, drawnMatchups };
    });
  }, [roundStats, event.formats]);

  // ── completion date ───────────────────────────────────────────────────────────
  const finalRound = event.recordedRounds[event.recordedRounds.length - 1];
  const completedAt = finalRound
    ? new Date(finalRound.recordedAt).toLocaleString(undefined, {
        month: "short",
        day: "numeric",
        year: "numeric",
        hour: "2-digit",
        minute: "2-digit",
      })
    : null;

  // ── share link ────────────────────────────────────────────────────────────────
  const [copied, setCopied] = useState(false);
  const copyShareLink = () => {
    const url = `${window.location.origin}${window.location.pathname}?share=${event.id}`;
    navigator.clipboard.writeText(url).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    });
  };

  // timer duration for computing elapsed match times
  const timerDurationSeconds = event.timer.durationSeconds;

  // ── render ────────────────────────────────────────────────────────────────────
  return (
    <div className="h-full w-full flex flex-col gap-px overflow-hidden">
      {/* ── nav bar ─────────────────────────────────────────────────────────── */}
      <div
        className="shrink-0 flex items-center gap-px bg-[#f5f5f6] dark:bg-[#282839]"
        style={{ fontFamily: MONO }}
      >
        {!isPublic && onBack && (
          <button
            onClick={onBack}
            className="px-[16px] py-[11px] text-[11px] uppercase tracking-[1px] text-[#545461] dark:text-[#c4c4ca] hover:text-[#171725] dark:hover:text-white shrink-0"
          >
            ← Past Events
          </button>
        )}
        {isPublic && (
          <span className="px-[16px] py-[11px] text-[11px] uppercase tracking-[1px] text-[#545461] dark:text-[#c4c4ca] shrink-0">
            Results
          </span>
        )}
        <div className="flex-[1_0_0] min-w-px" />
        {/* Share / copy link */}
        <button
          onClick={copyShareLink}
          className="flex items-center gap-[5px] px-[14px] py-[11px] text-[11px] uppercase tracking-[1px] text-[#545461] dark:text-[#c4c4ca] hover:text-[#171725] dark:hover:text-white shrink-0 transition-colors"
          title="Copy share link"
        >
          <Link size={12} />
          {copied ? "Copied!" : "Share"}
        </button>
        {!isPublic && (
          <>
            <button
              onClick={() => window.print()}
              className="p-[11px] text-[#545461] dark:text-[#c4c4ca] hover:text-[#171725] dark:hover:text-white shrink-0"
              aria-label="Print results"
            >
              <Printer size={15} />
            </button>
            {onOpenSettings && (
              <button
                onClick={onOpenSettings}
                className="p-[11px] text-[#545461] dark:text-[#c4c4ca] hover:text-[#171725] dark:hover:text-white shrink-0"
                aria-label="Event settings"
              >
                <Settings size={15} />
              </button>
            )}
            {onSignOut && (
              <button
                onClick={onSignOut}
                className="px-[16px] py-[11px] text-[11px] uppercase tracking-[1px] text-[#545461] dark:text-[#c4c4ca] hover:text-[#171725] dark:hover:text-white shrink-0"
              >
                Sign out
              </button>
            )}
          </>
        )}
      </div>

      {/* ── hero ────────────────────────────────────────────────────────────── */}
      <div className="shrink-0 bg-[#171725] dark:bg-[#0d0d19] flex flex-col items-center justify-center gap-[10px] px-[32px] py-[40px] text-center">
        {isTie ? (
          <p
            className="text-white uppercase tracking-[4px] leading-none"
            style={{ fontSize: "clamp(22px, 4.5vw, 52px)", fontWeight: 700, fontFamily: MONO }}
          >
            Event Ends in a Tie
          </p>
        ) : (
          <>
            <p
              className="text-[#00ffd9] uppercase tracking-[4px] leading-none"
              style={{ fontSize: "clamp(22px, 4.5vw, 52px)", fontWeight: 700, fontFamily: MONO }}
            >
              {winner!.name} Wins
            </p>
            <p
              className="text-white/40 text-[12px] tracking-[2px] uppercase"
              style={{ fontFamily: MONO }}
            >
              +{margin} match win{margin !== 1 ? "s" : ""}
            </p>
          </>
        )}

        <div className="flex items-baseline gap-[14px] mt-[6px]" style={{ fontFamily: MONO }}>
          <span className="text-white/50 text-[clamp(13px,1.8vw,18px)] truncate max-w-[30vw]">
            {teamA.name}
          </span>
          <span
            className="tabular-nums leading-none"
            style={{
              fontSize: "clamp(28px, 5vw, 64px)",
              fontWeight: 700,
              color: isTie || winner?.id === teamA.id ? "#00ffd9" : "rgba(255,255,255,0.35)",
            }}
          >
            {aFinal}
          </span>
          <span className="text-white/20 text-[clamp(20px,3vw,40px)]">—</span>
          <span
            className="tabular-nums leading-none"
            style={{
              fontSize: "clamp(28px, 5vw, 64px)",
              fontWeight: 700,
              color: isTie || winner?.id === teamB.id ? "#00ffd9" : "rgba(255,255,255,0.35)",
            }}
          >
            {bFinal}
          </span>
          <span className="text-white/50 text-[clamp(13px,1.8vw,18px)] truncate max-w-[30vw]">
            {teamB.name}
          </span>
        </div>

        <div
          className="flex flex-wrap items-center justify-center gap-x-[12px] gap-y-[2px] mt-[4px] text-[10px] text-white/30 uppercase tracking-[1.2px]"
          style={{ fontFamily: MONO }}
        >
          <span>{event.name}</span>
          <span>·</span>
          <span>Completed</span>
          {completedAt && <><span>·</span><span>{completedAt}</span></>}
          <span>·</span>
          <span>{event.numberOfRounds} rounds</span>
          <span>·</span>
          <span>{totalMatches} matches</span>
          {totalDraws > 0 && <><span>·</span><span>{totalDraws} {totalDraws === 1 ? "draw" : "draws"}</span></>}
          <span>·</span>
          <span>{event.matchupMethod === "round_robin" ? "Round Robin" : "Swiss"}</span>
        </div>
      </div>

      {/* ── scrollable content ───────────────────────────────────────────────── */}
      <div className="flex-[1_0_0] min-h-0 overflow-y-auto flex flex-col gap-px">
        {/* AI insights shelf */}
        <AIInsightsShelf
          eventId={event.id}
          regenerateRateLimit={isPublic ? 5 : undefined}
          fetchInsights={fetchInsights}
        />

        {/* Format record callouts — large scores per format, aligned with round grid columns */}
        <FormatRecordBar formatSummary={formatSummary} teamA={teamA} teamB={teamB} />

        {/* Round grids — one per recorded round, read-only */}
        {roundStats.map((rs) => (
          <RoundResultGrid
            key={rs.roundNumber}
            rs={rs}
            event={event}
            playerName={playerName}
            timerDurationSeconds={timerDurationSeconds}
          />
        ))}
      </div>
    </div>
  );
}
