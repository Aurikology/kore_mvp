/// The state of the link to whatever is producing samples.
///
/// `EegSource.start()` returns a `Future<void>` that either completes or
/// throws, and that is the wrong shape for a radio: a BLE link scans,
/// connects, negotiates, subscribes, drops, and reconnects, and the user needs
/// to see all of it. The future still means what it meant - acquisition is
/// running when it completes - but the states it passes through on the way are
/// published here rather than being invisible inside it.
///
/// Written now, with exactly one implementation behind the seam, for the same
/// reason the rest of `EegSource` was: changing it later costs a rewrite of
/// everything that reads it. See `docs/hardware-seam.md`.
library;

enum SourceLinkState {
  /// Nothing has been asked for yet, or the link has been stopped.
  idle,

  /// Looking for a device. No device is known yet, so there is nothing to
  /// name on screen except the search itself.
  scanning,

  /// A device has been found and is being connected to. This is the first
  /// state that can carry a [PatchIdentity].
  connecting,

  /// Connected and delivering samples. The only state in which a reading on
  /// screen is a live measurement.
  streaming,

  /// Was streaming, is not now, and is trying to get back. Distinct from
  /// [connecting] because the app already has a baseline, a history, and a
  /// number on screen - it is resuming, not starting.
  reconnecting,

  /// Gave up. Carries a reason, because "failed" alone gives the user nothing
  /// to act on.
  failed,
}

extension SourceLinkStateX on SourceLinkState {
  /// Whether samples are arriving right now.
  bool get isLive => this == SourceLinkState.streaming;

  /// Whether the link is mid-flight - the states a screen renders as a wait
  /// rather than as a result.
  bool get isBusy =>
      this == SourceLinkState.scanning ||
      this == SourceLinkState.connecting ||
      this == SourceLinkState.reconnecting;
}

/// What the app knows about the device on the other end.
///
/// Separate from the state because identity outlives a transition: a patch
/// that drops still has a name and a battery level while it reconnects, and a
/// screen that blanked them during the outage would read as a lost device.
class PatchIdentity {
  /// Shown to the user. A simulated patch must say so here - the badge rule in
  /// the dashboard applies to every surface, and a pairing screen is the
  /// easiest place in the product to imply hardware that is not attached.
  final String name;

  /// 0-100, or null when the device cannot report it.
  ///
  /// Nullable for the same reason `SignalQuality.contact` is: a front end with
  /// no battery characteristic reports nothing, and a fabricated 100% is a
  /// worse answer than an absent one. A screen must render the null case as
  /// "not reported", never as full.
  final int? batteryPercent;

  const PatchIdentity({required this.name, this.batteryPercent});

  bool get batteryMeasured => batteryPercent != null;

  /// Whether the battery is low enough that it is worth saying so before a
  /// session starts. Unmeasured batteries are never low - absence of a
  /// measurement is not a measurement.
  bool get batteryLow => batteryPercent != null && batteryPercent! <= 15;

  @override
  String toString() =>
      'PatchIdentity($name, battery: ${batteryPercent ?? "not reported"})';
}

/// The link as one value: where it is, and what it is connected to.
///
/// One object rather than a bare enum plus a separate identity getter, so a
/// listener cannot observe a state and an identity that disagree - the pairing
/// screen renders both together and reads them from a single event.
class SourceLink {
  final SourceLinkState state;

  /// Null until a device has been found.
  final PatchIdentity? patch;

  /// Why the link failed, in words a user can act on. Null unless [state] is
  /// [SourceLinkState.failed].
  final String? failure;

  const SourceLink({required this.state, this.patch, this.failure});

  static const SourceLink idle = SourceLink(state: SourceLinkState.idle);

  bool get isLive => state.isLive;

  bool get isBusy => state.isBusy;

  /// Whether the app has ever had this device connected - the difference
  /// between "connecting" and "reconnecting" from the screen's point of view.
  bool get hasPatch => patch != null;

  SourceLink copyWith({
    SourceLinkState? state,
    PatchIdentity? patch,
    String? failure,
  }) =>
      SourceLink(
        state: state ?? this.state,
        patch: patch ?? this.patch,
        failure: failure,
      );

  @override
  String toString() => 'SourceLink(${state.name}'
      '${patch == null ? '' : ', ${patch!.name}'}'
      '${failure == null ? '' : ', $failure'})';
}
