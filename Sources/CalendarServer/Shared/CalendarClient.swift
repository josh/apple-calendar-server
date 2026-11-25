import Foundation

// Framework calls run as one main-actor job; the pool releases their temporaries.
// Only Sendable records come back.
func onMainActor<T: Sendable>(_ body: @MainActor () throws -> T) async throws -> T {
  try await MainActor.run { try autoreleasepool(invoking: body) }
}
