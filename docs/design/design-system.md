# KORE Design System

The code is in `lib/theme/`. This document says *why* each token is what it
is. Where the two disagree, the code is right and this file is stale.

## The constraint everything answers to

**KORE is opened by someone who is already cognitively overloaded.** That is
not a persona note; it is the specification. It means:

- Low visual burden. Fewer elements, larger targets, no ornament that has to
  be parsed before it can be dismissed.
- High readability. Body type at 16, tabular numerals, 4.5:1 minimum contrast
  everywhere, including the load ramp.
- Predictable interaction. The same control in the same place across states.
  Nothing appears or moves because a reading changed.
- Fast insight. The answer to "how am I doing" is one number, one word and
  one shape, all visible without scrolling.

A busy, clever interface is a failed interface here.

## The honesty rule as a visual rule

The product states the measurement plainly, including when a reset did not
work. That constrains the palette as much as it constrains the copy:

- There is **no signal red** in KORE. The strain end of the ramp is a warm
  burnt orange, and the previous theme's `semanticColors` map — which carried
  a `#ef4444` error red, a `#4ade80` success green and an `#fbbf24` warning
  amber, none of them used — has been deleted rather than left as an
  invitation.
- Nothing flashes, pulses or slides in when the index rises. Strain is a
  reading, not an event.
- `Your load rose 12 points` is rendered in exactly the same style as
  `Your load fell 12 points`: secondary text, no colour, no icon. Colouring
  the bad outcome would turn a measurement into a verdict on someone who has
  just spent a minute breathing.
- A statistic with no data behind it prints `--` in `unmeasured`, never in the
  calm colour. Absence of a measurement must not read as a good one. This is
  enforced at the token level: `KoreColors.forLoad(value, measured: false)`
  returns `unmeasured`, so a calibrating gauge cannot paint itself calm even
  by accident.

## Layers

Three, in the usual order, and the boundary is enforced by convention rather
than by tooling:

| Layer | File | Contains | Who reads it |
|---|---|---|---|
| 1. Primitive | `primitives.dart` | `KoreInk.x05`, `KoreBrand.rustBright` — raw values, no meaning | only layer 2 |
| 2. Semantic | `colors.dart`, `metrics.dart` | `canvas`, `textSecondary`, `strain`, `KoreSpace.md` | widgets |
| 3. Component | `components.dart` | `KoreGauge.stroke(d)`, `KoreSparkline.height(w)` | one widget each |

Layer 2 colour is a `ThemeExtension`, not a set of statics. The gauge and the
sparkline are `CustomPainter`s, which have no `BuildContext`; the widget above
each reads `context.kore` once in `build` and passes the resolved object into
the painter as a field. That also gives `shouldRepaint` a cheap check that
catches a theme change.

Layer 3 exists because of the responsive work. A gauge at 148 px and a gauge
at 240 px are the same gauge — stroke, numeral size and caption gap are all
derived from the diameter here, so a layout can resize the component without
inventing numbers at the call site.

## Colour

### The ramp is the hard part

The Cognitive Load Index runs 0–100, calm to strained, and its colour has real
work to do: it is the only channel that reads from across a room.

The original ramp was `Color.lerp(sage #8DA48B, rust #CF5F3C, t)`. Two
problems, one cosmetic and one disqualifying.

*Cosmetic:* a straight RGB lerp between a desaturated green and an orange
passes through a chroma-dead brown around 50. That is exactly the range the
reading sits in most of the time, and it is where movement most needs to be
visible.

*Disqualifying:* green-to-red is the precise axis that red-green colour
vision deficiency collapses. Simulated (Viénot–Brettel–Mollon 1999) and
measured in CIE ΔE76:

| Pair | Normal | Protanopia | Deuteranopia | Tritanopia |
|---|---|---|---|---|
| old ramp, 0 vs 25 | 20.5 | 6.3 | **4.6** | 17.9 |
| old ramp, 0 vs 100 | 63.8 | 29.3 | 41.5 | 59.1 |

