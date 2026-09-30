import type { SQL } from "bun";

export type DraftMediaSchemaState = {
  ready: boolean;
  missingTables: string[];
  missingColumns: string[];
  invalidColumns: string[];
  missingUniqueConstraints: string[];
  missingCheckConstraints: string[];
  missingIndexes: string[];
  missingMigrations: string[];
  accountEventConstraintReady: boolean;
  accountCleanupReady: boolean;
};

type ColumnContract = {
  table: string;
  column: string;
  type: string;
  notNull: boolean;
  default: string | null;
};

const REQUIRED_TABLES = [
  "accounts",
  "schema_migrations",
  "dialogs",
  "messages",
  "send_requests",
  "account_events",
  "media_objects",
  "account_dialog_drafts",
  "draft_attachments",
  "draft_mutation_requests",
  "draft_mutation_tombstones",
  "draft_mutation_budgets",
  "media_group_send_requests",
  "media_group_send_tombstones",
  "media_group_send_budgets",
  "dialog_preferences",
  "dialog_preference_requests",
  "dialog_preference_action_budgets",
  "dialog_preference_legacy_reconciliation",
  "bootstrap_snapshots",
] as const;

// These are the complete feature-owned rows plus every shared column read or written by the
// draft-consumption and grouped-send paths. Defaults and nullability are executable behavior:
// accepting traffic against a half-applied ALTER can otherwise corrupt replay or optimistic state.
const REQUIRED_COLUMNS: readonly ColumnContract[] = [
  { table: "messages", column: "media_id", type: "uuid", notNull: false, default: null },
  { table: "messages", column: "media_group_id", type: "uuid", notNull: false, default: null },
  { table: "messages", column: "media_group_index", type: "smallint", notNull: false, default: null },
  { table: "messages", column: "media_group_count", type: "smallint", notNull: false, default: null },
  { table: "messages", column: "draft_consume_operation_id", type: "uuid", notNull: false, default: null },
  { table: "messages", column: "draft_cleared_revision", type: "bigint", notNull: false, default: null },
  { table: "send_requests", column: "draft_consume_operation_id", type: "uuid", notNull: false, default: null },
  { table: "send_requests", column: "cleared_draft_revision", type: "bigint", notNull: false, default: null },
  { table: "account_events", column: "account_id", type: "uuid", notNull: true, default: null },
  { table: "account_events", column: "type", type: "text", notNull: true, default: null },
  { table: "dialogs", column: "photo_media_id", type: "uuid", notNull: false, default: null },
  { table: "media_objects", column: "id", type: "uuid", notNull: true, default: "gen_random_uuid()" },
  { table: "media_objects", column: "owner_account_id", type: "uuid", notNull: true, default: null },

  { table: "account_dialog_drafts", column: "account_id", type: "uuid", notNull: true, default: null },
  { table: "account_dialog_drafts", column: "dialog_id", type: "uuid", notNull: true, default: null },
  { table: "account_dialog_drafts", column: "state", type: "text", notNull: true, default: null },
  { table: "account_dialog_drafts", column: "body_key_id", type: "text", notNull: true, default: null },
  { table: "account_dialog_drafts", column: "body_nonce", type: "bytea", notNull: true, default: null },
  { table: "account_dialog_drafts", column: "body_ciphertext", type: "bytea", notNull: true, default: null },
  { table: "account_dialog_drafts", column: "reply_to_msg_id", type: "bigint", notNull: false, default: null },
  { table: "account_dialog_drafts", column: "mentions", type: "jsonb", notNull: true, default: "'[]'::jsonb" },
  { table: "account_dialog_drafts", column: "revision", type: "bigint", notNull: true, default: null },
  { table: "account_dialog_drafts", column: "operation_id", type: "uuid", notNull: true, default: null },
  { table: "account_dialog_drafts", column: "source_device_id", type: "uuid", notNull: false, default: null },
  { table: "account_dialog_drafts", column: "created_at", type: "timestamp with time zone", notNull: true, default: "now()" },
  { table: "account_dialog_drafts", column: "updated_at", type: "timestamp with time zone", notNull: true, default: "now()" },

  { table: "draft_attachments", column: "account_id", type: "uuid", notNull: true, default: null },
  { table: "draft_attachments", column: "dialog_id", type: "uuid", notNull: true, default: null },
  { table: "draft_attachments", column: "attachment_id", type: "uuid", notNull: true, default: null },
  { table: "draft_attachments", column: "media_id", type: "uuid", notNull: true, default: null },
  { table: "draft_attachments", column: "position", type: "smallint", notNull: true, default: null },
  { table: "draft_attachments", column: "created_at", type: "timestamp with time zone", notNull: true, default: "now()" },

  { table: "draft_mutation_requests", column: "account_id", type: "uuid", notNull: true, default: null },
  { table: "draft_mutation_requests", column: "operation_id", type: "uuid", notNull: true, default: null },
  { table: "draft_mutation_requests", column: "dialog_id", type: "uuid", notNull: true, default: null },
  { table: "draft_mutation_requests", column: "payload_fingerprint", type: "bytea", notNull: true, default: null },
  { table: "draft_mutation_requests", column: "status", type: "text", notNull: true, default: "'pending'::text" },
  { table: "draft_mutation_requests", column: "resulting_revision", type: "bigint", notNull: false, default: null },
  { table: "draft_mutation_requests", column: "response_key_id", type: "text", notNull: false, default: null },
  { table: "draft_mutation_requests", column: "response_nonce", type: "bytea", notNull: false, default: null },
  { table: "draft_mutation_requests", column: "response_ciphertext", type: "bytea", notNull: false, default: null },
  { table: "draft_mutation_requests", column: "created_at", type: "timestamp with time zone", notNull: true, default: "now()" },

  { table: "draft_mutation_tombstones", column: "account_id", type: "uuid", notNull: true, default: null },
  { table: "draft_mutation_tombstones", column: "operation_id", type: "uuid", notNull: true, default: null },
  { table: "draft_mutation_tombstones", column: "dialog_id", type: "uuid", notNull: true, default: null },
  { table: "draft_mutation_tombstones", column: "payload_fingerprint", type: "bytea", notNull: true, default: null },
  { table: "draft_mutation_tombstones", column: "resulting_revision", type: "bigint", notNull: true, default: null },
  { table: "draft_mutation_tombstones", column: "created_at", type: "timestamp with time zone", notNull: true, default: "now()" },

  { table: "draft_mutation_budgets", column: "id", type: "bigint", notNull: true, default: "nextval('draft_mutation_budgets_id_seq'::regclass)" },
  { table: "draft_mutation_budgets", column: "account_id", type: "uuid", notNull: true, default: null },
  { table: "draft_mutation_budgets", column: "device_id", type: "uuid", notNull: true, default: null },
  { table: "draft_mutation_budgets", column: "operation_id", type: "uuid", notNull: true, default: null },
  { table: "draft_mutation_budgets", column: "accepted_at", type: "timestamp with time zone", notNull: true, default: "now()" },

  { table: "media_group_send_requests", column: "sender_account_id", type: "uuid", notNull: true, default: null },
  { table: "media_group_send_requests", column: "client_group_id", type: "uuid", notNull: true, default: null },
  { table: "media_group_send_requests", column: "dialog_id", type: "uuid", notNull: true, default: null },
  { table: "media_group_send_requests", column: "payload_fingerprint", type: "bytea", notNull: true, default: null },
  { table: "media_group_send_requests", column: "status", type: "text", notNull: true, default: "'pending'::text" },
  { table: "media_group_send_requests", column: "first_msg_id", type: "bigint", notNull: false, default: null },
  { table: "media_group_send_requests", column: "last_msg_id", type: "bigint", notNull: false, default: null },
  { table: "media_group_send_requests", column: "sender_pts", type: "bigint", notNull: false, default: null },
  { table: "media_group_send_requests", column: "draft_consume_operation_id", type: "uuid", notNull: false, default: null },
  { table: "media_group_send_requests", column: "cleared_draft_revision", type: "bigint", notNull: false, default: null },
  { table: "media_group_send_requests", column: "created_at", type: "timestamp with time zone", notNull: true, default: "now()" },

  { table: "media_group_send_tombstones", column: "sender_account_id", type: "uuid", notNull: true, default: null },
  { table: "media_group_send_tombstones", column: "client_group_id", type: "uuid", notNull: true, default: null },
  { table: "media_group_send_tombstones", column: "dialog_id", type: "uuid", notNull: true, default: null },
  { table: "media_group_send_tombstones", column: "payload_fingerprint", type: "bytea", notNull: true, default: null },
  { table: "media_group_send_tombstones", column: "first_msg_id", type: "bigint", notNull: true, default: null },
  { table: "media_group_send_tombstones", column: "last_msg_id", type: "bigint", notNull: true, default: null },
  { table: "media_group_send_tombstones", column: "sender_pts", type: "bigint", notNull: true, default: null },
  { table: "media_group_send_tombstones", column: "cleared_draft_revision", type: "bigint", notNull: false, default: null },
  { table: "media_group_send_tombstones", column: "created_at", type: "timestamp with time zone", notNull: true, default: "now()" },

  { table: "media_group_send_budgets", column: "id", type: "bigint", notNull: true, default: "nextval('media_group_send_budgets_id_seq'::regclass)" },
  { table: "media_group_send_budgets", column: "account_id", type: "uuid", notNull: true, default: null },
  { table: "media_group_send_budgets", column: "device_id", type: "uuid", notNull: true, default: null },
  { table: "media_group_send_budgets", column: "item_count", type: "smallint", notNull: true, default: null },
  { table: "media_group_send_budgets", column: "accepted_at", type: "timestamp with time zone", notNull: true, default: "now()" },

  // The unified account-deletion boundary executes even when the individual feature switches are
  // dark. Keep its preference-compatibility dependency in this contract so capability
  // advertisement cannot approve a function that will fail when an old node deletes an account.
  { table: "dialog_preference_legacy_reconciliation", column: "dialog_id", type: "uuid", notNull: true, default: null },
  { table: "dialog_preference_legacy_reconciliation", column: "account_id", type: "uuid", notNull: true, default: null },
  { table: "dialog_preference_legacy_reconciliation", column: "created_at", type: "timestamp with time zone", notNull: true, default: "now()" },
  { table: "dialog_preferences", column: "account_id", type: "uuid", notNull: true, default: null },
  { table: "dialog_preference_requests", column: "account_id", type: "uuid", notNull: true, default: null },
  { table: "dialog_preference_action_budgets", column: "account_id", type: "uuid", notNull: true, default: null },
  { table: "bootstrap_snapshots", column: "account_id", type: "uuid", notNull: true, default: null },
] as const;

