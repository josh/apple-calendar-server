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

func collectMetrics() async throws -> String {
  let data = try await onMainActor { try readCalendars() }
  let calendars = data.calendars
  let accounts = Set(calendars.map { $0.source.id })
  var lines: [String] = []
  func family(_ name: String, _ help: String) { lines += familyHeader(name, .gauge, help) }
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
  return lines.joined(separator: "\n") + "\n"
}
