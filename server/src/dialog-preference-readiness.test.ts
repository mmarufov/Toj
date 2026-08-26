import { $, type SQL } from "bun";
import { expect, test } from "bun:test";
import { startCloudServer } from "./cloud";
import { makeSql } from "./db";
import { dialogPreferenceSchemaState } from "./dialog-preference-readiness";
import { dialogPreferenceBacklogMetrics } from "./ops";

const sourceURL = new URL(
  process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test",
);
const adminURL = new URL(sourceURL);
adminURL.pathname = "/postgres";
const serverRoot = new URL("..", import.meta.url).pathname;
const schema = new URL("./schema.sql", import.meta.url).pathname;
const concurrentSchema = new URL("./schema-concurrent.sql", import.meta.url).pathname;
const expand = new URL("./schema-dialog-preferences-expand.sql", import.meta.url).pathname;
const contract = new URL("./schema-dialog-preferences-contract.sql", import.meta.url).pathname;

type Fixture = {
  sql: SQL;
  url: string;
  runFile: (path: string) => Promise<void>;
  runMigration: () => Promise<void>;
};

async function withDisposableDatabase(
  options: { migrated: boolean },
  body: (fixture: Fixture) => Promise<void>,
): Promise<void> {
  const databaseName = `toj_readiness_${crypto.randomUUID().replaceAll("-", "").slice(0, 16)}`;
  const databaseURL = new URL(sourceURL);
  databaseURL.pathname = `/${databaseName}`;
  let sql: SQL | null = null;
  try {
    await $`psql ${adminURL.toString()} -v ON_ERROR_STOP=1 -c ${`CREATE DATABASE ${databaseName}`}`.quiet();
    const runFile = async (path: string) => {
      await $`psql ${databaseURL.toString()} -v ON_ERROR_STOP=1 -f ${path}`.quiet();
    };
    const runMigration = async () => {
      const process = Bun.spawn(["bun", "run", "src/migrate.ts"], {
        cwd: serverRoot,
        env: { ...globalThis.process.env, DATABASE_URL: databaseURL.toString() },
        stdout: "pipe",
        stderr: "pipe",
      });
      const [exitCode, stdout, stderr] = await Promise.all([
        process.exited,
        new Response(process.stdout).text(),
        new Response(process.stderr).text(),
      ]);
      if (exitCode !== 0) {
        throw new Error(`migration failed (${exitCode}): ${stderr || stdout}`);
      }
    };
    if (options.migrated) {
      await runMigration();
    } else {
      await runFile(schema);
      await runFile(concurrentSchema);
    }
    sql = makeSql(databaseURL.toString());
    await body({ sql, url: databaseURL.toString(), runFile, runMigration });
  } finally {
    if (sql) await sql.close();
    await $`psql ${adminURL.toString()} -v ON_ERROR_STOP=1 -c ${`
      SELECT pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE datname = '${databaseName}' AND pid <> pg_backend_pid()
    `}`.quiet();
    await $`psql ${adminURL.toString()} -v ON_ERROR_STOP=1 -c ${`
      DROP DATABASE IF EXISTS ${databaseName}
    `}`.quiet();
  }
}

async function readyStatus(sql: SQL): Promise<number> {
  const server = startCloudServer(0, sql, null, null);
  try {
    return (await fetch(`http://127.0.0.1:${server.port}/ready`)).status;
  } finally {
    await server.stop(true);
  }
}

const TRIGGER_ACCOUNT_ID = "00000000-0000-4000-8000-000000000091";
const TRIGGER_DIALOG_ID = "00000000-0000-4000-8000-000000000092";

