import Foundation

// Typed tool arguments. Each rejects keys its tool does not declare. MCP rejects
// explicit nulls before decoding, so optional fields are plain optionals.

struct IDArguments: Decodable {
  let id: String
  enum CodingKeys: String, CodingKey, CaseIterable { case id }
  init(from decoder: Decoder) throws {
    id = try decoder.inputContainer(keyedBy: CodingKeys.self).decode(String.self, forKey: .id)
    guard !id.isEmpty else { throw ServerError.invalidArgument("id required") }
  }
}

struct CalendarSearchArguments: Decodable {
  let filter: Filter?
  let orderBy: Order?
  let limit: Int?
  let cursor: String?

  struct Filter: Decodable {
    let query: String?
    let accountIds: [String]?
    let allowsContentModifications, subscribed: Bool?
    enum CodingKeys: String, CodingKey, CaseIterable {
      case query, accountIds, allowsContentModifications, subscribed
    }
    init(from decoder: Decoder) throws {
      let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
      query = try c.decodeIfPresent(String.self, forKey: .query)
      accountIds = try c.decodeIfPresent([String].self, forKey: .accountIds)
      allowsContentModifications = try c.decodeIfPresent(
        Bool.self, forKey: .allowsContentModifications)
      subscribed = try c.decodeIfPresent(Bool.self, forKey: .subscribed)
    }
  }
  struct Order: Decodable {
    let direction: SortDirection?
    enum CodingKeys: String, CodingKey, CaseIterable { case direction }
    init(from decoder: Decoder) throws {
      direction = try decoder.inputContainer(keyedBy: CodingKeys.self).decodeIfPresent(
        SortDirection.self, forKey: .direction)
    }
  }
  enum CodingKeys: String, CodingKey, CaseIterable { case filter, orderBy, limit, cursor }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    filter = try c.decodeIfPresent(Filter.self, forKey: .filter)
    orderBy = try c.decodeIfPresent(Order.self, forKey: .orderBy)
    limit = try c.decodeIfPresent(Int.self, forKey: .limit)
    cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
  }
}

struct SummaryArguments: Decodable {
  let calendarId, from, before: String?
  enum CodingKeys: String, CodingKey, CaseIterable { case calendarId, from, before }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    calendarId = try c.decodeIfPresent(String.self, forKey: .calendarId)
    from = try c.decodeIfPresent(String.self, forKey: .from)
    before = try c.decodeIfPresent(String.self, forKey: .before)
  }
}

struct EventSearchArguments: Decodable {
  let from, before: String?
  let filter: Filter?
  let orderBy: Order?
  let limit: Int?
  let cursor: String?

  struct Filter: Decodable {
    let query, titleContains: String?
    let calendarIds, accountIds: [String]?
    let allDay, recurring, detached, hasAttendees, hasAlarms: Bool?
    let availabilities: [EventAvailability]?
    let statuses: [EventStatus]?
    let myStatuses: [ParticipantStatus]?
    enum CodingKeys: String, CodingKey, CaseIterable {
      case query, titleContains, calendarIds, accountIds, allDay, recurring, detached
      case hasAttendees, hasAlarms, availabilities, statuses, myStatuses
    }
    init(from decoder: Decoder) throws {
      let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
      query = try c.decodeIfPresent(String.self, forKey: .query)
      titleContains = try c.decodeIfPresent(String.self, forKey: .titleContains)
      calendarIds = try c.decodeIfPresent([String].self, forKey: .calendarIds)
      accountIds = try c.decodeIfPresent([String].self, forKey: .accountIds)
      allDay = try c.decodeIfPresent(Bool.self, forKey: .allDay)
      recurring = try c.decodeIfPresent(Bool.self, forKey: .recurring)
      detached = try c.decodeIfPresent(Bool.self, forKey: .detached)
      hasAttendees = try c.decodeIfPresent(Bool.self, forKey: .hasAttendees)
      hasAlarms = try c.decodeIfPresent(Bool.self, forKey: .hasAlarms)
      availabilities = try c.decodeIfPresent([EventAvailability].self, forKey: .availabilities)
      statuses = try c.decodeIfPresent([EventStatus].self, forKey: .statuses)
      myStatuses = try c.decodeIfPresent([ParticipantStatus].self, forKey: .myStatuses)
    }
  }
  struct Order: Decodable {
    let field: EventSortField
    let direction: SortDirection?
    enum CodingKeys: String, CodingKey, CaseIterable { case field, direction }
    init(from decoder: Decoder) throws {
      let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
      field = try c.decode(EventSortField.self, forKey: .field)
      direction = try c.decodeIfPresent(SortDirection.self, forKey: .direction)
    }
  }
  enum CodingKeys: String, CodingKey, CaseIterable {
    case from, before, filter, orderBy, limit, cursor
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    from = try c.decodeIfPresent(String.self, forKey: .from)
    before = try c.decodeIfPresent(String.self, forKey: .before)
    filter = try c.decodeIfPresent(Filter.self, forKey: .filter)
    orderBy = try c.decodeIfPresent(Order.self, forKey: .orderBy)
    limit = try c.decodeIfPresent(Int.self, forKey: .limit)
    cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
  }
}
