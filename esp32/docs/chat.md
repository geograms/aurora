# Chat System

This document describes the Wi-Fi AP chat page, the HTTP API, and how messages are stored and signed.

## Overview

- The ESP32 runs a softAP and serves a single-page chat UI at `/`.
- Clients connect to the AP and load the chat UI from the ESP32.
- The ESP32 keeps a rolling history of the last 100 messages in RAM.
- Messages are stored in arrival order and returned by ID.

## HTTP Endpoints

- `GET /`
  - Serves the chat HTML page.
  - Injects a bundled `nostr-tools` build into the page.

- `GET /api/chat/messages?since=<id>`
  - Returns a JSON payload with messages newer than `since`.
  - Also returns `latest_id`, `count`, `max_len`, and `my_callsign`.
  - Message order is by arrival ID, not by timestamp.

- `POST /api/chat/send`
  - Form fields:
    - `text` (required): message text.
    - `callsign` (optional): sender callsign.
    - `client_ts` (optional): Unix timestamp (seconds) from the browser.
    - `event` (optional): JSON string of a signed Nostr event (kind 1).
  - Stores the message locally with the provided callsign.
  - Uses `client_ts` if provided; otherwise falls back to device time.

- `POST /api/chat/client`
  - Form fields:
    - `callsign`, `npub`, `mode`, `error`.
  - Used by the browser to report key status for logging on the ESP32.

## Browser Key Handling

- The page prefers a Nostr extension if present (`window.nostr`).
  - It calls `window.nostr.getPublicKey()`.
  - It derives `npub` and `callsign` from the returned hex pubkey.
- If no extension is available, the page generates local keys.
  - The keys are stored in `localStorage` under `geogram_nostr_keys`.
- Callsign format: `X1` + first 4 chars of `npub` (uppercased).

## Nostr Signed Notes

- Messages can be signed as Nostr kind-1 events.
- The browser uses its own time (`created_at`) in seconds.
- A `client_time` tag is added with ISO time (`YYYY-MM-DDTHH:MM:SSZ`).
- The signed event is sent in the `event` field of `/api/chat/send`.

## Message Storage

- Chat history is stored in a fixed-size ring buffer on the ESP32.
- Maximum history: 100 messages.
- Each message includes:
  - `id`: incrementing arrival ID.
  - `timestamp`: Unix time (device or client).
  - `callsign`: sender callsign.
  - `text`: message text (max 200 chars).

## UI Behavior

- Portrait mode: local messages on the right, remote messages on the left.
- Landscape mode: all messages aligned left.
- Timestamps are rendered as `YYYY-MM-DD HH:MM` using browser time.
- The footer shows: `Connected to station <CALLSIGN>` when known.
- The hamburger menu includes “Reset local data,” which clears local keys, clears the message list, and skips previously stored history when the next poll runs.

## Logging

The ESP32 logs key and chat actions to the serial console, including:

- Client key status and npub (from `/api/chat/client`).
- Chat message posts.
- Signed event receipts (size and client timestamp when provided).

## Attachments (metadata-only)

Goal: allow users to attach files while the station stores only metadata (no binary). Files are shared client-to-client.

### Metadata message

Attachment messages are a special chat message type that contain:

- `sha1` (20-byte hash, hex in UI)
- `size` (bytes)
- `mime_type` (e.g., `image/png`)
- `filename` (optional)
- `text` (caption/description)

These metadata messages are stored in the same 100-message ring buffer and expire like any other message.

### Client flow (browser)

1) User selects a file (max 20MB).  
2) Browser computes SHA1 and collects metadata.  
3) Browser sends metadata to the station, which stores a file-type message.  
4) Browser retains the binary locally (memory/IndexedDB) for later sharing.  

### Station/API plan

- HTTP endpoint: `POST /api/chat/send-file` (metadata only).
- Server calls a file-message helper (local-only or mesh-broadcast) to insert metadata into history.
- No binary is stored on the ESP32.

### Discovery + transfer

WebSocket signaling already exists in `ws_server`:

- `file_request`: broadcast “who has sha1?”
- `file_available`: response from a client who has the file
- `file_fetch`: request a peer to start transfer
- `file_chunk`: chunked data relay
- `file_complete`: transfer finished metadata
- `rtc_offer/answer/ice`: optional (unused in this flow)

The chat UI will:

- Show a “Request file” action for file messages.
- Send a `file_request` with `sha1` and client ID.
- Listen for `file_available` and initiate transfer.

### Transfer

- WebSocket relay by client ID (`file_fetch`, `file_chunk`, `file_complete`).
- Sender streams chunks to the recipient via the station as a relay.
- Station still does not store binaries; it only forwards frames.

### Limits and lifecycle

- File size limit: 20MB per file.
- Metadata messages expire after 100 total messages.
- Binary data lives only on clients and can be evicted by the browser.
