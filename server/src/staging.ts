import { configureStagingEnvironment } from "./staging-config";

// Validate before importing modules that construct database pools or read provider settings.
configureStagingEnvironment();
const { startCloudServer } = await import("./cloud");
const { sql } = await import("./db");
const server = startCloudServer();
let stopping = false;
async function shutdown(): Promise<void> {
  if (stopping) return;
  stopping = true;
  const deadline = setTimeout(() => process.exit(1), 25_000);
  deadline.unref();
  try {
    await server.stop(true);
    await sql.end();
    clearTimeout(deadline);
    process.exit(0);
  } catch {
    console.error(JSON.stringify({ event: "staging.shutdown_failed" }));
    process.exit(1);
  }
}
process.on("SIGTERM", () => void shutdown());
process.on("SIGINT", () => void shutdown());
