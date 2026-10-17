// BlueBubbles (iMessage) adapter.
//
// Mirrors Hermes `plugins/platforms/bluebubbles/adapter.py`: the BlueBubbles
// server exposes a local REST API at `{server_url}/api/v1`, authenticated with
// a password query parameter, and pushes inbound messages to a webhook as
// `{"type":"new-message","data":{…}}`.

///|
/// API root (`{server_url}/api/v1`).
pub fn bluebubbles_api_base(cfg : PlatformConfig) -> String {
  let url = cfg.extra_str("server_url", "")
  let trimmed = if url.has_suffix("/") {
    url[:url.length() - 1].to_owned()
  } else {
    url
  }
  "\{trimmed}/api/v1"
}

///|
/// Append the password query parameter to an endpoint.
pub fn bluebubbles_url(cfg : PlatformConfig, path : String) -> String {
  let password = cfg.token_of().unwrap_or("")
  if password.is_empty() {
    "\{bluebubbles_api_base(cfg)}\{path}"
  } else {
    "\{bluebubbles_api_base(cfg)}\{path}?password=\{url_quote(password)}"
  }
}

///|
/// `POST /message/text` payload.
pub fn bluebubbles_send_payload(
  chat_guid : String,
  message : String,
  reply_to : String?,
) -> Json {
  let payload = json_obj([
    ("chatGuid", Json::string(chat_guid)),
    ("tempGuid", Json::string("temp-\{random_hex(12)}")),
    ("message", Json::string(message)),
    ("method", Json::string("apple-script")),
  ])
  obj_with_opt(payload, "selectedMessageGuid", reply_to)
}

///|
/// Map a BlueBubbles `{status, message, data}` response onto a `SendResult`.
fn bluebubbles_result(j : Json, prefix : String) -> SendResult {
  let status = json_field_int(j, "status").unwrap_or(200)
  if status >= 200 && status < 300 {
    let mid = match json_field_obj(j, "data") {
      Some(d) => json_field_string(d, "guid")
      None => json_field_string(j, "guid")
    }
    send_ok(mid, j)
  } else {
    let msg = json_field_string(j, "message").unwrap_or(j.stringify())
    SendResult::failed(
      "\{prefix}: \{msg}",
      retryable=status == 503 || status == 500,
      kind=classify_send_error(msg),
      raw=j.stringify(),
    )
  }
}

///|
/// One BlueBubbles call.
async fn bluebubbles_call(
  cfg : PlatformConfig,
  meth : String,
  path : String,
  payload : Json,
) -> SendResult {
  let url = bluebubbles_url(cfg, path)
  let res = match meth {
    "GET" => get_json(url, json_headers())
    "POST" => post_json(url, payload, json_headers())
    _ => post_json(url, payload, json_headers())
  }
  match res {
    Err(e) => send_failure("bluebubbles", e)
    Ok(j) => bluebubbles_result(j, "bluebubbles")
  }
}

