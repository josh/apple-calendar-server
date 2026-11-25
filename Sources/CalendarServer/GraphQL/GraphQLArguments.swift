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

struct GraphQLIDArguments: Decodable {
  let id: String
}
