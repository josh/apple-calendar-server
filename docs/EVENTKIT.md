# EventKit

Use [EKEventStore](https://developer.apple.com/documentation/eventkit/ekeventstore)
for all calendar data. The server uses public EventKit only: no Apple events, private
properties, or database reads. [What EventKit cannot do](#not-available) lists the gaps.

Provider observations below are from iCloud on macOS 27.2 with disposable events;
other providers can differ.

## Ownership and access

Native calls run on the main actor in the server process. Each read or write uses a
fresh store, kept alive until conversion to value records to preserve calendar and
account references. Only value records leave the actor. A write validates and applies
its changes to its own store, so a rejected change is discarded with the store rather
than left pending. Requests can interleave between calls; writes are not globally serialized.

Require full access before operations. Denied access fails rather than returning
empty data. See [startup authorization](SERVER.md#setup).

A calendar is an [EKCalendar](https://developer.apple.com/documentation/eventkit/ekcalendar),
owned by an [EKSource](https://developer.apple.com/documentation/eventkit/eksource).
Use `calendars(for: .event)`; `sources` includes accounts without event calendars.
ID lookups must check event support; the default counts only if accessible. Check
calendar editability before writing, while allowing for native save failures.

## Reads

`predicateForEvents(withStart:end:calendars:)` returns events overlapping a range and
expands repeating events into occurrences. It silently shortens a range longer than
four years, so [windows](GRAPHQL.md#event-windows) are capped at 1096 days and a longer
one is refused. Fetch one second wider than the window on each side, then apply exact
inclusive-lower/exclusive-upper overlap bounds, so native endpoint handling cannot
lose a match. A zero-length event belongs to the window its start falls in.

Nil calendars means all calendars; an empty selection skips the fetch, because an
empty array can also mean all. The fetch is synchronous and holds the main actor.
`enumerateEvents(matching:using:)` stops between events once the request is cancelled
or after 20,000 candidates (`RESULT_TOO_LARGE`). A 1096-day window over ten calendars
holding 2,300 events took under two seconds.

[EKEvent](https://developer.apple.com/documentation/eventkit/ekevent) and
[EKCalendarItem](https://developer.apple.com/documentation/eventkit/ekcalendaritem)
define stored fields. Fail a read on an event with no identifier, calendar, or dates;
never drop bad records silently. Retain all alarms and all recurrence rules.
[EKParticipant](https://developer.apple.com/documentation/eventkit/ekparticipant)
is read-only. Its URL is read through key-value coding, so an unset one cannot trap.

## Identity

Every occurrence of a repeating event shares one `eventIdentifier`, and
`event(withIdentifier:)` returns the first occurrence. An occurrence edited apart from
its series has the identifier `<series>/RID=<n>`, which `event(withIdentifier:)`
does not resolve.

So an event's API id is its `eventIdentifier`, and an occurrence's is its series
identifier, a slash, and its current start: `…/2027-11-15T18:00:00Z`, or
`…/2027-11-15` when all-day. Resolve an occurrence by fetching the second (or day) at
that start and matching identifiers equal to the series or prefixed by it and a slash.
Several matches make the id ambiguous and fail. Never substitute a same-title event.

An id is a locator, not a permanent key:

- Moving an occurrence changes its id; the old id then resolves to nothing.
- `FUTURE_EVENTS` on a later occurrence splits the series. The later part gets a new
  series identifier; the earlier part keeps its own.
- Detaching one occurrence leaves its id unchanged while it keeps its start.
- A detached occurrence that moved was found again by its new start. Its
  `occurrenceDate` followed it to the new start, contrary to the header's description,
  so `occurrenceDate` does not key occurrences.
- Deleting a series by its series id also removed its detached occurrence.
- Moving an event to another calendar in the same account kept its identifier.
  Apple warns that it can change, and that identifiers can change after a full sync.

`calendarItemExternalIdentifier` is server-provided and shared by occurrences and
copies; it is exposed for reference and never accepted as input.

[EKEventStoreChanged](https://developer.apple.com/documentation/eventkit/updating-with-notifications)
signals invalidation, not item deltas; the server reads fresh data per request and
does not observe it. `refreshSourcesIfNecessary()` does not prove cloud sync has finished.

## Dates

Events store instants. A timed event has an optional time zone it is anchored to; nil
means floating. Setting the zone does not move the instants. A weekly series created
before a clock change kept its wall-clock time after it.

All-day events are floating, and EventKit reports them in the host zone, so their days
are read and written there. Write an all-day event from midnight of its first day
through the last second of its last day. Read its last day as the day containing the
end, or the day before when the end is exactly midnight after the start. The API's
`allDayEndDate` is inclusive, so a one-day event has equal start and end days.

## Writes

Assign new events a calendar and new calendars a source. Validate resulting state
before `save(_:span:commit:)`. Skip the save when `hasChanges` is false: EventKit's header says saving
an unchanged event can report failure without an error. A patch that sets a field to
its current value succeeds.

`EKSpan` decides how far a change to an occurrence reaches; the
[span rules](GRAPHQL.md#events-and-occurrences) make the caller choose. A series id
saves from the first occurrence with `.futureEvents`. Recurrence changes always save
with `.futureEvents`. Build the response from the saved object.

Changing or deleting an event with attendees can make its provider send updates or
cancellations to other people. Require `allowAttendeeNotifications` for any such
write. This guard has not been exercised live, because EventKit cannot create an
event with attendees.

Use [EKRecurrenceRule](https://developer.apple.com/documentation/eventkit/ekrecurrencerule)
for repetition. The simplified API supports one rule. Selector arrays must be nonempty
and unique; monthly weekday ordinals are limited to ±5, yearly to ±53, and ordinal
weekdays cannot combine with `weeksOfYear`. Interval/count must fit positive Int32.
An explicit end must choose exactly one of count or until.

Check `supportedEventAvailabilities` before setting availability; iCloud calendars
store only busy and free.

Calendar deletion checks emptiness unless `allowNonEmpty`. Events cannot be
enumerated for all time, so the check probes from 1970 through ten years ahead in
three-year slices, nearest first, stopping at the first event. An event outside that
range is not detected. External edits remain unlocked.

### Alarms

[EKAlarm](https://developer.apple.com/documentation/eventkit/ekalarm) supports absolute
and relative triggers; relative offsets count from the event's start. Location
triggers are not accepted on events and fail the simplified projection when stored;
the raw alarm still shows them. Validate sound names against available system sounds.

For sound/email writes, reset/refetch and match every requested trigger/delivery
once. Missing/changed settings return `WRITE_APPLIED` with the ID. Stored settings
do not prove delivery. iCloud dropped a sound from a relative alarm and kept the
display trigger; the write returned `WRITE_APPLIED`.

## Not available

Calendar.app stores more than public EventKit exposes. None of it is read or written here.

| Data                                                          | Where it is reachable           |
| ------------------------------------------------------------- | ------------------------------- |
| Travel time and its starting location                         | Private `EKEvent` properties    |
| Video call link, when not also in the URL, notes, or location | Private `EKEvent` properties    |
| Attachments; the private-event flag                           | Private `EKEvent` properties    |
| Answering invitations; adding or removing attendees           | Private setters                 |
| Setting event status; calendar descriptions; excluded dates   | Calendar's scripting dictionary |
| Sidebar visibility, calendar order, and calendar groups       | Neither                         |

EventKit also cannot create subscribed calendars, share or publish a calendar, or
edit events in the Birthdays calendar.
