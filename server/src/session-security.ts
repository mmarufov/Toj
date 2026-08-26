import type { SQL } from "bun";
import { randomBytes } from "node:crypto";
import { Client } from "pg";
import { AuthError } from "./auth-error";
import { sessionRotationAAD, tokenHashCandidates, tokenHashIndex } from "./crypto";
import { openForScope, sealForScope } from "./envelope-crypto";
import { revokePushBindingsForDevice } from "./push";

export const ACCESS_TOKEN_TTL_MS = 15 * 60_000;
export const SESSION_IDLE_TTL_MS = 30 * 24 * 60 * 60_000;
export const SESSION_ABSOLUTE_TTL_MS = 180 * 24 * 60 * 60_000;
export const ROTATION_RECEIPT_TTL_MS = 5 * 60_000;
const SESSION_REVOCATION_CHANNEL = "toj_session_revocations";
const ACCESS_TOKEN_PREFIX = "toj.v2.access.";
const REFRESH_TOKEN_PREFIX = "toj.v2.refresh.";
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type AuthV2Session = {
  accountId: string;
  deviceId: string;
  accessToken: string;
  accessTokenExpiresAt: string;
  refreshToken: string;
  sessionExpiresAt: string;
  tokenVersion: 2;
};

type DeviceRegistration = {
  accountId: string;
  platform: string;
  deviceName?: string | null;
  existingDeviceId?: string;
  now?: Date;
};

function token(prefix: string): string {
  return `${prefix}${randomBytes(32).toString("base64url")}`;
}

export function isV2AccessToken(value: string): boolean {
  return value.startsWith(ACCESS_TOKEN_PREFIX);
}

function date(value: unknown): Date {
  return value instanceof Date ? value : new Date(String(value));
}

function responseFromRow(row: any, accessToken: string, refreshToken: string): AuthV2Session {
  return {
    accountId: String(row.account_id),
    deviceId: String(row.device_id),
    accessToken,
    accessTokenExpiresAt: date(row.access_expires_at).toISOString(),
    refreshToken,
    sessionExpiresAt: date(row.absolute_expires_at).toISOString(),
    tokenVersion: 2,
  };
}

