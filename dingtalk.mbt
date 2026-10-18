// DingTalk adapter.
//
// Mirrors Hermes `plugins/platforms/dingtalk/adapter.py` (which now speaks
// Stream Mode) and the openclaw community connectors. Three transports are
// supported:
//
// - inbound **Stream Mode** (recommended): a WebSocket long-connection opened
//   with `client_id`/`client_secret` (`[dingtalk.extra] stream = false` opts
//   out) — no public callback URL is needed;
// - inbound **robot callback** (legacy): DingTalk POSTs the message to the
//   gateway's `/dingtalk` route;
// - outbound replies: the `sessionWebhook` from the freshest inbound message
//   (markdown, `@`-ing the sender back in group chats), falling back to the
//   app-robot API (`robot/oToMessages/batchSend`) or a static group-robot
//   webhook.

///|
/// Robot webhook access token (`DINGTALK_ACCESS_TOKEN` / `[dingtalk.extra]`).
pub fn dingtalk_robot_token(cfg : PlatformConfig) -> String? {
  match cfg.extra_first(["access_token", "robot_token"]) {
    Some(t) => Some(t)
    None => cfg.token_of()
  }
}

///|
/// App credentials (`DINGTALK_CLIENT_ID` + `DINGTALK_CLIENT_SECRET`).
pub fn dingtalk_app_key(cfg : PlatformConfig) -> String? {
  cfg.extra_first(["client_id", "app_key"])
}

///|
/// App secret, also accepted as `api_key`.
pub fn dingtalk_app_secret(cfg : PlatformConfig) -> String? {
  match cfg.extra_first(["client_secret", "app_secret"]) {
    Some(s) => Some(s)
    None => cfg.api_key_of()
  }
}

///|
/// `robotCode` used by the app-robot APIs: `[dingtalk.extra] robot_code` when
/// set, else the app key (DingTalk's convention for self-built robots).
pub fn dingtalk_robot_code(cfg : PlatformConfig) -> String? {
  match cfg.extra_first(["robot_code"]) {
    Some(rc) => Some(rc)
    None => dingtalk_app_key(cfg)
  }
}

///|
/// `robot/send` payload (robot webhook uses markdown, app uses text).
pub fn dingtalk_send_payload(
  content : String,
  title : String,
  use_markdown : Bool,
) -> Json {
  if use_markdown {
    json_obj([
      ("msgtype", Json::string("markdown")),
      (
        "markdown",
        json_obj([
          ("title", Json::string(title)),
          ("text", Json::string(content)),
        ]),
      ),
    ])
  } else {
    json_obj([
      ("msgtype", Json::string("text")),
      ("text", json_obj([("content", Json::string(content))])),
    ])
  }
}

///|
/// One cached app access token with its absolute expiry (epoch ms).
pub(all) struct DingtalkToken {
  token : String
  expires_at : Int64
} derive(Debug)

///|
/// Cached app access tokens keyed by app key.
let dingtalk_token_cache : Map[String, DingtalkToken] = Map([])

///|
/// Renew app tokens one minute before DingTalk expires them (7200 s TTL by
/// default; the official connector refreshes with the same margin).
let dingtalk_token_refresh_margin_ms : Int64 = 60_000L

///|
/// Fetch (and cache) an app-robot access token, honouring `expireIn`.
pub async fn dingtalk_access_token(cfg : PlatformConfig) -> String? {
  let key = match dingtalk_app_key(cfg) {
    Some(k) => k
    None => return None
  }
  let secret = match dingtalk_app_secret(cfg) {
    Some(s) => s
    None => return None
  }
  let now = now_ms()
  match dingtalk_token_cache.get(key) {
    Some(cached) =>
      if cached.expires_at > now + dingtalk_token_refresh_margin_ms {
        return Some(cached.token)
      }
    None => ()
  }
  let api_base = cfg.extra_str("api_base", "https://api.dingtalk.com")
  let url = "\{api_base}/v1.0/oauth2/accessToken"
  let body = json_obj([
    ("appKey", Json::string(key)),
    ("appSecret", Json::string(secret)),
  ])
  match post_json(url, body, json_headers()) {
    Err(_) => None
    Ok(j) =>
      match json_field_string(j, "accessToken") {
        Some(t) => {
          let ttl_ms = match json_field_int(j, "expireIn") {
            Some(secs) => secs.to_int64() * 1000L
            None => 7200_000L
          }
          dingtalk_token_cache.set(key, {
            token: t,
            expires_at: now_ms() + ttl_ms,
          })
          Some(t)
        }
        None => None
      }
  }
}

