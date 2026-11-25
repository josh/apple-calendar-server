import Foundation

enum EventClearValue: String, Sendable, CaseIterable {
  case notes = "NOTES"
  case location = "LOCATION"
  case url = "URL"
  case recurrence = "RECURRENCE"
  case timeZone = "TIME_ZONE"

  var description: String {
    switch self {
    case .notes: "Remove the notes."
    case .location: "Remove the location, including its coordinates."
    case .url: "Remove the associated URL."
    case .recurrence: "Stop repetition."
    case .timeZone: "Make a timed event floating, so it keeps its wall-clock time in any zone."
    }
  }
}
// How far a change to one occurrence of a repeating event reaches.
enum EventSpan: String, CaseIterable, Codable, Sendable {
  case thisEvent = "THIS_EVENT"
  case futureEvents = "FUTURE_EVENTS"
}

struct StructuredLocationInput: Decodable, Sendable {
  let title: String
  let latitude, longitude: Double
  let radiusMeters: Double?

  enum CodingKeys: String, CodingKey, CaseIterable { case title, latitude, longitude, radiusMeters }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    title = try c.decode(String.self, forKey: .title)
    latitude = try c.decode(Double.self, forKey: .latitude)
    longitude = try c.decode(Double.self, forKey: .longitude)
    radiusMeters = try c.decodeIfPresent(Double.self, forKey: .radiusMeters)
  }
}

struct AlarmInput: Decodable, Sendable {
  let absoluteDate: String?
  let relativeOffsetSeconds: Double?
  let soundName, emailAddress: String?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case absoluteDate, relativeOffsetSeconds, soundName, emailAddress
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    absoluteDate = try c.decodeIfPresent(String.self, forKey: .absoluteDate)
    relativeOffsetSeconds = try c.decodeIfPresent(Double.self, forKey: .relativeOffsetSeconds)
    soundName = try c.decodeIfPresent(String.self, forKey: .soundName)
    emailAddress = try c.decodeIfPresent(String.self, forKey: .emailAddress)
  }
}

// Event create and patch input. Only patches accept clearFields.
struct EventInput: Decodable, Sendable {
  let calendarId, calendarName, title, notes, location, url, timeZone: InputField<String>
  let startDate, endDate, allDayStartDate, allDayEndDate: InputField<String>
  let structuredLocation: InputField<StructuredLocationInput>
  let availability: InputField<EventAvailability>
  let alarms: InputField<[AlarmInput]>
  let recurrence: InputField<RecurrenceInput>
  let clearFields: InputField<[String]>
  let containsNull: Bool

  enum CodingKeys: String, CodingKey, CaseIterable {
    case calendarId, calendarName, title, notes, location, structuredLocation, url, startDate
    case endDate, allDayStartDate, allDayEndDate, timeZone, availability, alarms, recurrence
    case clearFields
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    calendarId = try c.field(.calendarId)
    calendarName = try c.field(.calendarName)
    title = try c.field(.title)
    notes = try c.field(.notes)
    location = try c.field(.location)
    structuredLocation = try c.field(.structuredLocation)
    url = try c.field(.url)
    startDate = try c.field(.startDate)
    endDate = try c.field(.endDate)
    allDayStartDate = try c.field(.allDayStartDate)
    allDayEndDate = try c.field(.allDayEndDate)
    timeZone = try c.field(.timeZone)
    availability = try c.field(.availability)
    alarms = try c.field(.alarms)
    recurrence = try c.field(.recurrence)
    clearFields = try c.field(.clearFields)
    containsNull = try c.containsNull()
  }
}