async function seedTriggerMember(sql: SQL): Promise<void> {
  await sql`
    INSERT INTO public.accounts (
      id, phone_lookup_hash, phone_e164_ciphertext, phone_nonce, phone_key_id,
      display_name
    ) VALUES (
      ${TRIGGER_ACCOUNT_ID},
      decode(repeat('91', 32), 'hex'),
      decode('91', 'hex'),
      decode('92', 'hex'),
      'readiness-trigger-key',
      'Readiness trigger'
    )`;
  await sql`
    INSERT INTO public.account_sync_states (account_id)
    VALUES (${TRIGGER_ACCOUNT_ID})`;
  await sql`
    INSERT INTO public.dialogs (id, type, title, created_by)
    VALUES (
      ${TRIGGER_DIALOG_ID}, 'group', 'Readiness trigger', ${TRIGGER_ACCOUNT_ID}
    )`;
  await sql`
    INSERT INTO public.dialog_members (
      dialog_id, account_id, notification_mode
    ) VALUES (${TRIGGER_DIALOG_ID}, ${TRIGGER_ACCOUNT_ID}, 'all')`;
}

async function installTriggerShadowRelations(sql: SQL): Promise<void> {
  await sql`CREATE SCHEMA trigger_shadow`;
  await sql`
    CREATE TABLE trigger_shadow.accounts (
      id UUID PRIMARY KEY,
      status TEXT NOT NULL
    )`;
  await sql`
    INSERT INTO trigger_shadow.accounts (id, status)
    VALUES (${TRIGGER_ACCOUNT_ID}, 'active')`;
  await sql`
    CREATE TABLE trigger_shadow.dialog_preferences (
      LIKE public.dialog_preferences INCLUDING ALL
    )`;
  await sql`
    CREATE TABLE trigger_shadow.dialog_preference_legacy_reconciliation (
      LIKE public.dialog_preference_legacy_reconciliation INCLUDING ALL
    )`;
}

test("rerunning expand invalidates a completed contract until final contract is restored", async () => {
  await withDisposableDatabase({ migrated: true }, async ({ sql, runFile }) => {
    expect(await readyStatus(sql)).toBe(200);

    await runFile(expand);
    const interrupted = await dialogPreferenceSchemaState(sql, { bypassCache: true });
    expect(interrupted).toMatchObject({
      ready: false,
      compatibilityTriggerReady: false,
      contractVersion: 0,
      contractCompleted: false,
    });
    expect(await readyStatus(sql)).toBe(503);

    await runFile(contract);
    const completed = await dialogPreferenceSchemaState(sql, { bypassCache: true });
    expect(completed).toMatchObject({
      ready: true,
      compatibilityTriggerReady: true,
      contractVersion: 1,
      contractCompleted: true,
    });
    expect(await readyStatus(sql)).toBe(200);
  });
}, 120_000);

test("readiness requires locked search_path on both compatibility functions", async () => {
  await withDisposableDatabase({ migrated: true }, async ({ sql }) => {
    const functions = await sql`
      SELECT function_row.proname, function_row.proconfig
      FROM pg_catalog.pg_proc function_row
      JOIN pg_catalog.pg_namespace namespace
        ON namespace.oid = function_row.pronamespace
      WHERE namespace.nspname = 'public'
        AND function_row.proname IN (
          'mirror_dialog_notification_mode_to_preferences_v1_staging',
          'mirror_dialog_notification_mode_to_preferences_v1_final'
        )
      ORDER BY function_row.proname`;
    expect(functions).toHaveLength(2);
    expect(functions.every((row: any) =>
      row.proconfig?.length === 1
      && row.proconfig[0] === "search_path=pg_catalog, public, pg_temp"
    )).toBe(true);

    await sql`
      ALTER FUNCTION
        public.mirror_dialog_notification_mode_to_preferences_v1_final()
      SET search_path = public, pg_catalog, pg_temp`;
    expect((await dialogPreferenceSchemaState(sql, { bypassCache: true })).ready)
      .toBe(false);
    await sql`
      ALTER FUNCTION
        public.mirror_dialog_notification_mode_to_preferences_v1_final()
      SET search_path = pg_catalog, public, pg_temp`;
    expect((await dialogPreferenceSchemaState(sql, { bypassCache: true })).ready)
      .toBe(true);

    await sql`
      ALTER FUNCTION
        public.mirror_dialog_notification_mode_to_preferences_v1_staging()
      RESET search_path`;
    expect((await dialogPreferenceSchemaState(sql, { bypassCache: true })).ready)
      .toBe(false);
  });
}, 120_000);