///|
/// Reply state remembered from the last inbound message of a chat: the
/// `sessionWebhook` (Hermes `_session_webhooks`), its expiry, the sender to
/// `@` back and whether the chat is a group.
pub(all) struct DingtalkChatSession {
  webhook : String
  expires_at : Int64
  sender_id : String
  group : Bool
} derive(Debug)

///|
/// Per-chat session webhooks, capped like Hermes (`_SESSION_WEBHOOKS_MAX`).
let dingtalk_chat_sessions : Map[String, DingtalkChatSession] = Map([])

///|
let dingtalk_chat_sessions_max : Int32 = 500

///|
/// Stop using a webhook five minutes before it expires (Hermes' margin).
let dingtalk_session_webhook_margin_ms : Int64 = 5 * 60 * 1000L

///|
/// Whether ``url`` is a DingTalk session webhook (Hermes `_DINGTALK_WEBHOOK_RE`).
pub fn dingtalk_session_webhook_url(url : String) -> Bool {
  url.has_prefix("https://api.dingtalk.com/") ||
  url.has_prefix("https://oapi.dingtalk.com/")
}

///|
/// Remember a chat's session webhook for later replies.
pub fn dingtalk_remember_session(
  chat_id : String,
  webhook : String,
  expires_at : Int64,
  sender_id : String,
  group : Bool,
) -> Unit {
  if chat_id.is_empty() || webhook.is_empty() {
    return
  }
  if dingtalk_chat_sessions.length() >= dingtalk_chat_sessions_max {
    dingtalk_chat_sessions.clear()
  }
  dingtalk_chat_sessions.set(chat_id, { webhook, expires_at, sender_id, group, })
}

///|
/// The chat's still-valid session webhook, if any. Expired entries (known
/// expiry inside the 5-minute margin) are dropped.
pub fn dingtalk_chat_session(chat_id : String) -> DingtalkChatSession? {
  match dingtalk_chat_sessions.get(chat_id) {
    None => None
    Some(s) =>
      if s.expires_at > 0L &&
        now_ms() + dingtalk_session_webhook_margin_ms >= s.expires_at {
        dingtalk_chat_sessions.remove(chat_id)
        None
      } else {
        Some(s)
      }
  }
}

///|
/// Map a DingTalk `{errcode, errmsg}` response onto a `SendResult`.
fn dingtalk_robot_result(j : Json) -> SendResult {
  match json_field_int(j, "errcode") {
    Some(0) => send_ok(None, j)
    Some(code) => {
      let msg = json_field_string(j, "errmsg").unwrap_or(j.stringify())
      SendResult::failed(
        "dingtalk: \{msg} (code \{code})",
        kind=classify_send_error(msg),
        raw=j.stringify(),
      )
    }
    None => send_ok(None, j)
  }
}

