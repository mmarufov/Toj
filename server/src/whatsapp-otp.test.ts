import { expect, spyOn, test } from "bun:test";
import type { OTPDelivery, OTPDeliveryRegistry } from "./auth";
import { WhatsAppOTPDelivery, whatsappOTPFromEnvironment } from "./whatsapp-otp";

const phone = "+12025550101";
const accessToken = "synthetic-whatsapp-token-not-a-credential";
const code = "012345";
const endpoint = "https://graph.facebook.com/v26.0/100000000000001/messages";
const fixture = () => ({
  accessToken, phoneNumberId: "100000000000001",
  template: "toj_verification", templateLanguage: "ru", phones: [phone],
});
const acceptedBody = () => ({
  messaging_product: "whatsapp",
  contacts: [{ input: phone.slice(1), wa_id: phone.slice(1) }],
  messages: [{ id: "wamid.synthetic", message_status: "accepted" }],
});
const accepted = () => Response.json(acceptedBody());

test("WhatsApp implements the whatsapp registry contract without environment activation", () => {
  const delivery: OTPDelivery = new WhatsAppOTPDelivery(fixture(), async () => accepted());
  const registry: OTPDeliveryRegistry = new Map([[delivery.channel, delivery]]);
  expect(registry.get("whatsapp")).toBe(delivery);
  expect(delivery.dailyRequestLimit).toBe(10);
  expect(delivery.allows?.(phone)).toBe(true);
  expect(delivery.allows?.("+12025550102")).toBe(false);
  // An authentication template's body is fixed by Meta, so this channel declines security alerts
  // rather than approximating one with a verification code.
  expect(delivery.sendSecurityAlert).toBeUndefined();
});

test("WhatsApp validates its configuration without echoing secrets", () => {
  for (const graphVersion of ["", "v26", "26.0", "vv26.0", "v26.0.1", "latest", "v26.0/../v1.0"]) {
    expect(() => new WhatsAppOTPDelivery({ ...fixture(), graphVersion }))
      .toThrow("Invalid WhatsApp Graph API version");
  }
  for (const phoneNumberId of ["", "abc", "1000/messages", "100 001", "1".repeat(33)]) {
    expect(() => new WhatsAppOTPDelivery({ ...fixture(), phoneNumberId }))
      .toThrow("Invalid WhatsApp phone number ID");
  }
  for (const token of ["", "has space", "token\nheader", "token\tvalue", "token\u007f", "tokené"]) {
    expect(() => new WhatsAppOTPDelivery({ ...fixture(), accessToken: token }))
      .toThrow("Invalid WhatsApp access token");
  }
  for (const template of ["", "Toj_Verification", "toj verification", "toj-verification", "тоҷ"]) {
    expect(() => new WhatsAppOTPDelivery({ ...fixture(), template }))
      .toThrow("Invalid WhatsApp template name");
  }
  for (const templateLanguage of ["", "russian", "RU", "ru-RU", "ru_ru"]) {
    expect(() => new WhatsAppOTPDelivery({ ...fixture(), templateLanguage }))
      .toThrow("Invalid WhatsApp template language");
  }
  for (const phones of [[], ["*"], [""], [phone.slice(1)], [phone + " "], Array(6).fill(phone)]) {
    expect(() => new WhatsAppOTPDelivery({ ...fixture(), phones }))
      .toThrow("exact international test numbers");
  }
});

test("WhatsApp copies the recipient allowlist rather than trusting a mutable caller array", () => {
  const options = fixture();
  const delivery = new WhatsAppOTPDelivery(options);
  options.phones.push("+12025550102");
  expect(delivery.allows("+12025550102")).toBe(false);
});

test("WhatsApp posts the documented authentication payload to the pinned Cloud API host", async () => {
  let calls = 0;
  const delivery = new WhatsAppOTPDelivery(fixture(), async (url, init) => {
    calls++;
    // The host is pinned, not configured: there is no environment value that can redirect the
    // access token and the code to another server.
    expect(url).toBe(endpoint);
    expect(init.method).toBe("POST");
    expect(init.redirect).toBe("error");
    expect((init.headers as Record<string, string>).authorization).toBe(`Bearer ${accessToken}`);
    const body = JSON.parse(init.body as string);
    expect(body).toMatchObject({
      messaging_product: "whatsapp", recipient_type: "individual",
      to: phone.slice(1), type: "template",
      template: { name: "toj_verification", language: { code: "ru" } },
    });
    // The code appears twice by design — fixed body, then the copy-code button value — and the
    // button component is Meta's sub_type "url" with a string index.
    expect(body.template.components).toEqual([
      { type: "body", parameters: [{ type: "text", text: code }] },
      { type: "button", sub_type: "url", index: "0", parameters: [{ type: "text", text: code }] },
    ]);
    return accepted();
  });
  await delivery.send(phone, code, "login");
  await delivery.send(phone, code, "security_change");
  expect(calls).toBe(2);
});

