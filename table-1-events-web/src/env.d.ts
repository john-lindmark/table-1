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
}

/** package.json version, set by vite.config.ts. */
declare const __APP_VERSION__: string;
/** Short git commit of the build, set by vite.config.ts. */
declare const __APP_BUILD__: string;
