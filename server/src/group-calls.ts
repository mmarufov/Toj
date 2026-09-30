import type { SQL } from "bun";
import { createHash, createHmac, randomBytes } from "node:crypto";
import { Client } from "pg";
import {
  DialogAccessError,
  lockDialogForMutation,
  requireDialogReadAccess,
  requireGroupRole,
} from "./dialog-access";
import { requireActiveDevice } from "./auth";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const GROUP_CALL_VERSION = 1;
const PARTICIPANT_LIMIT = 32;
const PUBLISHER_LIMIT = 16;
const TOKEN_TTL_SECONDS = 5 * 60;
const CAMERA_LEASE_SECONDS = 15;
const SCREEN_SHARE_LEASE_SECONDS = 15;
const MEDIA_LEASE_UPDATE_MIN_SECONDS = 3;
const ACTIVE_HEARTBEAT_TIMEOUT_SECONDS = 120;
const PENDING_KEY_TIMEOUT_SECONDS = 60;
const EPOCH_GRACE_SECONDS = 10;
const GROUP_CALL_NOTIFY_CHANNEL = "toj_group_call_events";
const SFU_CONTROL_TIMEOUT_MS = 3_000;
const SFU_CONTROL_CLAIM_SECONDS = 15;

type GroupCallRow = Record<string, any>;
type ParticipantRow = Record<string, any>;

export class GroupCallError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly status = 400,
    readonly details: Record<string, unknown> = {},
    readonly retryAfter?: number,
  ) {
    super(message);
    this.name = "GroupCallError";
  }
}

export type GroupCallHint = {
  accountId: string;
  deviceId: string;
  callId: string;
  stateRevision: number;
};

export type GroupCallWakeup = { callId: string; stateRevision: number };

export type GroupCallParticipantDTO = {
  accountId: string;
  deviceId: string;
  participantId: string;
  status: "pending_key" | "active";
  joinPublicKey: string;
  joinNonce: string;
  joinedMembershipRevision: number;
  readyMediaEpoch: number | null;
  joinedAt: string;
  isSelf: boolean;
  isKeyLeader: boolean;
};

export type GroupCallSnapshot = {
  id: string;
  dialogId: string;
  initialKind: "voice" | "video";
  state: "active" | "ended";
  participantLimit: number;
  publisherLimit: number;
  membershipRevision: number;
  stateRevision: number;
  selfRole: "owner" | "admin" | "member";
  mediaEpoch: number;
  keyLeaderDeviceId: string;
  rekeyRequired: boolean;
  epoch: {
    epoch: number;
    membershipRevision: number;
    keyCommitment: string;
    participantSetHash: string;
    activatedAt: string;
    previousEpochGraceExpiresAt: string | null;
  };
  participants: GroupCallParticipantDTO[];
  selfEnvelope: {
    epoch: number;
    senderPublicKey: string;
    recipientPublicKey: string;
    ciphertext: string;
  } | null;
  cameraPublishers: string[];
  screenShare: {
    participantId: string;
    expiresAt: string;
  } | null;
  createdAt: string;
  endedAt: string | null;
  endReason: string | null;
};

export type GroupCallCredentials = {
  url: string;
  token: string;
  participantId: string;
  expiresAt: string;
  mediaEpoch: number;
};

type LiveKitConfiguration = {
  url: string;
  apiKey: string;
  apiSecret: string;
  managedCloud: boolean;
};

export type GroupCallSFUControl = {
  ensureRoom(room: string, participantLimit: number): Promise<void>;
  updateParticipant(input: {
    room: string;
    identity: string;
    mediaAllowed: boolean;
    cameraAllowed: boolean;
    screenShareAllowed: boolean;
  }): Promise<void>;
  /// Returns the minimum JWT `nbf` accepted after this revocation, or zero when the provider
  /// does not implement durable token revocation (development/test controls only).
  removeParticipant(room: string, identity: string): Promise<number>;
};

function iso(value: unknown): string {
  return value instanceof Date ? value.toISOString() : String(value);
}

function n(value: unknown): number {
  return Number(value as any);
}

function requireUUID(value: unknown, field: string): string {
  const normalized = String(value ?? "").toLowerCase();
  if (!UUID_PATTERN.test(normalized)) {
    throw new GroupCallError(`${field} is invalid`, "invalid_request");
  }
  return normalized;
}

function decodeBase64(value: unknown, field: string, exactBytes?: number): Buffer {
  if (typeof value !== "string" || value.length === 0 || value.length > 8_192
    || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) {
    throw new GroupCallError(`${field} must be base64`, "invalid_request");
  }
  const decoded = Buffer.from(value, "base64");
  if (exactBytes !== undefined && decoded.length !== exactBytes) {
    throw new GroupCallError(`${field} must decode to ${exactBytes} bytes`, "invalid_request");
  }
  return decoded;
}

function decodeJoinMaterial(value: unknown, field: "joinPublicKey" | "joinNonce"): Buffer {
  const decoded = decodeBase64(value, field, 32);
  if (decoded.every((byte) => byte === 0)) {
    throw new GroupCallError(`${field} is invalid`, "invalid_request");
  }
  return decoded;
}

function sameBytes(left: unknown, right: Buffer): boolean {
  return left != null && Buffer.from(left as Uint8Array).equals(right);
}

function mapDialogError(error: unknown): never {
  if (error instanceof DialogAccessError) {
    throw new GroupCallError(error.message, error.code, error.status);
  }
  throw error;
}

function liveKitConfiguration(): LiveKitConfiguration {
  const rawURL = (process.env.TOJ_LIVEKIT_URL ?? "").trim();
  const apiKey = (process.env.TOJ_LIVEKIT_API_KEY ?? "").trim();
  const apiSecret = (process.env.TOJ_LIVEKIT_API_SECRET ?? "").trim();
  const managedCloud = process.env.TOJ_LIVEKIT_DEPLOYMENT === "cloud";
  let url: URL;
  try {
    url = new URL(rawURL);
  } catch {
    throw new GroupCallError("group media is unavailable", "sfu_unavailable", 503);
  }
  const secure = url.protocol === "wss:" || url.protocol === "https:";
  const localDevelopment = process.env.NODE_ENV !== "production"
    && (url.hostname === "localhost" || url.hostname === "127.0.0.1")
    && (url.protocol === "ws:" || url.protocol === "http:");
  if ((!secure && !localDevelopment) || url.username || url.password || url.search || url.hash
    || apiKey.length < 6 || apiSecret.length < 32
    || /^(change-?me|placeholder|secret)$/i.test(apiSecret)
    // RemoveParticipant's token-revocation timestamp is enforced by LiveKit Cloud. Refuse a
    // production configuration that cannot invalidate every pre-membership-change room token.
    || (process.env.NODE_ENV === "production" && !managedCloud)) {
    throw new GroupCallError("group media is unavailable", "sfu_unavailable", 503);
  }
  return { url: url.toString().replace(/\/$/, ""), apiKey, apiSecret, managedCloud };
}

export function groupCallsConfigured(groupsReady = process.env.TOJ_GROUPS_V1_ENABLED === "1"): boolean {
  if (!groupsReady
    || process.env.TOJ_GROUP_CALLS_ENABLED !== "1"
    || process.env.TOJ_GROUP_CALLS_SFU_READY !== "1"
    || process.env.TOJ_GROUP_CALLS_E2EE_REQUIRED !== "1") return false;
  try {
    liveKitConfiguration();
    return true;
  } catch {
    return false;
  }
}

/**
 * SFU revocation is a drain-plane responsibility, not an admission feature. Keep durable remove
 * and permission-revoke work active whenever the control endpoint is valid, even if a rollout or
 * emergency switch has stopped all new starts and joins.
 */
export function groupCallSFUControlConfigured(): boolean {
  if (process.env.TOJ_GROUP_CALLS_SFU_READY !== "1") return false;
  try {
    liveKitConfiguration();
    return true;
  } catch {
    return false;
  }
}

export function groupScreenSharingConfigured(groupCallsReady = groupCallsConfigured()): boolean {
  return groupCallsReady
    && process.env.TOJ_GROUP_SCREEN_SHARING_ENABLED === "1"
    && process.env.TOJ_GROUP_SCREEN_SHARING_READY === "1";
}

export function groupCallsEnabledForAccount(
  accountId: string,
  ready = groupCallsConfigured(),
): boolean {
  if (!ready) return false;
  const normalized = accountId.trim().toLowerCase();
  const allowlist = new Set((process.env.TOJ_GROUP_CALLS_ALLOWLIST ?? "")
    .split(",").map((value) => value.trim().toLowerCase()).filter(Boolean));
  if (allowlist.has(normalized)) return true;
  const percent = Number(process.env.TOJ_GROUP_CALLS_ROLLOUT_PERCENT ?? "0");
  if (!Number.isFinite(percent) || percent <= 0) return false;
  if (percent >= 100) return true;
  const digest = createHash("sha256")
    .update(`toj-group-call-rollout-v1|${normalized}`).digest();
  const bucket = digest.readUInt32BE(0) / 0x1_0000_0000 * 100;
  return bucket < percent;
}

const REQUIRED_GROUP_CALL_TABLES = [
  "group_calls",
  "group_call_participants",
  "group_call_epochs",
  "group_call_epoch_envelopes",
  "group_call_camera_leases",
  "group_call_screen_share_leases",
  "group_call_sfu_participant_states",
  "group_call_action_budgets",
] as const;

const REQUIRED_DEVICE_COLUMNS = [
  "supported_group_call_versions",
  "group_call_view_version",
  "supports_group_screen_share",
] as const;

const REQUIRED_GROUP_CALL_COLUMNS: Record<string, readonly string[]> = {
  group_calls: [
    "id", "dialog_id", "creator_account_id", "creator_device_id", "initial_kind", "state",
    "sfu_room_name", "participant_limit", "publisher_limit", "membership_revision", "media_epoch",
    "state_revision",
    "key_leader_device_id", "epoch_key_commitment", "created_at", "updated_at", "ended_at", "end_reason",
  ],
  group_call_participants: [
    "call_id", "device_id", "account_id", "call_local_identity", "status", "join_public_key",
    "join_nonce", "joined_membership_revision", "ready_media_epoch", "joined_at", "last_seen_at", "left_at",
    "last_heartbeat_at",
  ],
  group_call_epochs: [
    "call_id", "epoch", "membership_revision", "leader_device_id", "key_commitment",
    "participant_set_hash", "created_at", "activated_at", "grace_expires_at",
  ],
  group_call_epoch_envelopes: [
    "call_id", "epoch", "recipient_device_id", "sender_public_key", "recipient_public_key", "ciphertext",
    "created_at",
  ],
  group_call_camera_leases: [
    "call_id", "device_id", "generation", "expires_at", "created_at", "updated_at",
  ],
  group_call_screen_share_leases: [
    "call_id", "device_id", "generation", "expires_at", "created_at", "updated_at",
  ],
  group_call_sfu_participant_states: [
    "call_id", "device_id", "participant_identity", "desired_status", "media_allowed", "camera_allowed",
    "screen_share_allowed", "revision", "applied_revision", "applied_status",
    "applied_media_allowed", "applied_camera_allowed", "applied_screen_share_allowed", "claim_token", "claim_revision",
    "claim_expires_at", "token_not_before", "attempt_count", "next_attempt_at", "last_error_code",
    "created_at", "updated_at",
  ],
  group_call_action_budgets: ["id", "account_id", "device_id", "action", "created_at"],
};

const REQUIRED_GROUP_CALL_PRIMARY_KEYS: Record<string, readonly string[]> = {
  group_calls: ["id"],
  group_call_participants: ["call_id", "device_id"],
  group_call_epochs: ["call_id", "epoch"],
  group_call_epoch_envelopes: ["call_id", "epoch", "recipient_device_id"],
  group_call_camera_leases: ["call_id", "device_id"],
  group_call_screen_share_leases: ["call_id"],
  group_call_sfu_participant_states: ["call_id", "participant_identity"],
  group_call_action_budgets: ["id"],
};

const REQUIRED_GROUP_CALL_INDEXES = [
  "group_calls_one_active_per_dialog_idx",
  "group_call_participants_one_device_per_account_idx",
  "group_call_participants_stale_idx",
  "group_call_participants_account_active_idx",
  "group_call_camera_lease_expiry_idx",
  "group_call_screen_share_expiry_idx",
  "group_call_sfu_state_device_idx",
  "group_call_sfu_state_pending_idx",
  "group_call_sfu_state_retention_idx",
  "group_call_action_budgets_window_idx",
  "group_call_action_budgets_retention_idx",
] as const;

const REQUIRED_GROUP_CALL_INDEX_DEFINITIONS: Record<string, string> = {
  group_calls_one_active_per_dialog_idx:
    "CREATE UNIQUE INDEX group_calls_one_active_per_dialog_idx ON public.group_calls USING btree (dialog_id) WHERE (state = 'active'::text)",
  group_call_participants_one_device_per_account_idx:
    "CREATE UNIQUE INDEX group_call_participants_one_device_per_account_idx ON public.group_call_participants USING btree (call_id, account_id) WHERE (status = ANY (ARRAY['pending_key'::text, 'active'::text]))",
  group_call_participants_stale_idx:
    "CREATE INDEX group_call_participants_stale_idx ON public.group_call_participants USING btree (last_seen_at, call_id, device_id) WHERE (status = ANY (ARRAY['pending_key'::text, 'active'::text]))",
  group_call_participants_account_active_idx:
    "CREATE INDEX group_call_participants_account_active_idx ON public.group_call_participants USING btree (account_id, call_id, device_id) WHERE (status = ANY (ARRAY['pending_key'::text, 'active'::text]))",
  group_call_camera_lease_expiry_idx:
    "CREATE INDEX group_call_camera_lease_expiry_idx ON public.group_call_camera_leases USING btree (expires_at)",
  group_call_screen_share_expiry_idx:
    "CREATE INDEX group_call_screen_share_expiry_idx ON public.group_call_screen_share_leases USING btree (expires_at)",
  group_call_sfu_state_device_idx:
    "CREATE INDEX group_call_sfu_state_device_idx ON public.group_call_sfu_participant_states USING btree (call_id, device_id, updated_at)",
  group_call_sfu_state_pending_idx:
    "CREATE INDEX group_call_sfu_state_pending_idx ON public.group_call_sfu_participant_states USING btree (next_attempt_at, updated_at) WHERE (applied_revision < revision)",
  group_call_sfu_state_retention_idx:
    "CREATE INDEX group_call_sfu_state_retention_idx ON public.group_call_sfu_participant_states USING btree (updated_at, call_id, participant_identity) WHERE ((desired_status = 'removed'::text) AND (applied_revision = revision))",
  group_call_action_budgets_window_idx:
    "CREATE INDEX group_call_action_budgets_window_idx ON public.group_call_action_budgets USING btree (account_id, action, created_at DESC)",
  group_call_action_budgets_retention_idx:
    "CREATE INDEX group_call_action_budgets_retention_idx ON public.group_call_action_budgets USING btree (created_at, id)",
};

