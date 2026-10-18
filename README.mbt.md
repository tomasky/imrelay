# kupas/imrelay

A Hermes-style agent gateway written in [MoonBit](https://docs.moonbitlang.com) —
one bridge that feeds chat messages from **14 messaging platforms** into your
agent and delivers its replies back, with retries, chunking, typing
indicators, per-chat session context and slash commands.

The adapter layer mirrors the vocabulary of
[Hermes](https://github.com/NousResearch/hermes) (`SendResult` /
`MessageEvent` / `Platform` / `classify_send_error` / `truncate_message`,
per-adapter env var names and `MAX_MESSAGE_LENGTH`s), so ports of existing
Hermes plugins map onto this codebase 1:1.

## Supported platforms

| Platform                  | value          | Inbound                        | Sends                                                     |
| ------------------------- | -------------- | ------------------------------ | --------------------------------------------------------- |
| Telegram                  | `telegram`     | webhook + long-poll            | text / media / edit / delete / typing / reactions         |
| Discord                   | `discord`      | gateway events + interactions  | text / embeds / edit / delete / typing / reactions        |
| Slack                     | `slack`        | events API (signature-checked) | text / edit / delete / typing / reactions                 |
| WhatsApp (Cloud/Meta API) | `whatsapp`     | webhook + hub verification     | text / media / read receipts                              |
| Signal (signal-cli HTTP)  | `signal`       | receive RPC polling            | text via JSON-RPC `send`                                  |
| Email (SMTP/IMAP)         | `email`        | parsed raw messages            | RFC 5322 messages over SMTP (STARTTLS/SSL)                |
| Mattermost                | `mattermost`   | outgoing webhook               | posts via v4 API                                          |
| Matrix                    | `matrix`       | `/sync` polling                | text / edit / reactions / typing (`m.*` events)           |
| DingTalk                  | `dingtalk`     | Stream Mode + robot callback   | session-webhook markdown / app messages / group robot     |
| Feishu / Lark             | `feishu`       | event webhook + challenge      | app messages                                              |
| WeChat (iLink Bot API)  | `weixin`       | long-poll                      | iLink bot messages                                        |
| WeCom (Enterprise WeChat) | `wecom`        | callback (XML + JSON)          | app messages / group-robot webhook, markdown              |
| BlueBubbles (iMessage)    | `bluebubbles`  | new-message webhook            | text via AppleScript, attachments                         |
| Home Assistant            | `homeassistant`| automation webhook             | `notify` / any `notify.*` service                         |

## Build & test

```bash
moon check --target native
moon build  --target native
moon test   --target native        # 136 tests
```

## Run

`example/main` is a runnable gateway. It reads `$IMRELAY_CONFIG` (or
`gateway.toml` in the working directory); if neither exists it falls back to
Hermes-style environment variables.

```bash
IMRELAY_CONFIG=gateway.toml moon run example/main --target native
```

Then:

```
GET  /                        landing page / health check
GET  /health                  {"ok":true,"platforms":N}
POST /<platform>              inbound webhook for that platform (per table above)
```

## Configuration

All configuration is **TOML** (`gateway.toml`); the env-var reader exists so
existing Hermes deployments can migrate without rewriting secrets.

### `gateway.toml`

```toml
[gateway]
name = "my-gateway"            # optional
host = "0.0.0.0"               # listen address
port = 8080                    # listen port
public_url = "https://chat.example.com/"   # optional, used for webhook hints
allowed_users = ["alice"]      # optional global allow-list
allow_all_users = true         # optional; default false

[platforms.telegram]
token = "123:abc"
home_channel = "-100123"
home_channel_name = "Ops"
home_channel_thread = "42"
allowed_users = ["alice"]

[platforms.telegram.extra]     # platform-specific options (see below)
parse_mode = "MarkdownV2"
api_base = "https://tg.local"  # optional self-hosted Bot API
polling = true                 # telegram also long-polls by default
```

Per-platform keys: `enabled` (default `true`), `token`, `api_key`,
`home_channel`, `home_channel_name`, `home_channel_thread`, `allowed_users`,
and an `extra` table of string values. Any `[platforms.<name>]` section key not
listed above goes into `extra` automatically (arbitrary adapter settings).

Inbound requests are authenticated before the event is parsed:

| Platform     | `extra` key                            | Check                                                     |
| ------------ | -------------------------------------- | --------------------------------------------------------- |
| Telegram     | `webhook_secret`                       | `X-Telegram-Bot-Api-Secret-Token` (required)              |
| Discord      | —                                      | gateway events arrive over an **outbound** WebSocket, not a public webhook |
| Slack        | `signing_secret`                       | `X-Slack-Signature` + 5-minute replay window (required)   |
| WhatsApp     | `app_secret`                           | `X-Hub-Signature-256` HMAC of the raw body (required)     |
| Signal       | —                                      | `signal-cli` receive-RPC polling; no public endpoint      |
| Email        | —                                      | IMAP polling; no public endpoint                          |
| Mattermost   | `webhook_token`                        | `token` in the outgoing-webhook body (when set)           |
| Matrix       | —                                      | `/sync` polling; no public endpoint                       |
| DingTalk     | `client_id` + `client_secret`          | Stream Mode long-connection (no public URL); HTTP robot callbacks are unsigned — keep the callback URL secret |
| Feishu/Lark  | `verification_token` / `encrypt_key` not checked yet | `challenge` handshake only — keep the endpoint URL secret, or front it with your own auth |
| WeChat       | —                                      | iLink long-poll; no public endpoint                       |
| WeCom        | `callback_token` + `encoding_aes_key`  | `msg_signature` SHA1 + AES-256-CBC decrypt (when set)     |
| BlueBubbles  | `password`                             | `password` query param / `x-password` header (when set)   |
| Home Assistant | —                                    | automation webhook; the URL itself is the secret          |

Missing Telegram/Slack/WhatsApp secrets **fail closed** — `POST /<platform>`
answers `503` with the configuration hint until the secret is set. WeCom
callback crypto is opt-in: with `encoding_aes_key` set, `POST /wecom`
verifies `msg_signature`, decrypts the `<Encrypt>` envelope (answering the
GET `echostr` handshake the same way) and acks `success`; without it, bodies
pass through unchanged (relay mode). DingTalk's Stream Mode needs no public
endpoint at all: the gateway opens the connection outbound with
`client_id`/`client_secret` (`stream = false` opts out).

### Environment variables

The same config is available as env vars (used only when no TOML is present):

| Platform                  | Variables                                                                                   |
| ------------------------- | ------------------------------------------------------------------------------------------- |
| Global                    | `GATEWAY_ALLOWED_USERS`, `GATEWAY_ALLOW_ALL_USERS`                                          |
| Telegram                  | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_WEBHOOK_SECRET`, `TELEGRAM_HOME_CHANNEL[_NAME]`, `TELEGRAM_ALLOWED_USERS` |
| Discord                   | `DISCORD_BOT_TOKEN`, `DISCORD_HOME_CHANNEL[_NAME]`, `DISCORD_ALLOWED_USERS`                  |
| Slack                     | `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, `SLACK_SIGNING_SECRET`, `SLACK_HOME_CHANNEL[_NAME]`, `SLACK_ALLOWED_USERS`     |
| WhatsApp                  | `WHATSAPP_CLOUD_PHONE_NUMBER_ID`, `WHATSAPP_CLOUD_ACCESS_TOKEN`, `WHATSAPP_CLOUD_API_VERSION`, `WHATSAPP_CLOUD_VERIFY_TOKEN`, `WHATSAPP_CLOUD_APP_SECRET`, `WHATSAPP_HOME_CHANNEL[_NAME]`, `WHATSAPP_ALLOWED_USERS` |
| Signal                    | `SIGNAL_HTTP_URL`, `SIGNAL_ACCOUNT`, `SIGNAL_HOME_CHANNEL[_NAME]`, `SIGNAL_ALLOWED_USERS`    |
| Email                     | `EMAIL_ADDRESS`, `EMAIL_PASSWORD`, `EMAIL_SMTP_HOST`, `EMAIL_SMTP_PORT`, `EMAIL_IMAP_HOST`, `EMAIL_HOME_ADDRESS[_NAME]`, `EMAIL_ALLOWED_USERS` |
| Mattermost                | `MATTERMOST_TOKEN`, `MATTERMOST_URL`, `MATTERMOST_WEBHOOK_TOKEN`, `MATTERMOST_HOME_CHANNEL[_NAME]`, `MATTERMOST_ALLOWED_USERS` |
| Matrix                    | `MATRIX_HOMESERVER`, `MATRIX_ACCESS_TOKEN` (or `MATRIX_PASSWORD` + `MATRIX_USER_ID`), `MATRIX_HOME_ROOM[_NAME]`, `MATRIX_ALLOWED_USERS` |
| DingTalk                  | `DINGTALK_CLIENT_ID`, `DINGTALK_CLIENT_SECRET`, `DINGTALK_WEBHOOK_URL`, `DINGTALK_ROBOT_CODE`, `DINGTALK_STREAM`, `DINGTALK_REQUIRE_MENTION`, `DINGTALK_FREE_RESPONSE_CHATS`, `DINGTALK_MENTION_PATTERNS`, `DINGTALK_HOME_CHANNEL[_NAME]`, `DINGTALK_ALLOWED_USERS` |
| Feishu/Lark               | `FEISHU_APP_ID`, `FEISHU_APP_SECRET`, `FEISHU_DOMAIN`, `FEISHU_HOME_CHANNEL[_NAME]`, `FEISHU_ALLOWED_USERS` |
| WeChat (iLink)            | `WEIXIN_ACCOUNT_ID`, `WEIXIN_TOKEN`, `WEIXIN_BASE_URL`, `WEIXIN_HOME_CHANNEL[_NAME]`, `WEIXIN_ALLOWED_USERS` |
| WeCom                     | `WECOM_CALLBACK_CORP_ID`, `WECOM_CALLBACK_CORP_SECRET`, `WECOM_CALLBACK_AGENT_ID`, `WECOM_CALLBACK_TOKEN`, `WECOM_CALLBACK_ENCODING_AES_KEY`, `WECOM_GROUP_ROBOT_WEBHOOK`, `WECOM_HOME_CHANNEL[_NAME]`, `WECOM_ALLOWED_USERS` |
| BlueBubbles               | `BLUEBUBBLES_SERVER_URL`, `BLUEBUBBLES_PASSWORD`, `BLUEBUBBLES_HOME_CHANNEL[_NAME]`, `BLUEBUBBLES_ALLOWED_USERS` |
| Home Assistant            | `HASS_TOKEN`, `HASS_URL` (`HASS_HOME_CHANNEL`/`HASS_HOME_CHANNEL_NAME` if configured)        |

## How it works

1. **Inbound** — a webhook server on `<host>:<port>` routes `POST /<platform>`
   to the matching adapter's parser, which normalizes the payload into a
   `MessageEvent`. Webhook requests are authenticated first (see the table
   above); handshakes are answered before that: Slack/Feishu `challenge`,
   WhatsApp `hub.challenge`, WeCom `echostr`. Telegram and WeChat
   additionally long-poll, Matrix polls `/sync`, and DingTalk streams robot
   messages over its WebSocket long-connection (each in its own background
   task).
2. **Authorization** — every event must pass `allowed_users`: the platform or
   gateway allowlist must contain the user id (or `*`), unless
   `allow_all_users = true`. With no allowlist configured the gate is closed
   (the gateway logs who was dropped, and warns at startup). A `home_channel`
   (with optional thread/name) marks where notifications go.
3. **Session** — each `(platform, chat_id)` gets a `Session` with bounded
   history (`Gateway::new(cfg, handler, max_history=24)`). The agent callback
   `async (MessageEvent, Session) -> String` receives both.
4. **Commands** — inbound text starting with `/` is intercepted first: `/help`,
   `/reset`, `/new`, `/status`, `/platforms` are answered locally; unknown
   commands still reach the agent.
5. **Send** — a reply is delivered through the platform adapter: chunked at
   `Platform::max_message_length`, trimmed to `truncate` limits, retried on
   transient failures with backoff honoring server `retry_after`
   (Telegram FloodWait etc.), and suppressed when the handler returns a
   silence token (`[silent]`, `no reply`, empty).
6. **Errors** — every failure is a typed `SendResult` with
   `SendErrorKind` (`TooLong/BadFormat/Forbidden/NotFound/RateLimited/
   Transient/Unknown`) via `classify_send_error`, mirroring Hermes'
   `SEND_ERROR_KINDS`.

## Library quick tour

```moonbit nocheck
// Normalize a raw webhook body (any platform).
let events : Array[MessageEvent] = @imrelay.parse_inbound(@imrelay.Telegram, raw)

// Build the gateway with a history-aware agent.
let gw = @imrelay.Gateway::new(cfg, async (ev, session) => "echo: \{ev.text}")
gw.run()

// Classify send failures the way Hermes does.
let kind = @imrelay.classify_send_error("Bad Request: chat not found") // NotFound
assert_true(@imrelay.is_chat_level_not_found("chat not found"))

// Chunk a long reply at a platform's limit, preferring paragraph breaks.
let chunks = @imrelay.chunk_text(long_reply, @imrelay.Platform::max_message_length(p))
```

Central types (`types.mbt`): `Platform`, `MessageType` (Text/Command/Photo/
Video/Audio/Voice/Document/Sticker/Location), `SendErrorKind`, `SendResult`,
`HomeChannel`, `ChatInfo`, `MediaAttachment`, `MessageEvent`. Supporting
modules: `http.mbt` (typed `ApiError`, retry/backoff), `session.mbt`
(`Session`, `SessionStore`, `parse_command`/`command_reply`/
`is_silent_reply`), `config.mbt` (`GatewayConfig`, `PlatformConfig`, TOML +
env loaders), `dispatch.mbt` (`parse_inbound`, `send_message`,
`platform_configured`), `gateway.mbt` (`Gateway`, `HubParams`).

## Testing

`imrelay_test.mbt` (core types / session / config) and `platforms_test.mbt`
(payload builders, inbound parsers, Slack signature vectors, WhatsApp
`retry_after`, WeCom crypto — official `WXBizMsgCrypt` vector, DingTalk
stream frames / session-webhook cache / group gating, dispatch routing per
adapter) — 136 tests:

```bash
moon test --target native
```

## Platform notes

- **BlueBubbles (iMessage)** — built in as a first-class adapter: it talks
  directly to the REST API of *your own* BlueBubbles server
  (`{server_url}/api/v1`, `GET /ping`, `POST /message/text`, `POST /chat/query`,
  password-authenticated), and receives inbound messages from that server's
  new-message webhook (`{"type":"new-message","data":…}`). You only need to
  run a BlueBubbles server on your Mac — the same way Signal needs your own
  `signal-cli` HTTP daemon and Telegram can use a self-hosted Bot API base.
  Messages use `chats[].guid` as the chat id.
- **WeChat** — via Tencent's official *iLink Bot API* (`base_url` default
  `https://ilinkai.weixin.qq.com`, long-polled): you scan a QR to bind a bot
  identity, and only direct messages are reliably delivered — iLink bots
  typically cannot join regular group chats. Media uploads (encrypted CDN)
  and the QR setup wizard are not ported; the adapter covers text send,
  typing and long-poll receive.
