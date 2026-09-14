import { expect, spyOn, test } from "bun:test";
import type { OTPDelivery, OTPDeliveryRegistry } from "./auth";
import { InfobipOTPDelivery, infobipOTPFromEnvironment } from "./infobip-otp";

const phone = "+12025550101";
const apiKey = "synthetic-infobip-key-not-a-credential";
const code = "012345";
const fixture = () => ({ baseUrl: "https://synthetic.api.infobip.com", apiKey,
  sender: "ServiceSMS", phones: [phone] });
const acceptedBody = () => ({ messages: [{ messageId: "synthetic-message-id",
  destination: phone.slice(1), status: { groupId: 1, groupName: "PENDING", id: 26, name: "PENDING_ACCEPTED" } }] });
const accepted = () => Response.json(acceptedBody());

test("Infobip implements the SMS registry contract without environment activation", () => {
  const delivery: OTPDelivery = new InfobipOTPDelivery(fixture(), async () => accepted());
  const registry: OTPDeliveryRegistry = new Map([[delivery.channel, delivery]]);
  expect(registry.get("sms")).toBe(delivery);
  expect(delivery.dailyRequestLimit).toBe(10);
  expect(delivery.allows?.(phone)).toBe(true);
  expect(delivery.allows?.("+12025550102")).toBe(false);
});

test("Infobip validates credential destination and trial configuration without echoing secrets", () => {
  for (const baseUrl of ["bad", "http://synthetic.api.infobip.com", "https://evil.test",
    "https://api.infobip.com.evil.test", "https://evil.test/api.infobip.com",
    "https://api.infobip.com:444", "https://api.infobip.com/path",
    `https://${apiKey}@api.infobip.com`, `https://api.infobip.com/?key=${apiKey}`,
    "https://api.infobip.com/#fragment"]) {
    expect(() => new InfobipOTPDelivery({ ...fixture(), baseUrl })).toThrow("Invalid Infobip base URL");
  }
  for (const badKey of ["", "has space", "key\nheader", "key\tvalue", "key\u007f", "keyé"]) {
    expect(() => new InfobipOTPDelivery({ ...fixture(), apiKey: badKey })).toThrow("Invalid Infobip API key");
  }
  for (const sender of ["", "ab", "12345", "waytoolongsender", "Toj\n", "Toj!", "Тоҷ"]) {
    expect(() => new InfobipOTPDelivery({ ...fixture(), sender })).toThrow("Invalid Infobip sender");
  }
  for (const phones of [[], ["*"], [""], [phone.slice(1)], [phone + " "], Array(6).fill(phone)]) {
    expect(() => new InfobipOTPDelivery({ ...fixture(), phones })).toThrow("exact international test numbers");
  }
});

test("Infobip copies the recipient allowlist rather than trusting a mutable caller array", () => {
  const options = fixture();
  const delivery = new InfobipOTPDelivery(options);
  options.phones.push("+12025550102");
  expect(delivery.allows("+12025550102")).toBe(false);
});

test("Infobip accepts the global or account base URL and uses the explicitly supplied sender", async () => {
  for (const baseUrl of ["https://api.infobip.com", "https://synthetic.api.infobip.com/"]) {
    const delivery = new InfobipOTPDelivery({ ...fixture(), baseUrl, sender: "Toj" }, async (url, init) => {
      expect(url).toBe(new URL("/sms/3/messages", baseUrl).href);
      expect(JSON.parse(init.body as string).messages[0].sender).toBe("Toj");
      return accepted();
    });
    await delivery.send(phone, code, "login");
  }
});

test("Infobip passes a ten-second cancellation signal through to its single transport attempt", async () => {
  const controller = new AbortController();
  const timeout = spyOn(AbortSignal, "timeout").mockReturnValue(controller.signal);
  const logging = spyOn(console, "error").mockImplementation(() => {});
  let calls = 0;
  try {
    const delivery = new InfobipOTPDelivery(fixture(), async (_url, init) => {
      calls++;
      expect(init.signal).toBe(controller.signal);
      return new Promise<Response>((_resolve, reject) => {
        init.signal!.addEventListener("abort", () => reject(init.signal!.reason), { once: true });
        controller.abort(new DOMException("synthetic timeout", "TimeoutError"));
      });
    });
    await expect(delivery.send(phone, code, "login")).rejects.toThrow("Infobip OTP delivery unavailable");
    expect(timeout).toHaveBeenCalledTimes(1);
    expect(timeout).toHaveBeenCalledWith(10_000);
    expect(calls).toBe(1);
    expect(logging).toHaveBeenCalledWith(expect.any(String), "auth.otp.infobip_failed", "timeout");
  } finally {
    timeout.mockRestore();
    logging.mockRestore();
  }
});