const REQUIRED_GROUP_CALL_CONSTRAINTS: Record<string, { table: string; definition: string }> = {
  group_call_sfu_applied_status_check: {
    table: "group_call_sfu_participant_states",
    definition: "CHECK ((applied_status = ANY (ARRAY['active'::text, 'removed'::text])))",
  },
  group_call_sfu_applied_media_check: {
    table: "group_call_sfu_participant_states",
    definition: "CHECK (((applied_status = 'active'::text) OR ((NOT applied_media_allowed) AND (NOT applied_camera_allowed) AND (NOT applied_screen_share_allowed))))",
  },
  group_call_sfu_removed_media_check: {
    table: "group_call_sfu_participant_states",
    definition: "CHECK (((desired_status = 'active'::text) OR ((NOT media_allowed) AND (NOT camera_allowed) AND (NOT screen_share_allowed))))",
  },
  group_call_sfu_media_gate_check: {
    table: "group_call_sfu_participant_states",
    definition: "CHECK ((media_allowed OR ((NOT camera_allowed) AND (NOT screen_share_allowed))))",
  },
  group_call_sfu_token_not_before_check: {
    table: "group_call_sfu_participant_states",
    definition: "CHECK ((token_not_before >= 0))",
  },
};

function normalizeCatalogDefinition(value: unknown): string {
  return String(value ?? "").replace(/\s+/g, " ").trim();
}

type GroupCallColumnContract = {
  table: string;
  column: string;
  type: string;
  notNull: boolean;
  default: string | null;
};

const NULLABLE_GROUP_CALL_COLUMNS = new Set([
  "group_calls.ended_at", "group_calls.end_reason",
  "group_call_participants.ready_media_epoch", "group_call_participants.left_at",
  "group_call_epochs.grace_expires_at",
  "group_call_sfu_participant_states.claim_token",
  "group_call_sfu_participant_states.claim_revision",
  "group_call_sfu_participant_states.claim_expires_at",
  "group_call_sfu_participant_states.last_error_code",
]);

const GROUP_CALL_COLUMN_DEFAULTS = new Map<string, string>([
  ["devices.supported_group_call_versions", "ARRAY[]::integer[]"],
  ["devices.group_call_view_version", "0"],
  ["devices.supports_group_screen_share", "false"],
  ["group_calls.state", "'active'::text"],
  ["group_calls.participant_limit", "32"],
  ["group_calls.publisher_limit", "16"],
  ["group_calls.membership_revision", "1"],
  ["group_calls.state_revision", "1"],
  ["group_calls.media_epoch", "1"],
  ["group_calls.created_at", "now()"],
  ["group_calls.updated_at", "now()"],
  ["group_call_participants.joined_at", "now()"],
  ["group_call_participants.last_seen_at", "now()"],
  ["group_call_participants.last_heartbeat_at", "(now() - '00:00:20'::interval)"],
  ["group_call_epochs.created_at", "now()"],
  ["group_call_epochs.activated_at", "now()"],
  ["group_call_epoch_envelopes.created_at", "now()"],
  ["group_call_camera_leases.created_at", "now()"],
  ["group_call_camera_leases.updated_at", "now()"],
  ["group_call_screen_share_leases.created_at", "now()"],
  ["group_call_screen_share_leases.updated_at", "now()"],
  ["group_call_sfu_participant_states.desired_status", "'active'::text"],
  ["group_call_sfu_participant_states.media_allowed", "false"],
  ["group_call_sfu_participant_states.camera_allowed", "false"],
  ["group_call_sfu_participant_states.screen_share_allowed", "false"],
  ["group_call_sfu_participant_states.revision", "1"],
  ["group_call_sfu_participant_states.applied_revision", "1"],
  ["group_call_sfu_participant_states.applied_status", "'active'::text"],
  ["group_call_sfu_participant_states.applied_media_allowed", "false"],
  ["group_call_sfu_participant_states.applied_camera_allowed", "false"],
  ["group_call_sfu_participant_states.applied_screen_share_allowed", "false"],
  ["group_call_sfu_participant_states.token_not_before", "0"],
  ["group_call_sfu_participant_states.attempt_count", "0"],
  ["group_call_sfu_participant_states.next_attempt_at", "now()"],
  ["group_call_sfu_participant_states.created_at", "now()"],
  ["group_call_sfu_participant_states.updated_at", "now()"],
  ["group_call_action_budgets.id", "nextval('group_call_action_budgets_id_seq'::regclass)"],
  ["group_call_action_budgets.created_at", "now()"],
]);

function groupCallColumnType(table: string, column: string): string {
  if (table === "devices" && column === "supported_group_call_versions") return "integer[]";
  if (table === "devices" && column === "group_call_view_version") return "integer";
  if (table === "devices" && column === "supports_group_screen_share") return "boolean";
  if (table === "group_call_action_budgets" && column === "id") return "bigint";
  if (column === "participant_limit" || column === "publisher_limit") return "smallint";
  if (column === "attempt_count") return "integer";
  if (["membership_revision", "state_revision", "media_epoch", "epoch",
    "joined_membership_revision", "ready_media_epoch", "revision", "applied_revision",
    "claim_revision", "token_not_before"].includes(column)) return "bigint";
  if (["join_public_key", "join_nonce", "epoch_key_commitment", "key_commitment",
    "participant_set_hash", "sender_public_key", "recipient_public_key", "ciphertext"]
    .includes(column)) return "bytea";
  if (["media_allowed", "camera_allowed", "screen_share_allowed",
    "applied_media_allowed", "applied_camera_allowed", "applied_screen_share_allowed"]
    .includes(column)) return "boolean";
  if (column.endsWith("_at")) return "timestamp with time zone";
  if (column === "id" || column.endsWith("_id") || column === "generation"
    || column === "claim_token" || column === "call_local_identity"
    || column === "participant_identity") return "uuid";
  return "text";
}

const REQUIRED_GROUP_CALL_COLUMN_CONTRACTS: readonly GroupCallColumnContract[] = [
  ...REQUIRED_DEVICE_COLUMNS.map((column) => ({ table: "devices", column })),
  ...Object.entries(REQUIRED_GROUP_CALL_COLUMNS).flatMap(([table, columns]) =>
    columns.map((column) => ({ table, column }))),
].map(({ table, column }) => {
  const key = `${table}.${column}`;
  return {
    table,
    column,
    type: groupCallColumnType(table, column),
    notNull: !NULLABLE_GROUP_CALL_COLUMNS.has(key),
    default: GROUP_CALL_COLUMN_DEFAULTS.get(key) ?? null,
  };
});

const REQUIRED_GROUP_CALL_MIGRATIONS = ["group-calls-media-fence-v2"] as const;

export type GroupCallSchemaReadiness = {
  ready: boolean;
  missingTables: string[];
  missingDeviceColumns: string[];
  missingCriticalColumns: string[];
  invalidColumns: string[];
  invalidPrimaryKeys: string[];
  missingIndexes: string[];
  invalidIndexes: string[];
  invalidConstraints: string[];
  missingMigrations: string[];
};

type CachedGroupCallSchemaReadiness = {
  expiresAt: number;
  value?: GroupCallSchemaReadiness;
  inFlight?: Promise<GroupCallSchemaReadiness>;
};

const groupCallSchemaReadinessCache = new WeakMap<object, CachedGroupCallSchemaReadiness>();

export function clearGroupCallSchemaReadinessCache(sql?: SQL): void {
  if (sql) groupCallSchemaReadinessCache.delete(sql as unknown as object);
}

async function inspectGroupCallSchema(sql: SQL): Promise<GroupCallSchemaReadiness> {
  const tables = await sql`
    SELECT requested.name, to_regclass('public.' || requested.name) IS NOT NULL AS present
    FROM unnest(${sql.array([...REQUIRED_GROUP_CALL_TABLES], "text")}::text[]) AS requested(name)`;
  const columns = await sql`
    SELECT requested.table_name, requested.column_name,
      attribute.attnum IS NOT NULL AS present,
      CASE WHEN attribute.attnum IS NULL THEN NULL
        ELSE pg_catalog.format_type(attribute.atttypid, attribute.atttypmod)
      END AS data_type,
      attribute.attnotnull AS not_null,
      pg_catalog.pg_get_expr(attribute_default.adbin, attribute_default.adrelid) AS column_default
    FROM unnest(
      ${sql.array(REQUIRED_GROUP_CALL_COLUMN_CONTRACTS.map((contract) => contract.table), "text")}::text[],
      ${sql.array(REQUIRED_GROUP_CALL_COLUMN_CONTRACTS.map((contract) => contract.column), "text")}::text[]
    ) AS requested(table_name, column_name)
    LEFT JOIN pg_catalog.pg_namespace table_namespace
      ON table_namespace.nspname = 'public'
    LEFT JOIN pg_catalog.pg_class table_row
      ON table_row.relnamespace = table_namespace.oid
      AND table_row.relname = requested.table_name
      AND table_row.relkind IN ('r', 'p')
    LEFT JOIN pg_catalog.pg_attribute attribute
      ON attribute.attrelid = table_row.oid
      AND attribute.attname = requested.column_name
      AND attribute.attnum > 0 AND NOT attribute.attisdropped
    LEFT JOIN pg_catalog.pg_attrdef attribute_default
      ON attribute_default.adrelid = table_row.oid
      AND attribute_default.adnum = attribute.attnum`;
  const primaryKeyTables = Object.keys(REQUIRED_GROUP_CALL_PRIMARY_KEYS);
  const primaryKeys = await sql`
    SELECT table_row.relname AS table_name,
      array_agg(attribute.attname ORDER BY key_column.ordinality) AS columns
    FROM pg_catalog.pg_constraint constraint_row
    JOIN pg_catalog.pg_class table_row ON table_row.oid = constraint_row.conrelid
    JOIN pg_catalog.pg_namespace table_namespace
      ON table_namespace.oid = table_row.relnamespace
      AND table_namespace.nspname = 'public'
    JOIN pg_catalog.pg_index primary_index
      ON primary_index.indexrelid = constraint_row.conindid
    CROSS JOIN LATERAL unnest(constraint_row.conkey)
      WITH ORDINALITY AS key_column(attnum, ordinality)
    JOIN pg_catalog.pg_attribute attribute
      ON attribute.attrelid = constraint_row.conrelid
      AND attribute.attnum = key_column.attnum
    WHERE constraint_row.contype = 'p'
      AND constraint_row.convalidated
      AND NOT constraint_row.condeferrable
      AND primary_index.indisvalid
      AND primary_index.indisready
      AND primary_index.indislive
      AND table_row.relname = ANY(${sql.array(primaryKeyTables, "text")}::text[])
    GROUP BY table_row.relname`;
  const indexes = await sql`
    SELECT requested.name, index_row.oid IS NOT NULL AS present,
      table_namespace.nspname AS table_namespace,
      index_data.indisvalid, index_data.indisready, index_data.indislive,
      pg_catalog.pg_get_indexdef(index_row.oid) AS definition
    FROM unnest(${sql.array([...REQUIRED_GROUP_CALL_INDEXES], "text")}::text[]) AS requested(name)
    LEFT JOIN pg_catalog.pg_namespace index_namespace
      ON index_namespace.nspname = 'public'
    LEFT JOIN pg_catalog.pg_class index_row
      ON index_row.relnamespace = index_namespace.oid
      AND index_row.relname = requested.name
      AND index_row.relkind = 'i'
    LEFT JOIN pg_catalog.pg_index index_data ON index_data.indexrelid = index_row.oid
    LEFT JOIN pg_catalog.pg_class table_row ON table_row.oid = index_data.indrelid
    LEFT JOIN pg_catalog.pg_namespace table_namespace
      ON table_namespace.oid = table_row.relnamespace`;
  const constraints = await sql`
    SELECT constraint_row.conname, table_row.relname AS table_name,
      constraint_row.contype, constraint_row.convalidated, constraint_row.condeferrable,
      pg_catalog.pg_get_constraintdef(constraint_row.oid) AS definition
    FROM pg_catalog.pg_constraint constraint_row
    JOIN pg_catalog.pg_class table_row ON table_row.oid = constraint_row.conrelid
    JOIN pg_catalog.pg_namespace table_namespace
      ON table_namespace.oid = table_row.relnamespace
      AND table_namespace.nspname = 'public'
    WHERE table_row.relname = ANY(${sql.array([...REQUIRED_GROUP_CALL_TABLES], "text")}::text[])`;
  const migrations = await sql`
    SELECT requested.name, EXISTS (
      SELECT 1 FROM public.schema_migrations migration WHERE migration.name = requested.name
    ) AS present
    FROM unnest(${sql.array([...REQUIRED_GROUP_CALL_MIGRATIONS], "text")}::text[]) AS requested(name)`;
  const missingTables = tables.filter((row: any) => !row.present).map((row: any) => String(row.name));
  const missingDeviceColumns = columns.filter((row: any) =>
    row.table_name === "devices" && !row.present).map((row: any) => String(row.column_name));
  const missingCriticalColumns = columns.filter((row: any) =>
    row.table_name !== "devices" && !row.present)
    .map((row: any) => `${row.table_name}.${row.column_name}`);
  const expectedColumns = new Map(REQUIRED_GROUP_CALL_COLUMN_CONTRACTS.map((contract) => [
    `${contract.table}.${contract.column}`, contract,
  ]));
  const invalidColumns = columns.filter((row: any) => {
    if (!row.present) return false;
    const contract = expectedColumns.get(`${row.table_name}.${row.column_name}`);
    if (!contract) return true;
    return String(row.data_type) !== contract.type
      || Boolean(row.not_null) !== contract.notNull
      || (row.column_default == null ? null : String(row.column_default)) !== contract.default;
  }).map((row: any) => `${row.table_name}.${row.column_name}`);
  const actualPrimaryKeys = new Map<string, string[]>(primaryKeys.map((row: any) => [
    String(row.table_name), Array.from(row.columns ?? [], String),
  ]));
  const invalidPrimaryKeys = Object.entries(REQUIRED_GROUP_CALL_PRIMARY_KEYS)
    .filter(([tableName, expected]) => {
      const actual = actualPrimaryKeys.get(tableName);
      return !actual || actual.length !== expected.length
        || actual.some((column, index) => column !== expected[index]);
    })
    .map(([tableName]) => tableName);
  const missingIndexes = indexes.filter((row: any) => !row.present)
    .map((row: any) => String(row.name));
  const invalidIndexes = indexes.filter((row: any) => row.present && (
    row.table_namespace !== "public"
      || !row.indisvalid
      || !row.indisready
      || !row.indislive
      || normalizeCatalogDefinition(row.definition)
        !== REQUIRED_GROUP_CALL_INDEX_DEFINITIONS[String(row.name)]
  )).map((row: any) => String(row.name));
  const actualConstraints = new Map(constraints.map((row: any) => [String(row.conname), row]));
  const invalidConstraints = Object.entries(REQUIRED_GROUP_CALL_CONSTRAINTS)
    .filter(([name, contract]) => {
      const actual = actualConstraints.get(name) as any;
      return !actual || actual.table_name !== contract.table || actual.contype !== "c"
        || !actual.convalidated || actual.condeferrable
        || normalizeCatalogDefinition(actual.definition) !== contract.definition;
    })
    .map(([name]) => name);
  for (const constraint of constraints) {
    if (!constraint.convalidated) {
      const name = String(constraint.conname);
      if (!invalidConstraints.includes(name)) invalidConstraints.push(name);
    }
  }
  const missingMigrations = migrations.filter((row: any) => !row.present)
    .map((row: any) => String(row.name));
  return {
    ready: missingTables.length === 0
      && missingDeviceColumns.length === 0
      && missingCriticalColumns.length === 0
      && invalidColumns.length === 0
      && invalidPrimaryKeys.length === 0
      && missingIndexes.length === 0
      && invalidIndexes.length === 0
      && invalidConstraints.length === 0
      && missingMigrations.length === 0,
    missingTables,
    missingDeviceColumns,
    missingCriticalColumns,
    invalidColumns,
    invalidPrimaryKeys,
    missingIndexes,
    invalidIndexes,
    invalidConstraints,
    missingMigrations,
  };
}

