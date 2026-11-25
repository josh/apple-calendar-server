import Foundation

// Typed collection arguments. GraphQL has already checked their types and filled
// defaults; decoding gives resolvers named fields instead of map lookups.

struct GraphQLCalendarSearch: Decodable {
  let filter: Filter?
  let orderBy: Order?
  let limit, offset: Int

  struct Filter: Decodable, Sendable {
    let query: String?
    let accountIds: [String]?
    let allowsContentModifications, subscribed: Bool?
  }
  struct Order: Decodable, Sendable {
    let direction: SortDirection?
  }
}

struct GraphQLEventSearch: Decodable {
  let from, before: String?
  let filter: Filter?
  let orderBy: Order?
  let limit, offset: Int

  struct Filter: Decodable, Sendable {
    let query, titleContains: String?
    let calendarIds, accountIds: [String]?
    let allDay, recurring, detached, hasAttendees, hasAlarms: Bool?
    let availabilities: [EventAvailability]?
    let statuses: [EventStatus]?
    let myStatuses: [ParticipantStatus]?
  }
  struct Order: Decodable, Sendable {
    let field: EventSortField
    let direction: SortDirection?
  }
}

struct GraphQLWindowArguments: Decodable {
  let from, before: String?
}

struct GraphQLIDArguments: Decodable {
  let id: String
}

// Mutation arguments.

struct GraphQLCreateArguments<Input: Decodable>: Decodable {
  let input: Input
}

struct GraphQLPatchArguments<Patch: Decodable>: Decodable {
  let id: String
  let patch: Patch
}

struct GraphQLCalendarDeleteArguments: Decodable {
  let id: String
  let allowNonEmpty: Bool
}
