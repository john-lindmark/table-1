import { useState } from "react";
import { avatarColor, avatarInitials } from "../lib/avatar";
import { avatarUrl, useAvatarPath } from "../lib/avatarStore";

/** A square tile: the photo when the account has one, otherwise initials on its color. */
export function Avatar({ name, userId, size = 24 }: { name: string; userId?: string | null; size?: number }) {
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