export async function groupCallSchemaReadiness(
  sql: SQL,
  options: { bypassCache?: boolean } = {},
): Promise<GroupCallSchemaReadiness> {
  if (options.bypassCache) return await inspectGroupCallSchema(sql);

  const cacheKey = sql as unknown as object;
  const now = Date.now();
  const cached = groupCallSchemaReadinessCache.get(cacheKey);
  if (cached?.value && cached.expiresAt > now) return cached.value;
  if (cached?.inFlight) return await cached.inFlight;

  // Heartbeats are intentionally frequent, but PostgreSQL catalog validation is not a
  // per-heartbeat operation. Coalesce concurrent cold probes and retain a short fail-closed
  // result. A missing migration is retried quickly; a complete contract is revalidated every
  // five seconds and unconditionally by /ready.
  const inFlight = inspectGroupCallSchema(sql);
  groupCallSchemaReadinessCache.set(cacheKey, { expiresAt: 0, inFlight });
  try {
    const value = await inFlight;
    if (groupCallSchemaReadinessCache.get(cacheKey)?.inFlight === inFlight) {
      groupCallSchemaReadinessCache.set(cacheKey, {
        expiresAt: Date.now() + (value.ready ? 5_000 : 1_000),
        value,
      });
    }
    return value;
  } catch (error) {
    if (groupCallSchemaReadinessCache.get(cacheKey)?.inFlight === inFlight) {
      groupCallSchemaReadinessCache.delete(cacheKey);
    }
    throw error;
  }
}

function lengthPrefixed(hash: ReturnType<typeof createHash>, value: Buffer): void {
  const length = Buffer.allocUnsafe(4);
  length.writeUInt32BE(value.length);
  hash.update(length).update(value);
}

function participantSetHash(participants: ParticipantRow[]): Buffer {
  const hash = createHash("sha256");
  lengthPrefixed(hash, Buffer.from("toj-group-participants-v1", "utf8"));
  for (const participant of [...participants].sort((left, right) =>
    String(left.device_id).localeCompare(String(right.device_id)))) {
    lengthPrefixed(hash, Buffer.from(String(participant.account_id), "utf8"));
    lengthPrefixed(hash, Buffer.from(String(participant.device_id), "utf8"));
    lengthPrefixed(hash, Buffer.from(participant.join_public_key));
    lengthPrefixed(hash, Buffer.from(participant.join_nonce));
  }
  return hash.digest();
}

async function requireGroupMediaDevice(sql: SQL, accountId: string, deviceId: string,
  requireScreenShare = false): Promise<void> {
  await requireActiveDevice(sql, accountId, deviceId);
  const row = (await sql`
    SELECT id FROM devices
    WHERE id = ${deviceId} AND account_id = ${accountId} AND revoked_at IS NULL
      AND ${GROUP_CALL_VERSION} = ANY(supported_group_call_versions)
      AND group_call_view_version >= 1
      AND (${!requireScreenShare} OR supports_group_screen_share)`)[0];
  if (!row) {
    throw new GroupCallError(
      requireScreenShare ? "screen sharing is unavailable on this device" : "group calls are unavailable on this device",
      "device_capability_unavailable",
      409,
    );
  }
}

async function notify(sql: SQL, row: GroupCallRow): Promise<void> {
  await sql`SELECT pg_notify(
    ${GROUP_CALL_NOTIFY_CHANNEL},
    json_build_object(
      'callId', ${row.id}::uuid,
      'stateRevision', ${n(row.state_revision)}::bigint
    )::text
  )`;
}

async function advanceCallState(sql: SQL, callId: string): Promise<GroupCallRow> {
  return (await sql`
    UPDATE group_calls
    SET state_revision = state_revision + 1, updated_at = now()
    WHERE id = ${callId}
    RETURNING *`)[0];
}

async function hintTargets(sql: SQL, row: GroupCallRow): Promise<GroupCallHint[]> {
  const rows = await sql`
    SELECT DISTINCT device.account_id, device.id AS device_id,
      participant.status AS participant_status
    FROM devices device
    LEFT JOIN dialog_members member
      ON member.account_id = device.account_id AND member.dialog_id = ${row.dialog_id}
    LEFT JOIN group_call_participants participant
      ON participant.device_id = device.id AND participant.call_id = ${row.id}
    WHERE device.revoked_at IS NULL
      AND (
        (member.left_at IS NULL AND member.role IS NOT NULL
          AND ${GROUP_CALL_VERSION} = ANY(device.supported_group_call_versions)
          AND device.group_call_view_version >= 1)
        OR participant.status IN ('pending_key','active')
      )
    ORDER BY device.account_id, device.id`;
  return rows.filter((target: any) =>
    ["pending_key", "active"].includes(String(target.participant_status))
      || groupCallsEnabledForAccount(String(target.account_id)))
    .map((target: any) => ({
    accountId: String(target.account_id),
    deviceId: String(target.device_id),
    callId: String(row.id),
    stateRevision: n(row.state_revision),
    }));
}

export async function resolveGroupCallHintTargets(
  sql: SQL,
  wakeup: GroupCallWakeup,
  localDeviceIds: string[],
): Promise<GroupCallHint[]> {
  if (!UUID_PATTERN.test(wakeup.callId) || !Number.isSafeInteger(wakeup.stateRevision)
    || wakeup.stateRevision < 1 || localDeviceIds.length === 0) return [];
  const bounded = [...new Set(localDeviceIds.filter((id) => UUID_PATTERN.test(id)))].slice(0, 10_000);
  if (!bounded.length) return [];
  const rows = await sql`
    SELECT DISTINCT device.account_id, device.id AS device_id, call.state_revision,
      participant.status AS participant_status
    FROM group_calls call
    JOIN devices device ON device.id = ANY(${sql.array(bounded, "uuid")}::uuid[])
    LEFT JOIN dialog_members member
      ON member.dialog_id = call.dialog_id AND member.account_id = device.account_id
    LEFT JOIN group_call_participants participant
      ON participant.call_id = call.id AND participant.device_id = device.id
    WHERE call.id = ${wakeup.callId} AND device.revoked_at IS NULL
      AND (
        (member.left_at IS NULL AND member.role IS NOT NULL
          AND ${GROUP_CALL_VERSION} = ANY(device.supported_group_call_versions)
          AND device.group_call_view_version >= 1)
        OR participant.status IN ('pending_key','active')
      )
    ORDER BY device.account_id, device.id`;
  return rows.filter((target: any) =>
    ["pending_key", "active"].includes(String(target.participant_status))
      || groupCallsEnabledForAccount(String(target.account_id)))
    .map((target: any) => ({
      accountId: String(target.account_id), deviceId: String(target.device_id),
      callId: wakeup.callId, stateRevision: n(target.state_revision),
    }));
}

async function loadSnapshot(
  sql: SQL,
  row: GroupCallRow,
  accountId: string,
  deviceId: string,
): Promise<GroupCallSnapshot> {
  const membership = (await sql`
    SELECT role FROM dialog_members
    WHERE dialog_id = ${row.dialog_id} AND account_id = ${accountId} AND left_at IS NULL`)[0];
  if (!membership || !["owner", "admin", "member"].includes(String(membership.role))) {
    throw new GroupCallError("group access revoked", "group_access_revoked", 410);
  }
  const participants: ParticipantRow[] = await sql`
    SELECT * FROM group_call_participants
    WHERE call_id = ${row.id} AND status IN ('pending_key','active')
    ORDER BY joined_at, device_id`;
  const epoch = (await sql`
    SELECT current_epoch.*,
      previous.grace_expires_at AS previous_epoch_grace_expires_at
    FROM group_call_epochs current_epoch
    LEFT JOIN group_call_epochs previous
      ON previous.call_id = current_epoch.call_id AND previous.epoch = current_epoch.epoch - 1
    WHERE current_epoch.call_id = ${row.id} AND current_epoch.epoch = ${row.media_epoch}`)[0];
  if (!epoch) throw new GroupCallError("group call epoch is unavailable", "security_error", 409);
  const envelope = (await sql`
    SELECT * FROM group_call_epoch_envelopes
    WHERE call_id = ${row.id} AND epoch = ${row.media_epoch}
      AND recipient_device_id = ${deviceId}`)[0] ?? null;
  const screen = (await sql`
    SELECT lease.expires_at, participant.call_local_identity
    FROM group_call_screen_share_leases lease
    JOIN group_call_participants participant
      ON participant.call_id = lease.call_id AND participant.device_id = lease.device_id
    WHERE lease.call_id = ${row.id} AND lease.expires_at > now()
      AND participant.status = 'active'`)[0] ?? null;
  const cameras = await sql`
    SELECT participant.call_local_identity
    FROM group_call_camera_leases lease
    JOIN group_call_participants participant
      ON participant.call_id = lease.call_id AND participant.device_id = lease.device_id
    WHERE lease.call_id = ${row.id} AND lease.expires_at > now()
      AND participant.status = 'active' AND participant.ready_media_epoch = ${row.media_epoch}
    ORDER BY participant.call_local_identity`;
  return {
    id: String(row.id), dialogId: String(row.dialog_id), initialKind: row.initial_kind,
    state: row.state, participantLimit: n(row.participant_limit), publisherLimit: n(row.publisher_limit),
    membershipRevision: n(row.membership_revision), mediaEpoch: n(row.media_epoch),
    stateRevision: n(row.state_revision),
    selfRole: membership.role,
    keyLeaderDeviceId: String(row.key_leader_device_id),
    rekeyRequired: n(epoch.membership_revision) !== n(row.membership_revision),
    epoch: {
      epoch: n(epoch.epoch), membershipRevision: n(epoch.membership_revision),
      keyCommitment: Buffer.from(epoch.key_commitment).toString("base64"),
      participantSetHash: Buffer.from(epoch.participant_set_hash).toString("base64"),
      activatedAt: iso(epoch.activated_at),
      previousEpochGraceExpiresAt: epoch.previous_epoch_grace_expires_at == null
        ? null : iso(epoch.previous_epoch_grace_expires_at),
    },
    participants: participants.map((participant) => ({
      accountId: String(participant.account_id), deviceId: String(participant.device_id),
      participantId: String(participant.call_local_identity), status: participant.status,
      joinPublicKey: Buffer.from(participant.join_public_key).toString("base64"),
      joinNonce: Buffer.from(participant.join_nonce).toString("base64"),
      joinedMembershipRevision: n(participant.joined_membership_revision),
      readyMediaEpoch: participant.ready_media_epoch == null ? null : n(participant.ready_media_epoch),
      joinedAt: iso(participant.joined_at), isSelf: participant.device_id === deviceId,
      isKeyLeader: participant.device_id === row.key_leader_device_id,
    })),
    selfEnvelope: envelope ? {
      epoch: n(envelope.epoch),
      senderPublicKey: Buffer.from(envelope.sender_public_key).toString("base64"),
      recipientPublicKey: Buffer.from(envelope.recipient_public_key).toString("base64"),
      ciphertext: Buffer.from(envelope.ciphertext).toString("base64"),
    } : null,
    cameraPublishers: cameras.map((camera: any) => String(camera.call_local_identity)),
    screenShare: screen ? {
      participantId: String(screen.call_local_identity), expiresAt: iso(screen.expires_at),
    } : null,
    createdAt: iso(row.created_at), endedAt: row.ended_at == null ? null : iso(row.ended_at),
    endReason: row.end_reason ?? null,
  };
}

async function authorizedCall(sql: SQL, accountId: string, deviceId: string,
  callId: string, lock: boolean | "share" = false): Promise<GroupCallRow> {
  await requireGroupMediaDevice(sql, accountId, deviceId);
  const row = (lock === true
    ? await sql`SELECT * FROM group_calls WHERE id = ${callId} FOR UPDATE`
    : lock === "share"
      ? await sql`SELECT * FROM group_calls WHERE id = ${callId} FOR SHARE`
      : await sql`SELECT * FROM group_calls WHERE id = ${callId}`)[0];
  if (!row) throw new GroupCallError("group call not found", "not_found", 404);
  if (!groupCallsEnabledForAccount(accountId)) {
    const draining = await sql`
      SELECT 1 FROM group_call_participants
      WHERE call_id = ${callId} AND account_id = ${accountId} AND device_id = ${deviceId}
        AND status IN ('pending_key','active')`;
    if (!draining.length) {
      throw new GroupCallError("group call not found", "not_found", 404);
    }
  }
  await requireDialogReadAccess(sql, accountId, row.dialog_id).catch(mapDialogError);
  return row;
}

async function requireCurrentMediaEpoch(
  sql: SQL,
  row: GroupCallRow,
  deviceId: string,
): Promise<ParticipantRow> {
  const participant = (await sql`
    SELECT participant.*
    FROM group_call_participants participant
    JOIN group_call_epochs epoch
      ON epoch.call_id = participant.call_id AND epoch.epoch = ${row.media_epoch}
    WHERE participant.call_id = ${row.id} AND participant.device_id = ${deviceId}
      AND participant.status = 'active'
      AND participant.ready_media_epoch = ${row.media_epoch}
      AND epoch.membership_revision = ${row.membership_revision}
    FOR UPDATE OF participant`)[0];
  if (!participant) {
    throw new GroupCallError("current epoch key is not ready", "epoch_not_ready", 409);
  }
  return participant;
}

function initialKind(value: unknown): "voice" | "video" {
  if (value !== "voice" && value !== "video") {
    throw new GroupCallError("initialKind must be voice or video", "invalid_request");
  }
  return value;
}

async function enforceBudget(sql: SQL, accountId: string, deviceId: string,
  action: "start" | "join" | "camera_publish" | "screen_share"): Promise<void> {
  await sql`SELECT pg_advisory_xact_lock(hashtextextended(${`group-call-budget:${accountId}:${action}`}, 0))`;
  const window = action === "start" ? "10 minutes" : "1 hour";
  const limit = action === "start" ? 10 : action === "join" ? 60
    : action === "camera_publish" ? 120 : 20;
  const count = n((await sql`
    SELECT count(*)::int AS count FROM group_call_action_budgets
    WHERE account_id = ${accountId} AND action = ${action}
      AND created_at > now() - (${window}::interval)`)[0].count);
  if (count >= limit) {
    throw new GroupCallError("group call rate limit reached", "rate_limited", 429, {}, 60);
  }
  await sql`
    INSERT INTO group_call_action_budgets(account_id, device_id, action)
    VALUES (${accountId}, ${deviceId}, ${action})`;
}

function makeRoomName(): string {
  return `toj_gc_${randomBytes(24).toString("base64url")}`;
}

function makeLiveKitToken(config: LiveKitConfiguration, row: GroupCallRow,
  participant: ParticipantRow, tokenNotBefore = 0): GroupCallCredentials {
  const now = Math.floor(Date.now() / 1_000);
  const expires = now + TOKEN_TTL_SECONDS;
  const header = Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" })).toString("base64url");
  const claims = Buffer.from(JSON.stringify({
    iss: config.apiKey,
    sub: String(participant.call_local_identity),
    nbf: Math.max(now - 5, tokenNotBefore),
    iat: now,
    exp: expires,
    jti: crypto.randomUUID(),
    metadata: JSON.stringify({ protocol: GROUP_CALL_VERSION }),
    video: {
      room: row.sfu_room_name,
      roomJoin: true,
      canPublish: true,
      canSubscribe: true,
      canPublishData: false,
      // Camera and screen sources are granted only through short server leases and the
      // RoomService UpdateParticipant API. A cached join token can publish microphone only.
      canPublishSources: ["microphone"],
      canUpdateOwnMetadata: false,
      hidden: false,
      recorder: false,
      ingressAdmin: false,
      roomAdmin: false,
      roomCreate: false,
      roomList: false,
      roomRecord: false,
    },
  })).toString("base64url");
  const input = `${header}.${claims}`;
  const signature = createHmac("sha256", config.apiSecret).update(input).digest("base64url");
  return {
    url: config.url,
    token: `${input}.${signature}`,
    participantId: String(participant.call_local_identity),
    expiresAt: new Date(expires * 1_000).toISOString(),
    mediaEpoch: n(row.media_epoch),
  };
}

