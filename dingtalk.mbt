// DingTalk adapter.
//
// Mirrors Hermes `plugins/platforms/dingtalk/adapter.py`. Two transports are
// supported: a group robot webhook (`oapi.dingtalk.com/robot/send`) and the
// newer app-robot API (`api.dingtalk.com/v1.0/robot/…`) addressed by
// `robotCode`. Inbound traffic arrives as an outgoing robot callback carrying
// a `sessionWebhook` that can be used for replies.

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
/// Cached app access tokens keyed by app key.
let dingtalk_token_cache : Map[String, String] = Map([])

///|
/// Fetch (and cache) an app-robot access token.
pub async fn dingtalk_access_token(cfg : PlatformConfig) -> String? {
  let key = match dingtalk_app_key(cfg) {
    Some(k) => k
    None => return None
  }
  let secret = match dingtalk_app_secret(cfg) {
    Some(s) => s
    None => return None
  }
  match dingtalk_token_cache.get(key) {
    Some(t) => return Some(t)
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
          dingtalk_token_cache.set(key, t)
          Some(t)
        }
        None => None
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
/// Send ``content``. Uses the app-robot API when app credentials are present,
/// otherwise falls back to the group robot webhook.
pub async fn dingtalk_send(
  cfg : PlatformConfig,
  chat_id : String,
  content : String,
  reply_to? : String,
) -> SendResult {
  ignore(reply_to)
  let title = cfg.extra_str("title", "Message")
  if content.is_empty() {
    return SendResult::ok()
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
          ("robotCode", Json::string(dingtalk_app_key(cfg).unwrap_or(""))),
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
/// Send through the group robot webhook.
pub async fn dingtalk_send_webhook(
  cfg : PlatformConfig,
  content : String,
  title : String,
) -> SendResult {
  match dingtalk_robot_token(cfg) {
    None => missing_config(Dingtalk, "DINGTALK_ACCESS_TOKEN")
    Some(token) => {
      let base = cfg.extra_str("webhook_base", "https://oapi.dingtalk.com")
      let url = "\{base}/robot/send?access_token=\{url_quote(token)}"
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
  }
}

///|
/// Post to a fresh `sessionWebhook` (used to reply to an inbound callback).
pub async fn dingtalk_session_reply(
  session_webhook : String,
  content : String,
  title? : String,
) -> SendResult {
  let payload = dingtalk_send_payload(content, title.unwrap_or("Message"), true)
  match post_json(session_webhook, payload, json_headers()) {
    Err(e) => send_failure("dingtalk session", e)
    Ok(j) => dingtalk_robot_result(j)
  }
}

///|
/// Parse a DingTalk robot callback body into a `MessageEvent`. The
/// `sessionWebhook` is preserved in `reply_to_text` so the caller can answer
/// without a separate token.
pub fn dingtalk_parse_callback(body : String) -> Array[MessageEvent] {
  let out : Array[MessageEvent] = []
  let j = @json.parse(body) catch { _ => return out }
  let chat_id = or_opt(
    json_field_string(j, "conversationId"),
    json_field_string(j, "senderId"),
  ).unwrap_or("")
  if chat_id.is_empty() {
    return out
  }
  let text = match json_field_string(j, "msgtype") {
    Some("markdown") =>
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
  let mtype = if text.has_prefix("/") { Command } else { Text }
  out.push(
    MessageEvent::new(
      text,
      mtype,
      Dingtalk,
      chat_id,
      user_id?=json_field_string(j, "senderId"),
      user_name?=json_field_string(j, "senderNick"),
      message_id?=json_field_string(j, "msgId"),
      reply_to_text?=json_field_string(j, "sessionWebhook"),
      media=[],
      timestamp=now_ms(),
    ),
  )
  out
}