func eventChanges(_ input: EventInput, creating: Bool) throws -> EventChanges {
  guard !creating || input.clearFields.isAbsent else {
    throw ServerError.invalidArgument("Unknown input field")
  }
  if !creating, input.containsNull {
    throw ServerError.invalidArgument("patch values cannot be null; use clearFields")
  }
  guard input.calendarId.isAbsent || input.calendarName.isAbsent else {
    throw ServerError.invalidArgument("calendarId and calendarName are mutually exclusive")
  }
  func nonblank(_ field: InputField<String>, _ name: String) throws -> String? {
    guard !field.isAbsent else { return nil }
    let value = try field.required(name)
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ServerError.invalidArgument("\(name) must not be blank")
    }
    return value
  }
  var result = EventChanges()
  result.calendarId = try nonblank(input.calendarId, "calendarId")
  result.calendarName = try nonblank(input.calendarName, "calendarName")
  result.title = try nonblank(input.title, "title")
  if creating && result.title == nil { throw ServerError.invalidArgument("title is required") }
  result.notes = input.notes.value
  result.location = try nonblank(input.location, "location")
  if let value = input.url.value {
    guard let url = URL(string: value), let scheme = url.scheme, !scheme.isEmpty,
      value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    else {
      throw ServerError.invalidArgument("url must be an absolute URL without whitespace")
    }
    result.url = url
  }
  if let names = input.clearFields.value {
    guard Set(names).count == names.count else {
      throw ServerError.invalidArgument("duplicate clearFields")
    }
    result.clear = try Set(
      names.map {
        guard let value = EventClearValue(rawValue: $0) else {
          throw ServerError.invalidArgument("unsupported clear field")
        }
        return value
      })
  }
  let timed = input.startDate.value != nil || input.endDate.value != nil
  let wholeDay = input.allDayStartDate.value != nil || input.allDayEndDate.value != nil
  guard !(timed && wholeDay) else {
    throw ServerError.invalidArgument(
      "use startDate/endDate for a timed event or allDayStartDate/allDayEndDate for an all-day event, not both"
    )
  }
  if timed {
    let start = try input.startDate.value.map(parseTimestamp)
    let end = try input.endDate.value.map(parseTimestamp)
    if creating && (start == nil || end == nil) {
      throw ServerError.invalidArgument("a timed event requires startDate and endDate")
    }
    if let start, let end, start > end {
      throw ServerError.invalidArgument("startDate must not be later than endDate")
    }
    result.dates = .timed(start: start, end: end)
  } else if wholeDay {
    let start = input.allDayStartDate.value
    let end = input.allDayEndDate.value
    try [start, end].compactMap { $0 }.forEach(validateDay)
    if creating && start == nil {
      throw ServerError.invalidArgument("an all-day event requires allDayStartDate")
    }
    if let start, let end, start > end {
      throw ServerError.invalidArgument("allDayStartDate must not be later than allDayEndDate")
    }
    result.dates = .allDay(start: start, end: end)
  } else if creating {
    throw ServerError.invalidArgument(
      "supply startDate and endDate, or allDayStartDate for an all-day event")
  }
  if let zone = input.timeZone.value {
    guard TimeZone.knownTimeZoneIdentifiers.contains(zone) || zone == "UTC",
      let parsed = TimeZone(identifier: zone)
    else {
      throw ServerError.invalidArgument("timeZone must be an IANA time-zone identifier")
    }
    guard !wholeDay else {
      throw ServerError.invalidArgument("all-day events are floating; do not supply timeZone")
    }
    result.timeZone = parsed
  }
  if let place = input.structuredLocation.value {
    let radius = place.radiusMeters ?? 0
    guard !place.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      place.latitude.isFinite, place.longitude.isFinite, radius.isFinite,
      (-90...90).contains(place.latitude), (-180...180).contains(place.longitude), radius >= 0
    else { throw ServerError.invalidArgument("invalid structuredLocation") }
    result.structuredLocation = StructuredLocationChange(
      title: place.title, latitude: place.latitude, longitude: place.longitude, radius: radius)
  }
  if let availability = input.availability.value {
    guard availability != .notSupported else {
      throw ServerError.invalidArgument(
        "availability must be BUSY, FREE, TENTATIVE, or UNAVAILABLE")
    }
    result.availability = availability
  }
  result.alarms = try input.alarms.value?.map(alarmChange)
  result.recurrence = try input.recurrence.value.map(recurrenceChange)
  guard !(result.location != nil && result.structuredLocation != nil) else {
    throw ServerError.invalidArgument("location and structuredLocation are mutually exclusive")
  }
  guard !(result.notes != nil && result.clear.contains(.notes)),
    !(result.url != nil && result.clear.contains(.url)),
    !(result.timeZone != nil && result.clear.contains(.timeZone)),
    !(result.recurrence != nil && result.clear.contains(.recurrence)),
    !((result.location != nil || result.structuredLocation != nil)
      && result.clear.contains(.location))
  else { throw ServerError.invalidArgument("cannot set and clear the same field") }
  guard creating || result != EventChanges() else {
    throw ServerError.invalidArgument("patch must contain at least one change")
  }
  return result
}

func alarmChange(_ input: AlarmInput) throws -> AlarmChange {
  guard input.soundName == nil || input.emailAddress == nil else {
    throw ServerError.invalidArgument("an alarm cannot combine soundName and emailAddress")
  }
  if let sound = input.soundName, sound.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    throw ServerError.invalidArgument("soundName must not be blank")
  }
  if let email = input.emailAddress {
    let parts = email.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
      email.rangeOfCharacter(
        from: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>,;"))) == nil
    else {
      throw ServerError.invalidArgument("emailAddress must be a single address without whitespace")
    }
  }
  let trigger: AlarmTrigger
  switch (input.absoluteDate, input.relativeOffsetSeconds) {
  case (let date?, nil):
    trigger = .absolute(try parseTimestamp(date))
  case (nil, let offset?):
    guard offset.isFinite else {
      throw ServerError.invalidArgument("alarm offset must be finite")
    }
    trigger = .relative(offset)
  default:
    throw ServerError.invalidArgument(
      "each alarm requires exactly one of absoluteDate or relativeOffsetSeconds")
  }
  return AlarmChange(
    trigger: trigger, soundName: input.soundName, emailAddress: input.emailAddress)
}