///|
/// Send ``content``. The freshest inbound `sessionWebhook` wins (works for
/// DMs and groups, no app credentials needed); otherwise the app-robot API is
/// used when app credentials are present, else the group robot webhook.
pub async fn dingtalk_send(
  cfg : PlatformConfig,
  chat_id : String,
  content : String,
  reply_to? : String,
) -> SendResult {
  let title = cfg.extra_str("title", "Message")
  if content.is_empty() {
    return SendResult::ok()
  }
  // Preferred path: reply through the cached `sessionWebhook` (or an explicit
  // `reply_to` that is one). This keeps group chats working and can `@` the
  // sender back.
  let session = match dingtalk_chat_session(chat_id) {
    Some(s) => Some(s)
    None =>
      match reply_to {
        Some(r) =>
          if dingtalk_session_webhook_url(r) {
            Some(DingtalkChatSession::{
              webhook: r,
              expires_at: 0L,
              sender_id: "",
              group: false,
            })
          } else {
            None
          }
        None => None
      }
  }
  match session {
    Some(s) => {
      let r = dingtalk_session_send(s, content, title)
      if r.success {
        return r
      }
      log_line(
        "[imrelay] dingtalk: session webhook reply failed (\{r.error.unwrap_or("unknown")}); falling back to the app API",
      )
    }
    None => ()
  }
  if cfg.extra_bool("use_webhook", false) || dingtalk_app_key(cfg) is None {
    return dingtalk_send_webhook(cfg, content, title)
  }
  match dingtalk_access_token(cfg) {
    None =>
      missing_config(Dingtalk, "DINGTALK_CLIENT_ID / DINGTALK_CLIENT_SECRET")
    Some(token) => {
      let api_base = cfg.extra_str("api_base", "https://api.dingtalk.com")
      let url = "\{api_base}/v1.0/robot/oToMessages/batchSend"
      let headers = json_headers()
      headers.set("x-acs-dingtalk-access-token", token)
      let mut last = SendResult::ok()
      for chunk in chunk_text(content, Platform::max_message_length(Dingtalk)) {
        let msg_param = json_obj([
          ("title", Json::string(title)),
          ("text", Json::string(chunk)),
        ])
        let body = json_obj([
          ("robotCode", Json::string(dingtalk_robot_code(cfg).unwrap_or(""))),
          ("userIds", Json::array([Json::string(chat_id)])),
          ("msgKey", Json::string("sampleMarkdown")),
          ("msgParam", Json::string(msg_param.stringify())),
        ])
        let r = send_with_retry(() => {
          match post_json(url, body, headers) {
            Err(e) => send_failure("dingtalk", e)
            Ok(j) =>
              match json_field_string(j, "message") {
                Some(m) =>
                  if json_field_string(j, "processQueryKey") is None {
                    SendResult::failed(
                      "dingtalk: \{m}",
                      kind=classify_send_error(m),
                    )
                  } else {
                    send_ok(json_field_string(j, "processQueryKey"), j)
                  }
                None => send_ok(json_field_string(j, "processQueryKey"), j)
              }
          }
        })
        if !r.success {
          return r
        }
        last = r
      }
      last
    }
  }
}

///|
/// Send through a static group-robot webhook (`webhook_url` when configured,
/// else `webhook_base` + `access_token`).
pub async fn dingtalk_send_webhook(
  cfg : PlatformConfig,
  content : String,
  title : String,
) -> SendResult {
  let url = match cfg.extra_first(["webhook_url"]) {
    Some(u) => Some(u)
    None =>
      match dingtalk_robot_token(cfg) {
        None => None
        Some(token) => {
          let base = cfg.extra_str("webhook_base", "https://oapi.dingtalk.com")
          Some("\{base}/robot/send?access_token=\{url_quote(token)}")
        }
      }
  }
  let url = match url {
    None =>
      return missing_config(
        Dingtalk,
        "DINGTALK_WEBHOOK_URL / DINGTALK_ACCESS_TOKEN",
      )
    Some(u) => u
  }
  let markdown = cfg.extra_bool("markdown", true)
  let mut last = SendResult::ok()
  for chunk in chunk_text(content, Platform::max_message_length(Dingtalk)) {
    let r = send_with_retry(() => {
      match
        post_json(
          url,
          dingtalk_send_payload(chunk, title, markdown),
          json_headers(),
        ) {
        Err(e) => send_failure("dingtalk webhook", e)
        Ok(j) => dingtalk_robot_result(j)
      }
    })
    if !r.success {
      return r
    }
    last = r
  }
  last
}

///|
/// Session-webhook payload: markdown, plus the `at` block DingTalk needs to
/// notify the mentioned user.
pub fn dingtalk_session_payload(
  content : String,
  title : String,
  at_user_id : String?,
) -> Json {
  let fields : Array[(String, Json)] = [
    ("msgtype", Json::string("markdown")),
    (
      "markdown",
      json_obj([("title", Json::string(title)), ("text", Json::string(content))]),
    ),
  ]
  match at_user_id {
    Some(u) =>
      if !u.is_empty() {
        fields.push(
          (
            "at",
            json_obj([
              ("atUserIds", Json::array([Json::string(u)])),
              ("isAtAll", Json::boolean(false)),
            ]),
          ),
        )
      }
    None => ()
  }
  json_obj(fields)
}

