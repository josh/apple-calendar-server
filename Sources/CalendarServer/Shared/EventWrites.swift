import AppKit
import CoreLocation
import EventKit
import Foundation

enum AlarmTrigger: Equatable, Sendable {
  case absolute(Date)
  case relative(Double)
}
struct AlarmChange: Equatable, Sendable {
  let trigger: AlarmTrigger
  let soundName: String?
  let emailAddress: String?
}
struct StructuredLocationChange: Equatable, Sendable {
  let title: String
  let latitude, longitude, radius: Double
}
// Nil parts keep the stored value: a new start alone moves the event, a new end resizes it.
enum EventDatesChange: Equatable, Sendable {
  case timed(start: Date?, end: Date?)
  case allDay(start: String?, end: String?)
}
struct EventChanges: Equatable, Sendable {
  var calendarId: String?
  var calendarName: String?
  var title: String?
  var notes: String?
  var location: String?
  var structuredLocation: StructuredLocationChange?
  var url: URL?
  var dates: EventDatesChange?
  var timeZone: TimeZone?
  var availability: EventAvailability?
  var alarms: [AlarmChange]?
  var recurrence: RecurrenceChange?
  var clear: Set<EventClearValue> = []
}
enum EventWrite: Sendable {
  case create(changes: EventChanges)
  case update(id: String, changes: EventChanges, span: EventSpan?, allowAttendeeNotifications: Bool)
}

// How far a write to the named event reaches. An occurrence id needs an explicit span; a
// series id means the whole series, saved from its first occurrence onward.
@MainActor
private func writeSpan(_ event: EKEvent, id: String, requested: EventSpan?) throws -> EKSpan {
  guard event.isSeriesMember else { return .thisEvent }
  guard parseEventID(id).key != nil else {
    guard requested != .thisEvent else {
      throw ServerError.invalidArgument(
        "a series id names the whole repeating event; use an occurrence id with THIS_EVENT")
    }
    return .futureEvents
  }
  switch requested {
  case .thisEvent: return .thisEvent
  case .futureEvents: return .futureEvents
  case nil:
    throw ServerError.spanRequired(
      "this is one occurrence of a repeating event; pass span THIS_EVENT for only it or FUTURE_EVENTS for it and later occurrences"
    )
  }
}
// Changing or deleting an event with attendees can make its provider send them updates
// or cancellations, so the caller must say that is intended.
@MainActor
private func requireAttendeeConsent(_ event: EKEvent, allowed: Bool) throws {
  guard !event.hasAttendees || allowed else {
    throw ServerError.hasAttendees(
      "this event has attendees, who may be notified of the change; pass allowAttendeeNotifications to proceed"
    )
  }
}
@MainActor
private func editableEvent(_ store: EKEventStore, id: String) throws -> EKEvent {
  guard let event = try resolveEvent(store, id: id) else {
    throw ServerError.notFound("event is unavailable")
  }
  guard let calendar = event.calendar, calendar.allowsContentModifications else {
    throw ServerError.readOnly("the event's calendar is not editable")
  }
  return event
}
@MainActor
private func destinationCalendar(_ store: EKEventStore, _ patch: EventChanges) throws
  -> EKCalendar?
{
  let calendar: EKCalendar
  if let id = patch.calendarId {
    guard let found = eventCalendar(store, id: id) else {
      throw ServerError.notFound("calendar is unavailable")
    }
    calendar = found
  } else if let name = patch.calendarName {
    calendar = try eventCalendar(store, named: name)
  } else {
    return nil
  }
  guard calendar.allowsContentModifications else {
    throw ServerError.readOnly("calendar is not editable")
  }
  return calendar
}
// All-day events are stored from host-zone midnight through the last second of their last day.
@MainActor
private func setAllDay(_ event: EKEvent, start: String, end: String) throws {
  guard start <= end else {
    throw ServerError.invalidArgument("allDayStartDate must not be later than allDayEndDate")
  }
  event.isAllDay = true
  event.timeZone = nil
  event.startDate = try startOfLocalDay(start)
  event.endDate = addingLocalDays(1, to: try startOfLocalDay(end)).addingTimeInterval(-1)
}

