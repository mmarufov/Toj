import { expect, test } from "bun:test";
import { TelegramOTPDelivery, telegramOTPFromEnvironment } from "./telegram-otp";

const phone = "+12025550101";
const token = "synthetic-token-not-a-credential";
const fixture = (): NodeJS.ProcessEnv => ({ NODE_ENV: "staging", TOJ_OTP_PROVIDER: "telegram",
  TOJ_RETURN_OTP: "0", TOJ_TELEGRAM_GATEWAY_TOKEN: token, TOJ_TELEGRAM_TEST_ALLOWLIST: phone });
const accepted = () => Response.json({ ok: true, result: {
  request_id: "synthetic-request", phone_number: phone, request_cost: 0,
} });

test("storing a token alone does not activate Telegram", () => {
  expect(telegramOTPFromEnvironment({ TOJ_TELEGRAM_GATEWAY_TOKEN: token })).toBeNull();
});

test("Telegram config rejects production, OTP bypass, and invalid secrets/allowlists", () => {
  for (const change of [
    { NODE_ENV: "production" }, { NODE_ENV: "development" }, { TOJ_RETURN_OTP: "1" },
    { TOJ_RETURN_OTP: undefined }, { TOJ_TELEGRAM_GATEWAY_TOKEN: "" },
    { TOJ_TELEGRAM_GATEWAY_TOKEN: "bad\ntoken" }, { TOJ_TELEGRAM_TEST_ALLOWLIST: "" },
    { TOJ_TELEGRAM_TEST_ALLOWLIST: "*" }, { TOJ_TELEGRAM_TEST_ALLOWLIST: `${phone},` },
    { TOJ_TELEGRAM_TEST_ALLOWLIST: Array(6).fill(phone).join(",") },
  ]) expect(() => telegramOTPFromEnvironment({ ...fixture(), ...change })).toThrow();
  const delivery = telegramOTPFromEnvironment(fixture())!;
  expect(delivery.channel).toBe("telegram");
  expect(delivery.dailyRequestLimit).toBe(10);
  expect(delivery.allows(phone)).toBe(true);
  expect(delivery.allows("+12025550102")).toBe(false);
});

test("Telegram uses one fixed HTTPS POST, header auth, supplied OTP, bounded TTL, no redirects/preflight", async () => {
  let calls = 0;
  const delivery = new TelegramOTPDelivery(token, [phone], async (url, init) => {
    calls++;
    expect(url).toBe("https://gatewayapi.telegram.org/sendVerificationMessage");
    expect(init.method).toBe("POST");
    expect(init.redirect).toBe("error");
    expect(new Headers(init.headers).get("authorization")).toBe(`Bearer ${token}`);
    expect(JSON.parse(init.body as string)).toEqual({ phone_number: phone, code: "123456", ttl: 300 });
    expect(init.signal).toBeInstanceOf(AbortSignal);
    return accepted();
  });
  await delivery.send(phone, "123456", "login");
  expect(calls).toBe(1);
});

test("unapproved recipients, bad codes, and deletion codes never reach Telegram", async () => {
  let calls = 0;
  const delivery = new TelegramOTPDelivery(token, [phone], async () => { calls++; return accepted(); });
  await expect(delivery.send("+12025550102", "123456", "login")).rejects.toThrow();
  await expect(delivery.send(phone, "bad", "login")).rejects.toThrow();
  // Deletion stays out: deleteAccount clears the otp_challenges rows the request budget counts,
  // so minting a deletion code would make that budget resettable.
  await expect(delivery.send(phone, "123456", "account_deletion")).rejects.toThrow();
  expect(calls).toBe(0);
});

test("security-change codes are delivered, so two-step enrollment is reachable", async () => {
  let sent = 0;
  const delivery = new TelegramOTPDelivery(token, [phone], async () => { sent++; return accepted(); });
  await delivery.send(phone, "123456", "security_change");
  expect(sent).toBe(1);
});

