import Foundation

private let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
func timestamp(_ date: Date) -> String {
  date.formatted(timestampStyle)
}
func parseTimestamp(_ value: String) throws -> Date {
  let pattern =
    #"^\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(\.\d+)?(Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$"#
  guard value.range(of: pattern, options: .regularExpression) != nil else {
    throw ServerError.invalidArgument(
      "expected RFC 3339 timestamp with an explicit offset")
  }
  try validateDay(String(value.prefix(10)))
  // The style accepts any number of fraction digits, or none, as RFC 3339 allows.
  guard let date = try? timestampStyle.parse(value) else {
    throw ServerError.invalidArgument("invalid timestamp")
  }
  return date
}
func validateDay(_ value: String) throws {
  let parts = value.split(separator: "-").map { Int($0) }
  guard value.range(of: #"^\d{4}-\d{2}-\d{2}\z"#, options: .regularExpression) != nil,
    parts.count == 3, let year = parts[0], let month = parts[1], let day = parts[2],
    (1...9999).contains(year),
    DateComponents(year: year, month: month, day: day)
      .isValidDate(in: Calendar(identifier: .gregorian))
  else {
    throw ServerError.invalidArgument("calendar days must be valid Gregorian YYYY-MM-DD")
  }
}

// EventKit returns all-day and floating events in the host zone, so calendar days are
// read and written there.
private var hostCalendar: Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = .current
  return calendar
}
// The host-zone calendar day of an instant, as YYYY-MM-DD.
func localDay(_ date: Date) -> String {
  date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
}
// Midnight in the host zone at the start of a YYYY-MM-DD day.
func startOfLocalDay(_ day: String) throws -> Date {
  try validateDay(day)
  let parts = day.split(separator: "-").compactMap { Int($0) }
  guard
    let date = hostCalendar.date(
      from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
  else { throw ServerError.invalidArgument("calendar day does not resolve in the host zone") }
  return date
}
// A window bound: an RFC 3339 timestamp, or a calendar day meaning its host-zone midnight.
func parseBound(_ value: String) throws -> Date {
  value.contains("T") ? try parseTimestamp(value) : try startOfLocalDay(value)
}
// A whole number of host-zone calendar days from an instant; DST days stay whole days.
func addingLocalDays(_ days: Int, to date: Date) -> Date {
  hostCalendar.date(byAdding: .day, value: days, to: date) ?? date
}
func startOfLocalDay(containing date: Date) -> Date { hostCalendar.startOfDay(for: date) }
// Whole host-zone calendar days from one instant's day to another's; negative when earlier.
func localDays(from: Date, to: Date) -> Int {
  hostCalendar.dateComponents(
    [.day], from: hostCalendar.startOfDay(for: from), to: hostCalendar.startOfDay(for: to)
  ).day ?? 0
}

func orderEvents(_ items: [EventRecord], by field: EventSortField, direction: SortDirection)
  -> [EventRecord]
{
  func compare<T: Comparable>(_ a: T?, _ b: T?) -> Bool? {
    if a == b { return nil }
    guard let a else { return false }
    guard let b else { return true }
    return direction == .descending ? a > b : a < b
  }
  return items.sorted { a, b in
    let result: Bool?
    switch field {
    case .startDate: result = compare(a.start, b.start) ?? compare(a.end, b.end)
    case .endDate: result = compare(a.end, b.end) ?? compare(a.start, b.start)
    case .title: result = compare(a.title?.lowercased(), b.title?.lowercased())
    case .creationDate: result = compare(a.creationDate, b.creationDate)
    case .modificationDate: result = compare(a.modificationDate, b.modificationDate)
    }
    // Ties fall back to start, then identifier, so pages are stable.
    return result ?? (a.start == b.start ? a.id < b.id : a.start < b.start)
  }
}

// The last host-zone day an all-day event covers. An end stored at the following
// midnight is exclusive, so it belongs to the day before.
func lastAllDayDay(start: Date, end: Date) -> String {
  let exclusive = end > start && end == startOfLocalDay(containing: end)
  return localDay(exclusive ? end.addingTimeInterval(-1) : end)
}