function makeLiveKitAdminToken(
  config: LiveKitConfiguration,
  video: Record<string, unknown>,
): string {
  const now = Math.floor(Date.now() / 1_000);
  const header = Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" })).toString("base64url");
  const claims = Buffer.from(JSON.stringify({
    iss: config.apiKey,
    nbf: now - 5,
    iat: now,
    exp: now + 60,
    jti: crypto.randomUUID(),
    video,
  })).toString("base64url");
  const input = `${header}.${claims}`;
  return `${input}.${createHmac("sha256", config.apiSecret).update(input).digest("base64url")}`;
}

function liveKitHTTPBase(config: LiveKitConfiguration): string {
  const url = new URL(config.url);
  url.protocol = url.protocol === "wss:" ? "https:" : url.protocol === "ws:" ? "http:" : url.protocol;
  url.pathname = "/";
  return url.toString().replace(/\/$/, "");
}

async function liveKitRoomRequest(
  config: LiveKitConfiguration,
  method: "CreateRoom" | "UpdateParticipant" | "RemoveParticipant",
  body: Record<string, unknown>,
  videoGrant: Record<string, unknown>,
  acceptedCodes: ReadonlySet<string> = new Set(),
): Promise<void> {
  let response: Response;
  try {
    response = await fetch(
      `${liveKitHTTPBase(config)}/twirp/livekit.RoomService/${method}`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${makeLiveKitAdminToken(config, videoGrant)}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(SFU_CONTROL_TIMEOUT_MS),
      },
    );
  } catch {
    throw new GroupCallError("group media control is unavailable", "sfu_control_unavailable", 503);
  }
  if (response.ok) return;
  let code = "unknown";
  try {
    const value = await response.json() as { code?: unknown };
    if (typeof value.code === "string" && value.code.length <= 64) code = value.code;
  } catch {}
  if (acceptedCodes.has(code)) return;
  throw new GroupCallError("group media control is unavailable", "sfu_control_unavailable", 503);
}

function defaultGroupCallSFUControl(): GroupCallSFUControl {
  const config = liveKitConfiguration();
  return {
    ensureRoom: async (room, participantLimit) => liveKitRoomRequest(
      config,
      "CreateRoom",
      {
        name: room,
        emptyTimeout: 60,
        departureTimeout: 30,
        maxParticipants: participantLimit,
      },
      { roomCreate: true },
      new Set(["already_exists", "alreadyExists"]),
    ),
    updateParticipant: async (input) => {
      const sources: string[] = input.mediaAllowed ? ["MICROPHONE"] : [];
      if (input.mediaAllowed && input.cameraAllowed) sources.push("CAMERA");
      if (input.mediaAllowed && input.screenShareAllowed) {
        sources.push("SCREEN_SHARE", "SCREEN_SHARE_AUDIO");
      }
      await liveKitRoomRequest(
        config,
        "UpdateParticipant",
        {
          room: input.room,
          identity: input.identity,
          permission: {
            canSubscribe: input.mediaAllowed,
            canPublish: input.mediaAllowed,
            canPublishData: false,
            canPublishSources: sources,
            hidden: false,
            canUpdateMetadata: false,
            canSubscribeMetrics: false,
          },
        },
        { room: input.room, roomAdmin: true },
      );
    },
    removeParticipant: async (room, identity) => {
      // LiveKit rejects tokens whose `nbf` is earlier than this second. Advance one full second so
      // an old token issued immediately before the mutation cannot compare equal to the cutoff.
      const tokenNotBefore = config.managedCloud ? Math.floor(Date.now() / 1_000) + 1 : 0;
      await liveKitRoomRequest(
        config,
        "RemoveParticipant",
        {
          room,
          identity,
          ...(tokenNotBefore > 0 ? { revokeTokenTs: tokenNotBefore } : {}),
        },
        { room, roomAdmin: true },
        new Set(["not_found", "notFound"]),
      );
      return tokenNotBefore;
    },
  };
}

async function initializeParticipantSFUState(
  sql: SQL,
  row: GroupCallRow,
  participant: ParticipantRow,
): Promise<void> {
  const mediaAllowed = row.state === "active"
    && participant.status === "active"
    && n(participant.ready_media_epoch) === n(row.media_epoch)
    && n(participant.joined_membership_revision) === n(row.membership_revision);
  await sql`
    INSERT INTO group_call_sfu_participant_states (
      call_id, device_id, participant_identity, desired_status,
      media_allowed, camera_allowed, screen_share_allowed, revision, applied_revision,
      applied_media_allowed
    ) VALUES (
      ${row.id}, ${participant.device_id}, ${participant.call_local_identity}, 'active',
      ${mediaAllowed}, FALSE, FALSE, 1, 1, ${mediaAllowed}
    )
    ON CONFLICT (call_id, participant_identity) DO NOTHING`;
}

async function queueParticipantSFUState(
  sql: SQL,
  row: GroupCallRow,
  deviceId: string,
  force = false,
): Promise<void> {
  const participant = (await sql`
    SELECT * FROM group_call_participants
    WHERE call_id = ${row.id} AND device_id = ${deviceId}`)[0];
  if (!participant) return;
  const active = participant.status === "active" || participant.status === "pending_key";
  const currentEpoch = (await sql`
    SELECT membership_revision FROM group_call_epochs
    WHERE call_id = ${row.id} AND epoch = ${row.media_epoch}`)[0];
  const mediaAllowed = row.state === "active"
    && participant.status === "active"
    && n(participant.ready_media_epoch) === n(row.media_epoch)
    && n(currentEpoch?.membership_revision) === n(row.membership_revision);
  const cameraAllowed = mediaAllowed && Boolean((await sql`
    SELECT 1 FROM group_call_camera_leases
    WHERE call_id = ${row.id} AND device_id = ${deviceId} AND expires_at > now()`)[0]);
  const screenAllowed = mediaAllowed && Boolean((await sql`
    SELECT 1 FROM group_call_screen_share_leases
    WHERE call_id = ${row.id} AND device_id = ${deviceId} AND expires_at > now()`)[0]);
  const desiredStatus = active ? "active" : "removed";
  await sql`
    INSERT INTO group_call_sfu_participant_states (
      call_id, device_id, participant_identity, desired_status,
      media_allowed, camera_allowed, screen_share_allowed, revision, applied_revision,
      next_attempt_at
    ) VALUES (
      ${row.id}, ${deviceId}, ${participant.call_local_identity}, ${desiredStatus},
      ${mediaAllowed}, ${cameraAllowed}, ${screenAllowed}, 1, 0, now()
    )
    ON CONFLICT (call_id, participant_identity) DO UPDATE SET
      device_id = excluded.device_id,
      desired_status = excluded.desired_status,
      media_allowed = excluded.media_allowed,
      camera_allowed = excluded.camera_allowed,
      screen_share_allowed = excluded.screen_share_allowed,
      revision = CASE WHEN
        ${force}
        OR group_call_sfu_participant_states.desired_status IS DISTINCT FROM excluded.desired_status
        OR group_call_sfu_participant_states.media_allowed IS DISTINCT FROM excluded.media_allowed
        OR group_call_sfu_participant_states.camera_allowed IS DISTINCT FROM excluded.camera_allowed
        OR group_call_sfu_participant_states.screen_share_allowed IS DISTINCT FROM excluded.screen_share_allowed
        THEN group_call_sfu_participant_states.revision + 1
        ELSE group_call_sfu_participant_states.revision
      END,
      attempt_count = CASE WHEN
        ${force}
        OR group_call_sfu_participant_states.desired_status IS DISTINCT FROM excluded.desired_status
        OR group_call_sfu_participant_states.media_allowed IS DISTINCT FROM excluded.media_allowed
        OR group_call_sfu_participant_states.camera_allowed IS DISTINCT FROM excluded.camera_allowed
        OR group_call_sfu_participant_states.screen_share_allowed IS DISTINCT FROM excluded.screen_share_allowed
        THEN 0
        ELSE group_call_sfu_participant_states.attempt_count
      END,
      next_attempt_at = LEAST(group_call_sfu_participant_states.next_attempt_at, now()),
      last_error_code = NULL,
      updated_at = now()`;
}

async function queueLiveParticipantSFUStates(
  sql: SQL,
  row: GroupCallRow,
  force = false,
): Promise<string[]> {
  const participants = await sql`
    SELECT device_id FROM group_call_participants
    WHERE call_id = ${row.id} AND status IN ('pending_key','active')
    ORDER BY device_id`;
  const deviceIds = participants.map((participant: any) => String(participant.device_id));
  for (const deviceId of deviceIds) {
    await queueParticipantSFUState(sql, row, deviceId, force);
  }
  return deviceIds;
}

type ClaimedSFUState = {
  callId: string;
  deviceId: string;
  room: string;
  identity: string;
  desiredStatus: "active" | "removed";
  mediaAllowed: boolean;
  appliedMediaAllowed: boolean;
  appliedCameraAllowed: boolean;
  appliedScreenShareAllowed: boolean;
  cameraAllowed: boolean;
  screenShareAllowed: boolean;
  revision: number;
  claimToken: string;
};

async function claimParticipantSFUState(
  sql: SQL,
  callId: string,
  deviceId: string,
): Promise<ClaimedSFUState | null | "busy"> {
  return sql.begin(async (tx) => {
    const state = (await tx`
      SELECT state.*, call.sfu_room_name
      FROM group_call_sfu_participant_states state
      JOIN group_calls call ON call.id = state.call_id
      WHERE state.call_id = ${callId} AND state.device_id = ${deviceId}
        AND state.applied_revision < state.revision
        AND state.next_attempt_at <= now()
        AND (state.claim_token IS NULL OR state.claim_expires_at <= now())
        AND NOT EXISTS (
          SELECT 1 FROM group_call_sfu_participant_states blocker
          WHERE blocker.call_id = state.call_id
            AND blocker.participant_identity <> state.participant_identity
            AND blocker.applied_revision < blocker.revision
            AND (
              (state.media_allowed AND (
                (blocker.applied_status = 'active' AND blocker.desired_status = 'removed')
                OR (blocker.applied_media_allowed AND NOT blocker.media_allowed)
              ))
              OR
              (state.camera_allowed AND (
                (blocker.applied_status = 'active' AND blocker.desired_status = 'removed')
                OR (blocker.applied_camera_allowed AND NOT blocker.camera_allowed)
              ))
              OR (state.screen_share_allowed AND (
                (blocker.applied_status = 'active' AND blocker.desired_status = 'removed')
                OR (blocker.applied_screen_share_allowed AND NOT blocker.screen_share_allowed)
              ))
            )
        )
      ORDER BY (state.desired_status = 'removed') DESC, state.updated_at,
        state.participant_identity
      FOR UPDATE OF state SKIP LOCKED
      LIMIT 1`)[0];
    if (!state) {
      const pending = await tx`
        SELECT 1 FROM group_call_sfu_participant_states
        WHERE call_id = ${callId} AND device_id = ${deviceId}
          AND applied_revision < revision
        LIMIT 1`;
      return pending.length ? "busy" : null;
    }
    const claimToken = crypto.randomUUID();
    await tx`
      UPDATE group_call_sfu_participant_states SET
        claim_token = ${claimToken}, claim_revision = ${n(state.revision)},
        claim_expires_at = now() + (${SFU_CONTROL_CLAIM_SECONDS} * interval '1 second'),
        attempt_count = attempt_count + 1, updated_at = now()
      WHERE call_id = ${callId}
        AND participant_identity = ${state.participant_identity}`;
    return {
      callId,
      deviceId,
      room: String(state.sfu_room_name),
      identity: String(state.participant_identity),
      desiredStatus: state.desired_status,
      mediaAllowed: Boolean(state.media_allowed),
      appliedMediaAllowed: Boolean(state.applied_media_allowed),
      appliedCameraAllowed: Boolean(state.applied_camera_allowed),
      appliedScreenShareAllowed: Boolean(state.applied_screen_share_allowed),
      cameraAllowed: Boolean(state.camera_allowed),
      screenShareAllowed: Boolean(state.screen_share_allowed),
      revision: n(state.revision),
      claimToken,
    };
  });
}

export async function reconcileGroupCallSFUParticipant(
  sql: SQL,
  callId: string,
  deviceId: string,
  control: GroupCallSFUControl = defaultGroupCallSFUControl(),
): Promise<boolean> {
  for (let pass = 0; pass < 16; pass += 1) {
    const claimed = await claimParticipantSFUState(sql, callId, deviceId);
    if (claimed === null) return true;
    if (claimed === "busy") return false;
    let tokenNotBefore = 0;
    try {
      if (claimed.desiredStatus === "removed" || !claimed.mediaAllowed) {
        tokenNotBefore = await control.removeParticipant(claimed.room, claimed.identity);
        if (!Number.isSafeInteger(tokenNotBefore) || tokenNotBefore < 0) {
          throw new GroupCallError("group media control is unavailable", "sfu_control_unavailable", 503);
        }
      } else if (!claimed.appliedMediaAllowed
        && !claimed.appliedCameraAllowed
        && !claimed.appliedScreenShareAllowed
        && !claimed.cameraAllowed
        && !claimed.screenShareAllowed) {
        // A successful epoch fence disconnects the old session and revokes its token. Moving from
        // media-denied to microphone-only therefore needs no mutation of a participant that is not
        // in the room yet; the freshly minted post-epoch token carries the base permission.
      } else {
        await control.updateParticipant({
          room: claimed.room,
          identity: claimed.identity,
          mediaAllowed: claimed.mediaAllowed,
          cameraAllowed: claimed.cameraAllowed,
          screenShareAllowed: claimed.screenShareAllowed,
        });
      }
    } catch (error) {
      const attempt = n((await sql`
        SELECT attempt_count FROM group_call_sfu_participant_states
        WHERE call_id = ${callId}
          AND participant_identity = ${claimed.identity}`)[0]?.attempt_count ?? 1);
      const delay = Math.min(30, 2 ** Math.min(attempt, 5));
      await sql`
        UPDATE group_call_sfu_participant_states SET
          claim_token = NULL, claim_revision = NULL, claim_expires_at = NULL,
          next_attempt_at = now() + (${delay} * interval '1 second'),
          last_error_code = 'request_failed', updated_at = now()
        WHERE call_id = ${callId}
          AND participant_identity = ${claimed.identity}
          AND claim_token = ${claimed.claimToken}`;
      if (error instanceof GroupCallError) throw error;
      throw new GroupCallError("group media control is unavailable", "sfu_control_unavailable", 503);
    }
    await sql`
      UPDATE group_call_sfu_participant_states SET
        applied_revision = GREATEST(applied_revision, ${claimed.revision}),
        applied_status = ${claimed.desiredStatus},
        applied_media_allowed = ${claimed.mediaAllowed},
        applied_camera_allowed = ${claimed.cameraAllowed},
        applied_screen_share_allowed = ${claimed.screenShareAllowed},
        token_not_before = GREATEST(token_not_before, ${tokenNotBefore}),
        claim_token = NULL, claim_revision = NULL, claim_expires_at = NULL,
        attempt_count = 0, next_attempt_at = now(), last_error_code = NULL, updated_at = now()
      WHERE call_id = ${callId}
        AND participant_identity = ${claimed.identity}
        AND claim_token = ${claimed.claimToken}`;
  }
  return false;
}