A ΔE of 4.6 is "these are the same colour". For roughly one man in twelve,
the bottom quarter of the old ramp did not exist.

### What replaced it

Five hand-placed stops interpolated pairwise, traversing **cool to warm**
rather than green to red:

```
0    teal      #4FA9A2      1.  cool  ->  warm adds a blue-yellow component,
25   sage      #8DBE85          which is the axis every common deficiency
50   ochre     #E0C566          preserves.
75   amber     #F4A45F      2.  Placed stops keep chroma through the middle
100  rust      #E85E42          instead of passing through brown.
```

| Pair | Normal | Protanopia | Deuteranopia | Tritanopia |
|---|---|---|---|---|
| new dark, 0 vs 100 | 93.6 | 41.5 | 63.8 | 89.3 |
| new light, 0 vs 100 | 83.4 | 36.7 | 56.1 | 79.3 |

Every stop clears **4.5:1** against both the canvas and the card in its own
theme — better than the 3:1 that large text and graphical objects strictly
require, which means the same colour can also carry the small state text
without a second token. `test/widgets/load_ramp_test.dart` asserts both the
contrast floor and a ΔE ≥ 35 end-to-end separation under all three
deficiencies, so these are claims the build checks rather than claims this
document makes.

**What is still imperfect, stated plainly.** Adjacent stops in the warm half
(50 → 75, ochre to amber) separate by only ΔE 4.0 under deuteranopia: to a
deuteranope both are yellow, and their lightness is close. The ramp cannot fix
that without abandoning either the brand or the contrast floor. It does not
need to, because **colour is never the only channel**:

- the numeral states the reading,
- the state chip states it in a word,
- the fraction of the arc that is filled is monotone in the reading,
- a tick on the arc and a dashed rule on the trend mark the strain threshold.

Discard colour entirely and the gauge still reads correctly. That, not the
ramp, is what makes the surface accessible; the ramp is a supporting cue that
now supports more people than it used to.

### Why not just make it monotone in lightness

The obvious fix — a viridis-style ramp that rises steadily in lightness — is
unavailable here. On the dark canvas, a 4.5:1 floor puts every stop above
L\* ≈ 57, and a saturated orange above L\* ≈ 80 is a pale peach that reads as
a highlight rather than as strain. Monotone lightness, brand identity and the
contrast floor are three constraints that do not simultaneously hold. Chroma
carries the ramp instead, lightness peaks in the middle, and the redundant
channels above cover what that costs.

### Roles

| Role | Dark | Light | Note |
|---|---|---|---|
| `canvas` | `#12100F` | `#FAF7F1` | warm neutral, not grey — the type is a warm cream, and neutral grey under it reads faintly blue |
| `surface` | `#1A1817` | `#FFFFFF` | sheets, bars |
| `card` | `#232120` | `#FFFFFF` | panels |
| `border` / `borderStrong` | `#322F2D` / `#423E3B` | `#E3DCD0` / `#C8BFB1` | hairlines and dividers |
| `textPrimary` / `textSecondary` | `#F0EBE1` / `#B0A89D` | `#1A1817` / `#6B6560` | both clear 4.5:1 on all three grounds |
| `accent` / `onAccent` | `#CF5F3C` / `#12100F` | `#B44E2C` / `#FFFFFF` | actions only |
| `calm` / `strain` | ramp ends | ramp ends | for states with no numeric reading |
| `unmeasured` | `#8C857E` | `#6B6560` | no baseline, no data, no rating |

`accent` is deliberately **not** on the ramp. A button must not change colour
because a reading moved — that is the "predictable interaction" clause, and
it is why the reset CTA is rust at 12 and rust at 92.

