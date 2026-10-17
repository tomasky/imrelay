// Telegram Bot API adapter.
//
// Mirrors Hermes `plugins/platforms/telegram/adapter.py`: text sends use
// `sendMessage` (chunked at 4096 chars), sends retry once on rate limits, and
// a markdown send that fails with a formatting error falls back to plain text.
// Inbound updates arrive either through the webhook or through `getUpdates`
// long polling.

///|
/// Bot API root, e.g. `https://api.telegram.org/bot<token>`.
pub fn telegram_api_base(cfg : PlatformConfig, token : String) -> String {
  let base = cfg.extra_str("api_base", "https://api.telegram.org")
  let trimmed = if base.has_suffix("/") {
    base[:base.length() - 1].to_owned()
  } else {
    base
  }
  "\{trimmed}/bot\{token}"
}

///|
/// Parse mode to request, from `[telegram.extra] parse_mode`.
/// `""` (default) sends plain text; `MarkdownV2`/`HTML` opt in.
pub fn telegram_parse_mode(cfg : PlatformConfig) -> String? {
  let pm = cfg.extra_str("parse_mode", "")
  if pm.is_empty() {
    None
  } else {
    Some(pm)
  }
}

///|
/// `sendMessage` payload.
pub fn telegram_send_payload(
  chat_id : String,
  text : String,
  reply_to : String?,
  thread_id : String?,
  parse_mode : String?,
) -> Json {
  let payload = json_obj([
    ("chat_id", Json::string(chat_id)),
    ("text", Json::string(text)),
  ])
  let payload = obj_with_opt(payload, "parse_mode", parse_mode)
  let payload = obj_with_opt(payload, "reply_to_message_id", reply_to)
  obj_with_opt(payload, "message_thread_id", thread_id)
}

///|
/// `sendChatAction` payload.
pub fn telegram_typing_payload(chat_id : String, thread_id : String?) -> Json {
  let payload = json_obj([
    ("chat_id", Json::string(chat_id)),
    ("action", Json::string("typing")),
  ])
  obj_with_opt(payload, "message_thread_id", thread_id)
}

///|
/// `send<Kind>` payload for media by URL.
pub fn telegram_media_payload(
  chat_id : String,
  kind : String,
  url : String,
  caption : String?,
  parse_mode : String?,
) -> Json {
  let field = match kind {
    "photo" | "image" => "photo"
    "video" => "video"
    "audio" => "audio"
    "voice" => "voice"
    "document" | "file" => "document"
    "sticker" => "sticker"
    _ => "document"
  }
  let payload = json_obj([
    ("chat_id", Json::string(chat_id)),
    (field, Json::string(url)),
  ])
  let payload = obj_with_opt(payload, "caption", caption)
  obj_with_opt(payload, "parse_mode", parse_mode)
}

///|
/// Telegram method name for a media kind (`sendPhoto`, `sendDocument`, ...).
pub fn telegram_media_method(kind : String) -> String {
  let field = match kind {
    "photo" | "image" => "photo"
    "video" => "video"
    "audio" => "audio"
    "voice" => "voice"
    "document" | "file" => "document"
    "sticker" => "sticker"
    _ => "document"
  }
  "send\{field[:1].to_owned().to_upper()}\{field[1:].to_owned()}"
}

///|
/// Message id from a `{"ok":true,"result":{"message_id":N}}` response.
fn telegram_result_id(j : Json) -> String? {
  match json_field_obj(j, "result") {
    Some(r) => json_id(r, "message_id")
    None => json_id(j, "message_id")
  }
}

///|
/// Human-readable error from a Telegram error response
/// (`{"ok":false,"description":"…","error_code":429,"parameters":{"retry_after":n}}`).
fn telegram_error(j : Json) -> (String, Double?) {
  let desc = json_field_string(j, "description").unwrap_or(j.stringify())
  let retry_after = match json_field_obj(j, "parameters") {
    Some(p) =>
      match p {
        Object(m) =>
          match m.get("retry_after") {
            Some(Number(n, ..)) => Some(n)
            _ => None
          }
        _ => None
      }
    None => None
  }
  (desc, retry_after)
}