test("staging and final triggers use public relations under a shadow search_path", async () => {
  await withDisposableDatabase({ migrated: true }, async ({ sql }) => {
    await seedTriggerMember(sql);
    await installTriggerShadowRelations(sql);
    await sql.begin(async (tx) => {
      await tx`SET LOCAL search_path = trigger_shadow, public, pg_catalog`;
      await tx`
        UPDATE public.dialog_members
        SET notification_mode = 'muted'
        WHERE dialog_id = ${TRIGGER_DIALOG_ID}
          AND account_id = ${TRIGGER_ACCOUNT_ID}`;
    });
    expect(Boolean((await sql`
      SELECT is_muted
      FROM public.dialog_preferences
      WHERE dialog_id = ${TRIGGER_DIALOG_ID}
        AND account_id = ${TRIGGER_ACCOUNT_ID}`)[0]?.is_muted)).toBe(true);
    expect(await sql`SELECT account_id FROM trigger_shadow.dialog_preferences`)
      .toHaveLength(0);
    expect(await sql`
      SELECT pts
      FROM public.account_events
      WHERE account_id = ${TRIGGER_ACCOUNT_ID}
        AND type = 'dialog.preferences_updated'`).toHaveLength(1);
  });

  await withDisposableDatabase(
    { migrated: true },
    async ({ sql, runFile }) => {
      await seedTriggerMember(sql);
      await runFile(expand);
      await installTriggerShadowRelations(sql);
      await sql.begin(async (tx) => {
        await tx`SET LOCAL search_path = trigger_shadow, public, pg_catalog`;
        await tx`
          UPDATE public.dialog_members
          SET notification_mode = 'muted'
          WHERE dialog_id = ${TRIGGER_DIALOG_ID}
            AND account_id = ${TRIGGER_ACCOUNT_ID}`;
      });
      expect(Boolean((await sql`
        SELECT is_muted
        FROM public.dialog_preferences
        WHERE dialog_id = ${TRIGGER_DIALOG_ID}
          AND account_id = ${TRIGGER_ACCOUNT_ID}`)[0]?.is_muted)).toBe(true);
      expect(await sql`
        SELECT account_id
        FROM public.dialog_preference_legacy_reconciliation
        WHERE dialog_id = ${TRIGGER_DIALOG_ID}
          AND account_id = ${TRIGGER_ACCOUNT_ID}`).toHaveLength(1);
      expect(await sql`
        SELECT account_id
        FROM trigger_shadow.dialog_preferences`).toHaveLength(0);
      expect(await sql`
        SELECT account_id
        FROM trigger_shadow.dialog_preference_legacy_reconciliation`).toHaveLength(0);
    },
  );
}, 120_000);

test("readiness requires the enabled compatibility trigger bound to the final function", async () => {
  await withDisposableDatabase({ migrated: true }, async ({ sql, runFile }) => {
    await sql`
      ALTER TABLE public.dialog_members
      DISABLE TRIGGER dialog_members_notification_mode_mirror`;
    expect((await dialogPreferenceSchemaState(sql, { bypassCache: true })).ready).toBe(false);

    await sql`
      ALTER TABLE public.dialog_members
      ENABLE TRIGGER dialog_members_notification_mode_mirror`;
    expect((await dialogPreferenceSchemaState(sql, { bypassCache: true })).ready).toBe(true);

    await sql`
      ALTER TABLE public.dialog_members
      ENABLE ALWAYS TRIGGER dialog_members_notification_mode_mirror`;
    expect((await dialogPreferenceSchemaState(sql, { bypassCache: true })).ready).toBe(false);

    await sql`
      ALTER TABLE public.dialog_members
      ENABLE TRIGGER dialog_members_notification_mode_mirror`;
    expect((await dialogPreferenceSchemaState(sql, { bypassCache: true })).ready).toBe(true);

    await sql`
      DROP TRIGGER dialog_members_notification_mode_mirror
      ON public.dialog_members`;
    expect((await dialogPreferenceSchemaState(sql, { bypassCache: true })).ready).toBe(false);

    await runFile(contract);
    expect((await dialogPreferenceSchemaState(sql, { bypassCache: true })).ready).toBe(true);
  });
}, 120_000);

