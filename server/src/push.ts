import type { SQL } from "bun";
import {
  connect,
  constants,
  type ClientHttp2Session,
  type IncomingHttpHeaders,
} from "node:http2";
import { createPrivateKey, sign } from "node:crypto";
import {
  installationPushTokenAAD,
  pushTokenAAD,
  tokenHashCandidates,
  tokenHashIndex,
  voipPushTokenAAD,
} from "./crypto";
import { CryptoUnavailableError, openForScope, sealForScope } from "./envelope-crypto";
import {
  CallVersionCapabilityError,
  normalizeCallVersionCapabilities,
} from "./call-versions";

export type PushEnvironment = "sandbox" | "production";

/** Installation push credentials are shared across every account bound to the installation. */
const INSTALLATION_PUSH_SCOPE = { kind: "service", serviceName: "push-installation" } as const;

export class PushError extends Error {}

const TOKEN_MIN_BYTES = 16;
const TOKEN_MAX_BYTES = 512;
const MAX_ATTEMPTS = 8;
const CLAIM_TIMEOUT_SECONDS = 5 * 60;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function normalizeDeviceToken(value: string): string {
  const token = value.trim().toLowerCase();
  if (!/^[0-9a-f]+$/.test(token) || token.length % 2 !== 0) {
    throw new PushError("invalid APNs device token");
  }
  const bytes = token.length / 2;
  if (bytes < TOKEN_MIN_BYTES || bytes > TOKEN_MAX_BYTES) {
    throw new PushError("invalid APNs device token length");
  }
  return token;
}

function validateEnvironment(value: string): PushEnvironment {
  if (value === "sandbox" || value === "production") return value;
  throw new PushError("invalid APNs environment");
}

function normalizeGroupCallCapabilities(
  rawVersions: unknown,
  rawViewVersion: unknown,
  rawSupportsScreenShare: unknown,
): { versions: number[]; viewVersion: number; supportsScreenShare: boolean } {
  let versions: number[];
  if (rawVersions == null) {
    versions = [];
  } else if (Array.isArray(rawVersions) && rawVersions.length === 0) {
    // Unlike an authenticated 1:1 negotiation offer, a device capability set may be empty so a
    // downgraded or failed runtime self-check can explicitly revoke stale server-side support.
    versions = [];
  } else {
    try {
      versions = normalizeCallVersionCapabilities(rawVersions);
    } catch (error) {
      if (error instanceof CallVersionCapabilityError) throw new PushError(error.message);
      throw error;
    }
  }
  const viewVersion = rawViewVersion == null ? 0 : Number(rawViewVersion);
  if (!Number.isSafeInteger(viewVersion) || viewVersion < 0 || viewVersion > 0xffff) {
    throw new PushError("invalid group call view version");
  }
  const supportsScreenShare = rawSupportsScreenShare === true;
  if ((viewVersion > 0 || supportsScreenShare) && !versions.includes(1)) {
    throw new PushError("group call view capabilities require group call version 1");
  }
  if (versions.includes(1) && viewVersion < 1) {
    throw new PushError("group call version 1 requires group call view version 1");
  }
  return { versions, viewVersion, supportsScreenShare };
}

export async function registerPushToken(
  sql: SQL,
  deviceId: string,
  rawToken: string,
  rawEnvironment: string,
): Promise<{ registered: true }> {
  const token = normalizeDeviceToken(rawToken);
  const environment = validateEnvironment(rawEnvironment);
  const tokenInput = `apns|${environment}|${token}`;
  const tokenIndex = tokenHashIndex(tokenInput);
  const tokenHashes = tokenHashCandidates(tokenInput).map((candidate) => candidate.digest);
  const registrationLocks = tokenHashes.map((candidate) => candidate.readBigInt64BE(0))
    .sort((left, right) => left < right ? -1 : left > right ? 1 : 0);
  await sql.begin(async (tx) => {
    // Serialize ownership changes for this token, then lock every affected device in stable UUID
    // order. The ordering also prevents two concurrent token swaps from deadlocking.
    for (const lock of registrationLocks) await tx`SELECT pg_advisory_xact_lock(${lock})`;
    const devices = await tx`
      SELECT id, account_id, platform, revoked_at FROM devices
      WHERE id = ${deviceId}
         OR (push_environment = ${environment}
           AND push_token_hash IN (
             SELECT decode(value, 'hex') FROM unnest(
               ${tx.array(tokenHashes.map((hash) => hash.toString("hex")), "text")}::text[]
             ) AS candidate(value)
           ))
      ORDER BY id
      FOR UPDATE`;
    const device = devices.find((row: {
      id: string; account_id: string; platform: string; revoked_at: unknown;
    }) => row.id === deviceId);
    if (!device || device.platform !== "ios" || device.revoked_at) {
      throw new PushError("active iOS device required");
    }
    const sealed = await sealForScope(
      tx,
      { kind: "account", accountId: device.account_id },
      token,
      pushTokenAAD(deviceId),
    );

    // APNs can reassign a token after restore/reinstall. Transfer ownership atomically instead of
    // letting a stale device keep receiving another installation's notifications.
    await tx`
      UPDATE devices SET
        push_token_hash = NULL,
        push_token_hash_key_id = NULL,
        push_token_ciphertext = NULL,
        push_token_nonce = NULL,
        push_token_key_id = NULL,
        push_environment = NULL,
        push_updated_at = now()
      WHERE id <> ${deviceId}
        AND push_environment = ${environment}
        AND push_token_hash IN (
          SELECT decode(value, 'hex') FROM unnest(
            ${tx.array(tokenHashes.map((hash) => hash.toString("hex")), "text")}::text[]
          ) AS candidate(value)
        )`;

    await tx`
      UPDATE devices SET
        push_token_hash = ${tokenIndex.digest},
        push_token_hash_key_id = ${tokenIndex.keyId},
        push_token_ciphertext = ${sealed.ciphertext},
        push_token_nonce = ${sealed.nonce},
        push_token_key_id = ${sealed.keyId},
        push_environment = ${environment},
        push_updated_at = now()
      WHERE id = ${deviceId}`;
  });
  return { registered: true };
}

export async function unregisterPushToken(sql: SQL, deviceId: string): Promise<{ registered: false }> {
  await sql`
    UPDATE devices SET
      push_token_hash = NULL,
      push_token_hash_key_id = NULL,
      push_token_ciphertext = NULL,
      push_token_nonce = NULL,
      push_token_key_id = NULL,
      push_environment = NULL,
      push_updated_at = now()
    WHERE id = ${deviceId}`;
  return { registered: false };
}

