import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The Vapor backend serves this app's built assets in production (via FileMiddleware) at the
// same origin, so no API base URL is needed there. In dev, proxy /api and /healthz to the local
// `swift run` server (default port 8080) so the browser never hits a cross-origin request.
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      // `ws: true` is required for the live-capture WebSocket (/api/sessions/:id/live) to proxy —
      // the plain string shorthand only forwards HTTP, not the upgrade handshake.
      "/api": { target: "http://127.0.0.1:8080", ws: true },
      "/healthz": "http://127.0.0.1:8080",
    },
  },
  build: {
    outDir: "dist",
  },
});
