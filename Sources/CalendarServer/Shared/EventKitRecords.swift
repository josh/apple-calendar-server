import CoreGraphics
import EventKit
import Foundation

// Convert framework objects on the main actor. Only Sendable value records leave it.
extension EKCalendar {
  // The server's rule for updating or deleting a calendar, also reported to clients.
  var allowsCalendarModifications: Bool {
    !isImmutable && allowsContentModifications && !isSubscribed
  }
}
extension CalendarType {
  init(_ type: EKCalendarType) {
    switch type {
    case .local: self = .local
    case .calDAV: self = .calDAV
    case .exchange: self = .exchange
    case .subscription: self = .subscription
    case .birthday: self = .birthday
    @unknown default: self = .unknown
    }
  }
}
extension CalendarRecord {
  init(_ calendar: EKCalendar) throws {
    // EventKit leaves source nil on a calendar whose account is gone; the IUO would trap.
    guard let source = calendar.source else {
      throw ServerError.internalError("Calendar \(calendar.calendarIdentifier) has no account")
    }
    let color = calendar.cgColor?.converted(
      to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
    let hex = color?.components.flatMap { values -> String? in
      guard values.count == 4 else { return nil }
      return "#"
        + values.map {
          String(format: "%02X", Int((min(1, max(0, $0)) * 255).rounded()))
        }.joined()
    }
    let mask = calendar.supportedEventAvailabilities
    let supported: [(EKCalendarEventAvailabilityMask, EventAvailability)] = [
      (.busy, .busy), (.free, .free), (.tentative, .tentative), (.unavailable, .unavailable),
    ]
    self.init(
      id: calendar.calendarIdentifier, name: calendar.title, color: hex,
      source: SourceRecord(
        id: source.sourceIdentifier, title: source.title, type: source.sourceType.rawValue),
      type: CalendarType(calendar.type),
      allowsContentModifications: calendar.allowsContentModifications,
      allowsCalendarModifications: calendar.allowsCalendarModifications,
      subscribed: calendar.isSubscribed, immutable: calendar.isImmutable,
      supportedAvailabilities: supported.filter { mask.contains($0.0) }.map(\.1))
  }
}