export async function registerVoIPPushToken(
  sql: SQL,
  deviceId: string,
  rawToken: string,
  rawEnvironment: string,
  rawSupportedCallProtocolVersions?: unknown,
  rawSupportedCallMediaProfileVersions?: unknown,
  rawCallViewVersion?: unknown,
  rawSupportedGroupCallVersions?: unknown,
  rawGroupCallViewVersion?: unknown,
  rawSupportsGroupScreenShare?: unknown,
): Promise<{ registered: true; supportedCallProtocolVersions: number[];
  supportedCallMediaProfileVersions: number[]; callViewVersion: number;
  supportedGroupCallVersions: number[]; groupCallViewVersion: number;
  supportsGroupScreenShare: boolean }> {
  const token = normalizeDeviceToken(rawToken);
  const environment = validateEnvironment(rawEnvironment);
  const tokenInput = `apns-voip|${environment}|${token}`;
  const tokenIndex = tokenHashIndex(tokenInput);
  const tokenHashes = tokenHashCandidates(tokenInput).map((candidate) => candidate.digest);
  const registrationLocks = tokenHashes.map((candidate) => candidate.readBigInt64BE(0))
    .sort((left, right) => left < right ? -1 : left > right ? 1 : 0);
  // Omitted values are a legacy registration, not a partial update. Resetting to profile 1
  // prevents stale video capability from surviving an app downgrade or restore.
  let supportedCallProtocolVersions: number[];
  let supportedCallMediaProfileVersions: number[];
  let supportedGroupCallVersions: number[];
  try {
    supportedCallProtocolVersions = normalizeCallVersionCapabilities(rawSupportedCallProtocolVersions);
    supportedCallMediaProfileVersions = normalizeCallVersionCapabilities(rawSupportedCallMediaProfileVersions);
  } catch (error) {
    if (error instanceof CallVersionCapabilityError) {
      throw new PushError(error.message);
    }
    throw error;
  }
  const callViewVersion = rawCallViewVersion == null ? 1 : Number(rawCallViewVersion);
  if (!Number.isSafeInteger(callViewVersion) || callViewVersion < 1 || callViewVersion > 0xffff) {
    throw new PushError("invalid call view version");
  }
  const groupCapabilities = normalizeGroupCallCapabilities(
    rawSupportedGroupCallVersions,
    rawGroupCallViewVersion,
    rawSupportsGroupScreenShare,
  );
  supportedGroupCallVersions = groupCapabilities.versions;
  const groupCallViewVersion = groupCapabilities.viewVersion;
  const supportsGroupScreenShare = groupCapabilities.supportsScreenShare;

  await sql.begin(async (tx) => {
    for (const lock of registrationLocks) await tx`SELECT pg_advisory_xact_lock(${lock})`;
    const devices = await tx`
      SELECT id, account_id, platform, revoked_at FROM devices
      WHERE id = ${deviceId}
         OR (voip_push_environment = ${environment}
           AND voip_push_token_hash IN (
             SELECT decode(value, 'hex') FROM unnest(
               ${tx.array(tokenHashes.map((hash) => hash.toString("hex")), "text")}::text[]
             ) AS candidate(value)
           ))
      ORDER BY id FOR UPDATE`;
    const device = devices.find((row: {
      id: string; account_id: string; platform: string; revoked_at: unknown;
    }) => row.id === deviceId);
    if (!device || device.platform !== "ios" || device.revoked_at) {
      throw new PushError("active iOS device required");
    }
    const sealed = await sealForScope(
      tx,
      { kind: "account", accountId: device.account_id },
      token,
      voipPushTokenAAD(deviceId),
    );
    await tx`
      UPDATE devices SET
        voip_push_token_hash = NULL, voip_push_token_hash_key_id = NULL,
        voip_push_token_ciphertext = NULL,
        voip_push_token_nonce = NULL, voip_push_token_key_id = NULL,
        voip_push_environment = NULL, voip_push_updated_at = now()
      WHERE id <> ${deviceId}
        AND voip_push_environment = ${environment}
        AND voip_push_token_hash IN (
          SELECT decode(value, 'hex') FROM unnest(
            ${tx.array(tokenHashes.map((hash) => hash.toString("hex")), "text")}::text[]
          ) AS candidate(value)
        )`;
    await tx`
      UPDATE devices SET
        voip_push_token_hash = ${tokenIndex.digest},
        voip_push_token_hash_key_id = ${tokenIndex.keyId},
        voip_push_token_ciphertext = ${sealed.ciphertext},
        voip_push_token_nonce = ${sealed.nonce}, voip_push_token_key_id = ${sealed.keyId},
        voip_push_environment = ${environment}, voip_push_updated_at = now(),
        supported_call_protocol_versions = ${tx.array(supportedCallProtocolVersions, "INT4")},
        supported_call_media_profile_versions = ${tx.array(supportedCallMediaProfileVersions, "INT4")},
        call_view_version = ${callViewVersion},
        supported_group_call_versions = ${tx.array(supportedGroupCallVersions, "INT4")},
        group_call_view_version = ${groupCallViewVersion},
        supports_group_screen_share = ${supportsGroupScreenShare}
      WHERE id = ${deviceId}`;
  });
  return {
    registered: true,
    supportedCallProtocolVersions,
    supportedCallMediaProfileVersions,
    callViewVersion,
    supportedGroupCallVersions,
    groupCallViewVersion,
    supportsGroupScreenShare,
  };
}

export async function unregisterVoIPPushToken(sql: SQL, deviceId: string): Promise<{ registered: false }> {
  await sql`
    UPDATE devices SET
      voip_push_token_hash = NULL, voip_push_token_hash_key_id = NULL,
      voip_push_token_ciphertext = NULL,
      voip_push_token_nonce = NULL, voip_push_token_key_id = NULL,
      voip_push_environment = NULL, voip_push_updated_at = now()
    WHERE id = ${deviceId}`;
  return { registered: false };
}

type InstallationPushRegistration = {
  accountId: string;
  deviceId: string;
  installationId: string;
  token: string;
  environment: string;
  kind: "normal" | "voip";
};

function rethrowInstallationRegistrationError(error: unknown): never {
  if (
    error && typeof error === "object"
    && [String((error as any).code ?? ""), String((error as any).errno ?? "")]
      .includes("23514")
    && String((error as any).message ?? "").includes("at most three active accounts")
  ) {
    throw new PushError("installation may bind at most three active accounts");
  }
  throw error;
}

