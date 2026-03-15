# PocketBase MCP Server (Dart)

Dart implementation of a PocketBase MCP server using:

- `mcp_dart: ^2.1.0`
- `pocketbase: ^0.23.2`

## Requirements

- Dart SDK 3.x
- A reachable PocketBase instance

## Install

```bash
dart pub get
```

## Run (stdio MCP server)

```bash
POCKETBASE_URL=http://127.0.0.1:8090 \
POCKETBASE_ADMIN_EMAIL=admin@example.com \
POCKETBASE_ADMIN_PASSWORD=admin_password \
dart run
```

Permission-related environment variables:

- `PB_MCP_MODE`: `readonly` or `readwrite` (default: `readwrite`)
- `PB_MCP_ALLOWED_TOOLS`: comma-separated allow list (optional)
- `PB_MCP_DENIED_TOOLS`: comma-separated deny list (optional)

## Available Tools

- General:
  - `get_server_permissions`
  - `raw_api_call` (full PocketBase API bridge)
- Records:
  - `get_record`, `list_records`, `list_all_records`
  - `create_record`, `update_record`, `delete_record`, `import_data`
- Auth:
  - `list_auth_methods`, `authenticate_user`, `auth_refresh`
  - `authenticate_with_oauth2`, `request_otp`, `authenticate_with_otp`
  - `request_verification`, `confirm_verification`
  - `request_password_reset`, `confirm_password_reset`
  - `request_email_change`, `confirm_email_change`
  - `create_user`, `impersonate_user`
- Collections:
  - `create_collection`, `update_collection`, `delete_collection`, `truncate_collection`
  - `list_collections`, `get_collection`, `get_collection_scaffolds`
- Backups:
  - `backup_database`, `list_backups`, `delete_backup`, `restore_backup`
- Admin Observability and Ops:
  - `list_logs`, `get_log`, `get_logs_stats`
  - `list_cron_jobs`, `run_cron_job`
  - `health_check`
  - `get_settings`, `update_settings`, `test_s3_settings`, `send_test_email`

Notes:

- In `readonly` mode, write tools are blocked.
- For `raw_api_call`, `readonly` mode allows only `GET`.
- Admin tools require `POCKETBASE_ADMIN_EMAIL` and `POCKETBASE_ADMIN_PASSWORD`.

## VS Code MCP config example

Use `.vscode/mcp.json`:

```json
{
  "servers": {
    "pocketbaseDart": {
      "type": "stdio",
      "command": "dart",
      "args": ["run", "bin/server.dart"],
      "cwd": "${workspaceFolder}",
      "env": {
        "POCKETBASE_URL": "http://127.0.0.1:8090",
        "POCKETBASE_ADMIN_EMAIL": "admin@example.com",
        "POCKETBASE_ADMIN_PASSWORD": "admin_password",
        "PB_MCP_MODE": "readwrite",
        "PB_MCP_ALLOWED_TOOLS": "",
        "PB_MCP_DENIED_TOOLS": "delete_record,delete_collection"
      }
    }
  }
}
```

## Test command

```bash
dart run
```

## AOT build (local host target)

```bash
./scripts/build_release.sh
```

This script produces a native executable in `build/` for your current platform.

## Build with Makefile

```bash
make aot
```

Builds native AOT executable:

- `build/pocketbase_mcp`

Windows x64 cross-compile:

```bash
make win
```

Builds:

- `build/pocketbase_mcp.exe`

Additional release targets:

```bash
make mac-amd64
make mac-arm64
make all-release
```

## Release targets

This repo includes a GitHub Actions workflow to publish AOT executables for:

- macOS amd64
- macOS arm64
- Windows amd64

The workflow compiles on native runners per target architecture and uploads artifacts.
