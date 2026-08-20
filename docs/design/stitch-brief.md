# KORE — Stitch Brief

Prompts for generating KORE's mobile screens in Google Stitch. Each block below
is self-contained: the shared style preamble plus one screen. Send them one at
a time — a prompt covering several screens produces an average of them.

The screens marked **designed, not built** in `mobile.md` are the ones worth
generating. The dashboard, reset protocol, check-in and trend already exist in
Flutter and are on tokens; regenerating them from scratch would fork the design
system rather than extend it.

---

## Shared style preamble

Paste this above every screen prompt.

> Dark, warm, editorial mobile UI for **KORE**, a cognitive-load measuring app
> for students. Not a medical app, not a meditation app, not a fitness tracker.
>
> **Palette.** Background near-black warm ink `#12100F`, surfaces `#1A1817`,
> hairline borders `#322F2D`. Primary text warm paper `#F0EBE1`, secondary
> `#B0A89D`, muted `#8C857E`. Accent rust `#CF5F3C`. The cognitive-load scale
> runs cool → warm across five stops: teal `#4FA9A2`, sage `#8DBE85`, ochre
> `#E0C566`, amber `#F4A45F`, rust `#E85E42`. **Never green-to-red** — that is
> the axis red-green colour blindness collapses, and the cool-to-warm ramp is
> deliberate.
>
> **There is no alarm colour.** No red error states, no warning triangles, no
> exclamation marks. KORE reports a bad reading plainly and never dramatises
> it.
>
> **Type.** Display serif for headlines (Fraunces or similar), geometric sans
> for body and UI (Space Grotesk or similar), tabular figures for any numeral.
>
> **Restraint.** Hairline 1px borders instead of glows. No gradients except
> very low-opacity radial washes. Generous spacing on an 4/8/12/16/24/32 scale.
> Rounded corners 8/16/24. One accent per screen, at most.
>
> **The constraint that governs everything:** the user opens this app when they
> are *already cognitively overloaded*. Low visual burden, high readability,
> predictable interaction. A busy, clever interface is a failed interface here.

---

## Screen 1 — Welcome

> A first-run welcome screen. Its only job is to set the claim boundary before
> the first reading appears, because that boundary is the product's
> credibility.
>
> Content: the KORE wordmark, then three short lines of body copy stating that
> KORE measures the balance of two EEG rhythms and turns it into one number
> from 0 to 100, that it is a wellness tool and not a medical device, and that
> it does not diagnose anything. One primary button: **Get started**.
>
> No carousel, no pagination dots, no illustration of a brain, no permission
> requests, no sign-in, no account. Asking for anything before the user has
> seen a reading is asking them to trust an empty box. Vertically generous,
> text left-aligned, button pinned to the bottom within thumb reach.

## Screen 2 — Pair (three states, one screen)

> A pairing screen for a wearable EEG patch, showing **three states in one
> screen, never three separate screens**. Generate all three states as
> variants:
>
> 1. **Searching** — a slowly animated concentric ring, caption "Looking for
>    your patch", a text button "Cancel".
> 2. **Found** — the patch name, its battery level, a primary button
>    "Connect".
> 3. **Contact check** — the important one. A small head diagram showing
>    electrode placement, and a per-electrode contact-quality reading. Each
>    electrode shows its quality as a labelled state, *not colour alone* —
>    words like "Good" / "Weak" / "No contact" alongside the colour. The
>    primary button "Continue" is visibly disabled until contact is good, with
>    a one-line explanation of why it is disabled.
>
> Tone for the contact check: instructive, not alarming. "Press the left pad
> down until it reads" rather than "ERROR: bad signal". A poor electrode
> produces a *plausible* number rather than an obviously broken one, so this
> screen is where the product's honesty is enforced — but it should feel like
> being helped, not scolded.

## Screen 3 — History

> A reverse-chronological history of reset sessions, reached from a card on
> the dashboard rather than from a tab bar.
>
> A list grouped by day. Each day is a date header and a horizontal row of
> **reset chips**. Each chip shows the measured drop in cognitive load (for
> example "−14") and the self-reported clarity as a 1–5 indicator. Abandoned
> resets appear in the row too, greyed and clearly marked as abandoned rather
> than hidden.
>
> Include an empty state: a short line explaining that resets appear here once
> the first one is finished — no illustration, no "Oops!".
>
> Showing abandoned sessions is deliberate. Hiding them would flatter the
> numbers, and the app's rule is to state the measurement plainly.

## Screen 4 — Signal lost (state, not a screen)

> The dashboard in its **signal-lost** state, as an overlay treatment on an
> existing screen rather than a new page.
>
> A large circular gauge showing a number that is visibly *held rather than
> live*: the numeral and arc rendered in muted grey `#8C857E` instead of the
> load ramp, with the caption under it reading "LAST READING" rather than
> "COGNITIVE LOAD". Below the gauge, a bordered notice card stating the fault
> and the fix in plain language — for example "The electrode is not making
> contact" with the line "Press it back down. Nothing is being recorded until
> it reads."
>
> No red. No warning icon. No modal. The reading stays on screen so the user
> can sanity-check it; it simply stops claiming to be current.

---

## What not to ask Stitch for

- **A tab bar.** Two destinations do not justify bottom navigation; entry to
  the trend and history is a tap on the card you are already reading.
- **A green-to-red gauge.** Covered above, but it is the single most likely
  thing a generator will default to.
- **Charts with auto-scaled axes.** The load scale is pinned 0–100 so a calm
  fortnight and a strained one do not draw identically.
- **Celebration.** No confetti, no streak fire, no "Great job!". The reset
  either moved the number or it did not, and the app says which.
