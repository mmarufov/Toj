# Toj website writing and design rules

These rules govern the public website and its supporting content. Read them before changing copy.

## Voice

- The hero is warm, human, and brief. Keep the tagline exactly: "A little closer. Even on a weak signal."
- Product explanations describe what a person can do and what happens when the connection fails.
- Engineering explanations use concrete mechanisms and link to their implementation or recorded evidence.
- Security and availability statements are plain and explicit. Do not soften limitations into slogans.
- Use short sentences, varied rhythms, active verbs, and straight apostrophes. No em dashes.
- Avoid repeated contrast templates. The only permitted "X. Not Y." line is "Retry the send. Not the message."
- Avoid superlatives, generic innovation language, competitor comparisons, and guarantees of delivery or speed.

## Product truth

- Toj is an iPhone-first cloud messenger in development, intended for unreliable connections anywhere.
- Keep availability visible. There is no public download, public signup, or waitlist in this version.
- Default chats are encrypted in transit and at rest. The server holds the keys, so Toj operators can decrypt their contents. Default chats are not end-to-end encrypted.
- Secret Chats are planned. Calls have implementation code but remain disabled pending infrastructure and release gates.
- Distinguish an illustrative browser sequence from an app screenshot, live backend test, or measured result.
- State test date, revision, method, and limitations beside numerical claims. Local fault-injection results do not establish physical-device or production performance.
- Do not imply support for a desktop app, every language, or platforms that have not shipped.
- Use geography only when necessary to explain a verified language feature. The main product story is global.
- Never publish private operational context, real conversations, identifiers, or secrets.

## Design and implementation

- Preserve the crown mark. Use graphite, ivory, restrained gold, and a lighter engineering chapter.
- Give the hero one finite delivery sequence with stillness around it. Keep ordinary page scrolling.
- No phone-shell hero, stock illustration, icon grids, parallax, scroll-jacking, video background, or repeated entrance animations.
- The sender's locally saved message remains visible during interruption. Server acceptance and recipient delivery are separate states.
- Essential content must work without JavaScript or web fonts. Respect reduced motion, Save-Data, visibility, and keyboard navigation.
- Use native semantic controls and never communicate state through color alone.
- All runtime assets are self-hosted. No backend calls, tracking, or third-party embeds.
- Validate Tajik glyph coverage explicitly. Font branding must not cause missing or substituted letters.
- Website changes do not change application APIs, databases, backend infrastructure, CNAME, or the Pages source.