test("Infobip makes exactly one bounded HTTPS v3 POST with App authentication and the supplied code", async () => {
  let calls = 0;
  const delivery = new InfobipOTPDelivery(fixture(), async (url, init) => {
    calls++;
    expect(url).toBe("https://synthetic.api.infobip.com/sms/3/messages");
    expect(init.method).toBe("POST");
    expect(init.redirect).toBe("error");
    expect(init.signal).toBeInstanceOf(AbortSignal);
    expect(init.signal?.aborted).toBe(false);
    expect(new Headers(init.headers).get("authorization")).toBe(`App ${apiKey}`);
    expect(new Headers(init.headers).get("content-type")).toBe("application/json");
    expect(JSON.parse(init.body as string)).toEqual({ messages: [{ sender: "ServiceSMS",
      destinations: [{ to: phone.slice(1) }],
      content: { text: `Your Toj sign-in code is ${code}. Do not share this code.` } }] });
    return accepted();
  });
  await delivery.send(phone, code, "login");
  expect(calls).toBe(1);
});

test("Infobip permits security-change codes but rejects deletion and invalid inputs before dispatch", async () => {
  const sent: string[] = [];
  const delivery = new InfobipOTPDelivery(fixture(), async (_url, init) => {
    sent.push(JSON.parse(init.body as string).messages[0].content.text);
    return accepted();
  });
  for (const recipient of ["+12025550102", phone.slice(1), "", "*"]) {
    await expect(delivery.send(recipient, code, "login")).rejects.toThrow("Infobip OTP request rejected");
  }
  for (const invalid of ["", "12345", "1234567", "abcdef", "123456\n"]) {
    await expect(delivery.send(phone, invalid, "login")).rejects.toThrow();
  }
  // Row absence after deleteAccount would reset the budget based on otp_challenges. Keep this
  // pilot incapable of issuing deletion codes, matching the existing Telegram pilot boundary.
  await expect(delivery.send(phone, code, "account_deletion")).rejects.toThrow();
  await expect(delivery.send(phone, code, "bogus" as "login")).rejects.toThrow();
  expect(sent).toHaveLength(0);
  await delivery.send(phone, code, "security_change");
  expect(sent).toEqual([`Your Toj security change code is ${code}. Do not share this code.`]);
});

test("Infobip accepts documented pending/delivered statuses and optional leading plus in destination", async () => {
  for (const [groupId, groupName, ids] of [[1, "PENDING", [3, 7, 26]], [3, "DELIVERED", [2, 5]]] as const) {
    for (const id of ids) {
      for (const destination of [phone, phone.slice(1)]) {
        const delivery = new InfobipOTPDelivery(fixture(), async () => Response.json({ messages: [{
          messageId: "synthetic-id", destination, status: { groupId, groupName, id },
        }] }));
        await delivery.send(phone, code, "login");
      }
    }
  }
});

