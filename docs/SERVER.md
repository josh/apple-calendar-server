# Server

Requires macOS 14+. Serves `POST /graphql`, `POST /mcp`, and `GET /metrics`.
`swift build -c release` produces `.build/release/apple-calendar-server`.

## Setup

launchd owns the sockets and starts the server on connection, including after
exit. Direct launch is refused. Use absolute executable/socket paths (`~` is not
expanded); Unix socket paths have a 104-byte limit. Adjust this LaunchAgent to
the installed binary and user, and create its socket directory:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.github.josh.apple-calendar-server</string>
  <key>ProgramArguments</key>
  <array><string>/usr/local/bin/apple-calendar-server</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>CALENDAR_REQUEST_ACCESS</key><string>1</string>
  </dict>
  <key>Sockets</key><dict>
    <key>Listeners</key><dict>
      <key>SockPathName</key><string>/Users/you/Library/Application Support/apple-calendar-server/server.sock</string>
      <key>SockPathMode</key><integer>384</integer>
    </dict>
  </dict>
</dict></plist>
```

Save as `~/Library/LaunchAgents/com.github.josh.apple-calendar-server.plist`, then load:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.github.josh.apple-calendar-server.plist
```

The executable embeds `NSCalendarsFullAccessUsageDescription` in its
`__TEXT,__info_plist` section. EventKit stays in this process so authorization
belongs to the executable launchd runs. A rebuilt ad-hoc signed binary is a new
executable to macOS and may be asked for access again; sign with a stable identity
to keep the grant.

`CALENDAR_REQUEST_ACCESS=1` requests missing full Calendar access at startup;
reads never request it. While the request is pending, `/graphql` and `/mcp` return
503; metrics remain available.

Every read and write needs Full Access. There is no native read-only grant, and
"Add Only" access cannot read calendars or existing events, so the server treats it
like no access. Without Full Access the server keeps running: GraphQL fields and MCP
tools answer `NOT_AUTHORIZED` with a message naming the state and how to change it,
`calendar_full_access` reports 0, and location search and schema discovery still
work. A refusal does not exit the process, because launchd would only start it
again into the same refusal. Writes honor native editability.

