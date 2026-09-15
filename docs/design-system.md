# Design System — Toj

## Product

Toj is a private, Tajik-first messenger for iPhone and iPad. It should feel fast,
quiet, premium, and immediately familiar to people who already use modern chat apps.

## Visual Direction

- Black-only interface with matte conversation content and floating Liquid Glass controls —
  premium, minimal, and sleek in the spirit of X and Grok, and unmistakably Toj.
- We borrow how Telegram *executes* iOS 26 Liquid Glass (floating chrome, well-measured pressable
  controls, inset grouped cards, folder pills, detached search) — never its palette.
- Modern Tajik identity is expressed through the restrained crown mark, not flag stripes or ornament.

## Color

- Canvas: `#000000`
- Base surface: `#08090B`
- Raised surface: `#111318`
- Strong surface: `#191C21`
- Primary text: `#F4F5F7`
- Secondary text: `#9096A1`
- Brand gold / accent: `#D6A936`
- Secure green: `#38C991`
- Outgoing bubble: `#1B1D21` (with a faint gold hairline)
- Destructive actions use the system red semantic color.

## Accent

- Gold is Toj's **signature interactive accent** — the role Telegram gives blue. Apply it with
  precision to high-intent and active moments: the send button, primary CTAs, active unread badges,
  and selected folder/search pills. On gold, foreground is `canvas` (black).
- White (`text`) stays the neutral accent for high-frequency/secondary controls (back, compose,
  attach, chevrons) so the interface reads clean, not gaudy.
- Green (`secure`) signals encryption / online / success only. Red signals destruction only.
- Never encode meaning through color alone; never use thin text on black.

## Typography

- Brand and large headings: Onest Semibold/Bold, relative to Dynamic Type styles.
- Messages, labels, controls, and dense lists: native iOS text styles.
- Never use thin text on black or encode meaning through color alone.

## Shape and Spacing

- Base spacing unit: 4 pt. Use the `TojSpacing` scale (`xs 4, sm 8, md 12, lg 16, xl 24, xxl 32`).
- Corner radii use the `TojRadius` scale (`field 18, tile 14, card 20, cardLarge 22, bubble 20,
  bubbleTail 6`).
- Search, navigation identity, and composer: full capsules.
- Avatars and compact icon controls: circles.
- Message bubbles: 20 pt radius with a 6 pt conversational tail corner.
- Minimum interactive target: 44×44 pt.

## Components

- Reuse the shared primitives in `TojTheme.swift`: `TojNavHeader` + `TojGlassIconButton` (floating
  chrome), `TojSectionCard` + `TojIconTile` (grouped rows), `TojPillFilter` (segmented pills), and
  `TojPressableStyle` / `.buttonStyle(.tojPressable)` (reactive press feedback).
- Grouped-row icon tiles are premium/monochrome by default; use a semantic tint only where it carries
  meaning (green privacy, gold premium, red destructive), never a rainbow.
- Everything interactive is pressable: a gentle press-scale + dim, replaced by opacity under Reduce Motion.

## Motion

- Micro transitions: 140–180 ms; screen/state transitions: 180–220 ms.
- Prefer native navigation, glass morphing, opacity, and short snappy springs.
- Reduce Motion replaces movement and scale with opacity.
- Reduce Transparency replaces glass with an opaque raised surface.

## Liquid Glass

- Use glass only for navigation, search, the composer, and high-level controls.
- Keep lists and bubbles matte for legibility and rendering performance.
- Group nearby glass controls in `GlassEffectContainer` when they morph or interact.