///|
/// Call a Bot API method and map the response onto a `SendResult`.
async fn telegram_call(
  cfg : PlatformConfig,
  token : String,
  api_method : String,
  payload : Json,
) -> SendResult {
  let url = "\{telegram_api_base(cfg, token)}/\{api_method}"
  match post_json(url, payload, json_headers()) {
    Err(e) => send_failure("telegram \{api_method}", e)
    Ok(j) =>
      if json_field_bool(j, "ok").unwrap_or(false) {
        send_ok(telegram_result_id(j), j)
      } else {
        let (desc, retry_after) = telegram_error(j)
        SendResult::failed(
          "telegram \{api_method}: \{desc}",
          retryable=classify_send_error(desc) == RateLimited ||
            classify_send_error(desc) == Transient,
          retry_after?,
          kind=classify_send_error(desc),
          raw=j.stringify(),
        )
      }
  }
}

///|
/// Send one chunk with an optional parse mode, falling back to plain text when
/// Telegram rejects the formatting (Hermes `_send_chunk_markdown_or_plain`).
async fn telegram_send_chunk(
  cfg : PlatformConfig,
  token : String,
  chat_id : String,
  text : String,
  reply_to : String?,
  thread_id : String?,
) -> SendResult {
  let parse_mode = telegram_parse_mode(cfg)
  send_with_retry(() => {
    let payload = telegram_send_payload(
      chat_id, text, reply_to, thread_id, parse_mode,
    )
    let r = telegram_call(cfg, token, "sendMessage", payload)
    if r.success {
      return r
    }
    match parse_mode {
      Some(_) =>
        if r.error_kind == Some(BadFormat) || r.error_kind == Some(TooLong) {
          let plain = telegram_send_payload(
            chat_id,
            text,
            reply_to,
            thread_id,
            None,
          )
          telegram_call(cfg, token, "sendMessage", plain)
        } else {
          r
        }
      None => r
    }
  })
}

///|
/// Send ``content`` to ``chat_id``, chunked at the platform limit. Only the
/// first chunk replies to ``reply_to``; every chunk stays in ``thread_id``.
pub async fn telegram_send(
  cfg : PlatformConfig,
  chat_id : String,
  content : String,
  reply_to? : String,
  thread_id? : String,
) -> SendResult {
  match cfg.token_of() {
    None => missing_config(Telegram, "TELEGRAM_BOT_TOKEN")
    Some(token) =>
      if content.is_empty() {
        return SendResult::ok()
      } else {
        let mut first = true
        let mut last = SendResult::ok()
        let mut first_id : String? = None
        for chunk in chunk_text(content, Platform::max_message_length(Telegram)) {
          let reply = if first { reply_to } else { None }
          let r = telegram_send_chunk(
            cfg, token, chat_id, chunk, reply, thread_id,
          )
          first = false
          if !r.success {
            return r
          }
          if first_id is None {
            first_id = r.message_id
          }
          last = r
        }
        { ..last, message_id: first_id, }
      }
  }
}

///|
/// Typing indicator (`sendChatAction`), errors are ignored.
pub async fn telegram_typing(
  cfg : PlatformConfig,
  chat_id : String,
  thread_id? : String,
) -> Unit {
  match cfg.token_of() {
    None => ()
    Some(token) =>
      ignore(
        telegram_call(
          cfg,
          token,
          "sendChatAction",
          telegram_typing_payload(chat_id, thread_id),
        ),
      )
  }
}

