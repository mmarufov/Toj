import type { SQL } from "bun";

export type DialogPreferenceSchemaState = {
  ready: boolean;
  missingTables: string[];
  missingColumns: string[];
  invalidColumns: string[];
  missingUniqueConstraints: string[];
  eventConstraintValidated: boolean;
  compatibilityTriggerReady: boolean;
  migrationCompleted: boolean;
  contractVersion: number;
  contractCompleted: boolean;
  reconciliationBacklog: number;
};

type ColumnContract = {
  table: string;
  column: string;
  type: string;
  notNull: boolean;
  default: string | null;
};

const REQUIRED_TABLES = [
  "dialog_members",
  "dialog_preferences",
  "dialog_preference_requests",
  "dialog_preference_action_budgets",
  "dialog_preference_legacy_reconciliation",
  "online_migration_cursors",
  "bootstrap_snapshot_dialogs",
  "account_events",
  "push_deliveries",
] as const;

// These signatures are part of the executable SQL contract, not merely migration documentation.
// Checking defaults and nullability catches partially applied ALTERs that would otherwise admit
// traffic and then subtly change optimistic state, idempotency, or snapshot semantics.
const REQUIRED_COLUMNS: readonly ColumnContract[] = [
  { table: "dialog_members", column: "notification_mode", type: "text", notNull: true, default: "'all'::text" },
  { table: "dialog_preferences", column: "dialog_id", type: "uuid", notNull: true, default: null },
  { table: "dialog_preferences", column: "account_id", type: "uuid", notNull: true, default: null },
  { table: "dialog_preferences", column: "is_pinned", type: "boolean", notNull: true, default: "false" },
  { table: "dialog_preferences", column: "pinned_at", type: "timestamp with time zone", notNull: false, default: null },
  { table: "dialog_preferences", column: "is_muted", type: "boolean", notNull: true, default: "false" },
  { table: "dialog_preferences", column: "is_archived", type: "boolean", notNull: true, default: "false" },
  { table: "dialog_preferences", column: "updated_at", type: "timestamp with time zone", notNull: true, default: "now()" },
  { table: "dialog_preference_requests", column: "account_id", type: "uuid", notNull: true, default: null },
  { table: "dialog_preference_requests", column: "client_mutation_id", type: "uuid", notNull: true, default: null },
  { table: "dialog_preference_requests", column: "dialog_id", type: "uuid", notNull: true, default: null },
  { table: "dialog_preference_requests", column: "fingerprint", type: "bytea", notNull: true, default: null },
  { table: "dialog_preference_requests", column: "status", type: "text", notNull: true, default: "'pending'::text" },
  { table: "dialog_preference_requests", column: "result_pts", type: "bigint", notNull: false, default: null },
  { table: "dialog_preference_requests", column: "result_json", type: "jsonb", notNull: false, default: null },
  { table: "dialog_preference_requests", column: "created_at", type: "timestamp with time zone", notNull: true, default: "now()" },
  { table: "dialog_preference_action_budgets", column: "account_id", type: "uuid", notNull: true, default: null },
  { table: "dialog_preference_action_budgets", column: "bucket_started", type: "timestamp with time zone", notNull: true, default: null },
  { table: "dialog_preference_action_budgets", column: "mutation_count", type: "integer", notNull: true, default: "0" },
  { table: "dialog_preference_action_budgets", column: "updated_at", type: "timestamp with time zone", notNull: true, default: "now()" },
  { table: "dialog_preference_legacy_reconciliation", column: "dialog_id", type: "uuid", notNull: true, default: null },
  { table: "dialog_preference_legacy_reconciliation", column: "account_id", type: "uuid", notNull: true, default: null },
  { table: "dialog_preference_legacy_reconciliation", column: "created_at", type: "timestamp with time zone", notNull: true, default: "now()" },
  { table: "online_migration_cursors", column: "migration_name", type: "text", notNull: true, default: null },
  { table: "online_migration_cursors", column: "last_dialog_id", type: "uuid", notNull: false, default: null },
  { table: "online_migration_cursors", column: "last_account_id", type: "uuid", notNull: false, default: null },
  { table: "online_migration_cursors", column: "rows_processed", type: "bigint", notNull: true, default: "0" },
  { table: "online_migration_cursors", column: "completed_at", type: "timestamp with time zone", notNull: false, default: null },
  { table: "online_migration_cursors", column: "contract_version", type: "integer", notNull: true, default: "0" },
  { table: "online_migration_cursors", column: "contract_completed_at", type: "timestamp with time zone", notNull: false, default: null },
  { table: "online_migration_cursors", column: "updated_at", type: "timestamp with time zone", notNull: true, default: "now()" },
  { table: "bootstrap_snapshot_dialogs", column: "preferences_captured", type: "boolean", notNull: true, default: "false" },
  { table: "bootstrap_snapshot_dialogs", column: "preference_is_pinned", type: "boolean", notNull: false, default: null },
  { table: "bootstrap_snapshot_dialogs", column: "preference_pinned_at", type: "timestamp with time zone", notNull: false, default: null },
  { table: "bootstrap_snapshot_dialogs", column: "preference_is_muted", type: "boolean", notNull: false, default: null },
  { table: "bootstrap_snapshot_dialogs", column: "preference_is_archived", type: "boolean", notNull: false, default: null },
  { table: "bootstrap_snapshot_dialogs", column: "preference_updated_at", type: "timestamp with time zone", notNull: false, default: null },
  { table: "account_events", column: "type", type: "text", notNull: true, default: null },
  { table: "account_events", column: "data", type: "jsonb", notNull: true, default: "'{}'::jsonb" },
  { table: "push_deliveries", column: "account_id", type: "uuid", notNull: true, default: null },
  { table: "push_deliveries", column: "pts", type: "bigint", notNull: true, default: null },
  { table: "push_deliveries", column: "device_id", type: "uuid", notNull: true, default: null },
] as const;

