import { createHash, createHmac } from "node:crypto";
import type { SQL } from "bun";

export type BlindIndexDomain =
  | "phone-lookup"
  | "otp-code"
  | "opaque-token"
  | "media-digest"
  | "draft-mutation"
  | "message-send"
  | "message-send-v2"
  | "media-group-send"
  | "abuse-report"
  | "messaging-feature"
  | "chat-folder-mutation"
  | "scheduled-delivery-mutation"
  | "link-preview-url"
  | "link-preview-asset";

export type VersionedBlindIndex = { keyId: string; digest: Buffer };
export const EXPIRED_BLIND_INDEX_KEY_ID = "expired";

type KeyEntry = { keyId: string; key: Buffer; legacy: boolean };
type ParsedKeyring = { activeKeyId: string; keys: KeyEntry[] };

let cachedKeyring: { signature: string; value: ParsedKeyring } | null = null;

function requiredKey(value: string | undefined, name: string, developmentByte: number): Buffer {
  if (value) {
    const decoded = Buffer.from(value, "base64");
    if (decoded.length !== 32) {
      decoded.fill(0);
      throw new Error(`${name} must decode to 32 bytes`);
    }
    return decoded;
  }
  if (process.env.NODE_ENV === "production") throw new Error(`${name} required in production`);
  return Buffer.alloc(32, developmentByte);
}

function parseKeyring(): ParsedKeyring {
  // The cache token must detect configuration changes without retaining an extra plaintext copy
  // of every base64-encoded key for the lifetime of the process.
  const signature = createHash("sha256").update(JSON.stringify([
    process.env.NODE_ENV ?? "",
    process.env.TOJ_HMAC_KEY ?? "",
    process.env.TOJ_BLIND_INDEX_KEYRING ?? "",
    process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID ?? "",
    process.env.TOJ_BLIND_INDEX_LEGACY_DISABLED ?? "",
  ])).digest("hex");
  if (cachedKeyring?.signature === signature) return cachedKeyring.value;
  if (cachedKeyring) {
    for (const entry of cachedKeyring.value.keys) entry.key.fill(0);
    cachedKeyring = null;
  }
  const legacyDisabled = process.env.TOJ_BLIND_INDEX_LEGACY_DISABLED === "1";
  const legacy: KeyEntry | null = legacyDisabled ? null : {
    keyId: "legacy-v1",
    key: requiredKey(process.env.TOJ_HMAC_KEY, "TOJ_HMAC_KEY", 0x0b),
    legacy: true,
  };
  const raw = process.env.TOJ_BLIND_INDEX_KEYRING;
  if (!raw) {
    if (!legacy) {
      throw new Error(
        "TOJ_BLIND_INDEX_KEYRING is required when legacy-v1 is disabled",
      );
    }
    const value = { activeKeyId: legacy.keyId, keys: [legacy] };
    cachedKeyring = { signature, value };
    return value;
  }

  let configured: Record<string, string>;
  try {
    const parsed = JSON.parse(raw);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error();
    configured = parsed as Record<string, string>;
  } catch {
    legacy?.key.fill(0);
    throw new Error("TOJ_BLIND_INDEX_KEYRING must be a JSON object of key IDs to base64 keys");
  }
  if (Object.keys(configured).length > 16) {
    legacy?.key.fill(0);
    throw new Error("TOJ_BLIND_INDEX_KEYRING supports at most 16 readable keys");
  }
  const versioned: KeyEntry[] = [];
  try {
    for (const [keyId, encoded] of Object.entries(configured)) {
      if (!/^[a-z0-9][a-z0-9._-]{0,63}$/i.test(keyId) || keyId === "legacy-v1") {
        throw new Error(`invalid blind-index key ID: ${keyId}`);
      }
      versioned.push({
        keyId,
        key: requiredKey(encoded, `blind-index key ${keyId}`, 0),
        legacy: false,
      });
    }
    const keys = [...(legacy ? [legacy] : []), ...versioned];
    // A safe rolling rotation first deploys the new key as readable everywhere while the old
    // key remains active. Selecting legacy-v1 here is therefore intentional and temporary.
    const activeKeyId = process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID ?? legacy?.keyId ?? "";
    if (!keys.some((entry) => entry.keyId === activeKeyId)) {
      throw new Error("TOJ_BLIND_INDEX_ACTIVE_KEY_ID must select a configured readable key");
    }
    const value = { activeKeyId, keys };
    cachedKeyring = { signature, value };
    return value;
  } catch (error) {
    legacy?.key.fill(0);
    for (const entry of versioned) entry.key.fill(0);
    throw error;
  }
}

