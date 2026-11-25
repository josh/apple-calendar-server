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

// More candidates than this in one window is refused rather than held in memory.
private let maxEventCandidates = 20_000

// Events overlapping the window in the selected calendars; nil selections mean every
// calendar. predicateForEvents expands repeating events into their occurrences. The fetch
// is synchronous, so it stops between events once the request is cancelled.
@MainActor
func readEvents(
  window: EventWindow, calendarIds: [String]? = nil, accountIds: [String]? = nil
) throws -> EventsData {
  let (store, available) = try eventCalendars()
  return try withExtendedLifetime(store) {
    let data = try calendarData(store, available)
    let calendars = available.filter {
      (calendarIds == nil || calendarIds!.contains($0.calendarIdentifier))
        && (accountIds == nil || accountIds!.contains($0.source.sourceIdentifier))
    }
    // An empty calendar array can mean all calendars to EventKit; never fetch it.
    guard !calendars.isEmpty else { return EventsData(calendars: data, events: [], window: window) }
    // Exact bounds are applied by Search. Fetch a superset so native endpoint
    // inclusivity cannot lose a match.
    let predicate = store.predicateForEvents(
      withStart: window.from.addingTimeInterval(-1), end: window.before.addingTimeInterval(1),
      calendars: calendars)
    var fetched: [EKEvent] = []
    var cancelled = false
    store.enumerateEvents(matching: predicate) { event, stop in
      fetched.append(event)
      cancelled = Task.isCancelled
      if cancelled || fetched.count > maxEventCandidates { stop.pointee = true }
    }
    if cancelled { throw CancellationError() }
    guard fetched.count <= maxEventCandidates else {
      throw ServerError.resultTooLarge(
        "More than \(maxEventCandidates) events overlap this window; narrow from/before or select calendars"
      )
    }
    serverLogger.debug(
      "Read event candidates",
      metadata: ["calendars": "\(calendars.count)", "events": "\(fetched.count)"])
    return EventsData(calendars: data, events: try fetched.map(EventRecord.init), window: window)
  }
}
// EventKit objects lose their calendar and account once their store is released, so each
// read keeps its store alive until the record is built.
@MainActor
func readEvent(id: String) throws -> EventRecord? {
  try requireAccess()
  let store = EKEventStore()
  return try withExtendedLifetime(store) {
    try resolveEvent(store, id: id).map(EventRecord.init)
  }
}