const REQUIRED_UNIQUE_CONSTRAINTS = [
  { table: "dialog_members", columns: ["dialog_id", "account_id"] },
  { table: "dialog_preferences", columns: ["dialog_id", "account_id"] },
  { table: "dialog_preference_requests", columns: ["account_id", "client_mutation_id"] },
  { table: "dialog_preference_action_budgets", columns: ["account_id", "bucket_started"] },
  { table: "dialog_preference_legacy_reconciliation", columns: ["dialog_id", "account_id"] },
  { table: "online_migration_cursors", columns: ["migration_name"] },
  { table: "push_deliveries", columns: ["account_id", "pts", "device_id"] },
] as const;

const LEGACY_EVENT_CONSTRAINT =
  "type = ANY (ARRAY['message.new'::text, 'message.edited'::text, 'message.deleted'::text, " +
  "'reaction.updated'::text, 'read.updated'::text, 'dialog.created'::text, " +
  "'member.added'::text, 'member.removed'::text, 'member.role_changed'::text, " +
  "'member.left'::text, 'dialog.profile_updated'::text, 'dialog.closed'::text, " +
  "'dialog.access_revoked'::text, 'dialog.preferences_updated'::text, 'profile.updated'::text, " +
  "'draft.updated'::text])";
const PRODUCTIVITY_EVENT_CONSTRAINT =
  "type = ANY (ARRAY['message.new'::text, 'message.edited'::text, 'message.deleted'::text, " +
  "'message.preview_updated'::text, 'reaction.updated'::text, 'read.updated'::text, " +
  "'dialog.created'::text, 'member.added'::text, 'member.removed'::text, " +
  "'member.role_changed'::text, 'member.left'::text, 'dialog.profile_updated'::text, " +
  "'dialog.closed'::text, 'dialog.access_revoked'::text, 'dialog.preferences_updated'::text, " +
  "'profile.updated'::text, 'draft.updated'::text, 'chat_folders.updated'::text, " +
  "'scheduled.created'::text, 'scheduled.updated'::text, 'scheduled.canceled'::text, " +
  "'scheduled.failed'::text])";