function inputs(
  domain: BlindIndexDomain,
  value: Uint8Array | string,
  legacyValue?: Uint8Array | string,
): { current: Buffer; legacy: Buffer } {
  const current = typeof value === "string" ? Buffer.from(value, "utf8") : Buffer.from(value);
  const old = legacyValue == null
    ? current
    : typeof legacyValue === "string" ? Buffer.from(legacyValue, "utf8") : Buffer.from(legacyValue);
  return { current, legacy: old };
}

function calculate(
  entry: KeyEntry,
  domain: BlindIndexDomain,
  value: Uint8Array | string,
  legacyValue?: Uint8Array | string,
): VersionedBlindIndex {
  const input = inputs(domain, value, legacyValue);
  try {
    const hmac = createHmac("sha256", entry.key);
    if (entry.legacy) hmac.update(input.legacy);
    else hmac.update(`toj/blind-index/v2|${entry.keyId}|${domain}|`).update(input.current);
    return { keyId: entry.keyId, digest: hmac.digest() };
  } finally {
    input.current.fill(0);
    if (input.legacy !== input.current) input.legacy.fill(0);
  }
}

export function activeBlindIndex(
  domain: BlindIndexDomain,
  value: Uint8Array | string,
  legacyValue?: Uint8Array | string,
): VersionedBlindIndex {
  const keyring = parseKeyring();
  const entry = keyring.keys.find((candidate) => candidate.keyId === keyring.activeKeyId)!;
  return calculate(entry, domain, value, legacyValue);
}

export function blindIndexForKey(
  keyId: string,
  domain: BlindIndexDomain,
  value: Uint8Array | string,
  legacyValue?: Uint8Array | string,
): VersionedBlindIndex {
  const entry = parseKeyring().keys.find((candidate) => candidate.keyId === keyId);
  if (!entry) throw new Error(`unknown blind-index key ID ${keyId}`);
  return calculate(entry, domain, value, legacyValue);
}

export function blindIndexCandidates(
  domain: BlindIndexDomain,
  value: Uint8Array | string,
  legacyValue?: Uint8Array | string,
): VersionedBlindIndex[] {
  const keyring = parseKeyring();
  return keyring.keys.map((entry) => calculate(entry, domain, value, legacyValue));
}

export function blindIndexReadiness(): {
  activeKeyId: string;
  readableKeyIds: string[];
  launchBlocking: boolean;
} {
  const keyring = parseKeyring();
  return {
    activeKeyId: keyring.activeKeyId,
    readableKeyIds: keyring.keys.map((entry) => entry.keyId),
    launchBlocking: process.env.NODE_ENV === "production" && keyring.activeKeyId === "legacy-v1",
  };
}