/** Issue a v2 device grant. Callers may pass a transaction for atomic login completion. */
export async function issueV2Session(sql: SQL, registration: DeviceRegistration): Promise<AuthV2Session> {
  const now = registration.now ?? new Date();
  const accessToken = token(ACCESS_TOKEN_PREFIX);
  const refreshToken = token(REFRESH_TOKEN_PREFIX);
  const accessExpiresAt = new Date(now.getTime() + ACCESS_TOKEN_TTL_MS);
  const absoluteExpiresAt = new Date(now.getTime() + SESSION_ABSOLUTE_TTL_MS);
  const accessIndex = tokenHashIndex(accessToken);
  const refreshIndex = tokenHashIndex(refreshToken);
  let deviceId = registration.existingDeviceId;
  if (deviceId) {
    // v2 devices authenticate through session_access_tokens, so the legacy column keeps an
    // unusable random digest. It still records the active blind-index key so rotation audits
    // do not see it as an unmigrated 'legacy-v1' row.
    const placeholder = tokenHashIndex(token(ACCESS_TOKEN_PREFIX));
    const updated = await sql`
      UPDATE devices SET auth_scheme = 'v2',
        auth_token_hash = ${placeholder.digest}, auth_token_key_id = ${placeholder.keyId},
        last_seen_at = ${now}
      WHERE id = ${deviceId} AND account_id = ${registration.accountId} AND revoked_at IS NULL
      RETURNING id`;
    if (!updated.length) throw new AuthError("device is no longer active", 401, undefined, "device_revoked");

    // A security change reissues the current device in place. Fence every credential and crash
    // receipt from the previous generation before installing the replacement refresh token. If an
    // old refresh token appears later, retaining its digest in history turns it into an explicit
    // replay instead of an ambiguous "invalid token" response.
    const prior = (await sql`
      SELECT id, refresh_token_hash, refresh_token_hash_key_id
      FROM device_sessions
      WHERE device_id = ${deviceId}
      FOR UPDATE`)[0];
    if (prior) {
      await sql`
        INSERT INTO session_refresh_token_history (token_digest, token_digest_key_id, session_id)
        VALUES (${prior.refresh_token_hash}, ${prior.refresh_token_hash_key_id}, ${prior.id})
        ON CONFLICT (token_digest) DO NOTHING`;
      await sql`DELETE FROM session_access_tokens WHERE session_id = ${prior.id}`;
      await sql`DELETE FROM session_rotation_receipts WHERE session_id = ${prior.id}`;
    }
  } else {
    const placeholder = tokenHashIndex(token(ACCESS_TOKEN_PREFIX));
    const inserted = await sql`
      INSERT INTO devices (
        account_id, platform, device_name, auth_token_hash, auth_token_key_id,
        auth_scheme, last_seen_at
      )
      VALUES (
        ${registration.accountId}, ${registration.platform}, ${registration.deviceName ?? null},
        ${placeholder.digest}, ${placeholder.keyId}, 'v2', ${now}
      ) RETURNING id`;
    deviceId = String(inserted[0].id);
  }

  const session = (await sql`
    INSERT INTO device_sessions (
      device_id, refresh_token_hash, refresh_token_hash_key_id,
      last_activity_at, absolute_expires_at
    )
    VALUES (${deviceId}, ${refreshIndex.digest}, ${refreshIndex.keyId}, ${now}, ${absoluteExpiresAt})
    ON CONFLICT (device_id) DO UPDATE SET
      refresh_token_hash = EXCLUDED.refresh_token_hash,
      refresh_token_hash_key_id = EXCLUDED.refresh_token_hash_key_id,
      rotation_generation = device_sessions.rotation_generation + 1,
      last_activity_at = EXCLUDED.last_activity_at,
      absolute_expires_at = EXCLUDED.absolute_expires_at,
      revoked_at = NULL,
      revocation_reason = NULL
    RETURNING id, device_id, absolute_expires_at`)[0];
  await sql`
    INSERT INTO session_access_tokens (token_digest, token_digest_key_id, session_id, expires_at)
    VALUES (${accessIndex.digest}, ${accessIndex.keyId}, ${session.id}, ${accessExpiresAt})`;
  return responseFromRow({
    account_id: registration.accountId,
    device_id: deviceId,
    access_expires_at: accessExpiresAt,
    absolute_expires_at: session.absolute_expires_at,
  }, accessToken, refreshToken);
}

export async function upgradeLegacySession(
  sql: SQL,
  accountId: string,
  deviceId: string,
): Promise<AuthV2Session> {
  return await sql.begin(async (tx) => issueV2Session(tx, {
    accountId, deviceId, existingDeviceId: deviceId, platform: "ios",
  }));
}

export async function resolveV2Access(
  sql: SQL,
  accessToken: string,
  now = new Date(),
): Promise<{ accountId: string; deviceId: string; accessExpiresAt: Date } | null> {
  const candidates = tokenHashCandidates(accessToken);
  const result = await sql.begin(async (tx) => {
    const rows = await tx`
      SELECT access.id AS access_id, access.token_digest, access.token_digest_key_id,
             access.expires_at AS access_expires_at,
             session.id AS session_id, session.last_activity_at,
             session.absolute_expires_at, session.revoked_at, session.revocation_reason,
             device.id AS device_id, device.account_id, device.revoked_at AS device_revoked_at,
             account.status AS account_status
      FROM session_access_tokens access
      JOIN device_sessions session ON session.id = access.session_id
      JOIN devices device ON device.id = session.device_id
      JOIN accounts account ON account.id = device.account_id
      WHERE access.token_digest IN (
        SELECT decode(value, 'hex') FROM unnest(
          ${tx.array(candidates.map((candidate) => candidate.digest.toString("hex")), "text")}::text[]
        ) AS candidate(value)
      )
      FOR UPDATE OF access, session, device`;
    if (rows.length > 1) {
      return new AuthError("invalid access token", 401, undefined, "device_revoked");
    }
    const row = rows[0];
    if (!row) return null;
    if (row.revoked_at || row.device_revoked_at) {
      throw new AuthError(
        "device is no longer active", 401, undefined,
        row.revocation_reason === "refresh_reuse_detected" ? "refresh_reuse_detected" : "device_revoked",
      );
    }
    if (!["active", "limited"].includes(String(row.account_status))) {
      throw new AuthError("account unavailable", 403, undefined, "device_revoked");
    }
    const idleExpired = date(row.last_activity_at).getTime() + SESSION_IDLE_TTL_MS <= now.getTime();
    const absoluteExpired = date(row.absolute_expires_at) <= now;
    if (idleExpired || absoluteExpired) {
      await revokeSessionRows(tx, String(row.session_id), String(row.device_id), "session_expired", now);
      return new AuthError("session expired", 401, undefined, "session_expired");
    }
    if (date(row.access_expires_at) <= now) {
      return new AuthError("access token expired", 401, undefined, "access_token_expired");
    }
    await tx`UPDATE device_sessions SET last_activity_at = ${now} WHERE id = ${row.session_id}`;
    await tx`UPDATE devices SET last_seen_at = ${now} WHERE id = ${row.device_id}`;
    const active = tokenHashIndex(accessToken);
    if (String(row.token_digest_key_id) !== active.keyId) {
      await tx`UPDATE session_access_tokens
        SET token_digest = ${active.digest}, token_digest_key_id = ${active.keyId}
        WHERE id = ${row.access_id} AND token_digest = ${row.token_digest}`;
    }
    return {
      accountId: String(row.account_id),
      deviceId: String(row.device_id),
      accessExpiresAt: date(row.access_expires_at),
    };
  });
  if (result instanceof AuthError) throw result;
  return result;
}

