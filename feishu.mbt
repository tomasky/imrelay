// Feishu / Lark open-platform adapter.
//
// Mirrors Hermes `plugins/platforms/feishu/adapter.py`: a tenant access token
// is fetched from `/auth/v3/tenant_access_token/internal`, messages are posted
// to `/im/v1/messages?receive_id_type=chat_id` (4000-char text chunks), and
// inbound traffic arrives as an event callback (`im.message.receive_v1`).

///|
/// Open-platform root, overridable with `[feishu.extra] api_base`
/// (`https://open.larksuite.com/open-apis` for Lark).
pub fn feishu_api_base(cfg : PlatformConfig) -> String {
  let base = cfg.extra_str("api_base", "https://open.feishu.cn/open-apis")
  if base.has_suffix("/") {
    base[:base.length() - 1].to_owned()
  } else {
    base
  }
}

///|
/// App id (`FEISHU_APP_ID`).
pub fn feishu_app_id(cfg : PlatformConfig) -> String {
  cfg.extra_str("app_id", "")
}

///|
/// App secret (`FEISHU_APP_SECRET`), also accepted as `token`.
pub fn feishu_app_secret(cfg : PlatformConfig) -> String? {
  match cfg.extra_first(["app_secret"]) {
    Some(s) => Some(s)
    None => cfg.token_of()
  }
}

///|
/// Cached tenant access tokens keyed by app id.
let feishu_token_cache : Map[String, String] = Map([])

///|
/// Fetch (and cache) a tenant access token.
pub async fn feishu_tenant_token(cfg : PlatformConfig) -> String? {
  let app_id = feishu_app_id(cfg)
  let secret = match feishu_app_secret(cfg) {
    Some(s) => s
    None => return None
  }
  if app_id.is_empty() {
    return None
  }
  match feishu_token_cache.get(app_id) {
    Some(t) => return Some(t)
    None => ()
  }
  let url = "\{feishu_api_base(cfg)}/auth/v3/tenant_access_token/internal"
  let body = json_obj([
    ("app_id", Json::string(app_id)),
    ("app_secret", Json::string(secret)),
  ])
  match post_json(url, body, json_headers()) {
    Err(_) => None
    Ok(j) =>
      match json_field_string(j, "tenant_access_token") {
        Some(t) => {
          feishu_token_cache.set(app_id, t)
          Some(t)
        }
        None => None
      }
  }
}

///|
/// Map a Feishu API response (`{code, msg, data}`) onto a `SendResult`.
fn feishu_result(j : Json) -> SendResult {
  match json_field_int(j, "code") {
    Some(0) => {
      let mid = match json_field_obj(j, "data") {
        Some(d) => json_field_string(d, "message_id")
        None => None
      }
      send_ok(mid, j)
    }
    Some(code) => {
      let msg = json_field_string(j, "msg").unwrap_or(j.stringify())
      SendResult::failed(
        "feishu: \{msg} (code \{code})",
        kind=classify_send_error(msg),
        raw=j.stringify(),
      )
    }
    None => send_body_failure("feishu", j.stringify())
  }
}