async function registerInstallationPushTokenInTransaction(
  tx: SQL,
  input: InstallationPushRegistration,
): Promise<{ registered: true; routingHandle: string }> {
  if (!UUID_PATTERN.test(input.installationId)) {
    throw new PushError("invalid installation id");
  }
  const token = normalizeDeviceToken(input.token);
  const environment = validateEnvironment(input.environment);
  const tokenInput = `apns-installation-${input.kind}|${environment}|${token}`;
  const tokenIndex = tokenHashIndex(tokenInput);
  const tokenHashes = tokenHashCandidates(tokenInput).map((candidate) => candidate.digest);
  const tokenHashPredicate = tx.array(
    tokenHashes.map((hash) => hash.toString("hex")),
    "text",
  );
  // One installation credential is shared by every account bound to it, so it is sealed under a
  // service scope rather than the registering account's key. Account scoping would leave the
  // other bindings unable to decrypt the same ciphertext.
  const sealed = await sealForScope(
    tx,
    INSTALLATION_PUSH_SCOPE,
    token,
    installationPushTokenAAD(input.installationId, input.kind),
  );
  // Registration is rare and ownership changes touch two unique token indexes plus bindings.
  // A single catalog lock prevents opposing token swaps from deadlocking and makes transfers
  // deterministic across application versions.
  await tx`SELECT pg_advisory_xact_lock(hashtextextended('push-installation-registration-v1', 0))`;
  const device = (await tx`
    SELECT id FROM devices
    WHERE id = ${input.deviceId} AND account_id = ${input.accountId}
      AND platform = 'ios' AND revoked_at IS NULL
    FOR UPDATE`)[0];
  if (!device) throw new PushError("active iOS device required");

  if (input.kind === "normal") {
    await tx`
      DELETE FROM push_account_bindings binding
      USING push_installations installation
      WHERE binding.installation_id = installation.installation_id
        AND installation.installation_id <> ${input.installationId}
        AND installation.normal_environment = ${environment}
        AND installation.normal_token_hash IN (
          SELECT decode(value, 'hex') FROM unnest(${tokenHashPredicate}::text[])
            AS candidate(value)
        )
        AND NOT binding.voip_enabled`;
    await tx`
      UPDATE push_account_bindings binding SET normal_enabled = FALSE, updated_at = now()
      FROM push_installations installation
      WHERE binding.installation_id = installation.installation_id
        AND installation.installation_id <> ${input.installationId}
        AND installation.normal_environment = ${environment}
        AND installation.normal_token_hash IN (
          SELECT decode(value, 'hex') FROM unnest(${tokenHashPredicate}::text[])
            AS candidate(value)
        )
        AND binding.voip_enabled`;
    await tx`
      UPDATE push_installations SET
        normal_token_hash = NULL, normal_token_hash_key_id = NULL,
        normal_token_ciphertext = NULL, normal_token_nonce = NULL,
        normal_token_key_id = NULL, normal_environment = NULL, updated_at = now()
      WHERE installation_id <> ${input.installationId}
        AND normal_environment = ${environment}
        AND normal_token_hash IN (
          SELECT decode(value, 'hex') FROM unnest(${tokenHashPredicate}::text[])
            AS candidate(value)
        )`;
    await tx`
      INSERT INTO push_installations (
        installation_id, normal_token_hash, normal_token_hash_key_id,
        normal_token_ciphertext, normal_token_nonce,
        normal_token_key_id, normal_environment
      ) VALUES (
        ${input.installationId}, ${tokenIndex.digest}, ${tokenIndex.keyId},
        ${sealed.ciphertext}, ${sealed.nonce},
        ${sealed.keyId}, ${environment}
      )
      ON CONFLICT (installation_id) DO UPDATE SET
        normal_token_hash = excluded.normal_token_hash,
        normal_token_hash_key_id = excluded.normal_token_hash_key_id,
        normal_token_ciphertext = excluded.normal_token_ciphertext,
        normal_token_nonce = excluded.normal_token_nonce,
        normal_token_key_id = excluded.normal_token_key_id,
        normal_environment = excluded.normal_environment,
        updated_at = now()`;
  } else {
    await tx`
      DELETE FROM push_account_bindings binding
      USING push_installations installation
      WHERE binding.installation_id = installation.installation_id
        AND installation.installation_id <> ${input.installationId}
        AND installation.voip_environment = ${environment}
        AND installation.voip_token_hash IN (
          SELECT decode(value, 'hex') FROM unnest(${tokenHashPredicate}::text[])
            AS candidate(value)
        )
        AND NOT binding.normal_enabled`;
    await tx`
      UPDATE push_account_bindings binding SET voip_enabled = FALSE, updated_at = now()
      FROM push_installations installation
      WHERE binding.installation_id = installation.installation_id
        AND installation.installation_id <> ${input.installationId}
        AND installation.voip_environment = ${environment}
        AND installation.voip_token_hash IN (
          SELECT decode(value, 'hex') FROM unnest(${tokenHashPredicate}::text[])
            AS candidate(value)
        )
        AND binding.normal_enabled`;
    await tx`
      UPDATE push_installations SET
        voip_token_hash = NULL, voip_token_hash_key_id = NULL,
        voip_token_ciphertext = NULL, voip_token_nonce = NULL,
        voip_token_key_id = NULL, voip_environment = NULL, updated_at = now()
      WHERE installation_id <> ${input.installationId}
        AND voip_environment = ${environment}
        AND voip_token_hash IN (
          SELECT decode(value, 'hex') FROM unnest(${tokenHashPredicate}::text[])
            AS candidate(value)
        )`;
    await tx`
      INSERT INTO push_installations (
        installation_id, voip_token_hash, voip_token_hash_key_id,
        voip_token_ciphertext, voip_token_nonce,
        voip_token_key_id, voip_environment
      ) VALUES (
        ${input.installationId}, ${tokenIndex.digest}, ${tokenIndex.keyId},
        ${sealed.ciphertext}, ${sealed.nonce},
        ${sealed.keyId}, ${environment}
      )
      ON CONFLICT (installation_id) DO UPDATE SET
        voip_token_hash = excluded.voip_token_hash,
        voip_token_hash_key_id = excluded.voip_token_hash_key_id,
        voip_token_ciphertext = excluded.voip_token_ciphertext,
        voip_token_nonce = excluded.voip_token_nonce,
        voip_token_key_id = excluded.voip_token_key_id,
        voip_environment = excluded.voip_environment,
        updated_at = now()`;
  }
  await tx`
    DELETE FROM push_account_bindings
    WHERE device_id = ${input.deviceId}
      AND (installation_id <> ${input.installationId} OR account_id <> ${input.accountId})`;
  const binding = (await tx`
    INSERT INTO push_account_bindings (
      installation_id, account_id, device_id, active, normal_enabled, voip_enabled
    ) VALUES (
      ${input.installationId}, ${input.accountId}, ${input.deviceId}, TRUE,
      ${input.kind === "normal"}, ${input.kind === "voip"}
    )
    ON CONFLICT (installation_id, account_id) DO UPDATE SET
      device_id = excluded.device_id,
      active = TRUE,
      normal_enabled = push_account_bindings.normal_enabled OR excluded.normal_enabled,
      voip_enabled = push_account_bindings.voip_enabled OR excluded.voip_enabled,
      updated_at = now()
    RETURNING routing_handle`)[0];
  if (input.kind === "normal") {
    await tx`
      UPDATE devices SET
        push_token_hash = NULL, push_token_hash_key_id = NULL,
        push_token_ciphertext = NULL, push_token_nonce = NULL,
        push_token_key_id = NULL, push_environment = NULL, push_updated_at = now()
      WHERE id = ${input.deviceId}`;
  } else {
    await tx`
      UPDATE devices SET
        voip_push_token_hash = NULL, voip_push_token_hash_key_id = NULL,
        voip_push_token_ciphertext = NULL,
        voip_push_token_nonce = NULL, voip_push_token_key_id = NULL,
        voip_push_environment = NULL, voip_push_updated_at = now()
      WHERE id = ${input.deviceId}`;
  }
  return { registered: true, routingHandle: String(binding.routing_handle) };
}

export async function registerInstallationPushToken(
  sql: SQL,
  input: InstallationPushRegistration,
): Promise<{ registered: true; routingHandle: string }> {
  try {
    return await sql.begin(async (tx) =>
      await registerInstallationPushTokenInTransaction(tx, input)
    );
  } catch (error) {
    rethrowInstallationRegistrationError(error);
  }
}

export async function unregisterInstallationPushBinding(
  sql: SQL,
  accountId: string,
  deviceId: string,
  installationId: string,
): Promise<{ registered: false }> {
  if (!UUID_PATTERN.test(installationId)) throw new PushError("invalid installation id");
  await sql.begin(async (tx) => {
    await tx`SELECT id FROM accounts WHERE id = ${accountId} FOR UPDATE`;
    await tx`SELECT pg_advisory_xact_lock(hashtextextended('push-installation-registration-v1', 0))`;
    await tx`
      DELETE FROM push_account_bindings
      WHERE installation_id = ${installationId} AND account_id = ${accountId}
        AND device_id = ${deviceId}`;
    await tx`
      DELETE FROM push_installations installation
      WHERE installation.installation_id = ${installationId}
        AND NOT EXISTS (
          SELECT 1 FROM push_account_bindings binding
          WHERE binding.installation_id = installation.installation_id
        )`;
  });
  return { registered: false };
}

/** Remove every installation route for a device that has already been revoked in this transaction. */
export async function revokePushBindingsForDevice(sql: SQL, deviceId: string): Promise<void> {
  const removed = await sql`
    DELETE FROM push_account_bindings
    WHERE device_id = ${deviceId}
    RETURNING installation_id`;
  if (!removed.length) return;
  const installationIds = [...new Set(removed.map((row: any) => String(row.installation_id)))];
  await sql`
    DELETE FROM push_installations installation
    WHERE installation.installation_id IN ${sql(installationIds)}
      AND NOT EXISTS (
        SELECT 1 FROM push_account_bindings binding
        WHERE binding.installation_id = installation.installation_id
      )`;
}

export async function unregisterInstallationTokenKind(
  sql: SQL,
  accountId: string,
  deviceId: string,
  installationId: string,
  kind: "normal" | "voip",
): Promise<{ registered: false }> {
  if (!UUID_PATTERN.test(installationId)) throw new PushError("invalid installation id");
  await sql.begin(async (tx) => {
    await tx`SELECT id FROM accounts WHERE id = ${accountId} FOR UPDATE`;
    await tx`SELECT pg_advisory_xact_lock(hashtextextended('push-installation-registration-v1', 0))`;
    const binding = (await tx`
      SELECT normal_enabled, voip_enabled FROM push_account_bindings
      WHERE installation_id = ${installationId} AND account_id = ${accountId}
        AND device_id = ${deviceId} AND active
      FOR UPDATE`)[0];
    if (!binding) return;
    if (kind === "normal") {
      await tx`
        UPDATE push_account_bindings SET
          normal_enabled = FALSE,
          active = voip_enabled,
          updated_at = now()
        WHERE installation_id = ${installationId} AND account_id = ${accountId}
          AND device_id = ${deviceId}`;
      await tx`
        UPDATE push_installations installation SET
          normal_token_hash = NULL, normal_token_hash_key_id = NULL,
          normal_token_ciphertext = NULL, normal_token_nonce = NULL,
          normal_token_key_id = NULL, normal_environment = NULL, updated_at = now()
        WHERE installation.installation_id = ${installationId}
          AND NOT EXISTS (
            SELECT 1 FROM push_account_bindings other
            WHERE other.installation_id = installation.installation_id
              AND other.active AND other.normal_enabled
          )`;
    } else {
      await tx`
        UPDATE push_account_bindings SET
          voip_enabled = FALSE,
          active = normal_enabled,
          updated_at = now()
        WHERE installation_id = ${installationId} AND account_id = ${accountId}
          AND device_id = ${deviceId}`;
      await tx`
        UPDATE push_installations installation SET
          voip_token_hash = NULL, voip_token_hash_key_id = NULL,
          voip_token_ciphertext = NULL, voip_token_nonce = NULL,
          voip_token_key_id = NULL, voip_environment = NULL, updated_at = now()
        WHERE installation.installation_id = ${installationId}
          AND NOT EXISTS (
            SELECT 1 FROM push_account_bindings other
            WHERE other.installation_id = installation.installation_id
              AND other.active AND other.voip_enabled
          )`;
    }
    await tx`
      DELETE FROM push_account_bindings
      WHERE installation_id = ${installationId} AND account_id = ${accountId}
        AND device_id = ${deviceId} AND NOT active`;
    await tx`
      DELETE FROM push_installations installation
      WHERE installation.installation_id = ${installationId}
        AND NOT EXISTS (
          SELECT 1 FROM push_account_bindings other
          WHERE other.installation_id = installation.installation_id
        )`;
  });
  return { registered: false };
}

