import { expect, test } from "bun:test";
import { X509Certificate } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const serverRoot = resolve(import.meta.dir, "..");
const fingerprint = "80:70:25:AD:50:D4:ED:21:9D:2C:9C:7D:29:9C:00:4F:82:4E:B0:0C:F7:F6:5A:FE:F6:07:D0:7B:72:E6:CA:FA";

test("staging bundles the authenticated Supabase root CA, not a private key or leaf", () => {
  const pem = readFileSync(resolve(serverRoot, "certs/supabase-root-2021.crt"), "utf8");
  const cert = new X509Certificate(pem);
  expect(cert.fingerprint256).toBe(fingerprint);
  expect(cert.ca).toBe(true);
  expect(cert.verify(cert.publicKey)).toBe(true);
  expect(Date.parse(cert.validTo)).toBeGreaterThan(Date.now() + 30 * 86400_000);
  expect(pem).not.toContain("PRIVATE KEY");
});

test("staging loads the CA at process startup without replacing public roots", async () => {
  const pkg = JSON.parse(readFileSync(resolve(serverRoot, "package.json"), "utf8"));
  const prefix = "NODE_EXTRA_CA_CERTS=./certs/supabase-root-2021.crt ";
  expect(pkg.scripts.staging.startsWith(prefix)).toBe(true);
  expect(pkg.scripts.staging.slice(prefix.length)).toBe("bun run src/staging.ts");
  const child = Bun.spawn([process.execPath, "-e", `
    import { getCACertificates } from "node:tls";
    import { X509Certificate } from "node:crypto";
    const extra = getCACertificates("extra").map(pem => new X509Certificate(pem).fingerprint256);
    console.log(JSON.stringify({ extra, defaultCount: getCACertificates("default").length }));
  `], {
    cwd: serverRoot,
    env: { ...process.env, NODE_EXTRA_CA_CERTS: "./certs/supabase-root-2021.crt" },
    stdout: "pipe", stderr: "pipe",
  });
  const [output, errors, status] = await Promise.all([
    new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
  ]);
  expect(status).toBe(0);
  expect(errors).toBe("");
  const trust = JSON.parse(output);
  expect(trust.extra).toEqual([fingerprint]);
  expect(trust.defaultCount).toBeGreaterThan(1);
});