test("WhatsApp honours an explicit Graph version without letting it escape the path", async () => {
  const delivery = new WhatsAppOTPDelivery({ ...fixture(), graphVersion: "v27.0" }, async (url) => {
    expect(url).toBe("https://graph.facebook.com/v27.0/100000000000001/messages");
    return accepted();
  });
  await delivery.send(phone, code, "login");
});

test("WhatsApp bounds its single transport attempt with a cancellation signal", async () => {
  let calls = 0;
  const delivery = new WhatsAppOTPDelivery(fixture(), async (_url, init) => {
    calls++;
    expect(init.signal).toBeInstanceOf(AbortSignal);
    expect(init.signal!.aborted).toBe(false);
    return accepted();
  });
  await delivery.send(phone, code, "login");
  expect(calls).toBe(1);
});

test("WhatsApp rejects out-of-scope requests before contacting the provider", async () => {
  let calls = 0;
  const delivery = new WhatsAppOTPDelivery(fixture(), async () => { calls++; return accepted(); });
  // account_deletion stays closed: deleteAccount hard-deletes the otp_challenges rows the daily
  // budget counts, which would make that budget resettable.
  await expect(delivery.send(phone, code, "account_deletion")).rejects.toThrow("request rejected");
  await expect(delivery.send("+12025550102", code, "login")).rejects.toThrow("request rejected");
  await expect(delivery.send(phone.slice(1), code, "login")).rejects.toThrow("request rejected");
  for (const bad of ["", "12345", "1234567", "01234a", " 01234"]) {
    await expect(delivery.send(phone, bad, "login")).rejects.toThrow("request rejected");
  }
  expect(calls).toBe(0);
});

test("WhatsApp emits only mapped error constants and never echoes provider strings", async () => {
  const logging = spyOn(console, "error").mockImplementation(() => {});
  try {
    for (const [status, apiCode, diagnostic] of [
      [401, 190, "ACCESS_TOKEN_INVALID"],
      [403, 368, "ACCOUNT_RESTRICTED"],
      [429, 130429, "RATE_LIMIT"],
      [400, 131026, "MESSAGE_UNDELIVERABLE"],
      [400, 131042, "BUSINESS_ELIGIBILITY_PAYMENT"],
      [400, 131047, "REENGAGEMENT_WINDOW"],
      [404, 132001, "TEMPLATE_NOT_FOUND"],
      [400, 133010, "PHONE_NUMBER_NOT_REGISTERED"],
      // Unmapped integers degrade rather than reaching the log: the map is an allowlist, so an
      // incomplete list costs diagnostic detail and never leaks. A six-digit OTP is an integer too.
      [400, 999999, "unrecognized"],
      [400, Number(code), "unrecognized"],
    ] as const) {
      logging.mockClear();
      let calls = 0;
      const delivery = new WhatsAppOTPDelivery(fixture(), async () => {
        calls++;
        return Response.json({
          error: {
            code: apiCode,
            message: `${accessToken} ${phone} ${code}`,
            error_data: { details: `${accessToken} ${phone} ${code}` },
          },
        }, { status });
      });
      await expect(delivery.send(phone, code, "login"))
        .rejects.toThrow("WhatsApp OTP delivery unavailable");
      expect(calls).toBe(1);
      expect(logging).toHaveBeenCalledTimes(1);
      expect(logging).toHaveBeenCalledWith(expect.any(String), "auth.otp.whatsapp_failed",
        `http_${status}:${diagnostic}`);
      const logged = logging.mock.calls.flat().join(" ");
      for (const secret of [accessToken, phone, code]) expect(logged).not.toContain(secret);
    }
  } finally {
    logging.mockRestore();
  }
});

test("WhatsApp fails closed on malformed acknowledgements and a mismatched echo", async () => {
  const logging = spyOn(console, "error").mockImplementation(() => {});
  try {
    for (const [body, diagnostic] of [
      [{}, "malformed_response"],
      [{ ...acceptedBody(), messaging_product: "sms" }, "malformed_response"],
      [{ ...acceptedBody(), contacts: [] }, "malformed_response"],
      [{ ...acceptedBody(), contacts: [{ wa_id: phone.slice(1) }] }, "malformed_response"],
      [{ ...acceptedBody(), messages: [] }, "malformed_response"],
      [{ ...acceptedBody(), messages: [{ id: "  " }] }, "malformed_response"],
      [{ ...acceptedBody(), messages: [{ id: "a" }, { id: "b" }] }, "malformed_response"],
      [{ ...acceptedBody(), contacts: [{ input: "12025550102", wa_id: "12025550102" }] },
        "phone_mismatch"],
      // A held message may never arrive inside the OTP TTL, so it fails closed and the user re-picks.
      [{ ...acceptedBody(), messages: [{ id: "wamid.x", message_status: "held_for_quality_assessment" }] },
        "provider_status_held"],
      [{ ...acceptedBody(), messages: [{ id: "wamid.x", message_status: "something_new" }] },
        "provider_status_unrecognized"],
    ] as const) {
      logging.mockClear();
      const delivery = new WhatsAppOTPDelivery(fixture(), async () => Response.json(body));
      await expect(delivery.send(phone, code, "login"))
        .rejects.toThrow("WhatsApp OTP delivery unavailable");
      expect(logging).toHaveBeenCalledWith(expect.any(String), "auth.otp.whatsapp_failed", diagnostic);
    }
  } finally {
    logging.mockRestore();
  }
});