test("Infobip rejects malformed, mismatched and failed responses without leaking data or retrying", async () => {
  const secret = `${apiKey} ${phone} ${code}`;
  const failures: [string, () => Response][] = [
    ...[302, 400, 401, 403, 429, 500].map((status): [string, () => Response] =>
      [`http_${status}`, () => new Response(secret, { status })]),
    ...[null, {}, { messages: [] }, { messages: [null] },
      { messages: [...acceptedBody().messages, ...acceptedBody().messages] },
      { messages: [{ ...acceptedBody().messages[0], messageId: " " }] },
      { messages: [{ ...acceptedBody().messages[0], destination: null }] },
      { messages: [{ ...acceptedBody().messages[0], status: { groupId: "1", id: 26 } }] },
    ].map((body): [string, () => Response] => ["malformed_response", () => Response.json(body)]),
    ["malformed_response", () => new Response(secret)],
    ["phone_mismatch", () => Response.json({ messages: [{ ...acceptedBody().messages[0], destination: "12025550102" }] })],
    ...[2, 4, 5, 999].map((groupId): [string, () => Response] => ["provider_status_rejected", () =>
      Response.json({ messages: [{ ...acceptedBody().messages[0], status: { groupId, id: 12, name: secret } }] })]),
    ["provider_status_rejected", () => Response.json({ messages: [{ ...acceptedBody().messages[0],
      status: { groupId: 1, groupName: "PENDING", id: 12, description: secret } }] })],
    ["provider_status_rejected", () => Response.json({ messages: [{ ...acceptedBody().messages[0],
      status: { groupId: 1, groupName: secret, id: 26 } }] })],
    ["timeout", () => { throw Object.assign(new Error(secret), { name: "TimeoutError" }); }],
    ["timeout", () => { throw Object.assign(new Error(secret), { name: "AbortError" }); }],
    ["network", () => { throw new TypeError(secret); }],
    ["transport_error", () => { throw new Error(secret); }],
  ];
  const original = console.error;
  const logged: string[] = [];
  console.error = (...args: unknown[]) => { logged.push(args.map(String).join(" ")); };
  try {
    for (const [reason, result] of failures) {
      logged.length = 0;
      let calls = 0;
      const delivery = new InfobipOTPDelivery(fixture(), async () => { calls++; return result(); });
      await expect(delivery.send(phone, code, "login")).rejects.toThrow("Infobip OTP delivery unavailable");
      expect(calls).toBe(1);
      expect(logged).toHaveLength(1);
      expect(logged[0]).toContain(`auth.otp.infobip_failed ${reason}`);
      for (const value of [apiKey, phone, phone.slice(1), code]) expect(logged[0]).not.toContain(value);
    }
  } finally {
    console.error = original;
  }
});

test("credentials alone do not activate Infobip, and staging/OTP-return gates hold", () => {
  const full = (): NodeJS.ProcessEnv => ({
    TOJ_INFOBIP_ENABLED: "1", NODE_ENV: "staging", TOJ_RETURN_OTP: "0",
    TOJ_INFOBIP_BASE_URL: "https://55n4vx.api.infobip.com",
    TOJ_INFOBIP_API_KEY: "synthetic-key-not-a-credential",
    TOJ_INFOBIP_SENDER: "ServiceSMS",
    TOJ_INFOBIP_TEST_ALLOWLIST: "+12025550101",
  });
  // A key sitting in the environment must never start sending on its own.
  const { TOJ_INFOBIP_ENABLED: _drop, ...credentialsOnly } = full();
  expect(infobipOTPFromEnvironment(credentialsOnly)).toBeNull();

  for (const change of [
    { NODE_ENV: "production" }, { NODE_ENV: "development" },
    { TOJ_RETURN_OTP: "1" }, { TOJ_RETURN_OTP: undefined },
    { TOJ_INFOBIP_BASE_URL: "http://55n4vx.api.infobip.com" },
    { TOJ_INFOBIP_BASE_URL: "https://evil.test" },
    { TOJ_INFOBIP_API_KEY: "" }, { TOJ_INFOBIP_SENDER: "" },
    { TOJ_INFOBIP_TEST_ALLOWLIST: "" }, { TOJ_INFOBIP_TEST_ALLOWLIST: "*" },
  ]) expect(() => infobipOTPFromEnvironment({ ...full(), ...change })).toThrow();

  const delivery = infobipOTPFromEnvironment(full())!;
  expect(delivery.channel).toBe("sms");
  expect(delivery.allows("+12025550101")).toBe(true);
  expect(delivery.allows("+12025550102")).toBe(false);

  // Pasted separators configure the pilot rather than crash-looping the deployment.
  const spaced = infobipOTPFromEnvironment({
    ...full(), TOJ_INFOBIP_TEST_ALLOWLIST: " +1 (202) 555-0101 ",
  })!;
  expect(spaced.allows("+12025550101")).toBe(true);
});
