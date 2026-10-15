import svgPaths from "./svg-rhfdmma4ls";

export default function PlayerObject() {
  return (
    <button className="bg-[#282839] content-stretch cursor-pointer flex gap-px items-center justify-center px-[16px] py-[12px] relative size-full" data-name="Player Object">
      <p className="[word-break:break-word] flex-[1_0_0] font-['SF_Mono:Regular',sans-serif] leading-[16px] min-w-px not-italic relative text-[12px] text-left text-white tracking-[0.2px]">Player</p>
      <div className="bg-[#00ffd9] relative shrink-0 size-[8px]" data-name="Recorded Win" />
      <div className="bg-[#00ffd9] relative shrink-0 size-[8px]" data-name="Recorded Win" />
      <div className="overflow-clip relative shrink-0 size-[12px]" data-name="add_24dp_5F6368_FILL0_wght300_GRAD0_opsz24 2">
        <div className="absolute inset-[8.33%]" data-name="Vector">
          <svg className="absolute block inset-0 size-full" fill="none" preserveAspectRatio="none" viewBox="0 0 10 10">
            <path d={svgPaths.p2963e800} fill="var(--fill-0, #545461)" id="Vector" />
          </svg>
        </div>
      </div>
    </button>
  );
}