export async function registerInstallationVoIPPushToken(
  sql: SQL,
  input: {
    accountId: string;
    deviceId: string;
    installationId: string;
    token: string;
    environment: string;
    supportedCallProtocolVersions?: unknown;
    supportedCallMediaProfileVersions?: unknown;
    callViewVersion?: unknown;
    supportedGroupCallVersions?: unknown;
    groupCallViewVersion?: unknown;
    supportsGroupScreenShare?: unknown;
  },
) {
  let supportedCallProtocolVersions: number[];
  let supportedCallMediaProfileVersions: number[];
  try {
    supportedCallProtocolVersions = normalizeCallVersionCapabilities(
      input.supportedCallProtocolVersions,
    );
    supportedCallMediaProfileVersions = normalizeCallVersionCapabilities(
      input.supportedCallMediaProfileVersions,
    );
  } catch (error) {
    if (error instanceof CallVersionCapabilityError) throw new PushError(error.message);
    throw error;
  }
  const callViewVersion = input.callViewVersion == null ? 1 : Number(input.callViewVersion);
  if (!Number.isSafeInteger(callViewVersion) || callViewVersion < 1 || callViewVersion > 0xffff) {
    throw new PushError("invalid call view version");
  }
  const group = normalizeGroupCallCapabilities(
    input.supportedGroupCallVersions,
    input.groupCallViewVersion,
    input.supportsGroupScreenShare,
  );
  try {
    return await sql.begin(async (tx) => {
      const registration = await registerInstallationPushTokenInTransaction(tx, {
        ...input,
        kind: "voip",
      });
      const updated = await tx`
        UPDATE devices SET
          supported_call_protocol_versions = ${tx.array(supportedCallProtocolVersions, "INT4")},
          supported_call_media_profile_versions = ${tx.array(supportedCallMediaProfileVersions, "INT4")},
          call_view_version = ${callViewVersion},
          supported_group_call_versions = ${tx.array(group.versions, "INT4")},
          group_call_view_version = ${group.viewVersion},
          supports_group_screen_share = ${group.supportsScreenShare}
        WHERE id = ${input.deviceId} AND account_id = ${input.accountId}
          AND platform = 'ios' AND revoked_at IS NULL
        RETURNING id`;
      if (!updated.length) throw new PushError("active iOS device required");
      return {
        ...registration,
        supportedCallProtocolVersions,
        supportedCallMediaProfileVersions,
        callViewVersion,
        supportedGroupCallVersions: group.versions,
        groupCallViewVersion: group.viewVersion,
        supportsGroupScreenShare: group.supportsScreenShare,
      };
    });
  } catch (error) {
    rethrowInstallationRegistrationError(error);
  }
}

/**
 * Group media capability is independent from PushKit and microphone permission: a member may
 * discover a room, join muted, and grant microphone/camera access only after a foreground tap.
 * Keeping this registration separate prevents a microphone-denied device from becoming a 1:1
 * VoIP ring target merely to advertise group-call support.
 */
export async function registerGroupCallCapabilities(
  sql: SQL,
  deviceId: string,
  rawSupportedVersions?: unknown,
  rawViewVersion?: unknown,
  rawSupportsScreenShare?: unknown,
): Promise<{ registered: true; supportedGroupCallVersions: number[];
  groupCallViewVersion: number; supportsGroupScreenShare: boolean }> {
  const normalized = normalizeGroupCallCapabilities(
    rawSupportedVersions,
    rawViewVersion,
    rawSupportsScreenShare,
  );
  const supportedGroupCallVersions = normalized.versions;
  const groupCallViewVersion = normalized.viewVersion;
  const supportsGroupScreenShare = normalized.supportsScreenShare;
  const updated = await sql`
    UPDATE devices SET
      supported_group_call_versions = ${sql.array(supportedGroupCallVersions, "INT4")},
      group_call_view_version = ${groupCallViewVersion},
      supports_group_screen_share = ${supportsGroupScreenShare}
    WHERE id = ${deviceId} AND platform = 'ios' AND revoked_at IS NULL
    RETURNING id`;
  if (!updated.length) throw new PushError("active iOS device required");
  return {
    registered: true,
    supportedGroupCallVersions,
    groupCallViewVersion,
    supportsGroupScreenShare,
  };
}

/** Called inside the message transaction, after account_events is inserted. */
export async function enqueuePushDeliveries(sql: SQL, p: {
  accountId: string;
  pts: number;
  senderAccountId: string;
  sourceDeviceId?: string | null;
  alertRecipients?: boolean;
  forceAlert?: boolean;
}): Promise<void> {
  await sql`
    INSERT INTO push_deliveries (account_id, pts, device_id, alert)
    SELECT ${p.accountId}, ${p.pts}, d.id,
           ${p.forceAlert === true
             || (p.alertRecipients !== false && p.accountId !== p.senderAccountId)}
    FROM devices d
    WHERE d.account_id = ${p.accountId}
      AND d.platform = 'ios'
      AND d.revoked_at IS NULL
      AND (
        EXISTS (
          SELECT 1
          FROM push_account_bindings binding
          JOIN push_installations installation
            ON installation.installation_id = binding.installation_id
          WHERE binding.device_id = d.id AND binding.account_id = d.account_id
            AND binding.active AND binding.normal_enabled
            AND installation.normal_token_hash IS NOT NULL
            AND installation.normal_token_ciphertext IS NOT NULL
        )
        OR (
          d.push_token_hash IS NOT NULL AND d.push_token_ciphertext IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM push_account_bindings binding
            WHERE binding.device_id = d.id AND binding.account_id = d.account_id
              AND binding.active AND binding.normal_enabled
          )
        )
      )
      AND (${p.sourceDeviceId ?? null}::uuid IS NULL OR d.id <> ${p.sourceDeviceId ?? null})
    ON CONFLICT (account_id, pts, device_id) DO NOTHING`;
}

export type APNsSyncSendRequest = {
  kind?: "sync";
  token: string;
  environment: PushEnvironment;
  pts: number;
  alert: boolean;
  routingHandle?: string;
};

export type APNsVoIPSendRequest = {
  kind: "voip";
  token: string;
  environment: PushEnvironment;
  callId: string;
  callerAccountId: string;
  initialKind: "voice" | "video";
  expiresAt: string;
  routingHandle?: string;
};

export type APNsSendRequest = APNsSyncSendRequest | APNsVoIPSendRequest;

export type APNsSendResult = { status: number; reason?: string; apnsId?: string };

export interface PushSender {
  send(request: APNsSendRequest): Promise<APNsSendResult>;
  close?(): void;
}

export function buildAPNsPayload(
  request: Pick<APNsSyncSendRequest, "pts" | "alert" | "routingHandle">,
): Record<string, unknown> {
  return request.alert
    ? {
        aps: {
          alert: { title: "Toj", body: "New message" },
          sound: "default",
          "content-available": 1,
        },
        toj: { pts: request.pts, ...(request.routingHandle ? { routingHandle: request.routingHandle } : {}) },
      }
    : {
        aps: { "content-available": 1 },
        toj: { pts: request.pts, ...(request.routingHandle ? { routingHandle: request.routingHandle } : {}) },
      };
}

export function buildVoIPAPNsPayload(
  request: Pick<APNsVoIPSendRequest, "callId" | "callerAccountId" | "initialKind" | "expiresAt" | "routingHandle">,
): Record<string, unknown> {
  return {
    aps: { "content-available": 1 },
    toj: {
      v: 1,
      type: request.initialKind === "video" ? "video_call" : "voice_call",
      callId: request.callId,
      ...(request.routingHandle
        ? { routingHandle: request.routingHandle }
        : { callerAccountId: request.callerAccountId }),
      expiresAt: request.expiresAt,
    },
  };
}

