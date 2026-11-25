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
