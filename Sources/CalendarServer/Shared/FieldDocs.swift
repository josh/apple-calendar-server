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
  enum EventWindow {
    static let from =
      "Inclusive start of the window events must overlap: an RFC 3339 timestamp, or YYYY-MM-DD for that day's midnight in the host zone. Defaults to now."
    static let before =
      "Exclusive end of the window, in the same forms. Defaults to 30 days after from. The window may span at most 1096 days."
    static let resolvedFrom = "The resolved inclusive start of the window."
    static let resolvedBefore =
      "The resolved exclusive end of the window. Send from and before back unchanged for later pages, because the defaults move with the clock."
  }
  enum EventOrder {
    static let field = "Property to sort by."
    static let direction =
      "Direction of ordering. Nulls sort last either way and ties use start, then identifier; without orderBy, events sort by start."
  }
  enum EventFilter {
    static let query = "Case-insensitive substring of the event title, notes, or location."
    static let titleContains = "Case-insensitive substring of the event title."
    static let calendarIds = "Match events in any of these calendars; [] matches nothing."
    static let accountIds = "Match events in any of these accounts; [] matches nothing."
    static let allDay = "Match all-day or timed events."
    static let recurring = "Match occurrences that carry recurrence rules, or events that do not."
    static let detached =
      "Match occurrences edited apart from their series, or events that are not."
    static let hasAttendees = "Match events with or without attendees."
    static let hasAlarms = "Match events with or without alarms."
    static let availabilities = "Match any of these availability values; [] matches nothing."
    static let statuses = "Match any of these event statuses; [] matches nothing."
    static let myStatuses =
      "Match events where the current user is an attendee with any of these participation statuses; [] matches nothing."
  }
  enum EventPage {
    static let items = "Events in this page."
    static let totalCount = "Number of matching events in the window before pagination."
  }
  enum Event {
    static let id =
      "Identifier of this event or occurrence. An occurrence of a repeating event is its series identifier, a slash, and its current start. Treat the value as opaque; it changes when an occurrence moves and can change after a write or a sync."
    static let seriesId =
      "Identifier shared by every occurrence of a repeating event; null for an event that does not repeat. As an id it names the whole series."
    static let eventIdentifier = "The identifier EventKit stores for the event, for reference only."
    static let externalId =
      "Identifier assigned by the calendar server. Occurrences and copies can share it, so it does not identify one event."
    static let calendarId = "Identifier of the owning calendar."
    static let title = "The title of the event."
    static let notes = "The notes attached to the event."
    static let location = "The location of the event as text."
    static let structuredLocation =
      "The location with coordinates, when the event stores one. Its title also appears as location."
    static let url = "The URL attached to the event."
    static let allDay = "Whether the event covers whole days rather than a time span."
    static let startDate = "When a timed event starts; null for an all-day event."
    static let endDate = "When a timed event ends; null for an all-day event."
    static let allDayStartDate =
      "The first day of an all-day event, in the host zone; null for a timed event."
    static let allDayEndDate =
      "The last day of an all-day event, inclusive; a one-day event has the same start and end. Null for a timed event."
    static let timeZone =
      "IANA time zone the event is anchored to; null for a floating event, including every all-day event."
    static let occurrenceDate =
      "The start EventKit reports for this occurrence within its series; null for an event that does not repeat. It is not a stable key: it has been observed to follow a detached occurrence that moves."
    static let detached = "Whether this occurrence was edited apart from its repeating series."
    static let recurring = "Whether the event carries recurrence rules."
    static let availability = "How the event shows on a free/busy schedule."
    static let status =
      "The event's status as the calendar server reports it. EventKit cannot change it."
    static let organizer = "Who organized the event; null when it has no organizer."
    static let attendees =
      "People, rooms, and resources invited to the event. EventKit cannot add, remove, or answer for attendees."
    static let myStatus =
      "The current user's own participation status; null when they are not an attendee."
    static let birthdayContactIdentifier =
      "Contacts identifier of the person a Birthdays-calendar event is for."
    static let creationDate = "When the event was created."
    static let modificationDate = "When the event was last modified."
    static let rawAlarms = "Alarms exactly as stored."
    static let alarms =
      "Configured alerts. An empty list means no alerts; a trigger this projection cannot represent, such as a location trigger, fails the field, and rawAlarms holds the stored values."
    static let recurrenceRules = "Recurrence rules exactly as stored."
    static let recurrence =
      "A single repeating schedule; null when the event does not repeat. Multiple rules fail the field, and recurrenceRules holds the stored rules."
  }
  enum Participant {
    static let name = "Display name, when known."
    static let url = "The participant's address, usually a mailto: URL."
    static let email = "Email address taken from a mailto: URL, when the address is one."
    static let status = "Whether the participant accepted, declined, or has yet to answer."
    static let role = "The participant's role in the event."
    static let type = "Whether the participant is a person, room, resource, or group."
    static let currentUser = "Whether this participant is the user of this Mac."
  }
  enum RawAlarm {
    static let action = "Stored alarm action: display, audio, email, procedure, or unknown."
    static let soundName = "Stored sound name, when set."
    static let emailAddress = "Stored email alarm recipient, when set."
    static let absoluteDate = "Absolute trigger time, when set."
    static let relativeOffset =
      "Seconds from the start date. Zero alone does not distinguish absolute and relative triggers."
    static let proximity = "none, enter, leave, or unknown."
    static let structuredLocation = "The location of a geofence trigger, when set."
  }
  enum StructuredLocation {
    static let title = "Display name of the location."
    static let latitude = "Latitude in degrees, when set."
    static let longitude = "Longitude in degrees, when set."
    static let radius = "Radius in meters; zero means the system default."
  }
  enum AbsoluteAlarm {
    static let at = "The date and time at which the alert triggers."
  }
  enum RelativeAlarm {
    static let offsetSeconds =
      "Seconds from the start date: negative before, zero at, positive after."
  }
  enum RecurrenceRule {
    static let frequency = "daily, weekly, monthly, yearly, or unknown."
    static let calendarIdentifier = "Calendar the rule is evaluated in."
    static let interval = "Frequency units between occurrences."
    static let firstDayOfTheWeek = "First day of the week, Sunday = 1; zero is unset."
    static let daysOfTheWeek = "Weekday constraints; empty when unconstrained."
    static let end = "When repetition stops; null for no end."
    static let daysOfTheMonth = "Selector values; empty when unconstrained."
    static let daysOfTheYear = "Selector values; empty when unconstrained."
    static let weeksOfTheYear = "Selector values; empty when unconstrained."
    static let monthsOfTheYear = "Selector values; empty when unconstrained."
    static let setPositions = "Selector values; empty when unconstrained."
  }
  enum RecurrenceDay {
    static let dayOfTheWeek = "Weekday, Sunday = 1."
    static let weekNumber = "Signed ordinal; zero means every occurrence."
  }
  enum RecurrenceEnd {
    static let endDate = "End timestamp, when set."
    static let occurrenceCount = "Number of occurrences; zero when unset."
  }
  enum Schedule {
    static let frequency = "The unit of repetition."
    static let interval = "Positive number of frequency units between occurrences."
    static let daysOfWeek =
      "Weekday constraints. Null means unconstrained. Not allowed for daily rules."
    static let daysOfWeekNames =
      "Weekday phrases such as tuesday or second tuesday, ignoring case. Ordinals: first through fifth and last through fifth-to-last. Mutually exclusive with daysOfWeek."
    static let end = "When repetition stops; null means no specified end."
    static let daysOfMonth =
      "Days 1..31 or -31..-1 counting backward from the end of the month. Monthly rules only."
    static let monthsOfYear = "Months 1..12. Yearly rules only."
    static let weeksOfYear =
      "Week numbers 1..53 or -53..-1 counting backward from year end. Yearly rules only."
    static let daysOfYear =
      "Year days 1..366 or -366..-1 counting backward from year end. Yearly rules only."
    static let setPositions =
      "Select positions 1..366 or -366..-1 from occurrences matching the other constraints in each period. Requires another selector."
  }
  enum ScheduleDay {
    static let day = "The weekday to match."
    static let ordinal =
      "Occurrence of this weekday: 1 is first, -1 last; omit for every occurrence. Valid range -53..53 excluding zero; non-null ordinals require monthly or yearly frequency."
  }
  enum ScheduleEnd {
    static let until = "Inclusive end timestamp; mutually exclusive with count."
    static let count = "Positive number of occurrences; mutually exclusive with until."
  }
}
