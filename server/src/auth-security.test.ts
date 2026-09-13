import { beforeEach, describe, expect, test } from "bun:test";
import { Client } from "pg";
import { makeSql } from "./db";
import {
  checkVerification,
  checkVerificationV2,
  completeSecurityStepUp,
  completeTwoFactorLogin,
  configureTwoFactor,
  deleteAccount,
  disableTwoFactor,
  regenerateTwoFactorRecoveryCodes,
  resolveDevice,
  startAccountDeletion,
  startSecurityChange,
  startVerification,
  twoFactorStatus,
} from "./auth";
import { startCloudServer } from "./cloud";
import {
  ACCESS_TOKEN_TTL_MS,
  ROTATION_RECEIPT_RETAINED_GENERATIONS,
  SESSION_ABSOLUTE_TTL_MS,
  issueV2Session,
  refreshV2Session,
  resolveV2Access,
  upgradeLegacySession,
} from "./session-security";
import { cleanupExpiredData } from "./ops";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);

async function resetDb() {
  await db`TRUNCATE accounts, otp_challenges RESTART IDENTITY CASCADE`;
}

async function legacyAccount(phone: string) {
  const { code } = await startVerification(db, phone);
  return await checkVerification(db, phone, code!, "ios", "Security iPhone", "Alice");
}

