import { expect, test } from "bun:test";
import { randomBytes } from "node:crypto";
import { configureStagingEnvironment } from "./staging-config";

function fixture(): NodeJS.ProcessEnv {
  return {
    NODE_ENV: "staging", TOJ_CRYPTO_MODE: "envelope", TOJ_KEY_ENCRYPTION_PROVIDER: "local",
    DATABASE_URL: "postgres://localhost:5432/toj_test?sslmode=verify-full",
    TOJ_LOCAL_KEY_ENCRYPTION_KEY: randomBytes(32).toString("base64"),
    TOJ_MESSAGE_KEY: randomBytes(32).toString("base64"),
    TOJ_HMAC_KEY: randomBytes(32).toString("base64"),
    TOJ_PROTOCOL_ID_KEY: randomBytes(32).toString("base64"),
    TOJ_STAGING_BLIND_INDEX_KEY: randomBytes(32).toString("base64"),
  };
}

test("staging has no deterministic fallback keys and refuses reused secrets", () => {
  for (const name of ["TOJ_LOCAL_KEY_ENCRYPTION_KEY", "TOJ_MESSAGE_KEY", "TOJ_HMAC_KEY",
    "TOJ_PROTOCOL_ID_KEY", "TOJ_STAGING_BLIND_INDEX_KEY"]) {
    for (const value of [undefined, Buffer.alloc(32, 7).toString("base64"), "invalid"]) {
      const env = fixture();
      env[name] = value;
      expect(() => configureStagingEnvironment(env)).toThrow(name);
    }
  }
  const env = fixture();
  env.TOJ_HMAC_KEY = env.TOJ_LOCAL_KEY_ENCRYPTION_KEY;
  expect(() => configureStagingEnvironment(env)).toThrow("TOJ_HMAC_KEY");
});

test("staging refuses production mode and legacy writes", () => {
  expect(() => configureStagingEnvironment({ ...fixture(), NODE_ENV: "production" })).toThrow();
  expect(() => configureStagingEnvironment({ ...fixture(), TOJ_CRYPTO_MODE: "legacy" })).toThrow();
});

test("staging requires certificate-verified session connections for pool and listeners", () => {
  for (const name of ["DATABASE_URL", "TOJ_CALL_NOTIFY_DATABASE_URL"]) {
    for (const url of ["not a url", "postgres://localhost:6543/postgres?sslmode=verify-full",
      "postgres://localhost:5432/postgres?sslmode=require"]) {
      expect(() => configureStagingEnvironment({ ...fixture(), [name]: url })).toThrow(name);
    }
  }
});

test("staging OTP requires a nonempty exact-phone allowlist", () => {
  for (const allowlist of [undefined, "", "*", "invalid", "+12025550101,"]) {
    expect(() => configureStagingEnvironment({ ...fixture(), TOJ_RETURN_OTP: "1",
      TOJ_DEV_OTP_ALLOWLIST: allowlist })).toThrow("TOJ_DEV_OTP_ALLOWLIST");
  }
});

test("staging configures a versioned keyring without changing production checks", () => {
  const env = fixture();
  configureStagingEnvironment(env);
  expect(env.NODE_ENV).toBe("staging");
  expect(env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID).toBe("staging-v1");
  expect(JSON.parse(env.TOJ_BLIND_INDEX_KEYRING!)["staging-v1"]).toBe(env.TOJ_STAGING_BLIND_INDEX_KEY);
});

test("staging rejects unreviewed external providers and URL bearer tokens", () => {
  for (const name of ["TOJ_VOICE_CALLS_ENABLED", "TOJ_VIDEO_CALLS_ENABLED",
    "TOJ_GROUP_CALLS_ENABLED", "TOJ_ABUSE_REPORTS_ENABLED", "TOJ_GIPHY_ENABLED",
    "TOJ_ALLOW_LEGACY_WS_QUERY_TOKEN"]) {
    expect(() => configureStagingEnvironment({ ...fixture(), [name]: "1" })).toThrow();
  }
});
