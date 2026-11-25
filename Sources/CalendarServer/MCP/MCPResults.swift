import Foundation

// An event as MCP returns it. Clients cannot deselect fields, and a window spans
// calendars the user does not control, so a stored alarm or recurrence the simplified
// form cannot represent is reported in `unsupported` instead of failing the call.
struct MCPEvent: Encodable {
  let record: EventRecord
  let alarms: [AlarmView]?
  let recurrence: RecurrenceView?
  let unsupported: [String]

  init(record: EventRecord) {
    self.record = record
    var unsupported: [String] = []
    alarms = try? record.alarms.map(AlarmView.init)
    if alarms == nil { unsupported.append(CodingKeys.alarms.stringValue) }
    do { recurrence = try recurrenceView(record.recurrenceRules) } catch {
      recurrence = nil
      unsupported.append(CodingKeys.recurrence.stringValue)
    }
    self.unsupported = unsupported
  }

  enum CodingKeys: String, CodingKey {
    case id, seriesId, eventIdentifier, externalId, calendarId, title, notes, location
    case structuredLocation, url, allDay, startDate, endDate, allDayStartDate, allDayEndDate
    case timeZone, occurrenceDate, detached, recurring, availability, status, organizer
    case attendees, myStatus, birthdayContactIdentifier, creationDate, modificationDate
    case rawAlarms, alarms, recurrenceRules, recurrence, unsupported
  }
  // Projected fields are always present, as null when absent; stored optional fields are
  // omitted when absent.
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(record.id, forKey: .id)
    try c.encodeIfPresent(record.seriesId, forKey: .seriesId)
    try c.encode(record.eventIdentifier, forKey: .eventIdentifier)
    try c.encodeIfPresent(record.externalId, forKey: .externalId)
    try c.encode(record.calendarId, forKey: .calendarId)
    try c.encodeIfPresent(record.title, forKey: .title)
    try c.encodeIfPresent(record.notes, forKey: .notes)
    try c.encodeIfPresent(record.location, forKey: .location)
    try c.encodeIfPresent(record.structuredLocation, forKey: .structuredLocation)
    try c.encodeIfPresent(record.url, forKey: .url)
    try c.encode(record.allDay, forKey: .allDay)
    try c.encode(record.startDate, forKey: .startDate)
    try c.encode(record.endDate, forKey: .endDate)
    try c.encode(record.allDayStartDate, forKey: .allDayStartDate)
    try c.encode(record.allDayEndDate, forKey: .allDayEndDate)
    try c.encode(record.timeZone, forKey: .timeZone)
    try c.encodeIfPresent(record.occurrenceDate.map(timestamp), forKey: .occurrenceDate)
    try c.encode(record.detached, forKey: .detached)
    try c.encode(record.recurring, forKey: .recurring)
    try c.encode(record.availability, forKey: .availability)
    try c.encode(record.status, forKey: .status)
    try c.encodeIfPresent(record.organizer, forKey: .organizer)
    try c.encode(record.attendees, forKey: .attendees)
    try c.encodeIfPresent(record.myStatus, forKey: .myStatus)
    try c.encodeIfPresent(record.birthdayContactIdentifier, forKey: .birthdayContactIdentifier)
    try c.encodeIfPresent(record.creationDate.map(timestamp), forKey: .creationDate)
    try c.encodeIfPresent(record.modificationDate.map(timestamp), forKey: .modificationDate)
    try c.encode(record.alarms, forKey: .rawAlarms)
    try c.encode(alarms, forKey: .alarms)
    try c.encode(record.recurrenceRules, forKey: .recurrenceRules)
    try c.encode(recurrence, forKey: .recurrence)
    try c.encode(unsupported, forKey: .unsupported)
  }
}