describe("auth protocol v2 and two-step verification", () => {
  beforeEach(resetDb);

  test("refresh rotation is crash-safe and detects a different replay", async () => {
    const legacy = await legacyAccount("+16505557101");
    const upgraded = await upgradeLegacySession(db, legacy.accountId, legacy.deviceId);
    expect(upgraded.accessToken.startsWith("toj.v2.access.")).toBe(true);
    expect(upgraded.refreshToken.startsWith("toj.v2.refresh.")).toBe(true);
    expect((await resolveDevice(db, upgraded.accessToken)).deviceId).toBe(legacy.deviceId);
    await expect(resolveDevice(db, legacy.token)).rejects.toMatchObject({ code: "device_revoked" });

    const rotationId = crypto.randomUUID();
    const rotated = await refreshV2Session(db, upgraded.refreshToken, rotationId);
    const recovered = await refreshV2Session(db, upgraded.refreshToken, rotationId);
    expect(recovered).toEqual(rotated);
    expect((await resolveDevice(db, rotated.accessToken)).accountId).toBe(legacy.accountId);

    await expect(refreshV2Session(db, upgraded.refreshToken, crypto.randomUUID()))
      .rejects.toMatchObject({ code: "refresh_reuse_detected" });
    await expect(resolveDevice(db, rotated.accessToken))
      .rejects.toMatchObject({ code: "refresh_reuse_detected" });
  });

  test("age decides neither replay nor pruning for a client stuck mid-rotation", async () => {
    const legacy = await legacyAccount("+16505557121");
    const upgraded = await upgradeLegacySession(db, legacy.accountId, legacy.deviceId);
    const rotationId = crypto.randomUUID();
    const rotated = await refreshV2Session(db, upgraded.refreshToken, rotationId);

    // The response was lost and the client returns well past the old five-minute window: a dropped
    // connection on a 100-500 kbps link, or iOS suspending the app. This used to revoke the session
    // as refresh_reuse_detected, drop its push bindings and force a phone re-verification.
    await db`UPDATE session_rotation_receipts SET expires_at = now() - interval '1 minute'`;
    expect(await refreshV2Session(db, upgraded.refreshToken, rotationId)).toEqual(rotated);

    // And maintenance must not bury it either, at a realistic backstop and days of delay.
    await db`UPDATE session_rotation_receipts
      SET expires_at = now() + interval '23 days', created_at = now() - interval '7 days'`;
    await cleanupExpiredData(db);

    expect(await db`SELECT rotation_id FROM session_rotation_receipts`).toHaveLength(1);
    expect(await refreshV2Session(db, upgraded.refreshToken, rotationId)).toEqual(rotated);
    await expect(resolveV2Access(db, rotated.accessToken)).resolves.toMatchObject({
      deviceId: legacy.deviceId,
    });
  });

  test("receipts are pruned by rotation depth, and burial past it is superseded not reuse", async () => {
    const legacy = await legacyAccount("+16505557122");
    const upgraded = await upgradeLegacySession(db, legacy.accountId, legacy.deviceId);
    const rotationId = crypto.randomUUID();
    let session = await refreshV2Session(db, upgraded.refreshToken, rotationId);

    // Only another party rotating the session can bury a stuck client's receipt. Drive the
    // generation past the retained depth, which is the one case that must not replay.
    for (let i = 0; i < ROTATION_RECEIPT_RETAINED_GENERATIONS; i += 1) {
      session = await refreshV2Session(db, session.refreshToken, crypto.randomUUID());
    }
    await cleanupExpiredData(db);

    const surviving = await db`
      SELECT rotation_id FROM session_rotation_receipts WHERE rotation_id = ${rotationId}`;
    expect(surviving).toHaveLength(0);
    await expect(refreshV2Session(db, upgraded.refreshToken, rotationId))
      .rejects.toMatchObject({ code: "refresh_reuse_detected" });
  });

  test("cleanup prunes receipts without locking the live sessions they belong to", async () => {
    const legacy = await legacyAccount("+16505557123");
    const upgraded = await upgradeLegacySession(db, legacy.accountId, legacy.deviceId);
    await refreshV2Session(db, upgraded.refreshToken, crypto.randomUUID());

    // A bare FOR UPDATE across the join would lock device_sessions and contend with refreshes.
    const holder = new Client({ connectionString: TEST_URL });
    await holder.connect();
    try {
      await holder.query("BEGIN");
      await holder.query("SELECT id FROM device_sessions FOR UPDATE");
      await expect(cleanupExpiredData(db)).resolves.toBeDefined();
    } finally {
      await holder.query("ROLLBACK");
      await holder.end();
    }
  });

  test("refresh rejects malformed and cross-generation rotation identifiers without mutation", async () => {
    const legacy = await legacyAccount("+16505557107");
    const upgraded = await upgradeLegacySession(db, legacy.accountId, legacy.deviceId);
    await expect(refreshV2Session(db, upgraded.refreshToken, "------------------------------------"))
      .rejects.toMatchObject({ status: 400, code: "invalid_rotation_id" });

    const rotationId = crypto.randomUUID();
    const first = await refreshV2Session(db, upgraded.refreshToken, rotationId);
    await expect(refreshV2Session(db, first.refreshToken, rotationId))
      .rejects.toMatchObject({ status: 409, code: "rotation_id_reused" });
    const recovered = await refreshV2Session(db, first.refreshToken, crypto.randomUUID());
    expect((await resolveDevice(db, recovered.accessToken)).deviceId).toBe(legacy.deviceId);
  });

  test("late receipts cannot roll credentials backward and in-place reissue fences prior access", async () => {
    const legacy = await legacyAccount("+16505557108");
    const upgraded = await upgradeLegacySession(db, legacy.accountId, legacy.deviceId);
    const firstRotationId = crypto.randomUUID();
    const first = await refreshV2Session(db, upgraded.refreshToken, firstRotationId);
    const second = await refreshV2Session(db, first.refreshToken, crypto.randomUUID());

    await expect(refreshV2Session(db, upgraded.refreshToken, firstRotationId))
      .rejects.toMatchObject({ status: 409, code: "rotation_superseded" });
    await expect(resolveDevice(db, second.accessToken)).resolves.toMatchObject({
      deviceId: legacy.deviceId,
    });

    const reissued = await issueV2Session(db, {
      accountId: legacy.accountId,
      platform: "ios",
      existingDeviceId: legacy.deviceId,
    });
    await expect(resolveDevice(db, second.accessToken))
      .rejects.toMatchObject({ code: "device_revoked" });
    await expect(resolveDevice(db, reissued.accessToken)).resolves.toMatchObject({
      deviceId: legacy.deviceId,
    });
  });

  test("access and absolute expiry boundaries use the injected clock", async () => {
    const legacy = await legacyAccount("+16505557103");
    const base = new Date("2026-08-11T00:00:00.000Z");
    const session = await issueV2Session(db, {
      accountId: legacy.accountId,
      platform: "ios",
      existingDeviceId: legacy.deviceId,
      now: base,
    });
    await expect(resolveV2Access(
      db,
      session.accessToken,
      new Date(base.getTime() + ACCESS_TOKEN_TTL_MS - 1),
    )).resolves.toMatchObject({ deviceId: legacy.deviceId });
    await expect(resolveV2Access(
      db,
      session.accessToken,
      new Date(base.getTime() + ACCESS_TOKEN_TTL_MS),
    )).rejects.toMatchObject({ code: "access_token_expired" });
    await expect(refreshV2Session(
      db,
      session.refreshToken,
      crypto.randomUUID(),
      new Date(base.getTime() + SESSION_ABSOLUTE_TTL_MS),
    )).rejects.toMatchObject({ code: "session_expired" });
  });

  test("password login and SMS-bound recovery rotate codes and revoke older sessions", async () => {
    const phone = "+16505557102";
    const legacy = await legacyAccount(phone);
    const upgraded = await upgradeLegacySession(db, legacy.accountId, legacy.deviceId);

    const security = await startSecurityChange(db, legacy.accountId);
    const stepUp = await completeSecurityStepUp(db, legacy.accountId, security.code!);
    const enabled = await configureTwoFactor(db, {
      accountId: legacy.accountId,
      currentDeviceId: legacy.deviceId,
      stepUpToken: stepUp.stepUpToken,
      password: "correct horse battery staple",
    });
    expect(enabled.recoveryCodes).toHaveLength(10);
    expect(await twoFactorStatus(db, legacy.accountId)).toEqual({
      enabled: true,
      recoveryCodesRemaining: 10,
    });
    await expect(resolveDevice(db, upgraded.accessToken)).rejects.toMatchObject({
      code: "device_revoked",
    });
    await expect(resolveDevice(db, enabled.session.accessToken)).resolves.toMatchObject({
      accountId: legacy.accountId,
    });

    await db`UPDATE otp_challenges SET created_at = created_at - interval '31 seconds'`;
    const nextOTP = await startVerification(db, phone);
    const challenge = await checkVerificationV2(
      db, phone, nextOTP.code!, "ios", "New iPhone", "Alice",
    );
    expect(challenge.state).toBe("two_factor_required");
    if (challenge.state !== "two_factor_required") throw new Error("expected challenge");
    await expect(completeTwoFactorLogin(db, {
      challengeId: challenge.challengeId,
      password: "wrong password",
    })).rejects.toMatchObject({ code: "incorrect_second_factor" });
    const signedIn = await completeTwoFactorLogin(db, {
      challengeId: challenge.challengeId,
      password: "correct horse battery staple",
    });
    expect(signedIn.session.tokenVersion).toBe(2);

    await db`UPDATE otp_challenges SET created_at = created_at - interval '31 seconds'`;
    const recoveryOTP = await startVerification(db, phone);
    const recoveryChallenge = await checkVerificationV2(
      db, phone, recoveryOTP.code!, "ios", "Recovered iPhone", "Alice",
    );
    if (recoveryChallenge.state !== "two_factor_required") throw new Error("expected challenge");
    const recovered = await completeTwoFactorLogin(db, {
      challengeId: recoveryChallenge.challengeId,
      recoveryCode: enabled.recoveryCodes[0],
      newPassword: "a completely different safe password",
    });
    expect(recovered.recoveryCodes).toHaveLength(10);
    expect(recovered.recoveryCodes).not.toEqual(enabled.recoveryCodes);
    await expect(resolveDevice(db, signedIn.session.accessToken))
      .rejects.toMatchObject({ code: "device_revoked" });
  });

  test("rollout rollback keeps enrolled login and issued refresh credentials usable", async () => {
    const originalAuth = process.env.TOJ_AUTH_SESSIONS_V2_ENABLED;
    const originalFactor = process.env.TOJ_TWO_FACTOR_ENABLED;
    process.env.TOJ_AUTH_SESSIONS_V2_ENABLED = "1";
    process.env.TOJ_TWO_FACTOR_ENABLED = "1";
    const phone = "+16505557109";
    const legacy = await legacyAccount(phone);
    const upgraded = await upgradeLegacySession(db, legacy.accountId, legacy.deviceId);
    const security = await startSecurityChange(db, legacy.accountId);
    const stepUp = await completeSecurityStepUp(db, legacy.accountId, security.code!);
    const enabled = await configureTwoFactor(db, {
      accountId: legacy.accountId,
      currentDeviceId: legacy.deviceId,
      stepUpToken: stepUp.stepUpToken,
      password: "rollback safe account password",
    });
    await db`UPDATE otp_challenges SET created_at = created_at - interval '31 seconds'`;
    const nextOTP = await startVerification(db, phone);

    process.env.TOJ_TWO_FACTOR_ENABLED = "0";
    const server = startCloudServer(0, db, null, null, { backgroundWorkers: false });
    try {
      const base = `http://127.0.0.1:${server.port}`;
      const challengeResponse = await fetch(`${base}/v1/auth/check`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          phone,
          code: nextOTP.code,
          authProtocolVersion: 2,
          platform: "ios",
          deviceName: "Rollback iPhone",
        }),
      });
      expect(challengeResponse.status).toBe(200);
      const challenge = await challengeResponse.json() as any;
      expect(challenge.state).toBe("two_factor_required");
      const completion = await fetch(`${base}/v1/auth/two-factor/check`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          challengeId: challenge.challengeId,
          password: "rollback safe account password",
        }),
      });
      expect(completion.status).toBe(200);

      const capabilities = await fetch(`${base}/v1/capabilities`, {
        headers: { authorization: `Bearer ${enabled.session.accessToken}` },
      }).then((response) => response.json()) as any;
      expect(capabilities.capabilities).toContain("two_factor_v1");

      process.env.TOJ_AUTH_SESSIONS_V2_ENABLED = "0";
      const refresh = await fetch(`${base}/v1/session/refresh`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          refreshToken: enabled.session.refreshToken,
          rotationId: crypto.randomUUID(),
        }),
      });
      expect(refresh.status).toBe(200);
      expect((await refresh.json() as any).tokenVersion).toBe(2);
    } finally {
      await server.stop(true);
      if (originalAuth == null) delete process.env.TOJ_AUTH_SESSIONS_V2_ENABLED;
      else process.env.TOJ_AUTH_SESSIONS_V2_ENABLED = originalAuth;
      if (originalFactor == null) delete process.env.TOJ_TWO_FACTOR_ENABLED;
      else process.env.TOJ_TWO_FACTOR_ENABLED = originalFactor;
    }
  });

  test("security step-up locks on the fifth failed SMS attempt", async () => {
    const legacy = await legacyAccount("+16505557104");
    const security = await startSecurityChange(db, legacy.accountId);
    for (let attempt = 1; attempt < 5; attempt += 1) {
      await expect(completeSecurityStepUp(db, legacy.accountId, "000000"))
        .rejects.toMatchObject({ status: 401 });
    }
    await expect(completeSecurityStepUp(db, legacy.accountId, "000000"))
      .rejects.toMatchObject({ status: 429, code: "challenge_locked" });
    await expect(completeSecurityStepUp(db, legacy.accountId, security.code!))
      .rejects.toMatchObject({ status: 429, code: "challenge_locked" });
  });

  test("concurrent recovery consumes an old code exactly once", async () => {
    const phone = "+16505557105";
    const legacy = await legacyAccount(phone);
    const security = await startSecurityChange(db, legacy.accountId);
    const stepUp = await completeSecurityStepUp(db, legacy.accountId, security.code!);
    const enabled = await configureTwoFactor(db, {
      accountId: legacy.accountId,
      currentDeviceId: legacy.deviceId,
      stepUpToken: stepUp.stepUpToken,
      password: "concurrent recovery password",
    });

    async function makeChallenge(deviceName: string) {
      await db`UPDATE otp_challenges SET created_at = created_at - interval '31 seconds'`;
      const otp = await startVerification(db, phone);
      const result = await checkVerificationV2(db, phone, otp.code!, "ios", deviceName, "Alice");
      if (result.state !== "two_factor_required") throw new Error("expected challenge");
      return result.challengeId;
    }

    const firstChallenge = await makeChallenge("Recovery A");
    const secondChallenge = await makeChallenge("Recovery B");
    const attempts = await Promise.allSettled([
      completeTwoFactorLogin(db, {
        challengeId: firstChallenge,
        recoveryCode: enabled.recoveryCodes[0],
        newPassword: "first replacement password",
      }),
      completeTwoFactorLogin(db, {
        challengeId: secondChallenge,
        recoveryCode: enabled.recoveryCodes[0],
        newPassword: "second replacement password",
      }),
    ]);
    expect(attempts.filter((attempt) => attempt.status === "fulfilled")).toHaveLength(1);
    expect(attempts.filter((attempt) => attempt.status === "rejected")).toHaveLength(1);
    expect(await twoFactorStatus(db, legacy.accountId)).toEqual({
      enabled: true,
      recoveryCodesRemaining: 10,
    });
  });

  test("parallel challenges cannot overrun the account-wide attempt budget", async () => {
    const phone = "+16505557110";
    const legacy = await legacyAccount(phone);
    const security = await startSecurityChange(db, legacy.accountId);
    const stepUp = await completeSecurityStepUp(db, legacy.accountId, security.code!);
    await configureTwoFactor(db, {
      accountId: legacy.accountId,
      currentDeviceId: legacy.deviceId,
      stepUpToken: stepUp.stepUpToken,
      password: "account budget concurrency password",
    });

    async function makeChallenge(deviceName: string) {
      await db`UPDATE otp_challenges SET created_at = created_at - interval '31 seconds'`;
      const otp = await startVerification(db, phone);
      const result = await checkVerificationV2(db, phone, otp.code!, "ios", deviceName, "Alice");
      if (result.state !== "two_factor_required") throw new Error("expected challenge");
      return result.challengeId;
    }

    const firstChallenge = await makeChallenge("Budget A");
    const secondChallenge = await makeChallenge("Budget B");
    await db`
      INSERT INTO two_factor_attempt_budgets (account_id)
      SELECT ${legacy.accountId} FROM generate_series(1, 19)`;

    const attempts = await Promise.allSettled([
      completeTwoFactorLogin(db, { challengeId: firstChallenge, password: "wrong password" }),
      completeTwoFactorLogin(db, { challengeId: secondChallenge, password: "wrong password" }),
    ]);
    expect(attempts.every((attempt) => attempt.status === "rejected")).toBe(true);
    const codes = attempts.map((attempt) =>
      attempt.status === "rejected" ? attempt.reason?.code : undefined,
    );
    expect(codes.sort()).toEqual(["challenge_locked", "incorrect_second_factor"]);
    const budget = await db`
      SELECT count(*) AS count FROM two_factor_attempt_budgets
      WHERE account_id = ${legacy.accountId}`;
    expect(Number(budget[0].count)).toBe(20);
  });

  test("recovery codes can be replaced without changing the password", async () => {
    const legacy = await legacyAccount("+16505557106");
    const security = await startSecurityChange(db, legacy.accountId);
    const stepUp = await completeSecurityStepUp(db, legacy.accountId, security.code!);
    const enabled = await configureTwoFactor(db, {
      accountId: legacy.accountId,
      currentDeviceId: legacy.deviceId,
      stepUpToken: stepUp.stepUpToken,
      password: "password retained during regeneration",
    });

    await db`UPDATE otp_challenges SET created_at = created_at - interval '31 seconds'`;
    const nextSecurity = await startSecurityChange(db, legacy.accountId);
    const nextStepUp = await completeSecurityStepUp(db, legacy.accountId, nextSecurity.code!);
    const regenerated = await regenerateTwoFactorRecoveryCodes(db, {
      accountId: legacy.accountId,
      currentDeviceId: legacy.deviceId,
      stepUpToken: nextStepUp.stepUpToken,
      currentCredential: "password retained during regeneration",
    });
    expect(regenerated.recoveryCodes).toHaveLength(10);
    expect(regenerated.recoveryCodes).not.toEqual(enabled.recoveryCodes);
    expect((await resolveDevice(db, regenerated.session.accessToken)).accountId)
      .toBe(legacy.accountId);

    await db`UPDATE otp_challenges SET created_at = created_at - interval '31 seconds'`;
    const disableSecurity = await startSecurityChange(db, legacy.accountId);
    const disableStepUp = await completeSecurityStepUp(
      db,
      legacy.accountId,
      disableSecurity.code!,
    );
    await disableTwoFactor(db, {
      accountId: legacy.accountId,
      currentDeviceId: legacy.deviceId,
      stepUpToken: disableStepUp.stepUpToken,
      currentCredential: "password retained during regeneration",
    });
    expect(await twoFactorStatus(db, legacy.accountId)).toEqual({
      enabled: false,
      recoveryCodesRemaining: 0,
    });
    const remainingCodes = await db`
      SELECT count(*) AS count FROM two_factor_recovery_codes
      WHERE account_id = ${legacy.accountId}`;
    expect(Number(remainingCodes[0].count)).toBe(0);
  });

  test("account deletion publishes committed revocations for every device", async () => {
    const legacy = await legacyAccount("+16505557111");
    const second = await issueV2Session(db, {
      accountId: legacy.accountId,
      platform: "ios",
      deviceName: "Second iPhone",
    });
    const deletion = await startAccountDeletion(db, legacy.accountId);
    if (!deletion.code) throw new Error("missing deletion code");

    const listener = new Client({ connectionString: TEST_URL });
    const received = new Set<string>();
    let resolveAll!: () => void;
    const allReceived = new Promise<void>((resolve) => { resolveAll = resolve; });
    listener.on("notification", (notification) => {
      if (notification.channel !== "toj_session_revocations" || !notification.payload) return;
      const wakeup = JSON.parse(notification.payload) as {
        accountId: string;
        deviceId: string;
        reason: string;
      };
      if (wakeup.accountId !== legacy.accountId || wakeup.reason !== "device_revoked") return;
      received.add(wakeup.deviceId);
      if (received.size === 2) resolveAll();
    });

    try {
      await listener.connect();
      await listener.query("LISTEN toj_session_revocations");
      await deleteAccount(db, legacy.accountId, deletion.code);
      await Promise.race([
        allReceived,
        Bun.sleep(2_000).then(() => { throw new Error("timed out waiting for revocations"); }),
      ]);
      expect(received).toEqual(new Set([legacy.deviceId, second.deviceId]));
    } finally {
      await listener.query("UNLISTEN toj_session_revocations").catch(() => {});
      await listener.end().catch(() => {});
    }
  }, 10_000);
});
