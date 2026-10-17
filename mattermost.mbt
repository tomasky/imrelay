// Mattermost REST API v4 adapter.
//
// Mirrors Hermes `plugins/platforms/mattermost/adapter.py`: posts go through
// `POST /api/v4/posts` with mentions disabled, replies use `root_id` in thread
// mode, and inbound traffic arrives through an outgoing-webhook POST.

///|
/// API root (`{url}/api/v4`), overridable with `[mattermost.extra] api_base`.
pub fn mattermost_api_base(cfg : PlatformConfig) -> String {
  let api_override = cfg.extra_str("api_base", "")
  if !api_override.is_empty() {
    return if api_override.has_suffix("/") {
      api_override[:api_override.length() - 1].to_owned()
    } else {
      api_override
    }
  }
  let url = cfg.extra_str("url", "")
  let trimmed = if url.has_suffix("/") {
    url[:url.length() - 1].to_owned()
  } else {
    url
  }
  "\{trimmed}/api/v4"
}

///|
/// `POST /posts` payload (mentions disabled, optional thread root).
pub fn mattermost_send_payload(
  channel_id : String,
  message : String,
  reply_to : String?,
) -> Json {
  let props : Map[String, Json] = Map([])
  props.set("disable_mentions", Json::boolean(true))
  let payload = json_obj([
    ("channel_id", Json::string(channel_id)),
    ("message", Json::string(message)),
    ("props", Json::object(props)),
  ])
  obj_with_opt(payload, "root_id", reply_to)
}

///|
/// Call the Mattermost API.
async fn mattermost_call(
  cfg : PlatformConfig,
  token : String,
  meth : String,
  path : String,
  payload : Json,
) -> SendResult {
  let url = "\{mattermost_api_base(cfg)}\{path}"
  let headers = bearer_headers(token)
  let res = match meth {
    "GET" => get_json(url, headers)
    _ => post_json(url, payload, headers)
  }
  match res {
    Err(e) => send_failure("mattermost", e)
    Ok(j) =>
      match json_field_string(j, "message") {
        Some(m) =>
          if json_field_string(j, "id") is None &&
            json_field_int(j, "status_code") is Some(_) {
            send_body_failure("mattermost", m)
          } else {
            send_ok(json_field_string(j, "id"), j)
          }
        None => send_ok(json_field_string(j, "id"), j)
      }
  }
}

///|
/// Send ``content``, chunked at Mattermost's 16383-char limit.
pub async fn mattermost_send(
  cfg : PlatformConfig,
  chat_id : String,
  content : String,
  reply_to? : String,
) -> SendResult {
  match cfg.token_of() {
    None => missing_config(Mattermost, "MATTERMOST_TOKEN")
    Some(token) =>
      if mattermost_api_base(cfg) == "/api/v4" {
        missing_config(Mattermost, "MATTERMOST_URL")
      } else if content.is_empty() {
        SendResult::ok()
      } else {
        let mut first = true
        let mut last = SendResult::ok()
        let mut first_id : String? = None
        for
          chunk in chunk_text(content, Platform::max_message_length(Mattermost)) {
          let reply = if first { reply_to } else { None }
          let r = send_with_retry(() => {
            mattermost_call(
              cfg,
              token,
              "POST",
              "/posts",
              mattermost_send_payload(chat_id, chunk, reply),
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
  }
}

///|
/// Channel metadata (`GET /channels/{id}`).
pub async fn mattermost_get_chat(
  cfg : PlatformConfig,
  chat_id : String,
) -> ChatInfo? {
  match cfg.token_of() {
    None => None
    Some(token) => {
      let url = "\{mattermost_api_base(cfg)}/channels/\{chat_id}"
      match get_json(url, bearer_headers(token)) {
        Err(_) => None
        Ok(j) =>
          Some({
            name: or_opt(
              json_field_string(j, "display_name"),
              json_field_string(j, "name"),
            ).unwrap_or(chat_id),
            chat_type: json_field_string(j, "type").unwrap_or("O"),
            chat_id,
          })
      }
    }
  }
}

///|
/// The `token` carried by a Mattermost outgoing-webhook body (configured on
/// the outgoing webhook in Mattermost; compared with `[mattermost.extra]
/// webhook_token` when set).
pub fn mattermost_webhook_token(body : String) -> String? {
  let j = @json.parse(body) catch { _ => return None }
  json_field_string(j, "token")
}

///|
/// Parse a Mattermost outgoing-webhook body into a `MessageEvent`.
pub fn mattermost_parse_webhook(body : String) -> Array[MessageEvent] {
  let out : Array[MessageEvent] = []
  let j = @json.parse(body) catch { _ => return out }
  let text = json_field_string(j, "text").unwrap_or("")
  let channel_id = json_field_string(j, "channel_id").unwrap_or("")
  if channel_id.is_empty() || text.is_empty() {
    return out
  }
  let mtype = if text.has_prefix("/") { Command } else { Text }
  out.push(
    MessageEvent::new(
      text,
      mtype,
      Mattermost,
      channel_id,
      user_id?=json_field_string(j, "user_id"),
      user_name?=json_field_string(j, "user_name"),
      message_id?=json_field_string(j, "post_id"),
      media=[],
      timestamp=now_ms(),
    ),
  )
  out
}