///|
/// Reply through a chat's cached session webhook, chunked; the final chunk
/// `@`s the sender back in group chats (DingTalk only notifies on `@`).
async fn dingtalk_session_send(
  session : DingtalkChatSession,
  content : String,
  title : String,
) -> SendResult {
  let chunks = chunk_text(content, Platform::max_message_length(Dingtalk))
  let mut last = SendResult::ok()
  for i, chunk in chunks {
    let mention = if session.group &&
      !session.sender_id.is_empty() &&
      i == chunks.length() - 1 {
      Some(session.sender_id)
    } else {
      None
    }
    let r = send_with_retry(() => {
      dingtalk_session_reply(
        session.webhook,
        chunk,
        title~,
        at_user_id?=mention,
      )
    })
    if !r.success {
      return r
    }
    last = r
  }
  last
}

///|
/// Post to a fresh `sessionWebhook` (used to reply to an inbound callback).
pub async fn dingtalk_session_reply(
  session_webhook : String,
  content : String,
  title? : String,
  at_user_id? : String,
) -> SendResult {
  let mut text = content
  let mut at : String? = None
  match at_user_id {
    Some(u) =>
      if !u.is_empty() {
        text = "\{text} @\{u}"
        at = Some(u)
      }
    None => ()
  }
  let payload = dingtalk_session_payload(text, title.unwrap_or("Message"), at)
  match post_json(session_webhook, payload, json_headers()) {
    Err(e) => send_failure("dingtalk session", e)
    Ok(j) => dingtalk_robot_result(j)
  }
}

///|
/// Split `mention_patterns` (a JSON string array, or a comma-separated list).
fn dingtalk_mention_patterns(raw : String) -> Array[String] {
  if raw.is_empty() {
    return []
  }
  let j = @json.parse(raw) catch { _ => return split_list(raw) }
  match j {
    Array(items) => {
      let out : Array[String] = []
      for item in items {
        match item {
          String(s) => if !s.is_empty() { out.push(s) }
          _ => ()
        }
      }
      out
    }
    _ => split_list(raw)
  }
}

///|
/// Group trigger rules (Hermes `_should_process_message`): DMs always pass;
/// groups pass when `require_mention` is off (the default), the chat is in
/// `free_response_chats`, the bot was `@`-mentioned (`isInAtList`), or the
/// text matches a `mention_patterns` entry (case-insensitive substring).
pub fn dingtalk_group_should_process(
  cfg : PlatformConfig,
  chat_id : String,
  text : String,
  is_in_at_list : Bool,
) -> Bool {
  if !cfg.extra_bool("require_mention", false) {
    return true
  }
  for c in split_list(cfg.extra_str("free_response_chats", "")) {
    if c == chat_id {
      return true
    }
  }
  if is_in_at_list {
    return true
  }
  let lower = text.to_lower()
  for p in dingtalk_mention_patterns(cfg.extra_str("mention_patterns", "")) {
    if !p.is_empty() && lower.contains(p.to_lower()) {
      return true
    }
  }
  false
}