///|
/// Send a media URL with an optional caption.
pub async fn telegram_send_media(
  cfg : PlatformConfig,
  chat_id : String,
  kind : String,
  url : String,
  caption? : String,
  reply_to? : String,
) -> SendResult {
  match cfg.token_of() {
    None => missing_config(Telegram, "TELEGRAM_BOT_TOKEN")
    Some(token) =>
      send_with_retry(() => {
        let payload = obj_with_opt(
          telegram_media_payload(
            chat_id,
            kind,
            url,
            caption,
            telegram_parse_mode(cfg),
          ),
          "reply_to_message_id",
          reply_to,
        )
        telegram_call(cfg, token, telegram_media_method(kind), payload)
      })
  }
}

///|
/// Edit a previously sent message.
pub async fn telegram_edit(
  cfg : PlatformConfig,
  chat_id : String,
  message_id : String,
  text : String,
) -> SendResult {
  match cfg.token_of() {
    None => missing_config(Telegram, "TELEGRAM_BOT_TOKEN")
    Some(token) => {
      let payload = json_obj([
        ("chat_id", Json::string(chat_id)),
        ("message_id", Json::string(message_id)),
        ("text", Json::string(text)),
      ])
      telegram_call(
        cfg,
        token,
        "editMessageText",
        obj_with_opt(payload, "parse_mode", telegram_parse_mode(cfg)),
      )
    }
  }
}

///|
/// Delete a message.
pub async fn telegram_delete(
  cfg : PlatformConfig,
  chat_id : String,
  message_id : String,
) -> SendResult {
  match cfg.token_of() {
    None => missing_config(Telegram, "TELEGRAM_BOT_TOKEN")
    Some(token) => {
      let payload = json_obj([
        ("chat_id", Json::string(chat_id)),
        ("message_id", Json::string(message_id)),
      ])
      telegram_call(cfg, token, "deleteMessage", payload)
    }
  }
}

///|
/// React to a message with an emoji (Bot API 7.0 `setMessageReaction`).
pub async fn telegram_react(
  cfg : PlatformConfig,
  chat_id : String,
  message_id : String,
  emoji : String,
) -> SendResult {
  match cfg.token_of() {
    None => missing_config(Telegram, "TELEGRAM_BOT_TOKEN")
    Some(token) => {
      let reaction = Json::array([
        json_obj([
          ("type", Json::string("emoji")),
          ("emoji", Json::string(emoji)),
        ]),
      ])
      let payload = json_obj([
        ("chat_id", Json::string(chat_id)),
        ("message_id", Json::string(message_id)),
        ("reaction", reaction),
      ])
      telegram_call(cfg, token, "setMessageReaction", payload)
    }
  }
}

///|
/// Chat metadata via `getChat`.
pub async fn telegram_get_chat(
  cfg : PlatformConfig,
  chat_id : String,
) -> ChatInfo? {
  match cfg.token_of() {
    None => None
    Some(token) => {
      let url = "\{telegram_api_base(cfg, token)}/getChat"
      let payload = json_obj([("chat_id", Json::string(chat_id))])
      match post_json(url, payload, json_headers()) {
        Err(_) => None
        Ok(j) =>
          match json_field_obj(j, "result") {
            Some(r) =>
              Some({
                name: or_opt(
                  or_opt(
                    json_field_string(r, "title"),
                    json_field_string(r, "username"),
                  ),
                  json_field_string(r, "first_name"),
                ).unwrap_or(chat_id),
                chat_type: json_field_string(r, "type").unwrap_or("private"),
                chat_id,
              })
            None => None
          }
      }
    }
  }
}

///|
/// Fetch updates (`getUpdates`) for long-polling transports, surfacing
/// transport/API failures so pollers can back off instead of hammering a
/// broken endpoint. ``offset`` acknowledges every earlier update.
pub async fn telegram_get_updates_result(
  cfg : PlatformConfig,
  token : String,
  offset : Int32,
  timeout_s : Int32,
) -> Result[Array[Json], ApiError] {
  let url = "\{telegram_api_base(cfg, token)}/getUpdates"
  let payload = json_obj([
    ("offset", Json::number(offset.to_double())),
    ("timeout", Json::number(timeout_s.to_double())),
    (
      "allowed_updates",
      Json::array([
        Json::string("message"),
        Json::string("edited_message"),
        Json::string("channel_post"),
        Json::string("callback_query"),
      ]),
    ),
  ])
  match post_json(url, payload, json_headers()) {
    Err(e) => Err(e)
    Ok(j) =>
      match json_field_array(j, "result") {
        Some(a) => Ok(a)
        None => Ok([])
      }
  }
}

