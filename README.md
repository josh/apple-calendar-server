# apple-calendar-server

A Swift HTTP server for reading and changing Apple Calendar events on macOS through
GraphQL and MCP, with Prometheus metrics for event counts. EventKit runs in the
server process.

| Endpoint        | Documentation                                               |
| --------------- | ----------------------------------------------------------- |
| `POST /graphql` | [GraphQL](docs/GRAPHQL.md), [schema](docs/calendar.graphql) |
| `POST /mcp`     | [MCP](docs/MCP.md), [tool catalog](docs/mcp-tools.json)     |
| `GET /metrics`  | [Metrics](docs/METRICS.md), [example](docs/metrics.prom)    |

## Running

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.github.josh.apple-calendar-server</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/apple-calendar-server</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CALENDAR_REQUEST_ACCESS</key>
    <string>1</string>
  </dict>
  <key>Sockets</key>
  <dict>
    <key>Listeners</key>
    <dict>
      <key>SockPathName</key>
      <string>/Users/josh/Library/Application Support/apple-calendar-server/server.sock</string>
      <key>SockPathMode</key>
      <integer>384</integer>
    </dict>
  </dict>
</dict>
</plist>
```
