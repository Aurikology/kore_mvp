/// What is wrong with the signal, when something is.
///
/// A set rather than a single worst-fault, because the answers to "what do I
/// do about it" are different and a user with two problems needs both. Poor
/// contact is fixed by pressing the band down; a dropout is fixed by moving
/// closer to the phone; neither is fixed by the other's instruction.
enum SignalFault {
  /// Electrode-skin coupling has degraded, but the electrode is still on.
  poorContact,

  /// Coupling has collapsed. This is the dangerous one: a dry electrode coming
  /// off does not go quiet, it produces a large sub-alpha artifact while the
  /// physiological signal fades - theta up, alpha down, which is exactly the
  /// signature the Cognitive Load Index is built to read as strain.
  electrodeDetached,

  /// Samples the device produced never reached the app. The analysis window
  /// they belong to is spliced rather than gapped, and a Hann-windowed
  /// Goertzel turns that discontinuity into broadband splatter landing in both
  /// bands at once.
  dropout,

  /// The device is not sampling at the rate the DSP was built against. The
  /// 60 Hz notch is Q = 20 and detunes fast, and every frame-counted constant
  /// in the index and the predictor assumes exactly 4 frames per second.
  sampleRateDrift,

  /// The fault has cleared but the analysis window still contains samples from
  /// while it had not. Raised by `SignalQualityGate`, never by a source: a
  /// source reports on the samples it just sent, and only the analysis knows
  /// how long they keep mattering.
  settling,
}

/// How much of the signal can be believed. Worst fault wins.
enum SignalQualityLevel {
  /// Nothing wrong that the source can see.
  good,

  /// Still a measurement of the user, but something is going wrong and they
  /// should be told before it stops being one. Readings still publish.
  degraded,

  /// Not a measurement of the user. Nothing derived from it may be published,
  /// recorded, or learned from.
  unusable,
}

/// How one electrode's contact reads, as a word.
///
/// The word exists because colour may never be the only channel carrying a
/// state - see `docs/design/DESIGN.md`. It matters more here than on the
/// gauge: the two warm ramp stops a contact chip would otherwise rely on
/// separate by only dE 4.0 under deuteranopia, so the redundant word is
/// load-bearing rather than a courtesy.
enum ElectrodeContactState {
  /// Coupling is not the limiting factor on the reading.
  good,

  /// Still coupled, but degrading. The user is told before it stops being a
  /// measurement of them.
  weak,

  /// Coupling has collapsed. Not silence - a dry electrode coming off produces
  /// a large sub-alpha artifact that reads as strain.
  noContact,

  /// This electrode has no contact measurement at all.
  ///
  /// Deliberately distinct from [good]. A device with no impedance front end
  /// must not have its silence rendered as health - absence of evidence is not
  /// evidence of a fault, and it is not evidence of health either.
  unmeasured,
}

/// One electrode's contact, named the way the person wearing it would name it.
///
/// Naming is a product decision, not a cosmetic one. The first generated pass
/// at the pairing screen labelled these FP1/FPZ/T3/T4, which reads as clinical
/// instrumentation and cuts directly against a positioning that is explicitly
/// not a medical device. Labels here are positional and lay - "Left pad" - and
/// are meant to be resolved against the placement diagram rather than
/// memorised.
///
/// Note that electrodes are *not* data channels. The analysis consumes a
/// single channel; how many electrodes produce it is a property of the device.
/// Indexing contact by data-channel position would make any electrode that
/// does not carry its own channel unrepresentable.
class ElectrodeContact {
  /// Stable machine key, e.g. `left`. Never shown to anyone.
  final String id;

  /// User-facing name. Positional and lay, never a 10-20 designator.
  final String label;

  /// Electrode-skin coupling, 0 (off the head) to 1 (perfect), or null when
  /// this electrode has no way to be measured.
  ///
  /// Nullable per electrode, not merely per device: a patch may measure
  /// impedance on some pads and not others, and fabricating 1.0 for the rest
  /// is the same lie the aggregate field refuses to tell.
  final double? contact;

