import type { SQL } from "bun";

export type MessagingFeatureSchemaState = {
  ready: boolean;
  missingTables: string[];
  missingIndexes: string[];
  missingMigrations: string[];
  columnsReady: boolean;
  constraintsReady: boolean;
};

const REQUIRED_TABLES = [
  "message_pins",
  "message_polls",
  "poll_votes",
  "message_external_content",
  "sticker_packs",
  "stickers",
  "account_sticker_packs",
  "account_sticker_favorites",
  "account_sticker_recents",
  "messaging_feature_mutations",
  "push_installations",
  "push_account_bindings",
] as const;

const REQUIRED_INDEXES = [
  "messages_visible_expiry_idx",
  "message_pins_dialog_latest_idx",
  "poll_votes_poll_idx",
  "stickers_search_idx",
  "account_sticker_recents_latest_idx",
  "push_installations_normal_token_active_idx",
  "push_installations_voip_token_active_idx",
  "push_account_bindings_account_active_idx",
  "messaging_feature_mutations_cleanup_idx",
  "messaging_feature_mutations_pending_cleanup_idx",
] as const;

const REQUIRED_MIGRATIONS = [
  "messaging-parity-expand-v1",
  "messaging-parity-indexes-v1",
  "messaging-parity-contract-v1",
  "push-binding-kind-flags-v1",
  "messages-domain-constraints-v3",
  "account-events-type-v7",
] as const;

const REQUIRED_EVENT_TYPES = [
  "security.changed",
  "message.preview_updated",
  "scheduled.created",
  "message.expired",
  "pin.updated",
  "dialog.auto_delete_updated",
  "poll.updated",
  "sticker_preferences.updated",
] as const;

type CacheEntry = {
  expiresAt: number;
  value?: MessagingFeatureSchemaState;
  inFlight?: Promise<MessagingFeatureSchemaState>;
};
const cache = new WeakMap<object, CacheEntry>();

export function clearMessagingFeatureReadinessCache(sql?: SQL): void {
  if (sql) cache.delete(sql as unknown as object);
}