export function buildAPNsHeaders(
  request: APNsSendRequest,
  topic: string,
  voipTopic = `${topic}.voip`,
  nowSeconds = Math.floor(Date.now() / 1_000),
): Record<string, string> {
  const voip = request.kind === "voip";
  return {
    "apns-topic": voip ? voipTopic : topic,
    "apns-push-type": voip ? "voip" : request.alert ? "alert" : "background",
    "apns-priority": voip || request.alert ? "10" : "5",
    ...(voip ? {} : { "apns-collapse-id": "sync" }),
    "apns-expiration": voip ? "0" : String(nowSeconds + 24 * 60 * 60),
  };
}

type APNsConfig = {
  teamId: string;
  keyId: string;
  topic: string;
  voipTopic: string;
  privateKey: ReturnType<typeof createPrivateKey>;
};

function base64url(value: string | Buffer): string {
  return Buffer.from(value).toString("base64url");
}

export class APNsClient implements PushSender {
  private readonly sessions = new Map<PushEnvironment, ClientHttp2Session>();
  private jwt?: { value: string; issuedAt: number };

  constructor(private readonly config: APNsConfig) {}

  static fromEnvironment(): APNsClient | null {
    const teamId = process.env.TOJ_APNS_TEAM_ID;
    const keyId = process.env.TOJ_APNS_KEY_ID;
    const keyBase64 = process.env.TOJ_APNS_PRIVATE_KEY_BASE64;
    const configured = [teamId, keyId, keyBase64].filter(Boolean).length;
    if (configured === 0) return null;
    if (configured !== 3) {
      throw new PushError("TOJ_APNS_TEAM_ID, TOJ_APNS_KEY_ID, and TOJ_APNS_PRIVATE_KEY_BASE64 must be set together");
    }
    const pem = Buffer.from(keyBase64!, "base64").toString("utf8");
    return new APNsClient({
      teamId: teamId!,
      keyId: keyId!,
      topic: process.env.TOJ_APNS_TOPIC ?? "com.toj.Toj",
      voipTopic: process.env.TOJ_APNS_VOIP_TOPIC ?? `${process.env.TOJ_APNS_TOPIC ?? "com.toj.Toj"}.voip`,
      privateKey: createPrivateKey(pem),
    });
  }

  async send(request: APNsSendRequest): Promise<APNsSendResult> {
    const session = this.session(request.environment);
    const voip = request.kind === "voip";
    const payload = voip ? buildVoIPAPNsPayload(request) : buildAPNsPayload(request);

    const response = await new Promise<{ headers: IncomingHttpHeaders; body: string }>((resolve, reject) => {
      const stream = session.request({
        [constants.HTTP2_HEADER_METHOD]: "POST",
        [constants.HTTP2_HEADER_PATH]: `/3/device/${request.token}`,
        authorization: `bearer ${this.providerToken()}`,
        ...buildAPNsHeaders(request, this.config.topic, this.config.voipTopic),
      });
      let headers: IncomingHttpHeaders = {};
      let body = "";
      stream.setEncoding("utf8");
      stream.on("response", (value) => { headers = value; });
      stream.on("data", (chunk) => { body += String(chunk); });
      stream.on("end", () => resolve({ headers, body }));
      stream.on("error", reject);
      stream.setTimeout(10_000, () => stream.destroy(new Error("APNs request timed out")));
      stream.end(JSON.stringify(payload));
    });

    const status = Number(response.headers[constants.HTTP2_HEADER_STATUS] ?? 0);
    let reason: string | undefined;
    if (response.body) {
      try { reason = JSON.parse(response.body).reason; } catch { reason = response.body.slice(0, 200); }
    }
    const apnsId = String(response.headers["apns-id"] ?? "") || undefined;
    return { status, reason, apnsId };
  }

  close(): void {
    for (const session of this.sessions.values()) session.close();
    this.sessions.clear();
  }

  private session(environment: PushEnvironment): ClientHttp2Session {
    const existing = this.sessions.get(environment);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    const origin = environment === "production"
      ? "https://api.push.apple.com"
      : "https://api.sandbox.push.apple.com";
    const session = connect(origin);
    this.sessions.set(environment, session);
    const discard = () => {
      if (this.sessions.get(environment) === session) this.sessions.delete(environment);
    };
    session.on("error", discard);
    session.on("goaway", () => { discard(); session.close(); });
    session.on("close", discard);
    return session;
  }

  private providerToken(): string {
    const now = Math.floor(Date.now() / 1000);
    if (this.jwt && now - this.jwt.issuedAt < 50 * 60) return this.jwt.value;
    const header = base64url(JSON.stringify({ alg: "ES256", kid: this.config.keyId }));
    const claims = base64url(JSON.stringify({ iss: this.config.teamId, iat: now }));
    const input = `${header}.${claims}`;
    const signature = sign("sha256", Buffer.from(input), {
      key: this.config.privateKey,
      dsaEncoding: "ieee-p1363",
    });
    const value = `${input}.${signature.toString("base64url")}`;
    this.jwt = { value, issuedAt: now };
    return value;
  }
}

type ClaimedDelivery = {
  id: string;
  account_id: string;
  device_id: string;
  pts: number | bigint;
  alert: boolean;
  attempts: number;
  expires_at: Date | string;
  push_token_ciphertext: Uint8Array | null;
  push_token_nonce: Uint8Array | null;
  push_token_key_id: string | null;
  push_environment: PushEnvironment | null;
  installation_id: string | null;
  routing_handle: string | null;
};

async function claimDeliveries(sql: SQL, limit: number): Promise<ClaimedDelivery[]> {
  await sql`
    UPDATE push_deliveries SET status = 'dead', last_error = 'expired'
    WHERE status IN ('pending','sending') AND expires_at <= now()`;
  return await sql`
    WITH picked AS (
      SELECT delivery.id,
             CASE
               WHEN delivery.alert AND event.msg_id IS NOT NULL THEN
                 message.state = 'visible'
                 AND (message.expires_at IS NULL OR message.expires_at > now())
               ELSE delivery.alert
             END AS effective_alert
      FROM push_deliveries delivery
      LEFT JOIN account_events event
        ON event.account_id = delivery.account_id AND event.pts = delivery.pts
      LEFT JOIN messages message
        ON message.dialog_id = event.dialog_id AND message.msg_id = event.msg_id
      WHERE delivery.expires_at > now()
        AND (
          (delivery.status = 'pending' AND delivery.available_at <= now())
          OR (delivery.status = 'sending'
            AND delivery.claimed_at < now() - (${CLAIM_TIMEOUT_SECONDS} * interval '1 second'))
        )
      ORDER BY delivery.available_at, delivery.created_at
      FOR UPDATE OF delivery SKIP LOCKED
      LIMIT ${limit}
    )
    UPDATE push_deliveries pd SET status = 'sending', claimed_at = now()
    FROM picked, devices d
    JOIN accounts account ON account.id = d.account_id
    LEFT JOIN push_account_bindings binding
      ON binding.device_id = d.id AND binding.account_id = d.account_id
     AND binding.active AND binding.normal_enabled
    LEFT JOIN push_installations installation
      ON installation.installation_id = binding.installation_id
    WHERE pd.id = picked.id AND d.id = pd.device_id
      AND account.status IN ('active','limited')
      AND d.revoked_at IS NULL
      -- The credential comes from the installation when a binding is active and from the
      -- device row otherwise; require a complete envelope on whichever side is used.
      AND CASE WHEN binding.installation_id IS NOT NULL THEN
            installation.normal_token_ciphertext IS NOT NULL
            AND installation.normal_token_nonce IS NOT NULL
            AND installation.normal_token_key_id IS NOT NULL
            AND installation.normal_environment IS NOT NULL
          ELSE
            d.push_token_hash IS NOT NULL
            AND d.push_token_ciphertext IS NOT NULL
            AND d.push_token_nonce IS NOT NULL
            AND d.push_token_key_id IS NOT NULL
            AND d.push_environment IS NOT NULL
          END
    RETURNING pd.id, d.account_id, pd.device_id, pd.pts, picked.effective_alert AS alert,
              pd.attempts, pd.expires_at,
              CASE WHEN binding.installation_id IS NOT NULL
                THEN installation.normal_token_ciphertext ELSE d.push_token_ciphertext END
                AS push_token_ciphertext,
              CASE WHEN binding.installation_id IS NOT NULL
                THEN installation.normal_token_nonce ELSE d.push_token_nonce END AS push_token_nonce,
              CASE WHEN binding.installation_id IS NOT NULL
                THEN installation.normal_token_key_id ELSE d.push_token_key_id END AS push_token_key_id,
              CASE WHEN binding.installation_id IS NOT NULL
                THEN installation.normal_environment ELSE d.push_environment END AS push_environment,
              binding.installation_id,
              binding.routing_handle` as ClaimedDelivery[];
}

