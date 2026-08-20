# Stitch output — first pass

Generated in Google Stitch (project `10218682354863067055`) from the prompts in
`../stitch-brief.md`. These are **direction, not specification** — the built
app's design system in `lib/theme/` remains the source of truth.

## Reproducing

`generate_screen_from_text` over the Stitch MCP, one screen per call. Two
arguments break it silently — the call returns a bare `{projectId, sessionId}`
after doing no work, with no error:

- `modelId` — any explicit value, including `GEMINI_3_1_PRO`. Omit it.
- `designSystem` — an asset id that the project does not actually own. Omit it
  unless the id came from `list_design_systems` for this project.

Also note `list_screens` does not return generated screens. Read the screen ids
and screenshot URLs out of the `outputComponents[].design.screens` array in the
generation response instead.

`upload_design_md` + `create_design_system_from_design_md` ran without error but
left `designTheme` empty, so the palette in `../DESIGN.md` is not bound to the
project. Each prompt carries the palette inline instead.

## What each screen is

| File | Screen | Verdict |
|---|---|---|
| `kore-welcome.png` | First run, claim boundary | Usable as direction |
| `kore-signal-lost.png` | Dashboard holding a stale reading | Best of the four |
| `kore-history.png` | Reset history by day | Needs corrections |
| `kore-pair.png` | Electrode contact check | Re-run required |

## Known problems

Recorded so nobody mistakes these for approved designs.

1. **Both dashboard-adjacent screens grew a bottom tab bar** (Dashboard /
   Trends / Settings). Ruled out in `../mobile.md`: two destinations do not
   justify bottom navigation, and entry to the trend is a tap on the card you
   are already reading.
2. **`kore-pair.png` is not usable.** The head diagram came back as a separate
   raster image with the electrode labels scattered over it and colliding. It
   also invented clinical 10–20 electrode names (FP1, FP2, FPZ, T3, T4), which
   reads as medical instrumentation and cuts directly against the positioning,
   and it used green for "Good" — dragging the ramp back toward the green/red
   axis the palette exists to avoid.
3. **`kore-history.png` shows invented statistics** — a 12-day streak, a −18
   mean drop, 4.2 clarity — presented as real. Same class of thing that was
   stripped from the landing page: outcome numbers for a product with no users
   and no sensor.
4. **`kore-welcome.png` lost the type pairing.** Everything is set in the
   display serif; the geometric sans for body and UI did not survive.

## What held up

The palette carried across all four, and nothing reached for green-to-red.
`kore-signal-lost.png` got the honesty rule right unprompted by any example: a
muted numeral captioned LAST READING, the fault named with its fix, no red, no
warning icon, no modal.