export async function reconcilePendingGroupCallSFUStates(
  sql: SQL,
  limit = 100,
  control: GroupCallSFUControl = defaultGroupCallSFUControl(),
): Promise<number> {
  const pending = await sql`
    SELECT call_id, device_id, min(next_attempt_at) AS next_attempt_at,
      min(updated_at) AS updated_at
    FROM group_call_sfu_participant_states
    WHERE applied_revision < revision AND next_attempt_at <= now()
      AND (claim_token IS NULL OR claim_expires_at <= now())
    GROUP BY call_id, device_id
    ORDER BY next_attempt_at, updated_at
    LIMIT ${Math.max(1, Math.min(limit, 1_000))}`;
  let processed = 0;
  let failed = 0;
  let nextIndex = 0;
  const workerCount = Math.min(8, pending.length);
  await Promise.all(Array.from({ length: workerCount }, async () => {
    while (nextIndex < pending.length) {
      const state = pending[nextIndex++];
      try {
        if (await reconcileGroupCallSFUParticipant(
          sql,
          String(state.call_id),
          String(state.device_id),
          control,
        )) processed += 1;
      } catch {
        failed += 1;
      }
    }
  }));
  if (failed > 0) {
    console.error(JSON.stringify({
      ts: new Date().toISOString(),
      event: "group_call.sfu_reconcile.batch_failed",
      failed,
      selected: pending.length,
    }));
  }
  return processed;
}

export function startGroupCallSFUWorker(
  sql: SQL,
  intervalMs = 2_000,
  control: GroupCallSFUControl = defaultGroupCallSFUControl(),
): () => void {
  let running = false;
  const tick = async () => {
    if (running) return;
    running = true;
    try {
      if ((await groupCallSchemaReadiness(sql)).ready) {
        await reconcilePendingGroupCallSFUStates(sql, 100, control);
      }
    } catch (error) {
      console.error(JSON.stringify({
        ts: new Date().toISOString(),
        event: "group_call.sfu_reconcile.error",
        errorType: error instanceof Error ? error.name : "UnknownError",
      }));
    } finally {
      running = false;
    }
  };
  void tick();
  const timer = setInterval(() => { void tick(); }, intervalMs);
  timer.unref?.();
  return () => clearInterval(timer);
}

type GroupCallMutationResult = {
  call: GroupCallSnapshot; hints: GroupCallHint[]; duplicate: boolean;
};

type GroupCallReleaseResult = { released: true; hints: GroupCallHint[] };

export async function startGroupCall(sql: SQL, input: {
  accountId: string; deviceId: string; callId: unknown; dialogId: unknown;
  initialKind: unknown; joinPublicKey: unknown; joinNonce: unknown; epochKeyCommitment: unknown;
}, control: GroupCallSFUControl = defaultGroupCallSFUControl()): Promise<{
  call: GroupCallSnapshot; credentials: GroupCallCredentials; hints: GroupCallHint[];
  duplicate: boolean }> {
  const config = liveKitConfiguration();
  const callId = requireUUID(input.callId, "callId");
  const dialogId = requireUUID(input.dialogId, "dialogId");
  const kind = initialKind(input.initialKind);
  const joinPublicKey = decodeJoinMaterial(input.joinPublicKey, "joinPublicKey");
  const joinNonce = decodeJoinMaterial(input.joinNonce, "joinNonce");
  const epochCommitment = decodeBase64(input.epochKeyCommitment, "epochKeyCommitment", 32);
  const result = await sql.begin<{
    call: GroupCallSnapshot; credentials: GroupCallCredentials | null; hints: GroupCallHint[];
    duplicate: boolean;
  }>(async (tx) => {
    await requireGroupMediaDevice(tx, input.accountId, input.deviceId);
    const access = await lockDialogForMutation(tx, input.accountId, dialogId).catch(mapDialogError);
    requireGroupRole(access, ["owner", "admin", "member"]);
    const existing = (await tx`SELECT * FROM group_calls WHERE id = ${callId} FOR UPDATE`)[0];
    if (existing) {
      const participant = (await tx`
        SELECT * FROM group_call_participants
        WHERE call_id = ${callId} AND device_id = ${input.deviceId}`)[0];
      if (existing.dialog_id !== dialogId || existing.creator_account_id !== input.accountId
        || existing.creator_device_id !== input.deviceId || existing.initial_kind !== kind
        || !participant || !sameBytes(participant.join_public_key, joinPublicKey)
        || !sameBytes(participant.join_nonce, joinNonce)
        || !sameBytes(existing.epoch_key_commitment, epochCommitment)) {
        throw new GroupCallError("call id was reused with different details", "idempotency_conflict", 409);
      }
      if (existing.state !== "active" || participant.status !== "active") {
        throw new GroupCallError("group call has ended", "call_ended", 410);
      }
      return {
        call: await loadSnapshot(tx, existing, input.accountId, input.deviceId),
        credentials: null as GroupCallCredentials | null, hints: [], duplicate: true,
      };
    }
    const active = (await tx`
      SELECT id FROM group_calls WHERE dialog_id = ${dialogId} AND state = 'active' FOR UPDATE`)[0];
    if (active) {
      throw new GroupCallError("a group call is already active", "call_already_active", 409, {
        existingCallId: active.id,
      });
    }
    await enforceBudget(tx, input.accountId, input.deviceId, "start");
    const participantId = crypto.randomUUID();
    let row = (await tx`
      INSERT INTO group_calls (
        id, dialog_id, creator_account_id, creator_device_id, initial_kind, sfu_room_name,
        participant_limit, publisher_limit, key_leader_device_id, epoch_key_commitment
      ) VALUES (
        ${callId}, ${dialogId}, ${input.accountId}, ${input.deviceId}, ${kind}, ${makeRoomName()},
        ${PARTICIPANT_LIMIT}, ${PUBLISHER_LIMIT}, ${input.deviceId}, ${epochCommitment}
      ) RETURNING *`)[0];
    const participant = (await tx`
      INSERT INTO group_call_participants (
        call_id, device_id, account_id, call_local_identity, status, join_public_key, join_nonce,
        joined_membership_revision, ready_media_epoch
      ) VALUES (
        ${callId}, ${input.deviceId}, ${input.accountId}, ${participantId}, 'active',
        ${joinPublicKey}, ${joinNonce}, 1, 1
      ) RETURNING *`)[0];
    await initializeParticipantSFUState(tx, row, participant);
    const setHash = participantSetHash([participant]);
    await tx`
      INSERT INTO group_call_epochs (
        call_id, epoch, membership_revision, leader_device_id, key_commitment,
        participant_set_hash, grace_expires_at
      ) VALUES (${callId}, 1, 1, ${input.deviceId}, ${epochCommitment}, ${setHash}, NULL)`;
    row = (await tx`UPDATE group_calls SET updated_at = now() WHERE id = ${callId} RETURNING *`)[0];
    await notify(tx, row);
    return {
      call: await loadSnapshot(tx, row, input.accountId, input.deviceId),
      credentials: makeLiveKitToken(config, row, participant),
      hints: await hintTargets(tx, row), duplicate: false,
    };
  });
  try {
    const room = (await sql`
      SELECT sfu_room_name FROM group_calls WHERE id = ${callId}`)[0];
    if (!room) throw new GroupCallError("group call not found", "not_found", 404);
    await control.ensureRoom(String(room.sfu_room_name), result.call.participantLimit);
  } catch (error) {
    if (!result.duplicate) {
      await sql.begin(async (tx) => {
        const ended = (await tx`
          UPDATE group_calls SET state = 'ended', ended_at = now(), end_reason = 'sfu_unavailable',
            state_revision = state_revision + 1, updated_at = now()
          WHERE id = ${callId} AND state = 'active' RETURNING *`)[0];
        if (ended) {
          await tx`
            UPDATE group_call_participants SET status = 'left', ready_media_epoch = NULL,
              left_at = now(), last_seen_at = now()
            WHERE call_id = ${callId} AND status IN ('pending_key','active')`;
          await queueParticipantSFUState(tx, ended, input.deviceId);
          await notify(tx, ended);
        }
      });
    }
    throw error;
  }
  if (result.duplicate) {
    result.credentials = (await getGroupCallCredentials(
      sql,
      input.accountId,
      input.deviceId,
      callId,
      control,
    )).credentials;
  }
  if (!result.credentials) {
    throw new GroupCallError("group media credentials are unavailable", "sfu_control_unavailable", 503);
  }
  return { ...result, credentials: result.credentials };
}

export async function joinGroupCall(sql: SQL, input: {
  accountId: string; deviceId: string; callId: unknown; joinPublicKey: unknown; joinNonce: unknown;
}, control: GroupCallSFUControl = defaultGroupCallSFUControl()): Promise<{
  call: GroupCallSnapshot; hints: GroupCallHint[]; duplicate: boolean;
}> {
  const callId = requireUUID(input.callId, "callId");
  const joinPublicKey = decodeJoinMaterial(input.joinPublicKey, "joinPublicKey");
  const joinNonce = decodeJoinMaterial(input.joinNonce, "joinNonce");
  const result = await sql.begin<GroupCallMutationResult>(async (tx) => {
    await requireGroupMediaDevice(tx, input.accountId, input.deviceId);
    const base = (await tx`SELECT dialog_id FROM group_calls WHERE id = ${callId}`)[0];
    if (!base) throw new GroupCallError("group call not found", "not_found", 404);
    const access = await lockDialogForMutation(tx, input.accountId, base.dialog_id).catch(mapDialogError);
    requireGroupRole(access, ["owner", "admin", "member"]);
    let row = (await tx`SELECT * FROM group_calls WHERE id = ${callId} FOR UPDATE`)[0];
    if (!row || row.state !== "active") throw new GroupCallError("group call has ended", "call_ended", 410);
    const existing = (await tx`
      SELECT * FROM group_call_participants
      WHERE call_id = ${callId} AND device_id = ${input.deviceId} FOR UPDATE`)[0];
    const removedAccount = await tx`
      SELECT 1 FROM group_call_participants
      WHERE call_id = ${callId} AND account_id = ${input.accountId} AND status = 'removed'
      LIMIT 1 FOR UPDATE`;
    if (removedAccount.length) {
      throw new GroupCallError("this account was removed from the call", "removed_from_call", 403);
    }
    if (existing?.status === "active" || existing?.status === "pending_key") {
      if (!sameBytes(existing.join_public_key, joinPublicKey)
        || !sameBytes(existing.join_nonce, joinNonce)) {
        throw new GroupCallError("join key changed on retry", "idempotency_conflict", 409);
      }
      return { call: await loadSnapshot(tx, row, input.accountId, input.deviceId),
        hints: [], duplicate: true };
    }
    const anotherDevice = (await tx`
      SELECT device_id FROM group_call_participants
      WHERE call_id = ${callId} AND account_id = ${input.accountId}
        AND status IN ('pending_key','active') FOR UPDATE`)[0];
    if (anotherDevice) {
      throw new GroupCallError("this account joined on another device", "joined_elsewhere", 409);
    }
    const joinedCount = n((await tx`
      SELECT count(*)::int AS count FROM group_call_participants
      WHERE call_id = ${callId} AND status IN ('pending_key','active')`)[0].count);
    if (joinedCount >= n(row.participant_limit)) {
      throw new GroupCallError("group call is full", "participant_limit_reached", 409);
    }
    await enforceBudget(tx, input.accountId, input.deviceId, "join");
    const membershipRevision = n(row.membership_revision) + 1;
    const participantId = crypto.randomUUID();
    if (existing) {
      await tx`
        UPDATE group_call_participants SET
          call_local_identity = ${participantId}, status = 'pending_key',
          join_public_key = ${joinPublicKey}, join_nonce = ${joinNonce},
          joined_membership_revision = ${membershipRevision}, ready_media_epoch = NULL,
          joined_at = now(), last_seen_at = now(), left_at = NULL
        WHERE call_id = ${callId} AND device_id = ${input.deviceId}`;
    } else {
      await tx`
        INSERT INTO group_call_participants (
          call_id, device_id, account_id, call_local_identity, status, join_public_key, join_nonce,
          joined_membership_revision
        ) VALUES (
          ${callId}, ${input.deviceId}, ${input.accountId}, ${participantId}, 'pending_key',
          ${joinPublicKey}, ${joinNonce}, ${membershipRevision}
        )`;
    }
    const participant = (await tx`
      SELECT * FROM group_call_participants
      WHERE call_id = ${callId} AND device_id = ${input.deviceId}`)[0];
    await initializeParticipantSFUState(tx, row, participant);
    row = (await tx`
      UPDATE group_calls SET membership_revision = ${membershipRevision},
        state_revision = state_revision + 1, updated_at = now()
      WHERE id = ${callId} RETURNING *`)[0];
    // A membership revision invalidates every pre-change room token, not only the newcomer. Leases
    // are epoch-scoped in practice even though their rows are short lived, so discard them before
    // queuing the room-wide disconnect barrier.
    await tx`DELETE FROM group_call_screen_share_leases WHERE call_id = ${callId}`;
    await tx`DELETE FROM group_call_camera_leases WHERE call_id = ${callId}`;
    await queueLiveParticipantSFUStates(tx, row);
    await notify(tx, row);
    return { call: await loadSnapshot(tx, row, input.accountId, input.deviceId),
      hints: await hintTargets(tx, row), duplicate: false };
  });
  await requireGroupCallSFUBarrierApplied(sql, [callId], control);
  return result;
}

type NormalizedEnvelope = { recipientDeviceId: string; ciphertext: Buffer };

function normalizeEnvelopes(value: unknown): NormalizedEnvelope[] {
  if (!Array.isArray(value) || value.length > PARTICIPANT_LIMIT - 1) {
    throw new GroupCallError("epoch envelopes are invalid", "invalid_request");
  }
  const result = value.map((entry: any) => ({
    recipientDeviceId: requireUUID(entry?.recipientDeviceId, "recipientDeviceId"),
    ciphertext: decodeBase64(entry?.ciphertext, "ciphertext"),
  }));
  if (result.some((entry) => entry.ciphertext.length < 48 || entry.ciphertext.length > 4_096)) {
    throw new GroupCallError("epoch ciphertext size is invalid", "invalid_request");
  }
  if (new Set(result.map((entry) => entry.recipientDeviceId)).size !== result.length) {
    throw new GroupCallError("epoch recipients must be unique", "invalid_request");
  }
  return result.sort((left, right) => left.recipientDeviceId.localeCompare(right.recipientDeviceId));
}