const MALFORMED_TRIGGER_DEFINITIONS = [
  [
    "before instead of after",
    `CREATE TRIGGER dialog_members_notification_mode_mirror
     BEFORE INSERT OR UPDATE OF notification_mode ON public.dialog_members
     FOR EACH ROW
     EXECUTE FUNCTION public.mirror_dialog_notification_mode_to_preferences_v1_final()`,
  ],
  [
    "missing the insert event",
    `CREATE TRIGGER dialog_members_notification_mode_mirror
     AFTER UPDATE OF notification_mode ON public.dialog_members
     FOR EACH ROW
     EXECUTE FUNCTION public.mirror_dialog_notification_mode_to_preferences_v1_final()`,
  ],
  [
    "statement-level instead of row-level",
    `CREATE TRIGGER dialog_members_notification_mode_mirror
     AFTER INSERT OR UPDATE OF notification_mode ON public.dialog_members
     FOR EACH STATEMENT
     EXECUTE FUNCTION public.mirror_dialog_notification_mode_to_preferences_v1_final()`,
  ],
  [
    "watching the wrong update column",
    `CREATE TRIGGER dialog_members_notification_mode_mirror
     AFTER INSERT OR UPDATE OF role ON public.dialog_members
     FOR EACH ROW
     EXECUTE FUNCTION public.mirror_dialog_notification_mode_to_preferences_v1_final()`,
  ],
  [
    "conditional execution",
    `CREATE TRIGGER dialog_members_notification_mode_mirror
     AFTER INSERT OR UPDATE OF notification_mode ON public.dialog_members
     FOR EACH ROW
     WHEN (NEW.notification_mode = 'muted')
     EXECUTE FUNCTION public.mirror_dialog_notification_mode_to_preferences_v1_final()`,
  ],
  [
    "unexpected trigger arguments",
    `CREATE TRIGGER dialog_members_notification_mode_mirror
     AFTER INSERT OR UPDATE OF notification_mode ON public.dialog_members
     FOR EACH ROW
     EXECUTE FUNCTION public.mirror_dialog_notification_mode_to_preferences_v1_final('unexpected')`,
  ],
  [
    "staging function still attached",
    `CREATE TRIGGER dialog_members_notification_mode_mirror
     AFTER INSERT OR UPDATE OF notification_mode ON public.dialog_members
     FOR EACH ROW
     EXECUTE FUNCTION public.mirror_dialog_notification_mode_to_preferences_v1_staging()`,
  ],
] as const;

test("readiness rejects every malformed compatibility trigger topology", async () => {
  for (const [description, definition] of MALFORMED_TRIGGER_DEFINITIONS) {
    await withDisposableDatabase({ migrated: true }, async ({ sql }) => {
      await sql`
        DROP TRIGGER dialog_members_notification_mode_mirror
        ON public.dialog_members`;
      await sql.unsafe(definition);
      const state = await dialogPreferenceSchemaState(sql, { bypassCache: true });
      expect(state.compatibilityTriggerReady, description).toBe(false);
      expect(state.ready, description).toBe(false);
    });
  }
}, 240_000);

