# GraphQL

`POST /graphql`. The [schema](calendar.graphql) documents types, fields, inputs,
and validation. No subscriptions.

```sh
curl --unix-socket /path/to/server.sock http://localhost/graphql \
  -H 'Content-Type: application/json' \
  --data '{"query":"{ events(limit: 10) { from before totalCount items { id title startDate allDayStartDate } } }"}'
```

The endpoint follows [GraphQL over HTTP](https://http-spec.graphql.org/September2026/).
Responses use `application/graphql-response+json` when Accept allows it or is absent,
else `application/json` on 2xx; Accept without either returns 406.

Null `variables`/`operationName` mean absent. Request errors carry no `data`: a body
that is not JSON or a document that does not parse returns 400; a malformed envelope,
failed validation, an ambiguous operation, or variables that do not coerce return 422.
Other methods return 405 with `Allow: POST`. A read-only grant permits only the
selected query operation; mutations require write access (403). Execution errors use
HTTP 200 with `data` and `errors`; clients must inspect the body.

## Reads and mutations

Repeated reads share results/failures within a request: calendars are read once, and
each distinct event window once. Mutations refresh reads after attempted writes,
including failures, so later fields see earlier writes; separate requests can interleave.
See [access and sync limits](SERVER.md#limits).

Collections filter and sort before pagination. `limit` is 1–100 (default 50),
`offset` is nonnegative, and an offset beyond the end returns an empty page with
the full matching count. Pages across requests have no shared snapshot.

Nullable create/filter inputs generally treat null as absent. Top-level patch
values reject null; remove values with `clearFields`. Reject invalid changes before
saving. Later mutation failures do not undo earlier successful mutations.

## Event windows

Events are read through a window, because a repeating event has no last occurrence.
`events`, `Account.events`, `Calendar.events`, and `Calendar.summary` take `from`
(inclusive) and `before` (exclusive), each an RFC 3339 timestamp or a `YYYY-MM-DD`
day meaning its midnight in the host zone. An event matches when it overlaps the
window; repeating events appear once per occurrence.

`from` defaults to the request's instant and `before` to 30 days after `from`. A
window may span at most 1096 days; a longer one is `INVALID_ARGUMENT`, never
shortened. Every page echoes the resolved `from` and `before`. Send them back
unchanged with later pages, because the defaults move with the clock. A window
that more than 20,000 events overlap returns `RESULT_TOO_LARGE`.

Events sort by start, then end, then identifier unless `orderBy` says otherwise.

## Events and occurrences

`Event.id` names one event or one occurrence; `seriesId` is non-null for every
occurrence of a repeating event and names the whole series. `event(id:)` given a
series id returns its first occurrence. See [identity](EVENTKIT.md#identity) for the
id format and when it changes.

A timed event has `startDate`/`endDate`; an all-day event has `allDayStartDate` and an
inclusive `allDayEndDate` instead, and no `timeZone`. `alarms` and `recurrence` are
simplified projections that fail individually when a stored value does not fit;
`rawAlarms` and `recurrenceRules` always hold the stored values.

`updateEvent` and `deleteEvent` take `span` beside `id`:

| `id`                          | `span`          | Effect                                     |
| ----------------------------- | --------------- | ------------------------------------------ |
| An event that does not repeat | Ignored         | That event.                                |
| An occurrence of a series     | `THIS_EVENT`    | Only that occurrence.                      |
| An occurrence of a series     | `FUTURE_EVENTS` | It and later occurrences; splits a series. |
| An occurrence of a series     | Omitted         | `SPAN_REQUIRED`.                           |
| A series id                   | Omitted         | The whole series.                          |

Changing `recurrence` or moving calendars applies to a series, so on an occurrence
it needs `FUTURE_EVENTS`. An event with attendees also needs
`allowAttendeeNotifications: true`, or the write returns `HAS_ATTENDEES`.

## Input aliases

Both APIs accept `calendarName` in place of `calendarId` and `daysOfWeekNames` in
place of `daysOfWeek`, and return canonical IDs and structured weekdays. Alias values
reject null, even on creation; supplying both forms fails even when one is null.

`calendarName` searches all accessible calendars, including other accounts and
read-only calendars, before checking editability. No match returns `NOT_FOUND`;
multiple matches return `INVALID_ARGUMENT`. A supplied name never falls back to the
default calendar.

Weekday phrases use full English names and ignore surrounding/repeated whitespace.
Duplicates are checked after normalization; structured recurrence constraints still apply.

## Errors

[Error codes](SERVER.md#errors) appear in `extensions.code`. Select `id` in
mutation responses and retain it even when other fields return errors.
A failed response field can be null after a successful save; `WRITE_APPLIED`
can instead return a null mutation result with the saved ID only in the error
message. Follow the [partial-save recovery guidance](SERVER.md#errors).