  /// Measured impedance for this electrode, when available. Informational -
  /// it never gates anything, for the same reason the aggregate does not.
  final double? impedanceKOhm;

  const ElectrodeContact({
    required this.id,
    required this.label,
    required this.contact,
    this.impedanceKOhm,
  });

  bool get isMeasured => contact != null;

  /// This electrode's banded state, against the same constants the aggregate
  /// is banded by - there is only one definition of "good contact".
  ElectrodeContactState get state {
    final c = contact;
    if (c == null) return ElectrodeContactState.unmeasured;
    if (c < SignalQuality.kContactDetached) return ElectrodeContactState.noContact;
    if (c < SignalQuality.kContactGood) return ElectrodeContactState.weak;
    return ElectrodeContactState.good;
  }

  /// Whether this electrode is what is stopping the signal being trusted.
  bool get needsAttention =>
      state == ElectrodeContactState.weak ||
      state == ElectrodeContactState.noContact;

  @override
  String toString() {
    final c = contact == null ? 'unmeasured' : contact!.toStringAsFixed(2);
    return 'ElectrodeContact($id, $c, ${state.name})';
  }
}

/// A live report from an [EegSource] on whether its signal is worth believing.
///
/// This is the type that closes KORE's most dangerous gap. Every other part of
/// the pipeline reasons about *how loaded* the user is; this one reasons about
/// whether there is a user in the reading at all, and the two are orthogonal -
/// a detached electrode produces a perfectly plausible strain reading.
///
/// Three design decisions are what make it survivable by real hardware rather
/// than shaped around what the simulator finds easy:
///
/// - **Every measurement is nullable when it cannot be taken.** A front end
///   with no impedance channel reports `contact: null`, not a fabricated 1.0.
///   Inventing a perfect score for a device that cannot measure one is the
///   same lie in a different place.
/// - **Raw measurements, banded separately.** [contact], [impedanceKOhm],
///   [droppedSamples] and [measuredRateHz] are what a device reports;
///   [level] and [faults] are policy derived from them. A device that learns
///   to measure something new adds a field, not a meaning.
/// - **It describes a moment, not a session.** Quality is re-reported with
///   every block, so a headband that slips at minute forty is caught. A
///   one-time impedance check at start-up would pass and then be wrong for an
///   hour.
class SignalQuality {
  // --- Banding. Kept named and at the top for the same reason as the index's
  // tuning constants: these are what you retune against a real electrode. ---

  /// Above this, coupling is not the limiting factor on the reading.
  static const double kContactGood = 0.60;

  /// Below this the reading stops being about the user. Between the two the
  /// signal is still usable and the user is warned.
  static const double kContactUsable = 0.35;

  /// Below this the electrode is off, not merely loose - a distinction that
  /// exists because it changes what the user is told to do.
  static const double kContactDetached = 0.15;

  /// Fractional rate error the analysis tolerates. At 1% the mains sits 0.6 Hz
  /// off the centre of a Q = 20 notch - a fifth of its bandwidth - and the
  /// frame rate the index's EMA and dwell counters are denominated in is no
  /// longer 4 Hz.
  static const double kRateDriftDegraded = 0.01;

  /// Beyond this the notch has effectively stopped notching and the frame-count
  /// constants describe a different clock.
  static const double kRateDriftUnusable = 0.03;

  /// Electrode-skin coupling, 0 (off the head) to 1 (perfect), or null when
  /// the source has no way to measure it.
  ///
  /// A proxy, not a physical quantity: a front end that measures impedance
  /// derives this from it, one that only has a contact comparator reports the
  /// two ends of the scale, and one that has neither reports null.
  final double? contact;

  /// Measured electrode impedance in kilohms, when the front end can measure
  /// it. Informational only - it never gates anything, because the mapping
  /// from impedance to usable signal is electrode chemistry and belongs to the
  /// device, which is why [contact] exists. Carried so a real measurement has
  /// somewhere to live other than being scaled into [contact] and lost.
  final double? impedanceKOhm;