///|
/// Fetch updates (`getUpdates`) for long-polling transports; failures are
/// reported as an empty batch (see `telegram_get_updates_result`).
pub async fn telegram_get_updates(
  cfg : PlatformConfig,
  token : String,
  offset : Int32,
  timeout_s : Int32,
) -> Array[Json] {
  match telegram_get_updates_result(cfg, token, offset, timeout_s) {
    Ok(a) => a
    Err(_) => []
  }
}

///|
/// Whether a Telegram webhook carries the configured
/// `X-Telegram-Bot-Api-Secret-Token` (constant-time; Telegram echoes the
/// `secret_token` passed to `setWebhook`).
pub fn telegram_webhook_authorized(
  expected : String,
  provided : String?,
) -> Bool {
  if expected.is_empty() {
    return false
  }
  match provided {
    Some(p) => constant_time_eq(expected, p)
    None => false
  }
}

///|
/// Register a webhook.
pub async fn telegram_set_webhook(
  cfg : PlatformConfig,
  token : String,
  url : String,
  secret_token? : String,
) -> SendResult {
  let api = "\{telegram_api_base(cfg, token)}/setWebhook"
  let payload = json_obj([
    ("url", Json::string(url)),
    (
      "allowed_updates",
      Json::array([
        Json::string("message"),
        Json::string("edited_message"),
        Json::string("channel_post"),
      ]),
    ),
  ])
  let payload = obj_with_opt(payload, "secret_token", secret_token)
  match post_json(api, payload, json_headers()) {
    Err(e) => send_failure("telegram setWebhook", e)
    Ok(j) =>
      if json_field_bool(j, "ok").unwrap_or(false) {
        SendResult::ok()
      } else {
        let (desc, _) = telegram_error(j)
        send_body_failure("telegram setWebhook", desc)
      }
  }
}

///|
/// Remove any registered webhook (required before long polling).
pub async fn telegram_delete_webhook(
  cfg : PlatformConfig,
  token : String,
) -> SendResult {
  let api = "\{telegram_api_base(cfg, token)}/deleteWebhook"
  let payload = json_obj([("drop_pending_updates", Json::boolean(false))])
  match post_json(api, payload, json_headers()) {
    Err(e) => send_failure("telegram deleteWebhook", e)
    Ok(_) => SendResult::ok()
  }
}

///|
/// Convert one Telegram `Message`/`ChannelPost` object into a `MessageEvent`.
pub fn telegram_parse_message(msg : Json) -> MessageEvent? {
  let chat = json_field_obj(msg, "chat")
  let chat_id = match chat {
    Some(c) => json_id(c, "id")
    None => None
  }
  match chat_id {
    None => None
    Some(chat_id) => {
      let from = json_field_obj(msg, "from")
      let user_id = match from {
        Some(f) => json_id(f, "id")
        None => None
      }
      let user_name = match from {
        Some(f) =>
          or_opt(
            json_field_string(f, "username"),
            json_field_string(f, "first_name"),
          )
        None => None
      }
      let text = or_opt(
        json_field_string(msg, "text"),
        json_field_string(msg, "caption"),
      ).unwrap_or("")
      let (mtype, media) = telegram_media_of(msg)
      let reply = json_field_obj(msg, "reply_to_message")
      let reply_id = match reply {
        Some(r) => json_id(r, "message_id")
        None => None
      }
      let reply_text = match reply {
        Some(r) => json_field_string(r, "text")
        None => None
      }
      let message_type = if text.has_prefix("/") { Command } else { mtype }
      Some(
        MessageEvent::new(
          text,
          message_type,
          Telegram,
          chat_id,
          user_id?,
          user_name?,
          message_id?=json_id(msg, "message_id"),
          reply_to_message_id?=reply_id,
          reply_to_text?=reply_text,
          media~,
          timestamp=json_field_int(msg, "date").unwrap_or(0).to_int64() * 1000L,
        ),
      )
    }
  }
}