///|
/// Send ``content``, chunked at iMessage's practical 4000-char limit.
pub async fn bluebubbles_send(
  cfg : PlatformConfig,
  chat_id : String,
  content : String,
  reply_to? : String,
) -> SendResult {
  if bluebubbles_api_base(cfg) == "/api/v1" {
    return missing_config(Bluebubbles, "BLUEBUBBLES_SERVER_URL")
  }
  if content.is_empty() {
    return SendResult::ok()
  }
  let mut first = true
  let mut last = SendResult::ok()
  let mut first_id : String? = None
  for chunk in chunk_text(content, Platform::max_message_length(Bluebubbles)) {
    let reply = if first { reply_to } else { None }
    let r = send_with_retry(() => {
      bluebubbles_call(
        cfg,
        "POST",
        "/message/text",
        bluebubbles_send_payload(chat_id, chunk, reply),
      )
    })
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

///|
/// Typing indicator (`POST /chat/{guid}/typing`).
pub async fn bluebubbles_typing(cfg : PlatformConfig, chat_id : String) -> Unit {
  ignore(
    bluebubbles_call(
      cfg,
      "POST",
      "/chat/\{url_quote(chat_id)}/typing",
      Json::null(),
    ),
  )
}

///|
/// Last path segment of a local file path.
fn basename(path : String) -> String {
  let mut name = path
  for part in path.split("/") {
    let p = part.to_owned()
    if !p.is_empty() {
      name = p
    }
  }
  name
}

///|
/// Send a media attachment by local file path.
pub async fn bluebubbles_send_attachment(
  cfg : PlatformConfig,
  chat_id : String,
  attachment_path : String,
) -> SendResult {
  let payload = json_obj([
    ("chatGuid", Json::string(chat_id)),
    ("tempGuid", Json::string("temp-\{random_hex(12)}")),
    ("name", Json::string(basename(attachment_path))),
    ("path", Json::string(attachment_path)),
    ("method", Json::string("apple-script")),
  ])
  bluebubbles_call(cfg, "POST", "/message/attachment", payload)
}

///|
/// Server health (`GET /ping`) — also validates the password.
pub async fn bluebubbles_ping(cfg : PlatformConfig) -> Bool {
  match get_json(bluebubbles_url(cfg, "/ping"), json_headers()) {
    Err(_) => false
    Ok(j) => json_field_int(j, "status").unwrap_or(200) == 200
  }
}

///|
/// Chat metadata (`POST /chat/query` filtered by guid).
pub async fn bluebubbles_get_chat(
  cfg : PlatformConfig,
  chat_id : String,
) -> ChatInfo? {
  let payload = json_obj([
    ("limit", Json::number(1.0)),
    ("offset", Json::number(0.0)),
    ("with", Json::array([Json::string("participants")])),
  ])
  match
    post_json(bluebubbles_url(cfg, "/chat/query"), payload, json_headers()) {
    Err(_) => None
    Ok(j) =>
      match json_field_array(j, "data") {
        Some(items) =>
          if items.length() > 0 {
            let c = items[0]
            Some({
              name: or_opt(
                json_field_string(c, "displayName"),
                json_field_string(c, "guid"),
              ).unwrap_or(chat_id),
              chat_type: if json_field_array(c, "participants")
                .unwrap_or([])
                .length() >
                1 {
                "group"
              } else {
                "dm"
              },
              chat_id,
            })
          } else {
            None
          }
        None => None
      }
  }
}

///|
/// Webhook credential from a BlueBubbles POST: the `password` query parameter
/// (BlueBubbles appends it to registered webhook URLs) or the `x-password`
/// header (Hermes `_webhook_token`).
pub fn bluebubbles_webhook_token(query : String, header : String?) -> String? {
  match query_param(query, "password") {
    Some(p) => if !p.is_empty() { return Some(p) }
    None => ()
  }
  match header {
    Some(h) => if !h.is_empty() { Some(h) } else { None }
    None => None
  }
}

///|
/// Parse a BlueBubbles `new-message` webhook into events. Self-sent messages
/// (`isFromMe`) are filtered to avoid echo loops.
pub fn bluebubbles_parse_event(body : String) -> Array[MessageEvent] {
  let out : Array[MessageEvent] = []
  let j = @json.parse(body) catch { _ => return out }
  if json_field_string(j, "type") is Some(t) {
    if t != "new-message" {
      return out
    }
  }
  let data = match json_field_obj(j, "data") {
    Some(d) => d
    None => j
  }
  if json_field_bool(data, "isFromMe").unwrap_or(false) {
    return out
  }
  let chat_guid = match json_field_array(data, "chats") {
    Some(chats) =>
      if chats.length() > 0 {
        json_field_string(chats[0], "guid")
      } else {
        None
      }
    None => None
  }
  let chat_id = or_opt(chat_guid, json_field_string(data, "chatGuid")).unwrap_or(
    "",
  )
  if chat_id.is_empty() {
    return out
  }
  let text = json_field_string(data, "text").unwrap_or("")
  let handle = json_field_obj(data, "handle").unwrap_or(Json::null())
  let has_attachment = json_field_array(data, "attachments")
    .unwrap_or([])
    .length() >
    0
  let mtype = if text.has_prefix("/") {
    Command
  } else if has_attachment {
    Photo
  } else {
    Text
  }
  out.push(
    MessageEvent::new(
      text,
      mtype,
      Bluebubbles,
      chat_id,
      user_id?=json_field_string(handle, "address"),
      message_id?=json_field_string(data, "guid"),
      media=[],
      timestamp=now_ms(),
    ),
  )
  out
}
