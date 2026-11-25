import Foundation

// Framework calls run as one main-actor job; the pool releases their temporaries.
// Only Sendable records come back.
func onMainActor<T: Sendable>(_ body: @MainActor () throws -> T) async throws -> T {
  try await MainActor.run { try autoreleasepool(invoking: body) }
}

func writeCalendar(_ request: CalendarWrite) async throws -> CalendarRecord {
  try await onMainActor { try executeCalendarWrite(request) }
}
func deleteCalendar(id: String, allowNonEmpty: Bool) async throws -> DeleteResult {
  try await executeCalendarDelete(id: id, allowNonEmpty: allowNonEmpty)
}
func writeEvent(_ request: EventWrite) async throws -> EventRecord {
  try await onMainActor { try executeEventWrite(request) }
}
func deleteEvent(id: String, span: EventSpan?, allowAttendeeNotifications: Bool) async throws
  -> DeleteResult
{
  try await onMainActor {
    try executeEventDelete(
      id: id, span: span, allowAttendeeNotifications: allowAttendeeNotifications)
  }
}