- **WhatsApp**: Cloud Business API over Graph (`graph.facebook.com`), with
  hub verification for webhook subscriptions.
- **DingTalk** — inbound rides DingTalk's recommended **Stream Mode**: with
  `client_id`/`client_secret` configured the gateway POSTs
  `v1.0/gateway/connections/open`, subscribes to `/v1.0/im/bot/messages/get`
  on the returned WebSocket, acks every callback (so the server's 60-second
  redelivery never bites), echoes `ping`/`disconnect` frames and reconnects
  with exponential backoff (1 s → 60 s). No public callback URL is needed;
  the legacy `POST /dingtalk` robot callback keeps working, and
  `[dingtalk.extra] stream = false` turns Stream Mode off.
  Replies go through the freshest **`sessionWebhook`** (cached per chat with
  a 5-minute expiry margin, `@`-ing the sender back in group chats), falling
  back to the app-robot API (`robot/oToMessages/batchSend`) or a static group
  robot webhook (`webhook_url`, or `webhook_base` + `access_token`).
  Group trigger rules match Hermes: `require_mention` (default `false`),
  `free_response_chats` (comma-separated chat ids that never need a mention),
  `mention_patterns` (JSON array or CSV; case-insensitive substring wake
  words) — DMs always pass.
- **WeCom**: keys/secret pairs for the official app APIs, plus a static
  inbound-robot webhook; callback mode implements the official
  `WXBizMsgCrypt` `msg_signature` + AES-256-CBC verification and decryption
  (`callback_token` + `encoding_aes_key`) and the GET `echostr` handshake.
- **Feishu / Lark**: `app_id`/`app_secret` app messages and the event-webhook
  `challenge` handshake; `verification_token`/`encrypt_key` signature
  verification is not implemented yet — keep the endpoint URL secret.