export async function blindIndexDatabaseReadiness(sql: SQL): Promise<{
  activeKeyId: string;
  readableKeyIds: string[];
  schemaReady: boolean;
  missingSchema: string[];
  references: Array<{ domain: string; keyId: string; count: number }>;
  unknownKeyIds: string[];
  ready: boolean;
  launchBlocking: boolean;
}> {
  const configured = blindIndexReadiness();
  const required: Record<string, string[]> = {
    accounts: ["status", "phone_lookup_key_id"],
    devices: ["auth_token_key_id", "push_token_hash_key_id", "voip_push_token_hash_key_id"],
    otp_challenges: ["phone_lookup_key_id", "code_key_id", "network_key_id"],
    call_invite_attempts: ["network_key_id"],
    contact_lookup_attempts: ["target_phone_key_id"],
    draft_mutation_requests: ["fingerprint_key_id"],
    draft_mutation_tombstones: ["fingerprint_key_id"],
    send_requests: ["fingerprint_key_id"],
    messages: ["send_fingerprint", "send_fingerprint_key_id"],
    media_group_send_requests: ["fingerprint_key_id"],
    media_group_send_tombstones: ["fingerprint_key_id"],
    media_objects: ["expected_digest_key_id"],
    media_chunks: ["plain_digest_key_id"],
    abuse_reports: ["fingerprint_key_id"],
    chat_folder_mutation_requests: ["fingerprint_key_id"],
    scheduled_delivery_mutation_requests: ["fingerprint_key_id"],
    link_preview_cache_entries: ["url_lookup_key_id"],
    message_link_previews: ["url_lookup_key_id"],
    link_preview_waiters: ["url_lookup_key_id"],
    link_preview_assets: ["digest_key_id"],
    device_sessions: ["refresh_token_hash_key_id"],
    session_access_tokens: ["token_digest_key_id"],
    session_refresh_token_history: ["token_digest_key_id"],
    session_rotation_receipts: ["request_token_digest_key_id"],
    two_factor_recovery_codes: ["code_key_id"],
    two_factor_attempt_budgets: ["network_key_id"],
    security_step_up_tickets: ["token_key_id"],
    messaging_feature_mutations: ["fingerprint_key_id"],
    push_installations: ["normal_token_hash_key_id", "voip_token_hash_key_id"],
  };
  const columns = await sql`
    SELECT table_name, column_name, column_default FROM information_schema.columns
    WHERE table_schema = current_schema()
      AND table_name = ANY(${sql.array(Object.keys(required), "text")}::text[])`;
  const present = new Set(columns.map((row: any) => `${row.table_name}.${row.column_name}`));
  const missingSchema = Object.entries(required).flatMap(([table, names]) =>
    names.filter((name) => !present.has(`${table}.${name}`)).map((name) => `${table}.${name}`)
  );
  const requiredLegacyDefaults = [
    "devices.push_token_hash_key_id",
    "devices.voip_push_token_hash_key_id",
    "otp_challenges.network_key_id",
    "call_invite_attempts.network_key_id",
    "message_link_previews.url_lookup_key_id",
    "device_sessions.refresh_token_hash_key_id",
    "session_access_tokens.token_digest_key_id",
    "session_refresh_token_history.token_digest_key_id",
    "session_rotation_receipts.request_token_digest_key_id",
    "two_factor_recovery_codes.code_key_id",
    "two_factor_attempt_budgets.network_key_id",
    "security_step_up_tickets.token_key_id",
    "messaging_feature_mutations.fingerprint_key_id",
    "push_installations.normal_token_hash_key_id",
    "push_installations.voip_token_hash_key_id",
  ];
  const defaults = new Map(columns.map((row: any) => [
    `${row.table_name}.${row.column_name}`, String(row.column_default ?? ""),
  ]));
  for (const column of requiredLegacyDefaults) {
    if (present.has(column) && !defaults.get(column)?.includes("legacy-v1")) {
      missingSchema.push(`${column}.legacy-default`);
    }
  }
  const requiredConstraints = [
    "devices_push_hash_key_check",
    "devices_voip_push_hash_key_check",
    "otp_challenges_network_hash_key_check",
    "call_invite_attempts_network_hash_key_check",
    "send_requests_fingerprint_key_check",
    "message_link_previews_url_hash_key_check",
    "two_factor_attempt_network_key_check",
    "push_installations_normal_hash_key_check",
    "push_installations_voip_hash_key_check",
  ];
  const constraints = await sql`
    SELECT conname FROM pg_constraint
    WHERE connamespace = current_schema()::regnamespace
      AND conname = ANY(${sql.array(requiredConstraints, "text")}::text[])
      AND convalidated`;
  const validated = new Set(constraints.map((row: any) => String(row.conname)));
  missingSchema.push(...requiredConstraints
    .filter((constraint) => !validated.has(constraint))
    .map((constraint) => `constraint.${constraint}`));
  if (missingSchema.length > 0) {
    return {
      ...configured,
      schemaReady: false,
      missingSchema,
      references: [],
      unknownKeyIds: [],
      ready: false,
      launchBlocking: process.env.NODE_ENV === "production" || configured.launchBlocking,
    };
  }
  const rows = await sql`
    SELECT domain, key_id, count(*)::bigint AS count
    FROM (
      SELECT 'accounts.phone' AS domain, phone_lookup_key_id AS key_id FROM accounts
        WHERE status <> 'deleted'
      UNION ALL SELECT 'devices.auth', auth_token_key_id FROM devices
      UNION ALL SELECT 'devices.push', COALESCE(push_token_hash_key_id, 'unlabeled')
        FROM devices WHERE push_token_hash IS NOT NULL
      UNION ALL SELECT 'devices.voip', COALESCE(voip_push_token_hash_key_id, 'unlabeled')
        FROM devices WHERE voip_push_token_hash IS NOT NULL
      UNION ALL SELECT 'otp.phone', phone_lookup_key_id FROM otp_challenges
      UNION ALL SELECT 'otp.code', code_key_id FROM otp_challenges
      UNION ALL SELECT 'otp.network', COALESCE(network_key_id, 'unlabeled')
        FROM otp_challenges WHERE network_hash IS NOT NULL
      UNION ALL SELECT 'call-invite.network', COALESCE(network_key_id, 'unlabeled')
        FROM call_invite_attempts WHERE network_hash IS NOT NULL
      UNION ALL SELECT 'contact.target', target_phone_key_id FROM contact_lookup_attempts
      UNION ALL SELECT 'draft.receipt', fingerprint_key_id FROM draft_mutation_requests
      UNION ALL SELECT 'draft.tombstone', fingerprint_key_id FROM draft_mutation_tombstones
      UNION ALL SELECT 'message-send.receipt', fingerprint_key_id FROM send_requests
        WHERE fingerprint IS NOT NULL
      UNION ALL SELECT 'message-send.message', send_fingerprint_key_id FROM messages
        WHERE send_fingerprint IS NOT NULL
      UNION ALL SELECT 'media-group.receipt', fingerprint_key_id FROM media_group_send_requests
      UNION ALL SELECT 'media-group.tombstone', fingerprint_key_id FROM media_group_send_tombstones
      UNION ALL SELECT 'media.expected-digest', expected_digest_key_id FROM media_objects
        WHERE status = 'uploading'
      UNION ALL SELECT 'media.chunk-digest', chunk.plain_digest_key_id
        FROM media_chunks chunk JOIN media_objects media ON media.id = chunk.media_id
        WHERE media.status = 'uploading'
      UNION ALL SELECT 'report.receipt', fingerprint_key_id FROM abuse_reports
      UNION ALL SELECT 'folder.receipt', fingerprint_key_id FROM chat_folder_mutation_requests
      UNION ALL SELECT 'scheduled.receipt', fingerprint_key_id
        FROM scheduled_delivery_mutation_requests
      UNION ALL SELECT 'preview.cache-url', url_lookup_key_id FROM link_preview_cache_entries
      UNION ALL SELECT 'preview.message-url', COALESCE(url_lookup_key_id, 'unlabeled')
        FROM message_link_previews WHERE url_lookup_hmac IS NOT NULL AND state = 'pending'
      UNION ALL SELECT 'preview.waiter-url', url_lookup_key_id FROM link_preview_waiters
      UNION ALL SELECT 'sessions.refresh', refresh_token_hash_key_id FROM device_sessions
      UNION ALL SELECT 'sessions.access', token_digest_key_id FROM session_access_tokens
      UNION ALL SELECT 'sessions.refresh-history', token_digest_key_id
        FROM session_refresh_token_history
      UNION ALL SELECT 'sessions.rotation-receipt', request_token_digest_key_id
        FROM session_rotation_receipts
      UNION ALL SELECT 'two-factor.recovery', code_key_id FROM two_factor_recovery_codes
      UNION ALL SELECT 'two-factor.network-budget', COALESCE(network_key_id, 'unlabeled')
        FROM two_factor_attempt_budgets WHERE network_hash IS NOT NULL
      UNION ALL SELECT 'two-factor.step-up', token_key_id FROM security_step_up_tickets
      UNION ALL SELECT 'messaging-feature.receipt', fingerprint_key_id
        FROM messaging_feature_mutations
      UNION ALL SELECT 'push-installation.normal', COALESCE(normal_token_hash_key_id, 'unlabeled')
        FROM push_installations WHERE normal_token_hash IS NOT NULL
      UNION ALL SELECT 'push-installation.voip', COALESCE(voip_token_hash_key_id, 'unlabeled')
        FROM push_installations WHERE voip_token_hash IS NOT NULL
    ) all_references
    WHERE key_id IS NOT NULL AND key_id NOT IN ('random-deleted', 'expired')
    GROUP BY domain, key_id ORDER BY domain, key_id`;
  const references = rows.map((row: any) => ({
    domain: String(row.domain), keyId: String(row.key_id), count: Number(row.count),
  }));
  const readable = new Set(configured.readableKeyIds);
  const unknownKeyIds = [...new Set(references
    .filter((reference) => !readable.has(reference.keyId))
    .map((reference) => reference.keyId))].sort();
  return {
    ...configured,
    schemaReady: true,
    missingSchema: [],
    references,
    unknownKeyIds,
    ready: unknownKeyIds.length === 0,
    launchBlocking: process.env.NODE_ENV === "production"
      && (configured.launchBlocking || unknownKeyIds.length > 0),
  };
}

