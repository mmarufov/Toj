# Toj design system

## Product

Toj is a messenger for iPhone and iPad. It should feel fast and quiet, and familiar to people
who already use modern chat apps.

## Visual Direction

- Black-only interface with matte conversation content and floating Liquid Glass controls, in
  the minimal style of X and Grok.
- We follow Telegram's use of iOS 26 Liquid Glass (floating chrome, well-measured pressable
  controls, inset grouped cards, folder pills, detached search) with our own palette.
- The crown logo carries the brand. The interface uses no flag colors or ornament.

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

- Gold is Toj's **interactive accent**, the role blue plays in Telegram. Use it for high-intent and
  active elements: the send button, primary CTAs, active unread badges, and selected folder/search
  pills. On gold, foreground is `canvas` (black).
- White (`text`) stays the neutral accent for high-frequency/secondary controls (back, compose,
  attach, chevrons), which keeps the interface calm.
- Green (`secure`) signals encryption / online / success only. Red signals destruction only.
- Never encode meaning through color alone; never use thin text on black.

## Logo

- A solid off-white crown (`#F5F5F3`), tilted 6° counter-clockwise, on a charcoal tile
  (`#17191B`). No color and no gradient.
- It lives in three places that must change together: the app icon set
  (`Toj/Assets.xcassets/AppIcon.appiconset`), `docs/assets/toj-symbol.png` and `.webp` (README and
  website), and `TojMark` in `TojTheme.swift`, which draws the same geometry in code.
- The tinted app icon is the crown in white on black; iOS applies the tint.

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
  meaning (green privacy, gold premium, red destructive).
- Everything interactive is pressable: a gentle press-scale + dim, replaced by opacity under Reduce Motion.

## Motion

- Micro transitions: 140-180 ms; screen/state transitions: 180-220 ms.
- Prefer native navigation, glass morphing, opacity, and short snappy springs.
- Reduce Motion replaces movement and scale with opacity.
- Reduce Transparency replaces glass with an opaque raised surface.

## Liquid Glass

- Use glass only for navigation, search, the composer, and high-level controls.
- Keep lists and bubbles matte for legibility and rendering performance.
- Group nearby glass controls in `GlassEffectContainer` when they morph or interact.