const REQUIRED_UNIQUE_CONSTRAINTS = [
  { table: "account_dialog_drafts", columns: ["account_id", "dialog_id"] },
  { table: "draft_attachments", columns: ["account_id", "dialog_id", "attachment_id"] },
  { table: "draft_attachments", columns: ["account_id", "dialog_id", "position"] },
  { table: "draft_attachments", columns: ["account_id", "dialog_id", "media_id"] },
  { table: "draft_mutation_requests", columns: ["account_id", "operation_id"] },
  { table: "draft_mutation_tombstones", columns: ["account_id", "operation_id"] },
  { table: "draft_mutation_budgets", columns: ["account_id", "operation_id"] },
  { table: "media_group_send_requests", columns: ["sender_account_id", "client_group_id"] },
  { table: "media_group_send_tombstones", columns: ["sender_account_id", "client_group_id"] },
] as const;

const REQUIRED_CHECK_CONSTRAINTS = new Map<string, string>([
  ["account_dialog_drafts_state_check", "state = ANY (ARRAY['active'::text, 'cleared'::text])"],
  ["account_dialog_drafts_revision_check", "revision > 0"],
  ["draft_attachments_position_check", "\"position\" >= 0 AND \"position\" <= 9"],
  ["draft_mutation_requests_payload_fingerprint_check", "octet_length(payload_fingerprint) = 32"],
  ["draft_mutation_requests_status_check", "status = ANY (ARRAY['pending'::text, 'completed'::text])"],
  ["draft_mutation_requests_check", "status = 'pending'::text AND resulting_revision IS NULL AND response_key_id IS NULL AND response_nonce IS NULL AND response_ciphertext IS NULL OR status = 'completed'::text AND resulting_revision IS NOT NULL AND response_key_id IS NOT NULL AND response_nonce IS NOT NULL AND response_ciphertext IS NOT NULL"],
  ["draft_mutation_tombstones_payload_fingerprint_check", "octet_length(payload_fingerprint) = 32"],
  ["draft_mutation_tombstones_resulting_revision_check", "resulting_revision > 0"],
  ["media_group_send_requests_payload_fingerprint_check", "octet_length(payload_fingerprint) = 32"],
  ["media_group_send_requests_status_check", "status = ANY (ARRAY['pending'::text, 'completed'::text])"],
  ["media_group_send_requests_check", "status = 'pending'::text AND first_msg_id IS NULL AND last_msg_id IS NULL AND sender_pts IS NULL OR status = 'completed'::text AND first_msg_id IS NOT NULL AND last_msg_id IS NOT NULL AND sender_pts IS NOT NULL"],
  ["media_group_send_tombstones_payload_fingerprint_check", "octet_length(payload_fingerprint) = 32"],
  ["media_group_send_budgets_item_count_check", "item_count >= 2 AND item_count <= 10"],
  ["messages_media_group_shape_check", "media_group_id IS NULL AND media_group_index IS NULL AND media_group_count IS NULL OR media_group_id IS NOT NULL AND media_group_index IS NOT NULL AND media_group_count >= 2 AND media_group_count <= 10 AND media_group_index >= 0 AND media_group_index < media_group_count AND media_id IS NOT NULL"],
]);

