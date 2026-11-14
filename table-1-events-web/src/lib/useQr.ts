import { useEffect, useState } from "react";

/**
 * A QR code of `text` as an image address (null until drawn, or when it can't be). The encoder is its own chunk,
 * loaded the first time a QR is shown: the organizer's join code, the display's sign-up link and its own address.
 */
export function useQr(text: string | null, width = 480): string | null {
  const [qr, setQr] = useState<string | null>(null);
  useEffect(() => {
    if (!text) return setQr(null);
    let gone = false;
    import("qrcode")
      .then(({ default: QRCode }) => QRCode.toDataURL(text, { margin: 1, width, color: { dark: "#171725", light: "#ffffff" } }))
      .then((url) => { if (!gone) setQr(url); })
      .catch(() => { if (!gone) setQr(null); });
    return () => { gone = true; };
  }, [text, width]);
  return qr;
}
