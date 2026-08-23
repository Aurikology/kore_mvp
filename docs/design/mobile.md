# KORE on a Phone

The desktop build is a prototype harness. The product is a wearable EEG patch
paired with a phone, and that changes the design more than it changes the
code. This document is the design; the responsive work in `lib/app/` and
`lib/widgets/` is the part of it that is built.

## What actually changes

**The user is no longer sitting at the thing that measures them.** On desktop,
KORE is a window open beside their work; the dashboard is ambient and they
glance at it. On a phone, the patch is on their forehead and the phone is in a
pocket. The app is not where they find out they are strained — **the patch
tells them, and the app is where they look for detail.** Everything below
follows from that inversion.

**The session is four seconds, not four hours.** A phone glance answers one
question — *what now?* — and the answer must be above the fold, at arm's
length, without focusing. The desktop layout can afford a second screenful.
The phone layout cannot.

**One hand, and the wrong one.** They are holding a pen, a coffee, a door.
The only control that matters — the reset — is pinned to a bottom bar and does
not move when the state changes. Everything else scrolls past it. Nothing
destructive lives at the top of the screen where a stretched thumb lands.

**The screen is the wrong channel for the protocol itself.** Positioning calls
KORE a *screenless* focus system. Spending sixty seconds staring at a phone to
know when to breathe out is the opposite of that. On a phone the protocol is
paced by **haptics** — a tap at each of the four phase boundaries — and the
expanding circle becomes the fallback channel rather than the only one. This
is implemented: `ResetProtocolSheet` pulses on each quarter of the cycle, and
swallows the failure on desktop, which has no motor.

**Light matters.** A phone is used outdoors. The app follows the system theme
and ships a real light palette, with the load ramp reversed in lightness — on
a light ground it has to get *darker* toward strain to stay legible. See
`design-system.md`.

**Interruption is a feature with a cost.** The patch can detect strain the
user has not noticed. A phone can tell them. That is the product's whole
promise and also the fastest way to make it uninstallable. The rule: KORE
prompts at most once per strain episode, never within ten minutes of the last
prompt, never during a reset, and every prompt is dismissible in one action
from the lock screen. It says what it measured and for how long, never how the
user feels.

## Flow

```
  first run
     |
  Welcome ......... what KORE measures, and what it does not claim
     |
  Pair ............ find patch -> connect -> contact check
     |
  Calibrate ....... 15 s baseline, bounded and counted
     |
     v
  DASHBOARD  <----------------------------+
     |  ^                                 |
     |  |  strain detected                |
     |  |  (notification, patch or phone) |
     |  |                                 |
     v  |                                 |
  RESET PROTOCOL .. 60 s, haptic-paced    |
     |                                    |
     v                                    |
  CHECK-IN ........ one question, skippable
     |                                    |
     +------------------------------------+
     |
     +--> TREND ... reached from the trend card, not from a tab bar
     |
     v
  HISTORY ......... reached from the recovery card, not from a tab bar
```

Six screens plus two sheets. That is the whole app, and it should stay that
way; a second tab is a second decision to make before the first one is done.
Both of the destinations off the dashboard are reached by tapping the card that
is already showing a summary of them — the card is the affordance, and it is
free, where a bottom bar costs a permanent choice on every screen.

## Screens

### Welcome — built

Three lines and a button. Its only job is to set the claim boundary before the
first reading appears, because that boundary is the product's credibility:

> KORE measures the balance of two EEG rhythms and turns it into one number
> from 0 to 100. It is a wellness tool, not a medical device, and it does not
> diagnose anything.

No carousel, no permissions requested yet, no account. Asking for anything
before the user has seen a reading is asking them to trust an empty box.

### Pair — built

Three states in one screen, never three screens:

| State | Shows | Action |
|---|---|---|
| Searching | animated ring, `Looking for your patch` | Cancel |
| Found | patch name, battery | Connect |
| Contact check | per-electrode contact quality, a placement diagram | Continue (enabled only when contact is good) |

The contact check is the one that matters and the one hardware demos always
skip. A poor electrode produces a *plausible* index rather than an obviously
broken one, and a plausible wrong number is worse than no number. This screen
is the honesty rule applied to hardware.

Built against `SourceLink` and the per-pad contact report. Three details are
the screen rather than decoration: Continue is disabled until every *measurable*
pad is seated, the line under it names the pad rather than describing the
fault, and an unmeasurable pad reads "Not measured" and blocks nothing — it is
not evidence of a fault and not evidence of health. The placement diagram
guesses geometry from the pad's id, which is a drawing decision and is allowed
to be wrong in a way a measurement is not; nothing in the model carries
electrode positions, because coordinates on `ElectrodeContact` would commit the
repo to a montage by accident.

With no radio yet it pairs with the simulated patch, which says so in its own
name. The scan and connect delays live at the composition root rather than in
the source: everywhere else the simulated patch connects instantly, which is
what keeps the test suite free of pumping, and a scan that resolves in one
frame cannot be cancelled and reads as a mock-up.