export async function activateGroupCallEpoch(sql: SQL, input: {
  accountId: string; deviceId: string; callId: unknown; epoch: unknown;
  expectedMembershipRevision: unknown; keyCommitment: unknown; participantSetHash: unknown;
  envelopes: unknown;
}, control: GroupCallSFUControl = defaultGroupCallSFUControl()): Promise<{
  call: GroupCallSnapshot; hints: GroupCallHint[]; duplicate: boolean;
}> {
  const callId = requireUUID(input.callId, "callId");
  const requestedEpoch = Number(input.epoch);
  const expectedRevision = Number(input.expectedMembershipRevision);
  if (!Number.isSafeInteger(requestedEpoch) || requestedEpoch < 1
    || !Number.isSafeInteger(expectedRevision) || expectedRevision < 1) {
    throw new GroupCallError("epoch revision is invalid", "invalid_request");
  }
  const keyCommitment = decodeBase64(input.keyCommitment, "keyCommitment", 32);
  const suppliedSetHash = decodeBase64(input.participantSetHash, "participantSetHash", 32);
  const envelopes = normalizeEnvelopes(input.envelopes);
  const result = await sql.begin<GroupCallMutationResult>(async (tx) => {
    await requireGroupMediaDevice(tx, input.accountId, input.deviceId);
    const base = (await tx`SELECT dialog_id FROM group_calls WHERE id = ${callId}`)[0];
    if (!base) throw new GroupCallError("group call not found", "not_found", 404);
    await lockDialogForMutation(tx, input.accountId, base.dialog_id).catch(mapDialogError);
    let row = await authorizedCall(tx, input.accountId, input.deviceId, callId, true);
    if (row.state !== "active") throw new GroupCallError("group call has ended", "call_ended", 410);
    if (row.key_leader_device_id !== input.deviceId) {
      throw new GroupCallError("only the current key leader can activate an epoch", "not_key_leader", 403);
    }
    if (requestedEpoch === n(row.media_epoch)) {
      const existing = (await tx`
        SELECT * FROM group_call_epochs WHERE call_id = ${callId} AND epoch = ${requestedEpoch}`)[0];
      const storedEnvelopes = await tx`
        SELECT recipient_device_id, ciphertext FROM group_call_epoch_envelopes
        WHERE call_id = ${callId} AND epoch = ${requestedEpoch}
        ORDER BY recipient_device_id`;
      const envelopeMatch = storedEnvelopes.length === envelopes.length
        && storedEnvelopes.every((stored: any, index: number) =>
          stored.recipient_device_id === envelopes[index].recipientDeviceId
          && sameBytes(stored.ciphertext, envelopes[index].ciphertext));
      if (existing && n(existing.membership_revision) === expectedRevision
        && sameBytes(existing.key_commitment, keyCommitment)
        && sameBytes(existing.participant_set_hash, suppliedSetHash) && envelopeMatch) {
        return { call: await loadSnapshot(tx, row, input.accountId, input.deviceId),
          hints: [], duplicate: true };
      }
      throw new GroupCallError("epoch retry changed details", "idempotency_conflict", 409);
    }
    if (requestedEpoch !== n(row.media_epoch) + 1) {
      throw new GroupCallError("epoch is out of sequence", "sequence_error", 409);
    }
    if (expectedRevision !== n(row.membership_revision)) {
      throw new GroupCallError("membership changed during rekey", "stale_membership", 409, {
        currentMembershipRevision: n(row.membership_revision),
      });
    }
    const participants: ParticipantRow[] = await tx`
      SELECT * FROM group_call_participants
      WHERE call_id = ${callId} AND status IN ('pending_key','active')
      ORDER BY device_id FOR UPDATE`;
    const setHash = participantSetHash(participants);
    if (!setHash.equals(suppliedSetHash)) {
      throw new GroupCallError("participant transcript mismatch", "stale_membership", 409);
    }
    const recipients = participants
      .filter((participant) => participant.device_id !== input.deviceId)
      .map((participant) => String(participant.device_id)).sort();
    if (recipients.length !== envelopes.length
      || recipients.some((recipient, index) => recipient !== envelopes[index].recipientDeviceId)) {
      throw new GroupCallError("epoch must cover every participant exactly once", "incomplete_epoch", 409);
    }
    const leader = participants.find((participant) => participant.device_id === input.deviceId);
    if (!leader) throw new GroupCallError("key leader is not joined", "invalid_state", 409);
    await tx`
      UPDATE group_call_epochs
      SET grace_expires_at = now() + (${EPOCH_GRACE_SECONDS} * interval '1 second')
      WHERE call_id = ${callId} AND epoch = ${row.media_epoch}`;
    await tx`
      INSERT INTO group_call_epochs (
        call_id, epoch, membership_revision, leader_device_id, key_commitment,
        participant_set_hash, grace_expires_at
      ) VALUES (
        ${callId}, ${requestedEpoch}, ${expectedRevision}, ${input.deviceId}, ${keyCommitment},
        ${setHash}, NULL
      )`;
    for (const envelope of envelopes) {
      const recipient = participants.find((candidate) =>
        candidate.device_id === envelope.recipientDeviceId)!;
      await tx`
        INSERT INTO group_call_epoch_envelopes (
          call_id, epoch, recipient_device_id, sender_public_key,
          recipient_public_key, ciphertext
        ) VALUES (
          ${callId}, ${requestedEpoch}, ${envelope.recipientDeviceId}, ${leader.join_public_key},
          ${recipient.join_public_key}, ${envelope.ciphertext}
        )`;
    }
    await tx`
      UPDATE group_call_participants
      SET status = 'active', ready_media_epoch = ${requestedEpoch}, last_seen_at = now()
      WHERE call_id = ${callId} AND status IN ('pending_key','active')`;
    row = (await tx`
      UPDATE group_calls SET media_epoch = ${requestedEpoch},
        state_revision = state_revision + 1,
        epoch_key_commitment = ${keyCommitment}, updated_at = now()
      WHERE id = ${callId} RETURNING *`)[0];
    await queueLiveParticipantSFUStates(tx, row);
    await notify(tx, row);
    return { call: await loadSnapshot(tx, row, input.accountId, input.deviceId),
      hints: await hintTargets(tx, row), duplicate: false };
  });
  await requireGroupCallSFUBarrierApplied(sql, [callId], control);
  return result;
}

export async function getGroupCall(sql: SQL, accountId: string, deviceId: string,
  rawCallId: unknown): Promise<{ call: GroupCallSnapshot }> {
  const callId = requireUUID(rawCallId, "callId");
  return sql.begin(async (tx) => {
    const row = await authorizedCall(tx, accountId, deviceId, callId, "share");
    return { call: await loadSnapshot(tx, row, accountId, deviceId) };
  });
}

export async function getActiveGroupCall(sql: SQL, accountId: string, deviceId: string,
  rawDialogId: unknown): Promise<{ call: GroupCallSnapshot | null }> {
  const dialogId = requireUUID(rawDialogId, "dialogId");
  return sql.begin(async (tx) => {
    await requireGroupMediaDevice(tx, accountId, deviceId);
    await requireDialogReadAccess(tx, accountId, dialogId).catch(mapDialogError);
    const row = (await tx`
      SELECT * FROM group_calls
      WHERE dialog_id = ${dialogId} AND state = 'active' FOR SHARE`)[0];
    return { call: row ? await loadSnapshot(tx, row, accountId, deviceId) : null };
  });
}

export async function getGroupCallCredentials(sql: SQL, accountId: string, deviceId: string,
  rawCallId: unknown,
  control: GroupCallSFUControl = defaultGroupCallSFUControl(),
): Promise<{ credentials: GroupCallCredentials }> {
  const config = liveKitConfiguration();
  const callId = requireUUID(rawCallId, "callId");
  // Never let an authenticated non-member use a guessed call UUID to drive the external SFU
  // reconciliation plane. The final credential transaction revalidates after the barrier.
  await sql.begin(async (tx) => {
    const row = await authorizedCall(tx, accountId, deviceId, callId, "share");
    if (row.state !== "active") {
      throw new GroupCallError("group call has ended", "call_ended", 410);
    }
    const participant = await tx`
      SELECT 1 FROM group_call_participants
      WHERE call_id = ${callId} AND device_id = ${deviceId}
        AND status IN ('pending_key','active')`;
    if (!participant.length) {
      throw new GroupCallError("device is not joined", "not_joined", 409);
    }
  });
  await requireGroupCallSFUBarrierApplied(sql, [callId], control);
  const tokenFence = (await sql`
    SELECT state.token_not_before
    FROM group_call_participants participant
    JOIN group_call_sfu_participant_states state
      ON state.call_id = participant.call_id
      AND state.participant_identity = participant.call_local_identity
    WHERE participant.call_id = ${callId} AND participant.device_id = ${deviceId}`)[0];
  const tokenNotBefore = n(tokenFence?.token_not_before ?? 0);
  const waitMilliseconds = tokenNotBefore * 1_000 - Date.now();
  if (waitMilliseconds > 5_000) {
    throw new GroupCallError("group media control is unavailable", "sfu_control_unavailable", 503);
  }
  if (waitMilliseconds > 0) {
    await new Promise((resolve) => setTimeout(resolve, waitMilliseconds));
  }
  return sql.begin(async (tx) => {
    const row = await authorizedCall(tx, accountId, deviceId, callId, true);
    if (row.state !== "active") throw new GroupCallError("group call has ended", "call_ended", 410);
    const participant = await requireCurrentMediaEpoch(tx, row, deviceId);
    const mediaAuthorization = (await tx`
      SELECT token_not_before FROM group_call_sfu_participant_states
      WHERE call_id = ${callId}
        AND participant_identity = ${participant.call_local_identity}
        AND desired_status = 'active' AND media_allowed
        AND applied_revision = revision
        AND applied_status = 'active' AND applied_media_allowed`)[0];
    if (!mediaAuthorization) {
      throw new GroupCallError("current epoch key is not ready", "epoch_not_ready", 409);
    }
    if (deviceId !== row.key_leader_device_id) {
      const envelope = await tx`
        SELECT 1 FROM group_call_epoch_envelopes
        WHERE call_id = ${callId} AND epoch = ${row.media_epoch}
          AND recipient_device_id = ${deviceId}`;
      if (!envelope.length) throw new GroupCallError("epoch envelope is missing", "security_error", 409);
    }
    await tx`
      UPDATE group_call_participants SET last_seen_at = now()
      WHERE call_id = ${callId} AND device_id = ${deviceId}`;
    return {
      credentials: makeLiveKitToken(
        config,
        row,
        participant,
        n(mediaAuthorization.token_not_before),
      ),
    };
  });
}

async function departParticipantTx(sql: SQL, row: GroupCallRow, deviceId: string,
  status: "left" | "removed", reason: string): Promise<GroupCallRow> {
  const changed = await sql`
    UPDATE group_call_participants SET status = ${status}, ready_media_epoch = NULL,
      left_at = now(), last_seen_at = now()
    WHERE call_id = ${row.id} AND device_id = ${deviceId}
      AND status IN ('pending_key','active') RETURNING device_id`;
  if (!changed.length) return row;
  await sql`
    DELETE FROM group_call_screen_share_leases
    WHERE call_id = ${row.id}`;
  await sql`
    DELETE FROM group_call_camera_leases
    WHERE call_id = ${row.id}`;
  const remaining: ParticipantRow[] = await sql`
    SELECT * FROM group_call_participants
    WHERE call_id = ${row.id} AND status IN ('pending_key','active')
    ORDER BY joined_at, device_id FOR UPDATE`;
  if (!remaining.length) {
    const ended = (await sql`
      UPDATE group_calls SET state = 'ended', ended_at = now(), end_reason = ${reason},
        state_revision = state_revision + 1, updated_at = now()
      WHERE id = ${row.id} RETURNING *`)[0];
    await queueParticipantSFUState(sql, ended, deviceId, true);
    await notify(sql, ended);
    return ended;
  }
  const leaderStillJoined = remaining.some((participant) =>
    participant.device_id === row.key_leader_device_id);
  const leaderDeviceId = leaderStillJoined ? row.key_leader_device_id : remaining[0].device_id;
  const updated = (await sql`
    UPDATE group_calls SET membership_revision = membership_revision + 1,
      state_revision = state_revision + 1,
      key_leader_device_id = ${leaderDeviceId}, updated_at = now()
    WHERE id = ${row.id} RETURNING *`)[0];
  await queueParticipantSFUState(sql, updated, deviceId, true);
  await queueLiveParticipantSFUStates(sql, updated, true);
  await notify(sql, updated);
  return updated;
}

export async function leaveGroupCall(sql: SQL, input: {
  accountId: string; deviceId: string; callId: unknown;
}, control: GroupCallSFUControl = defaultGroupCallSFUControl()): Promise<{
  call: GroupCallSnapshot; hints: GroupCallHint[]; duplicate: boolean;
}> {
  const callId = requireUUID(input.callId, "callId");
  const result = await sql.begin(async (tx) => {
    await requireGroupMediaDevice(tx, input.accountId, input.deviceId);
    const base = (await tx`SELECT dialog_id FROM group_calls WHERE id = ${callId}`)[0];
    if (!base) throw new GroupCallError("group call not found", "not_found", 404);
    await lockDialogForMutation(tx, input.accountId, base.dialog_id).catch(mapDialogError);
    let row = await authorizedCall(tx, input.accountId, input.deviceId, callId, true);
    const participant = (await tx`
      SELECT status FROM group_call_participants
      WHERE call_id = ${callId} AND device_id = ${input.deviceId} FOR UPDATE`)[0];
    if (!participant) throw new GroupCallError("device is not joined", "not_joined", 409);
    const duplicate = participant.status === "left" || participant.status === "removed";
    if (!duplicate) row = await departParticipantTx(tx, row, input.deviceId, "left", "empty");
    return { call: await loadSnapshot(tx, row, input.accountId, input.deviceId),
      hints: duplicate ? [] : await hintTargets(tx, row), duplicate };
  });
  await requireGroupCallSFUBarrierApplied(sql, [callId], control);
  return result;
}

export async function removeGroupCallParticipant(sql: SQL, input: {
  accountId: string; deviceId: string; callId: unknown; targetDeviceId: unknown;
}, control: GroupCallSFUControl = defaultGroupCallSFUControl()): Promise<{
  call: GroupCallSnapshot; hints: GroupCallHint[];
}> {
  const callId = requireUUID(input.callId, "callId");
  const targetDeviceId = requireUUID(input.targetDeviceId, "targetDeviceId");
  const result = await sql.begin(async (tx) => {
    await requireGroupMediaDevice(tx, input.accountId, input.deviceId);
    const base = (await tx`SELECT dialog_id FROM group_calls WHERE id = ${callId}`)[0];
    if (!base) throw new GroupCallError("group call not found", "not_found", 404);
    const access = await lockDialogForMutation(tx, input.accountId, base.dialog_id).catch(mapDialogError);
    requireGroupRole(access, ["owner", "admin"]);
    let row = await authorizedCall(tx, input.accountId, input.deviceId, callId, true);
    const target = (await tx`
      SELECT participant.account_id, member.role
      FROM group_call_participants participant
      JOIN dialog_members member ON member.dialog_id = ${base.dialog_id}
        AND member.account_id = participant.account_id
      WHERE participant.call_id = ${callId} AND participant.device_id = ${targetDeviceId}
        AND participant.status IN ('pending_key','active') FOR UPDATE`)[0];
    if (!target) throw new GroupCallError("participant is unavailable", "participant_not_found", 404);
    if (target.role === "owner" || (target.role === "admin" && access.role !== "owner")) {
      throw new GroupCallError("insufficient group role", "insufficient_group_role", 403);
    }
    row = await departParticipantTx(tx, row, targetDeviceId, "removed", "empty");
    return { call: await loadSnapshot(tx, row, input.accountId, input.deviceId),
      hints: await hintTargets(tx, row) };
  });
  await requireGroupCallSFUBarrierApplied(sql, [callId], control);
  return result;
}