test("duplicate topology is scoped to dialog_members and intended function OIDs", async () => {
  await withDisposableDatabase({ migrated: true }, async ({ sql }) => {
    await sql`
      CREATE TRIGGER dialog_members_notification_mode_staging_duplicate
      AFTER UPDATE OF notification_mode ON public.dialog_members
      FOR EACH ROW
      EXECUTE FUNCTION
        public.mirror_dialog_notification_mode_to_preferences_v1_staging()`;
    const state = await dialogPreferenceSchemaState(sql, { bypassCache: true });
    expect(state.compatibilityTriggerReady).toBe(false);
    expect(state.ready).toBe(false);
  });
  await withDisposableDatabase({ migrated: true }, async ({ sql }) => {
    await sql`CREATE SCHEMA readiness_shadow`;
    await sql`
      CREATE TABLE public.unrelated_trigger_host (
        dialog_id UUID,
        account_id UUID,
        notification_mode TEXT
      )`;
    await sql`
      CREATE TRIGGER unrelated_intended_function_trigger
      AFTER UPDATE OF notification_mode ON public.unrelated_trigger_host
      FOR EACH ROW
      EXECUTE FUNCTION
        public.mirror_dialog_notification_mode_to_preferences_v1_staging()`;
    await sql.unsafe(`
      CREATE FUNCTION
        readiness_shadow.mirror_dialog_notification_mode_to_preferences_v1_staging()
      RETURNS TRIGGER
      LANGUAGE plpgsql
      AS $$
      BEGIN
        RETURN NEW;
      END;
      $$
    `);
    await sql`
      CREATE TRIGGER dialog_members_notification_mode_shadow_duplicate
      AFTER UPDATE OF notification_mode ON public.dialog_members
      FOR EACH ROW
      EXECUTE FUNCTION
        readiness_shadow.mirror_dialog_notification_mode_to_preferences_v1_staging()`;
    const state = await dialogPreferenceSchemaState(sql, { bypassCache: true });
    expect(state.compatibilityTriggerReady).toBe(true);
    expect(state.ready).toBe(true);
  });
}, 120_000);

test("readiness requires the exact validated account event constraint", async () => {
  await withDisposableDatabase({ migrated: true }, async ({ sql, runFile }) => {
    await sql`
      ALTER TABLE public.account_events
      DROP CONSTRAINT account_events_type_check`;
    await sql`
      ALTER TABLE public.account_events
      ADD CONSTRAINT account_events_type_check CHECK (type IN
        ('message.new','message.edited','message.deleted','reaction.updated','read.updated',
         'dialog.created','member.added','member.removed','member.role_changed','member.left',
         'dialog.profile_updated','dialog.closed','dialog.access_revoked',
         'dialog.preferences_updated','dialog.preferences_updated.extra','profile.updated'))`;
    const permissive = await dialogPreferenceSchemaState(sql, { bypassCache: true });
    expect(permissive.eventConstraintValidated).toBe(false);
    expect(permissive.ready).toBe(false);

    await runFile(expand);
    await sql`
      ALTER TABLE public.account_events
      VALIDATE CONSTRAINT account_events_type_check_v5`;
    await runFile(contract);
    expect((await dialogPreferenceSchemaState(sql, { bypassCache: true })).ready).toBe(true);
  });
}, 120_000);

const UNIQUE_INVARIANTS = [
  [
    "dialog_members",
    "dialog_members_pkey",
    "dialog_members(dialog_id,account_id)",
    "dialog_id, account_id",
  ],
  [
    "dialog_preferences",
    "dialog_preferences_pkey",
    "dialog_preferences(dialog_id,account_id)",
    "dialog_id, account_id",
  ],
  [
    "dialog_preference_requests",
    "dialog_preference_requests_pkey",
    "dialog_preference_requests(account_id,client_mutation_id)",
    "account_id, client_mutation_id",
  ],
  [
    "dialog_preference_action_budgets",
    "dialog_preference_action_budgets_pkey",
    "dialog_preference_action_budgets(account_id,bucket_started)",
    "account_id, bucket_started",
  ],
  [
    "dialog_preference_legacy_reconciliation",
    "dialog_preference_legacy_reconciliation_pkey",
    "dialog_preference_legacy_reconciliation(dialog_id,account_id)",
    "dialog_id, account_id",
  ],
  [
    "online_migration_cursors",
    "online_migration_cursors_pkey",
    "online_migration_cursors(migration_name)",
    "migration_name",
  ],
  [
    "push_deliveries",
    "push_deliveries_account_id_pts_device_id_key",
    "push_deliveries(account_id,pts,device_id)",
    "account_id, pts, device_id",
  ],
] as const;

