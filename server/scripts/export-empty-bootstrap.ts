import { SQL } from "bun";

// Run the canonical migration on a fresh, isolated local database first. Export its actual
// resulting catalog and migration metadata, never reconstruct the TypeScript phases by hand.
const url = process.env.TOJ_BOOTSTRAP_SOURCE_URL;
if (!url) throw new Error("TOJ_BOOTSTRAP_SOURCE_URL is required");
const parsed = new URL(url);
if (!["127.0.0.1", "localhost", "[::1]"].includes(parsed.hostname)
  || !parsed.pathname.endsWith("_bootstrap")) {
  throw new Error("bootstrap export requires a local database ending in _bootstrap");
}
const metadata = [
  "schema_migrations", "schema_migration_progress", "online_migration_cursors", "crypto_write_state",
];
const db = new SQL(url);
try {
  const tables = await db`SELECT tablename FROM pg_tables WHERE schemaname = 'public'`;
  if (tables.length === 0) throw new Error("run the canonical migration first");
  for (const { tablename } of tables) {
    if (metadata.includes(tablename)) continue;
    const name = String(tablename).replaceAll('"', '""');
    const rows = await db.unsafe(`SELECT 1 FROM public."${name}" LIMIT 1`);
    if (rows.length) throw new Error(`refusing to export nonempty application table ${tablename}`);
  }
  const incomplete = await db`SELECT 1 FROM schema_migration_progress WHERE completed_at IS NULL
    UNION ALL SELECT 1 FROM online_migration_cursors WHERE completed_at IS NULL`;
  if (incomplete.length) throw new Error("migration cursors are incomplete");
  const invalid = await db`SELECT 1 FROM pg_constraint WHERE connamespace = 'public'::regnamespace
    AND NOT convalidated UNION ALL SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid
    WHERE c.relnamespace='public'::regnamespace AND (NOT i.indisvalid OR NOT i.indisready)`;
  if (invalid.length) throw new Error("catalog contains unfinished constraints or indexes");
  const crypto = await db`SELECT write_mode, epoch FROM crypto_write_state`;
  if (crypto.length !== 1 || crypto[0].write_mode !== "legacy" || Number(crypto[0].epoch) !== 1) {
    throw new Error("source is not a fresh crypto bootstrap");
  }
} finally {
  await db.end();
}

async function dump(args: string[]): Promise<string> {
  const child = Bun.spawn(["pg_dump", "--dbname", url!, "--no-owner", "--no-acl", ...args], {
    stdout: "pipe", stderr: "pipe",
  });
  const [output, , status] = await Promise.all([
    new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
  ]);
  if (status !== 0) throw new Error("pg_dump failed; no bootstrap emitted");
  return output.split("\n").filter((line) =>
    !line.startsWith("\\")
    && !line.startsWith("CREATE SCHEMA public;")
    && !line.startsWith("COMMENT ON SCHEMA public ")
  ).join("\n");
}
const schema = await dump(["--schema-only", "--schema=public"]);
const data = await dump(["--data-only", "--inserts", ...metadata.map((name) => `--table=public.${name}`)]);
const hardening = `
-- Bun owns authorization. Supabase browser/API roles receive no access, even if Data API is
-- enabled later. RLS is defense in depth; the database owner still serves the staging backend.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon, authenticated, service_role, PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated, service_role, PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM anon, authenticated, service_role, PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated, service_role, PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated, service_role, PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon, authenticated, service_role, PUBLIC;
DO $hardening$
DECLARE item record;
BEGIN
  FOR item IN SELECT tablename FROM pg_tables WHERE schemaname='public' LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', item.tablename);
  END LOOP;
  FOR item IN SELECT p.oid::regprocedure AS signature FROM pg_proc p
    WHERE p.pronamespace='public'::regnamespace AND p.prokind='f' AND p.proconfig IS NULL
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = pg_catalog, public, pg_temp', item.signature);
  END LOOP;
END;
$hardening$;
`;
process.stdout.write(`-- Generated from the complete canonical Toj migration on an empty database.
-- EMPTY PUBLIC SCHEMA ONLY. Apply atomically with the Supabase migration tool.
DO $guard$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_class WHERE relnamespace='public'::regnamespace
    AND relkind IN ('r','p','v','m','S','f'))
    OR EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace) THEN
    RAISE EXCEPTION 'refusing to bootstrap a nonempty public schema';
  END IF;
END; $guard$;
${schema}
${data}
${hardening}
`);