// Writes honor EventKit authorization and the destination calendar's capabilities.
// Everything is validated and applied to a store of its own, so a rejected change is
// discarded with the store rather than left pending.
@MainActor
func executeEventWrite(_ request: EventWrite) throws -> EventRecord {
  try requireAccess()
  let store = EKEventStore()
  let event: EKEvent
  let patch: EventChanges
  var span = EKSpan.thisEvent
  let creating: Bool
  switch request {
  case .create(let changes):
    patch = changes
    creating = true
    guard
      let calendar = try destinationCalendar(store, changes) ?? store.defaultCalendarForNewEvents
    else {
      throw ServerError.invalidArgument("no default calendar is available; supply calendarId")
    }
    guard calendar.allowsContentModifications else {
      throw ServerError.readOnly("the default calendar is not editable; supply calendarId")
    }
    event = EKEvent(eventStore: store)
    event.calendar = calendar
  case .update(let id, let changes, let requested, let allowAttendeeNotifications):
    patch = changes
    creating = false
    event = try editableEvent(store, id: id)
    span = try writeSpan(event, id: id, requested: requested)
    try requireAttendeeConsent(event, allowed: allowAttendeeNotifications)
    let changesSeries = patch.recurrence != nil || patch.clear.contains(.recurrence)
    if let calendar = try destinationCalendar(store, changes),
      calendar.calendarIdentifier != event.calendar.calendarIdentifier
    {
      guard !event.isSeriesMember || span == .futureEvents else {
        throw ServerError.invalidArgument(
          "one occurrence cannot move to another calendar alone; use FUTURE_EVENTS or the series id"
        )
      }
      event.calendar = calendar
    }
    if changesSeries {
      guard !event.isSeriesMember || span == .futureEvents else {
        throw ServerError.invalidArgument(
          "recurrence belongs to the series; use FUTURE_EVENTS or the series id to change it")
      }
      span = .futureEvents
    }
  }
  if let title = patch.title { event.title = title }
  if let notes = patch.notes { event.notes = notes }
  if patch.clear.contains(.notes) { event.notes = nil }
  if let url = patch.url { event.url = url }
  if patch.clear.contains(.url) { event.url = nil }
  if patch.clear.contains(.location) {
    event.structuredLocation = nil
    event.location = nil
  }
  if let location = patch.location {
    // Drop stored coordinates first: they describe the place being replaced.
    event.structuredLocation = nil
    event.location = location
  }
  if let place = patch.structuredLocation {
    let location = EKStructuredLocation(title: place.title)
    location.geoLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
    location.radius = place.radius
    event.structuredLocation = location
  }
  switch patch.dates {
  case .timed(let start, let end):
    if creating || event.isAllDay {
      guard let start, let end else {
        throw ServerError.invalidArgument(
          "making an all-day event timed requires both startDate and endDate")
      }
      event.isAllDay = false
      event.startDate = start
      event.endDate = end
      if creating || event.timeZone == nil { event.timeZone = patch.timeZone ?? .current }
    } else {
      let duration = event.endDate.timeIntervalSince(event.startDate)
      if let start {
        event.startDate = start
        event.endDate = end ?? start.addingTimeInterval(duration)
      } else if let end {
        event.endDate = end
      }
    }
  case .allDay(let start, let end):
    if creating || !event.isAllDay {
      guard let start else {
        throw ServerError.invalidArgument("making a timed event all-day requires allDayStartDate")
      }
      try setAllDay(event, start: start, end: end ?? start)
    } else {
      let firstDay = localDay(event.startDate)
      let lastDay = lastAllDayDay(start: event.startDate, end: event.endDate)
      let length = localDays(from: event.startDate, to: try startOfLocalDay(lastDay))
      let newStart = start ?? firstDay
      // A new start alone moves the event and keeps its length in days.
      let newEnd =
        try end
        ?? (start == nil
          ? lastDay : localDay(addingLocalDays(length, to: startOfLocalDay(newStart))))
      try setAllDay(event, start: newStart, end: newEnd)
    }
  case nil: break
  }
  guard event.startDate <= event.endDate else {
    throw ServerError.invalidArgument("the event would end before it starts")
  }
  if let zone = patch.timeZone {
    guard !event.isAllDay else {
      throw ServerError.invalidArgument("all-day events are floating; do not supply timeZone")
    }
    event.timeZone = zone
  }
  if patch.clear.contains(.timeZone) { event.timeZone = nil }
  if let availability = patch.availability {
    let wanted: (EKEventAvailability, EKCalendarEventAvailabilityMask)
    switch availability {
    case .busy: wanted = (.busy, .busy)
    case .free: wanted = (.free, .free)
    case .tentative: wanted = (.tentative, .tentative)
    case .unavailable: wanted = (.unavailable, .unavailable)
    case .notSupported: throw ServerError.invalidArgument("availability cannot be NOT_SUPPORTED")
    }
    guard event.calendar.supportedEventAvailabilities.contains(wanted.1) else {
      throw ServerError.unsupportedOperation(
        "the calendar does not store this availability; see its supportedAvailabilities")
    }
    event.availability = wanted.0
  }
  var requestedDelivery: [AlarmRecord] = []
  if let alarms = patch.alarms {
    let made = try alarms.map(makeAlarm)
    event.alarms = made.isEmpty ? nil : made
    requestedDelivery = zip(alarms, made).compactMap {
      $0.soundName != nil || $0.emailAddress != nil ? AlarmRecord($1) : nil
    }
  }
  if let recurrence = patch.recurrence { event.recurrenceRules = [recurrence.eventKitRule()] }
  if patch.clear.contains(.recurrence) { event.recurrenceRules = nil }
  // Saving an event with nothing to save reports failure without an error; skip it.
  if creating || event.hasChanges {
    do { try store.save(event, span: span, commit: true) } catch {
      throw ServerError.writeFailed(
        "EventKit save failed (code \((error as NSError).code)); refetch before retrying"
      )
    }
  }
  let saved: EventRecord
  do { saved = try EventRecord(event) } catch {
    throw ServerError.writeApplied(
      "EventKit saved the event, but reading it back failed: \(error). Search its calendar before retrying"
    )
  }
  // Providers can drop sound and email delivery; confirm against what was stored.
  if !requestedDelivery.isEmpty {
    store.reset()
    guard let refreshed = try? resolveEvent(store, id: saved.id) else {
      throw ServerError.writeApplied(
        "event \(saved.id) was saved but is unavailable for verification; refetch before retrying"
      )
    }
    try verifyAlarmDelivery(
      requestedDelivery, stored: (refreshed.alarms ?? []).map(AlarmRecord.init), id: saved.id)
    do { return try EventRecord(refreshed) } catch {
      throw ServerError.writeApplied(
        "event \(saved.id) was saved, but reading it back failed: \(error). Refetch before retrying"
      )
    }
  }
  return saved
}