  /// Samples the device produced that never arrived, immediately before the
  /// block this report describes.
  ///
  /// Counted from device-side sample indices, so it is exact rather than
  /// inferred from arrival times - which is the entire reason [SampleBlock]
  /// carries `firstSampleIndex`.
  final int droppedSamples;

  /// The rate the device is actually sampling at, as best it can be measured.
  /// Not the nominal one: a real crystal runs at 255.7 Hz and drifts with
  /// temperature.
  final double measuredRateHz;

  /// The rate the device claims, and the one the DSP was built against.
  final double nominalRateHz;

  /// Per-electrode contact, when the device reports it. Empty when it does
  /// not, which is not the same as reporting that its electrodes are fine.
  ///
  /// This is the detail [contact] is rolled up from, kept rather than
  /// discarded because the aggregate cannot answer the only question the user
  /// can act on: *which pad*. "Contact is poor" is not an instruction;
  /// "press the left pad down until it reads" is.
  ///
  /// Not indexed by data channel - see [ElectrodeContact].
  final List<ElectrodeContact> electrodes;

  const SignalQuality({
    required this.contact,
    required this.measuredRateHz,
    required this.nominalRateHz,
    this.impedanceKOhm,
    this.droppedSamples = 0,
    this.electrodes = const [],
  });

  /// A report built from per-electrode measurements.
  ///
  /// [contact] is rolled up as the *worst* measured electrode, not an average.
  /// Averaging would let one detached pad be diluted by three good ones, which
  /// is the same shape as the dropout ratio threshold this file already
  /// refuses: a tolerance constant with nothing behind it. There is no such
  /// thing as a harmless detached electrode in a montage the analysis is
  /// summing over.
  ///
  /// Electrodes that cannot be measured are skipped rather than counted as
  /// bad. An unmeasurable pad is not evidence of a fault - and, per [level],
  /// not evidence of health either.
  factory SignalQuality.fromElectrodes({
    required List<ElectrodeContact> electrodes,
    required double measuredRateHz,
    required double nominalRateHz,
    int droppedSamples = 0,
  }) {
    ElectrodeContact? worst;
    for (final e in electrodes) {
      final c = e.contact;
      if (c == null) continue;
      if (worst == null || c < worst.contact!) worst = e;
    }
    return SignalQuality(
      contact: worst?.contact,
      impedanceKOhm: worst?.impedanceKOhm,
      droppedSamples: droppedSamples,
      measuredRateHz: measuredRateHz,
      nominalRateHz: nominalRateHz,
      electrodes: List.unmodifiable(electrodes),
    );
  }

  /// A source behaving perfectly at its nominal rate.
  const SignalQuality.pristine(double rateHz)
      : contact = 1.0,
        impedanceKOhm = null,
        droppedSamples = 0,
        electrodes = const [],
        measuredRateHz = rateHz,
        nominalRateHz = rateHz;

  /// A source that reports nothing about itself.
  ///
  /// Reads as [SignalQualityLevel.good] on purpose - see [level]. It is also
  /// the value a gate holds before the first block arrives, which is why it
  /// must not read as a fault.
  static const SignalQuality unreported = SignalQuality(
    contact: null,
    measuredRateHz: 0,
    nominalRateHz: 0,
  );

  /// Whether the source can measure coupling at all.
  ///
  /// False is not a fault, but nothing downstream may claim the contact was
  /// verified - the UI says "contact not measured", never "contact good".
  bool get contactMeasured => contact != null;

  /// Whether this report carries per-electrode detail at all.
  ///
  /// False means the device did not break contact down, not that it has one
  /// electrode. A UI that wants to name a pad must check this first and fall
  /// back to the undifferentiated wording, rather than inventing a pad name.
  bool get hasPerElectrodeContact => electrodes.isNotEmpty;

