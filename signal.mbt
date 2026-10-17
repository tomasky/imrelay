// Signal adapter via `signal-cli` JSON-RPC 2.0.
//
// Mirrors Hermes `plugins/platforms/signal/adapter.py`: every operation is a
// `POST {http_url}/api/v1/rpc` with `method: "send"` / `"sendTyping"`, and the
// account (phone number) is supplied in `params`. Group chats are addressed
// with a `group:` prefix on the chat id.

///|
/// signal-cli HTTP root (`SIGNAL_HTTP_URL`, e.g. `http://127.0.0.1:8080`).
pub fn signal_http_url(cfg : PlatformConfig) -> String {
  let url = cfg.extra_str("http_url", "")
  if url.has_suffix("/") {
    url[:url.length() - 1].to_owned()
  } else {
    url
  }
}

///|
/// Account phone number (`SIGNAL_ACCOUNT`).
pub fn signal_account(cfg : PlatformConfig) -> String? {
  cfg.extra_first(["account", "number"])
}

///|
/// Add the `recipient`/`groupId` routing key for ``chat_id`` to ``params``.
pub fn signal_with_target(params : Map[String, Json], chat_id : String) -> Unit {
  if chat_id.has_prefix("group:") {
    params.set("groupId", Json::string(chat_id[6:].to_owned()))
  } else {
    let recipients = Json::array([Json::string(chat_id)])
    params.set("recipient", recipients)
  }
}

///|
/// JSON-RPC body for `send`.
pub fn signal_send_params(
  account : String,
  chat_id : String,
  text : String,
) -> Json {
  let params : Map[String, Json] = Map([])
  params.set("account", Json::string(account))
  signal_with_target(params, chat_id)
  params.set("message", Json::string(text))
  json_obj([
    ("jsonrpc", Json::string("2.0")),
    ("method", Json::string("send")),
    ("params", Json::object(params)),
    ("id", Json::string("send_\{now_ms()}")),
  ])
}

///|
/// JSON-RPC body for `sendTyping`.
pub fn signal_typing_params(account : String, chat_id : String) -> Json {
  let params : Map[String, Json] = Map([])
  params.set("account", Json::string(account))
  signal_with_target(params, chat_id)
  json_obj([
    ("jsonrpc", Json::string("2.0")),
    ("method", Json::string("sendTyping")),
    ("params", Json::object(params)),
    ("id", Json::string("typing_\{now_ms()}")),
  ])
}

///|
/// One JSON-RPC call; returns the `result` object or an error string.
async fn signal_rpc(
  cfg : PlatformConfig,
  payload : Json,
) -> Result[Json, SendResult] {
  let url = "\{signal_http_url(cfg)}/api/v1/rpc"
  match post_json(url, payload, json_headers()) {
    Err(e) => Err(send_failure("signal rpc", e))
    Ok(j) =>
      match json_field_obj(j, "error") {
        Some(err) =>
          Err(
            send_body_failure(
              "signal rpc",
              json_field_string(err, "message").unwrap_or(err.stringify()),
            ),
          )
        None => Ok(json_field_obj(j, "result").unwrap_or(Json::null()))
      }
  }
}

///|
/// Send ``content``, chunked at Signal's 8000-char limit.
pub async fn signal_send(
  cfg : PlatformConfig,
  chat_id : String,
  content : String,
  reply_to? : String,
) -> SendResult {
  ignore(reply_to)
  match signal_account(cfg) {
    None => missing_config(Signal, "SIGNAL_ACCOUNT")
    Some(account) =>
      if signal_http_url(cfg).is_empty() {
        missing_config(Signal, "SIGNAL_HTTP_URL")
      } else if content.is_empty() {
        SendResult::ok()
      } else {
        let mut last = SendResult::ok()
        for chunk in chunk_text(content, Platform::max_message_length(Signal)) {
          let r = send_with_retry(() => {
            match signal_rpc(cfg, signal_send_params(account, chat_id, chunk)) {
              Err(e) => e
              Ok(result) =>
                SendResult::ok(
                  message_id?=json_field_int(result, "timestamp").map(x => {
                    x.to_string()
                  }),
                  raw=result.stringify(),
                )
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
/// Typing indicator (`method: sendTyping`), failures ignored.
pub async fn signal_typing(cfg : PlatformConfig, chat_id : String) -> Unit {
  match signal_account(cfg) {
    None => ()
    Some(account) =>
      if signal_http_url(cfg).is_empty() {
        ()
      } else {
        ignore(signal_rpc(cfg, signal_typing_params(account, chat_id)))
      }
  }
}

///|
/// Parse a `signal-cli` `dataMessage` envelope into a `MessageEvent`.
pub fn signal_parse_envelope(envelope : Json) -> MessageEvent? {
  let data = match json_field_obj(envelope, "dataMessage") {
    Some(d) => d
    None => return None
  }
  let source = or_opt(
    json_field_string(envelope, "sourceNumber"),
    json_field_string(envelope, "source"),
  ).unwrap_or("")
  if source.is_empty() {
    return None
  }
  let chat_id = match json_field_obj(data, "groupInfo") {
    Some(g) =>
      match json_field_string(g, "groupId") {
        Some(gid) => "group:\{gid}"
        None => source
      }
    None => source
  }
  let text = json_field_string(data, "message").unwrap_or("")
  let media : Array[MediaAttachment] = []
  for att in json_field_array(data, "attachments").unwrap_or([]) {
    let content_type = json_field_string(att, "contentType").unwrap_or("")
    let kind = if content_type.has_prefix("image/") {
      "photo"
    } else if content_type.has_prefix("audio/") {
      "voice"
    } else if content_type.has_prefix("video/") {
      "video"
    } else {
      "document"
    }
    media.push({ url: json_field_string(att, "id").unwrap_or(""), kind, })
  }
  let reply = match json_field_obj(data, "quote") {
    Some(q) => json_id(q, "id")
    None => None
  }
  let mtype = if text.has_prefix("/") { Command } else { Text }
  Some(
    MessageEvent::new(
      text,
      mtype,
      Signal,
      chat_id,
      user_id?=json_field_string(envelope, "sourceUuid"),
      user_name?=json_field_string(envelope, "sourceName"),
      message_id?=json_field_int(data, "timestamp").map(x => x.to_string()),
      reply_to_message_id?=reply,
      media~,
      timestamp=now_ms(),
    ),
  )
}

///|
/// Parse the array returned by `GET /v1/receive/{account}` (or a JSON-RPC
/// receive result) into events.
pub fn signal_parse_receive(body : String) -> Array[MessageEvent] {
  let out : Array[MessageEvent] = []
  let j = @json.parse(body) catch { _ => return out }
  let items = match j {
    Array(a) => a
    Object(_) =>
      match json_field_array(j, "envelopes") {
        Some(a) => a
        None => []
      }
    _ => []
  }
  for item in items {
    let envelope = json_field_obj(item, "envelope").unwrap_or(item)
    match signal_parse_envelope(envelope) {
      Some(ev) => out.push(ev)
      None => ()
    }
  }
  out
}
