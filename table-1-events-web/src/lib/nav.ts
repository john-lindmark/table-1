import { useCallback } from "react";
import { useNavigate } from "react-router-dom";

/** Back where the user came from, or `fallback` when the screen was opened directly (a shared link, a reload). */
export function useBack(fallback: string): () => void {
  const navigate = useNavigate();
  return useCallback(() => {
    const idx = (window.history.state as { idx?: number } | null)?.idx ?? 0;
    if (idx > 0) navigate(-1);
    else navigate(fallback, { replace: true });
  }, [navigate, fallback]);
}