Reducing the grant in System Settings does not stop a running server, and macOS
keeps telling that process it has Full Access. The server notices from what EventKit
then shows it (see [EventKit](EVENTKIT.md#ownership-and-access)) and answers
`NOT_AUTHORIZED` from the next request on; granting Full Access again needs no restart.
The server sends no Apple events and needs no Automation permission.

## Sockets

At least one `Sockets` label is required; each may hold multiple sockets. Use
`SockPathName`/`SockPathMode` for Unix or `SockNodeName`/`SockServiceName` for TCP.
Only `TailscaleServe` checks grants; other labels grant fixed access. Excluded
endpoints or missing grants return 403.

| Label            | Access                                                             |
| ---------------- | ------------------------------------------------------------------ |
| `Listeners`      | All endpoints, including writes. Restrict who can connect.         |
| `Metrics`        | `/metrics` only.                                                   |
| `GraphQL`        | `/graphql`, including writes.                                      |
| `MCP`            | `/mcp`, including writes.                                          |
| `TailscaleServe` | Checks `Tailscale-App-Capabilities` for the configured capability. |

For `TailscaleServe`, a Unix socket with `SockPathName` and `SockPathMode` 384 is
recommended:

```sh
tailscale serve --bg --https=443 --accept-app-caps=example.com/cap/calendar unix:/path/to/tailscale-serve.sock
```

`tailscaled` must run as root or as the socket's owner to open it. The sandboxed
Mac App Store build cannot use Unix sockets; use `SockNodeName=127.0.0.1`,
`SockServiceName=8173`, and an `http://127.0.0.1:8173` target instead. Any local
process can reach a loopback port and forge the capability header.

Capability grants are a list of objects mapping `graphql`/`mcp` to `r` or `rw`,
and `metrics` to `r`, under the configured capability key:

```json
{
  "example.com/cap/calendar": [{ "graphql": "r", "mcp": "rw", "metrics": "r" }]
}
```

Combine grants using the greatest access per endpoint; omitted endpoints get none.
Unknown API names/levels, `metrics: "rw"`, malformed headers, or headers over
16 KiB deny access. Accept plain JSON or RFC 2047 UTF-8 Q-encoded header values.
Only a trusted Tailscale Serve proxy may reach this socket: the header is its
assertion of identity and access, not a credential the server verifies independently.

No built-in authentication or TLS beyond socket access: keep direct sockets private
and use Tailscale Serve remotely.

## Configuration

Configuration comes only from the plist's `EnvironmentVariables`. Invalid values
prevent startup; other environment variables are ignored.

| Variable                            | Default      | Value                                                                        |
| ----------------------------------- | ------------ | ---------------------------------------------------------------------------- |
| `CALENDAR_REQUEST_ACCESS`           | Off          | `1` to request Calendar access.                                              |
| `CALENDAR_TAILSCALE_APP_CAPABILITY` | None         | `domain/path`; required for `TailscaleServe`.                                |
| `CALENDAR_ALLOWED_ORIGINS`          | None         | Space-separated `http(s)://host[:port]` origins.                             |
| `CALENDAR_EXIT_WHEN_IDLE_SECONDS`   | Stay running | 1–86400 seconds without open connections.                                    |
| `CALENDAR_LOG_LEVEL`                | `info`       | Minimum: `trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical`. |
| `CALENDAR_METRICS_INTERVAL_SECONDS` | `3600`       | Delay after collection, 1–604800 seconds.                                    |

## HTTP

HTTP/1.1 supports concurrent requests, keep-alive, and chunked bodies. JSON POSTs
require `Content-Type: application/json` (415 otherwise). Bodies over 1 MiB,
including chunked uploads, receive 413.

Host is not validated. An unlisted `Origin` receives 403; allowed origins receive
CORS headers and OPTIONS preflight support. Configured origins cannot contain
paths, queries, fragments, or credentials; default ports are removed.
Repeated `Origin`, `Content-Type`, or `Tailscale-App-Capabilities` headers return
400 rather than choosing a value.

## Deadlines and recovery

GraphQL/MCP handlers have a 60-second deadline after the body is collected.
Expiry cancels their task and returns 504 without waiting for it to finish.
Cancellation cannot interrupt a synchronous native call or undo a save, so work
may finish after the timeout. Refetch before retrying writes.

An independent watchdog checks the main actor every 10 seconds and exits with
status 1 after more than 120 seconds without a heartbeat. This lets launchd recover
from native calls that block the actor; an HTTP deadline alone cannot free it.
Idle exit counts open connections, including keep-alive connections, rather than
time since the last request. Event fetches are synchronous and hold the actor;
their limits are described in [EventKit](EVENTKIT.md#reads).

## Errors

| Code                    | Meaning                                                                       |
| ----------------------- | ----------------------------------------------------------------------------- |
| `INVALID_ARGUMENT`      | Invalid input; nothing saved.                                                 |
| `NOT_AUTHORIZED`        | The process lacks full Calendar access; the message says how to grant it.     |
| `NOT_FOUND`             | Object missing or inaccessible.                                               |
| `READ_ONLY`             | Calendar does not allow the change.                                           |
| `UNSUPPORTED`           | Stored value cannot be represented.                                           |
| `UNSUPPORTED_OPERATION` | Requested change cannot be stored.                                            |
| `SPAN_REQUIRED`         | Writing one occurrence of a repeating event requires `span`.                  |
| `HAS_ATTENDEES`         | Writing an event with attendees requires `allowAttendeeNotifications`.        |
| `CALENDAR_NOT_EMPTY`    | Deleting a calendar that has events requires `allowNonEmpty`.                 |
| `RESULT_TOO_LARGE`      | More than 20,000 events overlap the window; narrow it.                        |
| `WRITE_FAILED`          | Save failed; message includes the native error code. Refetch before retrying. |
| `WRITE_APPLIED`         | Saved, but a later step failed; message includes the saved ID.                |
| `INTERNAL`              | Unexpected failure.                                                           |

On `WRITE_APPLIED`, inspect the saved ID and apply only missing changes.
Check existing data before retrying a create after a timeout or lost connection.
Writes have no transaction spanning all steps, rollback, or idempotency key.

## Limits

Accounts come from accessible calendars; the default account comes from the default
calendar. Reads are not atomic across the database and do not prove complete cloud
sync. IDs can change after a write or a full sync.