The light theme is not an inversion. On a light ground the ramp has to get
*darker* toward strain to stay legible, which is why every ramp hue keeps a
separate deep variant rather than reusing the bright one. Both themes traverse
the same five hues in the same order, so the shape of a reading is identical
either way. `MaterialApp` follows the system: KORE is opened at 2am in a dark
room and at noon on a bright campus, and the phone already knows which.

## Type

Two bundled families, no runtime fetch. **Fraunces** (serif) is reserved for
moments the product wants to feel considered; **Space Grotesk** carries
everything functional, and has tabular figures, so the index does not jitter
as it ticks at 4 Hz.

| Step | px | Used for |
|---|---|---|
| `size48` / `size36` / `size28` | 48 / 36 / 28 | display (Fraunces) |
| `size24` / `size20` / `size16` | 24 / 20 / 16 | headlines |
| `size18` / `size16` / `size14` | 18 / 16 / 14 | titles |
| `size16` / `size14` / `size12` | 16 / 14 / 12 | body |
| `size12` / `size11` / `size10` | 12 / 11 / 10 | labels, all-caps, tracked |

Body sits at 16 so the app is readable at arm's length on a phone without
pinching. Nothing below 10, and nothing below 12 carries information that is
not also available elsewhere.

`KoreType.numerals(...)` is the only way to render a number that updates in
place. It is a separate call rather than a text-theme slot because it takes a
size from the layout, not from the scale — the gauge numeral is 30% of the
gauge diameter.

## Space, radius, elevation

`KoreSpace` is a 4pt scale: 4, 8, 12, 16, 20, 24, 32, 40, 56. Every gap in
the app is one of these, so vertical rhythm is a property of the system rather
than of whoever last touched a widget.

`KoreRadius`: 8 / 16 / 24 / 32, plus `pill` for buttons and chips.

**Elevation is a change of ground, not a shadow.** On the dark theme a drop
shadow is invisible against a near-black canvas, so the three levels are three
surface tints plus a hairline border. On the light theme those tints are
nearly identical, so there a soft shadow does the separating instead
(`KoreElevation.shadow`). Same three levels, different mechanism, one token.

## Motion

Short and deliberately dull. The user arrives overloaded; anything that draws
the eye without carrying information is a cost.

| Token | Duration | Used for |
|---|---|---|
| `quick` | 120 ms | state chips, badges |
| `standard` | 240 ms | routes, sheets |
| `gauge` | 260 ms | easing the index between 4 Hz frames so it reads as continuous rather than stepped |
| `breathCycle` | 16 s | one box-breathing cycle: inhale 4, hold 4, exhale 4, hold 4 |

`KoreMotion.respecting(context, d)` returns zero when the platform asks for
reduced motion. **The breathing pacer does not go through it.** The expansion
of that circle *is* the instruction; removing it would leave a word with no
pacing behind it. Decorative easing is negotiable, the protocol is not.

## Component specs

### Load gauge — `LoadMeter`

The product surface. A 270° arc opening downward; the gap is where the eye
enters and it keeps the numeral optically centred.

| Property | Value |
|---|---|
| Sweep | 270°, starting at 135° |
| Stroke | `diameter × 0.076`, clamped 9–18 |
| Numeral | `diameter × 0.30`, tabular, ramp colour |
| Caption | `labelMedium`, tracked 1.4, `COGNITIVE LOAD` |
| Threshold tick | at `kStrainEnter / 100` of the sweep, `textSecondary` at 60% |
| Diameter | 132–260 compact, 132–208 medium, 132–240 expanded |

States:

| State | Arc | Numeral | Caption |
|---|---|---|---|
| Calibrating | track only | seconds remaining, `unmeasured` | `CALIBRATING` |
| Measured | filled to value, ramp colour | the value, ramp colour | `COGNITIVE LOAD` |

The tick fraction is derived from `CognitiveLoadIndex.kStrainEnter` rather
than hardcoded at 0.70, so retuning the index moves the mark with it.