export async function refreshV2Session(
  sql: SQL,
  refreshToken: string,
  rotationId: string,
  now = new Date(),
): Promise<AuthV2Session> {
  if (!UUID_PATTERN.test(rotationId)) {
    throw new AuthError("valid rotationId required", 400, undefined, "invalid_rotation_id");
  }
  const requestCandidates = tokenHashCandidates(refreshToken);
  const outcome = await sql.begin(async (tx) => {
    const currentRows = await tx`
      SELECT session.*, device.account_id, device.id AS device_id, device.revoked_at AS device_revoked_at
      FROM device_sessions session
      JOIN devices device ON device.id = session.device_id
      WHERE session.refresh_token_hash IN (
        SELECT decode(value, 'hex') FROM unnest(
          ${tx.array(requestCandidates.map((candidate) => candidate.digest.toString("hex")), "text")}::text[]
        ) AS candidate(value)
      )
      FOR UPDATE OF session, device`;
    if (currentRows.length > 1) {
      return new AuthError("invalid refresh token", 401, undefined, "device_revoked");
    }
    const current = currentRows[0];
    if (!current) {
      const usedRows = await tx`
        SELECT history.session_id, history.token_digest, history.token_digest_key_id
        FROM session_refresh_token_history history
        WHERE history.token_digest IN (
          SELECT decode(value, 'hex') FROM unnest(
            ${tx.array(requestCandidates.map((candidate) => candidate.digest.toString("hex")), "text")}::text[]
          ) AS candidate(value)
        )`;
      if (usedRows.length > 1) {
        return new AuthError("invalid refresh token", 401, undefined, "device_revoked");
      }
      const used = usedRows[0];
      if (!used) return new AuthError("invalid refresh token", 401, undefined, "device_revoked");
      const receipt = (await tx`
        SELECT receipt.response_ciphertext, receipt.response_nonce, receipt.response_key_id,
               receipt.response_generation, session.rotation_generation AS current_generation,
               device.account_id
        FROM session_rotation_receipts receipt
        JOIN device_sessions session ON session.id = receipt.session_id
        JOIN devices device ON device.id = session.device_id
        WHERE receipt.session_id = ${used.session_id} AND receipt.rotation_id = ${rotationId}
          AND receipt.request_token_digest = ${used.token_digest}
          AND receipt.request_token_digest_key_id = ${used.token_digest_key_id}
          AND receipt.expires_at > ${now}`)[0];
      if (receipt) {
        if (Number(receipt.response_generation) !== Number(receipt.current_generation)) {
          return new AuthError(
            "refresh response was superseded by a newer rotation",
            409,
            undefined,
            "rotation_superseded",
          );
        }
        const plaintext = await openForScope(tx, {
          kind: "account", accountId: String(receipt.account_id),
        }, {
          ciphertext: Buffer.from(receipt.response_ciphertext),
          nonce: Buffer.from(receipt.response_nonce),
          keyId: String(receipt.response_key_id),
        }, sessionRotationAAD(String(used.session_id), rotationId));
        try {
          return JSON.parse(plaintext.toString("utf8")) as AuthV2Session;
        } finally {
          plaintext.fill(0);
        }
      }
      const session = (await tx`SELECT device_id FROM device_sessions WHERE id = ${used.session_id} FOR UPDATE`)[0];
      if (session) {
        await revokeSessionRows(
          tx, String(used.session_id), String(session.device_id), "refresh_reuse_detected", now,
        );
      }
      return new AuthError("refresh token reuse detected", 401, undefined, "refresh_reuse_detected");
    }

    if (current.revoked_at || current.device_revoked_at) {
      return new AuthError("device is no longer active", 401, undefined, "device_revoked");
    }
    if (
      date(current.absolute_expires_at) <= now
      || date(current.last_activity_at).getTime() + SESSION_IDLE_TTL_MS <= now.getTime()
    ) {
      await revokeSessionRows(tx, String(current.id), String(current.device_id), "session_expired", now);
      return new AuthError("session expired", 401, undefined, "session_expired");
    }

    const reusedRotation = (await tx`
      SELECT 1 FROM session_rotation_receipts
      WHERE session_id = ${current.id} AND rotation_id = ${rotationId}`)[0];
    if (reusedRotation) {
      return new AuthError(
        "rotation id was already used",
        409,
        undefined,
        "rotation_id_reused",
      );
    }

    const nextAccess = token(ACCESS_TOKEN_PREFIX);
    const nextRefresh = token(REFRESH_TOKEN_PREFIX);
    const nextAccessIndex = tokenHashIndex(nextAccess);
    const nextRefreshIndex = tokenHashIndex(nextRefresh);
    const accessExpiresAt = new Date(now.getTime() + ACCESS_TOKEN_TTL_MS);
    await tx`
      INSERT INTO session_refresh_token_history (token_digest, token_digest_key_id, session_id)
      VALUES (${current.refresh_token_hash}, ${current.refresh_token_hash_key_id}, ${current.id})`;
    await tx`
      UPDATE device_sessions SET
        refresh_token_hash = ${nextRefreshIndex.digest},
        refresh_token_hash_key_id = ${nextRefreshIndex.keyId},
        rotation_generation = rotation_generation + 1,
        last_activity_at = ${now}
      WHERE id = ${current.id}`;
    await tx`
      INSERT INTO session_access_tokens (token_digest, token_digest_key_id, session_id, expires_at)
      VALUES (${nextAccessIndex.digest}, ${nextAccessIndex.keyId}, ${current.id}, ${accessExpiresAt})`;
    const response = responseFromRow({
      account_id: current.account_id,
      device_id: current.device_id,
      access_expires_at: accessExpiresAt,
      absolute_expires_at: current.absolute_expires_at,
    }, nextAccess, nextRefresh);
    const sealed = await sealForScope(
      tx,
      { kind: "account", accountId: String(current.account_id) },
      JSON.stringify(response),
      sessionRotationAAD(String(current.id), rotationId),
    );
    await tx`
      INSERT INTO session_rotation_receipts
        (session_id, rotation_id, request_token_digest, request_token_digest_key_id, response_ciphertext,
         response_nonce, response_key_id, response_generation, expires_at)
      VALUES (
        ${current.id}, ${rotationId}, ${current.refresh_token_hash},
        ${current.refresh_token_hash_key_id}, ${sealed.ciphertext},
        ${sealed.nonce}, ${sealed.keyId}, ${Number(current.rotation_generation) + 1},
        ${new Date(now.getTime() + ROTATION_RECEIPT_TTL_MS)}
      )`;
    return response;
  });
  if (outcome instanceof AuthError) throw outcome;
  return outcome;
}

