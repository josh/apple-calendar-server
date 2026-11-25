import Foundation

// One filter for GraphQL and MCP searches.
enum SortDirection: String, CaseIterable, Decodable, Sendable {
  case ascending = "ASC"
  case descending = "DESC"
}
struct Search: Sendable {
  // Events sort by eventOrder; calendars sort by name when sortCalendarsByName is set.
  var sortCalendarsByName = false
  var direction = SortDirection.ascending
  var query: String?
  var accountIds: [String]?
  // Event criteria. from and before bound the window; each is a timestamp or YYYY-MM-DD.
  var from, before: String?
  var eventOrder: EventSortField?
  var calendarIds: [String]?
  var titleContains: String?
  var allDay, recurring, detached, hasAttendees, hasAlarms: Bool?
  var availabilities: [EventAvailability]?
  var statuses: [EventStatus]?
  var myStatuses: [ParticipantStatus]?
  // Calendar criteria.
  var allowsContentModifications: Bool?
  var subscribed: Bool?

  // The window events must overlap: from defaults to now and before to 30 days later.
  // EventKit silently shortens ranges beyond four years, so a longer span is refused.
  func window(now: Date) throws -> EventWindow {
    let lower = try from.map(parseBound) ?? now
    let upper = try before.map(parseBound) ?? addingLocalDays(30, to: lower)
    guard lower < upper else { throw ServerError.invalidArgument("from must precede before") }
    guard upper.timeIntervalSince(lower) <= Self.maxWindowDays * 86_400 else {
      throw ServerError.invalidArgument(
        "the window from..before must not exceed \(Int(Self.maxWindowDays)) days")
    }
    return EventWindow(from: lower, before: upper)
  }
  static let maxWindowDays: Double = 1096

  // Matching events overlapping the data's window, in the requested order or by start.
  // `scope` restricts the calendar IDs.
  func events(_ data: EventsData, scope: Set<String>? = nil) -> [EventRecord] {
    let window = data.window
    let accountCalendars = accountIds.map { ids in
      Set(data.calendars.calendars.filter { ids.contains($0.source.id) }.map(\.id))
    }
    let text = query?.lowercased()
    let title = titleContains?.lowercased()
    let items = data.events.filter { item in
      // A zero-length event belongs to the window its start falls in.
      guard item.start < window.before, item.end > window.from || item.start >= window.from
      else { return false }
      let itemTitle = (item.title ?? "").lowercased()
      return (accountCalendars == nil || accountCalendars!.contains(item.calendarId))
        && (scope == nil || scope!.contains(item.calendarId))
        && (calendarIds == nil || calendarIds!.contains(item.calendarId))
        && (allDay == nil || allDay == item.allDay)
        && (recurring == nil || recurring == item.recurring)
        && (detached == nil || detached == item.detached)
        && (hasAttendees == nil || hasAttendees == !item.attendees.isEmpty)
        && (hasAlarms == nil || hasAlarms == !item.alarms.isEmpty)
        && (availabilities == nil || availabilities!.contains(item.availability))
        && (statuses == nil || statuses!.contains(item.status))
        && (myStatuses == nil || item.myStatus.map(myStatuses!.contains) == true)
        && (text == nil || text!.isEmpty || itemTitle.contains(text!)
          || (item.notes ?? "").lowercased().contains(text!)
          || (item.location ?? "").lowercased().contains(text!))
        && (title == nil || title!.isEmpty || itemTitle.contains(title!))
    }
    return orderEvents(items, by: eventOrder ?? .startDate, direction: direction)
  }

  // Matching calendars, by name when ordered; `accountID` restricts to one account.
  func calendars(_ data: CalendarData, accountID: String? = nil) -> [CalendarRecord] {
    let text = query?.lowercased()
    var items = data.calendars.filter {
      (accountID == nil || $0.source.id == accountID)
        && (accountIds == nil || accountIds!.contains($0.source.id))
        && (text == nil || text!.isEmpty || $0.name.lowercased().contains(text!))
        && (allowsContentModifications == nil
          || $0.allowsContentModifications == allowsContentModifications)
        && (subscribed == nil || $0.subscribed == subscribed)
    }
    if sortCalendarsByName {
      items.sort {
        let a = $0.name.lowercased()
        let b = $1.name.lowercased()
        return a == b ? $0.id < $1.id : direction == .descending ? a > b : a < b
      }
    }
    return items
  }
}
