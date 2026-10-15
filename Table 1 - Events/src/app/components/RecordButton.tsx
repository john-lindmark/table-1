const MONO = "var(--font-sf-mono)";

interface RecordButtonProps {
  label: string;
  disabled: boolean;
  busy: boolean;
  incomplete: boolean;
  onClick: () => void;
}

export function RecordButton({ label, disabled, busy, incomplete, onClick }: RecordButtonProps) {
  const isDisabled = disabled || busy || incomplete;
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={isDisabled}
      className={`w-full px-[16px] py-[32px] flex items-center justify-center transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-[-4px] focus-visible:outline-[#00ffd9] ${
        incomplete || disabled
          ? "bg-[#545461] text-[#171725]"
          : "bg-[#171725] text-white hover:bg-[#2a2a3d] dark:bg-white dark:text-[#171725] dark:hover:bg-[#e6e6ea]"
      }`}
    >
      <p
        className="[word-break:break-word] flex-[1_0_0] leading-[24px] min-w-px text-[20px] text-center tracking-[6px] uppercase"
        style={{ fontFamily: MONO, fontWeight: 700 }}
      >
        {busy ? "Recording…" : label}
      </p>
    </button>
  );
}
