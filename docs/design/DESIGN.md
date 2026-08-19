# KORE Design System

KORE is a cognitive-load measuring app for students. It reads an EEG signal,
turns it into one number from 0 to 100, and guides a 60-second reset.

**The constraint that governs everything:** the user opens KORE when they are
*already cognitively overloaded*. Low visual burden, high readability,
predictable interaction. A busy, clever interface is a failed interface here.

## Colour

Dark, warm, editorial. Not clinical, not neon.

| Role | Hex |
|---|---|
| Canvas | `#12100F` |
| Surface | `#1A1817` |
| Border (hairline) | `#322F2D` |
| Text primary | `#F0EBE1` |
| Text secondary | `#B0A89D` |
| Text muted / unmeasured | `#8C857E` |
| Accent | `#CF5F3C` |

### The cognitive-load ramp

Five stops, **cool to warm**, for readings 0 to 100:

| Reading | Hex |
|---|---|
| 0 | `#4FA9A2` teal |
| 25 | `#8DBE85` sage |
| 50 | `#E0C566` ochre |
| 75 | `#F4A45F` amber |
| 100 | `#E85E42` rust |

**Never green-to-red.** That is the exact axis red-green colour blindness
collapses; the old ramp's bottom quarter was indistinguishable under
deuteranopia. Cool-to-warm keeps the blue-yellow component every common
deficiency preserves. Every stop clears 4.5:1 contrast on the canvas.

Colour is never the only channel. A reading is always carried by its numeral,
its state word, and the arc fill as well as its colour.

### There is no alarm colour

No red error states, no warning triangles, no exclamation marks. KORE reports a
bad reading plainly and never dramatises it. A fault is rendered in the muted
grey `#8C857E`, never in the strain colour — the distinction is between
colouring a *measurement* and colouring a *fault*, and a fault is not a
reading.

## Type

- Display serif for headlines — Fraunces or similar.
- Geometric sans for body and UI — Space Grotesk or similar.
- Tabular figures for every numeral.
- Tracked, small, uppercase labels for captions (letter-spacing ~0.12em).

## Spacing, radius, elevation

- Spacing scale: 4 / 8 / 12 / 16 / 24 / 32 / 48.
- Radius: 8 small, 16 medium, 24 large, pill for buttons.
- Elevation is a change of ground on dark, a shadow on light. Three levels.

## Restraint

- Hairline 1px borders instead of glows.
- No gradients except very low-opacity radial washes.
- One accent per screen at most.
- No confetti, no streak fire, no "Great job!". The reset either moved the
  number or it did not, and the app says which.

## Voice

Plain, measured, never clinical and never cheerful. State the measurement
including when it went the wrong way. Instruct rather than scold: "Press it
back down until it reads", not "ERROR: bad signal".