const MESSAGING_EVENT_CONSTRAINT =
  "type = ANY (ARRAY['message.new'::text, 'message.edited'::text, 'message.deleted'::text, " +
  "'message.expired'::text, 'message.preview_updated'::text, 'reaction.updated'::text, " +
  "'read.updated'::text, 'dialog.created'::text, 'member.added'::text, " +
  "'member.removed'::text, 'member.role_changed'::text, 'member.left'::text, " +
  "'dialog.profile_updated'::text, 'dialog.closed'::text, 'dialog.access_revoked'::text, " +
  "'dialog.preferences_updated'::text, 'profile.updated'::text, 'draft.updated'::text, " +
  "'security.changed'::text, 'chat_folders.updated'::text, 'scheduled.created'::text, " +
  "'scheduled.updated'::text, 'scheduled.canceled'::text, 'scheduled.failed'::text, " +
  "'pin.updated'::text, 'dialog.auto_delete_updated'::text, 'poll.updated'::text, " +
  "'sticker_preferences.updated'::text])";
const FINAL_TRIGGER_FUNCTION = "mirror_dialog_notification_mode_to_preferences_v1_final";
const STAGING_TRIGGER_FUNCTION =
  "mirror_dialog_notification_mode_to_preferences_v1_staging";
const LOCKED_TRIGGER_SEARCH_PATH = "search_path=pg_catalog, public, pg_temp";
const FINAL_CONTRACT_VERSION = 1;

type CachedState = { expiresAt: number; value: DialogPreferenceSchemaState };
const cache = new WeakMap<object, CachedState>();

function normalizedExpression(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  return String(value).replace(/\s+/g, " ").trim();
}

export function clearDialogPreferenceReadinessCache(sql?: SQL): void {
  if (sql) cache.delete(sql as unknown as object);
}

