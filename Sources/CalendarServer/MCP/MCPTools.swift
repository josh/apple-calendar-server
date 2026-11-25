import Foundation
import MCP
import NIOHTTP1

private struct PageOutput<Item: Encodable>: Encodable {
  let items: [Item]
  let totalCount: Int
  let nextCursor: String?
  enum CodingKeys: String, CodingKey { case items, totalCount, nextCursor }
}
// A page of events with the window the search resolved, which later pages must repeat.
private struct EventPageOutput: Encodable {
  let items: [MCPEvent]
  let totalCount: Int
  let nextCursor: String?
  let from, before: String
  enum CodingKeys: String, CodingKey { case items, totalCount, nextCursor, from, before }
}
private struct EventOutput: Encodable {
  let event: MCPEvent?
  enum CodingKeys: CodingKey { case event }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(event, forKey: .event)
  }
}
private struct LocationSearchOutput: Encodable {
  let items: [LocationSearchResult]
  enum CodingKeys: String, CodingKey { case items }
}
private struct SummaryOutput: Encodable {
  let items: [CalendarSummary]
  enum CodingKeys: String, CodingKey { case items }
}
private struct AccountOutput: Encodable {
  let account: AccountRecord?
  enum CodingKeys: CodingKey { case account }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(account, forKey: .account)
  }
}
private struct AccountsOutput: Encodable {
  let items: [AccountRecord]
  enum CodingKeys: String, CodingKey { case items }
}
private struct CalendarOutput: Encodable {
  let calendar: CalendarRecord?
  enum CodingKeys: CodingKey { case calendar }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(calendar, forKey: .calendar)
  }
}
private struct DefaultsOutput: Encodable {
  let calendar: CalendarRecord?
  let account: AccountRecord?
  enum CodingKeys: CodingKey { case calendar, account }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(calendar, forKey: .calendar)
    try c.encode(account, forKey: .account)
  }
}
private func describe(_ value: Value, _ text: String) -> Value {
  guard case .object(var object) = value else { return value }
  object["description"] = .string(text)
  return .object(object)
}
private func object(_ properties: [String: Value], required: [String] = []) -> Value {
  .object([
    "type": .string(JSONType.object.rawValue), "properties": .object(properties),
    "required": .array(required.map(Value.string)), "additionalProperties": false,
  ])
}
// An object schema whose property names are the coding keys of the type it describes,
// so the schema cannot name a field the encoder or decoder does not use.
private func schema<Key: CodingKey>(
  _: Key.Type, _ properties: KeyValuePairs<Key, Value>, required: [Key] = []
) -> Value {
  object(
    Dictionary(uniqueKeysWithValues: properties.map { ($0.key.stringValue, $0.value) }),
    required: required.map(\.stringValue))
}
// JSON Schema type names.
private enum JSONType: String { case object, array, string, integer, number, boolean, null }
// A value of one JSON type, with optional keywords such as minimum or default.
private func primitive(_ type: JSONType, _ keywords: [String: Value] = [:]) -> Value {
  .object(keywords.merging(["type": .string(type.rawValue)]) { _, type in type })
}
private func array(_ item: Value) -> Value {
  .object(["type": .string(JSONType.array.rawValue), "items": item])
}
private func enumeration(_ values: [String]) -> Value {
  primitive(.string, ["enum": .array(values.map(Value.string))])
}
private func nullable(_ value: Value) -> Value {
  .object(["anyOf": .array([value, primitive(.null)])])
}
private func toolsCatalog() -> [Tool] {
  let integer = primitive(.integer)
  let string = primitive(.string)
  let boolean = primitive(.boolean)
  let limit = describe(
    primitive(.integer, ["minimum": 1, "maximum": 100, "default": 50]),
    "Maximum items in the page, from 1 through 100; defaults to 50.")
  let cursor = describe(
    string, "nextCursor from the previous page; omit for the first page.")
  let direction = enumeration(SortDirection.allCases.map(\.rawValue))
  func page<Item: Encodable>(_: Item.Type, _ item: Value, _ items: String, _ totalCount: String)
    -> Value
  {
    schema(
      PageOutput<Item>.CodingKeys.self,
      [
        .items: describe(array(item), items),
        .totalCount: describe(integer, totalCount),
        .nextCursor: describe(string, "Cursor for the next page; omitted on the last page."),
      ], required: [.items, .totalCount])
  }
  func byID(_ noun: String) -> Value {
    schema(
      IDArguments.CodingKeys.self,
      [.id: describe(string, "Unique identifier of the \(noun).")], required: [.id])
  }
  let account = schema(
    AccountRecord.CodingKeys.self,
    [
      .id: describe(string, FieldDocs.Account.id),
      .name: describe(string, FieldDocs.Account.name),
    ], required: [.id, .name])
  let source = schema(
    SourceRecord.CodingKeys.self,
    [
      .id: describe(string, FieldDocs.Account.id),
      .title: describe(string, FieldDocs.Account.name),
      .type: describe(integer, "EventKit source type number."),
    ], required: [.id, .title, .type])
  let calendar = schema(
    CalendarRecord.CodingKeys.self,
    [
      .id: describe(string, FieldDocs.Calendar.id),
      .name: describe(string, FieldDocs.Calendar.name),
      .color: describe(string, FieldDocs.Calendar.color),
      .source: describe(source, "The account that owns the calendar."),
      .type: describe(
        enumeration(CalendarType.allCases.map(\.rawValue)), FieldDocs.Calendar.type),
      .allowsContentModifications: describe(
        boolean, FieldDocs.Calendar.allowsContentModifications),
      .allowsCalendarModifications: describe(
        boolean, FieldDocs.Calendar.allowsCalendarModifications),
      .subscribed: describe(boolean, FieldDocs.Calendar.subscribed),
      .immutable: describe(boolean, FieldDocs.Calendar.immutable),
      .supportedAvailabilities: describe(
        array(enumeration(EventAvailability.allCases.map(\.rawValue))),
        FieldDocs.Calendar.supportedAvailabilities),
    ],
    required: [
      .id, .name, .source, .type, .allowsContentModifications, .allowsCalendarModifications,
      .subscribed, .immutable, .supportedAvailabilities,
    ])
  let calendarSearch = schema(
    CalendarSearchArguments.CodingKeys.self,
    [
      .filter: schema(
        CalendarSearchArguments.Filter.CodingKeys.self,
        [
          .query: describe(string, FieldDocs.CalendarFilter.query),
          .accountIds: describe(array(string), FieldDocs.CalendarFilter.accountIds),
          .allowsContentModifications: describe(
            boolean, FieldDocs.CalendarFilter.allowsContentModifications),
          .subscribed: describe(boolean, FieldDocs.CalendarFilter.subscribed),
        ]),
      .orderBy: schema(
        CalendarSearchArguments.Order.CodingKeys.self,
        [.direction: describe(direction, FieldDocs.CalendarOrder.direction)]),
      .limit: limit, .cursor: cursor,
    ])
  let number = primitive(.number)
  let integers = array(integer)
  let from = describe(string, FieldDocs.EventWindow.from)
  let before = describe(string, FieldDocs.EventWindow.before)
  let structuredLocation = schema(
    StructuredLocation.CodingKeys.self,
    [
      .title: describe(string, FieldDocs.StructuredLocation.title),
      .latitude: describe(number, FieldDocs.StructuredLocation.latitude),
      .longitude: describe(number, FieldDocs.StructuredLocation.longitude),
      .radius: describe(number, FieldDocs.StructuredLocation.radius),
    ], required: [.radius])
  let participantStatus = enumeration(ParticipantStatus.allCases.map(\.rawValue))
  let participant = schema(
    ParticipantRecord.CodingKeys.self,
    [
      .name: describe(string, FieldDocs.Participant.name),
      .url: describe(string, FieldDocs.Participant.url),
      .email: describe(string, FieldDocs.Participant.email),
      .status: describe(participantStatus, FieldDocs.Participant.status),
      .role: describe(
        enumeration(ParticipantRole.allCases.map(\.rawValue)), FieldDocs.Participant.role),
      .type: describe(
        enumeration(ParticipantType.allCases.map(\.rawValue)), FieldDocs.Participant.type),
      .currentUser: describe(boolean, FieldDocs.Participant.currentUser),
    ], required: [.status, .role, .type, .currentUser])
  let rawAlarm = schema(
    AlarmRecord.CodingKeys.self,
    [
      .action: describe(string, FieldDocs.RawAlarm.action),
      .soundName: describe(string, FieldDocs.RawAlarm.soundName),
      .emailAddress: describe(string, FieldDocs.RawAlarm.emailAddress),
      .absoluteDate: describe(string, FieldDocs.RawAlarm.absoluteDate),
      .relativeOffset: describe(number, FieldDocs.RawAlarm.relativeOffset),
      .proximity: describe(
        enumeration(AlarmProximity.allCases.map(\.rawValue)), FieldDocs.RawAlarm.proximity),
      .structuredLocation: describe(structuredLocation, FieldDocs.RawAlarm.structuredLocation),
    ], required: [.action, .relativeOffset, .proximity])
  let alarm = schema(
    AlarmView.CodingKeys.self,
    [
      .kind: describe(
        enumeration([AlarmKind.absolute.rawValue, AlarmKind.relative.rawValue]),
        "AbsoluteAlarm carries at; RelativeAlarm carries offsetSeconds."),
      .action: describe(string, FieldDocs.RawAlarm.action),
      .soundName: describe(string, FieldDocs.RawAlarm.soundName),
      .emailAddress: describe(string, FieldDocs.RawAlarm.emailAddress),
      .at: describe(string, FieldDocs.AbsoluteAlarm.at),
      .offsetSeconds: describe(number, FieldDocs.RelativeAlarm.offsetSeconds),
    ], required: [.kind, .action])
  let rawRule = schema(
    RecurrenceRecord.CodingKeys.self,
    [
      .frequency: describe(
        enumeration(RecurrenceFrequency.allCases.map(\.rawValue)),
        FieldDocs.RecurrenceRule.frequency),
      .calendarIdentifier: describe(string, FieldDocs.RecurrenceRule.calendarIdentifier),
      .interval: describe(integer, FieldDocs.RecurrenceRule.interval),
      .firstDayOfTheWeek: describe(integer, FieldDocs.RecurrenceRule.firstDayOfTheWeek),
      .daysOfTheWeek: describe(
        array(
          schema(
            RecurrenceDay.CodingKeys.self,
            [
              .dayOfTheWeek: describe(integer, FieldDocs.RecurrenceDay.dayOfTheWeek),
              .weekNumber: describe(integer, FieldDocs.RecurrenceDay.weekNumber),
            ], required: [.dayOfTheWeek, .weekNumber])), FieldDocs.RecurrenceRule.daysOfTheWeek),
      .daysOfTheMonth: describe(integers, FieldDocs.RecurrenceRule.daysOfTheMonth),
      .daysOfTheYear: describe(integers, FieldDocs.RecurrenceRule.daysOfTheYear),
      .weeksOfTheYear: describe(integers, FieldDocs.RecurrenceRule.weeksOfTheYear),
      .monthsOfTheYear: describe(integers, FieldDocs.RecurrenceRule.monthsOfTheYear),
      .setPositions: describe(integers, FieldDocs.RecurrenceRule.setPositions),
      .end: describe(
        schema(
          RecurrenceEnd.CodingKeys.self,
          [
            .endDate: describe(string, FieldDocs.RecurrenceEnd.endDate),
            .occurrenceCount: describe(integer, FieldDocs.RecurrenceEnd.occurrenceCount),
          ], required: [.occurrenceCount]), FieldDocs.RecurrenceRule.end),
    ],
    required: [
      .frequency, .calendarIdentifier, .interval, .firstDayOfTheWeek, .daysOfTheWeek,
      .daysOfTheMonth, .daysOfTheYear, .weeksOfTheYear, .monthsOfTheYear, .setPositions,
    ])
  let weekday = enumeration(Weekday.allCases.map(\.rawValue))
  let frequency = enumeration(ScheduleFrequency.allCases.map(\.rawValue))
  let rule = schema(
    RecurrenceView.CodingKeys.self,
    [
      .frequency: describe(frequency, FieldDocs.Schedule.frequency),
      .interval: describe(integer, FieldDocs.Schedule.interval),
      .daysOfWeek: describe(
        array(
          schema(
            RecurrenceView.Day.CodingKeys.self,
            [
              .day: describe(weekday, FieldDocs.ScheduleDay.day),
              .ordinal: describe(integer, FieldDocs.ScheduleDay.ordinal),
            ], required: [.day])), FieldDocs.Schedule.daysOfWeek),
      .daysOfMonth: describe(integers, FieldDocs.Schedule.daysOfMonth),
      .monthsOfYear: describe(integers, FieldDocs.Schedule.monthsOfYear),
      .weeksOfYear: describe(integers, FieldDocs.Schedule.weeksOfYear),
      .daysOfYear: describe(integers, FieldDocs.Schedule.daysOfYear),
      .setPositions: describe(integers, FieldDocs.Schedule.setPositions),
      .end: describe(
        schema(
          RecurrenceView.End.CodingKeys.self,
          [
            .until: describe(string, FieldDocs.ScheduleEnd.until),
            .count: describe(integer, FieldDocs.ScheduleEnd.count),
          ]), FieldDocs.Schedule.end),
    ], required: [.frequency, .interval])
  let availability = enumeration(EventAvailability.allCases.map(\.rawValue))
  let eventStatus = enumeration(EventStatus.allCases.map(\.rawValue))
  let event = schema(
    MCPEvent.CodingKeys.self,
    [
      .id: describe(string, FieldDocs.Event.id),
      .seriesId: describe(string, FieldDocs.Event.seriesId),
      .eventIdentifier: describe(string, FieldDocs.Event.eventIdentifier),
      .externalId: describe(string, FieldDocs.Event.externalId),
      .calendarId: describe(string, FieldDocs.Event.calendarId),
      .title: describe(string, FieldDocs.Event.title),
      .notes: describe(string, FieldDocs.Event.notes),
      .location: describe(string, FieldDocs.Event.location),
      .structuredLocation: describe(structuredLocation, FieldDocs.Event.structuredLocation),
      .url: describe(string, FieldDocs.Event.url),
      .allDay: describe(boolean, FieldDocs.Event.allDay),
      .startDate: describe(nullable(string), FieldDocs.Event.startDate),
      .endDate: describe(nullable(string), FieldDocs.Event.endDate),
      .allDayStartDate: describe(nullable(string), FieldDocs.Event.allDayStartDate),
      .allDayEndDate: describe(nullable(string), FieldDocs.Event.allDayEndDate),
      .timeZone: describe(nullable(string), FieldDocs.Event.timeZone),
      .occurrenceDate: describe(string, FieldDocs.Event.occurrenceDate),
      .detached: describe(boolean, FieldDocs.Event.detached),
      .recurring: describe(boolean, FieldDocs.Event.recurring),
      .availability: describe(availability, FieldDocs.Event.availability),
      .status: describe(eventStatus, FieldDocs.Event.status),
      .organizer: describe(participant, FieldDocs.Event.organizer),
      .attendees: describe(array(participant), FieldDocs.Event.attendees),
      .myStatus: describe(participantStatus, FieldDocs.Event.myStatus),
      .birthdayContactIdentifier: describe(string, FieldDocs.Event.birthdayContactIdentifier),
      .creationDate: describe(string, FieldDocs.Event.creationDate),
      .modificationDate: describe(string, FieldDocs.Event.modificationDate),
      .rawAlarms: describe(array(rawAlarm), FieldDocs.Event.rawAlarms),
      .alarms: describe(
        nullable(array(alarm)),
        "Configured alerts; null when a stored trigger cannot be represented, in which case unsupported lists alarms and rawAlarms holds the stored values."
      ),
      .recurrenceRules: describe(array(rawRule), FieldDocs.Event.recurrenceRules),
      .recurrence: describe(
        nullable(rule),
        "A single repeating schedule; null when the event does not repeat, or when the stored rules cannot be represented, in which case unsupported lists recurrence."
      ),
      .unsupported: describe(
        array(enumeration(["alarms", "recurrence"])),
        "Projected fields that are null because the stored value cannot be represented."),
    ],
    required: [
      .id, .eventIdentifier, .calendarId, .allDay, .startDate, .endDate, .allDayStartDate,
      .allDayEndDate, .timeZone, .detached, .recurring, .availability, .status, .attendees,
      .rawAlarms, .alarms, .recurrenceRules, .recurrence, .unsupported,
    ])
  let eventSearch = schema(
    EventSearchArguments.CodingKeys.self,
    [
      .from: from, .before: before,
      .filter: schema(
        EventSearchArguments.Filter.CodingKeys.self,
        [
          .query: describe(string, FieldDocs.EventFilter.query),
          .titleContains: describe(string, FieldDocs.EventFilter.titleContains),
          .calendarIds: describe(array(string), FieldDocs.EventFilter.calendarIds),
          .accountIds: describe(array(string), FieldDocs.EventFilter.accountIds),
          .allDay: describe(boolean, FieldDocs.EventFilter.allDay),
          .recurring: describe(boolean, FieldDocs.EventFilter.recurring),
          .detached: describe(boolean, FieldDocs.EventFilter.detached),
          .hasAttendees: describe(boolean, FieldDocs.EventFilter.hasAttendees),
          .hasAlarms: describe(boolean, FieldDocs.EventFilter.hasAlarms),
          .availabilities: describe(array(availability), FieldDocs.EventFilter.availabilities),
          .statuses: describe(array(eventStatus), FieldDocs.EventFilter.statuses),
          .myStatuses: describe(array(participantStatus), FieldDocs.EventFilter.myStatuses),
        ]),
      .orderBy: schema(
        EventSearchArguments.Order.CodingKeys.self,
        [
          .field: describe(
            enumeration(EventSortField.allCases.map(\.rawValue)), FieldDocs.EventOrder.field),
          .direction: describe(direction, FieldDocs.EventOrder.direction),
        ], required: [.field]),
      .limit: limit, .cursor: cursor,
    ])
  let summary = schema(
    CalendarSummary.CodingKeys.self,
    [
      .calendarId: describe(string, FieldDocs.CalendarSummary.calendarId),
      .from: describe(string, FieldDocs.EventWindow.resolvedFrom),
      .before: describe(string, FieldDocs.EventWindow.resolvedBefore),
      .total: describe(integer, FieldDocs.CalendarSummary.total),
      .allDay: describe(integer, FieldDocs.CalendarSummary.allDay),
      .timed: describe(integer, FieldDocs.CalendarSummary.timed),
      .recurring: describe(integer, FieldDocs.CalendarSummary.recurring),
      .withAttendees: describe(integer, FieldDocs.CalendarSummary.withAttendees),
      .withAlarms: describe(integer, FieldDocs.CalendarSummary.withAlarms),
    ],
    required: [
      .calendarId, .from, .before, .total, .allDay, .timed, .recurring, .withAttendees,
      .withAlarms,
    ])
  func eventResult(_ event: Value, _ text: String) -> Value {
    schema(EventOutput.CodingKeys.self, [.event: describe(event, text)], required: [.event])
  }
  let annotations = Tool.Annotations(
    readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
  let noArguments = object([:])
  let created = Tool.Annotations(
    readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
  let changed = Tool.Annotations(
    readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
  let calendarResult = schema(
    CalendarOutput.CodingKeys.self,
    [.calendar: describe(calendar, "The saved calendar.")], required: [.calendar])
  let deleted = schema(
    DeleteResult.CodingKeys.self,
    [.deletedId: describe(string, FieldDocs.DeleteResult.deletedId)], required: [.deletedId])
  let calendarPatch = schema(
    CalendarInput.CodingKeys.self,
    [
      .name: describe(string, FieldDocs.CalendarPatch.name),
      .color: describe(string, FieldDocs.CalendarPatch.color),
    ])
  let alarmInput = schema(
    AlarmInput.CodingKeys.self,
    [
      .absoluteDate: describe(string, FieldDocs.AlarmInput.absoluteDate),
      .relativeOffsetSeconds: describe(number, FieldDocs.AlarmInput.relativeOffsetSeconds),
      .soundName: describe(string, FieldDocs.AlarmInput.soundName),
      .emailAddress: describe(string, FieldDocs.AlarmInput.emailAddress),
    ])
  let placeInput = schema(
    StructuredLocationInput.CodingKeys.self,
    [
      .title: describe(string, FieldDocs.StructuredLocationInput.title),
      .latitude: describe(number, FieldDocs.LocationSearch.latitude),
      .longitude: describe(number, FieldDocs.LocationSearch.longitude),
      .radiusMeters: describe(number, FieldDocs.StructuredLocationInput.radiusMeters),
    ], required: [.title, .latitude, .longitude])
  let ruleInput = schema(
    RecurrenceInput.CodingKeys.self,
    [
      .frequency: describe(frequency, FieldDocs.Schedule.frequency),
      .interval: describe(primitive(.integer, ["minimum": 1]), FieldDocs.Schedule.interval),
      .daysOfWeek: describe(
        array(
          schema(
            RecurrenceInput.Day.CodingKeys.self,
            [
              .day: describe(weekday, FieldDocs.ScheduleDay.day),
              .ordinal: describe(integer, FieldDocs.ScheduleDay.ordinal),
            ], required: [.day])), FieldDocs.Schedule.daysOfWeek),
      .daysOfWeekNames: describe(array(string), FieldDocs.Schedule.daysOfWeekNames),
      .daysOfMonth: describe(integers, FieldDocs.Schedule.daysOfMonth),
      .monthsOfYear: describe(integers, FieldDocs.Schedule.monthsOfYear),
      .weeksOfYear: describe(integers, FieldDocs.Schedule.weeksOfYear),
      .daysOfYear: describe(integers, FieldDocs.Schedule.daysOfYear),
      .setPositions: describe(integers, FieldDocs.Schedule.setPositions),
      .end: describe(
        schema(
          RecurrenceInput.End.CodingKeys.self,
          [
            .until: describe(string, FieldDocs.ScheduleEnd.until),
            .count: describe(integer, FieldDocs.ScheduleEnd.count),
          ]), FieldDocs.Schedule.end),
    ], required: [.frequency, .interval])
  let writableAvailability = enumeration(
    EventAvailability.allCases.filter { $0 != .notSupported }.map(\.rawValue))
  // Fields both create and patch accept; only a patch has clearFields.
  func eventInput(creating: Bool) -> Value {
    var properties: [String: Value] = [:]
    let fields: KeyValuePairs<EventInput.CodingKeys, Value> = [
      .calendarId: describe(string, FieldDocs.EventInput.calendarId),
      .calendarName: describe(string, FieldDocs.EventInput.calendarName),
      .title: describe(string, FieldDocs.EventInput.title),
      .notes: describe(string, FieldDocs.EventInput.notes),
      .location: describe(string, FieldDocs.EventInput.location),
      .structuredLocation: describe(placeInput, FieldDocs.EventInput.structuredLocation),
      .url: describe(string, FieldDocs.EventInput.url),
      .startDate: describe(string, FieldDocs.EventInput.startDate),
      .endDate: describe(string, FieldDocs.EventInput.endDate),
      .allDayStartDate: describe(string, FieldDocs.EventInput.allDayStartDate),
      .allDayEndDate: describe(string, FieldDocs.EventInput.allDayEndDate),
      .timeZone: describe(string, FieldDocs.EventInput.timeZone),
      .availability: describe(writableAvailability, FieldDocs.EventInput.availability),
      .alarms: describe(array(alarmInput), FieldDocs.EventInput.alarms),
      .recurrence: describe(ruleInput, FieldDocs.EventInput.recurrence),
    ]
    for (key, value) in fields { properties[key.stringValue] = value }
    if !creating {
      properties[EventInput.CodingKeys.clearFields.stringValue] = describe(
        array(enumeration(EventClearValue.allCases.map(\.rawValue))),
        FieldDocs.EventInput.clearFields)
    }
    return object(
      properties, required: creating ? [EventInput.CodingKeys.title.stringValue] : [])
  }
  let span = describe(enumeration(EventSpan.allCases.map(\.rawValue)), FieldDocs.EventWrite.span)
  let allowNotifications = describe(
    primitive(.boolean, ["default": false]), FieldDocs.EventWrite.allowAttendeeNotifications)
  // Event writes reach the calendar's server, which may notify other people.
  let eventCreated = Tool.Annotations(
    readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)
  let eventChanged = Tool.Annotations(
    readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true)
  let locationSearchResult = schema(
    LocationSearchResult.CodingKeys.self,
    [
      .name: describe(string, FieldDocs.LocationSearch.name),
      .address: describe(string, FieldDocs.LocationSearch.address),
      .latitude: describe(number, FieldDocs.LocationSearch.latitude),
      .longitude: describe(number, FieldDocs.LocationSearch.longitude),
    ], required: [.latitude, .longitude])
  return [
    Tool(
      name: ToolName.locationsSearch.rawValue,
      description: FieldDocs.LocationSearch.description,
      inputSchema: schema(
        LocationSearchArguments.CodingKeys.self,
        [
          .query: describe(string, FieldDocs.LocationSearch.query),
          .limit: describe(
            primitive(.integer, ["minimum": 1, "maximum": 10, "default": 5]),
            FieldDocs.LocationSearch.limit),
        ], required: [.query]),
      annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: true),
      outputSchema: schema(
        LocationSearchOutput.CodingKeys.self,
        [.items: array(locationSearchResult)], required: [.items])),
    Tool(
      name: ToolName.eventsCreate.rawValue,
      description: FieldDocs.EventWrite.create,
      inputSchema: eventInput(creating: true), annotations: eventCreated,
      outputSchema: eventResult(event, "The saved event.")),
    Tool(
      name: ToolName.eventsUpdate.rawValue,
      description: FieldDocs.EventWrite.update,
      inputSchema: schema(
        EventUpdateArguments.CodingKeys.self,
        [
          .id: describe(string, FieldDocs.EventWrite.id),
          .patch: describe(eventInput(creating: false), "Fields to change; at least one."),
          .span: span, .allowAttendeeNotifications: allowNotifications,
        ], required: [.id, .patch]),
      annotations: eventChanged, outputSchema: eventResult(event, "The saved event.")),
    Tool(
      name: ToolName.eventsDelete.rawValue,
      description: FieldDocs.EventWrite.delete,
      inputSchema: schema(
        EventDeleteArguments.CodingKeys.self,
        [
          .id: describe(string, FieldDocs.EventWrite.id),
          .span: span, .allowAttendeeNotifications: allowNotifications,
        ], required: [.id]),
      annotations: eventChanged, outputSchema: deleted),
    Tool(
      name: ToolName.calendarsCreate.rawValue,
      description:
        "Create an event calendar in an account. A WRITE_APPLIED error names a calendar that was saved before a later step failed; do not retry creation blindly.",
      inputSchema: schema(
        CalendarInput.CodingKeys.self,
        [
          .name: describe(string, FieldDocs.CreateCalendarInput.name),
          .color: describe(string, FieldDocs.CreateCalendarInput.color),
          .accountId: describe(string, FieldDocs.CreateCalendarInput.accountId),
        ], required: [.name, .accountId]),
      annotations: created, outputSchema: calendarResult),
    Tool(
      name: ToolName.calendarsUpdate.rawValue,
      description:
        "Update a calendar's name or color. Omit unchanged fields. A WRITE_APPLIED error means the save succeeded; refetch before retrying.",
      inputSchema: schema(
        PatchArguments<CalendarInput>.CodingKeys.self,
        [
          .id: describe(string, "Unique identifier of the calendar."),
          .patch: describe(calendarPatch, "Fields to change; at least one."),
        ], required: [.id, .patch]),
      annotations: changed, outputSchema: calendarResult),
    Tool(
      name: ToolName.calendarsDelete.rawValue,
      description: FieldDocs.DeleteCalendar.description,
      inputSchema: schema(
        CalendarDeleteArguments.CodingKeys.self,
        [
          .id: describe(string, "Unique identifier of the calendar."),
          .allowNonEmpty: describe(
            primitive(.boolean, ["default": false]), FieldDocs.DeleteCalendar.allowNonEmpty),
        ], required: [.id]),
      annotations: changed, outputSchema: deleted),
    Tool(
      name: ToolName.accountsList.rawValue,
      description: "Read every account that has an accessible event calendar.",
      inputSchema: noArguments, annotations: annotations,
      outputSchema: schema(
        AccountsOutput.CodingKeys.self,
        [.items: describe(array(account), "Accounts, in identifier order.")], required: [.items])),
    Tool(
      name: ToolName.accountsGet.rawValue,
      description: "Read one account by ID; returns null when absent.",
      inputSchema: byID("account"), annotations: annotations,
      outputSchema: schema(
        AccountOutput.CodingKeys.self,
        [.account: describe(nullable(account), "The account, or null when absent.")],
        required: [.account])),
    Tool(
      name: ToolName.calendarsList.rawValue,
      description:
        "Read event calendars filtered by name, account IDs, editability, and subscription. Filters intersect. orderBy.direction selects case-insensitive name ordering with ID ascending ties; omission uses identifier order. Pagination uses limit and cursor; keep the criteria unchanged across pages.",
      inputSchema: calendarSearch, annotations: annotations,
      outputSchema: page(
        CalendarRecord.self, calendar, FieldDocs.CalendarPage.items,
        FieldDocs.CalendarPage.totalCount)),
    Tool(
      name: ToolName.calendarsGet.rawValue,
      description: "Read one calendar by ID; returns null when absent.",
      inputSchema: byID("calendar"), annotations: annotations,
      outputSchema: schema(
        CalendarOutput.CodingKeys.self,
        [.calendar: describe(nullable(calendar), "The calendar, or null when absent.")],
        required: [.calendar])),
    Tool(
      name: ToolName.calendarsSummary.rawValue,
      description:
        "Count the events overlapping a window in each accessible calendar, optionally restricted to calendarId. Repeating events count once per occurrence; the attribute counts overlap. from defaults to now and before to 30 days later.",
      inputSchema: schema(
        SummaryArguments.CodingKeys.self,
        [
          .calendarId: describe(
            string, "Count only this calendar; omit for every accessible calendar."),
          .from: from, .before: before,
        ]),
      annotations: annotations,
      outputSchema: schema(
        SummaryOutput.CodingKeys.self,
        [.items: describe(array(summary), "Counts for each calendar.")], required: [.items])),
    Tool(
      name: ToolName.eventsSearch.rawValue,
      description:
        "Read events overlapping a window of time, with repeating events expanded into their occurrences. from defaults to now and before to 30 days later; the window may span at most 1096 days, and the result echoes it. Filters intersect; empty ID arrays match nothing. query matches the title, notes, or location. Results sort by start unless orderBy says otherwise, nulls last, ties by start then ID. Cursor is the next page offset; keep from, before, criteria, and limit unchanged across pages. All-day events report allDayStartDate and an inclusive allDayEndDate instead of timestamps. Attendees are read-only. A stored alarm or recurrence that cannot be represented is null and named in unsupported.",
      inputSchema: eventSearch, annotations: annotations,
      outputSchema: schema(
        EventPageOutput.CodingKeys.self,
        [
          .items: describe(array(event), FieldDocs.EventPage.items),
          .totalCount: describe(integer, FieldDocs.EventPage.totalCount),
          .nextCursor: describe(string, "Cursor for the next page; omitted on the last page."),
          .from: describe(string, FieldDocs.EventWindow.resolvedFrom),
          .before: describe(string, FieldDocs.EventWindow.resolvedBefore),
        ], required: [.items, .totalCount, .from, .before])),
    Tool(
      name: ToolName.eventsGet.rawValue,
      description:
        "Read one event or occurrence by the id a search returned; returns null when absent. A series id returns the first occurrence of the repeating event.",
      inputSchema: byID("event or occurrence"), annotations: annotations,
      outputSchema: eventResult(nullable(event), "The event, or null when absent.")),
    Tool(
      name: ToolName.defaultsGet.rawValue,
      description:
        "Read the default calendar for new events and its account; unavailable defaults return null.",
      inputSchema: noArguments, annotations: annotations,
      outputSchema: schema(
        DefaultsOutput.CodingKeys.self,
        [
          .calendar: describe(
            nullable(calendar), "The default calendar, or null when unavailable."),
          .account: describe(nullable(account), "The default calendar's account, or null."),
        ], required: [.calendar, .account])),
  ]
}
// MCP inputs omit optional values; an explicit null anywhere is invalid.
private func rejectNulls(_ value: Value) throws {
  switch value {
  case .null: throw ServerError.invalidArgument("Omit optional MCP inputs instead of sending null")
  case .object(let object): for value in object.values { try rejectNulls(value) }
  case .array(let array): for value in array { try rejectNulls(value) }
  default: break
  }
}
private func result<T: Encodable>(_ value: T) throws -> CallTool.Result {
  let bytes = try JSONEncoder().encode(value)
  return try .init(
    content: [.text(text: String(decoding: bytes, as: UTF8.self), annotations: nil, _meta: nil)],
    structuredContent: try JSONDecoder().decode(Value.self, from: bytes), isError: false)
}
// Tool names are the MCP contract; the catalog and dispatch both use these cases.
enum ToolName: String {
  case accountsGet = "accounts_get"
  case accountsList = "accounts_list"
  case calendarsCreate = "calendars_create"
  case calendarsDelete = "calendars_delete"
  case calendarsGet = "calendars_get"
  case calendarsList = "calendars_list"
  case calendarsSummary = "calendars_summary"
  case calendarsUpdate = "calendars_update"
  case defaultsGet = "defaults_get"
  case eventsCreate = "events_create"
  case eventsDelete = "events_delete"
  case eventsGet = "events_get"
  case eventsSearch = "events_search"
  case eventsUpdate = "events_update"
  case locationsSearch = "locations_search"
}
private func callTool(_ tool: ToolName, _ params: CallTool.Parameters) async throws
  -> CallTool.Result
{
  let args = params.arguments ?? [:]
  try rejectNulls(.object(args))
  func arguments<T: Decodable>(_ type: T.Type) throws -> T { try decodeInput(type, from: args) }
  func noArguments() throws {
    guard args.isEmpty else { throw ServerError.invalidArgument("Unknown input field") }
  }
  func ids(_ field: [String]?, _ name: String) throws -> [String]? {
    if field?.contains("") == true {
      throw ServerError.invalidArgument("\(name) must contain nonempty identifiers")
    }
    return field
  }
  // The page at the cursor offset; nextCursor is the following page's offset, and the
  // client keeps the criteria unchanged.
  func page<Item: Encodable>(
    _ items: [Item], limit: Int?, cursor: String?
  ) throws -> PageOutput<Item> {
    let limit = limit ?? 50
    guard (1...100).contains(limit) else {
      throw ServerError.invalidArgument("limit must be 1...100")
    }
    let offset =
      try cursor.map { token in
        guard let value = Int(token), value >= 0 else {
          throw ServerError.invalidArgument(
            "cursor must be a nextCursor string from the previous response. Omit cursor for the first page."
          )
        }
        return value
      } ?? 0
    let pageItems = Array(items.dropFirst(offset).prefix(limit))
    let end = offset + pageItems.count
    return PageOutput(
      items: pageItems, totalCount: items.count, nextCursor: end < items.count ? String(end) : nil)
  }
  func calendars() async throws -> CalendarData { try await onMainActor { try readCalendars() } }
  // CalendarRecord holds plain values, so its response cannot fail to encode.
  func savedCalendar(_ request: CalendarWrite) async throws -> CallTool.Result {
    try result(CalendarOutput(calendar: try await writeCalendar(request)))
  }
  func savedEvent(_ request: EventWrite) async throws -> CallTool.Result {
    try result(EventOutput(event: MCPEvent(record: try await writeEvent(request))))
  }
  switch tool {
  case .locationsSearch:
    return try await result(
      LocationSearchOutput(items: searchLocations(arguments(LocationSearchArguments.self))))
  case .eventsCreate:
    let input = try arguments(EventInput.self)
    return try await savedEvent(.create(changes: eventChanges(input, creating: true)))
  case .eventsUpdate:
    let update = try arguments(EventUpdateArguments.self)
    return try await savedEvent(
      .update(
        id: update.id, changes: eventChanges(update.patch, creating: false), span: update.span,
        allowAttendeeNotifications: update.allowAttendeeNotifications ?? false))
  case .eventsDelete:
    let delete = try arguments(EventDeleteArguments.self)
    return try await result(
      deleteEvent(
        id: delete.id, span: delete.span,
        allowAttendeeNotifications: delete.allowAttendeeNotifications ?? false))
  case .calendarsCreate:
    let input = try arguments(CalendarInput.self)
    return try await savedCalendar(
      .create(
        accountID: input.accountId.required("accountId"),
        changes: calendarChanges(input, creating: true)))
  case .calendarsUpdate:
    let update = try arguments(PatchArguments<CalendarInput>.self)
    return try await savedCalendar(
      .update(id: update.id, changes: calendarChanges(update.patch, creating: false)))
  case .calendarsDelete:
    let delete = try arguments(CalendarDeleteArguments.self)
    return try await result(
      deleteCalendar(id: delete.id, allowNonEmpty: delete.allowNonEmpty ?? false))
  case .accountsGet:
    let id = try arguments(IDArguments.self).id
    return try result(AccountOutput(account: await calendars().accounts.first { $0.id == id }))
  case .accountsList:
    try noArguments()
    return try result(AccountsOutput(items: await calendars().accounts))
  case .calendarsList:
    let search = try arguments(CalendarSearchArguments.self)
    var criteria = Search()
    if let filter = search.filter {
      criteria.query = filter.query
      criteria.accountIds = try ids(filter.accountIds, "accountIds")
      criteria.allowsContentModifications = filter.allowsContentModifications
      criteria.subscribed = filter.subscribed
    }
    if let order = search.orderBy {
      criteria.sortCalendarsByName = true
      criteria.direction = order.direction ?? .ascending
    }
    return try await result(
      page(criteria.calendars(calendars()), limit: search.limit, cursor: search.cursor))
  case .calendarsGet:
    let id = try arguments(IDArguments.self).id
    return try result(CalendarOutput(calendar: await calendars().calendars.first { $0.id == id }))
  case .calendarsSummary:
    let request = try arguments(SummaryArguments.self)
    var criteria = Search()
    criteria.from = request.from
    criteria.before = request.before
    let window = try criteria.window(now: Date())
    let scope = request.calendarId.map { [$0] }
    let data = try await onMainActor { try readEvents(window: window, calendarIds: scope) }
    let events = criteria.events(data)
    return try result(
      SummaryOutput(
        items: data.calendars.calendars.filter { scope == nil || scope!.contains($0.id) }.map {
          summarize(events, window: window, calendarId: $0.id)
        }))
  case .eventsGet:
    let id = try arguments(IDArguments.self).id
    return try result(
      EventOutput(event: await onMainActor { try readEvent(id: id) }.map(MCPEvent.init(record:))))
  case .eventsSearch:
    let search = try arguments(EventSearchArguments.self)
    var criteria = Search()
    criteria.from = search.from
    criteria.before = search.before
    if let filter = search.filter {
      criteria.query = filter.query
      criteria.titleContains = filter.titleContains
      criteria.calendarIds = try ids(filter.calendarIds, "calendarIds")
      criteria.accountIds = try ids(filter.accountIds, "accountIds")
      criteria.allDay = filter.allDay
      criteria.recurring = filter.recurring
      criteria.detached = filter.detached
      criteria.hasAttendees = filter.hasAttendees
      criteria.hasAlarms = filter.hasAlarms
      criteria.availabilities = filter.availabilities
      criteria.statuses = filter.statuses
      criteria.myStatuses = filter.myStatuses
    }
    if let order = search.orderBy {
      criteria.eventOrder = order.field
      criteria.direction = order.direction ?? .ascending
    }
    let window = try criteria.window(now: Date())
    // Check paging before the fetch, so a bad limit or cursor does not cost a read.
    _ = try page([Int](), limit: search.limit, cursor: search.cursor)
    let calendarIds = criteria.calendarIds
    let accountIds = criteria.accountIds
    let data = try await onMainActor {
      try readEvents(window: window, calendarIds: calendarIds, accountIds: accountIds)
    }
    let output = try page(
      criteria.events(data).map(MCPEvent.init(record:)), limit: search.limit,
      cursor: search.cursor)
    return try result(
      EventPageOutput(
        items: output.items, totalCount: output.totalCount,
        nextCursor: output.nextCursor, from: timestamp(window.from),
        before: timestamp(window.before)))
  case .defaultsGet:
    try noArguments()
    let data = try await calendars()
    return try result(
      DefaultsOutput(calendar: data.defaultCalendar, account: data.defaultAccount))
  }
}
private let tools = toolsCatalog()
// A tool without readOnlyHint requires write access.
private let readOnlyTools = Set(tools.filter { $0.annotations.readOnlyHint == true }.map(\.name))

func mcpToolsJSON() throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  return String(decoding: try encoder.encode(ListTools.Result(tools: tools)), as: UTF8.self)
}

// Tool errors are JSON like successful results, with the code clients act on.
private struct ToolError: Encodable {
  struct Body: Encodable {
    let code: ErrorCode
    let message: String
  }
  let error: Body
}
private func errorText(_ error: Error) -> String {
  let server = error as? ServerError
  let payload = ToolError(
    error: .init(
      code: server?.code ?? .internalError, message: server?.message ?? String(describing: error)))
  // Sorted keys put code before message; JSONEncoder does not keep declaration order.
  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  // A code and a message are plain strings, which always encode.
  return String(decoding: try! encoder.encode(payload), as: UTF8.self)
}

// The JSON-RPC method of a request body, for logging.
private func jsonRPCMethod(_ body: Data) -> String {
  switch try? JSONDecoder().decode(RPCEnvelope.self, from: body) {
  case .message(let method?, _): method
  case .batch: "batch"
  default: "unknown"
  }
}
// The JSON-RPC envelope fields the server logs; params and results stay undecoded.
private enum RPCEnvelope: Decodable {
  case message(method: String?, hasError: Bool)
  case batch
  enum CodingKeys: String, CodingKey { case method, error }
  init(from decoder: Decoder) throws {
    guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
      _ = try decoder.unkeyedContainer()
      self = .batch
      return
    }
    self = .message(
      method: try? c.decode(String.self, forKey: .method), hasError: c.contains(.error))
  }
}

