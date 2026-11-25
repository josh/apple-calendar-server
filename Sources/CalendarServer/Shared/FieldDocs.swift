// Field descriptions shared by the GraphQL schema and the MCP catalog.
enum FieldDocs {
  enum Account {
    static let id = "Unique identifier of the account. Treat this value as opaque."
    static let name = "The name of the account."
  }
  enum CalendarFilter {
    static let query = "Case-insensitive substring of the calendar name."
    static let accountIds =
      "Match calendars in any of these accounts, intersected with the parent scope; [] matches nothing."
    static let allowsContentModifications = "Match whether events in the calendar can be modified."
    static let subscribed = "Match subscribed or unsubscribed calendars."
  }
  enum CalendarOrder {
    static let direction =
      "Direction of name ordering. Ties use identifier order; without orderBy, calendars use identifier order."
  }
  enum CalendarPage {
    static let items = "Calendars in this page."
    static let totalCount = "Number of matching calendars before pagination."
  }
  enum Calendar {
    static let id = "Unique identifier of the calendar. Treat this value as opaque."
    static let name = "The name of the calendar."
    static let color = "The color of the calendar as an sRGB #RRGGBBAA hex string."
    static let type =
      "How the calendar is stored: local, CalDAV (including iCloud), Exchange, a subscription, or the Birthdays calendar."
    static let allowsContentModifications =
      "Whether events can be added, edited, and deleted in this calendar."
    static let allowsCalendarModifications =
      "Whether the calendar's own properties can be edited and the calendar deleted: it must allow content changes and be neither immutable nor subscribed."
    static let subscribed = "Whether the calendar is a subscription."
    static let immutable =
      "Whether the calendar is fixed by the system, such as Birthdays, and cannot be edited or deleted."
    static let supportedAvailabilities =
      "Availability values events in this calendar can store; empty when the calendar does not support availability."
  }
}
