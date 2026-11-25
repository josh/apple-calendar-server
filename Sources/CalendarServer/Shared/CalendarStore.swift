import EventKit
import Foundation

import struct os.OSAllocatedUnfairLock

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
// A process that was granted full access keeps reporting it after the user reduces the
// grant in System Settings, and EventKit then answers without failing: under Add Only it
// shows one placeholder calendar, and under No Access it shows no calendars at all. With
// real access Calendar always has at least one calendar, so either view means the grant
// is gone.
private let placeholderCalendarID = "VIRTUAL_APP_CALENDAR_UUID"
private let settingsPath = "System Settings > Privacy & Security > Calendars"
private let addOnlyMessage =
  "Calendar access is add-only, and this server needs Full Access to read or change events; change it in \(settingsPath)"
private let removedMessage =
  "macOS shows this server no calendars although it was granted Full Access, so access was probably removed while it was running; allow Full Access in \(settingsPath)"
private let sawReducedAccess = OSAllocatedUnfairLock(initialState: false)
// Updated each time a store is opened, so it can lag a change by one request or collection.
var hasFullAccess: Bool {
  EKEventStore.authorizationStatus(for: .event) == .fullAccess
    && !sawReducedAccess.withLock { $0 }
}
// Every read and write needs full access: add-only access cannot read calendars or
// existing events. The message says how to fix the state macOS reports.
func requireAccess() throws {
  let settings = settingsPath
  let problem: String
  switch EKEventStore.authorizationStatus(for: .event) {
  case .fullAccess: return
  case .writeOnly: problem = addOnlyMessage
  case .denied:
    problem = "Calendar access is denied; allow Full Access in \(settings)"
  case .restricted:
    problem = "Calendar access is restricted on this Mac, for example by a profile or Screen Time"
  case .notDetermined:
    problem =
      "Calendar access has not been requested; set \(ConfigVariable.requestAccess.rawValue)=1 in the launchd plist so the server can ask"
  @unknown default:
    problem = "Calendar access is in a state this server does not recognize; check \(settings)"
  }
  throw ServerError.notAuthorized(problem)
}
// A store for one read or write, after confirming the process can see real calendars.
@MainActor
func openStore() throws -> EKEventStore {
  try requireAccess()
  let store = EKEventStore()
  let calendars = store.calendars(for: .event)
  let problem =
    calendars.contains { $0.calendarIdentifier == placeholderCalendarID }
    ? addOnlyMessage : calendars.isEmpty ? removedMessage : nil
  sawReducedAccess.withLock { $0 = problem != nil }
  if let problem { throw ServerError.notAuthorized(problem) }
  return store
}
// Asks macOS for full access. A refusal is reported, not fatal: the server keeps
// answering, and requireAccess explains the state to each caller.
@MainActor
func authorizeCalendar() async throws {
  let granted: Bool
  do { granted = try await EKEventStore().requestFullAccessToEvents() } catch {
    let native = error as NSError
    throw ServerError.notAuthorized(
      "EventKit authorization failed (\(native.domain) code \(native.code))")
  }
  try requireAccess()
  guard granted else { throw ServerError.notAuthorized("the access request was refused") }
}

// Event calendars sorted by identifier, with the store that owns them.
@MainActor
func eventCalendars() throws -> (store: EKEventStore, calendars: [EKCalendar]) {
  let store = try openStore()
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
  let store = try openStore()
  return try withExtendedLifetime(store) {
    try resolveEvent(store, id: id).map(EventRecord.init)
  }
}
