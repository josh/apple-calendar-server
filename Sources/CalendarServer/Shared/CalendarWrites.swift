import CoreGraphics
import EventKit
import Foundation

struct CalendarChanges: Sendable {
  var name: String?
  var color: [Double]?
}
enum CalendarWrite: Sendable {
  case create(accountID: String, changes: CalendarChanges)
  case update(id: String, changes: CalendarChanges)
}
struct DeleteResult: Encodable, Sendable {
  let deletedId: String
  enum CodingKeys: String, CodingKey { case deletedId }
}

// An event calendar by identifier; nil when absent or not an event calendar.
@MainActor
func eventCalendar(_ store: EKEventStore, id: String) -> EKCalendar? {
  guard let calendar = store.calendar(withIdentifier: id),
    calendar.allowedEntityTypes.contains(.event)
  else { return nil }
  return calendar
}
// Resolve a supplied name exactly, ignoring case; never fall back to the default.
@MainActor
func eventCalendar(_ store: EKEventStore, named name: String) throws -> EKCalendar {
  let matches = store.calendars(for: .event).filter {
    $0.title.compare(name, options: .caseInsensitive) == .orderedSame
  }
  guard let match = matches.first else {
    throw ServerError.notFound("no calendar matches calendarName")
  }
  guard matches.count == 1 else {
    throw ServerError.invalidArgument("calendarName matches multiple calendars; use calendarId")
  }
  return match
}

@MainActor
func executeCalendarWrite(_ request: CalendarWrite) throws -> CalendarRecord {
  try requireAccess()
  let store = EKEventStore()
  let calendar: EKCalendar
  let patch: CalendarChanges
  switch request {
  case .create(let accountID, let changes):
    guard let source = store.sources.first(where: { $0.sourceIdentifier == accountID }) else {
      throw ServerError.notFound("account is unavailable")
    }
    guard changes.name != nil else {
      throw ServerError.invalidArgument("calendar name must not be blank")
    }
    calendar = EKCalendar(for: .event, eventStore: store)
    calendar.source = source
    patch = changes
  case .update(let id, let changes):
    calendar = try editableCalendar(store, id: id)
    patch = changes
  }
  if let name = patch.name {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ServerError.invalidArgument("calendar name must not be blank")
    }
    calendar.title = name
  }
  if let color = patch.color {
    guard
      let calendarColor = CGColor(
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: color.map { CGFloat($0) })
    else { throw ServerError.invalidArgument("invalid calendar color") }
    calendar.cgColor = calendarColor
  }
  do { try store.saveCalendar(calendar, commit: true) } catch {
    throw ServerError.writeFailed(
      "EventKit calendar save failed (code \((error as NSError).code)); refetch before retrying"
    )
  }
  let id = calendar.calendarIdentifier
  store.reset()
  guard let refreshed = store.calendar(withIdentifier: id) else {
    throw ServerError.writeApplied("calendar \(id) was saved but is unavailable for refetch")
  }
  do { return try CalendarRecord(refreshed) } catch {
    throw ServerError.writeApplied("calendar \(id) was saved, but reading it back failed: \(error)")
  }
}

// Events cannot be enumerated for all time, so emptiness is probed from 1970 through ten
// years ahead. An event outside that range is not seen.
private let probeSliceDays = 1095
@MainActor
private func hasEvents(_ store: EKEventStore, in calendar: EKCalendar, now: Date) async throws
  -> Bool
{
  let earliest = Date(timeIntervalSince1970: 0)
  let latest = addingLocalDays(3650, to: now)
  var slices: [EventWindow] = []
  var from = earliest
  while from < latest {
    let before = min(addingLocalDays(probeSliceDays, to: from), latest)
    slices.append(EventWindow(from: from, before: before))
    from = before
  }
  // Nearest first: a calendar in use has events around now.
  slices.sort {
    abs($0.from.timeIntervalSince(now)) < abs($1.from.timeIntervalSince(now))
  }
  for slice in slices {
    var found = false
    store.enumerateEvents(
      matching: store.predicateForEvents(
        withStart: slice.from, end: slice.before, calendars: [calendar])
    ) { _, stop in
      found = true
      stop.pointee = true
    }
    if found { return true }
    // Each slice is one synchronous fetch; let other main-actor work run between them.
    try Task.checkCancellation()
    await Task.yield()
  }
  return false
}

@MainActor
func executeCalendarDelete(id: String, allowNonEmpty: Bool) async throws -> DeleteResult {
  try requireAccess()
  let store = EKEventStore()
  let existing = try editableCalendar(store, id: id)
  if !allowNonEmpty {
    let occupied = try await hasEvents(store, in: existing, now: Date())
    try requireAccess()
    guard eventCalendar(store, id: id) != nil else {
      throw ServerError.internalError("Calendar changed during read; retry")
    }
    guard !occupied else {
      throw ServerError.calendarNotEmpty(
        "pass allowNonEmpty only to intentionally delete the calendar and its events; deleting events you organize can notify their attendees"
      )
    }
  }
  do { try store.removeCalendar(existing, commit: true) } catch {
    throw ServerError.writeFailed(
      "EventKit calendar deletion failed (code \((error as NSError).code)); refetch before retrying"
    )
  }
  return DeleteResult(deletedId: id)
}

@MainActor
private func editableCalendar(_ store: EKEventStore, id: String) throws -> EKCalendar {
  guard let calendar = eventCalendar(store, id: id) else {
    throw ServerError.notFound("calendar is unavailable")
  }
  guard calendar.allowsCalendarModifications else {
    throw ServerError.readOnly("calendar is not editable")
  }
  return calendar
}
