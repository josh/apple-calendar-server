import Foundation

// One filter for GraphQL and MCP searches.
enum SortDirection: String, CaseIterable, Decodable, Sendable {
  case ascending = "ASC"
  case descending = "DESC"
}
struct Search: Sendable {
  // Calendars sort by name when sortCalendarsByName is set.
  var sortCalendarsByName = false
  var direction = SortDirection.ascending
  var query: String?
  var accountIds: [String]?
  // Calendar criteria.
  var allowsContentModifications: Bool?
  var subscribed: Bool?

  // Matching calendars, by name when ordered; `accountID` restricts to one account.
  func calendars(_ data: CalendarData, accountID: String? = nil) -> [CalendarRecord] {
    let text = query?.lowercased()
    var items = data.calendars.filter {
      (accountID == nil || $0.source.id == accountID)
        && (accountIds == nil || accountIds!.contains($0.source.id))
        && (text == nil || text!.isEmpty || $0.name.lowercased().contains(text!))
        && (allowsContentModifications == nil
          || $0.allowsContentModifications == allowsContentModifications)
        && (subscribed == nil || $0.subscribed == subscribed)
    }
    if sortCalendarsByName {
      items.sort {
        let a = $0.name.lowercased()
        let b = $1.name.lowercased()
        return a == b ? $0.id < $1.id : direction == .descending ? a > b : a < b
      }
    }
    return items
  }
}
