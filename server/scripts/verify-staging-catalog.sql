-- Read-only fingerprints: compare the locally replayed empty bootstrap with remote staging.
SELECT json_build_object(
  'columns', (SELECT md5(string_agg(concat_ws('|', c.relname, a.attname,
    format_type(a.atttypid,a.atttypmod), a.attnotnull,
    pg_get_expr(d.adbin,d.adrelid)), E'\n' ORDER BY c.relname,a.attnum))
    FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid
    LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
    WHERE c.relnamespace='public'::regnamespace AND c.relkind IN ('r','p')
      AND a.attnum>0 AND NOT a.attisdropped),
  'constraints', (SELECT md5(string_agg(concat_ws('|', c.relname, co.conname,
    co.convalidated, pg_get_constraintdef(co.oid)), E'\n' ORDER BY c.relname,co.conname))
    FROM pg_constraint co JOIN pg_class c ON c.oid=co.conrelid
    WHERE co.connamespace='public'::regnamespace),
  'indexes', (SELECT md5(string_agg(indexdef, E'\n' ORDER BY tablename,indexname))
    FROM pg_indexes WHERE schemaname='public'),
  'triggers', (SELECT md5(string_agg(concat_ws('|', c.relname, t.tgname,
    t.tgenabled, pg_get_triggerdef(t.oid)), E'\n' ORDER BY c.relname,t.tgname))
    FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
    WHERE c.relnamespace='public'::regnamespace AND NOT t.tgisinternal),
  'functions', (SELECT md5(string_agg(pg_get_functiondef(p.oid), E'\n' ORDER BY p.proname,p.oid::regprocedure::text))
    FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.prokind='f'),
  'markers', (SELECT md5(string_agg(name, E'\n' ORDER BY name)) FROM schema_migrations),
  'completed_progress', (SELECT count(*) FROM schema_migration_progress WHERE completed_at IS NOT NULL),
  'completed_cursors', (SELECT count(*) FROM online_migration_cursors WHERE completed_at IS NOT NULL)
) AS catalog;
