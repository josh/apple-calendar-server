import Foundation

// Calendar create and patch input. Only creation accepts accountId.
struct CalendarInput: Decodable, Sendable {
  let accountId, name, color: InputField<String>
  let containsNull: Bool

  enum CodingKeys: String, CodingKey, CaseIterable {
    case accountId, name, color
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    accountId = try c.field(.accountId)
    name = try c.field(.name)
    color = try c.field(.color)
    containsNull = try c.containsNull()
  }
}

func calendarChanges(_ input: CalendarInput, creating: Bool) throws -> CalendarChanges {
  guard creating || input.accountId.isAbsent else {
    throw ServerError.invalidArgument("Unknown input field")
  }
  if !creating && input.containsNull {
    throw ServerError.invalidArgument("calendar patch values must not be null")
  }
  var result = CalendarChanges()
  result.name = input.name.value
  if let color = input.color.value {
    guard color.range(of: #"^#[0-9A-Fa-f]{6}([Ff]{2})?\z"#, options: .regularExpression) != nil
    else {
      throw ServerError.invalidArgument(
        "calendar colors must be opaque: use #RRGGBB or #RRGGBBFF")
    }
    let rgba = UInt32(color.dropFirst() + (color.count == 7 ? "FF" : ""), radix: 16)!
    result.color = (0..<4).map { Double(rgba >> (24 - 8 * $0) & 0xFF) / 255 }
  }
  guard creating || result.name != nil || result.color != nil else {
    throw ServerError.invalidArgument("calendar patch must contain at least one change")
  }
  return result
}
