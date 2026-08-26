import { makeSql } from "./db";
import { EnvelopeCrypto, LocalDevelopmentKeyProvider, type KeyScope } from "./envelope-crypto";

type Fixture = {
  databaseURL: string;
  accountId: string;
  keyId: string;
  nonce: string;
  ciphertext: string;
  aad: string;
};

const fixture = JSON.parse(process.argv[2] ?? "") as Fixture;
const sql = makeSql(fixture.databaseURL);
const scope: KeyScope = { kind: "account", accountId: fixture.accountId };
const sealed = {
  keyId: fixture.keyId,
  nonce: Buffer.from(fixture.nonce, "base64"),
  ciphertext: Buffer.from(fixture.ciphertext, "base64"),
};
const aad = Buffer.from(fixture.aad, "base64");
const crypto = new EnvelopeCrypto(sql, {
  mode: "envelope",
  activeProvider: new LocalDevelopmentKeyProvider(),
  cacheTTL: 5,
});

try {
  const first = await crypto.open(scope, sealed, aad);
  first.fill(0);
  process.stdout.write("cached\n");
  await Bun.stdin.text();
  try {
    const reopened = await crypto.open(scope, sealed, aad);
    reopened.fill(0);
    process.stdout.write("unexpected-open\n");
    process.exitCode = 2;
  } catch (error) {
    process.stdout.write(String(error).includes(`unknown key_id ${fixture.keyId}`)
      ? "revoked\n"
      : `unexpected-error:${String(error)}\n`);
    if (!String(error).includes(`unknown key_id ${fixture.keyId}`)) process.exitCode = 3;
  }
} finally {
  await sql.close();
}
