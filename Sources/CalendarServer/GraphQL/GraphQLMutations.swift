import Foundation
import GraphQL

// A write can change what this request already read, so the request's cached reads are
// dropped afterward, whether or not it succeeded.
private func afterWrite<T: Sendable>(
  _ context: (any Sendable)?, _ write: () async throws -> T
) async throws -> T {
  let value: T
  do { value = try await write() } catch {
    await (context as? GraphQLContext)?.invalidate()
    throw error
  }
  await (context as? GraphQLContext)?.invalidate()
  return value
}

// An input object's fields, named by the coding keys its decoder reads, in schema order.
private func inputFields<Key: CodingKey>(
  _: Key.Type, _ fields: KeyValuePairs<Key, InputObjectField>
) -> InputObjectFieldMap {
  InputObjectFieldMap(uniqueKeysWithValues: fields.map { ($0.key.stringValue, $0.value) })
}

func makeMutationType(
  calendar: GraphQLObjectType, event: GraphQLObjectType, dateTime: GraphQLScalarType,
  localDate: GraphQLScalarType, url: GraphQLScalarType, availability: GraphQLEnumType,
  frequency: GraphQLEnumType, weekday: GraphQLEnumType
) throws -> GraphQLObjectType {
  let alarm = try GraphQLInputObjectType(
    name: "EventAlarmInput",
    fields: inputFields(
      AlarmInput.CodingKeys.self,
      [
        .absoluteDate: InputObjectField(
          type: dateTime, description: FieldDocs.AlarmInput.absoluteDate),
        .relativeOffsetSeconds: InputObjectField(
          type: GraphQLFloat, description: FieldDocs.AlarmInput.relativeOffsetSeconds),
        .soundName: InputObjectField(
          type: GraphQLString, description: FieldDocs.AlarmInput.soundName),
        .emailAddress: InputObjectField(
          type: GraphQLString, description: FieldDocs.AlarmInput.emailAddress),
      ]))
  let place = try GraphQLInputObjectType(
    name: "StructuredLocationInput",
    fields: inputFields(
      StructuredLocationInput.CodingKeys.self,
      [
        .title: InputObjectField(
          type: GraphQLNonNull(GraphQLString), description: FieldDocs.StructuredLocationInput.title),
        .latitude: InputObjectField(
          type: GraphQLNonNull(GraphQLFloat), description: FieldDocs.LocationSearch.latitude),
        .longitude: InputObjectField(
          type: GraphQLNonNull(GraphQLFloat), description: FieldDocs.LocationSearch.longitude),
        .radiusMeters: InputObjectField(
          type: GraphQLFloat, description: FieldDocs.StructuredLocationInput.radiusMeters),
      ]))
  let ruleDay = try GraphQLInputObjectType(
    name: "RecurrenceDayInput",
    fields: inputFields(
      RecurrenceInput.Day.CodingKeys.self,
      [
        .day: InputObjectField(
          type: GraphQLNonNull(weekday), description: FieldDocs.ScheduleDay.day),
        .ordinal: InputObjectField(type: GraphQLInt, description: FieldDocs.ScheduleDay.ordinal),
      ]))
  let ruleEnd = try GraphQLInputObjectType(
    name: "RecurrenceEndInput",
    fields: inputFields(
      RecurrenceInput.End.CodingKeys.self,
      [
        .until: InputObjectField(type: dateTime, description: FieldDocs.ScheduleEnd.until),
        .count: InputObjectField(type: GraphQLInt, description: FieldDocs.ScheduleEnd.count),
      ]))
  let selectors = GraphQLList(GraphQLNonNull(GraphQLInt))
  let rule = try GraphQLInputObjectType(
    name: "RecurrenceRuleInput",
    fields: inputFields(
      RecurrenceInput.CodingKeys.self,
      [
        .frequency: InputObjectField(
          type: GraphQLNonNull(frequency), description: FieldDocs.Schedule.frequency),
        .interval: InputObjectField(
          type: GraphQLNonNull(GraphQLInt), description: FieldDocs.Schedule.interval),
        .daysOfWeek: InputObjectField(
          type: GraphQLList(GraphQLNonNull(ruleDay)), description: FieldDocs.Schedule.daysOfWeek),
        .daysOfWeekNames: InputObjectField(
          type: GraphQLList(GraphQLNonNull(GraphQLString)),
          description: FieldDocs.Schedule.daysOfWeekNames),
        .daysOfMonth: InputObjectField(
          type: selectors, description: FieldDocs.Schedule.daysOfMonth),
        .monthsOfYear: InputObjectField(
          type: selectors, description: FieldDocs.Schedule.monthsOfYear),
        .weeksOfYear: InputObjectField(
          type: selectors, description: FieldDocs.Schedule.weeksOfYear),
        .daysOfYear: InputObjectField(type: selectors, description: FieldDocs.Schedule.daysOfYear),
        .setPositions: InputObjectField(
          type: selectors, description: FieldDocs.Schedule.setPositions),
        .end: InputObjectField(type: ruleEnd, description: FieldDocs.Schedule.end),
      ]))
  let clear = try GraphQLEnumType(
    name: "EventClearField",
    values: GraphQLEnumValueMap(
      uniqueKeysWithValues: EventClearValue.allCases.map {
        ($0.rawValue, GraphQLEnumValue(value: .string($0.rawValue), description: $0.description))
      }))
  let span = try GraphQLEnumType(
    name: "EventSpan",
    values: [
      EventSpan.thisEvent.rawValue: GraphQLEnumValue(
        value: .string(EventSpan.thisEvent.rawValue), description: "Only this occurrence."),
      EventSpan.futureEvents.rawValue: GraphQLEnumValue(
        value: .string(EventSpan.futureEvents.rawValue),
        description: "This occurrence and every later one in its series."),
    ])
  // Fields both create and patch accept; create requires a title.
  func eventFields(creating: Bool) -> KeyValuePairs<EventInput.CodingKeys, InputObjectField> {
    [
      .calendarId: InputObjectField(type: GraphQLID, description: FieldDocs.EventInput.calendarId),
      .calendarName: InputObjectField(
        type: GraphQLString, description: FieldDocs.EventInput.calendarName),
      .title: InputObjectField(
        type: creating ? GraphQLNonNull(GraphQLString) : GraphQLString,
        description: FieldDocs.EventInput.title),
      .notes: InputObjectField(type: GraphQLString, description: FieldDocs.EventInput.notes),
      .location: InputObjectField(
        type: GraphQLString, description: FieldDocs.EventInput.location),
      .structuredLocation: InputObjectField(
        type: place, description: FieldDocs.EventInput.structuredLocation),
      .url: InputObjectField(type: url, description: FieldDocs.EventInput.url),
      .startDate: InputObjectField(type: dateTime, description: FieldDocs.EventInput.startDate),
      .endDate: InputObjectField(type: dateTime, description: FieldDocs.EventInput.endDate),
      .allDayStartDate: InputObjectField(
        type: localDate, description: FieldDocs.EventInput.allDayStartDate),
      .allDayEndDate: InputObjectField(
        type: localDate, description: FieldDocs.EventInput.allDayEndDate),
      .timeZone: InputObjectField(
        type: GraphQLString, description: FieldDocs.EventInput.timeZone),
      .availability: InputObjectField(
        type: availability, description: FieldDocs.EventInput.availability),
      .alarms: InputObjectField(
        type: GraphQLList(GraphQLNonNull(alarm)), description: FieldDocs.EventInput.alarms),
      .recurrence: InputObjectField(type: rule, description: FieldDocs.EventInput.recurrence),
    ]
  }
  let createEvent = try GraphQLInputObjectType(
    name: "CreateEventInput",
    fields: inputFields(EventInput.CodingKeys.self, eventFields(creating: true)))
  var patchFields = inputFields(EventInput.CodingKeys.self, eventFields(creating: false))
  patchFields[EventInput.CodingKeys.clearFields.stringValue] = InputObjectField(
    type: GraphQLList(GraphQLNonNull(clear)), description: FieldDocs.EventInput.clearFields)
  let eventPatch = try GraphQLInputObjectType(name: "EventPatch", fields: patchFields)
  let writeArgs: GraphQLArgumentConfigMap = [
    "id": GraphQLArgument(type: GraphQLNonNull(GraphQLID), description: FieldDocs.EventWrite.id),
    "span": GraphQLArgument(type: span, description: FieldDocs.EventWrite.span),
    "allowAttendeeNotifications": GraphQLArgument(
      type: GraphQLNonNull(GraphQLBoolean),
      description: FieldDocs.EventWrite.allowAttendeeNotifications, defaultValue: false),
  ]
  var updateArgs = writeArgs
  updateArgs["patch"] = GraphQLArgument(type: GraphQLNonNull(eventPatch))
  let deleted = try GraphQLObjectType(
    name: "DeleteResult",
    fields: [
      "deletedId": field(
        GraphQLNonNull(GraphQLID), \DeleteResult.deletedId,
        description: FieldDocs.DeleteResult.deletedId)
    ])
  let calendarPatch = try GraphQLInputObjectType(
    name: "CalendarPatch",
    fields: inputFields(
      CalendarInput.CodingKeys.self,
      [
        .name: InputObjectField(type: GraphQLString, description: FieldDocs.CalendarPatch.name),
        .color: InputObjectField(type: GraphQLString, description: FieldDocs.CalendarPatch.color),
      ]))
  let createCalendar = try GraphQLInputObjectType(
    name: "CreateCalendarInput",
    fields: inputFields(
      CalendarInput.CodingKeys.self,
      [
        .name: InputObjectField(
          type: GraphQLNonNull(GraphQLString), description: FieldDocs.CreateCalendarInput.name),
        .color: InputObjectField(
          type: GraphQLString, description: FieldDocs.CreateCalendarInput.color),
        .accountId: InputObjectField(
          type: GraphQLNonNull(GraphQLID), description: FieldDocs.CreateCalendarInput.accountId),
      ]))
  return try GraphQLObjectType(
    name: "Mutation",
    fields: [
      "createEvent": GraphQLField(
        type: event, description: FieldDocs.EventWrite.create,
        args: ["input": GraphQLArgument(type: GraphQLNonNull(createEvent))],
        resolve: { _, args, context, _ in
          let input = try decodeInput(GraphQLCreateArguments<EventInput>.self, from: args).input
          return try await afterWrite(context) {
            try await writeEvent(.create(changes: eventChanges(input, creating: true)))
          }
        }),
      "updateEvent": GraphQLField(
        type: event, description: FieldDocs.EventWrite.update, args: updateArgs,
        resolve: { _, args, context, _ in
          let update = try decodeInput(GraphQLEventUpdateArguments.self, from: args)
          return try await afterWrite(context) {
            try await writeEvent(
              .update(
                id: update.id, changes: eventChanges(update.patch, creating: false),
                span: update.span, allowAttendeeNotifications: update.allowAttendeeNotifications))
          }
        }),
      "deleteEvent": GraphQLField(
        type: deleted, description: FieldDocs.EventWrite.delete, args: writeArgs,
        resolve: { _, args, context, _ in
          let delete = try decodeInput(GraphQLEventDeleteArguments.self, from: args)
          return try await afterWrite(context) {
            try await deleteEvent(
              id: delete.id, span: delete.span,
              allowAttendeeNotifications: delete.allowAttendeeNotifications)
          }
        }),
      "createCalendar": GraphQLField(
        type: calendar,
        description:
          "Create an event calendar in an account. If reading it back fails, the error has code WRITE_APPLIED and names the saved ID; do not retry creation blindly.",
        args: ["input": GraphQLArgument(type: GraphQLNonNull(createCalendar))],
        resolve: { _, args, context, _ in
          let input = try decodeInput(GraphQLCreateArguments<CalendarInput>.self, from: args).input
          return try await afterWrite(context) {
            try await writeCalendar(
              .create(
                accountID: input.accountId.required("accountId"),
                changes: calendarChanges(input, creating: true)))
          }
        }),
      "updateCalendar": GraphQLField(
        type: calendar,
        description:
          "Update a calendar's name or color. An error with code WRITE_APPLIED means the save succeeded before a later failure; refetch the saved ID before retrying.",
        args: [
          "id": GraphQLArgument(type: GraphQLNonNull(GraphQLID)),
          "patch": GraphQLArgument(type: GraphQLNonNull(calendarPatch)),
        ],
        resolve: { _, args, context, _ in
          let update = try decodeInput(GraphQLPatchArguments<CalendarInput>.self, from: args)
          return try await afterWrite(context) {
            try await writeCalendar(
              .update(id: update.id, changes: calendarChanges(update.patch, creating: false)))
          }
        }),
      "deleteCalendar": GraphQLField(
        type: deleted, description: FieldDocs.DeleteCalendar.description,
        args: [
          "id": GraphQLArgument(type: GraphQLNonNull(GraphQLID)),
          "allowNonEmpty": GraphQLArgument(
            type: GraphQLNonNull(GraphQLBoolean), defaultValue: false),
        ],
        resolve: { _, args, context, _ in
          let delete = try decodeInput(GraphQLCalendarDeleteArguments.self, from: args)
          return try await afterWrite(context) {
            try await deleteCalendar(id: delete.id, allowNonEmpty: delete.allowNonEmpty)
          }
        }),
    ])
}
