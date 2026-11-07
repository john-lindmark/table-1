import { useState } from "react";
import { avatarColor, avatarInitials } from "../lib/avatar";
import { avatarUrl, useAvatarPath } from "../lib/avatarStore";
import { useOpenProfile } from "../lib/personLink";

/** A square tile: the photo when the account has one, otherwise initials on its color. With `opens` (where the row's own
 *  tap does something else) the tile alone opens their profile (lib/personLink.ts); `opens` names the place for telemetry. */
export function Avatar({ name, userId, size = 24, opens }: { name: string; userId?: string | null; size?: number; opens?: string }) {
  if (opens) return <AvatarLink name={name} userId={userId} size={size} from={opens} />;
  return <AvatarTile name={name} userId={userId} size={size} />;
}

function AvatarLink({ name, userId, size, from }: { name: string; userId?: string | null; size: number; from: string }) {
  const open = useOpenProfile(from)(userId);
  if (!open) return <AvatarTile name={name} userId={userId} size={size} />;
  // A span, not a button: it often sits inside a row that is a button.
  return (
    <span
      role="link"
      tabIndex={0}
      aria-label={`${name}'s profile`}
      className="shrink-0 cursor-pointer"
      onClick={(e) => {
        e.stopPropagation();
        e.preventDefault();
        open();
      }}
      onKeyDown={(e) => {
        if (e.key !== "Enter" && e.key !== " ") return;
        e.stopPropagation();
        e.preventDefault();
        open();
      }}
    >
      <AvatarTile name={name} userId={userId} size={size} />
    </span>
  );
}

function AvatarTile({ name, userId, size }: { name: string; userId?: string | null; size: number }) {
  const path = useAvatarPath(userId);
  const [failed, setFailed] = useState<string | null>(null);
  return (
    <span
      aria-hidden
      className="relative shrink-0 overflow-hidden flex items-center justify-center text-t1-text font-medium leading-none"
      style={{
        width: size,
        height: size,
        background: avatarColor(userId, name),
        fontSize: size * 0.4,
        letterSpacing: 0.5,
      }}
    >
      {avatarInitials(name)}
      {path && failed !== path && (
        <img
          src={avatarUrl(path)}
          alt=""
          className="absolute inset-0 w-full h-full object-cover"
          onError={() => setFailed(path)}
        />
      )}
    </span>
  );
}