### Calibrate

Fifteen seconds of baseline capture, already built. On a phone two things
change:

- The gauge shows a **count**, not a progress animation. A bounded wait can be
  planned around; a spinner cannot. This is how it already works and it was
  the right call.
- The instruction is *"Sit as you normally would"*, **not** *"relax"*. A
  baseline captured while deliberately relaxing makes every subsequent reading
  read as strain, and the user would have no way to know why their number
  never drops.

Calibration should be re-offered, not re-forced, when the patch is re-seated —
which the app cannot currently detect.

### Dashboard — built

Compact layout, top to bottom:

```
  KORE
  [Simulated signal] [Dart DSP]      <- badges wrap to their own row; the
                                        native label alone is half the width
        (  42  )                     <- gauge, 68% of the width, 132-260 px
       COGNITIVE LOAD
        [ * Steady ]
  +----------------------------+
  | LAST 2 MINUTES    thresh 70|
  |  ~~~~~~~~~~~~~-------~~~   |
  +----------------------------+
  | LAST 14 DAYS   See 30 days |
  | Your load is rising -      |
  | about 5 points a week.     |
  | Mean 54 across 6 days...   |
  |  ..||.|--.|||.             |  <- one bar per day, gaps are gaps
  |  5 Aug              Today  |
  +----------------------------+
  | RECOVERY        3 in 7 days|
  |  4        18       4.2     |
  |  streak   drop     clarity |
  +----------------------------+
  ...scrolls...
--------------------------------      <- hairline
  [       Run a reset        ]        <- pinned, always in the thumb zone
```

The gauge takes 68% of the available width on compact against 42% elsewhere.
On a phone it is the screen; on a desktop it is one panel among several, and a
400 px number is not more informative than a 240 px one.

At `expanded` (≥1000 px wide and ≥640 tall) the same widget list becomes two
columns — the reading and its action on the left, the history behind it on the
right — so a desktop window is one glance with no scroll. At `medium` it is a
single 720 px column. Three layouts, one widget list, chosen by window class
rather than by platform: a 500 px desktop window gets the phone layout, which
is what someone who has parked KORE beside their work actually wants.

### Reset protocol — built

Unchanged in structure, and deliberately almost empty: it is shown to someone
who has just been told they are overloaded, and every element on it is one
more thing to process instead of breathe through.

What changed for the phone:

- The breath circle is sized from the **shorter axis** (52%, clamped 120–240)
  rather than fixed at 240. The fixed version overflowed by 139 px on a phone
  in landscape — a test now covers it.
- The column scrolls with a `minHeight`, so it centres when there is room and
  scrolls when there is not, instead of throwing.
- Haptic pacing, as above.
- The phase word sits in a fixed-height box so the timer beneath it does not
  jump as the word changes length. On a screen someone is trying to breathe
  to, a 4-pixel jitter once a second is genuinely irritating.

Still missing for a real phone: keeping the screen awake for the minute, and
allowing it to be locked while the haptics carry on. Both need platform
capability the project does not have and should not take a plugin for yet.

### Check-in — built

One question, five options, and a skip as easy to reach as the scale. The five
buttons now divide the row with `Expanded` and a 48 px floor rather than
sitting at a fixed 52 px in a `spaceEvenly` row, which had no margin left
below about 360 px of sheet width. The sheet opens scroll-controlled so it is
not stranded at half height on a tall phone.

The measurement line — *Your load rose 12 points* — stays in secondary text
with no colour and no icon, exactly as the falling case does.

### Trend — built

The dashboard is where "what now?" is answered, and the trend is not that
question — so it lives **below the fold**, under the two-minute sparkline, and
never above the gauge. A phone glance is four seconds and it belongs to the
reading.

But it could not be *only* a separate screen either. Three of the four metrics
the product is judged on are longitudinal, and reinforcement is step 4 of the
loop; a longitudinal figure nobody opens reinforces nothing. So: **the card is
the hook, the screen is the detail.** The card carries the whole claim in one
sentence and a fortnight of bars, which is enough for the glance; the screen
carries thirty days, the mean and the peak, and the footnote explaining what a
day has to carry before it counts.

The two order themselves by zoom rather than by importance — the last two
minutes, then the last fortnight, then the record of resets. That is what turns
"I am at 62" into "and 62 is where I have been all week".

On `expanded` the card lands in the right-hand column with the rest of the
detail list, so a desktop window shows both time scales in one glance and the
screen is a convenience rather than the only way to see a month.

### History — built

Reached from the recovery card, not from a tab bar. Two destinations do not
justify a bottom navigation bar; a tap target on the thing you are already
looking at does.

A reverse-chronological list of days. Each day: a row of reset chips, each
chip showing the measured drop and the self-reported clarity, with abandoned
resets present but greyed. Abandonment is a retention signal and hiding it
would flatter the numbers — the same reason the session layer keeps those
records.

The drop is uncoloured in both directions. The check-in sheet states a rise in
exactly the same secondary text as a fall, and a history that painted the good
ones green would be grading the user rather than reporting the measurement —
the sign carries it.

