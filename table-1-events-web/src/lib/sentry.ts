// Only what telemetry.ts uses, so the lazily loaded Sentry chunk tree-shakes down to it.
export { browserTracingIntegration, captureException, close, getClient, httpClientIntegration, init, setUser, startInactiveSpan } from "@sentry/browser";