///|
/// Post to `/im/v1/messages`. ``id_type`` is `chat_id` or `open_id`.
pub async fn feishu_send_to(
  cfg : PlatformConfig,
  receive_id : String,
  id_type : String,
  content : String,
) -> SendResult {
  match feishu_tenant_token(cfg) {
    None => missing_config(Feishu, "FEISHU_APP_ID / FEISHU_APP_SECRET")
    Some(token) => {
      if content.is_empty() {
        return SendResult::ok()
      }
      let url = "\{feishu_api_base(cfg)}/im/v1/messages?receive_id_type=\{id_type}"
      let mut last = SendResult::ok()
      let mut first_id : String? = None
      for chunk in chunk_text(content, Platform::max_message_length(Feishu)) {
        let body = json_obj([
          ("receive_id", Json::string(receive_id)),
          ("msg_type", Json::string("text")),
          (
            "content",
            Json::string(json_obj([("text", Json::string(chunk))]).stringify()),
          ),
        ])
        let r = send_with_retry(() => {
          match post_json(url, body, bearer_headers(token)) {
            Err(e) => send_failure("feishu", e)
            Ok(j) => feishu_result(j)
          }
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
/// Send to a chat (`receive_id_type=chat_id`).
pub async fn feishu_send(
  cfg : PlatformConfig,
  chat_id : String,
  content : String,
  reply_to? : String,
) -> SendResult {
  ignore(reply_to)
  feishu_send_to(cfg, chat_id, "chat_id", content)
}

///|
/// Reply in-thread to a specific message.
pub async fn feishu_reply(
  cfg : PlatformConfig,
  message_id : String,
  content : String,
) -> SendResult {
  match feishu_tenant_token(cfg) {
    None => missing_config(Feishu, "FEISHU_APP_ID / FEISHU_APP_SECRET")
    Some(token) => {
      let url = "\{feishu_api_base(cfg)}/im/v1/messages/\{message_id}/reply"
      let body = json_obj([
        ("msg_type", Json::string("text")),
        (
          "content",
          Json::string(json_obj([("text", Json::string(content))]).stringify()),
        ),
      ])
      match post_json(url, body, bearer_headers(token)) {
        Err(e) => send_failure("feishu reply", e)
        Ok(j) => feishu_result(j)
      }
    }
  }
}

///|
/// Chat metadata (`GET /im/v1/chats/{chat_id}`).
pub async fn feishu_get_chat(
  cfg : PlatformConfig,
  chat_id : String,
) -> ChatInfo? {
  match feishu_tenant_token(cfg) {
    None => None
    Some(token) => {
      let url = "\{feishu_api_base(cfg)}/im/v1/chats/\{chat_id}"
      match get_json(url, bearer_headers(token)) {
        Err(_) => None
        Ok(j) =>
          match json_field_obj(j, "data") {
            Some(d) =>
              Some({
                name: json_field_string(d, "name").unwrap_or(chat_id),
                chat_type: json_field_string(d, "chat_mode").unwrap_or("group"),
                chat_id,
              })
            None => None
          }
      }
    }
  }
}

///|
/// Event-callback URL verification challenge.
pub fn feishu_challenge(body : String) -> String? {
  let j = @json.parse(body) catch { _ => return None }
  json_field_string(j, "challenge")
}

///|
/// Parse a Feishu event callback (`im.message.receive_v1`) into events.
/// Messages sent by the bot itself and plain text-less messages are skipped.
pub fn feishu_parse_event(body : String) -> Array[MessageEvent] {
  let out : Array[MessageEvent] = []
  let j = @json.parse(body) catch { _ => return out }
  let event = match json_field_obj(j, "event") {
    Some(e) => e
    None => return out
  }
  let message = match json_field_obj(event, "message") {
    Some(m) => m
    None => return out
  }
  let sender = json_field_obj(event, "sender").unwrap_or(Json::null())
  let sender_type = json_field_string(sender, "sender_type").unwrap_or("")
  if sender_type == "bot" || sender_type == "app" {
    return out
  }
  let sender_id = json_field_obj(sender, "sender_id").unwrap_or(Json::null())
  let chat_id = json_field_string(message, "chat_id").unwrap_or("")
  if chat_id.is_empty() {
    return out
  }
  let text = feishu_message_text(message)
  let msg_type = json_field_string(message, "message_type").unwrap_or("text")
  let mtype = if text.has_prefix("/") {
    Command
  } else {
    match msg_type {
      "image" => Photo
      "audio" => Audio
      "media" => Video
      "file" => Document
      _ => Text
    }
  }
  out.push(
    MessageEvent::new(
      text,
      mtype,
      Feishu,
      chat_id,
      user_id?=or_opt(
        json_field_string(sender_id, "open_id"),
        json_field_string(sender_id, "user_id"),
      ),
      message_id?=json_field_string(message, "message_id"),
      reply_to_message_id?=json_field_string(message, "parent_id"),
      media=[],
      timestamp=parse_ms(json_field_string(message, "create_time")),
    ),
  )
  out
}

///|
/// Extract the text body from a Feishu message (JSON-encoded `content`).
pub fn feishu_message_text(message : Json) -> String {
  let raw = json_field_string(message, "content").unwrap_or("")
  let content = @json.parse(raw) catch { _ => return raw }
  json_field_string(content, "text").unwrap_or(raw)
}