function retryable(status: number, reason?: string): boolean {
  return status === 0
    || status === 429
    || status >= 500
    || (status === 403 && ["ExpiredProviderToken", "InvalidProviderToken", "MissingProviderToken"].includes(reason ?? ""))
    || reason === "DeviceTokenNotForTopic";
}

function invalidDeviceToken(status: number, reason?: string): boolean {
  return status === 410 || reason === "BadDeviceToken" || reason === "Unregistered";
}

function cleanError(value: unknown): string {
  const message = value instanceof Error ? value.message : String(value);
  return message.replace(/[\r\n]+/g, " ").slice(0, 500);
}

async function retryOrKill(sql: SQL, delivery: ClaimedDelivery, error: string): Promise<void> {
  const attempts = Number(delivery.attempts) + 1;
  const expired = new Date(delivery.expires_at).getTime() <= Date.now();
  if (attempts >= MAX_ATTEMPTS || expired) {
    await sql`
      UPDATE push_deliveries
      SET status = 'dead', attempts = ${attempts}, last_error = ${error}, claimed_at = NULL
      WHERE id = ${delivery.id} AND status = 'sending'`;
    return;
  }
  const delaySeconds = Math.min(5 * 60, 2 ** Math.min(attempts, 8));
  await sql`
    UPDATE push_deliveries
    SET status = 'pending', attempts = ${attempts}, last_error = ${error}, claimed_at = NULL,
        available_at = now() + (${delaySeconds} * interval '1 second')
    WHERE id = ${delivery.id} AND status = 'sending'`;
}

async function sendClaimedDelivery(
  sql: SQL,
  sender: PushSender,
  delivery: ClaimedDelivery,
  token: string,
): Promise<void> {
  // Installation-bound deliveries hash into their own namespace; device-bound ones keep the
  // original namespace so existing registrations stay resolvable.
  const tokenHashes = tokenHashCandidates(
    delivery.installation_id
      ? `apns-installation-normal|${delivery.push_environment}|${token}`
      : `apns|${delivery.push_environment}|${token}`,
  ).map((candidate) => candidate.digest);
  await sql.begin(async (tx) => {
    // A ban locks the account first, then devices and deliveries. Holding the same locks in the
    // same order across the bounded APNs request gives the send a real linearization point: a ban
    // that commits first prevents the send, while a send that starts first completes before the
    // ban can revoke the account. A check performed outside this transaction leaves a race window.
    const account = (await tx`
      SELECT status FROM accounts WHERE id = ${delivery.account_id} FOR SHARE`)[0];
    // An installation credential is shared by several accounts and registration re-locks the
    // device row, so locking the device across this send would block the very rotation the
    // hash-predicated invalidation below is designed to tolerate. The account lock still gives
    // bans their linearization point; only device-bound sends fence the device row itself.
    const device = delivery.installation_id
      ? (await tx`
          SELECT account_id, revoked_at, push_environment, push_token_hash
          FROM devices WHERE id = ${delivery.device_id}`)[0]
      : (await tx`
          SELECT account_id, revoked_at, push_environment, push_token_hash
          FROM devices WHERE id = ${delivery.device_id} FOR UPDATE`)[0];
    const installation = delivery.installation_id
      ? (await tx`
          SELECT installation.normal_token_hash, installation.normal_environment
          FROM push_installations installation
          JOIN push_account_bindings binding
            ON binding.installation_id = installation.installation_id
           AND binding.active AND binding.normal_enabled
           AND binding.device_id = ${delivery.device_id}
           AND binding.account_id = ${delivery.account_id}
          WHERE installation.installation_id = ${delivery.installation_id}`)[0]
      : null;
    const currentDelivery = (await tx`
      SELECT id, account_id, device_id, pts, alert, attempts, expires_at, status
      FROM push_deliveries
      WHERE id = ${delivery.id} AND account_id = ${delivery.account_id}
        AND device_id = ${delivery.device_id}
      FOR UPDATE`)[0];
    // The credential lives on the installation when the delivery was routed through a binding.
    const storedTokenHash = delivery.installation_id
      ? installation?.normal_token_hash
      : device?.push_token_hash;
    const storedEnvironment = delivery.installation_id
      ? installation?.normal_environment
      : device?.push_environment;
    const tokenStillCurrent = storedTokenHash != null
      && tokenHashes.some((hash) => Buffer.from(storedTokenHash).equals(hash));
    const current = (account?.status === "active" || account?.status === "limited")
      && device?.account_id === delivery.account_id
      && !device?.revoked_at
      && storedEnvironment === delivery.push_environment
      && tokenStillCurrent
      && currentDelivery?.status === "sending"
      && new Date(currentDelivery.expires_at).getTime() > Date.now();
    if (!current) {
      await tx`
        UPDATE push_deliveries
        SET status = 'dead', last_error = COALESCE(last_error, 'device no longer active'),
            claimed_at = NULL
        WHERE id = ${delivery.id} AND status = 'sending'`;
      return;
    }

    const lockedDelivery: ClaimedDelivery = {
      ...delivery,
      attempts: Number(currentDelivery.attempts),
      expires_at: currentDelivery.expires_at,
    };
    try {
      const result = await sender.send({
        token,
        environment: delivery.push_environment!,
        pts: Number(currentDelivery.pts),
        alert: Boolean(currentDelivery.alert),
        routingHandle: delivery.routing_handle ?? undefined,
      });
      if (result.status === 200) {
        await tx`
          UPDATE push_deliveries
          SET status = 'sent', sent_at = now(), apns_id = ${result.apnsId ?? null},
              last_error = NULL, claimed_at = NULL
          WHERE id = ${delivery.id} AND status = 'sending'`;
      } else if (invalidDeviceToken(result.status, result.reason)) {
        // APNs may answer after iOS has already rotated to a new token. The row is locked, and
        // the hash predicate additionally ensures a stale Unregistered response only clears the
        // token that produced it and never erases a replacement registration.
        const hashPredicate = tx.array(
          tokenHashes.map((hash) => hash.toString("hex")),
          "text",
        );
        if (delivery.installation_id) {
          const invalidated = await tx`
            UPDATE push_installations SET
              normal_token_hash = NULL, normal_token_hash_key_id = NULL,
              normal_token_ciphertext = NULL,
              normal_token_nonce = NULL, normal_token_key_id = NULL,
              normal_environment = NULL, updated_at = now()
            WHERE installation_id = ${delivery.installation_id}
              AND normal_token_hash IN (
                SELECT decode(value, 'hex') FROM unnest(${hashPredicate}::text[])
                  AS candidate(value)
              )
            RETURNING installation_id`;
          if (invalidated.length) {
            await tx`
              UPDATE push_account_bindings SET
                normal_enabled = FALSE, active = voip_enabled, updated_at = now()
              WHERE installation_id = ${delivery.installation_id}`;
            await tx`
              DELETE FROM push_account_bindings
              WHERE installation_id = ${delivery.installation_id} AND NOT active`;
          }
        } else {
          await tx`
            UPDATE devices SET
              push_token_hash = NULL, push_token_hash_key_id = NULL,
              push_token_ciphertext = NULL, push_token_nonce = NULL,
              push_token_key_id = NULL, push_environment = NULL, push_updated_at = now()
            WHERE id = ${delivery.device_id}
              AND push_token_hash IN (
                SELECT decode(value, 'hex') FROM unnest(${hashPredicate}::text[])
                  AS candidate(value)
              )`;
        }
        await tx`
          UPDATE push_deliveries
          SET status = 'dead', attempts = attempts + 1,
              last_error = ${cleanError(result.reason ?? `APNs ${result.status}`)}, claimed_at = NULL
          WHERE id = ${delivery.id} AND status = 'sending'`;
      } else if (retryable(result.status, result.reason)) {
        await retryOrKill(tx, lockedDelivery, cleanError(result.reason ?? `APNs ${result.status}`));
      } else {
        await tx`
          UPDATE push_deliveries
          SET status = 'dead', attempts = attempts + 1,
              last_error = ${cleanError(result.reason ?? `APNs ${result.status}`)}, claimed_at = NULL
          WHERE id = ${delivery.id} AND status = 'sending'`;
      }
    } catch (error) {
      await retryOrKill(tx, lockedDelivery, cleanError(error));
    }
  });
}

