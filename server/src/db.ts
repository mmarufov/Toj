import { SQL } from "bun";

// Connection: DATABASE_URL, else local dev DB (no user in URL → libpq uses the OS user).
// We never hardcode a username in the committed repo.
export const DEFAULT_URL = "postgres://localhost:5432/toj_dev";

export function makeSql(url: string = process.env.DATABASE_URL ?? DEFAULT_URL): SQL {
  // Leave room for the six dedicated LISTEN clients in the small staging session pool.
  if (process.env.NODE_ENV === "staging") return new SQL(url, { max: 5 });
  return new SQL(url);
}

// Shared pool for the app. Tests build their own against toj_test.
export const sql = makeSql();