const REQUIRED_INDEXES = new Map<string, string>([
  ["account_dialog_drafts_dialog_idx", "CREATE INDEX account_dialog_drafts_dialog_idx ON public.account_dialog_drafts USING btree (dialog_id, account_id)"],
  ["draft_attachments_media_idx", "CREATE INDEX draft_attachments_media_idx ON public.draft_attachments USING btree (media_id)"],
  ["draft_mutation_budgets_device_window_idx", "CREATE INDEX draft_mutation_budgets_device_window_idx ON public.draft_mutation_budgets USING btree (device_id, accepted_at DESC)"],
  ["draft_mutation_requests_expiry_idx", "CREATE INDEX draft_mutation_requests_expiry_idx ON public.draft_mutation_requests USING btree (created_at, account_id, operation_id)"],
  ["draft_mutation_tombstones_dialog_idx", "CREATE INDEX draft_mutation_tombstones_dialog_idx ON public.draft_mutation_tombstones USING btree (account_id, dialog_id, resulting_revision DESC)"],
  ["media_group_send_budgets_account_window_idx", "CREATE INDEX media_group_send_budgets_account_window_idx ON public.media_group_send_budgets USING btree (account_id, accepted_at DESC)"],
  ["media_group_send_requests_expiry_idx", "CREATE INDEX media_group_send_requests_expiry_idx ON public.media_group_send_requests USING btree (created_at, sender_account_id, client_group_id)"],
  ["media_group_send_tombstones_dialog_idx", "CREATE INDEX media_group_send_tombstones_dialog_idx ON public.media_group_send_tombstones USING btree (sender_account_id, dialog_id, sender_pts DESC)"],
  ["messages_media_group_idx", "CREATE UNIQUE INDEX messages_media_group_idx ON public.messages USING btree (dialog_id, media_group_id, media_group_index) WHERE (media_group_id IS NOT NULL)"],
]);

