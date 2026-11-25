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

func makeMutationType(calendar: GraphQLObjectType) throws -> GraphQLObjectType {
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
