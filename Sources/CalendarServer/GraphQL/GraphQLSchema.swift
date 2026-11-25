import Foundation
import GraphQL

// Resolvers receive the Swift record their parent field returned.
func record<Source>(_ source: any Sendable, as _: Source.Type) throws -> Source {
  guard let value = source as? Source else {
    throw ServerError.internalError("Unexpected GraphQL source; expected \(Source.self)")
  }
  return value
}
func field<Source, Value: Sendable>(
  _ type: GraphQLOutputType, _ value: @escaping @Sendable (Source) throws -> Value,
  description: String? = nil
) -> GraphQLField {
  GraphQLField(
    type: type, description: description,
    resolve: { source, _, _, _ in try value(record(source, as: Source.self)) })
}
private func requestContext(_ context: (any Sendable)?) throws -> GraphQLContext {
  guard let context = context as? GraphQLContext else {
    throw ServerError.internalError("Missing GraphQL request context")
  }
  return context
}
private func calendarData(_ context: (any Sendable)?) async throws -> CalendarData {
  try await requestContext(context).calendarData()
}
private func calendarSearchPage(_ data: CalendarData, args: Map, accountID: String? = nil) throws
  -> GraphQLPage<CalendarRecord>
{
  let arguments = try decodeInput(GraphQLCalendarSearch.self, from: args)
  var search = Search()
  if let filter = arguments.filter {
    search.query = filter.query
    search.accountIds = filter.accountIds
    search.allowsContentModifications = filter.allowsContentModifications
    search.subscribed = filter.subscribed
  }
  if let order = arguments.orderBy {
    search.sortCalendarsByName = true
    search.direction = order.direction ?? .ascending
  }
  return try page(
    search.calendars(data, accountID: accountID), limit: arguments.limit, offset: arguments.offset)
}
// A page of events with the window the search resolved, which later pages must repeat.
struct GraphQLEventPage: Sendable {
  let page: GraphQLPage<EventRecord>
  let window: EventWindow
}
private func eventSearchPage(args: Map, context: (any Sendable)?, scope: Set<String>? = nil)
  async throws -> GraphQLEventPage
{
  let context = try requestContext(context)
  let arguments = try decodeInput(GraphQLEventSearch.self, from: args)
  var search = Search()
  search.from = arguments.from
  search.before = arguments.before
  if let filter = arguments.filter {
    search.query = filter.query
    search.titleContains = filter.titleContains
    search.calendarIds = filter.calendarIds
    search.accountIds = filter.accountIds
    search.allDay = filter.allDay
    search.recurring = filter.recurring
    search.detached = filter.detached
    search.hasAttendees = filter.hasAttendees
    search.hasAlarms = filter.hasAlarms
    search.availabilities = filter.availabilities
    search.statuses = filter.statuses
    search.myStatuses = filter.myStatuses
  }
  if let order = arguments.orderBy {
    search.eventOrder = order.field
    search.direction = order.direction ?? .ascending
  }
  // Validate paging before fetching, so a bad limit does not cost a read.
  _ = try page([Int](), limit: arguments.limit, offset: arguments.offset)
  let data = try await context.eventsData(search.window(now: context.now))
  return GraphQLEventPage(
    page: try page(
      search.events(data, scope: scope), limit: arguments.limit, offset: arguments.offset),
    window: data.window)
}
struct PageInfo: Sendable {
  let offset, limit: Int
  let hasNextPage, hasPreviousPage: Bool
}
struct GraphQLPage<Item: Sendable>: Sendable {
  let items: [Item]
  let totalCount: Int
  let pageInfo: PageInfo
}
func page<Item: Sendable>(_ values: [Item], limit: Int, offset: Int) throws -> GraphQLPage<Item> {
  guard (1...100).contains(limit), offset >= 0 else {
    throw ServerError.invalidArgument("limit must be 1...100 and offset must be nonnegative")
  }
  let start = min(offset, values.count)
  let end = min(start + limit, values.count)
  return GraphQLPage(
    items: Array(values[start..<end]), totalCount: values.count,
    pageInfo: PageInfo(
      offset: offset, limit: limit, hasNextPage: end < values.count,
      hasPreviousPage: offset > 0 && !values.isEmpty))
}

// One cache per HTTP execution, shared by item fields and root aliases. A Task
// caches failures as well as successes and coalesces concurrent resolver calls.
actor GraphQLContext {
  // One observation instant per request, so every default window agrees.
  let now = Date()
  func invalidate() {
    calendars = nil
    windows = [:]
    events = [:]
  }
  // Each window is fetched once across all calendars and filtered in memory.
  private var windows: [EventWindow: Task<EventsData, Error>] = [:]
  private var events: [String: Task<EventRecord?, Error>] = [:]
  func eventsData(_ window: EventWindow) async throws -> EventsData {
    if windows[window] == nil {
      windows[window] = Task { try await onMainActor { try readEvents(window: window) } }
    }
    return try await windows[window]!.value
  }
  func event(id: String) async throws -> EventRecord? {
    if events[id] == nil { events[id] = Task { try await onMainActor { try readEvent(id: id) } } }
    return try await events[id]!.value
  }
  private var calendars: Task<CalendarData, Error>?
  func calendarData() async throws -> CalendarData {
    if calendars == nil { calendars = Task { try await onMainActor { try readCalendars() } } }
    return try await calendars!.value
  }
}