  /// The measured electrode limiting the reading, or null when none of them
  /// can be measured.
  ElectrodeContact? get worstElectrode {
    ElectrodeContact? worst;
    for (final e in electrodes) {
      final c = e.contact;
      if (c == null) continue;
      if (worst == null || c < worst.contact!) worst = e;
    }
    return worst;
  }

  /// Every electrode the user could do something about, worst first.
  ///
  /// Unmeasured electrodes are excluded: there is no instruction to give for
  /// a pad whose state is unknown, and listing it under a heading about what
  /// to fix would imply one.
  List<ElectrodeContact> get electrodesNeedingAttention {
    final out = electrodes.where((e) => e.needsAttention).toList()
      ..sort((a, b) => a.contact!.compareTo(b.contact!));
    return List.unmodifiable(out);
  }

  /// Absolute rate error as a fraction of nominal. Zero when the source does
  /// not report a rate, since an unmeasured clock cannot be shown to drift.
  double get rateDriftFraction {
    if (nominalRateHz <= 0 || measuredRateHz <= 0) return 0;
    return (measuredRateHz - nominalRateHz).abs() / nominalRateHz;
  }

  /// Everything wrong with the signal right now. Empty when nothing is.
  Set<SignalFault> get faults {
    final out = <SignalFault>{};

    final c = contact;
    if (c != null && c < kContactGood) {
      out.add(c < kContactDetached
          ? SignalFault.electrodeDetached
          : SignalFault.poorContact);
    }

    if (droppedSamples > 0) out.add(SignalFault.dropout);
    if (rateDriftFraction > kRateDriftDegraded) {
      out.add(SignalFault.sampleRateDrift);
    }

    return out;
  }

  /// The verdict on the samples this report describes, worst fault wins.
  ///
  /// It is the *source's* view, so it stops at the block boundary. How long a
  /// fault keeps disqualifying analysis frames after it clears is a question
  /// about the 2 s window, which the source knows nothing about, and belongs
  /// to `SignalQualityGate`.
  ///
  /// A source that measures nothing reads [SignalQualityLevel.good]. That is a
  /// deliberate call and the one place this type gives ground: withholding
  /// every reading from a device without an impedance front end would mean
  /// KORE simply does not run on it. The honest position is that absence of
  /// evidence is not evidence of a fault - and [contactMeasured] is what stops
  /// it being sold as evidence of health.
  SignalQualityLevel get level {
    var worst = SignalQualityLevel.good;

    void at(SignalQualityLevel l) {
      if (l.index > worst.index) worst = l;
    }

    final c = contact;
    if (c != null) {
      if (c < kContactUsable) {
        at(SignalQualityLevel.unusable);
      } else if (c < kContactGood) {
        at(SignalQualityLevel.degraded);
      }
    }

    // Any gap at all, not a ratio: there is no such thing as a harmless splice
    // inside a 2 s analysis window. How long a single gap keeps disqualifying
    // frames is the gate's business, not this record's.
    if (droppedSamples > 0) at(SignalQualityLevel.unusable);

    final drift = rateDriftFraction;
    if (drift > kRateDriftUnusable) {
      at(SignalQualityLevel.unusable);
    } else if (drift > kRateDriftDegraded) {
      at(SignalQualityLevel.degraded);
    }

    return worst;
  }

  /// Whether a reading taken from this signal may be published at all.
  ///
  /// Note that publishing and *calibrating* have different bars: a degraded
  /// signal costs one reading, but a baseline captured from one is the
  /// reference every reading for the rest of the session is measured against.
  /// That stricter test is `SignalQualityGate.isBaselineGrade`, because it is
  /// the gate that knows about the analysis window.
  bool get isUsable => level != SignalQualityLevel.unusable;

  @override
  String toString() {
    final c = contact == null ? 'unmeasured' : contact!.toStringAsFixed(2);
    return 'SignalQuality(${level.name}, contact=$c, '
        'dropped=$droppedSamples, '
        'rate=${measuredRateHz.toStringAsFixed(2)}Hz, '
        'faults=${faults.map((f) => f.name).join('+')})';
  }
}
