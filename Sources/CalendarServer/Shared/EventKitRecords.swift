import CoreGraphics
import EventKit
import Foundation

// Convert framework objects on the main actor. Only Sendable value records leave it.
extension EKCalendar {
  // The server's rule for updating or deleting a calendar, also reported to clients.
  var allowsCalendarModifications: Bool {
    !isImmutable && allowsContentModifications && !isSubscribed
  }
}
extension CalendarType {
  init(_ type: EKCalendarType) {
    switch type {
    case .local: self = .local
    case .calDAV: self = .calDAV
    case .exchange: self = .exchange
    case .subscription: self = .subscription
    case .birthday: self = .birthday
    @unknown default: self = .unknown
    }
  }
}
extension CalendarRecord {
  init(_ calendar: EKCalendar) throws {
    // EventKit leaves source nil on a calendar whose account is gone; the IUO would trap.
    guard let source = calendar.source else {
      throw ServerError.internalError("Calendar \(calendar.calendarIdentifier) has no account")
    }
    let color = calendar.cgColor?.converted(
      to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
    let hex = color?.components.flatMap { values -> String? in
      guard values.count == 4 else { return nil }
      return "#"
        + values.map {
          String(format: "%02X", Int((min(1, max(0, $0)) * 255).rounded()))
        }.joined()
    }
    let mask = calendar.supportedEventAvailabilities
    let supported: [(EKCalendarEventAvailabilityMask, EventAvailability)] = [
      (.busy, .busy), (.free, .free), (.tentative, .tentative), (.unavailable, .unavailable),
    ]
    self.init(
      id: calendar.calendarIdentifier, name: calendar.title, color: hex,
      source: SourceRecord(
        id: source.sourceIdentifier, title: source.title, type: source.sourceType.rawValue),
      type: CalendarType(calendar.type),
      allowsContentModifications: calendar.allowsContentModifications,
      allowsCalendarModifications: calendar.allowsCalendarModifications,
      subscribed: calendar.isSubscribed, immutable: calendar.isImmutable,
      supportedAvailabilities: supported.filter { mask.contains($0.0) }.map(\.1))
  }
}
extension ParticipantRecord {
  init(_ participant: EKParticipant) {
    // The header declares url nonnull, but a provider can leave it unset; KVC reads it
    // without trapping.
    let url = participant.value(forKey: "URL") as? URL
    let email =
      url?.scheme?.lowercased() == "mailto"
      ? URLComponents(url: url!, resolvingAgainstBaseURL: false)?.path : nil
    let status: ParticipantStatus
    switch participant.participantStatus {
    case .unknown: status = .unknown
    case .pending: status = .pending
    case .accepted: status = .accepted
    case .declined: status = .declined
    case .tentative: status = .tentative
    case .delegated: status = .delegated
    case .completed: status = .completed
    case .inProcess: status = .inProcess
    @unknown default: status = .unknown
    }
    let role: ParticipantRole
    switch participant.participantRole {
    case .unknown: role = .unknown
    case .required: role = .required
    case .optional: role = .optional
    case .chair: role = .chair
    case .nonParticipant: role = .nonParticipant
    @unknown default: role = .unknown
    }
    let type: ParticipantType
    switch participant.participantType {
    case .unknown: type = .unknown
    case .person: type = .person
    case .room: type = .room
    case .resource: type = .resource
    case .group: type = .group
    @unknown default: type = .unknown
    }
    self.init(
      name: participant.name, url: url?.absoluteString, email: email, status: status, role: role,
      type: type, currentUser: participant.isCurrentUser)
  }
}
extension EventRecord {
  init(_ event: EKEvent) throws {
    // These are implicitly unwrapped in EventKit; an unsaved or orphaned event leaves them nil.
    guard let identifier = event.eventIdentifier, !identifier.isEmpty,
      let calendarID = event.calendar?.calendarIdentifier, !calendarID.isEmpty,
      let start = event.startDate, let end = event.endDate
    else { throw ServerError.internalError("Invalid EventKit event identifiers or dates") }
    let availability: EventAvailability
    switch event.availability {
    case .notSupported: availability = .notSupported
    case .busy: availability = .busy
    case .free: availability = .free
    case .tentative: availability = .tentative
    case .unavailable: availability = .unavailable
    @unknown default: availability = .notSupported
    }
    let status: EventStatus
    switch event.status {
    case .none: status = .none
    case .confirmed: status = .confirmed
    case .tentative: status = .tentative
    case .canceled: status = .canceled
    @unknown default: status = .none
    }
    let member = event.isSeriesMember
    let series = seriesIdentifier(identifier)
    self.init(
      id: member
        ? "\(series)/\(occurrenceKey(start: start, allDay: event.isAllDay))" : identifier,
      seriesId: member ? series : nil, eventIdentifier: identifier,
      externalId: event.calendarItemExternalIdentifier, calendarId: calendarID,
      title: event.title, notes: event.notes, location: event.location,
      url: event.url?.absoluteString,
      structuredLocation: event.structuredLocation.map {
        StructuredLocation(
          title: $0.title, latitude: $0.geoLocation?.coordinate.latitude,
          longitude: $0.geoLocation?.coordinate.longitude, radius: $0.radius)
      }, start: start, end: end, allDay: event.isAllDay,
      // All-day events are floating: EventKit reports them in the host zone.
      timeZone: event.isAllDay ? nil : event.timeZone?.identifier,
      occurrenceDate: member ? event.occurrenceDate : nil, detached: event.isDetached,
      recurring: event.hasRecurrenceRules, availability: availability, status: status,
      organizer: event.organizer.map(ParticipantRecord.init),
      attendees: (event.attendees ?? []).map(ParticipantRecord.init),
      birthdayContactIdentifier: event.birthdayContactIdentifier,
      creationDate: event.creationDate, modificationDate: event.lastModifiedDate,
      alarms: (event.alarms ?? []).map(AlarmRecord.init),
      recurrenceRules: (event.recurrenceRules ?? []).map(RecurrenceRecord.init))
  }
}
extension AlarmRecord {
  init(_ alarm: EKAlarm) {
    let action: String
    switch alarm.type {
    case .display: action = "display"
    case .audio: action = "audio"
    case .email: action = "email"
    case .procedure: action = "procedure"
    @unknown default: action = "unknown"
    }
    let proximity: AlarmProximity
    switch alarm.proximity {
    case .none: proximity = .none
    case .enter: proximity = .enter
    case .leave: proximity = .leave
    @unknown default: proximity = .unknown
    }
    self.init(
      action: action, soundName: alarm.soundName, emailAddress: alarm.emailAddress,
      absoluteDate: alarm.absoluteDate.map(timestamp), relativeOffset: alarm.relativeOffset,
      proximity: proximity,
      structuredLocation: alarm.structuredLocation.map {
        StructuredLocation(
          title: $0.title, latitude: $0.geoLocation?.coordinate.latitude,
          longitude: $0.geoLocation?.coordinate.longitude, radius: $0.radius)
      })
  }
}
extension RecurrenceRecord {
  init(_ rule: EKRecurrenceRule) {
    let frequency: RecurrenceFrequency
    switch rule.frequency {
    case .daily: frequency = .daily
    case .weekly: frequency = .weekly
    case .monthly: frequency = .monthly
    case .yearly: frequency = .yearly
    @unknown default: frequency = .unknown
    }
    func integers(_ values: [NSNumber]?) -> [Int] { (values ?? []).map(\.intValue) }
    self.init(
      frequency: frequency, calendarIdentifier: rule.calendarIdentifier,
      interval: rule.interval, firstDayOfTheWeek: rule.firstDayOfTheWeek,
      daysOfTheWeek: (rule.daysOfTheWeek ?? []).map {
        RecurrenceDay(dayOfTheWeek: $0.dayOfTheWeek.rawValue, weekNumber: $0.weekNumber)
      }, daysOfTheMonth: integers(rule.daysOfTheMonth), daysOfTheYear: integers(rule.daysOfTheYear),
      weeksOfTheYear: integers(rule.weeksOfTheYear),
      monthsOfTheYear: integers(rule.monthsOfTheYear),
      setPositions: integers(rule.setPositions),
      end: rule.recurrenceEnd.map {
        RecurrenceEnd(endDate: $0.endDate.map(timestamp), occurrenceCount: $0.occurrenceCount)
      })
  }
}