export async function revokeV2SessionForDevice(
  sql: SQL,
  accountId: string,
  deviceId: string,
  reason = "device_revoked",
): Promise<void> {
  await sql.begin(async (tx) => {
    await tx`SELECT id FROM accounts WHERE id = ${accountId} FOR UPDATE`;
    const row = (await tx`
      SELECT session.id
      FROM device_sessions session
      JOIN devices device ON device.id = session.device_id
      WHERE device.id = ${deviceId} AND device.account_id = ${accountId}
      FOR UPDATE OF session, device`)[0];
    if (row) await revokeSessionRows(tx, String(row.id), deviceId, reason, new Date());
  });
}

async function revokeSessionRows(
  sql: SQL,
  sessionId: string,
  deviceId: string,
  reason: string,
  now: Date,
): Promise<void> {
  await sql`
    UPDATE device_sessions SET revoked_at = COALESCE(revoked_at, ${now}), revocation_reason = ${reason}
    WHERE id = ${sessionId}`;
  const devices = await sql`
    UPDATE devices SET
      revoked_at = COALESCE(revoked_at, ${now}),
      push_token_hash = NULL, push_token_hash_key_id = NULL,
      push_token_ciphertext = NULL, push_token_nonce = NULL,
      push_token_key_id = NULL, push_environment = NULL, push_updated_at = ${now},
      voip_push_token_hash = NULL, voip_push_token_hash_key_id = NULL,
      voip_push_token_ciphertext = NULL,
      voip_push_token_nonce = NULL, voip_push_token_key_id = NULL,
      voip_push_environment = NULL, voip_push_updated_at = ${now}
    WHERE id = ${deviceId}
    RETURNING account_id`;
  await revokePushBindingsForDevice(sql, deviceId);
  if (devices[0]?.account_id) await notifySessionRevocation(
    sql,
    String(devices[0].account_id),
    deviceId,
    reason,
  );
}

