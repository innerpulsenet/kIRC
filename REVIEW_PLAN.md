# kIRC Full Application Review Plan

## Objective

Review kIRC end to end for defects and improvement opportunities in three areas:

1. Network connection reliability and IRC protocol correctness.
2. Runtime performance, resource use, and responsiveness.
3. Visual polish, accessibility, and user experience.

## Scope

- `rust/core`: parsing, capability negotiation, SASL, TLS, session lifecycle,
  keepalive, timeouts, reconnect behavior, outbound writes, and IRC state.
- `rust/src`: asynchronous runtime ownership, Qt/Rust bridging, model updates,
  buffer management, notification events, and command handling.
- `rust/qml`: connection, chat, settings, message rendering, themes, effects,
  keyboard navigation, focus, accessibility, and responsive layout.
- `cpp`: application lifecycle, configuration and secret handling,
  notifications, tray behavior, and QML integration.
- Build, packaging, and automated tests where they affect correctness or user
  experience.

## Review Sequence

### 1. Establish a baseline

- Run the Rust core test suite and available QML smoke/performance suites.
- Build or statically validate the full application where local dependencies
  permit it.
- Record existing failures separately from issues introduced by later changes.

### 2. Audit connection reliability

- Trace connect, DNS/TCP/TLS setup, registration, CAP and SASL negotiation,
  authentication, join, disconnect, and reconnect state transitions.
- Check timeout coverage, cancellation behavior, partial reads/writes, EOF,
  backpressure, message framing, server error propagation, and task cleanup.
- Review keepalive/PING handling, nick collisions, reconnect scheduling,
  connection-generation races, and stale-event suppression.
- Check IRC message length limits, encoding assumptions, malformed input, and
  state consistency under unusual server ordering.
- Add focused regression tests for confirmed defects.

### 3. Audit and optimize performance

- Inspect hot paths for unnecessary allocations, copies, model resets, broad
  QML bindings, repeated JavaScript work, excessive timers, and unbounded data.
- Review transcript append/switch/scroll behavior and large channel/member
  lists.
- Check async channel capacities and behavior under inbound/outbound bursts.
- Make only measurable or clearly justified low-risk optimizations and verify
  them with existing or new tests/benchmarks.

### 4. Review visual polish and UX

- Inspect the main connect, chat, settings, empty, loading, error, and
  disconnected states at representative window sizes and themes.
- Check focus order, keyboard operation, discoverability, validation,
  connection feedback, destructive-action affordances, unread state, and
  accessibility metadata/contrast.
- Review screenshots and render the live QML tests/application when possible.
- Implement focused improvements that preserve the terminal-style design.

### 5. Verify and report

- Re-run relevant Rust, QML, and integration tests after each change group.
- Review the final diff for regressions, scope creep, and unrelated edits.
- Deliver a concise findings report listing fixed issues, remaining risks,
  verification performed, and any recommendations that require product input.

## Change Policy

- Preserve existing user changes and avoid unrelated rewrites.
- Prefer small, reviewable fixes with regression coverage.
- Do not weaken TLS, authentication, privacy, or error reporting for
  convenience or performance.
- Separate confirmed defects from subjective polish recommendations.
