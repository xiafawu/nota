import Foundation

/// The window's alerts, in the order they were raised (FB-1).
///
/// `ContentView` mounts one alert for the whole window, and it used to hold one
/// value: a report raised while another was still up replaced it, so the owner
/// read the second and never the first — a delete that did not land, say, lost
/// to a refused file opened from Finder a moment later. Now a report that
/// arrives while one is up waits its turn behind it, oldest first.
///
/// An alert equal to one already up or already waiting is dropped: it would
/// say the same thing twice, and one action can reach the model by two routes.
///
/// Pure, so the order is asserted without a window. `NotaModel` asks it what
/// to put on screen and writes the answer in one place.
struct OwnerAlertQueue: Equatable {
  /// The head of the line: on screen, or handed back to go there.
  private(set) var current: OwnerAlert?
  /// Raised while `current` was up, oldest first.
  private(set) var waiting: [OwnerAlert] = []
  /// False only between a dismissal promoting the next alert and that alert
  /// being raised again to go on screen. The promotion happens at once, so a
  /// report raised in between queues behind it rather than jumping ahead.
  private var currentIsUp = false

  /// Raise `alert`. Returns it when it should go on screen now; nil when it
  /// waits its turn or repeats one already up or waiting.
  mutating func raise(_ alert: OwnerAlert) -> OwnerAlert? {
    guard let current else {
      self.current = alert
      currentIsUp = true
      return alert
    }
    if alert == current, !currentIsUp {
      currentIsUp = true
      return alert
    }
    if alert == current || waiting.contains(alert) { return nil }
    waiting.append(alert)
    return nil
  }

  /// The alert on screen was dismissed. Returns the next one, now `current`,
  /// for the caller to raise again once the dismissal has finished; nil when
  /// nothing is waiting — or when nothing was up, so a repeated dismissal
  /// cannot skip the alert that is on its way.
  mutating func dismissCurrent() -> OwnerAlert? {
    guard currentIsUp else { return nil }
    current = waiting.isEmpty ? nil : waiting.removeFirst()
    currentIsUp = false
    return current
  }
}
