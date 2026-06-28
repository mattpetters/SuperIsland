# lazytask Native Apple Client Spec

## Goal

Build the fastest native Taskwarrior client across macOS, iOS, and watchOS. The app should feel instant for capture, triage, completion, and review while preserving a consistent source of truth across devices.

## Product Principles

- Fully native Swift on every platform: SwiftUI for shared surfaces, AppKit/UIKit only where platform-specific speed or text handling matters.
- Local-first interaction: every create, complete, rename, schedule, and tag action commits to a local store immediately.
- Sync is continuous and boring: changes should resolve without manual refresh and should surface conflicts only when a user decision is genuinely needed.
- Taskwarrior compatibility stays real: import/export Taskwarrior JSON faithfully, preserve UUIDs, annotations, tags, projects, due dates, recurrence, dependencies, and UDAs.
- Power user speed matters: keyboard-first macOS, one-handed iOS capture, watch complications/actions, command palette everywhere practical.

## Platform Shape

### macOS

- Menu bar utility plus full window.
- Global quick-capture hotkey with natural-language parsing.
- Command palette for search, complete, defer, project/tag changes, sync status, and saved filters.
- Fast list views: Inbox, Today, Next, Waiting, Projects, Tags, Completed, Custom Reports.
- Bulk operations with multi-select and keyboard shortcuts.
- Optional Taskwarrior CLI bridge for users who already have `task` installed.

### iOS

- Capture-first home screen with Today and Inbox one tap away.
- Search that doubles as command entry: `+work due friday Pay invoice`, `done taxes`, `@home light`.
- Widgets for Today, next task, project counts, and quick add.
- Share extension for URL/text capture.
- Shortcuts/App Intents for add, complete, search, and start focus session.

### watchOS

- Glanceable Today and Inbox.
- Complications for next task and overdue count.
- Dictation capture with confirmation.
- One-tap complete/defer.
- Sync status should be passive; never block capture.

## Core Data Model

- `TaskRecord`: UUID, status, description, project, tags, priority, due, wait, scheduled, until, recurrence, annotations, dependencies, UDAs, entry, modified, end.
- `Mutation`: stable local ID, task UUID, operation, payload, createdAt, baseRevision, syncState.
- `SyncPeer`: device ID, lastSeen, lastVector, capabilities.
- `SavedView`: name, Taskwarrior-compatible filter, sort, platform visibility.

Store all records in SQLite via SwiftData or GRDB. Prefer GRDB if SwiftData conflict behavior or migration control gets in the way.

## Sync Strategy

Recommended first version: local SQLite + CloudKit private database + optional Taskwarrior sync bridge.

- CloudKit is the Apple-device consistency layer. It gives push-driven updates, offline queuing, account-level privacy, and no server to operate.
- Taskwarrior sync support should be a bridge, not the only transport. It should import/export through a sync adapter and run on macOS first, then iOS if config/key handling is reliable enough.
- Every local mutation applies optimistically, records a mutation log entry, and updates UI immediately.
- CloudKit pushes compact task records plus mutation metadata. Devices merge by UUID and modified timestamps, with field-level merge for low-risk fields.
- Conflict policy:
  - Completion status: newest mutation wins unless a task was deleted.
  - Description/project/tags/dates: field-level newest mutation wins.
  - Annotations: append by annotation UUID.
  - Dependencies: union if both sides changed, then validate missing UUIDs.
  - Delete vs edit: delete wins but remains recoverable in a trash/completed archive window.
- Sync health UI must show last successful sync, queued mutations, remote errors, and account/config issues.

Taskwarrior server option:

- Support `taskd` as an advanced sync target for users already invested in it.
- Keep CloudKit as the default Apple-device sync unless `taskd` proves as reliable on iOS as macOS.
- If both are enabled, designate one canonical remote and treat the other as an import/export bridge to avoid split brain.

## Fast UX Requirements

- Add task from cold start in under 2 seconds on iPhone and under 1 second from running app.
- Search should return local results in under 50 ms for 10k tasks.
- Complete/uncomplete should update visible lists instantly.
- Sync should begin within 1 second of foregrounding and react to CloudKit pushes in the background where allowed.
- All primary actions are available without leaving the current list.

## First Milestone

- Shared Swift package with data model, local store, Taskwarrior JSON parser/writer, filter parser, mutation log, and CloudKit adapter skeleton.
- macOS app: quick capture, list/search, complete/uncomplete, rename description, project/tag display, manual sync status.
- iOS app: capture, Today/Inbox, search, complete/uncomplete, rename description, CloudKit sync.
- watchOS app: Today list, quick complete, dictation add.

## Open Questions

- Whether to use GRDB from day one for predictable migrations and query speed.
- How much Taskwarrior filter syntax to support before 1.0.
- Whether recurring task generation should exactly mirror Taskwarrior behavior locally or delegate recurrence expansion to an adapter.
- How to safely handle `taskd` credentials on iOS without making setup fragile.
