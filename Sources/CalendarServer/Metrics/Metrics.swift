import Foundation

import struct os.OSAllocatedUnfairLock

private let processStart = Date()
private struct RequestKey: Hashable { let route: String, code: Int }
private let requestCounts = OSAllocatedUnfairLock<[RequestKey: Int]>(initialState: [:])

func recordRequest(route: String, code: Int) {
  requestCounts.withLock { $0[RequestKey(route: route, code: code), default: 0] += 1 }
}

// Prometheus metric types the exposition uses.
enum MetricType: String { case counter, gauge }
private func familyHeader(_ name: String, _ type: MetricType, _ help: String) -> [String] {
  ["# HELP \(name) \(help)", "# TYPE \(name) \(type.rawValue)"]
}

// Served even when the EventKit gauges are not: a failed EventKit read must not
// blank the request and liveness series that explain it.
func runtimeMetrics(eventKitUp: Bool, authorizing: Bool) -> String {
  var lines: [String] = []
  lines += familyHeader(
    "process_start_time_seconds", .gauge,
    "Start time of the process since the Unix epoch; a change is a restart.")
  lines.append("process_start_time_seconds \(Int(processStart.timeIntervalSince1970))")
  lines += familyHeader(
    "calendar_http_requests_total", .counter, "HTTP requests answered, by route and status code.")
  let counts = requestCounts.withLock { $0 }
  for (key, count) in counts.sorted(by: {
    ($0.key.route, $0.key.code) < ($1.key.route, $1.key.code)
  }) {
    lines.append(
      "calendar_http_requests_total{route=\"\(metricEscape(key.route))\",code=\"\(key.code)\"} \(count)"
    )
  }
  lines += familyHeader(
    "calendar_main_actor_heartbeat_age_seconds", .gauge,
    "Seconds since the main actor last ran a watchdog heartbeat; the process exits past \(mainActorWatchdogLimit.components.seconds)."
  )
  lines.append(
    "calendar_main_actor_heartbeat_age_seconds \(mainActorHeartbeatAge() / .seconds(1))")
  lines += familyHeader(
    "calendar_authorization_pending", .gauge,
    "1 while the startup Calendar access request has not finished; /graphql and /mcp answer 503 meanwhile."
  )
  lines.append("calendar_authorization_pending \(authorizing ? 1 : 0)")
  lines += familyHeader(
    "calendar_eventkit_up", .gauge,
    "1 when the last background EventKit read succeeded and its gauges follow.")
  lines.append("calendar_eventkit_up \(eventKitUp ? 1 : 0)")
  return lines.joined(separator: "\n") + "\n"
}

func metricEscape(_ text: String) -> String {
  text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
    .replacingOccurrences(of: "\"", with: "\\\"")
}
actor MetricsCollector {
  private(set) var exposition: String?

  func run(interval: Duration) async {
    var failed = false
    var delay = interval
    while !Task.isCancelled {
      do {
        exposition = try await collectMetrics()
        if failed { serverLogger.info("Metrics collection recovered") }
        failed = false
        delay = interval
      } catch {
        logFailure("Metrics collection failed", error: error)
        exposition = nil
        // Retry after a minute, doubling toward the interval so a lasting failure stays quiet.
        delay = failed ? min(delay * 2, interval) : min(.seconds(60), interval)
        failed = true
      }
      do { try await Task.sleep(for: delay) } catch { return }
    }
  }
}

// calendar_events labels; case order is the exposition order. The windows partition the
// days around today by each event's host-zone start day.
private enum DayWindow: String, CaseIterable {
  case pastMonth = "past_month"
  case pastWeek = "past_week"
  case today
  case nextWeek = "next_week"
  case nextMonth = "next_month"
  // Days before today reach back this far, and days after reach as far ahead.
  static let reach = 30
  init?(daysFromToday days: Int) {
    switch days {
    case -Self.reach ... -8: self = .pastMonth
    case -7 ... -1: self = .pastWeek
    case 0: self = .today
    case 1...7: self = .nextWeek
    case 8...Self.reach: self = .nextMonth
    default: return nil
    }
  }
}
private enum EventKind: String, CaseIterable {
  case timed
  case allDay = "all_day"
}
private struct EventBucket: Hashable {
  let calendarId: String
  let window: DayWindow
  let kind: EventKind
}

