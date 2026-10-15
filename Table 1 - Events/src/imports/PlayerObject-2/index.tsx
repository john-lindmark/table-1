import svgPaths from "./svg-e024w2hfst";

export default function PlayerObject() {
  return (
    <button className="bg-[#f5f5f6] content-stretch cursor-pointer flex gap-px items-center justify-center px-[16px] py-[12px] relative size-full" data-name="Player Object">
      <p className="[word-break:break-word] flex-[1_0_0] font-['SF_Mono:Regular',sans-serif] leading-[16px] min-w-px not-italic relative text-[#171725] text-[12px] text-left tracking-[0.2px]">Player</p>
      <div className="bg-[#00ffd9] relative shrink-0 size-[8px]" data-name="Recorded Win" />
      <div className="overflow-clip relative shrink-0 size-[12px]" data-name="add_24dp_5F6368_FILL0_wght300_GRAD0_opsz24 1">
        <div className="absolute inset-[22.92%]" data-name="Vector">
          <svg className="absolute block inset-0 size-full" fill="none" preserveAspectRatio="none" viewBox="0 0 6.5 6.5">
            <path d={svgPaths.p1d8c5e00} fill="var(--fill-0, #C4C4CA)" id="Vector" />
          </svg>
        </div>
      </div>
    </button>
  );
}