export async function messagingFeatureSchemaState(
  sql: SQL,
  options: { bypassCache?: boolean } = {},
): Promise<MessagingFeatureSchemaState> {
  const key = sql as unknown as object;
  const now = Date.now();
  const cached = cache.get(key);
  if (!options.bypassCache && cached) {
    if (cached.value && cached.expiresAt > now) return cached.value;
    if (cached.inFlight) return await cached.inFlight;
  }
  const inFlight = (async (): Promise<MessagingFeatureSchemaState> => {
    const tableRows = await sql`
      /* messaging_feature_required_tables */
      SELECT required.name, to_regclass('public.' || required.name) IS NOT NULL AS present
      FROM unnest(${sql.array([...REQUIRED_TABLES], "text")}::text[]) required(name)`;
    const missingTables = tableRows.filter((row: any) => !row.present)
      .map((row: any) => String(row.name));
    const indexRows = await sql`
      SELECT required.name,
             COALESCE(index_row.indisvalid AND index_row.indisready AND index_row.indislive, FALSE)
               AS present
      FROM unnest(${sql.array([...REQUIRED_INDEXES], "text")}::text[]) required(name)
      LEFT JOIN pg_class index_class ON index_class.relname = required.name
      LEFT JOIN pg_namespace index_namespace
        ON index_namespace.oid = index_class.relnamespace
       AND index_namespace.nspname = 'public'
      LEFT JOIN pg_index index_row ON index_row.indexrelid = index_class.oid`;
    const missingIndexes = indexRows.filter((row: any) => !row.present)
      .map((row: any) => String(row.name));
    const migrationRows = await sql`
      SELECT required.name, migration.name IS NOT NULL AS present
      FROM unnest(${sql.array([...REQUIRED_MIGRATIONS], "text")}::text[]) required(name)
      LEFT JOIN schema_migrations migration ON migration.name = required.name`;
    const missingMigrations = migrationRows.filter((row: any) => !row.present)
      .map((row: any) => String(row.name));
    const columns = (await sql`
      SELECT
        EXISTS (SELECT 1 FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = 'messages'
            AND column_name = 'expires_at' AND data_type = 'timestamp with time zone')
        AND EXISTS (SELECT 1 FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = 'dialogs'
            AND column_name = 'auto_delete_seconds' AND data_type = 'integer')
        AND EXISTS (SELECT 1 FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = 'push_account_bindings'
            AND column_name = 'normal_enabled' AND data_type = 'boolean'
            AND is_nullable = 'NO')
        AND EXISTS (SELECT 1 FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = 'push_account_bindings'
            AND column_name = 'voip_enabled' AND data_type = 'boolean'
            AND is_nullable = 'NO')
        AND EXISTS (SELECT 1 FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = 'send_requests'
            AND column_name = 'fingerprint' AND data_type = 'bytea')
        AND (SELECT count(*) = 1
          FROM pg_trigger trigger_row
          JOIN pg_proc function_row ON function_row.oid = trigger_row.tgfoid
          JOIN pg_namespace namespace ON namespace.oid = function_row.pronamespace
          WHERE trigger_row.tgrelid = to_regclass('public.push_account_bindings')
            AND trigger_row.tgname = 'push_installation_account_limit'
            AND NOT trigger_row.tgisinternal AND trigger_row.tgenabled = 'O'
            AND namespace.nspname = 'public'
            AND function_row.proname = 'enforce_push_installation_account_limit'
            AND function_row.proconfig = ARRAY['search_path=pg_catalog, public, pg_temp']::text[])
          AS ready`)[0];
    const constraintRows = await sql`
      SELECT conrelid::regclass::text AS table_name, conname, convalidated,
             pg_get_constraintdef(oid, TRUE) AS definition
      FROM pg_constraint
      WHERE (conrelid = to_regclass('public.messages') AND conname IN (
               'messages_kind_check', 'messages_service_type_check'
             ))
         OR (conrelid = to_regclass('public.account_events')
           AND conname = 'account_events_type_check')
         OR (conrelid = to_regclass('public.dialogs')
           AND conname = 'dialogs_auto_delete_seconds_check')
         OR (conrelid = to_regclass('public.push_account_bindings')
           AND conname = 'push_account_bindings_enabled_check')
         OR (conrelid = to_regclass('public.send_requests')
           AND conname = 'send_requests_fingerprint_size_check')`;
    const byName = new Map<string, { definition: string; convalidated: boolean }>(
      constraintRows.map((row: any) => [String(row.conname), row]),
    );
    const messageKinds = String(byName.get("messages_kind_check")?.definition ?? "");
    const serviceTypes = String(byName.get("messages_service_type_check")?.definition ?? "");
    const eventTypes = String(byName.get("account_events_type_check")?.definition ?? "");
    const bindingKinds = String(
      byName.get("push_account_bindings_enabled_check")?.definition ?? "",
    );
    const constraintsReady = [
      "messages_kind_check",
      "messages_service_type_check",
      "account_events_type_check",
      "dialogs_auto_delete_seconds_check",
      "push_account_bindings_enabled_check",
      "send_requests_fingerprint_size_check",
    ].every((name) => Boolean(byName.get(name)?.convalidated))
      && ["poll", "sticker", "external_media"].every((type) => messageKinds.includes(`'${type}'`))
      && ["message.pinned", "dialog.auto_delete_changed", "poll.closed"]
        .every((type) => serviceTypes.includes(`'${type}'`))
      && REQUIRED_EVENT_TYPES.every((type) => eventTypes.includes(`'${type}'`))
      && ["active", "normal_enabled", "voip_enabled"]
        .every((column) => bindingKinds.includes(column));
    const columnsReady = Boolean(columns?.ready);
    return {
      ready: missingTables.length === 0
        && missingIndexes.length === 0
        && missingMigrations.length === 0
        && columnsReady
        && constraintsReady,
      missingTables,
      missingIndexes,
      missingMigrations,
      columnsReady,
      constraintsReady,
    };
  })();
  cache.set(key, { expiresAt: now + 2_000, inFlight });
  try {
    const value = await inFlight;
    cache.set(key, { expiresAt: Date.now() + 2_000, value });
    return value;
  } catch (error) {
    cache.delete(key);
    throw error;
  }
}