Carries a `Semantics` label — *"Cognitive load 42 out of 100"* — because the
number is painted, and a painted number is invisible to a screen reader.

### Trend sparkline — `LoadSparkline`

Answers "where was I heading", which is what makes a reset visibly work.

- 2 px stroke, 3.5 px head dot, both in the colour of the **latest** reading
  so the trend and the gauge always agree on the state.
- Gradient fill under the trace, 22% to 0.
- Threshold rule dashed 5-on-5-off in `border`, so it reads as a reference
  and not as a second series.
- Height 72 compact / 64 medium / 76 expanded. Taller on a phone because it
  is the only trend surface there.
- The x-axis always spans the full history capacity, so the trace advances
  across the panel as data arrives instead of rescaling under the viewer.

### Reset protocol — `ResetProtocolSheet`

A full-screen route, deliberately almost empty. It is shown to someone who has
just been told they are overloaded, and every element on it is one more thing
to process instead of breathe through.

| Property | Value |
|---|---|
| Breath circle | `shortestSide × 0.52`, clamped 120–240 |
| Scale | 0.6 → 1.0 over the inhale; the 0.6 floor keeps it followable with peripheral vision, so the user can close their eyes on the exhale and still catch the turn |
| Fill / border | `calm` at 12% / 70%, 2 px |
| Phase word | `headlineMedium` in a fixed-height box, so the timer below does not shift as the word changes length |
| Timer | `size28` tabular, `textSecondary` |
| Exit | `End early`, text button, bottom — reachable, not adjacent to anything |

Sized off the shorter axis so a landscape phone or a short desktop window
shrinks the circle rather than clipping it, and wrapped in a scroll view with
a `minHeight` so it centres when there is room and scrolls when there is not.

### Check-in sheet — `CheckInSheet`

One question, five options, and a skip that is as easy to reach as the scale —
a check-in that is hard to dismiss stops being a measurement and starts being
a toll.

| Property | Value |
|---|---|
| Options | 5, laid out with `Expanded`, circle `(width − 4×8) / 5` clamped 48–60 |
| Option label | `labelSmall`, single line, `Foggy · Murky · Neutral · Clear · Sharp` |
| Measurement line | `bodyMedium` in `textSecondary`, **never coloured by the result** |
| Skip | text button, full-width tap area |

The circles used to be a fixed 52 px in a `spaceEvenly` row, which overflowed
below about 360 px of sheet width. They now divide the row, with 48 px — the
touch-target floor — as the minimum.

### Stats row — `RecoveryCard`

Renders nothing until the first reset is logged. An empty card reading
"0 day streak, no data" on first launch teaches the user that the feature is
dead weight before they have had a chance to use it.

Three statistics — day streak, average drop, average clarity — as `size28`
tabular numerals in `calm`, with `labelSmall` captions. A statistic with no
data prints `--` in `unmeasured`. The card owns no outer margin; the layout
that includes it owns the gap, so an absent card leaves no hole.

### Calibration state

Not a loading spinner. Calibration is 15 seconds of baseline capture, and the
index is meaningless until it finishes, so the gauge shows a *count* rather
than a *progress animation*: a bounded wait the user can plan around. The
track is drawn, the fill is not, the chip reads `Establishing your baseline`,
and the colour is `unmeasured` throughout.

The reset CTA stays enabled during calibration. Gating it would mean waiting
on the simulation before the loop could be demonstrated; the session layer
already declines to log a reset taken without a baseline, which is the correct
place for that rule.

## Responsive

`KoreWindow` classifies by size, not by device: `compact` below 600 px wide,
`expanded` at 1000 px or wider *and* 640 px or taller, `medium` in between.
`KoreBreakpoints.gutter` gives 20 / 24 / 32 — compact gives up the least width
to margins, because on a phone the gauge is competing for it.

See `docs/design/mobile.md` for what changes at compact and why.