test("readiness rejects every missing ON CONFLICT uniqueness invariant", async () => {
  for (const [table, constraint, readinessName] of UNIQUE_INVARIANTS) {
    await withDisposableDatabase({ migrated: true }, async ({ sql }) => {
      await sql.unsafe(
        `ALTER TABLE public.${table} DROP CONSTRAINT ${constraint} CASCADE`,
      );
      const state = await dialogPreferenceSchemaState(sql, { bypassCache: true });
      expect(state.ready).toBe(false);
      expect(state.missingUniqueConstraints).toContain(readinessName);
    });
  }
}, 240_000);

test("readiness rejects every deferrable ON CONFLICT uniqueness invariant", async () => {
  for (const [table, constraint, readinessName, columns] of UNIQUE_INVARIANTS) {
    await withDisposableDatabase({ migrated: true }, async ({ sql }) => {
      await sql.unsafe(
        `ALTER TABLE public.${table} DROP CONSTRAINT ${constraint} CASCADE`,
      );
      await sql.unsafe(
        `ALTER TABLE public.${table} ADD CONSTRAINT ${constraint} ` +
        `UNIQUE (${columns}) DEFERRABLE INITIALLY IMMEDIATE`,
      );
      const state = await dialogPreferenceSchemaState(sql, { bypassCache: true });
      expect(state.ready).toBe(false);
      expect(state.missingUniqueConstraints).toContain(readinessName);
    });
  }
}, 240_000);

test("readiness rejects every invalid ON CONFLICT uniqueness index", async () => {
  for (const [table, constraint, readinessName] of UNIQUE_INVARIANTS) {
    await withDisposableDatabase({ migrated: true }, async ({ sql }) => {
      await sql.begin(async (tx) => {
        await tx`SET LOCAL allow_system_table_mods = on`;
        await tx.unsafe(`
          UPDATE pg_catalog.pg_index
          SET indisvalid = FALSE
          WHERE indexrelid = (
            SELECT conindid
            FROM pg_catalog.pg_constraint
            WHERE conrelid = 'public.${table}'::pg_catalog.regclass
              AND conname = '${constraint}'
          )
        `);
      });
      const state = await dialogPreferenceSchemaState(sql, { bypassCache: true });
      expect(state.ready).toBe(false);
      expect(state.missingUniqueConstraints).toContain(readinessName);
    });
  }
}, 240_000);

test("readiness rejects conflict indexes that are not ready or live", async () => {
  for (const catalogFlag of ["indisready", "indislive"] as const) {
    await withDisposableDatabase({ migrated: true }, async ({ sql }) => {
      await sql.begin(async (tx) => {
        await tx`SET LOCAL allow_system_table_mods = on`;
        await tx.unsafe(`
          UPDATE pg_catalog.pg_index
          SET ${catalogFlag} = FALSE
          WHERE indexrelid = 'public.dialog_preferences_pkey'::pg_catalog.regclass
        `);
      });
      const state = await dialogPreferenceSchemaState(sql, { bypassCache: true });
      expect(state.ready, catalogFlag).toBe(false);
      expect(state.missingUniqueConstraints)
        .toContain("dialog_preferences(dialog_id,account_id)");
    });
  }
}, 120_000);