export function assertBlindIndexConfiguration(): void {
  void parseKeyring();
}

export function blindIndexMetrics(database?: {
  unknownKeyIds: string[];
  references: Array<{ count: number }>;
  launchBlocking?: boolean;
}): string {
  const state = blindIndexReadiness();
  return [
    "# HELP toj_blind_index_keyring_info Active versioned blind-index keyring.",
    "# TYPE toj_blind_index_keyring_info gauge",
    `toj_blind_index_keyring_info{active_key_id=\"${state.activeKeyId}\",readable_keys=\"${state.readableKeyIds.length}\"} 1`,
    "# HELP toj_blind_index_launch_blocking Whether the legacy-only keyring blocks production launch.",
    "# TYPE toj_blind_index_launch_blocking gauge",
    `toj_blind_index_launch_blocking ${(database?.launchBlocking ?? state.launchBlocking) ? 1 : 0}`,
    "# TYPE toj_blind_index_unknown_persisted_keys gauge",
    `toj_blind_index_unknown_persisted_keys ${database?.unknownKeyIds.length ?? 0}`,
    "# TYPE toj_blind_index_persisted_references gauge",
    `toj_blind_index_persisted_references ${database?.references.reduce((sum, item) => sum + item.count, 0) ?? 0}`,
    "",
  ].join("\n");
}