func makeSchema() throws -> GraphQLSchema {
  func enumeration(_ name: String, _ values: [String], descriptions: [String: String] = [:])
    throws -> GraphQLEnumType
  {
    try GraphQLEnumType(
      name: name,
      values: GraphQLEnumValueMap(
        uniqueKeysWithValues: values.map {
          ($0, GraphQLEnumValue(value: .string($0), description: descriptions[$0]))
        }))
  }
  let account = try GraphQLObjectType(
    name: "Account",
    fields: [
      "id": field(GraphQLNonNull(GraphQLID), \AccountRecord.id, description: FieldDocs.Account.id),
      "name": field(GraphQLString, \AccountRecord.name, description: FieldDocs.Account.name),
    ])
  let calendarType = try enumeration(
    "CalendarType", CalendarType.allCases.map(\.rawValue),
    descriptions: [
      "LOCAL": "Stored only on this Mac.", "CALDAV": "A CalDAV calendar, including iCloud.",
      "EXCHANGE": "An Exchange calendar.", "SUBSCRIPTION": "A subscribed, read-only feed.",
      "BIRTHDAY": "The Birthdays calendar built from Contacts.",
      "UNKNOWN": "A type this server does not recognize.",
    ])
  let availability = try enumeration(
    "EventAvailability", EventAvailability.allCases.map(\.rawValue),
    descriptions: [
      "NOT_SUPPORTED": "The calendar does not store availability.",
      "BUSY": "Shown as busy.", "FREE": "Shown as free.", "TENTATIVE": "Shown as tentative.",
      "UNAVAILABLE": "Shown as out of office.",
    ])
  let calendar = try GraphQLObjectType(
    name: "Calendar",
    fields: [
      "id": field(
        GraphQLNonNull(GraphQLID), \CalendarRecord.id, description: FieldDocs.Calendar.id),
      "name": field(GraphQLString, \CalendarRecord.name, description: FieldDocs.Calendar.name),
      "color": field(GraphQLString, \CalendarRecord.color, description: FieldDocs.Calendar.color),
      "type": field(
        GraphQLNonNull(calendarType), { (calendar: CalendarRecord) in calendar.type.rawValue },
        description: FieldDocs.Calendar.type),
      "allowsContentModifications": field(
        GraphQLBoolean, \CalendarRecord.allowsContentModifications,
        description: FieldDocs.Calendar.allowsContentModifications),
      "allowsCalendarModifications": field(
        GraphQLBoolean, \CalendarRecord.allowsCalendarModifications,
        description: FieldDocs.Calendar.allowsCalendarModifications),
      "subscribed": field(
        GraphQLBoolean, \CalendarRecord.subscribed, description: FieldDocs.Calendar.subscribed),
      "immutable": field(
        GraphQLBoolean, \CalendarRecord.immutable, description: FieldDocs.Calendar.immutable),
      "supportedAvailabilities": field(
        GraphQLNonNull(GraphQLList(GraphQLNonNull(availability))),
        { (calendar: CalendarRecord) in calendar.supportedAvailabilities.map(\.rawValue) },
        description: FieldDocs.Calendar.supportedAvailabilities),
    ])
  let direction = try enumeration(
    "SortDirection", SortDirection.allCases.map(\.rawValue),
    descriptions: ["ASC": "Smallest or earliest first.", "DESC": "Largest or latest first."])
  let calendarOrder = try GraphQLInputObjectType(
    name: "CalendarOrder",
    fields: [
      "direction": InputObjectField(
        type: direction, defaultValue: "ASC", description: FieldDocs.CalendarOrder.direction)
    ])
  let calendarFilter = try GraphQLInputObjectType(
    name: "CalendarFilter",
    fields: [
      "query": InputObjectField(
        type: GraphQLString, description: FieldDocs.CalendarFilter.query),
      "accountIds": InputObjectField(
        type: GraphQLList(GraphQLNonNull(GraphQLID)),
        description: FieldDocs.CalendarFilter.accountIds),
      "allowsContentModifications": InputObjectField(
        type: GraphQLBoolean, description: FieldDocs.CalendarFilter.allowsContentModifications),
      "subscribed": InputObjectField(
        type: GraphQLBoolean, description: FieldDocs.CalendarFilter.subscribed),
    ])
  let dateTime = try GraphQLScalarType(
    name: "DateTime", description: "RFC 3339 timestamp with an explicit offset, serialized in UTC.",
    // Every output date comes from timestamp() and is already canonical UTC.
    serialize: { value in
      guard let text = value as? String else {
        throw ServerError.internalError("DateTime output is not a string")
      }
      return .string(text)
    },
    parseValue: { value in
      _ = try parseTimestamp(value.stringValue())
      return value
    },
    parseLiteral: { node in
      let value = try valueFromASTUntyped(valueAST: node)
      _ = try parseTimestamp(value.stringValue())
      return value
    })
  let localDate = try GraphQLScalarType(
    name: "LocalDate", description: "Calendar date in YYYY-MM-DD form, without a time or offset.")
  let url = try GraphQLScalarType(name: "URL", description: "Absolute URL serialized as a string.")
  let structuredLocation = try GraphQLObjectType(
    name: "StructuredLocation",
    fields: [
      "title": field(
        GraphQLString, \StructuredLocation.title, description: FieldDocs.StructuredLocation.title),
      "latitude": field(
        GraphQLFloat, \StructuredLocation.latitude,
        description: FieldDocs.StructuredLocation.latitude),
      "longitude": field(
        GraphQLFloat, \StructuredLocation.longitude,
        description: FieldDocs.StructuredLocation.longitude),
      "radius": field(
        GraphQLNonNull(GraphQLFloat), \StructuredLocation.radius,
        description: FieldDocs.StructuredLocation.radius),
    ])
  let alarm = try GraphQLObjectType(
    name: "RawAlarm",
    description: "An alarm exactly as stored.",
    fields: [
      "action": field(
        GraphQLNonNull(GraphQLString), \AlarmRecord.action,
        description: FieldDocs.RawAlarm.action),
      "soundName": field(
        GraphQLString, \AlarmRecord.soundName,
        description: FieldDocs.RawAlarm.soundName),
      "emailAddress": field(
        GraphQLString, \AlarmRecord.emailAddress,
        description: FieldDocs.RawAlarm.emailAddress),
      "absoluteDate": field(
        dateTime, \AlarmRecord.absoluteDate, description: FieldDocs.RawAlarm.absoluteDate),
      "relativeOffset": field(
        GraphQLNonNull(GraphQLFloat), \AlarmRecord.relativeOffset,
        description: FieldDocs.RawAlarm.relativeOffset),
      "proximity": field(
        GraphQLNonNull(GraphQLString), { (alarm: AlarmRecord) in alarm.proximity.rawValue },
        description: FieldDocs.RawAlarm.proximity),
      "structuredLocation": field(
        structuredLocation, \AlarmRecord.structuredLocation,
        description: FieldDocs.RawAlarm.structuredLocation),
    ])
  let absoluteAlarm = try GraphQLObjectType(
    name: AlarmKind.absolute.rawValue,
    fields: [
      "action": field(
        GraphQLNonNull(GraphQLString), \AlarmView.action,
        description: FieldDocs.RawAlarm.action),
      "soundName": field(
        GraphQLString, \AlarmView.soundName,
        description: FieldDocs.RawAlarm.soundName),
      "emailAddress": field(
        GraphQLString, \AlarmView.emailAddress,
        description: FieldDocs.RawAlarm.emailAddress),
      "at": field(GraphQLNonNull(dateTime), \AlarmView.at, description: FieldDocs.AbsoluteAlarm.at),
    ])
  let relativeAlarm = try GraphQLObjectType(
    name: AlarmKind.relative.rawValue,
    fields: [
      "action": field(
        GraphQLNonNull(GraphQLString), \AlarmView.action,
        description: FieldDocs.RawAlarm.action),
      "soundName": field(
        GraphQLString, \AlarmView.soundName,
        description: FieldDocs.RawAlarm.soundName),
      "emailAddress": field(
        GraphQLString, \AlarmView.emailAddress,
        description: FieldDocs.RawAlarm.emailAddress),
      "offsetSeconds": field(
        GraphQLNonNull(GraphQLFloat), \AlarmView.offsetSeconds,
        description: FieldDocs.RelativeAlarm.offsetSeconds),
    ])
  let alarmUnion = try GraphQLUnionType(
    name: "EventAlarm",
    resolveType: { value, _ in try record(value, as: AlarmView.self).kind.rawValue },
    types: [absoluteAlarm, relativeAlarm])
  let recurrenceDay = try GraphQLObjectType(
    name: "RecurrenceDay",
    fields: [
      "dayOfTheWeek": field(
        GraphQLNonNull(GraphQLInt), \RecurrenceDay.dayOfTheWeek,
        description: FieldDocs.RecurrenceDay.dayOfTheWeek),
      "weekNumber": field(
        GraphQLNonNull(GraphQLInt), \RecurrenceDay.weekNumber,
        description: FieldDocs.RecurrenceDay.weekNumber),
    ])
  let recurrenceEnd = try GraphQLObjectType(
    name: "RecurrenceEnd",
    fields: [
      "endDate": field(
        dateTime, \RecurrenceEnd.endDate, description: FieldDocs.RecurrenceEnd.endDate),
      "occurrenceCount": field(
        GraphQLNonNull(GraphQLInt), \RecurrenceEnd.occurrenceCount,
        description: FieldDocs.RecurrenceEnd.occurrenceCount),
    ])
  let integers = GraphQLNonNull(GraphQLList(GraphQLNonNull(GraphQLInt)))
  let recurrence = try GraphQLObjectType(
    name: "RecurrenceRule", description: "A recurrence rule exactly as stored.",
    fields: [
      "frequency": field(
        GraphQLNonNull(GraphQLString), { (rule: RecurrenceRecord) in rule.frequency.rawValue },
        description: FieldDocs.RecurrenceRule.frequency),
      "calendarIdentifier": field(
        GraphQLNonNull(GraphQLString), \RecurrenceRecord.calendarIdentifier,
        description: FieldDocs.RecurrenceRule.calendarIdentifier),
      "interval": field(
        GraphQLNonNull(GraphQLInt), \RecurrenceRecord.interval,
        description: FieldDocs.RecurrenceRule.interval),
      "firstDayOfTheWeek": field(
        GraphQLNonNull(GraphQLInt), \RecurrenceRecord.firstDayOfTheWeek,
        description: FieldDocs.RecurrenceRule.firstDayOfTheWeek),
      "daysOfTheWeek": field(
        GraphQLNonNull(GraphQLList(GraphQLNonNull(recurrenceDay))), \RecurrenceRecord.daysOfTheWeek,
        description: FieldDocs.RecurrenceRule.daysOfTheWeek),
      "end": field(recurrenceEnd, \RecurrenceRecord.end, description: FieldDocs.RecurrenceRule.end),
      "daysOfTheMonth": field(
        integers, \RecurrenceRecord.daysOfTheMonth,
        description: FieldDocs.RecurrenceRule.daysOfTheMonth),
      "daysOfTheYear": field(
        integers, \RecurrenceRecord.daysOfTheYear,
        description: FieldDocs.RecurrenceRule.daysOfTheYear),
      "weeksOfTheYear": field(
        integers, \RecurrenceRecord.weeksOfTheYear,
        description: FieldDocs.RecurrenceRule.weeksOfTheYear),
      "monthsOfTheYear": field(
        integers, \RecurrenceRecord.monthsOfTheYear,
        description: FieldDocs.RecurrenceRule.monthsOfTheYear),
      "setPositions": field(
        integers, \RecurrenceRecord.setPositions,
        description: FieldDocs.RecurrenceRule.setPositions),
    ])
  let frequency = try enumeration(
    "RecurrenceFrequency", ScheduleFrequency.allCases.map(\.rawValue),
    descriptions: [
      "DAILY": "Repeat in day intervals.", "WEEKLY": "Repeat in week intervals.",
      "MONTHLY": "Repeat in month intervals.", "YEARLY": "Repeat in year intervals.",
    ])
  let weekday = try enumeration(
    "Weekday", Weekday.allCases.map(\.rawValue),
    descriptions: Dictionary(
      uniqueKeysWithValues: Weekday.allCases.map { ($0.rawValue, $0.rawValue.capitalized + ".") }))
  let scheduleDay = try GraphQLObjectType(
    name: "EventRecurrenceDay",
    fields: [
      "day": field(
        GraphQLNonNull(weekday), { (day: RecurrenceView.Day) in day.day.rawValue },
        description: FieldDocs.ScheduleDay.day),
      "ordinal": field(
        GraphQLInt, \RecurrenceView.Day.ordinal, description: FieldDocs.ScheduleDay.ordinal),
    ])
  let scheduleEnd = try GraphQLObjectType(
    name: "EventRecurrenceEnd",
    fields: [
      "until": field(dateTime, \RecurrenceView.End.until, description: FieldDocs.ScheduleEnd.until),
      "count": field(
        GraphQLInt, \RecurrenceView.End.count, description: FieldDocs.ScheduleEnd.count),
    ])
  let selectors = GraphQLList(GraphQLNonNull(GraphQLInt))
  let schedule = try GraphQLObjectType(
    name: "EventRecurrence",
    fields: [
      "frequency": field(
        GraphQLNonNull(frequency), { (rule: RecurrenceView) in rule.frequency.rawValue },
        description: FieldDocs.Schedule.frequency),
      "interval": field(
        GraphQLNonNull(GraphQLInt), \RecurrenceView.interval,
        description: FieldDocs.Schedule.interval),
      "daysOfWeek": field(
        GraphQLList(GraphQLNonNull(scheduleDay)), \RecurrenceView.daysOfWeek,
        description: FieldDocs.Schedule.daysOfWeek),
      "end": field(scheduleEnd, \RecurrenceView.end, description: FieldDocs.Schedule.end),
      "daysOfMonth": field(
        selectors, \RecurrenceView.daysOfMonth, description: FieldDocs.Schedule.daysOfMonth),
      "monthsOfYear": field(
        selectors, \RecurrenceView.monthsOfYear, description: FieldDocs.Schedule.monthsOfYear),
      "weeksOfYear": field(
        selectors, \RecurrenceView.weeksOfYear, description: FieldDocs.Schedule.weeksOfYear),
      "daysOfYear": field(
        selectors, \RecurrenceView.daysOfYear, description: FieldDocs.Schedule.daysOfYear),
      "setPositions": field(
        selectors, \RecurrenceView.setPositions, description: FieldDocs.Schedule.setPositions),
    ])
  let eventStatus = try enumeration(
    "EventStatus", EventStatus.allCases.map(\.rawValue),
    descriptions: [
      "NONE": "No status.", "CONFIRMED": "Confirmed.", "TENTATIVE": "Tentative.",
      "CANCELED": "Canceled by its organizer.",
    ])
  let participantStatus = try enumeration(
    "ParticipantStatus", ParticipantStatus.allCases.map(\.rawValue),
    descriptions: [
      "UNKNOWN": "No status reported.", "PENDING": "Invited and yet to answer.",
      "ACCEPTED": "Accepted.", "DECLINED": "Declined.", "TENTATIVE": "Tentatively accepted.",
      "DELEGATED": "Delegated to someone else.", "COMPLETED": "Marked completed.",
      "IN_PROCESS": "Marked in process.",
    ])
  let participantRole = try enumeration(
    "ParticipantRole", ParticipantRole.allCases.map(\.rawValue),
    descriptions: [
      "UNKNOWN": "No role reported.", "REQUIRED": "Attendance is required.",
      "OPTIONAL": "Attendance is optional.", "CHAIR": "Chairs the event.",
      "NON_PARTICIPANT": "Informed but not attending.",
    ])
  let participantType = try enumeration(
    "ParticipantType", ParticipantType.allCases.map(\.rawValue),
    descriptions: [
      "UNKNOWN": "No type reported.", "PERSON": "A person.", "ROOM": "A room.",
      "RESOURCE": "A resource such as equipment.", "GROUP": "A group of people.",
    ])
  let participant = try GraphQLObjectType(
    name: "Participant",
    description: "An organizer or attendee, as the calendar server reports them. Read-only.",
    fields: [
      "name": field(
        GraphQLString, \ParticipantRecord.name, description: FieldDocs.Participant.name),
      "url": field(GraphQLString, \ParticipantRecord.url, description: FieldDocs.Participant.url),
      "email": field(
        GraphQLString, \ParticipantRecord.email, description: FieldDocs.Participant.email),
      "status": field(
        GraphQLNonNull(participantStatus),
        { (participant: ParticipantRecord) in participant.status.rawValue },
        description: FieldDocs.Participant.status),
      "role": field(
        GraphQLNonNull(participantRole),
        { (participant: ParticipantRecord) in participant.role.rawValue },
        description: FieldDocs.Participant.role),
      "type": field(
        GraphQLNonNull(participantType),
        { (participant: ParticipantRecord) in participant.type.rawValue },
        description: FieldDocs.Participant.type),
      "currentUser": field(
        GraphQLNonNull(GraphQLBoolean), \ParticipantRecord.currentUser,
        description: FieldDocs.Participant.currentUser),
    ])
  let orderField = try enumeration(
    "EventSortField", EventSortField.allCases.map(\.rawValue),
    descriptions: [
      "START_DATE": "Start, then end.", "END_DATE": "End, then start.", "TITLE": "Event title.",
      "CREATION_DATE": "Creation timestamp.", "MODIFICATION_DATE": "Last modification timestamp.",
    ])
  let eventOrder = try GraphQLInputObjectType(
    name: "EventOrder",
    fields: [
      "field": InputObjectField(
        type: GraphQLNonNull(orderField), description: FieldDocs.EventOrder.field),
      "direction": InputObjectField(
        type: direction, defaultValue: "ASC", description: FieldDocs.EventOrder.direction),
    ])
  let ids = GraphQLList(GraphQLNonNull(GraphQLID))
  let eventFilter = try GraphQLInputObjectType(
    name: "EventFilter",
    fields: [
      "query": InputObjectField(type: GraphQLString, description: FieldDocs.EventFilter.query),
      "titleContains": InputObjectField(
        type: GraphQLString, description: FieldDocs.EventFilter.titleContains),
      "calendarIds": InputObjectField(type: ids, description: FieldDocs.EventFilter.calendarIds),
      "accountIds": InputObjectField(type: ids, description: FieldDocs.EventFilter.accountIds),
      "allDay": InputObjectField(type: GraphQLBoolean, description: FieldDocs.EventFilter.allDay),
      "recurring": InputObjectField(
        type: GraphQLBoolean, description: FieldDocs.EventFilter.recurring),
      "detached": InputObjectField(
        type: GraphQLBoolean, description: FieldDocs.EventFilter.detached),
      "hasAttendees": InputObjectField(
        type: GraphQLBoolean, description: FieldDocs.EventFilter.hasAttendees),
      "hasAlarms": InputObjectField(
        type: GraphQLBoolean, description: FieldDocs.EventFilter.hasAlarms),
      "availabilities": InputObjectField(
        type: GraphQLList(GraphQLNonNull(availability)),
        description: FieldDocs.EventFilter.availabilities),
      "statuses": InputObjectField(
        type: GraphQLList(GraphQLNonNull(eventStatus)), description: FieldDocs.EventFilter.statuses),
      "myStatuses": InputObjectField(
        type: GraphQLList(GraphQLNonNull(participantStatus)),
        description: FieldDocs.EventFilter.myStatuses),
    ])
  let event = try GraphQLObjectType(
    name: "Event",
    description: "One event, or one occurrence of a repeating event.",
    fields: [
      "id": field(GraphQLNonNull(GraphQLID), \EventRecord.id, description: FieldDocs.Event.id),
      "seriesId": field(GraphQLID, \EventRecord.seriesId, description: FieldDocs.Event.seriesId),
      "eventIdentifier": field(
        GraphQLString, \EventRecord.eventIdentifier,
        description: FieldDocs.Event.eventIdentifier),
      "externalId": field(
        GraphQLString, \EventRecord.externalId, description: FieldDocs.Event.externalId),
      "calendarId": field(
        GraphQLNonNull(GraphQLID), \EventRecord.calendarId,
        description: FieldDocs.Event.calendarId),
      "title": field(GraphQLString, \EventRecord.title, description: FieldDocs.Event.title),
      "notes": field(GraphQLString, \EventRecord.notes, description: FieldDocs.Event.notes),
      "location": field(
        GraphQLString, \EventRecord.location, description: FieldDocs.Event.location),
      "structuredLocation": field(
        structuredLocation, \EventRecord.structuredLocation,
        description: FieldDocs.Event.structuredLocation),
      "url": field(url, \EventRecord.url, description: FieldDocs.Event.url),
      "allDay": field(
        GraphQLNonNull(GraphQLBoolean), \EventRecord.allDay, description: FieldDocs.Event.allDay),
      "startDate": field(
        dateTime, \EventRecord.startDate, description: FieldDocs.Event.startDate),
      "endDate": field(dateTime, \EventRecord.endDate, description: FieldDocs.Event.endDate),
      "allDayStartDate": field(
        localDate, \EventRecord.allDayStartDate, description: FieldDocs.Event.allDayStartDate),
      "allDayEndDate": field(
        localDate, \EventRecord.allDayEndDate, description: FieldDocs.Event.allDayEndDate),
      "timeZone": field(
        GraphQLString, \EventRecord.timeZone, description: FieldDocs.Event.timeZone),
      "occurrenceDate": field(
        dateTime, { (item: EventRecord) in item.occurrenceDate.map(timestamp) },
        description: FieldDocs.Event.occurrenceDate),
      "detached": field(
        GraphQLNonNull(GraphQLBoolean), \EventRecord.detached,
        description: FieldDocs.Event.detached),
      "recurring": field(
        GraphQLNonNull(GraphQLBoolean), \EventRecord.recurring,
        description: FieldDocs.Event.recurring),
      "availability": field(
        GraphQLNonNull(availability), { (item: EventRecord) in item.availability.rawValue },
        description: FieldDocs.Event.availability),
      "status": field(
        GraphQLNonNull(eventStatus), { (item: EventRecord) in item.status.rawValue },
        description: FieldDocs.Event.status),
      "organizer": field(
        participant, \EventRecord.organizer, description: FieldDocs.Event.organizer),
      "attendees": field(
        GraphQLNonNull(GraphQLList(GraphQLNonNull(participant))), \EventRecord.attendees,
        description: FieldDocs.Event.attendees),
      "myStatus": field(
        participantStatus, { (item: EventRecord) in item.myStatus?.rawValue },
        description: FieldDocs.Event.myStatus),
      "birthdayContactIdentifier": field(
        GraphQLString, \EventRecord.birthdayContactIdentifier,
        description: FieldDocs.Event.birthdayContactIdentifier),
      "creationDate": field(
        dateTime, { (item: EventRecord) in item.creationDate.map(timestamp) },
        description: FieldDocs.Event.creationDate),
      "modificationDate": field(
        dateTime, { (item: EventRecord) in item.modificationDate.map(timestamp) },
        description: FieldDocs.Event.modificationDate),
      "rawAlarms": field(
        GraphQLNonNull(GraphQLList(GraphQLNonNull(alarm))), \EventRecord.alarms,
        description: FieldDocs.Event.rawAlarms),
      "alarms": field(
        GraphQLList(GraphQLNonNull(alarmUnion)),
        { (item: EventRecord) in try item.alarms.map(AlarmView.init) },
        description: FieldDocs.Event.alarms),
      "recurrenceRules": field(
        GraphQLNonNull(GraphQLList(GraphQLNonNull(recurrence))), \EventRecord.recurrenceRules,
        description: FieldDocs.Event.recurrenceRules),
      "recurrence": field(
        schedule, { (item: EventRecord) in try recurrenceView(item.recurrenceRules) },
        description: FieldDocs.Event.recurrence),
    ])
  let pageInfo = try GraphQLObjectType(
    name: "PageInfo",
    fields: [
      "offset": field(
        GraphQLNonNull(GraphQLInt), \PageInfo.offset, description: "Requested zero-based offset."),
      "limit": field(
        GraphQLNonNull(GraphQLInt), \PageInfo.limit, description: "Requested maximum page size."),
      "hasNextPage": field(
        GraphQLNonNull(GraphQLBoolean), \PageInfo.hasNextPage,
        description: "Whether results exist after this page."),
      "hasPreviousPage": field(
        GraphQLNonNull(GraphQLBoolean), \PageInfo.hasPreviousPage,
        description: "Whether matching results exist before the requested offset."),
    ])
  func pageType<Item: Sendable>(
    _ name: String, _ item: GraphQLObjectType, of _: Item.Type, items: String, totalCount: String
  ) throws -> GraphQLObjectType {
    try GraphQLObjectType(
      name: name,
      fields: [
        "items": field(
          GraphQLNonNull(GraphQLList(GraphQLNonNull(item))), \GraphQLPage<Item>.items,
          description: items),
        "totalCount": field(
          GraphQLNonNull(GraphQLInt), \GraphQLPage<Item>.totalCount, description: totalCount),
        "pageInfo": field(
          GraphQLNonNull(pageInfo), \GraphQLPage<Item>.pageInfo,
          description: "Position and availability of neighboring pages."),
      ])
  }
  let pageArgs: GraphQLArgumentConfigMap = [
    "limit": GraphQLArgument(type: GraphQLNonNull(GraphQLInt), defaultValue: 50),
    "offset": GraphQLArgument(type: GraphQLNonNull(GraphQLInt), defaultValue: 0),
  ]
  var calendarArgs = pageArgs
  calendarArgs["filter"] = GraphQLArgument(type: calendarFilter)
  calendarArgs["orderBy"] = GraphQLArgument(type: calendarOrder)
  let idArg: GraphQLArgumentConfigMap = ["id": GraphQLArgument(type: GraphQLNonNull(GraphQLID))]
  let calendarPage = try pageType(
    "CalendarPage", calendar, of: CalendarRecord.self, items: FieldDocs.CalendarPage.items,
    totalCount: FieldDocs.CalendarPage.totalCount)
  let eventPage = try GraphQLObjectType(
    name: "EventPage",
    fields: [
      "items": field(
        GraphQLNonNull(GraphQLList(GraphQLNonNull(event))), \GraphQLEventPage.page.items,
        description: FieldDocs.EventPage.items),
      "totalCount": field(
        GraphQLNonNull(GraphQLInt), \GraphQLEventPage.page.totalCount,
        description: FieldDocs.EventPage.totalCount),
      "pageInfo": field(
        GraphQLNonNull(pageInfo), \GraphQLEventPage.page.pageInfo,
        description: "Position and availability of neighboring pages."),
      "from": field(
        GraphQLNonNull(dateTime), { (page: GraphQLEventPage) in timestamp(page.window.from) },
        description: FieldDocs.EventWindow.resolvedFrom),
      "before": field(
        GraphQLNonNull(dateTime), { (page: GraphQLEventPage) in timestamp(page.window.before) },
        description: FieldDocs.EventWindow.resolvedBefore),
    ])
  func count(_ value: KeyPath<CalendarSummary, Int> & Sendable, _ description: String)
    -> GraphQLField
  {
    field(
      GraphQLNonNull(GraphQLInt), { (summary: CalendarSummary) in summary[keyPath: value] },
      description: description)
  }
  let summary = try GraphQLObjectType(
    name: "CalendarSummary",
    description: "Counts of the events in one calendar that overlap a window; they overlap.",
    fields: [
      "from": field(
        GraphQLNonNull(dateTime), \CalendarSummary.from,
        description: FieldDocs.EventWindow.resolvedFrom),
      "before": field(
        GraphQLNonNull(dateTime), \CalendarSummary.before,
        description: FieldDocs.EventWindow.resolvedBefore),
      "total": count(\.total, FieldDocs.CalendarSummary.total),
      "allDay": count(\.allDay, FieldDocs.CalendarSummary.allDay),
      "timed": count(\.timed, FieldDocs.CalendarSummary.timed),
      "recurring": count(\.recurring, FieldDocs.CalendarSummary.recurring),
      "withAttendees": count(\.withAttendees, FieldDocs.CalendarSummary.withAttendees),
      "withAlarms": count(\.withAlarms, FieldDocs.CalendarSummary.withAlarms),
    ])
  var eventArgs = pageArgs
  eventArgs["from"] = GraphQLArgument(type: GraphQLString, description: FieldDocs.EventWindow.from)
  eventArgs["before"] = GraphQLArgument(
    type: GraphQLString, description: FieldDocs.EventWindow.before)
  eventArgs["filter"] = GraphQLArgument(type: eventFilter)
  eventArgs["orderBy"] = GraphQLArgument(type: eventOrder)
  var accountFields = try account.fields()
  accountFields["events"] = GraphQLField(
    type: eventPage,
    description: "Events overlapping the window in this account; filters apply within it.",
    args: eventArgs,
    resolve: { source, args, context, _ in
      let id = try record(source, as: AccountRecord.self).id
      let calendars = try await calendarData(context).calendars
      return try await eventSearchPage(
        args: args, context: context,
        scope: Set(calendars.filter { $0.source.id == id }.map(\.id)))
    })
  accountFields["calendars"] = GraphQLField(
    type: calendarPage, description: "Calendars in this account; filters apply within it.",
    args: calendarArgs,
    resolve: { source, args, context, _ in
      let id = try record(source, as: AccountRecord.self).id
      return try await calendarSearchPage(calendarData(context), args: args, accountID: id)
    })
  account.fields = { accountFields }
  var calendarFields = try calendar.fields()
  calendarFields["account"] = GraphQLField(
    type: account, description: "The account that owns the calendar.",
    resolve: { source, _, context, _ in
      let id = try record(source, as: CalendarRecord.self).source.id
      return try await calendarData(context).accounts.first { $0.id == id }
    })
  calendarFields["events"] = GraphQLField(
    type: eventPage,
    description: "Events overlapping the window in this calendar; filters apply within it.",
    args: eventArgs,
    resolve: { source, args, context, _ in
      let id = try record(source, as: CalendarRecord.self).id
      return try await eventSearchPage(args: args, context: context, scope: [id])
    })
  calendarFields["summary"] = GraphQLField(
    type: summary,
    description: "Event counts for this calendar over a window, regardless of pagination.",
    args: [
      "from": GraphQLArgument(type: GraphQLString, description: FieldDocs.EventWindow.from),
      "before": GraphQLArgument(type: GraphQLString, description: FieldDocs.EventWindow.before),
    ],
    resolve: { source, args, context, _ in
      let id = try record(source, as: CalendarRecord.self).id
      let context = try requestContext(context)
      let arguments = try decodeInput(GraphQLWindowArguments.self, from: args)
      var search = Search()
      search.from = arguments.from
      search.before = arguments.before
      let data = try await context.eventsData(search.window(now: context.now))
      return summarize(search.events(data, scope: [id]), window: data.window, calendarId: id)
    })
  calendar.fields = { calendarFields }
  var eventFields = try event.fields()
  eventFields["calendar"] = GraphQLField(
    type: calendar, description: "The owning calendar.",
    resolve: { source, _, context, _ in
      let id = try record(source, as: EventRecord.self).calendarId
      return try await calendarData(context).calendars.first { $0.id == id }
    })
  event.fields = { eventFields }
  let mutation = try makeMutationType(
    calendar: calendar, event: event, dateTime: dateTime, localDate: localDate, url: url,
    availability: availability, frequency: frequency, weekday: weekday)
  let locationSearchResult = try GraphQLObjectType(
    name: "LocationSearchResult",
    fields: [
      "name": field(
        GraphQLString, \LocationSearchResult.name,
        description: FieldDocs.LocationSearch.name),
      "address": field(
        GraphQLString, \LocationSearchResult.address,
        description: FieldDocs.LocationSearch.address),
      "latitude": field(
        GraphQLNonNull(GraphQLFloat), \LocationSearchResult.latitude,
        description: FieldDocs.LocationSearch.latitude),
      "longitude": field(
        GraphQLNonNull(GraphQLFloat), \LocationSearchResult.longitude,
        description: FieldDocs.LocationSearch.longitude),
    ])
  return try GraphQLSchema(
    query: GraphQLObjectType(
      name: "Query",
      fields: [
        "searchLocations": GraphQLField(
          type: GraphQLList(GraphQLNonNull(locationSearchResult)),
          description: FieldDocs.LocationSearch.description,
          args: [
            "query": GraphQLArgument(
              type: GraphQLNonNull(GraphQLString),
              description: FieldDocs.LocationSearch.query),
            "limit": GraphQLArgument(
              type: GraphQLNonNull(GraphQLInt),
              description: FieldDocs.LocationSearch.limit, defaultValue: 5),
          ],
          resolve: { _, args, _, _ in
            try await searchLocations(decodeInput(LocationSearchArguments.self, from: args))
          }),
        "accounts": GraphQLField(
          type: GraphQLList(GraphQLNonNull(account)),
          description: "Accounts that have event calendars.",
          resolve: { _, _, context, _ in try await calendarData(context).accounts }),
        "account": GraphQLField(
          type: account,
          description: "Find an account by its unique identifier; null when missing.", args: idArg,
          resolve: { _, args, context, _ in
            let id = try decodeInput(GraphQLIDArguments.self, from: args).id
            return try await calendarData(context).accounts.first { $0.id == id }
          }),
        "calendars": GraphQLField(
          type: calendarPage, description: "Event calendars available in Calendar.",
          args: calendarArgs,
          resolve: { _, args, context, _ in
            try await calendarSearchPage(calendarData(context), args: args)
          }),
        "calendar": GraphQLField(
          type: calendar,
          description: "Find a calendar by its unique identifier; null when missing.",
          args: idArg,
          resolve: { _, args, context, _ in
            let id = try decodeInput(GraphQLIDArguments.self, from: args).id
            return try await calendarData(context).calendars.first { $0.id == id }
          }),
        "events": GraphQLField(
          type: eventPage,
          description:
            "Events overlapping a window of time, with repeating events expanded into their occurrences. The page echoes the resolved window.",
          args: eventArgs,
          resolve: { _, args, context, _ in
            try await eventSearchPage(args: args, context: context)
          }),
        "event": GraphQLField(
          type: event,
          description:
            "Find an event or occurrence by its id; null when missing. A series id returns its first occurrence.",
          args: idArg,
          resolve: { _, args, context, _ in
            let id = try decodeInput(GraphQLIDArguments.self, from: args).id
            return try await requestContext(context).event(id: id)
          }),
        "defaultAccount": GraphQLField(
          type: account,
          description: "The account of the default calendar, or null if none is available.",
          resolve: { _, _, context, _ in
            try await calendarData(context).defaultAccount
          }
        ),
        "defaultCalendar": GraphQLField(
          type: calendar,
          description: "The default calendar for new events, or null if none is available.",
          resolve: { _, _, context, _ in
            try await calendarData(context).defaultCalendar
          }),
      ]), mutation: mutation)
}