test("WhatsApp keeps an accepted send when Meta normalizes wa_id or omits the status", async () => {
  // wa_id is normalized per country (the Argentine 9, the Mexican 1). Comparing it would discard an
  // accepted — and already billable — send over a transformation we do not control.
  for (const body of [
    { ...acceptedBody(), contacts: [{ input: phone.slice(1), wa_id: "9" + phone.slice(1) }] },
    { ...acceptedBody(), contacts: [{ input: phone, wa_id: phone.slice(1) }] },
    { ...acceptedBody(), messages: [{ id: "wamid.synthetic" }] },
  ]) {
    const delivery = new WhatsAppOTPDelivery(fixture(), async () => Response.json(body));
    await expect(delivery.send(phone, code, "login")).resolves.toBeUndefined();
  }
});

test("WhatsApp classifies transport failures without quoting the thrown message", async () => {
  const logging = spyOn(console, "error").mockImplementation(() => {});
  try {
    for (const [name, diagnostic] of [
      ["TimeoutError", "timeout"], ["AbortError", "timeout"],
      ["TypeError", "network"], ["SyntaxError", "transport_error"],
    ] as const) {
      logging.mockClear();
      const delivery = new WhatsAppOTPDelivery(fixture(), async () => {
        const error = new Error(`${accessToken} ${phone} ${code}`);
        error.name = name;
        throw error;
      });
      await expect(delivery.send(phone, code, "login"))
        .rejects.toThrow("WhatsApp OTP delivery unavailable");
      expect(logging).toHaveBeenCalledWith(expect.any(String), "auth.otp.whatsapp_failed", diagnostic);
    }
  } finally {
    logging.mockRestore();
  }
});

test("credentials alone do not activate WhatsApp, and staging/OTP-return gates hold", () => {
  const full = (): NodeJS.ProcessEnv => ({
    TOJ_WHATSAPP_ENABLED: "1", NODE_ENV: "staging", TOJ_RETURN_OTP: "0",
    TOJ_WHATSAPP_ACCESS_TOKEN: "synthetic-token-not-a-credential",
    TOJ_WHATSAPP_PHONE_NUMBER_ID: "100000000000001",
    TOJ_WHATSAPP_TEMPLATE: "toj_verification",
    TOJ_WHATSAPP_TEMPLATE_LANGUAGE: "ru",
    TOJ_WHATSAPP_TEST_ALLOWLIST: "+12025550101",
  });
  // A token sitting in the environment must never start sending on its own.
  const { TOJ_WHATSAPP_ENABLED: _drop, ...credentialsOnly } = full();
  expect(whatsappOTPFromEnvironment(credentialsOnly)).toBeNull();

  for (const change of [
    { NODE_ENV: "production" }, { NODE_ENV: "development" }, { NODE_ENV: undefined },
    { TOJ_RETURN_OTP: "1" }, { TOJ_RETURN_OTP: undefined },
    { TOJ_WHATSAPP_ACCESS_TOKEN: "" }, { TOJ_WHATSAPP_PHONE_NUMBER_ID: "" },
    { TOJ_WHATSAPP_TEMPLATE: "" }, { TOJ_WHATSAPP_TEMPLATE_LANGUAGE: "" },
    { TOJ_WHATSAPP_GRAPH_VERSION: "latest" },
    { TOJ_WHATSAPP_TEST_ALLOWLIST: "" }, { TOJ_WHATSAPP_TEST_ALLOWLIST: "*" },
  ]) expect(() => whatsappOTPFromEnvironment({ ...full(), ...change })).toThrow();

  const delivery = whatsappOTPFromEnvironment(full())!;
  expect(delivery.channel).toBe("whatsapp");
  expect(delivery.allows("+12025550101")).toBe(true);
  expect(delivery.allows("+12025550102")).toBe(false);

  // Pasted separators configure the pilot rather than crash-looping the deployment.
  const spaced = whatsappOTPFromEnvironment({
    ...full(), TOJ_WHATSAPP_TEST_ALLOWLIST: " +1 (202) 555-0101 ",
  })!;
  expect(spaced.allows("+12025550101")).toBe(true);
});
