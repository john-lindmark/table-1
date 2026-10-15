import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { projectId, publicAnonKey } from "../../../utils/supabase/info";

// Singleton browser client.
let client: SupabaseClient | null = null;

export function getSupabase(): SupabaseClient {
  if (!client) {
    client = createClient(`https://${projectId}.supabase.co`, publicAnonKey, {
      auth: { persistSession: true, autoRefreshToken: true },
    });
  }
  return client;
}

export const API_BASE = `https://${projectId}.supabase.co/functions/v1/make-server-a539856f`;
export { publicAnonKey };