export async function processPushBatch(sql: SQL, sender: PushSender, limit = 50): Promise<number> {
  const deliveries = await claimDeliveries(sql, limit);
  for (const delivery of deliveries) {
    if (!delivery.push_token_ciphertext || !delivery.push_token_nonce
      || !delivery.push_token_key_id || !delivery.push_environment) {
      await sql`
        UPDATE push_deliveries SET status = 'dead', last_error = 'device token unavailable', claimed_at = NULL
        WHERE id = ${delivery.id} AND status = 'sending'`;
      continue;
    }

    let token: string;
    try {
      token = (await openForScope(sql, delivery.installation_id
        ? INSTALLATION_PUSH_SCOPE
        : { kind: "account", accountId: delivery.account_id }, {
        keyId: delivery.push_token_key_id,
        nonce: Buffer.from(delivery.push_token_nonce),
        ciphertext: Buffer.from(delivery.push_token_ciphertext),
      }, delivery.installation_id
        ? installationPushTokenAAD(delivery.installation_id, "normal")
        : pushTokenAAD(delivery.device_id))).toString("utf8");
    } catch (error) {
      if (error instanceof CryptoUnavailableError) {
        await sql`
          UPDATE push_deliveries
          SET status = 'pending', last_error = 'crypto_unavailable', claimed_at = NULL,
              available_at = now() + interval '5 seconds'
          WHERE id = ${delivery.id} AND status = 'sending'`;
        continue;
      }
      await sql`
        UPDATE push_deliveries SET status = 'dead', last_error = ${cleanError(error)}, claimed_at = NULL
        WHERE id = ${delivery.id} AND status = 'sending'`;
      continue;
    }

    await sendClaimedDelivery(sql, sender, delivery, token);
  }
  return deliveries.length;
}

type ClaimedVoIPDelivery = {
  id: string;
  account_id: string;
  call_id: string;
  caller_account_id: string;
  initial_kind: "voice" | "video";
  device_id: string;
  attempts: number;
  expires_at: Date | string;
  voip_push_token_ciphertext: Uint8Array | null;
  voip_push_token_nonce: Uint8Array | null;
  voip_push_token_key_id: string | null;
  voip_push_environment: PushEnvironment | null;
  installation_id: string | null;
  routing_handle: string | null;
};

async function claimVoIPDeliveries(sql: SQL, limit: number): Promise<ClaimedVoIPDelivery[]> {
  await sql`
    UPDATE voip_push_deliveries SET status = 'dead', last_error = 'expired', claimed_at = NULL
    WHERE status IN ('pending','sending') AND expires_at <= now()`;
  return await sql`
    WITH picked AS (
      SELECT pd.id FROM voip_push_deliveries pd
      JOIN calls c ON c.id = pd.call_id
      JOIN devices d ON d.id = pd.device_id
      LEFT JOIN push_account_bindings binding
        ON binding.device_id = d.id AND binding.account_id = d.account_id
       AND binding.active AND binding.voip_enabled
      LEFT JOIN push_installations installation
        ON installation.installation_id = binding.installation_id
      WHERE pd.expires_at > now() AND c.state = 'requested' AND c.expires_at > now()
        AND d.revoked_at IS NULL
        AND (CASE WHEN binding.installation_id IS NOT NULL
          THEN installation.voip_token_ciphertext ELSE d.voip_push_token_ciphertext END) IS NOT NULL
        AND ((pd.status = 'pending' AND pd.available_at <= now())
          OR (pd.status = 'sending'
            AND pd.claimed_at < now() - (${CLAIM_TIMEOUT_SECONDS} * interval '1 second')))
      ORDER BY pd.available_at, pd.created_at
      FOR UPDATE OF pd SKIP LOCKED LIMIT ${limit}
    )
    UPDATE voip_push_deliveries pd SET status = 'sending', claimed_at = now()
    FROM picked, devices d
    LEFT JOIN push_account_bindings binding
      ON binding.device_id = d.id AND binding.account_id = d.account_id
     AND binding.active AND binding.voip_enabled
    LEFT JOIN push_installations installation
      ON installation.installation_id = binding.installation_id
    WHERE pd.id = picked.id AND d.id = pd.device_id
    RETURNING pd.id, d.account_id, pd.call_id, pd.caller_account_id, pd.initial_kind,
      pd.device_id, pd.attempts, pd.expires_at,
      CASE WHEN binding.installation_id IS NOT NULL
        THEN installation.voip_token_ciphertext ELSE d.voip_push_token_ciphertext END
        AS voip_push_token_ciphertext,
      CASE WHEN binding.installation_id IS NOT NULL
        THEN installation.voip_token_nonce ELSE d.voip_push_token_nonce END AS voip_push_token_nonce,
      CASE WHEN binding.installation_id IS NOT NULL
        THEN installation.voip_token_key_id ELSE d.voip_push_token_key_id END AS voip_push_token_key_id,
      CASE WHEN binding.installation_id IS NOT NULL
        THEN installation.voip_environment ELSE d.voip_push_environment END AS voip_push_environment,
      binding.installation_id,
      binding.routing_handle` as ClaimedVoIPDelivery[];
}

async function retryOrKillVoIP(sql: SQL, delivery: ClaimedVoIPDelivery, error: string): Promise<void> {
  const attempts = Number(delivery.attempts) + 1;
  const expired = new Date(delivery.expires_at).getTime() <= Date.now();
  if (attempts >= MAX_ATTEMPTS || expired) {
    await sql`
      UPDATE voip_push_deliveries
      SET status = 'dead', attempts = ${attempts}, last_error = ${error}, claimed_at = NULL
      WHERE id = ${delivery.id} AND status = 'sending'`;
    return;
  }
  // Call invites expire quickly. Keep retry delays sub-second at first, then cap at five seconds.
  const delayMilliseconds = Math.min(5_000, 250 * 2 ** Math.min(attempts, 5));
  await sql`
    UPDATE voip_push_deliveries
    SET status = 'pending', attempts = ${attempts}, last_error = ${error}, claimed_at = NULL,
        available_at = now() + (${delayMilliseconds} * interval '1 millisecond')
    WHERE id = ${delivery.id} AND status = 'sending'`;
}