const REQUIRED_MIGRATIONS = [
  "media-constraints-v2",
  "messages-media-group-shape-v2",
  "messages-domain-constraints-v2",
  "account-events-type-v2",
  "account-events-type-v3",
  "message-mutation-operation-v2",
  "draft-request-dialog-fk-removal-v1",
  "media-group-request-dialog-fk-removal-v1",
  "account-private-cleanup-v1",
] as const;

const LEGACY_EVENT_CONSTRAINT =
  "type = ANY (ARRAY['message.new'::text, 'message.edited'::text, 'message.deleted'::text, " +
  "'reaction.updated'::text, 'read.updated'::text, 'dialog.created'::text, " +
  "'member.added'::text, 'member.removed'::text, 'member.role_changed'::text, " +
  "'member.left'::text, 'dialog.profile_updated'::text, 'dialog.closed'::text, " +
  "'dialog.access_revoked'::text, 'dialog.preferences_updated'::text, 'profile.updated'::text, " +
  "'draft.updated'::text])";
const CURRENT_EVENT_CONSTRAINT =
  "type = ANY (ARRAY['message.new'::text, 'message.edited'::text, 'message.deleted'::text, " +
  "'message.expired'::text, 'message.preview_updated'::text, 'reaction.updated'::text, " +
  "'read.updated'::text, 'dialog.created'::text, " +
  "'member.added'::text, 'member.removed'::text, 'member.role_changed'::text, " +
  "'member.left'::text, 'dialog.profile_updated'::text, 'dialog.closed'::text, " +
  "'dialog.access_revoked'::text, 'dialog.preferences_updated'::text, 'profile.updated'::text, " +
  "'draft.updated'::text, 'security.changed'::text, 'chat_folders.updated'::text, " +
  "'scheduled.created'::text, 'scheduled.updated'::text, 'scheduled.canceled'::text, " +
  "'scheduled.failed'::text, 'pin.updated'::text, 'dialog.auto_delete_updated'::text, " +
  "'poll.updated'::text, 'sticker_preferences.updated'::text])";
