import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import { startTelemetry } from "./lib/telemetry";
import { registerServiceWorker } from "./lib/serviceWorker";
import { installKeyboardAway } from "./lib/keyboardAway";
import "./styles/globals.css";

startTelemetry();
registerServiceWorker(navigator, window);
// A tap outside a text box puts the phone keyboard away (lib/keyboardAway.ts).
installKeyboardAway();

// A tab open across a deploy: its screens' chunks are gone from the server (hashed names, old ones not kept), so
// the first screen it opens afterwards fails to load and the link looks broken. Reload once onto the new build.
window.addEventListener("vite:preloadError", (event) => {
  const key = "t1.reloaded-for-chunk";
  let again = false;
  try { again = sessionStorage.getItem(key) === location.href; sessionStorage.setItem(key, location.href); } catch { /* storage off */ }
  if (again) return; // the same page twice: let the error show rather than loop
  event.preventDefault();
  location.reload();
});

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