test("HTTP/API/JSON/timeout failures are sanitized and never retried", async () => {
  for (const result of [
    () => new Response(token, { status: 429 }),
    () => Response.json({ ok: false, error: `${token} ${phone} 123456` }),
    () => new Response("invalid JSON"),
    () => Response.json({ ok: true, result: {} }),
    () => Response.json({ ok: true, result: { request_id: "id", phone_number: "+12025550102", request_cost: 0 } }),
    () => Response.json({ ok: true, result: { request_id: "id", phone_number: phone, request_cost: 0, delivery_status: { status: "expired" } } }),
    () => { throw new Error(`timeout ${token} ${phone} 123456`); },
  ]) {
    let calls = 0;
    const delivery = new TelegramOTPDelivery(token, [phone], async () => { calls++; return result(); });
    await expect(delivery.send(phone, "123456", "login")).rejects.toThrow("Telegram OTP delivery unavailable");
    expect(calls).toBe(1);
  }
});

test("allowlist entries tolerate the separators the login path already strips", () => {
  const spaced = telegramOTPFromEnvironment({ ...fixture(),
    TOJ_TELEGRAM_TEST_ALLOWLIST: " +1 (202) 555-0101 , +1-202-555-0102 " })!;
  expect(spaced.allows(phone)).toBe(true);
  expect(spaced.allows("+12025550102")).toBe(true);
  expect(spaced.allows("+12025550103")).toBe(false);
});

test("an accepted send is not discarded when Telegram echoes the number in another format", async () => {
  for (const echo of [phone, phone.slice(1), " +1 (202) 555-0101 "]) {
    const delivery = new TelegramOTPDelivery(token, [phone], async () => Response.json({
      ok: true, result: { request_id: "id", phone_number: echo, request_cost: 0 },
    }));
    await delivery.send(phone, "123456", "login");
  }
  const wrong = new TelegramOTPDelivery(token, [phone], async () => Response.json({
    ok: true, result: { request_id: "id", phone_number: "+12025550102", request_cost: 0 },
  }));
  await expect(wrong.send(phone, "123456", "login")).rejects.toThrow("Telegram OTP delivery unavailable");
});

test("failures log one actionable tag and never the token, phone, or code", async () => {
  const original = console.error;
  const logged: string[] = [];
  console.error = (...parts: unknown[]) => { logged.push(parts.map(String).join(" ")); };
  try {
    for (const [expected, result] of [
      ["http_401:ACCESS_TOKEN_INVALID", () => Response.json({ ok: false, error: "ACCESS_TOKEN_INVALID" }, { status: 401 })],
      ["http_400:BALANCE_NOT_ENOUGH", () => Response.json({ ok: false, error: "BALANCE_NOT_ENOUGH" }, { status: 400 })],
      // A provider string that is not an uppercase error code is reported without being echoed.
      ["http_200:unrecognized", () => Response.json({ ok: false, error: `${token} ${phone} 123456` })],
      ["http_429:unrecognized", () => new Response(token, { status: 429 })],
      ["malformed_response", () => Response.json({ ok: true, result: {} })],
      ["phone_mismatch", () => Response.json({ ok: true, result: { request_id: "id", phone_number: "+12025550102", request_cost: 0 } })],
      ["delivery_revoked", () => Response.json({ ok: true, result: { request_id: "id", phone_number: phone, request_cost: 0, delivery_status: { status: "revoked" } } })],
      ["timeout", () => { throw Object.assign(new Error(`aborted ${token}`), { name: "TimeoutError" }); }],
      ["network", () => { throw new TypeError(`redirect to ${phone}`); }],
      ["transport_error", () => { throw new Error(`boom ${token} ${phone} 123456`); }],
    ] as [string, () => Response][]) {
      logged.length = 0;
      const delivery = new TelegramOTPDelivery(token, [phone], async () => result());
      await expect(delivery.send(phone, "123456", "login")).rejects.toThrow("Telegram OTP delivery unavailable");
      expect(logged).toHaveLength(1);
      expect(logged[0]).toContain(`auth.otp.telegram_failed ${expected}`);
      for (const secret of [token, phone, phone.slice(1), "123456"]) {
        expect(logged[0]).not.toContain(secret);
      }
    }
  } finally {
    console.error = original;
  }
});

test("an SMS webhook alongside Telegram no longer blocks configuration", () => {
  // The old interlock threw here so only one unproven provider could send. It also made the
  // Telegram+SMS picker unbootable — the very feature it was protecting. Coexistence is now the
  // point; per-channel consent in startVerification is what stops a silent substitution.
  const delivery = telegramOTPFromEnvironment({
    ...fixture(),
    TOJ_SMS_WEBHOOK_URL: "https://example.test/sms",
    TOJ_SMS_WEBHOOK_TOKEN: "synthetic",
  });
  expect(delivery?.channel).toBe("telegram");
});