test("readiness rejects wrong preference column type, default, and nullability", async () => {
  await withDisposableDatabase({ migrated: true }, async ({ sql }) => {
    await sql`
      ALTER TABLE dialog_preference_requests
      ALTER COLUMN result_pts TYPE TEXT USING result_pts::text`;
    let state = await dialogPreferenceSchemaState(sql, { bypassCache: true });
    expect(state.invalidColumns).toContain("dialog_preference_requests.result_pts");
    expect(state.ready).toBe(false);
    await sql`
      ALTER TABLE dialog_preference_requests
      ALTER COLUMN result_pts TYPE BIGINT USING result_pts::bigint`;

    await sql`
      ALTER TABLE dialog_preferences
      ALTER COLUMN is_archived DROP DEFAULT`;
    state = await dialogPreferenceSchemaState(sql, { bypassCache: true });
    expect(state.invalidColumns).toContain("dialog_preferences.is_archived");
    expect(state.ready).toBe(false);
    await sql`
      ALTER TABLE dialog_preferences
      ALTER COLUMN is_archived SET DEFAULT FALSE`;

    await sql`
      ALTER TABLE dialog_preference_requests
      ALTER COLUMN result_json SET NOT NULL`;
    state = await dialogPreferenceSchemaState(sql, { bypassCache: true });
    expect(state.invalidColumns).toContain("dialog_preference_requests.result_json");
    expect(state.ready).toBe(false);
    await sql`
      ALTER TABLE dialog_preference_requests
      ALTER COLUMN result_json DROP NOT NULL`;

    expect((await dialogPreferenceSchemaState(sql, { bypassCache: true })).ready).toBe(true);
  });
}, 120_000);

test("pending-request metrics use the concurrent partial index", async () => {
  await withDisposableDatabase({ migrated: true }, async ({ sql }) => {
    await seedTriggerMember(sql);
    await sql`
      INSERT INTO public.dialog_preference_requests (
        account_id, client_mutation_id, dialog_id, fingerprint, status, created_at
      )
      SELECT
        ${TRIGGER_ACCOUNT_ID},
        gen_random_uuid(),
        ${TRIGGER_DIALOG_ID},
        decode('00', 'hex'),
        CASE WHEN series <= 5 THEN 'pending' ELSE 'completed' END,
        now() - series * interval '1 second'
      FROM generate_series(1, 20_000) AS series`;
    await sql`ANALYZE public.dialog_preference_requests`;

    const index = (await sql`
      SELECT index_row.indisvalid, index_row.indisready,
             pg_catalog.pg_get_expr(
               index_row.indpred,
               index_row.indrelid,
               TRUE
             ) AS predicate
      FROM pg_catalog.pg_index index_row
      WHERE index_row.indexrelid =
        'public.dialog_preference_requests_pending_idx'::pg_catalog.regclass`)[0];
    expect(index).toMatchObject({
      indisvalid: true,
      indisready: true,
      predicate: "status = 'pending'::text",
    });

    const plan = await sql`
      EXPLAIN (FORMAT JSON, COSTS OFF)
      SELECT pg_catalog.count(*)
      FROM public.dialog_preference_requests
      WHERE status = 'pending'`;
    const serializedPlan = JSON.stringify(plan);
    expect(serializedPlan).toContain("dialog_preference_requests_pending_idx");
    expect(serializedPlan).toContain("Index Only Scan");
  });
}, 120_000);

