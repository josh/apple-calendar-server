import EventKit
import Foundation

// EventKit runs on the main actor. Each read or write uses a fresh store, kept alive
// until its objects are converted. Only Sendable records leave the main actor.
func statusName() -> String {
  switch EKEventStore.authorizationStatus(for: .event) {
  case .notDetermined: return "notDetermined"
  case .restricted: return "restricted"
  case .denied: return "denied"
  case .fullAccess: return "fullAccess"
  case .writeOnly: return "writeOnly"
  @unknown default: return "unknown"
  }
}
func requireAccess() throws {
  guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
    throw ServerError.internalError(
      "Calendar access is \(statusName()); explicitly request access at startup or grant it in System Settings"
    )
  }
}
@MainActor
func authorizeCalendar() async throws {
  let granted: Bool
  do { granted = try await EKEventStore().requestFullAccessToEvents() } catch {
    throw ServerError.internalError(
      "EventKit authorization failed (code \((error as NSError).code))")
  }
  guard granted else { throw ServerError.internalError("Calendar access was not granted") }
  try requireAccess()
}

// Event calendars sorted by identifier, with the store that owns them.
@MainActor
func eventCalendars() throws -> (store: EKEventStore, calendars: [EKCalendar]) {
  try requireAccess()
  let store = EKEventStore()
  let calendars = store.calendars(for: .event).sorted {
    $0.calendarIdentifier < $1.calendarIdentifier
  }
  return (store, calendars)
}
@MainActor
func calendarData(_ store: EKEventStore, _ calendars: [EKCalendar]) throws -> CalendarData {
  let records = try calendars.map(CalendarRecord.init)
  let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier
  return CalendarData(
    calendars: records,
    defaultCalendarId: records.contains(where: { $0.id == defaultID }) ? defaultID : nil)
}
// Calendars and the default calendar, without fetching events.
@MainActor
func readCalendars() throws -> CalendarData {
  let (store, calendars) = try eventCalendars()
  return try withExtendedLifetime(store) { try calendarData(store, calendars) }
}
