import { defineConnectApp } from "@withone/connect/config";

// No `ask`. A listed ask caps the grant at those tools, and the person
// cannot widen it. Omitting it lets them grant any connector they connect
// on One. Update the live app with `one connect create` from this directory
// so the old eleven-tool permission set is dropped.
export default defineConnectApp({
  name: "Maia",
  redirectUris: [
    "http://127.0.0.1:8090/one/callback",
    "http://localhost:8090/one/callback",
    "http://127.0.0.1:8788/api/one/callback",
  ],
  reason:
    "Maia reads the accounts you connect and keeps them in your memory on this machine.",
});