Still missing is the *index series* behind each reset, which lives only in a
120-second in-memory ring, so a chip can say what the reset moved but not draw
the shape of it.

## What "glanceable" means here

A state is glanceable if it can be read in under a second, at arm's length,
in sunlight, by someone not wearing their glasses. Concretely:

- The numeral is 30% of the gauge diameter — around 70 px on a phone — in
  tabular figures so it does not jitter at 4 Hz.
- The state is also a **word**, not only a colour and not only a number.
- The arc's fill fraction is monotone in the reading, so the shape alone
  orders two readings correctly with colour discarded.
- Nothing on the screen animates except the gauge easing between frames.

**The tier above the app.** On a phone the most-used surface is one KORE does
not draw: the notification. Still designed, not built — it needs an in-repo
platform channel, and the copy below needs `strainSince`, which the session
layer does not yet expose. Designed, not built, and the format is fixed:

> **KORE** · Load 78 for the last 6 minutes
> [ Reset ]   [ Not now ]

It states the measurement and the duration. It does not say "you seem
stressed", does not use an emoji, and does not escalate if ignored. `Not now`
suppresses for the rest of the episode, not for ten minutes.

## What the session layer would need to expose

None of these are reachable from `lib/widgets/` and none should be faked
there. In rough order of how much the mobile design depends on them:

1. ~~**Electrode contact quality**, per channel, as a live value.~~ Delivered.
   `SignalQuality.electrodes` carries one `ElectrodeContact` per pad, each
   nullable on its own, and `KoreSession` exposes them along with
   `allPadsSeated`. The pairing screen is built on it.
2. ~~**Connection state and battery** as a typed value.~~ Delivered.
   `SourceLink` carries the state, the patch identity and the battery, with a
   `linkUpdates` stream alongside a synchronous getter — the same pair as
   `quality`/`qualityUpdates`, and for a sharper version of the same reason: a
   link that is scanning produces no blocks at all, so every state on the way
   to `streaming` is unobservable from the sample stream. Battery is nullable;
   a device that cannot report one says so rather than showing full.
3. **Today's rollup, before it is written.** `DailyLoadLog` now carries one
   entry per measured day and the trend view renders it — but `dailyLoad`
   excludes whatever the current session has measured since the last write, and
   the session only writes when the baseline lands or a reset is committed. So
   today's bar is missing from the chart for the whole of a session in which
   the user never resets, which is most of them. A read-only view of the
   in-flight accumulator — frames, mean, peak so far — would close it without
   the UI reaching past the read model. The screen currently states this out
   loud rather than hiding it.

   The rest of the original ask here is delivered: gaps *are* recorded as gaps,
   and the chart draws them as gaps. What is still missing is resolution finer
   than a day — load per hour, for a user who wants to know when in the day
   they crash.

   Two smaller gaps in the same layer. `DailyLoadLog` publishes
   `minFramesForTrend` and `trendPerDay`'s three-day refusal, but not **how
   many days in a window qualify** — the refusal copy has to name that number
   ("two days so far have"), so the widget re-derives the window boundary that
   `_within` already owns. A `qualifyingDays(today, window)` getter would
   remove the duplication. And `trendPerDay` returns a bare slope with no
   goodness-of-fit, where the crash predictor returns an R² and uses it to stay
   quiet; the trend view has nothing equivalent to lean on, so it withholds a
   direction on magnitude alone.
4. **`strainSince`** — the timestamp the current strain episode latched. The
   notification copy above says "for the last 6 minutes" and there is nothing
   to compute that from; `LoadState.strain` is a boolean-shaped fact.
5. ~~**Backgrounding and gaps.**~~ Delivered. `KoreSession.pause()` and
   `resume()` are driven from the dashboard's lifecycle observer. A gap longer
   than one analysis window clears the engine ring and the predictor
   trajectory, requires a full clean window before a frame is believed again,
   and puts a **hole** in the sparkline rather than a line across minutes
   nobody measured. A gap shorter than one window is left alone: every refusal
   costs a two-second settle, and a phone flickering in and out of the
   background would spend its life settling.

   What is still missing is the *record* of the gap beyond the live ring — the
   daily rollup has no way to say a day was half-observed.
6. **`baselineCapturedAt`** and a validity window. A baseline captured
   yesterday, before the patch was re-seated, is not today's baseline, and the
   calibration state has no way to know it is stale.
7. **A protocol identifier on `ResetRecord`.** There is one protocol today. The
   moment there are two, "reset effectiveness" stops being comparable across
   records unless each record says which one it was.

Items 1, 2 and 5 are done, which is what turned the dashboard from an honest
desktop prototype into an honest phone app. The rest — today's bar before it is
written, `strainSince`, `baselineCapturedAt`, a protocol id on `ResetRecord` —
are what turn it into a product someone keeps for a term. `strainSince` is the
one the notification tier waits on, and the notification tier waits on platform
code the project has not taken yet.