// Records the tool outcome so the logger need not reparse large result bodies.
private final class ToolOutcome: @unchecked Sendable {
  var ran = false
  var failed = false
}
@Sendable func handleMCP(
  method: HTTPMethod, headers: [String: String], body: Data,
  access: Capabilities.Access
) async throws -> ServiceResponse {
  let outcome = ToolOutcome()
  // Each HTTP request has isolated SDK protocol state, permitting independent clients.
  // The HTTP listener enforces Origin policy for all endpoints.
  let transport = StatelessHTTPServerTransport(
    validationPipeline: StandardValidationPipeline(validators: [
      AcceptHeaderValidator(mode: .jsonOnly),
      ContentTypeValidator(),
      ProtocolVersionValidator(),
    ]))
  let server = Server(
    name: "apple-calendar-server", version: "0.1.0",
    capabilities: .init(tools: .init(listChanged: false)))
  await server.withMethodHandler(ListTools.self) { params in
    guard params.cursor == nil else { throw MCPError.invalidParams("Tool catalog has no cursor") }
    outcome.ran = true
    return .init(tools: tools)
  }
  await server.withMethodHandler(CallTool.self) { params in
    guard let tool = ToolName(rawValue: params.name) else {
      throw MCPError.invalidParams("Unknown tool")
    }
    outcome.ran = true
    guard access == .write || (access == .read && readOnlyTools.contains(params.name)) else {
      outcome.failed = true
      return .init(
        content: [
          .text(text: "Forbidden: MCP write access required", annotations: nil, _meta: nil)
        ], isError: true)
    }
    do { return try await callTool(tool, params) } catch {
      outcome.failed = true
      return .init(
        content: [.text(text: errorText(error), annotations: nil, _meta: nil)], isError: true)
    }
  }
  do { try await server.start(transport: transport) } catch {
    await server.stop()
    throw error
  }
  let response = await transport.handleRequest(
    .init(method: method.rawValue, headers: headers, body: body, path: Route.mcp.rawValue))
  await server.stop()
  let responseBody = response.bodyData ?? Data()
  var failure: Failure? = outcome.failed ? .mcpTool : nil
  // Protocol replies (no tool or catalog handler ran) report errors in the JSON-RPC body.
  if !outcome.ran,
    case .message(_, hasError: true)? = try? JSONDecoder().decode(
      RPCEnvelope.self, from: responseBody)
  {
    failure = .mcpProtocol
  }
  var headers = HTTPHeaders(response.headers.map { ($0.key, $0.value) })
  if !headers.contains(name: "Content-Type") {
    headers.add(name: "Content-Type", value: "application/json")
  }
  return ServiceResponse(
    status: .init(statusCode: response.statusCode), headers: headers, body: responseBody,
    failure: failure,
    logMetadata: method == .POST ? ["rpc": jsonRPCMethod(body)] : [:])
}