@MainActor
func makeAlarm(_ value: AlarmChange) throws -> EKAlarm {
  let alarm: EKAlarm
  switch value.trigger {
  case .absolute(let date): alarm = EKAlarm(absoluteDate: date)
  case .relative(let offset): alarm = EKAlarm(relativeOffset: offset)
  }
  if let sound = value.soundName {
    guard NSSound(named: NSSound.Name(sound)) != nil else {
      throw ServerError.invalidArgument("soundName must name an available system sound")
    }
    alarm.soundName = sound
  }
  if let email = value.emailAddress { alarm.emailAddress = email }
  return alarm
}

// Compare triggers and delivery settings. A sound can accompany a display or audio action.
func verifyAlarmDelivery(_ requested: [AlarmRecord], stored: [AlarmRecord], id: String) throws {
  var unmatched = stored
  for alarm in requested {
    let index = unmatched.firstIndex {
      let actionMatches =
        alarm.soundName != nil
        ? ["display", "audio"].contains($0.action) : $0.action == alarm.action
      return actionMatches && $0.soundName == alarm.soundName
        && $0.emailAddress == alarm.emailAddress
        && $0.absoluteDate == alarm.absoluteDate && $0.relativeOffset == alarm.relativeOffset
    }
    guard let index else {
      throw ServerError.writeApplied(
        "event \(id) was saved, but the provider did not retain the requested alarm delivery; refetch this ID before retrying"
      )
    }
    unmatched.remove(at: index)
  }
}

@MainActor
func executeEventDelete(id: String, span requested: EventSpan?, allowAttendeeNotifications: Bool)
  throws -> DeleteResult
{
  try requireAccess()
  let store = EKEventStore()
  let event = try editableEvent(store, id: id)
  let span = try writeSpan(event, id: id, requested: requested)
  try requireAttendeeConsent(event, allowed: allowAttendeeNotifications)
  do { try store.remove(event, span: span, commit: true) } catch {
    throw ServerError.writeFailed(
      "EventKit delete failed (code \((error as NSError).code)); refetch before retrying"
    )
  }
  return DeleteResult(deletedId: id)
}
