/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_SUPABASE_URL: string;
  readonly VITE_SUPABASE_ANON_KEY: string;
  /** PostHog project key; empty means product analytics is off. */
  readonly VITE_POSTHOG_KEY?: string;
  /** Default https://us.i.posthog.com. */
  readonly VITE_POSTHOG_HOST?: string;
  /** Sentry DSN for table1-web; empty means error reporting is off. */
  readonly VITE_SENTRY_DSN?: string;
  /** "1" lets a dev server send telemetry (tagged environment "dev"). */
  readonly VITE_TELEMETRY?: string;
  /** Google's web OAuth client ID; empty means Google sign-in goes through Supabase's OAuth hop. */
  readonly VITE_GOOGLE_WEB_CLIENT_ID?: string;
  /** The Discord application's client id (contract/discord-2026-10-29.md); empty hides "Add to your server". */
  readonly VITE_DISCORD_CLIENT_ID?: string;
  /** A never-expiring invite to the Table 1 Discord server (discord.gg/…); empty hides "Join the Table 1 server". */
  readonly VITE_DISCORD_INVITE_URL?: string;
}

/** package.json version, set by vite.config.ts. */
declare const __APP_VERSION__: string;
/** Short git commit of the build, set by vite.config.ts. */
declare const __APP_BUILD__: string;
/** marketing/bundle/spots/shots on disk, set by vite.config.ts; the dev server serves it as /@fs/… */
declare const __SPOTS_SHOTS_DIR__: string;