const LOCKED_SEARCH_PATH = "search_path=pg_catalog, public, pg_temp";
const EXPECTED_CLEANUP_TRIGGER =
  "CREATE TRIGGER accounts_cleanup_saved_messages BEFORE UPDATE OF status ON accounts " +
  "FOR EACH ROW WHEN (old.status IS DISTINCT FROM new.status) " +
  "EXECUTE FUNCTION toj_cleanup_saved_messages_before_account_delete()";

type CachedState = { expiresAt: number; value: DraftMediaSchemaState };
const cache = new WeakMap<object, CachedState>();

function normalized(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  return String(value).replace(/\s+/g, " ").trim();
}

export function clearDraftMediaReadinessCache(sql?: SQL): void {
  if (sql) cache.delete(sql as unknown as object);
}

export async function draftMediaSchemaState(
  sql: SQL,
  options: { bypassCache?: boolean } = {},
): Promise<DraftMediaSchemaState> {
  const cacheKey = sql as unknown as object;
  const now = Date.now();
  const cached = cache.get(cacheKey);
  if (!options.bypassCache && cached && cached.expiresAt > now) return cached.value;

  const tableRows = await sql`
    SELECT required.name,
           pg_catalog.to_regclass('public.' || required.name) IS NOT NULL AS present
    FROM pg_catalog.unnest(
      ${sql.array([...REQUIRED_TABLES], "text")}::text[]
    ) AS required(name)`;
  const missingTables = tableRows
    .filter((row: any) => !row.present)
    .map((row: any) => String(row.name));

  const columnRows = await sql`
    SELECT relation.relname AS table_name,
           attribute.attname AS column_name,
           pg_catalog.format_type(attribute.atttypid, attribute.atttypmod) AS data_type,
           attribute.attnotnull AS not_null,
           pg_catalog.pg_get_expr(column_default.adbin, column_default.adrelid) AS column_default
    FROM pg_catalog.pg_attribute attribute
    JOIN pg_catalog.pg_class relation ON relation.oid = attribute.attrelid
    JOIN pg_catalog.pg_namespace namespace ON namespace.oid = relation.relnamespace
    LEFT JOIN pg_catalog.pg_attrdef column_default
      ON column_default.adrelid = relation.oid
     AND column_default.adnum = attribute.attnum
    WHERE namespace.nspname = 'public'
      AND relation.relname = ANY(
        ${sql.array([...new Set(REQUIRED_COLUMNS.map((column) => column.table))], "text")}::text[]
      )
      AND attribute.attnum > 0
      AND NOT attribute.attisdropped`;
  const actualColumns = new Map<string, { type: string; notNull: boolean; default: string | null }>(
    columnRows.map((row: any) => [
      `${row.table_name}.${row.column_name}`,
      {
        type: String(row.data_type),
        notNull: Boolean(row.not_null),
        default: normalized(row.column_default),
      },
    ]),
  );
  const missingColumns: string[] = [];
  const invalidColumns: string[] = [];
  for (const expected of REQUIRED_COLUMNS) {
    if (missingTables.includes(expected.table)) continue;
    const key = `${expected.table}.${expected.column}`;
    const actual = actualColumns.get(key);
    if (!actual) {
      missingColumns.push(key);
    } else if (
      actual.type !== expected.type
      || actual.notNull !== expected.notNull
      || actual.default !== normalized(expected.default)
    ) {
      invalidColumns.push(key);
    }
  }

  const uniqueRows = await sql`
    SELECT relation.relname AS table_name,
           pg_catalog.array_agg(attribute.attname ORDER BY key.ordinality) AS columns
    FROM pg_catalog.pg_constraint constraint_row
    JOIN pg_catalog.pg_class relation ON relation.oid = constraint_row.conrelid
    JOIN pg_catalog.pg_namespace namespace ON namespace.oid = relation.relnamespace
    JOIN pg_catalog.pg_index conflict_index
      ON conflict_index.indexrelid = constraint_row.conindid
     AND conflict_index.indrelid = constraint_row.conrelid
    CROSS JOIN LATERAL pg_catalog.unnest(constraint_row.conkey)
      WITH ORDINALITY AS key(attnum, ordinality)
    JOIN pg_catalog.pg_attribute attribute
      ON attribute.attrelid = relation.oid
     AND attribute.attnum = key.attnum
    WHERE namespace.nspname = 'public'
      AND constraint_row.contype IN ('p', 'u')
      AND constraint_row.convalidated
      AND NOT constraint_row.condeferrable
      AND NOT constraint_row.condeferred
      AND conflict_index.indisunique
      AND conflict_index.indimmediate
      AND conflict_index.indisvalid
      AND conflict_index.indisready
      AND conflict_index.indislive
      AND conflict_index.indpred IS NULL
      AND conflict_index.indexprs IS NULL
      AND conflict_index.indnkeyatts =
          pg_catalog.array_length(constraint_row.conkey, 1)
      AND relation.relname = ANY(
        ${sql.array([...new Set(REQUIRED_UNIQUE_CONSTRAINTS.map((item) => item.table))], "text")}::text[]
      )
    GROUP BY relation.relname, constraint_row.oid`;
  const actualUnique = new Set(
    uniqueRows.map((row: any) => `${row.table_name}(${row.columns.join(",")})`),
  );
  const missingUniqueConstraints = REQUIRED_UNIQUE_CONSTRAINTS
    .map((item) => `${item.table}(${item.columns.join(",")})`)
    .filter((item) => !actualUnique.has(item));

  const checkRows = await sql`
    SELECT constraint_row.conname,
           constraint_row.convalidated,
           pg_catalog.pg_get_expr(
             constraint_row.conbin,
             constraint_row.conrelid,
             TRUE
           ) AS expression
    FROM pg_catalog.pg_constraint constraint_row
    JOIN pg_catalog.pg_class relation ON relation.oid = constraint_row.conrelid
    JOIN pg_catalog.pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND constraint_row.contype = 'c'
      AND constraint_row.conname = ANY(
        ${sql.array([...REQUIRED_CHECK_CONSTRAINTS.keys()], "text")}::text[]
      )`;
  const actualChecks = new Map(
    checkRows.map((row: any) => [
      String(row.conname),
      Boolean(row.convalidated) ? normalized(row.expression) : null,
    ]),
  );
  const missingCheckConstraints = [...REQUIRED_CHECK_CONSTRAINTS]
    .filter(([name, expression]) => actualChecks.get(name) !== normalized(expression))
    .map(([name]) => name);

  const indexRows = await sql`
    SELECT index_relation.relname AS index_name,
           index_row.indisvalid,
           index_row.indisready,
           index_row.indislive,
           pg_catalog.pg_get_indexdef(index_row.indexrelid) AS definition
    FROM pg_catalog.pg_index index_row
    JOIN pg_catalog.pg_class index_relation
      ON index_relation.oid = index_row.indexrelid
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid = index_relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND index_relation.relname = ANY(
        ${sql.array([...REQUIRED_INDEXES.keys()], "text")}::text[]
      )`;
  const actualIndexes = new Map(
    indexRows.map((row: any) => [
      String(row.index_name),
      row.indisvalid && row.indisready && row.indislive
        ? normalized(row.definition)
        : null,
    ]),
  );
  const missingIndexes = [...REQUIRED_INDEXES]
    .filter(([name, definition]) => actualIndexes.get(name) !== normalized(definition))
    .map(([name]) => name);

  let completedMigrations = new Set<string>();
  if (!missingTables.includes("schema_migrations")) {
    const migrationRows = await sql`
      SELECT name
      FROM public.schema_migrations
      WHERE name = ANY(${sql.array([...REQUIRED_MIGRATIONS], "text")}::text[])`;
    completedMigrations = new Set(migrationRows.map((row: any) => String(row.name)));
  }
  const missingMigrations = REQUIRED_MIGRATIONS
    .filter((name) => !completedMigrations.has(name));

  let accountEventConstraintReady = false;
  if (!missingTables.includes("account_events")) {
    const eventConstraint = (await sql`
      SELECT constraint_row.convalidated,
             pg_catalog.pg_get_expr(
               constraint_row.conbin,
               constraint_row.conrelid,
               TRUE
             ) AS expression
      FROM pg_catalog.pg_constraint constraint_row
      WHERE constraint_row.conrelid =
              'public.account_events'::pg_catalog.regclass
        AND constraint_row.conname = 'account_events_type_check'
        AND constraint_row.contype = 'c'`)[0];
    accountEventConstraintReady = Boolean(eventConstraint?.convalidated)
      && [LEGACY_EVENT_CONSTRAINT, CURRENT_EVENT_CONSTRAINT]
        .some((expected) => normalized(eventConstraint?.expression) === normalized(expected));
  }

  let accountCleanupReady = false;
  if (!missingTables.includes("accounts")) {
    const cleanup = (await sql`
      SELECT
        (
          SELECT pg_catalog.count(*) = 1
             AND pg_catalog.bool_and(
               function_row.prorettype = 'pg_catalog.void'::pg_catalog.regtype
               AND function_row.proargtypes =
                   ARRAY['pg_catalog.uuid'::pg_catalog.regtype::oid]::oidvector
               AND function_row.proconfig =
                   ARRAY[${LOCKED_SEARCH_PATH}]::text[]
             )
          FROM pg_catalog.pg_proc function_row
          JOIN pg_catalog.pg_namespace namespace
            ON namespace.oid = function_row.pronamespace
          WHERE namespace.nspname = 'public'
            AND function_row.proname = 'toj_cleanup_account_private_state_v1'
        ) AS cleanup_function_ready,
        (
          SELECT pg_catalog.count(*) = 1
             AND pg_catalog.bool_and(
               function_row.prorettype = 'pg_catalog.void'::pg_catalog.regtype
               AND function_row.proargtypes =
                   ARRAY['pg_catalog.uuid'::pg_catalog.regtype::oid]::oidvector
             )
          FROM pg_catalog.pg_proc function_row
          JOIN pg_catalog.pg_namespace namespace
            ON namespace.oid = function_row.pronamespace
          WHERE namespace.nspname = 'public'
            AND function_row.proname =
                'toj_cleanup_saved_messages_for_account'
        ) AS saved_cleanup_function_ready,
        (
          SELECT pg_catalog.count(*) = 1
             AND pg_catalog.bool_and(
               function_row.prorettype = 'pg_catalog.trigger'::pg_catalog.regtype
               AND function_row.pronargs = 0
               AND function_row.proconfig =
                   ARRAY[${LOCKED_SEARCH_PATH}]::text[]
             )
          FROM pg_catalog.pg_proc function_row
          JOIN pg_catalog.pg_namespace namespace
            ON namespace.oid = function_row.pronamespace
          WHERE namespace.nspname = 'public'
            AND function_row.proname =
                'toj_cleanup_saved_messages_before_account_delete'
        ) AS trigger_function_ready,
        COALESCE((
          SELECT trigger_row.tgenabled = 'O'
             AND NOT trigger_row.tgisinternal
             AND trigger_row.tgtype = 19
             AND trigger_row.tgnargs = 0
             AND trigger_row.tgconstraint = 0
             AND NOT trigger_row.tgdeferrable
             AND NOT trigger_row.tginitdeferred
             AND pg_catalog.pg_get_triggerdef(trigger_row.oid, TRUE) =
                 ${EXPECTED_CLEANUP_TRIGGER}
          FROM pg_catalog.pg_trigger trigger_row
          WHERE trigger_row.tgrelid = 'public.accounts'::pg_catalog.regclass
            AND trigger_row.tgname = 'accounts_cleanup_saved_messages'
        ), FALSE) AS trigger_ready,
        (
          SELECT pg_catalog.count(*) = 1
          FROM pg_catalog.pg_trigger topology_trigger
          WHERE topology_trigger.tgrelid =
                  'public.accounts'::pg_catalog.regclass
            AND NOT topology_trigger.tgisinternal
            AND topology_trigger.tgfoid IN (
              SELECT intended_function.oid
              FROM pg_catalog.pg_proc intended_function
              JOIN pg_catalog.pg_namespace intended_namespace
                ON intended_namespace.oid = intended_function.pronamespace
              WHERE intended_namespace.nspname = 'public'
                AND intended_function.proname =
                    'toj_cleanup_saved_messages_before_account_delete'
                AND intended_function.pronargs = 0
            )
        ) AS topology_ready`)[0];
    accountCleanupReady = Boolean(cleanup?.cleanup_function_ready)
      && Boolean(cleanup?.saved_cleanup_function_ready)
      && Boolean(cleanup?.trigger_function_ready)
      && Boolean(cleanup?.trigger_ready)
      && Boolean(cleanup?.topology_ready);
  }

  const value = {
    ready: missingTables.length === 0
      && missingColumns.length === 0
      && invalidColumns.length === 0
      && missingUniqueConstraints.length === 0
      && missingCheckConstraints.length === 0
      && missingIndexes.length === 0
      && missingMigrations.length === 0
      && accountEventConstraintReady
      && accountCleanupReady,
    missingTables,
    missingColumns,
    invalidColumns,
    missingUniqueConstraints,
    missingCheckConstraints,
    missingIndexes,
    missingMigrations,
    accountEventConstraintReady,
    accountCleanupReady,
  };
  const ttlMs = Math.max(
    0,
    Number(process.env.TOJ_DRAFT_MEDIA_READINESS_CACHE_MS ?? 5_000),
  );
  cache.set(cacheKey, { expiresAt: now + ttlMs, value });
  return value;
}
