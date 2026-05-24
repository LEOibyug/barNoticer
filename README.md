# barNoticer

barNoticer is a lightweight macOS todo companion that lives around the camera notch. It turns the unused top-center screen area into a small “dynamic island” for quick task capture, review, and completion.

The app is designed for Apple Silicon Macs with a notch. It stays out of the Dock by default, opens a compact island when your pointer reaches the top hot zone, and keeps a conventional management window for settings and deeper edits.

> This branch keeps the repository source-focused. If you want to clone and build the app directly with Xcode, use the `xcode-project` branch.

## Highlights

- Notch island panel that expands naturally from the top hot zone.
- Standard and wide island layouts.
- Priority-based and custom-group-based task views.
- Quick add from inside the island.
- Task priority, completion state, custom groups, and optional deadlines.
- Remaining-time display for tasks with deadlines.
- Adjustable hot zone and expanded panel position.
- AI assistant with OpenAI-compatible Chat Completions APIs.
- Global shortcut for a Spotlight-like AI input panel.
- Optional confirmation before AI applies task operations.
- Local debug logs for AI requests, responses, and app events.
- Launch-at-login setting.

## Screens and Workflow

The main workflow has two surfaces:

- Island panel: fast capture and review near the macOS notch.
- Main window: full task management, groups, AI settings, island layout settings, and app preferences.

The island can display tasks by priority or by custom group. In wide mode it uses the extra horizontal space to show multiple columns, and group mode can scroll horizontally when there are more than three groups.

## AI Assistant

barNoticer can connect to OpenAI-compatible APIs. Users configure:

- Base URL
- model name
- API key
- global shortcut
- whether AI actions need manual confirmation

The assistant receives structured task context only from the local app: active tasks, completed tasks, groups, deadlines, creation times, daily summaries, current date, and timezone. It can propose or apply operations such as creating tasks, updating metadata, completing tasks, deleting tasks, creating groups, and saving daily summaries.

API keys are stored locally in app defaults, not committed to this repository.

## Repository Layout

```text
barNoticer/
  App, views, models, controllers, AI client, island logic, and assets
README.md
.gitignore
```

The `main` branch intentionally excludes local Xcode project scaffolding and tests so the repository reads cleanly as source code. Build scaffolding is available on the `xcode-project` branch.

## Build From Source

For a directly buildable checkout:

```bash
git clone -b xcode-project git@github.com:LEOibyug/barNoticer.git
cd barNoticer
open barNoticer.xcodeproj
```

Then select the `barNoticer` scheme in Xcode and run it.

Command-line Release build:

```bash
xcodebuild build \
  -project barNoticer.xcodeproj \
  -scheme barNoticer \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/barNoticerRelease
```

Install the local build:

```bash
ditto /private/tmp/barNoticerRelease/Build/Products/Release/barNoticer.app /Applications/barNoticer.app
open /Applications/barNoticer.app
```

Local builds use Xcode's local/ad-hoc signing by default. For public distribution, configure Developer ID signing, Hardened Runtime, and notarization.

## Requirements

- macOS
- Apple Silicon Mac
- Xcode with a recent macOS SDK
- SwiftUI and SwiftData support

## Logs

The app writes lightweight local logs for debugging. The log location is shown in the app's island settings page and typically resolves inside the app container:

```text
~/Library/Containers/com.LEOibyug.barNoticer/Data/Library/Application Support/barNoticer/Logs/barNoticer.log
```

Runtime logs and user configuration are local data and are not part of this repository.

## Data Model

barNoticer uses SwiftData models:

- `TodoItem`
- `TodoGroup`
- `DailySummary`

The built-in default group is named `默认分组` and cannot be deleted. Deleting a custom group moves its tasks back to the default group.

## Branches

- `main`: source-focused branch for browsing and documentation.
- `xcode-project`: buildable branch with Xcode project files and tests.

## Status

This is an experimental personal macOS utility. The core app is usable locally, but distribution packaging, notarization, and broader device compatibility are still intentionally lightweight.