export async function endGroupCall(sql: SQL, input: {
  accountId: string; deviceId: string; callId: unknown; reason?: unknown;
}, control: GroupCallSFUControl = defaultGroupCallSFUControl()): Promise<{
  call: GroupCallSnapshot; hints: GroupCallHint[]; duplicate: boolean;
}> {
  const callId = requireUUID(input.callId, "callId");
  const allowedReasons = new Set(["ended_by_admin", "failed", "security_error"]);
  const reason = typeof input.reason === "string" && allowedReasons.has(input.reason)
    ? input.reason : "ended_by_admin";
  const result = await sql.begin<GroupCallMutationResult>(async (tx) => {
    await requireGroupMediaDevice(tx, input.accountId, input.deviceId);
    const base = (await tx`SELECT dialog_id FROM group_calls WHERE id = ${callId}`)[0];
    if (!base) throw new GroupCallError("group call not found", "not_found", 404);
    const access = await lockDialogForMutation(tx, input.accountId, base.dialog_id).catch(mapDialogError);
    requireGroupRole(access, ["owner", "admin"]);
    let row = await authorizedCall(tx, input.accountId, input.deviceId, callId, true);
    if (row.state === "ended") {
      return { call: await loadSnapshot(tx, row, input.accountId, input.deviceId),
        hints: [], duplicate: true };
    }
    row = (await tx`
      UPDATE group_calls SET state = 'ended', ended_at = now(), end_reason = ${reason},
        state_revision = state_revision + 1, updated_at = now()
      WHERE id = ${callId} RETURNING *`)[0];
    const participantDevices = await tx`
      SELECT device_id FROM group_call_participants
      WHERE call_id = ${callId} AND status IN ('pending_key','active')
      ORDER BY device_id FOR UPDATE`;
    await tx`
      UPDATE group_call_participants SET status = 'left', ready_media_epoch = NULL,
        left_at = now(), last_seen_at = now()
      WHERE call_id = ${callId} AND status IN ('pending_key','active')`;
    await tx`DELETE FROM group_call_screen_share_leases WHERE call_id = ${callId}`;
    await tx`DELETE FROM group_call_camera_leases WHERE call_id = ${callId}`;
    for (const participant of participantDevices) {
      await queueParticipantSFUState(tx, row, String(participant.device_id), true);
    }
    await notify(tx, row);
    return { call: await loadSnapshot(tx, row, input.accountId, input.deviceId),
      hints: await hintTargets(tx, row), duplicate: false };
  });
  await requireGroupCallSFUBarrierApplied(sql, [callId], control);
  return result;
}

export async function heartbeatGroupCall(sql: SQL, input: {
  accountId: string; deviceId: string; callId: unknown;
}): Promise<{ state: "active" | "ended"; stateRevision: number }> {
  const callId = requireUUID(input.callId, "callId");
  return sql.begin(async (tx) => {
    const row = await authorizedCall(tx, input.accountId, input.deviceId, callId, true);
    if (row.state !== "active") throw new GroupCallError("group call has ended", "call_ended", 410);
    const participant = (await tx`
      SELECT status, last_heartbeat_at
      FROM group_call_participants
      WHERE call_id = ${callId} AND device_id = ${input.deviceId}
      FOR UPDATE`)[0];
    if (!participant || !["pending_key", "active"].includes(String(participant.status))) {
      throw new GroupCallError("device is not joined", "not_joined", 409);
    }
    const elapsed = Date.now() - new Date(participant.last_heartbeat_at).getTime();
    if (elapsed < 10_000) {
      throw new GroupCallError(
        "group call heartbeat is too frequent",
        "rate_limited",
        429,
        {},
        Math.max(1, Math.ceil((10_000 - elapsed) / 1_000)),
      );
    }
    await tx`
      UPDATE group_call_participants
      SET last_seen_at = now(), last_heartbeat_at = now()
      WHERE call_id = ${callId} AND device_id = ${input.deviceId}`;
    return { state: row.state, stateRevision: n(row.state_revision) };
  });
}

