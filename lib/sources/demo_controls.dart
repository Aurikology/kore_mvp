/// The levers a *simulated* source offers and a real one cannot.
///
/// These exist so the whole product - strain, a failing electrode, a dropped
/// radio, recovery after a reset - can be demonstrated and regression-tested
/// with no hardware. That is worth keeping. What is not worth keeping is
/// `KoreSession` being typed against the simulator to reach them, which is
/// what it did: the class held a `SimulatedEegSource`, so the seam that is
/// supposed to make hardware a drop-in was a seam everything downstream
/// reached straight past.
///
/// Splitting them out costs one nullable getter on [EegSource] and buys two
/// things. The session can hold an `EegSource`, so a BLE source really is a
/// drop-in. And the demo panel disappears on a device that has no simulator
/// behind it, rather than shipping a "Simulate detached electrode" button to
/// somebody wearing a real patch.
///
/// Everything here is a *lie about the world*, not a lie about the
/// measurement. The DSP, the index, the quality path and the history are the
/// same code in a demo as in the field; only the physics upstream of them is
/// invented, and the label on screen says so.
abstract class DemoControls {
  /// Whether the scripted demo arc is still driving the load, or a presenter
  /// has taken over.
  bool get followingTimeline;

  /// The simulated cognitive-load scalar, 0-1. Not the index - the thing the
  /// index is trying to recover from the signal.
  double get load;

  /// Drive the load directly. Takes the timeline out of the loop.
  void setLoadTarget(double target, {double? tauSeconds});

  /// Decay the simulated load the way a reset is supposed to.
  ///
  /// This is the one entry here the ordinary reset path calls, and its
  /// nullability is the honest part: on real hardware there is nothing to
  /// call, because recovery is something the user's head does rather than
  /// something the app arranges. The measured uplift is arithmetic over a
  /// simulation until then, and `README.md` says so out loud.
  void applyResetRecovery();

  /// Seat every pad at a fixed coupling, 0 (off the head) to 1 (perfect).
  void setContact(double contact);

  /// Every pad comes off. Not silence - a detached electrode reads as strain,
  /// which is the entire reason the quality path exists.
  void detachElectrode();

  /// Back on the head and seated properly.
  void restoreContact();

  /// Lose [count] samples the way a missed BLE notification loses them.
  void dropSamples(int count);

  /// The radio drops mid-session and starts trying to come back.
  void dropLink();

  /// The radio comes back.
  void restoreLink();
}