func collectMetrics() async throws -> String {
  // One observation instant places every event; day windows use the host zone.
  let now = Date()
  let today = startOfLocalDay(containing: now)
  let window = EventWindow(
    from: addingLocalDays(-DayWindow.reach, to: today),
    before: addingLocalDays(DayWindow.reach + 1, to: today))
  let data = try await onMainActor { try readEvents(window: window) }
  let calendars = data.calendars.calendars
  let accounts = Set(calendars.map { $0.source.id })
  var lines: [String] = []
  func family(_ name: String, _ help: String) { lines += familyHeader(name, .gauge, help) }
  family(
    "calendar_observation_timestamp_seconds",
    "When the event gauges were read, since the Unix epoch; day windows are relative to it.")
  lines.append("calendar_observation_timestamp_seconds \(Int(now.timeIntervalSince1970))")
  family("calendar_accounts", "Number of accounts with accessible event calendars.")
  lines.append("calendar_accounts \(accounts.count)")
  family("calendar_calendars", "Number of accessible event calendars in an account.")
  for account in accounts.sorted() {
    let count = calendars.count { $0.source.id == account }
    lines.append("calendar_calendars{account_id=\"\(metricEscape(account))\"} \(count)")
  }
  family("calendar_calendar_info", "Calendar identity, name, and type, with value 1.")
  for calendar in calendars {
    lines.append(
      "calendar_calendar_info{account_id=\"\(metricEscape(calendar.source.id))\",calendar_id=\"\(metricEscape(calendar.id))\",name=\"\(metricEscape(calendar.name))\",type=\"\(calendar.type.rawValue)\"} 1"
    )
  }
  // Each occurrence lands in the one window its start day belongs to; an event that
  // began before the earliest window is not counted.
  var counts: [EventBucket: Int] = [:]
  var recurring: [EventBucket: Int] = [:]
  var withAttendees: [EventBucket: Int] = [:]
  var withAlarms: [EventBucket: Int] = [:]
  var inProgress: [String: Int] = [:]
  for event in data.events {
    if !event.allDay && event.start <= now && now < event.end {
      inProgress[event.calendarId, default: 0] += 1
    }
    guard let window = DayWindow(daysFromToday: localDays(from: now, to: event.start)) else {
      continue
    }
    let bucket = EventBucket(
      calendarId: event.calendarId, window: window, kind: event.allDay ? .allDay : .timed)
    counts[bucket, default: 0] += 1
    if event.recurring { recurring[bucket, default: 0] += 1 }
    if !event.attendees.isEmpty { withAttendees[bucket, default: 0] += 1 }
    if !event.alarms.isEmpty { withAlarms[bucket, default: 0] += 1 }
  }
  func labels(_ calendar: CalendarRecord) -> String {
    "account_id=\"\(metricEscape(calendar.source.id))\",calendar_id=\"\(metricEscape(calendar.id))\""
  }
  family(
    "calendar_events",
    "Events and occurrences by the window their start day falls in (past_month days -30 to -8, past_week -7 to -1, today, next_week 1 to 7, next_month 8 to 30) and kind."
  )
  for calendar in calendars {
    for window in DayWindow.allCases {
      for kind in EventKind.allCases {
        let count =
          counts[EventBucket(calendarId: calendar.id, window: window, kind: kind), default: 0]
        lines.append(
          "calendar_events{\(labels(calendar)),window=\"\(window.rawValue)\",kind=\"\(kind.rawValue)\"} \(count)"
        )
      }
    }
  }
  for (name, values, what) in [
    ("calendar_recurring_events", recurring, "recurrence rules"),
    ("calendar_events_with_attendees", withAttendees, "attendees"),
    ("calendar_events_with_alarms", withAlarms, "alarms"),
  ] {
    family(name, "Events and occurrences with \(what), by the window their start day falls in.")
    for calendar in calendars {
      for window in DayWindow.allCases {
        let count = EventKind.allCases.reduce(0) {
          $0 + values[EventBucket(calendarId: calendar.id, window: window, kind: $1), default: 0]
        }
        lines.append("\(name){\(labels(calendar)),window=\"\(window.rawValue)\"} \(count)")
      }
    }
  }
  family(
    "calendar_events_in_progress",
    "Timed events that had started and not yet ended when the gauges were read.")
  for calendar in calendars {
    lines.append(
      "calendar_events_in_progress{\(labels(calendar))} \(inProgress[calendar.id, default: 0])")
  }
  return lines.joined(separator: "\n") + "\n"
}
