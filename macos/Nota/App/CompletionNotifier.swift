import AppKit
import Foundation
import UserNotifications

/// Posting a completion notification, and nothing else (XIA-435).
///
/// Every *decision* — whether to fire at all, what the title and facts are,
/// whether a retry belongs on it — is made by `CompletionNotifierPolicy` in
/// `BackgroundProcessing.swift`, which a test can reach. This type is the part
/// that needs a notification centre and a running app, kept behind
/// `CompletionNotifying` so the model's completion path can be driven without
/// either.
///
/// The plumbing is the same shape `DictationHUDController` already uses for its
/// HUD-unavailable notice: request authorization lazily, build a
/// `UNMutableNotificationContent`, add it with a `nil` trigger.
@MainActor
protocol CompletionNotifying: AnyObject {
  /// True when Nota is the frontmost application. Asked at the moment the
  /// record lands, never cached: the owner may have switched away during the
  /// summary, which is exactly the case the notification exists for.
  var appIsFrontmost: Bool { get }
  func post(_ notice: CompletionNotice)
}

@MainActor
final class CompletionNotifier: NSObject, CompletionNotifying {
  static let shared = CompletionNotifier()

  /// Identifier prefix; the record id makes each request unique, so a second
  /// post for the same record would replace rather than stack — a second
  /// belt over `ProcessingJob.notified`'s braces.
  private static let identifierPrefix = "com.xiafawu.nota.record."
  /// The category carrying the manual retry action. Registered once, on the
  /// first failure notice that needs it.
  static let failureCategoryID = "com.xiafawu.nota.record.failure"
  static let retryActionID = "com.xiafawu.nota.record.retry-summary"
  /// Where the record id rides so the click handler knows what to open.
  static let recordIDKey = "notaRecordID"

  private var registeredFailureCategory = false

  var appIsFrontmost: Bool { NSApp?.isActive ?? false }

  func post(_ notice: CompletionNotice) {
    Task { await deliver(notice) }
  }

  private func deliver(_ notice: CompletionNotice) async {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    guard let granted = try? await center.requestAuthorization(options: [.alert, .sound]), granted
    else {
      return
    }
    if notice.retry != nil { registerFailureCategoryIfNeeded(on: center) }

    let content = UNMutableNotificationContent()
    // The notification is ABOUT the record, so the record's title is the
    // notification's title and the facts sit underneath it. "Nota finished
    // transcribing" would be a sentence about the app.
    content.title = notice.title
    content.body = notice.body
    content.userInfo = [Self.recordIDKey: notice.recordID]
    if notice.retry != nil { content.categoryIdentifier = Self.failureCategoryID }

    try? await center.add(
      UNNotificationRequest(
        identifier: Self.identifierPrefix + notice.recordID,
        content: content,
        trigger: nil
      )
    )
  }

  private func registerFailureCategoryIfNeeded(on center: UNUserNotificationCenter) {
    guard !registeredFailureCategory else { return }
    registeredFailureCategory = true
    let retry = UNNotificationAction(
      identifier: Self.retryActionID,
      title: "Retry Summary",
      options: []
    )
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: Self.failureCategoryID,
        actions: [retry],
        intentIdentifiers: [],
        options: []
      )
    ])
  }
}

extension CompletionNotifier: UNUserNotificationCenterDelegate {
  /// Show the banner even when Nota is frontmost.
  ///
  /// Without this, macOS routes a foreground app's notification silently to
  /// Notification Center — so the one case the policy now deliberately admits
  /// while frontmost (a record that failed before it wrote any markdown, and
  /// therefore has no drawer row to appear in) would have been posted and never
  /// seen. Everything else is still suppressed by
  /// `CompletionNotifierPolicy.decide` before it ever reaches here; this method
  /// grants no permission the policy has not already given.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }

  /// A click opens the record; the retry action re-runs the summary and only
  /// the summary. Both leave through a `Notification` so the delegate stays
  /// free of any reference to the model.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    let recordID = userInfo[CompletionNotifier.recordIDKey] as? String
    let isRetry = response.actionIdentifier == CompletionNotifier.retryActionID
    Task { @MainActor in
      defer { completionHandler() }
      guard let recordID else { return }
      NotificationCenter.default.post(
        name: isRetry ? .notaRetryRecordSummary : .notaOpenRecord,
        object: recordID
      )
      if !isRetry { NSApp.activate(ignoringOtherApps: true) }
    }
  }
}

extension Notification.Name {
  /// A completion notification was clicked: open this record id.
  static let notaOpenRecord = Notification.Name("NotaOpenRecord")
  /// A failure notification's Retry Summary was pressed for this record id.
  static let notaRetryRecordSummary = Notification.Name("NotaRetryRecordSummary")
}
