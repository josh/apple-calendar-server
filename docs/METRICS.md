# Metrics

`GET /metrics` serves health and cached event counts in Prometheus text format
0.0.4. [metrics.prom](metrics.prom) is a synthetic example of every metric, type,
label, and help text; see the [format specification](https://prometheus.io/docs/instrumenting/exposition_formats/).

## Counts

A repeating event has no last occurrence, so events are counted in fixed windows
around one observation instant, `calendar_observation_timestamp_seconds`. Each
collection reads every accessible calendar from 30 days before today through 30
days after it and counts each event, or each occurrence of a repeating event, once.

`calendar_events` places an event by the host-zone day it starts on:

| `window`     | Start day, relative to today |
| ------------ | ---------------------------- |
| `past_month` | 30 to 8 days before          |
| `past_week`  | 7 days to 1 day before       |
| `today`      | Today                        |
| `next_week`  | 1 to 7 days after            |
| `next_month` | 8 to 30 days after           |

The windows do not overlap, so they can be summed. `kind` is `timed` or `all_day`.
Every calendar emits all ten combinations, including zeros. An event that started
before the earliest window is not counted, even if it is still running.
`calendar_recurring_events`, `calendar_events_with_attendees`, and
`calendar_events_with_alarms` count the same events by window; they overlap each
other. `calendar_events_in_progress` counts timed events that had started and not
ended at the observation instant.

Only `calendar_calendar_info` includes names; renames preserve count-series identity.
Calendar names cannot be suppressed. Labels exclude event IDs, titles, notes,
locations, and attendees. IDs are opaque and may change after account resets or full sync.

## Refresh

Collect at startup, then wait `CALENDAR_METRICS_INTERVAL_SECONDS` (default 3600)
after each collection. Scrapes and API requests do not trigger collection.
Counts remain available during refresh and may lag by the interval plus collection
time, so an event can sit in yesterday's window until the next collection after
midnight. Changes and removed calendars appear on success. Counts do not prove cloud sync.

Before the first success or after failure, omit event gauges and report
`calendar_eventkit_up 0`; health metrics remain. Failures clear previous counts
and retry after min(60 seconds, interval), doubling up to the interval. A server
that starts while Calendar access is still pending therefore reports its first
counts about a minute after access is granted.
Each collection is independent of API request snapshots. The health series cover
the current process; restarts reset counters, and this collector keeps no disk cache.
