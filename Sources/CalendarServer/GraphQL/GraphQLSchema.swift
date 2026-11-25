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
  func invalidate() {
    calendars = nil
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
  var accountFields = try account.fields()
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
  calendar.fields = { calendarFields }
  return try GraphQLSchema(
    query: GraphQLObjectType(
      name: "Query",
      fields: [
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
      ]))
}