///|
/// Classify the media carried by a Telegram message.
fn telegram_media_of(msg : Json) -> (MessageType, Array[MediaAttachment]) {
  let out : Array[MediaAttachment] = []
  if json_field_array(msg, "photo") is Some(photos) {
    if photos.length() > 0 {
      let best = photos[photos.length() - 1]
      match json_field_string(best, "file_id") {
        Some(fid) => out.push({ url: fid, kind: "photo", })
        None => ()
      }
    }
    return (Photo, out)
  }
  if json_field_obj(msg, "voice") is Some(v) {
    match json_field_string(v, "file_id") {
      Some(fid) => out.push({ url: fid, kind: "voice", })
      None => ()
    }
    return (Voice, out)
  }
  if json_field_obj(msg, "audio") is Some(a) {
    match json_field_string(a, "file_id") {
      Some(fid) => out.push({ url: fid, kind: "audio", })
      None => ()
    }
    return (Audio, out)
  }
  if json_field_obj(msg, "video") is Some(v) {
    match json_field_string(v, "file_id") {
      Some(fid) => out.push({ url: fid, kind: "video", })
      None => ()
    }
    return (Video, out)
  }
  if json_field_obj(msg, "document") is Some(d) {
    match json_field_string(d, "file_id") {
      Some(fid) => out.push({ url: fid, kind: "document", })
      None => ()
    }
    return (Document, out)
  }
  if json_field_obj(msg, "sticker") is Some(s) {
    match json_field_string(s, "file_id") {
      Some(fid) => out.push({ url: fid, kind: "sticker", })
      None => ()
    }
    return (Sticker, out)
  }
  if json_field_obj(msg, "location") is Some(_) {
    return (Location, out)
  }
  (Text, out)
}

///|
/// Parse a `{"update_id":N,"message":{…}}` webhook body into events.
pub fn telegram_parse_update(update : Json) -> Array[MessageEvent] {
  let out : Array[MessageEvent] = []
  for key in ["message", "edited_message", "channel_post"] {
    match json_field_obj(update, key) {
      Some(msg) =>
        match telegram_parse_message(msg) {
          Some(ev) => out.push(ev)
          None => ()
        }
      None => ()
    }
  }
  if json_field_obj(update, "callback_query") is Some(cb) {
    let from = json_field_obj(cb, "from")
    let user_id = match from {
      Some(f) => json_id(f, "id")
      None => None
    }
    let user_name = match from {
      Some(f) => json_field_string(f, "username")
      None => None
    }
    let chat_id = match json_field_obj(cb, "message") {
      Some(m) =>
        match json_field_obj(m, "chat") {
          Some(c) => json_id(c, "id")
          None => None
        }
      None => None
    }
    match chat_id {
      Some(chat_id) =>
        out.push(
          MessageEvent::new(
            json_field_string(cb, "data").unwrap_or(""),
            Command,
            Telegram,
            chat_id,
            user_id?,
            user_name?,
            message_id?=json_field_string(cb, "id"),
            media=[],
            timestamp=now_ms(),
          ),
        )
      None => ()
    }
  }
  out
}

///|
/// Parse a whole `getUpdates` result array.
pub fn telegram_parse_updates(updates : Array[Json]) -> Array[MessageEvent] {
  let out : Array[MessageEvent] = []
  for u in updates {
    for ev in telegram_parse_update(u) {
      out.push(ev)
    }
  }
  out
}