async function sendClaimedVoIPDelivery(
  sql: SQL,
  sender: PushSender,
  delivery: ClaimedVoIPDelivery,
  token: string,
): Promise<void> {
  // Installation-bound deliveries hash into their own namespace; device-bound ones keep the
  // original namespace so existing registrations stay resolvable.
  const tokenHashes = tokenHashCandidates(
    delivery.installation_id
      ? `apns-installation-voip|${delivery.voip_push_environment}|${token}`
      : `apns-voip|${delivery.voip_push_environment}|${token}`,
  ).map((candidate) => candidate.digest);
  await sql.begin(async (tx) => {
    // Keep the account and device eligibility locks across the bounded APNs request. This gives
    // bans, device revocation, and token rotation a real ordering boundary while a compatible
    // device SHARE lock still lets call cancellation/decline authenticate immediately. Do not
    // lock the call or delivery across the network request: a terminal call action must be able
    // to mark the delivery dead, and every result write below is conditional on it still sending.
    const account = (await tx`
      SELECT status FROM accounts WHERE id = ${delivery.account_id} FOR SHARE`)[0];
    const call = (await tx`
      SELECT state, expires_at FROM calls WHERE id = ${delivery.call_id}`)[0];
    // As on the normal path, an installation-bound send must leave the device row unlocked so a
    // concurrent re-registration can rotate the shared credential while this request is in flight.
    const device = delivery.installation_id
      ? (await tx`
          SELECT account_id, revoked_at, voip_push_environment, voip_push_token_hash
          FROM devices WHERE id = ${delivery.device_id}`)[0]
      : (await tx`
          SELECT account_id, revoked_at, voip_push_environment, voip_push_token_hash
          FROM devices WHERE id = ${delivery.device_id} FOR SHARE`)[0];
    // When the delivery was routed through a binding the credential lives on the installation,
    // and the binding must still be active for this device/account pair.
    const installation = delivery.installation_id
      ? (await tx`
          SELECT installation.voip_token_hash, installation.voip_environment
          FROM push_installations installation
          JOIN push_account_bindings binding
            ON binding.installation_id = installation.installation_id
           AND binding.active AND binding.voip_enabled
           AND binding.device_id = ${delivery.device_id}
           AND binding.account_id = ${delivery.account_id}
          WHERE installation.installation_id = ${delivery.installation_id}`)[0]
      : null;
    const currentDelivery = (await tx`
      SELECT id, status, attempts, expires_at
      FROM voip_push_deliveries
      WHERE id = ${delivery.id} AND call_id = ${delivery.call_id}
        AND device_id = ${delivery.device_id}`)[0];
    const storedTokenHash = delivery.installation_id
      ? installation?.voip_token_hash
      : device?.voip_push_token_hash;
    const storedEnvironment = delivery.installation_id
      ? installation?.voip_environment
      : device?.voip_push_environment;
    const tokenStillCurrent = storedTokenHash != null
      && tokenHashes.some((hash) => Buffer.from(storedTokenHash).equals(hash));
    const now = Date.now();
    const current = (account?.status === "active" || account?.status === "limited")
      && call?.state === "requested"
      && new Date(call.expires_at).getTime() > now
      && device?.account_id === delivery.account_id
      && !device?.revoked_at
      && storedEnvironment === delivery.voip_push_environment
      && tokenStillCurrent
      && currentDelivery?.status === "sending"
      && new Date(currentDelivery.expires_at).getTime() > now;
    if (!current) {
      await tx`
        UPDATE voip_push_deliveries
        SET status = 'dead', last_error = COALESCE(last_error, 'call no longer ringing'),
            claimed_at = NULL
        WHERE id = ${delivery.id} AND status = 'sending'`;
      return;
    }

    const lockedDelivery: ClaimedVoIPDelivery = {
      ...delivery,
      attempts: Number(currentDelivery.attempts),
      expires_at: currentDelivery.expires_at,
    };
    try {
      const result = await sender.send({
        kind: "voip",
        token,
        environment: delivery.voip_push_environment!,
        callId: delivery.call_id,
        callerAccountId: delivery.caller_account_id,
        initialKind: delivery.initial_kind,
        expiresAt: new Date(currentDelivery.expires_at).toISOString(),
        routingHandle: delivery.routing_handle ?? undefined,
      });
      if (result.status === 200) {
        await tx`
          UPDATE voip_push_deliveries
          SET status = 'sent', sent_at = now(), apns_id = ${result.apnsId ?? null},
              last_error = NULL, claimed_at = NULL
          WHERE id = ${delivery.id} AND status = 'sending'`;
      } else if (invalidDeviceToken(result.status, result.reason)) {
        // A stale Unregistered response must only clear the token that produced it, never a
        // replacement registration that arrived while this request was in flight.
        const hashPredicate = tx.array(
          tokenHashes.map((hash) => hash.toString("hex")),
          "text",
        );
        if (delivery.installation_id) {
          const invalidated = await tx`
            UPDATE push_installations SET
              voip_token_hash = NULL, voip_token_hash_key_id = NULL,
              voip_token_ciphertext = NULL,
              voip_token_nonce = NULL, voip_token_key_id = NULL,
              voip_environment = NULL, updated_at = now()
            WHERE installation_id = ${delivery.installation_id}
              AND voip_token_hash IN (
                SELECT decode(value, 'hex') FROM unnest(${hashPredicate}::text[])
                  AS candidate(value)
              )
            RETURNING installation_id`;
          if (invalidated.length) {
            await tx`
              UPDATE push_account_bindings SET
                voip_enabled = FALSE, active = normal_enabled, updated_at = now()
              WHERE installation_id = ${delivery.installation_id}`;
            await tx`
              DELETE FROM push_account_bindings
              WHERE installation_id = ${delivery.installation_id} AND NOT active`;
          }
        } else {
          await tx`
            UPDATE devices SET
              voip_push_token_hash = NULL, voip_push_token_hash_key_id = NULL,
              voip_push_token_ciphertext = NULL,
              voip_push_token_nonce = NULL, voip_push_token_key_id = NULL,
              voip_push_environment = NULL, voip_push_updated_at = now()
            WHERE id = ${delivery.device_id}
              AND voip_push_token_hash IN (
                SELECT decode(value, 'hex') FROM unnest(${hashPredicate}::text[])
                  AS candidate(value)
              )`;
        }
        await tx`
          UPDATE voip_push_deliveries
          SET status = 'dead', attempts = attempts + 1,
              last_error = ${cleanError(result.reason ?? `APNs ${result.status}`)}, claimed_at = NULL
          WHERE id = ${delivery.id} AND status = 'sending'`;
      } else if (retryable(result.status, result.reason)) {
        await retryOrKillVoIP(tx, lockedDelivery, cleanError(result.reason ?? `APNs ${result.status}`));
      } else {
        await tx`
          UPDATE voip_push_deliveries
          SET status = 'dead', attempts = attempts + 1,
              last_error = ${cleanError(result.reason ?? `APNs ${result.status}`)}, claimed_at = NULL
          WHERE id = ${delivery.id} AND status = 'sending'`;
      }
    } catch (error) {
      await retryOrKillVoIP(tx, lockedDelivery, cleanError(error));
    }
  });
}

async function processVoIPDelivery(sql: SQL, sender: PushSender, delivery: ClaimedVoIPDelivery): Promise<void> {
  if (!delivery.voip_push_token_ciphertext || !delivery.voip_push_token_nonce
    || !delivery.voip_push_token_key_id || !delivery.voip_push_environment) {
    await sql`
      UPDATE voip_push_deliveries
      SET status = 'dead', last_error = 'VoIP token unavailable', claimed_at = NULL
      WHERE id = ${delivery.id} AND status = 'sending'`;
    return;
  }
  let token: string;
  try {
    token = (await openForScope(sql, delivery.installation_id
      ? INSTALLATION_PUSH_SCOPE
      : { kind: "account", accountId: delivery.account_id }, {
      keyId: delivery.voip_push_token_key_id,
      nonce: Buffer.from(delivery.voip_push_token_nonce),
      ciphertext: Buffer.from(delivery.voip_push_token_ciphertext),
    }, delivery.installation_id
      ? installationPushTokenAAD(delivery.installation_id, "voip")
      : voipPushTokenAAD(delivery.device_id))).toString("utf8");
  } catch (error) {
    if (error instanceof CryptoUnavailableError) {
      await sql`
        UPDATE voip_push_deliveries
        SET status = CASE WHEN expires_at > now() THEN 'pending' ELSE 'dead' END,
            last_error = 'crypto_unavailable', claimed_at = NULL,
            available_at = LEAST(expires_at, now() + interval '250 milliseconds')
        WHERE id = ${delivery.id} AND status = 'sending'`;
      return;
    }
    await sql`
      UPDATE voip_push_deliveries
      SET status = 'dead', last_error = ${cleanError(error)}, claimed_at = NULL
      WHERE id = ${delivery.id} AND status = 'sending'`;
    return;
  }

  await sendClaimedVoIPDelivery(sql, sender, delivery, token);
}

export async function processVoIPPushBatch(sql: SQL, sender: PushSender, limit = 50): Promise<number> {
  const deliveries = await claimVoIPDeliveries(sql, limit);
  let next = 0;
  const worker = async () => {
    while (next < deliveries.length) {
      const delivery = deliveries[next++];
      await processVoIPDelivery(sql, sender, delivery);
    }
  };
  const concurrency = Math.min(8, deliveries.length);
  await Promise.all(Array.from({ length: concurrency }, worker));
  return deliveries.length;
}

export function startPushWorker(sql: SQL, sender: PushSender | null, intervalMs = 500): () => void {
  if (!sender) return () => {};
  let running = false;
  const tick = async () => {
    if (running) return;
    running = true;
    try {
      while (true) {
        const [sync, voip] = await Promise.all([
          processPushBatch(sql, sender),
          processVoIPPushBatch(sql, sender),
        ]);
        if (sync === 0 && voip === 0) break;
      }
    } catch (error) {
      console.error(new Date().toISOString(), "push.worker.error", cleanError(error));
    } finally {
      running = false;
    }
  };
  void tick();
  const timer = setInterval(() => { void tick(); }, intervalMs);
  timer.unref?.();
  return () => { clearInterval(timer); sender.close?.(); };
}