///|
/// Parse a DingTalk robot callback body into a `MessageEvent`. The
/// `sessionWebhook` is remembered for replies and preserved in `reply_to_text`
/// so the caller can answer without a separate token. Pass ``cfg`` to apply
/// the group `require_mention` / `free_response_chats` / `mention_patterns`
/// gates (stream and webhook inbound do).
pub fn dingtalk_parse_callback(
  body : String,
  cfg? : PlatformConfig,
) -> Array[MessageEvent] {
  let out : Array[MessageEvent] = []
  let j = @json.parse(body) catch { _ => return out }
  let chat_id = or_opt(
    json_field_string(j, "conversationId"),
    json_field_string(j, "senderId"),
  ).unwrap_or("")
  if chat_id.is_empty() {
    return out
  }
  let msgtype = json_field_string(j, "msgtype").unwrap_or("")
  let text = match msgtype {
    "markdown" =>
      match json_field_obj(j, "markdown") {
        Some(m) => json_field_string(m, "text").unwrap_or("")
        None => ""
      }
    _ =>
      match json_field_obj(j, "text") {
        Some(t) => json_field_string(t, "content").unwrap_or("")
        None => ""
      }
  }
  let is_group = json_field_string(j, "conversationType") == Some("2") ||
    json_field_string(j, "openConversationId") is Some(_)
  let sender_id = or_opt(
    json_field_string(j, "senderId"),
    json_field_string(j, "senderStaffId"),
  ).unwrap_or("")
  // Remember the reply webhook for this chat (Hermes `_session_webhooks`).
  match json_field_string(j, "sessionWebhook") {
    Some(w) =>
      if dingtalk_session_webhook_url(w) {
        dingtalk_remember_session(
          chat_id,
          w,
          json_field_int64(j, "sessionWebhookExpiredTime").unwrap_or(0L),
          or_opt(
            json_field_string(j, "senderStaffId"),
            json_field_string(j, "senderId"),
          ).unwrap_or(""),
          is_group,
        )
      }
    None => ()
  }
  // Group trigger rules, when the caller supplied the platform config.
  match cfg {
    Some(c) =>
      if is_group &&
        !dingtalk_group_should_process(
          c,
          chat_id,
          text,
          json_field_bool(j, "isInAtList").unwrap_or(false),
        ) {
        return out
      }
    None => ()
  }
  let mtype = if text.has_prefix("/") {
    Command
  } else {
    dingtalk_message_type(j)
  }
  out.push(
    MessageEvent::new(
      text,
      mtype,
      Dingtalk,
      chat_id,
      user_id?=if sender_id.is_empty() { None } else { Some(sender_id) },
      user_name?=json_field_string(j, "senderNick"),
      message_id?=json_field_string(j, "msgId"),
      reply_to_text?=json_field_string(j, "sessionWebhook"),
      media=[],
      timestamp=now_ms(),
    ),
  )
  out
}

// --- Inbound media ---------------------------------------------------------
//
// DingTalk robot messages carry media as `downloadCode`s (Hermes
// `extract_media` / `collect_download_codes`); each resolves to a
// short-lived URL through `POST /v1.0/robot/messageFiles/download` with the
// robot code. Voice notes are skipped like Hermes — their `recognition`
// text carries the payload — and the resolution is best-effort per code.

///|
/// `(downloadCode, kind)` media references of one callback body, kinds in
/// `MediaAttachment` vocabulary (`photo`/`video`/`voice`/`document`).
pub fn dingtalk_media_refs(body : String) -> Array[(String, String)] {
  let j = @json.parse(body) catch { _ => return [] }
  dingtalk_media_refs_of(j)
}

///|
fn dingtalk_push_media_ref(
  out : Array[(String, String)],
  code : String,
  kind : String,
) -> Unit {
  if code.is_empty() {
    return
  }
  for kv in out {
    if kv.0 == code {
      return
    }
  }
  out.push((code, kind))
}

///|
fn dingtalk_media_refs_of(j : Json) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  let content = json_field_obj(j, "content").unwrap_or(Json::null())
  match json_field_string(j, "msgtype").unwrap_or("") {
    "picture" | "image" =>
      dingtalk_push_media_ref(
        out,
        json_field_string(content, "downloadCode").unwrap_or(""),
        "photo",
      )
    "video" =>
      dingtalk_push_media_ref(
        out,
        json_field_string(content, "downloadCode").unwrap_or(""),
        "video",
      )
    "file" =>
      dingtalk_push_media_ref(
        out,
        json_field_string(content, "downloadCode").unwrap_or(""),
        "document",
      )
    "richText" =>
      for part in json_field_array(content, "richText").unwrap_or([]) {
        let code = or_opt(
          json_field_string(part, "downloadCode"),
          json_field_string(part, "pictureDownloadCode"),
        ).unwrap_or("")
        let kind = match json_field_string(part, "type").unwrap_or("") {
          "video" => "video"
          "voice" => "voice"
          "file" => "document"
          _ => "photo"
        }
        dingtalk_push_media_ref(out, code, kind)
      }
    _ => ()
  }
  out
}

