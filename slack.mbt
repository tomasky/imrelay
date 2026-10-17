// Slack Web API adapter (`slack.com/api`).
//
// Mirrors Hermes `plugins/platforms/slack/adapter.py`: `chat.postMessage` for
// sends (39000-char chunks), `chat.update` for streaming edits, and the
// Events API for inbound traffic. Request signing uses the standard
// `v0=HMAC_SHA256(signing_secret, "v0:{ts}:{body}")` scheme.

///|
/// API root, overridable with `[slack.extra] api_base`.
pub fn slack_api_base(cfg : PlatformConfig) -> String {
  let base = cfg.extra_str("api_base", "https://slack.com/api")
  if base.has_suffix("/") {
    base[:base.length() - 1].to_owned()
  } else {
    base
  }
}

///|
/// `chat.postMessage` payload.
pub fn slack_send_payload(
  channel : String,
  text : String,
  thread_ts : String?,
) -> Json {
  let payload = json_obj([
    ("channel", Json::string(channel)),
    ("text", Json::string(text)),
  ])
  obj_with_opt(payload, "thread_ts", thread_ts)
}

///|
/// `chat.update` payload (used for streaming/draft edits).
pub fn slack_update_payload(
  channel : String,
  ts : String,
  text : String,
) -> Json {
  json_obj([
    ("channel", Json::string(channel)),
    ("ts", Json::string(ts)),
    ("text", Json::string(text)),
  ])
}

///|
/// Slack headers (`Authorization: Bearer`, JSON content type).
pub fn slack_headers(token : String) -> Map[String, String] {
  let m = json_headers()
  m.set("Content-Type", "application/json; charset=utf-8")
  m.set("Authorization", "Bearer \{token}")
  m
}

///|
/// Slack answers HTTP 200 with `{"ok":false,"error":"…"}` on failure.
fn slack_result(
  prefix : String,
  res : Result[Json, ApiError],
  id_key : String,
) -> SendResult {
  match res {
    Err(e) => send_failure(prefix, e)
    Ok(j) =>
      if json_field_bool(j, "ok").unwrap_or(false) {
        send_ok(json_field_string(j, id_key), j)
      } else {
        let err = json_field_string(j, "error").unwrap_or(j.stringify())
        SendResult::failed(
          "\{prefix}: \{err}",
          retryable=err == "ratelimited" ||
            classify_send_error(err) == RateLimited,
          kind=classify_send_error(err),
          raw=j.stringify(),
        )
      }
  }
}

///|
/// Call a Slack Web API method.
async fn slack_call(
  cfg : PlatformConfig,
  token : String,
  api_method : String,
  payload : Json,
  id_key : String,
) -> SendResult {
  let url = "\{slack_api_base(cfg)}/\{api_method}"
  slack_result(
    "slack \{api_method}",
    post_json(url, payload, slack_headers(token)),
    id_key,
  )
}