test("readiness and metrics ignore search-path shadow relations", async () => {
  await withDisposableDatabase({ migrated: true }, async ({ sql }) => {
    await sql`CREATE SCHEMA readiness_shadow`;
    await sql`
      CREATE TABLE readiness_shadow.online_migration_cursors (
        migration_name TEXT PRIMARY KEY,
        completed_at TIMESTAMPTZ,
        contract_version INTEGER NOT NULL,
        contract_completed_at TIMESTAMPTZ
      )`;
    await sql`
      INSERT INTO readiness_shadow.online_migration_cursors (
        migration_name, completed_at, contract_version, contract_completed_at
      ) VALUES ('dialog_preferences_v1', NULL, 0, NULL)`;
    await sql`
      CREATE TABLE readiness_shadow.dialog_preference_legacy_reconciliation (
        marker INTEGER
      )`;
    await sql`
      INSERT INTO readiness_shadow.dialog_preference_legacy_reconciliation
      VALUES (1)`;
    await sql`
      CREATE TABLE readiness_shadow.dialog_preference_requests (
        status TEXT NOT NULL
      )`;
    await sql`
      INSERT INTO readiness_shadow.dialog_preference_requests
      VALUES ('pending'), ('pending')`;
    await sql`
      CREATE TABLE readiness_shadow.dialog_preference_action_budgets (
        updated_at TIMESTAMPTZ NOT NULL
      )`;
    await sql`
      INSERT INTO readiness_shadow.dialog_preference_action_budgets
      VALUES (now() - interval '48 hours')`;

    await sql.begin(async (tx) => {
      await tx`SET LOCAL search_path = readiness_shadow, pg_catalog`;
      const state = await dialogPreferenceSchemaState(
        tx as unknown as SQL,
        { bypassCache: true },
      );
      expect(state.ready).toBe(true);
      const metrics = await dialogPreferenceBacklogMetrics(tx as unknown as SQL);
      expect(metrics).toContain("toj_dialog_preference_schema_available 1");
      expect(metrics).toContain("toj_dialog_preference_pending_requests 0");
      expect(metrics)
        .toContain('toj_dialog_preference_cleanup_backlog_rows{table="budgets"} 0');
    });
  });
}, 120_000);

test("pre-expand schema fails traffic readiness with both switches off while metrics remain usable", async () => {
  await withDisposableDatabase({ migrated: false }, async ({ sql }) => {
    const previousEntrypoint = process.env.TOJ_DIALOG_PREFERENCES_V1_ENABLED;
    const previousBehavior = process.env.TOJ_DIALOG_PREFERENCES_BEHAVIOR_ENABLED;
    const previousMetricsToken = process.env.TOJ_METRICS_TOKEN;
    process.env.TOJ_DIALOG_PREFERENCES_V1_ENABLED = "0";
    process.env.TOJ_DIALOG_PREFERENCES_BEHAVIOR_ENABLED = "0";
    process.env.TOJ_METRICS_TOKEN = "readiness-metrics-token";
    const server = startCloudServer(0, sql, null, null);
    const base = `http://127.0.0.1:${server.port}`;
    try {
      expect((await fetch(`${base}/health`)).status).toBe(200);
      const readiness = await fetch(`${base}/ready`);
      expect(readiness.status).toBe(503);
      expect(await readiness.json()).toMatchObject({
        status: "not_ready",
        encryption: { ready: false, schema: { ready: false } },
        blindIndexes: { ready: false, schemaReady: false },
        dialogPreferences: {
          ready: false,
          missingTables: expect.arrayContaining([
            "dialog_preferences",
            "dialog_preference_requests",
            "dialog_preference_action_budgets",
            "dialog_preference_legacy_reconciliation",
            "online_migration_cursors",
          ]),
        },
      });
      const metrics = await fetch(`${base}/metrics`, {
        headers: { authorization: "Bearer readiness-metrics-token" },
      });
      expect(metrics.status).toBe(200);
      const metricsBody = await metrics.text();
      expect(metricsBody).toContain("toj_dialog_preference_schema_available 0");
      expect(metricsBody).toContain("toj_envelope_crypto_schema_available 0");
      expect(metricsBody).toContain("toj_blind_index_persisted_references 0");
    } finally {
      await server.stop(true);
      if (previousEntrypoint === undefined) delete process.env.TOJ_DIALOG_PREFERENCES_V1_ENABLED;
      else process.env.TOJ_DIALOG_PREFERENCES_V1_ENABLED = previousEntrypoint;
      if (previousBehavior === undefined) delete process.env.TOJ_DIALOG_PREFERENCES_BEHAVIOR_ENABLED;
      else process.env.TOJ_DIALOG_PREFERENCES_BEHAVIOR_ENABLED = previousBehavior;
      if (previousMetricsToken === undefined) delete process.env.TOJ_METRICS_TOKEN;
      else process.env.TOJ_METRICS_TOKEN = previousMetricsToken;
    }
  });
}, 120_000);