///|
/// `MessageType` promoted from a callback's `msgtype` (Hermes
/// `extract_media`): picture/image → `Photo`, video → `Video`, the audio
/// voice note → `Voice`, file → `Document`; rich text takes the kind of its
/// first media part, everything else stays `Text`.
fn dingtalk_message_type(j : Json) -> MessageType {
  match json_field_string(j, "msgtype").unwrap_or("") {
    "picture" | "image" => Photo
    "video" => Video
    "audio" => Voice
    "file" => Document
    "richText" => {
      let refs = dingtalk_media_refs_of(j)
      if refs.is_empty() {
        Text
      } else {
        match refs[0].1 {
          "video" => Video
          "voice" => Voice
          "document" => Document
          _ => Photo
        }
      }
    }
    _ => Text
  }
}

///|
/// Resolve one `downloadCode` to a temporary download URL through
/// `POST /v1.0/robot/messageFiles/download`. `None` without app credentials
/// or robot code, or when DingTalk answers without a `downloadUrl`.
pub async fn dingtalk_download_url(
  cfg : PlatformConfig,
  code : String,
) -> String? {
  let robot = match dingtalk_robot_code(cfg) {
    Some(r) => r
    None => return None
  }
  let token = match dingtalk_access_token(cfg) {
    Some(t) => t
    None => return None
  }
  let api_base = cfg.extra_str("api_base", "https://api.dingtalk.com")
  let url = "\{api_base}/v1.0/robot/messageFiles/download"
  let headers = json_headers()
  headers.set("x-acs-dingtalk-access-token", token)
  let payload = json_obj([
    ("downloadCode", Json::string(code)),
    ("robotCode", Json::string(robot)),
  ])
  match post_json(url, payload, headers) {
    Err(_) => None
    Ok(j) => json_field_string(j, "downloadUrl")
  }
}

///|
/// Resolve every media reference of a callback body into `MediaAttachment`s;
/// individual failures are skipped so one bad code cannot drop the message.
pub async fn dingtalk_resolve_media(
  cfg : PlatformConfig,
  body : String,
) -> Array[MediaAttachment] {
  let out : Array[MediaAttachment] = []
  for kv in dingtalk_media_refs(body) {
    match dingtalk_download_url(cfg, kv.0) {
      Some(url) => out.push({ url, kind: kv.1, })
      None => ()
    }
  }
  out
}

///|
/// Parse a DingTalk callback and attach resolved media URLs (one extra API
/// call per media-carrying message; no call when the message has no media).
pub async fn dingtalk_parse_callback_with_media(
  cfg : PlatformConfig,
  body : String,
) -> Array[MessageEvent] {
  let events = dingtalk_parse_callback(body, cfg~)
  if events.is_empty() {
    return events
  }
  let media = dingtalk_resolve_media(cfg, body)
  if media.is_empty() {
    return events
  }
  let out : Array[MessageEvent] = []
  for ev in events {
    out.push(
      MessageEvent::new(
        ev.text,
        ev.message_type,
        ev.platform,
        ev.chat_id,
        user_id?=ev.user_id,
        user_name?=ev.user_name,
        message_id?=ev.message_id,
        reply_to_message_id?=ev.reply_to_message_id,
        reply_to_text?=ev.reply_to_text,
        media~,
        timestamp=ev.timestamp,
      ),
    )
  }
  out
}

// --- Stream Mode ----------------------------------------------------------
//
// DingTalk's recommended transport: a WebSocket long-connection to
// `POST /v1.0/gateway/connections/open` (clientId/clientSecret + CALLBACK
// subscription) returning `{endpoint, ticket}`. Downstream frames are
// `{type: SYSTEM|CALLBACK, headers: {messageId, topic}, data}`; CALLBACK data
// is the same robot-message JSON as the HTTP callback, and the frame must be
// acked within 60 s or the server redelivers it.

///|
/// Robot-message topic subscribed on the stream.
pub let dingtalk_stream_robot_topic : String = "/v1.0/im/bot/messages/get"

///|
/// Whether Stream Mode should connect: app credentials present and
/// `stream = false` (extra) not set.
pub fn dingtalk_stream_enabled(cfg : PlatformConfig) -> Bool {
  if !cfg.extra_bool("stream", true) {
    return false
  }
  dingtalk_app_key(cfg) is Some(_) && dingtalk_app_secret(cfg) is Some(_)
}

