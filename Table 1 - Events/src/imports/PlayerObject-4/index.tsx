export default function PlayerObject() {
  return (
    <div className="bg-[#00ffd9] content-stretch flex gap-px items-center justify-center px-[16px] py-[12px] relative size-full" data-name="Player Object">
      <p className="[word-break:break-word] flex-[1_0_0] font-['SF_Mono:Regular',sans-serif] leading-[16px] min-w-px not-italic relative text-[12px] text-white tracking-[0.2px]">Player</p>
      <div className="bg-white relative shrink-0 size-[8px]" data-name="Recorded Win" />
      <div className="bg-white relative shrink-0 size-[8px]" data-name="Recorded Win" />
    </div>
  );
}