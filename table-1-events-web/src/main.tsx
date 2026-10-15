import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import { startTelemetry } from "./lib/telemetry";
import "./styles/globals.css";

startTelemetry();

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
