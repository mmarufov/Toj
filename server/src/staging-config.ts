// This profile deliberately uses the existing development wrapping provider with real secrets.
// It is not a managed KMS and cannot run with NODE_ENV=production.
export function configureStagingEnvironment(env: NodeJS.ProcessEnv = process.env): void {
  if (env.NODE_ENV !== "staging") throw new Error("staging entrypoint requires NODE_ENV=staging");
  if (env.TOJ_CRYPTO_MODE !== "envelope" || env.TOJ_KEY_ENCRYPTION_PROVIDER !== "local") {
    throw new Error("staging requires envelope encryption and the explicit local provider");
  }
  const keyNames = [
    "TOJ_LOCAL_KEY_ENCRYPTION_KEY", "TOJ_MESSAGE_KEY", "TOJ_HMAC_KEY",
    "TOJ_PROTOCOL_ID_KEY", "TOJ_STAGING_BLIND_INDEX_KEY",
  ];
  const encodedKeys = new Set<string>();
  for (const name of keyNames) {
    const value = env[name];
    const decoded = Buffer.from(value ?? "", "base64");
    const canonical = decoded.toString("base64");
    const valid = decoded.length === 32 && canonical === value
      && new Set(decoded).size > 1 && !encodedKeys.has(canonical);
    decoded.fill(0);
    if (!valid) throw new Error(`${name} must be a distinct random 32-byte base64 secret`);
    encodedKeys.add(canonical);
  }
  if (!env.DATABASE_URL) throw new Error("DATABASE_URL is required");
  for (const name of ["DATABASE_URL", "TOJ_CALL_NOTIFY_DATABASE_URL"]) {
    const value = env[name];
    if (!value) continue;
    let url: URL;
    try { url = new URL(value); } catch { throw new Error(`${name} must be a PostgreSQL URL`); }
    if (!["postgres:", "postgresql:"].includes(url.protocol)
      || url.port !== "5432" || url.searchParams.get("sslmode") !== "verify-full") {
      throw new Error(`${name} requires PostgreSQL session port 5432 and sslmode=verify-full`);
    }
  }
  if (env.TOJ_RETURN_OTP === "1") {
    const phones = (env.TOJ_DEV_OTP_ALLOWLIST ?? "").split(",").map((phone) => phone.trim());
    if (!phones.length || phones.some((phone) => !/^\+[1-9]\d{7,14}$/.test(phone))) {
      throw new Error("private staging OTP requires a valid nonempty TOJ_DEV_OTP_ALLOWLIST");
    }
  }
  // Never infer readiness for external providers from this private testing profile.
  for (const name of [
    "TOJ_VOICE_CALLS_ENABLED", "TOJ_VIDEO_CALLS_ENABLED", "TOJ_GROUP_CALLS_ENABLED",
    "TOJ_ABUSE_REPORTS_ENABLED", "TOJ_GIPHY_ENABLED",
  ]) {
    if (env[name] === "1") throw new Error(`${name} requires a separately reviewed deployment`);
  }
  if (env.TOJ_ALLOW_LEGACY_WS_QUERY_TOKEN === "1") {
    throw new Error("staging requires WebSocket Authorization headers");
  }
  env.TOJ_BLIND_INDEX_KEYRING = JSON.stringify({ "staging-v1": env.TOJ_STAGING_BLIND_INDEX_KEY });
  env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID = "staging-v1";
}