///|
/// Send ``content``, chunked at Slack's 39000-char limit, threaded on
/// ``thread_ts`` (defaults to ``reply_to``).
pub async fn slack_send(
  cfg : PlatformConfig,
  chat_id : String,
  content : String,
  reply_to? : String,
  thread_ts? : String,
) -> SendResult {
  match cfg.token_of() {
    None => missing_config(Slack, "SLACK_BOT_TOKEN")
    Some(token) =>
      if content.is_empty() {
        return SendResult::ok()
      } else {
        let thread = match thread_ts {
          Some(t) => Some(t)
          None => reply_to
        }
        let mut last = SendResult::ok()
        let mut first_id : String? = None
        for chunk in chunk_text(content, Platform::max_message_length(Slack)) {
          let r = send_with_retry(() => {
            slack_call(
              cfg,
              token,
              "chat.postMessage",
              slack_send_payload(chat_id, chunk, thread),
              "ts",
            )
          })
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
/// Slack has no typing indicator; we surface the assistant thread status
/// (`assistant.threads.setStatus`) and ignore failures.
pub async fn slack_typing(
  cfg : PlatformConfig,
  chat_id : String,
  thread_ts? : String,
) -> Unit {
  match cfg.token_of() {
    None => ()
    Some(token) =>
      match thread_ts {
        Some(ts) => {
          let payload = json_obj([
            ("channel_id", Json::string(chat_id)),
            ("thread_ts", Json::string(ts)),
            ("status", Json::string("is thinking…")),
          ])
          ignore(
            slack_call(cfg, token, "assistant.threads.setStatus", payload, "ok"),
          )
        }
        None => ()
      }
  }
}

///|
/// Update a previously sent message (`chat.update`).
pub async fn slack_edit(
  cfg : PlatformConfig,
  chat_id : String,
  message_id : String,
  content : String,
) -> SendResult {
  match cfg.token_of() {
    None => missing_config(Slack, "SLACK_BOT_TOKEN")
    Some(token) =>
      slack_call(
        cfg,
        token,
        "chat.update",
        slack_update_payload(chat_id, message_id, content),
        "ts",
      )
  }
}

///|
/// Delete a message (`chat.delete`).
pub async fn slack_delete(
  cfg : PlatformConfig,
  chat_id : String,
  message_id : String,
) -> SendResult {
  match cfg.token_of() {
    None => missing_config(Slack, "SLACK_BOT_TOKEN")
    Some(token) => {
      let payload = json_obj([
        ("channel", Json::string(chat_id)),
        ("ts", Json::string(message_id)),
      ])
      slack_call(cfg, token, "chat.delete", payload, "ts")
    }
  }
}

///|
/// Add a reaction (`reactions.add`).
pub async fn slack_react(
  cfg : PlatformConfig,
  chat_id : String,
  message_id : String,
  emoji : String,
) -> SendResult {
  match cfg.token_of() {
    None => missing_config(Slack, "SLACK_BOT_TOKEN")
    Some(token) => {
      let name = emoji.replace_all(old=":", new="")
      let payload = json_obj([
        ("channel", Json::string(chat_id)),
        ("timestamp", Json::string(message_id)),
        ("name", Json::string(name)),
      ])
      slack_call(cfg, token, "reactions.add", payload, "ok")
    }
  }
}

///|
/// Channel metadata (`conversations.info`).
pub async fn slack_get_chat(
  cfg : PlatformConfig,
  chat_id : String,
) -> ChatInfo? {
  match cfg.token_of() {
    None => None
    Some(token) => {
      let url = "\{slack_api_base(cfg)}/conversations.info?channel=\{url_quote(chat_id)}"
      match get_json(url, slack_headers(token)) {
        Err(_) => None
        Ok(j) =>
          if !json_field_bool(j, "ok").unwrap_or(false) {
            None
          } else {
            match json_field_obj(j, "channel") {
              Some(c) =>
                Some({
                  name: or_opt(
                    json_field_string(c, "name"),
                    json_field_string(c, "name_normalized"),
                  ).unwrap_or(chat_id),
                  chat_type: if json_field_bool(c, "is_im").unwrap_or(false) {
                    "im"
                  } else if json_field_bool(c, "is_private").unwrap_or(false) {
                    "group"
                  } else {
                    "channel"
                  },
                  chat_id,
                })
              None => None
            }
          }
      }
    }
  }
}

///|
/// Lowercase hex encoding of ``b``.
pub fn hex_lower(b : ArrayView[Byte]) -> String {
  let digits = "0123456789abcdef"
  let sb = StringBuilder()
  for x in b {
    let v = x.to_int()
    sb.write_string(digits[v / 16:v / 16 + 1].to_owned())
    sb.write_string(digits[v % 16:v % 16 + 1].to_owned())
  }
  sb.to_string()
}

///|
/// Slack request signature (`v0=<hex hmac-sha256>`).
pub fn slack_signature(
  secret : String,
  timestamp : String,
  body : String,
) -> String {
  "v0=\{hmac_sha256_hex(secret, "v0:\{timestamp}:\{body}")}"
}

///|
/// Verify a Slack `X-Slack-Signature` header (constant-time comparison).
pub fn slack_verify_signature(
  secret : String,
  timestamp : String,
  body : String,
  signature : String,
) -> Bool {
  constant_time_eq(slack_signature(secret, timestamp, body), signature)
}

///|
/// Verify a whole Slack webhook request: the `X-Slack-Signature` must match
/// and `X-Slack-Request-Timestamp` must be within ``window_s`` seconds of
/// ``now_s`` (Slack's recommended replay window is five minutes).
pub fn slack_request_verified(
  secret : String,
  timestamp : String,
  body : String,
  signature : String,
  now_s : Int64,
  window_s~ : Int64 = 300L,
) -> Bool {
  let ts = @string.parse_int64(timestamp) catch { _ => return false }
  let age = if now_s >= ts { now_s - ts } else { ts - now_s }
  age <= window_s && slack_verify_signature(secret, timestamp, body, signature)
}

///|
/// The `url_verification` challenge, if this body is a Slack handshake.
pub fn slack_challenge(body : String) -> String? {
  let j = @json.parse(body) catch { _ => return None }
  match json_field_string(j, "type") {
    Some("url_verification") => json_field_string(j, "challenge")
    _ => None
  }
}

///|
/// Parse a Slack Events API body (`event_callback`) into message events.
/// Bot/echo messages and message subtypes (edits, joins) are skipped.
pub fn slack_parse_event(
  body : String,
  bot_user_id? : String,
) -> Array[MessageEvent] {
  let j = @json.parse(body) catch { _ => return [] }
  let out : Array[MessageEvent] = []
  let ev = match json_field_obj(j, "event") {
    Some(e) => e
    None => return out
  }
  let ev_type = json_field_string(ev, "type").unwrap_or("")
  if ev_type != "message" && ev_type != "app_mention" {
    return out
  }
  if json_field_string(ev, "subtype") is Some(_) {
    return out
  }
  let user_id = json_field_string(ev, "user")
  match bot_user_id {
    Some(bot) =>
      match user_id {
        Some(u) => if u == bot { return out }
        None => ()
      }
    None => ()
  }
  if json_field_string(ev, "bot_id") is Some(_) {
    return out
  }
  let text = json_field_string(ev, "text").unwrap_or("")
  let channel = json_field_string(ev, "channel").unwrap_or("")
  if channel.is_empty() {
    return out
  }
  let thread = json_field_string(ev, "thread_ts")
  let mtype = if text.has_prefix("/") { Command } else { Text }
  out.push(
    MessageEvent::new(
      text,
      mtype,
      Slack,
      channel,
      user_id?,
      user_name?=json_field_string(ev, "username"),
      message_id?=json_field_string(ev, "ts"),
      reply_to_message_id?=thread,
      media=[],
      timestamp=now_ms(),
    ),
  )
  out
}
