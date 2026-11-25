# MCP

`POST /mcp` accepts one JSON-RPC 2.0 message using protocol `2025-11-25`.
Supports `initialize`, `ping`, `tools/list`, `tools/call`, and accepted notifications
(HTTP 202). GET returns 405. Stateless: no session header, SSE stream, server
requests, or resumability.

Send `Content-Type: application/json`, `Accept: application/json, text/event-stream`,
and, after initialization, `MCP-Protocol-Version: 2025-11-25`.

```sh
curl --unix-socket /path/to/server.sock http://localhost/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"example","version":"1"}}}'
```

`tools/list` returns current descriptions and input/output schemas; the
[catalog](mcp-tools.json) is an export. Annotations do not grant permission.
The server requires `rw` for any tool without `readOnlyHint: true`.

## Inputs and results

Reject unknown argument fields and explicit null anywhere in tool arguments,
including nested values; omit optional inputs instead. Calls read fresh data.
Pagination cursors are decimal offsets, not snapshots: keep filters, ordering,
and limit unchanged, and expect concurrent edits to affect later pages.

`events_search` and `calendars_summary` read a [window](GRAPHQL.md#event-windows) and
echo the resolved `from` and `before`; repeat them with later pages. `events_search`
fetches only the calendars its filter names.

The [span rules](GRAPHQL.md#events-and-occurrences) and
[input alias rules](GRAPHQL.md#input-aliases) apply to both APIs.

Event results always include the projected fields `startDate`, `endDate`,
`allDayStartDate`, `allDayEndDate`, `timeZone`, `alarms`, and `recurrence`, as null
when absent; other optional stored values are omitted when absent. A window spans
calendars the user does not control, so a stored alarm or recurrence the simplified
form cannot represent does not fail the call: the field is null, `unsupported` names
it, and `rawAlarms` or `recurrenceRules` holds the stored value.

Successful calls return `structuredContent` and matching JSON text. Tool failures
set `isError: true` and omit `structuredContent`. Application errors return JSON
text shaped as `{"error":{"code":"...","message":"..."}}`; permission denials
return plain text. See [error codes](SERVER.md#errors).
Unknown tools and protocol/dispatch failures use JSON-RPC errors instead of tool
results. A successful HTTP response alone does not establish tool success.