export type SessionRevocationWakeup = {
  accountId: string;
  deviceId: string;
  reason: string;
};

export async function notifySessionRevocation(
  sql: SQL,
  accountId: string,
  deviceId: string,
  reason: string,
): Promise<void> {
  const payload = JSON.stringify({ accountId, deviceId, reason });
  // PostgreSQL delivers NOTIFY only if this transaction commits, so a remote process can
  // never close a socket for a revocation that later rolls back.
  await sql`SELECT pg_notify(${SESSION_REVOCATION_CHANNEL}, ${payload})`;
}

/** Reconnectable, hint-only listener used to close revoked device sockets across instances. */
export function startSessionRevocationListener(
  databaseUrl: string | null,
  onRevocation: (wakeup: SessionRevocationWakeup) => void | Promise<void>,
): () => void {
  if (!databaseUrl) return () => {};
  let stopped = false;
  let client: Client | null = null;
  let retry: ReturnType<typeof setTimeout> | null = null;
  let attempts = 0;

  const schedule = () => {
    if (stopped || retry) return;
    const delay = Math.min(30_000, 500 * 2 ** Math.min(attempts, 6));
    attempts += 1;
    retry = setTimeout(() => { retry = null; void connect(); }, delay);
    retry.unref?.();
  };
  const connect = async () => {
    if (stopped) return;
    const next = new Client({
      connectionString: databaseUrl,
      application_name: "toj-session-revocation-notify",
    });
    client = next;
    next.on("notification", (notification) => {
      if (notification.channel !== SESSION_REVOCATION_CHANNEL || !notification.payload) return;
      try {
        const wakeup = JSON.parse(notification.payload) as SessionRevocationWakeup;
        if (!UUID_PATTERN.test(wakeup.accountId) || !UUID_PATTERN.test(wakeup.deviceId)) return;
        if (!["device_revoked", "session_expired", "refresh_reuse_detected", "security_change"]
          .includes(wakeup.reason)) return;
        void onRevocation(wakeup);
      } catch { /* notification hints are never authoritative */ }
    });
    let handledDisconnect = false;
    const disconnected = () => {
      if (handledDisconnect) return;
      handledDisconnect = true;
      if (client !== next) return;
      client = null;
      schedule();
    };
    next.once("error", disconnected);
    next.once("end", disconnected);
    try {
      await next.connect();
      await next.query(`LISTEN ${SESSION_REVOCATION_CHANNEL}`);
      attempts = 0;
    } catch {
      try { await next.end(); } catch { /* already closed */ }
      disconnected();
    }
  };
  void connect();
  return () => {
    stopped = true;
    if (retry) clearTimeout(retry);
    retry = null;
    if (client) void client.end().catch(() => {});
    client = null;
  };
}