export async function dialogPreferenceSchemaState(
  sql: SQL,
  options: { bypassCache?: boolean } = {},
): Promise<DialogPreferenceSchemaState> {
  const cacheKey = sql as unknown as object;
  const now = Date.now();
  const cached = cache.get(cacheKey);
  if (!options.bypassCache && cached && cached.expiresAt > now) return cached.value;

  const tables = await sql`
    SELECT required.name,
           pg_catalog.to_regclass('public.' || required.name) IS NOT NULL AS present
    FROM pg_catalog.unnest(
      ${sql.array([...REQUIRED_TABLES], "text")}::text[]
    ) AS required(name)`;
  const missingTables = tables
    .filter((row: any) => !row.present)
    .map((row: any) => String(row.name));

  const existingColumns = await sql`
    SELECT relation.relname AS table_name,
           attribute.attname AS column_name,
           pg_catalog.format_type(attribute.atttypid, attribute.atttypmod) AS data_type,
           attribute.attnotnull AS not_null,
           pg_catalog.pg_get_expr(
             column_default.adbin,
             column_default.adrelid
           ) AS column_default
    FROM pg_catalog.pg_attribute attribute
    JOIN pg_catalog.pg_class relation ON relation.oid = attribute.attrelid
    JOIN pg_catalog.pg_namespace namespace ON namespace.oid = relation.relnamespace
    LEFT JOIN pg_catalog.pg_attrdef column_default
      ON column_default.adrelid = relation.oid
     AND column_default.adnum = attribute.attnum
    WHERE namespace.nspname = 'public'
      AND relation.relname = ANY(${sql.array([...new Set(REQUIRED_COLUMNS.map((column) => column.table))], "text")}::text[])
      AND attribute.attnum > 0
      AND NOT attribute.attisdropped`;
  const actualColumns = new Map<string, { type: string; notNull: boolean; default: string | null }>(
    existingColumns.map((row: any) => [
      `${row.table_name}.${row.column_name}`,
      {
        type: String(row.data_type),
        notNull: Boolean(row.not_null),
        default: normalizedExpression(row.column_default),
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
      continue;
    }
    if (
      actual.type !== expected.type
      || actual.notNull !== expected.notNull
      || actual.default !== normalizedExpression(expected.default)
    ) {
      invalidColumns.push(key);
    }
  }

  const constraintRows = await sql`
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
      AND relation.relname = ANY(${sql.array([...new Set(REQUIRED_UNIQUE_CONSTRAINTS.map((constraint) => constraint.table))], "text")}::text[])
    GROUP BY relation.relname, constraint_row.oid`;
  const existingUniqueConstraints = new Set(
    constraintRows.map((row: any) => `${row.table_name}(${row.columns.join(",")})`),
  );
  const missingUniqueConstraints = REQUIRED_UNIQUE_CONSTRAINTS
    .map((constraint) => `${constraint.table}(${constraint.columns.join(",")})`)
    .filter((constraint) => !existingUniqueConstraints.has(constraint));

  let eventConstraintValidated = false;
  let compatibilityTriggerReady = false;
  let migrationCompleted = false;
  let contractVersion = -1;
  let contractCompleted = false;
  let reconciliationBacklog = -1;
  if (
    missingTables.length === 0
    && missingColumns.length === 0
    && invalidColumns.length === 0
    && missingUniqueConstraints.length === 0
  ) {
    const state = (await sql`
      SELECT
        COALESCE((
          SELECT constraint_row.convalidated
             AND pg_catalog.pg_get_expr(
                   constraint_row.conbin,
                   constraint_row.conrelid,
                   TRUE
                 ) = ANY(${sql.array([
                   LEGACY_EVENT_CONSTRAINT,
                   PRODUCTIVITY_EVENT_CONSTRAINT,
                   MESSAGING_EVENT_CONSTRAINT,
                 ], "text")}::text[])
          FROM pg_catalog.pg_constraint constraint_row
          WHERE constraint_row.conrelid = 'public.account_events'::pg_catalog.regclass
            AND constraint_row.conname = 'account_events_type_check'
            AND constraint_row.contype = 'c'
        ), FALSE) AS event_constraint_validated,
        (
          SELECT pg_catalog.count(*) = 1
          FROM pg_catalog.pg_trigger trigger_row
          JOIN pg_catalog.pg_proc function_row
            ON function_row.oid = trigger_row.tgfoid
          JOIN pg_catalog.pg_namespace function_namespace
            ON function_namespace.oid = function_row.pronamespace
          JOIN pg_catalog.pg_attribute notification_column
            ON notification_column.attrelid = trigger_row.tgrelid
           AND notification_column.attname = 'notification_mode'
           AND NOT notification_column.attisdropped
          WHERE trigger_row.tgrelid =
                  'public.dialog_members'::pg_catalog.regclass
            AND trigger_row.tgname =
                  'dialog_members_notification_mode_mirror'
            AND NOT trigger_row.tgisinternal
            AND trigger_row.tgenabled = 'O'
            -- AFTER + ROW + INSERT + UPDATE, and no other event kind.
            AND trigger_row.tgtype = 21
            AND pg_catalog.cardinality(trigger_row.tgattr::smallint[]) = 1
            AND trigger_row.tgattr::smallint[] @>
                ARRAY[notification_column.attnum::smallint]
            AND trigger_row.tgconstraint = 0
            AND NOT trigger_row.tgdeferrable
            AND NOT trigger_row.tginitdeferred
            AND trigger_row.tgqual IS NULL
            AND trigger_row.tgoldtable IS NULL
            AND trigger_row.tgnewtable IS NULL
            AND trigger_row.tgnargs = 0
            AND function_namespace.nspname = 'public'
            AND function_row.proname = ${FINAL_TRIGGER_FUNCTION}
            AND pg_catalog.pg_get_function_identity_arguments(function_row.oid) = ''
            AND function_row.proconfig =
                ARRAY[${LOCKED_TRIGGER_SEARCH_PATH}]::text[]
        )
        AND (
          SELECT pg_catalog.count(*) = 2
             AND pg_catalog.bool_and(
               COALESCE(
                 secured_function.proconfig =
                   ARRAY[${LOCKED_TRIGGER_SEARCH_PATH}]::text[],
                 FALSE
               )
             )
          FROM pg_catalog.pg_proc secured_function
          JOIN pg_catalog.pg_namespace secured_namespace
            ON secured_namespace.oid = secured_function.pronamespace
          WHERE secured_namespace.nspname = 'public'
            AND secured_function.proname = ANY(ARRAY[
              ${FINAL_TRIGGER_FUNCTION},
              ${STAGING_TRIGGER_FUNCTION}
            ]::text[])
            AND pg_catalog.pg_get_function_identity_arguments(
                  secured_function.oid
                ) = ''
            AND secured_function.prorettype =
                'pg_catalog.trigger'::pg_catalog.regtype
        )
        AND (
          SELECT pg_catalog.count(*) = 1
          FROM pg_catalog.pg_trigger topology_trigger
          WHERE NOT topology_trigger.tgisinternal
            AND topology_trigger.tgrelid =
                'public.dialog_members'::pg_catalog.regclass
            AND topology_trigger.tgfoid IN (
              SELECT intended_function.oid
              FROM pg_catalog.pg_proc intended_function
              JOIN pg_catalog.pg_namespace intended_namespace
                ON intended_namespace.oid = intended_function.pronamespace
              WHERE intended_namespace.nspname = 'public'
                AND intended_function.proname = ANY(ARRAY[
                  ${FINAL_TRIGGER_FUNCTION},
                  ${STAGING_TRIGGER_FUNCTION}
                ]::text[])
                AND pg_catalog.pg_get_function_identity_arguments(
                      intended_function.oid
                    ) = ''
                AND intended_function.prorettype =
                    'pg_catalog.trigger'::pg_catalog.regtype
            )
        ) AS compatibility_trigger_ready,
        COALESCE((
          SELECT completed_at IS NOT NULL
          FROM public.online_migration_cursors
          WHERE migration_name = 'dialog_preferences_v1'
        ), FALSE) AS migration_completed,
        COALESCE((
          SELECT contract_version
          FROM public.online_migration_cursors
          WHERE migration_name = 'dialog_preferences_v1'
        ), -1) AS contract_version,
        COALESCE((
          SELECT contract_version = ${FINAL_CONTRACT_VERSION}
             AND contract_completed_at IS NOT NULL
          FROM public.online_migration_cursors
          WHERE migration_name = 'dialog_preferences_v1'
        ), FALSE) AS contract_completed,
        EXISTS (
          SELECT 1
          FROM public.dialog_preference_legacy_reconciliation
          LIMIT 1
        ) AS has_reconciliation_backlog`)[0];
    eventConstraintValidated = Boolean(state?.event_constraint_validated);
    compatibilityTriggerReady = Boolean(state?.compatibility_trigger_ready);
    migrationCompleted = Boolean(state?.migration_completed);
    contractVersion = Number(state?.contract_version ?? -1);
    contractCompleted = Boolean(state?.contract_completed);
    reconciliationBacklog = state?.has_reconciliation_backlog ? 1 : 0;
  }

  const value = {
    ready: missingTables.length === 0
      && missingColumns.length === 0
      && invalidColumns.length === 0
      && missingUniqueConstraints.length === 0
      && eventConstraintValidated
      && compatibilityTriggerReady
      && migrationCompleted
      && contractVersion === FINAL_CONTRACT_VERSION
      && contractCompleted
      && reconciliationBacklog === 0,
    missingTables,
    missingColumns,
    invalidColumns,
    missingUniqueConstraints,
    eventConstraintValidated,
    compatibilityTriggerReady,
    migrationCompleted,
    contractVersion,
    contractCompleted,
    reconciliationBacklog,
  };
  const ttlMs = Math.max(
    0,
    Number(process.env.TOJ_DIALOG_PREFERENCE_READINESS_CACHE_MS ?? 5_000),
  );
  cache.set(cacheKey, { expiresAt: now + ttlMs, value });
  return value;
}

export async function dialogPreferenceBehaviorAvailable(sql: SQL): Promise<boolean> {
  if (process.env.TOJ_DIALOG_PREFERENCES_BEHAVIOR_ENABLED === "0") return false;
  return (await dialogPreferenceSchemaState(sql)).ready;
}