///|
/// Body of the `connections/open` request.
pub fn dingtalk_stream_open_payload(cfg : PlatformConfig) -> Json {
  json_obj([
    ("clientId", Json::string(dingtalk_app_key(cfg).unwrap_or(""))),
    ("clientSecret", Json::string(dingtalk_app_secret(cfg).unwrap_or(""))),
    ("ua", Json::string("imrelay")),
    (
      "subscriptions",
      Json::array([
        json_obj([
          ("type", Json::string("CALLBACK")),
          ("topic", Json::string(dingtalk_stream_robot_topic)),
        ]),
      ]),
    ),
  ])
}

///|
/// Open a stream connection: `(endpoint, ticket)` on success.
pub async fn dingtalk_stream_open(
  cfg : PlatformConfig,
) -> Result[(String, String), ApiError] {
  let api_base = cfg.extra_str("api_base", "https://api.dingtalk.com")
  let headers = json_headers()
  headers.set("accept", "application/json")
  match
    post_json(
      "\{api_base}/v1.0/gateway/connections/open",
      dingtalk_stream_open_payload(cfg),
      headers,
    ) {
    Err(e) => Err(e)
    Ok(j) =>
      match (json_field_string(j, "endpoint"), json_field_string(j, "ticket")) {
        (Some(endpoint), Some(ticket)) =>
          if endpoint.is_empty() || ticket.is_empty() {
            Err({ code: -1, body: "stream open: endpoint/ticket missing", })
          } else {
            Ok((endpoint, ticket))
          }
        _ => Err({ code: -1, body: "stream open: endpoint/ticket missing", })
      }
  }
}

///|
/// One parsed downstream frame.
pub(all) struct DingtalkStreamFrame {
  kind : String // SYSTEM | CALLBACK | EVENT
  topic : String
  message_id : String
  headers : Json
  data : Json
} derive(Debug)

///|
/// Parse a downstream stream frame.
pub fn dingtalk_stream_frame(raw : String) -> DingtalkStreamFrame? {
  let j = @json.parse(raw) catch { _ => return None }
  match j {
    Object(_) => ()
    _ => return None
  }
  let headers = json_field_obj(j, "headers").unwrap_or(json_obj([]))
  let data = match j {
    Object(m) => m.get("data").unwrap_or(Json::null())
    _ => Json::null()
  }
  Some({
    kind: json_field_string(j, "type").unwrap_or(""),
    topic: json_field_string(headers, "topic").unwrap_or(""),
    message_id: json_field_string(headers, "messageId").unwrap_or(""),
    headers,
    data,
  })
}

///|
/// Ack a `CALLBACK` frame (stops the server's 60-second retry).
pub fn dingtalk_stream_callback_ack(message_id : String) -> Json {
  json_obj([
    ("code", Json::number(200.0)),
    (
      "headers",
      json_obj([
        ("contentType", Json::string("application/json")),
        ("messageId", Json::string(message_id)),
      ]),
    ),
    ("message", Json::string("OK")),
    ("data", Json::string("{\"status\":\"SUCCESS\"}")),
  ])
}

///|
/// Echo reply for `SYSTEM` frames (`ping` / `disconnect`): the server expects
/// its own headers and data back.
pub fn dingtalk_stream_echo_reply(headers : Json, data : Json) -> Json {
  json_obj([
    ("code", Json::number(200.0)),
    ("headers", headers),
    ("message", Json::string("OK")),
    ("data", data),
  ])
}

///|
/// Frame ids seen recently (the server redelivers unacked callbacks).
let dingtalk_stream_seen : Map[String, Int64] = Map([])

///|
/// `true` when this frame id was already handled within five minutes.
pub fn dingtalk_stream_duplicate(message_id : String) -> Bool {
  if message_id.is_empty() {
    return false
  }
  let now = now_ms()
  if dingtalk_stream_seen.length() > 1000 {
    let stale : Array[String] = []
    for k, t in dingtalk_stream_seen {
      if now - t > 300_000L {
        stale.push(k)
      }
    }
    for k in stale {
      dingtalk_stream_seen.remove(k)
    }
  }
  match dingtalk_stream_seen.get(message_id) {
    Some(_) => true
    None => {
      dingtalk_stream_seen.set(message_id, now)
      false
    }
  }
}