async function requireParticipantSFUStateApplied(
  sql: SQL,
  callId: string,
  deviceId: string,
  control: GroupCallSFUControl,
): Promise<void> {
  for (let attempt = 0; attempt < 10; attempt += 1) {
    if (await reconcileGroupCallSFUParticipant(sql, callId, deviceId, control)) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new GroupCallError("group media control is busy", "sfu_control_unavailable", 503);
}

export async function requireGroupCallSFUBarrierApplied(
  sql: SQL,
  callIds: readonly string[],
  control: GroupCallSFUControl = defaultGroupCallSFUControl(),
): Promise<void> {
  for (const callId of [...new Set(callIds)]) {
    const pending = await sql`
      SELECT DISTINCT device_id FROM group_call_sfu_participant_states
      WHERE call_id = ${callId} AND applied_revision < revision
      ORDER BY device_id`;
    await Promise.all(pending.map((row: any) => requireParticipantSFUStateApplied(
      sql,
      callId,
      String(row.device_id),
      control,
    )));
    const unresolved = await sql`
      SELECT 1 FROM group_call_sfu_participant_states
      WHERE call_id = ${callId} AND applied_revision < revision
      LIMIT 1`;
    if (unresolved.length) {
      throw new GroupCallError("group media control is busy", "sfu_control_unavailable", 503);
    }
  }
}

async function compensateMediaLease(
  sql: SQL,
  callId: string,
  deviceId: string,
  generation: string,
  kind: "camera" | "screen",
  control: GroupCallSFUControl,
): Promise<void> {
  await sql.begin(async (tx) => {
    const row = (await tx`
      SELECT * FROM group_calls WHERE id = ${callId} FOR UPDATE`)[0];
    if (!row) return;
    let removed: any[];
    if (kind === "camera") {
      removed = await tx`
        DELETE FROM group_call_camera_leases
        WHERE call_id = ${callId} AND device_id = ${deviceId} AND generation = ${generation}
        RETURNING call_id`;
    } else {
      removed = await tx`
        DELETE FROM group_call_screen_share_leases
        WHERE call_id = ${callId} AND device_id = ${deviceId} AND generation = ${generation}
        RETURNING call_id`;
    }
    if (!removed.length) return;
    await queueParticipantSFUState(tx, row, deviceId);
    await notify(tx, await advanceCallState(tx, callId));
  });
  try { await requireParticipantSFUStateApplied(sql, callId, deviceId, control); } catch {}
}

export async function acquireGroupCamera(sql: SQL, input: {
  accountId: string; deviceId: string; callId: unknown; generation: unknown;
}, control: GroupCallSFUControl = defaultGroupCallSFUControl()): Promise<{
  generation: string; expiresAt: string; call: GroupCallSnapshot; hints: GroupCallHint[];
}> {
  const callId = requireUUID(input.callId, "callId");
  const generation = requireUUID(input.generation, "generation");
  if (!groupCallsEnabledForAccount(input.accountId)) {
    throw new GroupCallError("group calls are unavailable", "capability_unavailable", 404);
  }
  const result = await sql.begin(async (tx) => {
    const row = await authorizedCall(tx, input.accountId, input.deviceId, callId, true);
    if (row.state !== "active") throw new GroupCallError("group call has ended", "call_ended", 410);
    await requireCurrentMediaEpoch(tx, row, input.deviceId);
    const expired = await tx`
      DELETE FROM group_call_camera_leases
      WHERE call_id = ${callId} AND expires_at <= now()
      RETURNING device_id`;
    for (const lease of expired) {
      await queueParticipantSFUState(tx, row, String(lease.device_id));
    }
    const existing = (await tx`
      SELECT *, updated_at > now()
          - (${MEDIA_LEASE_UPDATE_MIN_SECONDS} * interval '1 second') AS reacquire_too_frequent,
        GREATEST(1, CEIL(EXTRACT(EPOCH FROM (
          updated_at + (${MEDIA_LEASE_UPDATE_MIN_SECONDS} * interval '1 second') - now()
        ))))::int AS retry_after
      FROM group_call_camera_leases
      WHERE call_id = ${callId} AND device_id = ${input.deviceId} FOR UPDATE`)[0];
    if (existing && existing.generation !== generation) {
      throw new GroupCallError("camera lease generation changed", "idempotency_conflict", 409);
    }
    if (existing?.reacquire_too_frequent) {
      throw new GroupCallError(
        "camera reacquisition is too frequent",
        "rate_limited",
        429,
        {},
        n(existing.retry_after),
      );
    }
    if (!existing) {
      const count = n((await tx`
        SELECT count(*)::int AS count FROM group_call_camera_leases
        WHERE call_id = ${callId} AND expires_at > now()`)[0].count);
      if (count >= n(row.publisher_limit)) {
        throw new GroupCallError("the camera publisher limit was reached", "publisher_limit_reached", 409);
      }
      await enforceBudget(tx, input.accountId, input.deviceId, "camera_publish");
    }
    const lease = (await tx`
      INSERT INTO group_call_camera_leases(call_id, device_id, generation, expires_at)
      VALUES (${callId}, ${input.deviceId}, ${generation},
        now() + (${CAMERA_LEASE_SECONDS} * interval '1 second'))
      ON CONFLICT (call_id, device_id) DO UPDATE SET
        expires_at = excluded.expires_at, updated_at = now()
      RETURNING *`)[0];
    await tx`
      UPDATE group_call_participants SET last_seen_at = now()
      WHERE call_id = ${callId} AND device_id = ${input.deviceId}`;
    await queueParticipantSFUState(tx, row, input.deviceId, Boolean(existing));
    const visibleRow = !existing || expired.length
      ? await advanceCallState(tx, callId)
      : row;
    if (!existing || expired.length) await notify(tx, visibleRow);
    return {
      generation,
      expiresAt: iso(lease.expires_at),
      call: await loadSnapshot(tx, visibleRow, input.accountId, input.deviceId),
      hints: !existing || expired.length ? await hintTargets(tx, visibleRow) : [],
      displacedDeviceIds: [...new Set<string>(expired
        .map((lease: any) => String(lease.device_id))
        .filter((deviceId: string) => deviceId !== input.deviceId))],
    };
  });
  try {
    for (const displacedDeviceId of result.displacedDeviceIds) {
      await requireParticipantSFUStateApplied(sql, callId, displacedDeviceId, control);
    }
    await requireParticipantSFUStateApplied(sql, callId, input.deviceId, control);
  } catch (error) {
    await compensateMediaLease(sql, callId, input.deviceId, generation, "camera", control);
    throw error;
  }
  const current = await sql`
    SELECT 1 FROM group_call_camera_leases
    WHERE call_id = ${callId} AND device_id = ${input.deviceId}
      AND generation = ${generation} AND expires_at > now()`;
  if (!current.length) {
    throw new GroupCallError("camera lease was superseded", "camera_lease_superseded", 409);
  }
  const { displacedDeviceIds: _, ...publicResult } = result;
  return sql.begin(async (tx) => {
    const row = await authorizedCall(tx, input.accountId, input.deviceId, callId, "share");
    return { ...publicResult, call: await loadSnapshot(tx, row, input.accountId, input.deviceId) };
  });
}

export async function heartbeatGroupCamera(sql: SQL, input: {
  accountId: string; deviceId: string; callId: unknown; generation: unknown;
}): Promise<{ generation: string; expiresAt: string }> {
  const callId = requireUUID(input.callId, "callId");
  const generation = requireUUID(input.generation, "generation");
  return sql.begin(async (tx) => {
    const row = await authorizedCall(tx, input.accountId, input.deviceId, callId, true);
    if (row.state !== "active") throw new GroupCallError("group call has ended", "call_ended", 410);
    await requireCurrentMediaEpoch(tx, row, input.deviceId);
    const lease = (await tx`
      UPDATE group_call_camera_leases
      SET expires_at = now() + (${CAMERA_LEASE_SECONDS} * interval '1 second'), updated_at = now()
      WHERE call_id = ${callId} AND device_id = ${input.deviceId}
        AND generation = ${generation} AND expires_at > now()
        AND updated_at <= now()
          - (${MEDIA_LEASE_UPDATE_MIN_SECONDS} * interval '1 second')
      RETURNING *`)[0];
    if (!lease) {
      const current = (await tx`
        SELECT generation, expires_at FROM group_call_camera_leases
        WHERE call_id = ${callId} AND device_id = ${input.deviceId}`)[0];
      if (current?.generation === generation && new Date(current.expires_at).getTime() > Date.now()) {
        throw new GroupCallError(
          "camera heartbeat is too frequent",
          "rate_limited",
          429,
          {},
          MEDIA_LEASE_UPDATE_MIN_SECONDS,
        );
      }
      throw new GroupCallError("camera lease expired", "camera_lease_expired", 409);
    }
    await tx`
      UPDATE group_call_participants SET last_seen_at = now()
      WHERE call_id = ${callId} AND device_id = ${input.deviceId}`;
    return { generation, expiresAt: iso(lease.expires_at) };
  });
}

export async function releaseGroupCamera(sql: SQL, input: {
  accountId: string; deviceId: string; callId: unknown; generation: unknown;
}, control: GroupCallSFUControl = defaultGroupCallSFUControl()): Promise<{
  released: true; hints: GroupCallHint[];
}> {
  const callId = requireUUID(input.callId, "callId");
  const generation = requireUUID(input.generation, "generation");
  const result = await sql.begin<GroupCallReleaseResult>(async (tx) => {
    const row = await authorizedCall(tx, input.accountId, input.deviceId, callId, true);
    const removed = await tx`
      DELETE FROM group_call_camera_leases
      WHERE call_id = ${callId} AND device_id = ${input.deviceId} AND generation = ${generation}
      RETURNING call_id`;
    if (removed.length) {
      await queueParticipantSFUState(tx, row, input.deviceId);
      const visibleRow = await advanceCallState(tx, callId);
      await notify(tx, visibleRow);
      return { released: true as const, hints: await hintTargets(tx, visibleRow) };
    }
    return { released: true as const, hints: [] };
  });
  try { await requireParticipantSFUStateApplied(sql, callId, input.deviceId, control); } catch {}
  return result;
}

export async function acquireGroupScreenShare(sql: SQL, input: {
  accountId: string; deviceId: string; callId: unknown; generation: unknown;
}, control: GroupCallSFUControl = defaultGroupCallSFUControl()): Promise<{
  generation: string; expiresAt: string; call: GroupCallSnapshot; hints: GroupCallHint[];
}> {
  if (!groupScreenSharingConfigured() || !groupCallsEnabledForAccount(input.accountId)) {
    throw new GroupCallError("screen sharing is unavailable", "screen_share_unavailable", 409);
  }
  const callId = requireUUID(input.callId, "callId");
  const generation = requireUUID(input.generation, "generation");
  const result = await sql.begin(async (tx) => {
    await requireGroupMediaDevice(tx, input.accountId, input.deviceId, true);
    const row = await authorizedCall(tx, input.accountId, input.deviceId, callId, true);
    if (row.state !== "active") throw new GroupCallError("group call has ended", "call_ended", 410);
    await requireCurrentMediaEpoch(tx, row, input.deviceId);
    const expired = await tx`DELETE FROM group_call_screen_share_leases
      WHERE call_id = ${callId} AND expires_at <= now()
      RETURNING device_id`;
    for (const lease of expired) {
      await queueParticipantSFUState(tx, row, String(lease.device_id));
    }
    const existing = (await tx`
      SELECT *, updated_at > now()
          - (${MEDIA_LEASE_UPDATE_MIN_SECONDS} * interval '1 second') AS reacquire_too_frequent,
        GREATEST(1, CEIL(EXTRACT(EPOCH FROM (
          updated_at + (${MEDIA_LEASE_UPDATE_MIN_SECONDS} * interval '1 second') - now()
        ))))::int AS retry_after
      FROM group_call_screen_share_leases WHERE call_id = ${callId} FOR UPDATE`)[0];
    if (existing && (existing.device_id !== input.deviceId || existing.generation !== generation)) {
      throw new GroupCallError("another participant is sharing their screen", "screen_share_busy", 409);
    }
    if (existing?.reacquire_too_frequent) {
      throw new GroupCallError(
        "screen-share reacquisition is too frequent",
        "rate_limited",
        429,
        {},
        n(existing.retry_after),
      );
    }
    if (!existing) await enforceBudget(tx, input.accountId, input.deviceId, "screen_share");
    const lease = (await tx`
      INSERT INTO group_call_screen_share_leases(call_id, device_id, generation, expires_at)
      VALUES (${callId}, ${input.deviceId}, ${generation},
        now() + (${SCREEN_SHARE_LEASE_SECONDS} * interval '1 second'))
      ON CONFLICT (call_id) DO UPDATE SET expires_at = excluded.expires_at, updated_at = now()
      RETURNING *`)[0];
    await tx`
      UPDATE group_call_participants SET last_seen_at = now()
      WHERE call_id = ${callId} AND device_id = ${input.deviceId}`;
    await queueParticipantSFUState(tx, row, input.deviceId, Boolean(existing));
    const visibleRow = !existing || expired.length
      ? await advanceCallState(tx, callId)
      : row;
    if (!existing || expired.length) await notify(tx, visibleRow);
    return { generation, expiresAt: iso(lease.expires_at),
      call: await loadSnapshot(tx, visibleRow, input.accountId, input.deviceId),
      hints: !existing || expired.length ? await hintTargets(tx, visibleRow) : [],
      displacedDeviceIds: [...new Set<string>(expired
        .map((lease: any) => String(lease.device_id))
        .filter((deviceId: string) => deviceId !== input.deviceId))] };
  });
  try {
    for (const displacedDeviceId of result.displacedDeviceIds) {
      await requireParticipantSFUStateApplied(sql, callId, displacedDeviceId, control);
    }
    await requireParticipantSFUStateApplied(sql, callId, input.deviceId, control);
  } catch (error) {
    await compensateMediaLease(sql, callId, input.deviceId, generation, "screen", control);
    throw error;
  }
  const current = await sql`
    SELECT 1 FROM group_call_screen_share_leases
    WHERE call_id = ${callId} AND device_id = ${input.deviceId}
      AND generation = ${generation} AND expires_at > now()`;
  if (!current.length) {
    throw new GroupCallError("screen share lease was superseded", "screen_share_lease_superseded", 409);
  }
  const { displacedDeviceIds: _, ...publicResult } = result;
  return sql.begin(async (tx) => {
    const row = await authorizedCall(tx, input.accountId, input.deviceId, callId, "share");
    return { ...publicResult, call: await loadSnapshot(tx, row, input.accountId, input.deviceId) };
  });
}

export async function heartbeatGroupScreenShare(sql: SQL, input: {
  accountId: string; deviceId: string; callId: unknown; generation: unknown;
}): Promise<{ generation: string; expiresAt: string }> {
  const callId = requireUUID(input.callId, "callId");
  const generation = requireUUID(input.generation, "generation");
  return sql.begin(async (tx) => {
    const row = await authorizedCall(tx, input.accountId, input.deviceId, callId, true);
    if (row.state !== "active") throw new GroupCallError("group call has ended", "call_ended", 410);
    await requireCurrentMediaEpoch(tx, row, input.deviceId);
    const lease = (await tx`
      UPDATE group_call_screen_share_leases
      SET expires_at = now() + (${SCREEN_SHARE_LEASE_SECONDS} * interval '1 second'), updated_at = now()
      WHERE call_id = ${callId} AND device_id = ${input.deviceId}
        AND generation = ${generation} AND expires_at > now()
        AND updated_at <= now()
          - (${MEDIA_LEASE_UPDATE_MIN_SECONDS} * interval '1 second')
      RETURNING *`)[0];
    if (!lease) {
      const current = (await tx`
        SELECT generation, expires_at FROM group_call_screen_share_leases
        WHERE call_id = ${callId}`)[0];
      if (current?.generation === generation && new Date(current.expires_at).getTime() > Date.now()) {
        throw new GroupCallError(
          "screen share heartbeat is too frequent",
          "rate_limited",
          429,
          {},
          MEDIA_LEASE_UPDATE_MIN_SECONDS,
        );
      }
      throw new GroupCallError("screen share lease expired", "screen_share_lease_expired", 409);
    }
    await tx`
      UPDATE group_call_participants SET last_seen_at = now()
      WHERE call_id = ${callId} AND device_id = ${input.deviceId}`;
    return { generation, expiresAt: iso(lease.expires_at) };
  });
}

export async function releaseGroupScreenShare(sql: SQL, input: {
  accountId: string; deviceId: string; callId: unknown; generation: unknown;
}, control: GroupCallSFUControl = defaultGroupCallSFUControl()): Promise<{
  released: true; hints: GroupCallHint[];
}> {
  const callId = requireUUID(input.callId, "callId");
  const generation = requireUUID(input.generation, "generation");
  const result = await sql.begin<GroupCallReleaseResult>(async (tx) => {
    const row = await authorizedCall(tx, input.accountId, input.deviceId, callId, true);
    const removed = await tx`
      DELETE FROM group_call_screen_share_leases
      WHERE call_id = ${callId} AND device_id = ${input.deviceId} AND generation = ${generation}
      RETURNING call_id`;
    if (removed.length) {
      await queueParticipantSFUState(tx, row, input.deviceId);
      const visibleRow = await advanceCallState(tx, callId);
      await notify(tx, visibleRow);
      return { released: true as const, hints: await hintTargets(tx, visibleRow) };
    }
    return { released: true as const, hints: [] };
  });
  try { await requireParticipantSFUStateApplied(sql, callId, input.deviceId, control); } catch {}
  return result;
}

/** Called while the group dialog row is already locked by a membership mutation. */
export async function revokeGroupCallAccountInLockedDialog(
  sql: SQL,
  dialogId: string,
  accountId: string,
): Promise<string[]> {
  const row = (await sql`
    SELECT * FROM group_calls WHERE dialog_id = ${dialogId} AND state = 'active' FOR UPDATE`)[0];
  if (!row) return [];
  const participants = await sql`
    SELECT device_id FROM group_call_participants
    WHERE call_id = ${row.id} AND account_id = ${accountId}
      AND status IN ('pending_key','active') ORDER BY device_id FOR UPDATE`;
  let current = row;
  for (const participant of participants) {
    current = await departParticipantTx(sql, current, participant.device_id, "removed", "empty");
  }
  return participants.length ? [String(row.id)] : [];
}

export async function revokeGroupCallDeviceTx(
  sql: SQL,
  accountId: string,
  deviceId: string,
): Promise<string[]> {
  const rows: GroupCallRow[] = await sql`
    SELECT call.* FROM group_calls call
    JOIN group_call_participants participant ON participant.call_id = call.id
    WHERE call.state = 'active' AND participant.account_id = ${accountId}
      AND participant.device_id = ${deviceId}
      AND participant.status IN ('pending_key','active')
    ORDER BY call.id FOR UPDATE OF call`;
  for (const row of rows) await departParticipantTx(sql, row, deviceId, "removed", "empty");
  return rows.map((row) => String(row.id));
}

export async function revokeGroupCallAccountTx(sql: SQL, accountId: string): Promise<string[]> {
  const rows: GroupCallRow[] = await sql`
    SELECT call.* FROM group_calls call
    JOIN group_call_participants participant ON participant.call_id = call.id
    WHERE call.state = 'active' AND participant.account_id = ${accountId}
      AND participant.status IN ('pending_key','active')
    ORDER BY call.id FOR UPDATE OF call`;
  for (const row of rows) {
    const devices = await sql`
      SELECT device_id FROM group_call_participants
      WHERE call_id = ${row.id} AND account_id = ${accountId}
        AND status IN ('pending_key','active') ORDER BY device_id FOR UPDATE`;
    let current = row;
    for (const participant of devices) {
      current = await departParticipantTx(sql, current, participant.device_id, "removed", "empty");
    }
  }
  return rows.map((row) => String(row.id));
}

export async function expireStaleGroupCallParticipants(sql: SQL, limit = 100): Promise<number> {
  return sql.begin(async (tx) => {
    const boundedLimit = Math.max(1, Math.min(limit, 1_000));
    // Every live mutation takes the call lock before touching leases or participants. Cleanup uses
    // the same order and skips busy calls, avoiding call->child versus child->call deadlocks at
    // heartbeat/expiry boundaries.
    const affectedCalls: GroupCallRow[] = await tx`
      SELECT call.* FROM group_calls call
      WHERE call.state = 'active' AND (
        EXISTS (SELECT 1 FROM group_call_camera_leases camera
          WHERE camera.call_id = call.id AND camera.expires_at <= now())
        OR EXISTS (SELECT 1 FROM group_call_screen_share_leases screen
          WHERE screen.call_id = call.id AND screen.expires_at <= now())
        OR EXISTS (
          SELECT 1 FROM group_call_participants participant
          WHERE participant.call_id = call.id AND (
            (participant.status = 'active'
              AND participant.last_seen_at <= now()
                - (${ACTIVE_HEARTBEAT_TIMEOUT_SECONDS} * interval '1 second'))
            OR (participant.status = 'pending_key'
              AND participant.last_seen_at <= now()
                - (${PENDING_KEY_TIMEOUT_SECONDS} * interval '1 second'))
          )
        )
      )
      ORDER BY call.id FOR UPDATE OF call SKIP LOCKED LIMIT ${boundedLimit}`;
    let expiredLeaseCount = 0;
    let staleParticipantCount = 0;
    for (const lockedRow of affectedCalls) {
      let current = lockedRow;
      const expiredCameras = await tx`
        DELETE FROM group_call_camera_leases
        WHERE call_id = ${current.id} AND expires_at <= now()
        RETURNING device_id`;
      const expiredScreens = await tx`
        DELETE FROM group_call_screen_share_leases
        WHERE call_id = ${current.id} AND expires_at <= now()
        RETURNING device_id`;
      const expiredLeases = [...expiredCameras, ...expiredScreens];
      expiredLeaseCount += expiredLeases.length;
      for (const deviceId of new Set(expiredLeases.map((lease: any) => String(lease.device_id)))) {
        await queueParticipantSFUState(tx, current, deviceId);
      }
      if (expiredLeases.length) {
        current = await advanceCallState(tx, String(current.id));
        await notify(tx, current);
      }

      const staleParticipants = await tx`
        SELECT device_id FROM group_call_participants
        WHERE call_id = ${current.id} AND (
          (status = 'active' AND last_seen_at <= now()
            - (${ACTIVE_HEARTBEAT_TIMEOUT_SECONDS} * interval '1 second'))
          OR (status = 'pending_key' AND last_seen_at <= now()
            - (${PENDING_KEY_TIMEOUT_SECONDS} * interval '1 second'))
        )
        ORDER BY last_seen_at, device_id FOR UPDATE`;
      for (const participant of staleParticipants) {
        current = await departParticipantTx(tx, current, participant.device_id, "left", "empty");
        staleParticipantCount += 1;
      }
    }
    const expiredBudgets = await tx`
      WITH doomed AS (
        SELECT id FROM group_call_action_budgets
        WHERE created_at < now() - interval '24 hours'
        ORDER BY created_at, id
        FOR UPDATE SKIP LOCKED LIMIT 1000
      )
      DELETE FROM group_call_action_budgets budget
      WHERE budget.id IN (SELECT id FROM doomed)
      RETURNING budget.id`;
    const retiredEpochs = await tx`
      WITH doomed AS (
        SELECT epoch.call_id, epoch.epoch
        FROM group_call_epochs epoch
        JOIN group_calls call ON call.id = epoch.call_id
        WHERE call.state = 'active'
          AND epoch.epoch < call.media_epoch
          AND epoch.grace_expires_at <= now()
        ORDER BY epoch.grace_expires_at, epoch.call_id, epoch.epoch
        FOR UPDATE OF epoch SKIP LOCKED LIMIT ${boundedLimit}
      )
      DELETE FROM group_call_epochs epoch USING doomed
      WHERE epoch.call_id = doomed.call_id AND epoch.epoch = doomed.epoch
      RETURNING epoch.call_id`;
    const retiredSFUStates = await tx`
      WITH doomed AS (
        SELECT call_id, participant_identity
        FROM group_call_sfu_participant_states
        WHERE desired_status = 'removed'
          AND applied_revision = revision
          AND updated_at < now() - interval '1 hour'
        ORDER BY updated_at, call_id, participant_identity
        FOR UPDATE SKIP LOCKED LIMIT ${boundedLimit}
      )
      DELETE FROM group_call_sfu_participant_states state USING doomed
      WHERE state.call_id = doomed.call_id
        AND state.participant_identity = doomed.participant_identity
      RETURNING state.call_id`;
    const retiredCalls = await tx`
      WITH doomed AS (
        SELECT call.id FROM group_calls call
        WHERE call.state = 'ended' AND call.ended_at < now() - interval '30 days'
          AND NOT EXISTS (
            SELECT 1 FROM group_call_sfu_participant_states state
            WHERE state.call_id = call.id
              AND state.applied_revision < state.revision
          )
        ORDER BY call.ended_at, call.id
        FOR UPDATE OF call SKIP LOCKED LIMIT ${boundedLimit}
      )
      DELETE FROM group_calls call USING doomed
      WHERE call.id = doomed.id
      RETURNING call.id`;
    return staleParticipantCount + expiredLeaseCount + expiredBudgets.length
      + retiredEpochs.length + retiredSFUStates.length + retiredCalls.length;
  });
}

export function startGroupCallCleanupWorker(sql: SQL, intervalMs = 15_000): () => void {
  let running = false;
  const tick = async () => {
    if (running) return;
    running = true;
    try {
      if (!(await groupCallSchemaReadiness(sql)).ready) return;
      while (await expireStaleGroupCallParticipants(sql) > 0) {}
    } catch (error) {
      console.error(JSON.stringify({
        ts: new Date().toISOString(), event: "group_call.cleanup.error",
        errorType: error instanceof Error ? error.name : "UnknownError",
      }));
    } finally {
      running = false;
    }
  };
  void tick();
  const timer = setInterval(() => { void tick(); }, intervalMs);
  timer.unref?.();
  return () => clearInterval(timer);
}

export function startGroupCallNotificationListener(
  databaseUrl: string | null,
  onWakeup: (wakeup: GroupCallWakeup) => void | Promise<void>,
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
    const next = new Client({ connectionString: databaseUrl });
    client = next;
    next.on("notification", (message) => {
      if (message.channel !== GROUP_CALL_NOTIFY_CHANNEL || !message.payload) return;
      try {
        const value = JSON.parse(message.payload);
        if (typeof value.callId === "string" && UUID_PATTERN.test(value.callId)
          && Number.isSafeInteger(Number(value.stateRevision))
          && Number(value.stateRevision) > 0) {
          void onWakeup({ callId: value.callId, stateRevision: Number(value.stateRevision) });
        }
      } catch {}
    });
    const reconnect = () => {
      if (client === next) client = null;
      if (!stopped) schedule();
    };
    next.on("error", reconnect);
    next.on("end", reconnect);
    try {
      await next.connect();
      await next.query(`LISTEN ${GROUP_CALL_NOTIFY_CHANNEL}`);
      attempts = 0;
    } catch {
      try { await next.end(); } catch {}
      reconnect();
    }
  };
  void connect();
  return () => {
    stopped = true;
    if (retry) clearTimeout(retry);
    retry = null;
    const active = client;
    client = null;
    if (active) void active.end().catch(() => {});
  };
}
