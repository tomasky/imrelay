// Discord REST adapter (`discord.com/api/v10`).
//
// Mirrors Hermes `plugins/platforms/discord/adapter.py`: text goes through
// `POST /channels/{id}/messages`, chunked at 2000 chars, with an optional
// `message_reference` for replies. Inbound traffic is either a Discord
// *interaction* webhook (PING / slash command) or a normalized MESSAGE_CREATE
// payload forwarded by a gateway relay.

///|
/// API root, overridable with `[discord.extra] api_base`.
pub fn discord_api_base(cfg : PlatformConfig) -> String {
  let base = cfg.extra_str("api_base", "https://discord.com/api/v10")
  if base.has_suffix("/") {
    base[:base.length() - 1].to_owned()
  } else {
    base
  }
}

///|
/// `POST /channels/{id}/messages` payload.
pub fn discord_send_payload(content : String, reply_to : String?) -> Json {
  let payload = json_obj([("content", Json::string(content))])
  match reply_to {
    Some(mid) =>
      if payload is Object(m) {
        m.set(
          "message_reference",
          json_obj([
            ("message_id", Json::string(mid)),
            ("fail_if_not_exists", Json::boolean(false)),
          ]),
        )
      }
    None => ()
  }
  payload
}

///|
/// Embed payload for a media URL (avoids multipart uploads).
pub fn discord_media_payload(
  kind : String,
  url : String,
  caption : String?,
) -> Json {
  let key = match kind {
    "photo" | "image" => "image"
    "video" => "image"
    _ => "image"
  }
  let embed = json_obj([(key, json_obj([("url", Json::string(url))]))])
  let payload = json_obj([("embeds", Json::array([embed]))])
  obj_with_opt(payload, "content", caption)
}

///|
/// Map a Discord REST error response onto a `SendResult`.
fn discord_failure(prefix : String, e : ApiError) -> SendResult {
  let retry_after = discord_retry_after(e.body)
  SendResult::failed(
    "\{prefix}: \{api_error_message(e)}",
    retryable=e.is_transient() || retry_after is Some(_),
    retry_after?,
    kind=classify_send_error(e.body),
  )
}

///|
/// Extract `retry_after` seconds from a Discord 429 body.
pub fn discord_retry_after(body : String) -> Double? {
  let j = @json.parse(body) catch { _ => return None }
  match j {
    Object(m) =>
      match m.get("retry_after") {
        Some(Number(n, ..)) => Some(n)
        _ => None
      }
    _ => None
  }
}

///|
/// Message id from a Discord message object.
fn discord_message_id(j : Json) -> String? {
  json_field_string(j, "id")
}

///|
/// One REST call. `meth` is one of "GET"/"POST"/"PATCH"/"PUT"/"DELETE".
async fn discord_call(
  cfg : PlatformConfig,
  token : String,
  meth : String,
  path : String,
  payload : Json,
) -> SendResult {
  let url = "\{discord_api_base(cfg)}\{path}"
  let (m, body) = match meth {
    "GET" => (@http.Get, "")
    "POST" => (@http.Post, payload.stringify())
    "PATCH" => (@http.Patch, payload.stringify())
    "PUT" => (@http.Put, payload.stringify())
    "DELETE" => (@http.Delete, "")
    _ => (@http.Get, "")
  }
  match request_json(m, url, body, bot_headers(token)) {
    Err(e) => discord_failure("discord \{meth} \{path}", e)
    Ok(j) => send_ok(discord_message_id(j), j)
  }
}

///|
/// Send ``content``, chunked at Discord's 2000-char limit.
pub async fn discord_send(
  cfg : PlatformConfig,
  chat_id : String,
  content : String,
  reply_to? : String,
) -> SendResult {
  match cfg.token_of() {
    None => missing_config(Discord, "DISCORD_BOT_TOKEN")
    Some(token) =>
      if content.is_empty() {
        return SendResult::ok()
      } else {
        let mut first = true
        let mut last = SendResult::ok()
        let mut first_id : String? = None
        for chunk in chunk_text(content, Platform::max_message_length(Discord)) {
          let reply = if first { reply_to } else { None }
          let r = send_with_retry(() => {
            discord_call(
              cfg,
              token,
              "POST",
              "/channels/\{chat_id}/messages",
              discord_send_payload(chunk, reply),
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
/// Typing indicator (`POST /channels/{id}/typing`, no content).
pub async fn discord_typing(cfg : PlatformConfig, chat_id : String) -> Unit {
  match cfg.token_of() {
    None => ()
    Some(token) =>
      ignore(
        discord_call(
          cfg,
          token,
          "POST",
          "/channels/\{chat_id}/typing",
          Json::null(),
        ),
      )
  }
}

///|
/// Send a media URL inside an embed.
pub async fn discord_send_media(
  cfg : PlatformConfig,
  chat_id : String,
  kind : String,
  url : String,
  caption? : String,
) -> SendResult {
  match cfg.token_of() {
    None => missing_config(Discord, "DISCORD_BOT_TOKEN")
    Some(token) =>
      discord_call(
        cfg,
        token,
        "POST",
        "/channels/\{chat_id}/messages",
        discord_media_payload(kind, url, caption),
      )
  }
}

///|
/// Edit a message (`PATCH /channels/{id}/messages/{mid}`).
pub async fn discord_edit(
  cfg : PlatformConfig,
  chat_id : String,
  message_id : String,
  content : String,
) -> SendResult {
  match cfg.token_of() {
    None => missing_config(Discord, "DISCORD_BOT_TOKEN")
    Some(token) =>
      discord_call(
        cfg,
        token,
        "PATCH",
        "/channels/\{chat_id}/messages/\{message_id}",
        json_obj([("content", Json::string(content))]),
      )
  }
}

///|
/// Delete a message.
pub async fn discord_delete(
  cfg : PlatformConfig,
  chat_id : String,
  message_id : String,
) -> SendResult {
  match cfg.token_of() {
    None => missing_config(Discord, "DISCORD_BOT_TOKEN")
    Some(token) =>
      discord_call(
        cfg,
        token,
        "DELETE",
        "/channels/\{chat_id}/messages/\{message_id}",
        Json::null(),
      )
  }
}

///|
/// Add a reaction (`PUT …/reactions/{emoji}/@me`).
pub async fn discord_react(
  cfg : PlatformConfig,
  chat_id : String,
  message_id : String,
  emoji : String,
) -> SendResult {
  match cfg.token_of() {
    None => missing_config(Discord, "DISCORD_BOT_TOKEN")
    Some(token) =>
      discord_call(
        cfg,
        token,
        "PUT",
        "/channels/\{chat_id}/messages/\{message_id}/reactions/\{url_quote(emoji)}/@me",
        Json::null(),
      )
  }
}

///|
/// Channel metadata (`GET /channels/{id}`).
pub async fn discord_get_chat(
  cfg : PlatformConfig,
  chat_id : String,
) -> ChatInfo? {
  match cfg.token_of() {
    None => None
    Some(token) => {
      let url = "\{discord_api_base(cfg)}/channels/\{chat_id}"
      match get_json(url, bot_headers(token)) {
        Err(_) => None
        Ok(j) =>
          match json_field_string(j, "name") {
            Some(name) =>
              Some({
                name,
                chat_type: discord_channel_type(
                  json_field_int(j, "type").unwrap_or(0),
                ),
                chat_id,
              })
            None => None
          }
      }
    }
  }
}

///|
/// Discord `channel.type` → a readable chat type.
pub fn discord_channel_type(t : Int32) -> String {
  match t {
    0 => "text"
    1 => "dm"
    2 => "voice"
    3 => "group_dm"
    4 => "category"
    5 => "announcement"
    10 | 11 | 12 => "thread"
    _ => "channel"
  }
}

///|
/// Parse a Discord interaction webhook: `PING` (type 1) / application command
/// (type 2). Returns the events plus the `PONG` body when a handshake arrived.
pub fn discord_parse_interaction(body : String) -> Array[MessageEvent] {
  let j = @json.parse(body) catch { _ => return [] }
  let out : Array[MessageEvent] = []
  match json_field_int(j, "type") {
    Some(2) => {
      let data = json_field_obj(j, "data").unwrap_or(Json::null())
      let name = json_field_string(data, "name").unwrap_or("")
      let text = discord_command_text(name, data)
      let chat_id = json_id(j, "channel_id").unwrap_or("")
      let member_obj = json_field_obj(j, "member").unwrap_or(Json::null())
      let user = json_field_obj(member_obj, "user").unwrap_or(Json::null())
      if !chat_id.is_empty() {
        out.push(
          MessageEvent::new(
            text,
            Command,
            Discord,
            chat_id,
            user_id?=json_id(user, "id"),
            user_name?=json_field_string(user, "username"),
            message_id?=json_field_string(j, "id"),
            media=[],
            timestamp=now_ms(),
          ),
        )
      }
    }
    _ => ()
  }
  out
}

///|
/// Render a slash command plus its options as `/name option:value …`.
pub fn discord_command_text(name : String, data : Json) -> String {
  let sb = StringBuilder()
  sb.write_string("/")
  sb.write_string(name)
  match json_field_array(data, "options") {
    Some(opts) =>
      for o in opts {
        sb.write_string(" ")
        sb.write_string(json_field_string(o, "name").unwrap_or(""))
        sb.write_string(":")
        match json_field_string(o, "value") {
          Some(v) => sb.write_string(v)
          None => sb.write_string("")
        }
      }
    None => ()
  }
  sb.to_string()
}

///|
/// Parse a normalized `MESSAGE_CREATE` payload (Discord gateway relay):
/// `{"t":"MESSAGE_CREATE","d":{"channel_id":…,"content":…,"author":{…},"id":…}}`
/// or a bare `d` object.
pub fn discord_parse_message_event(body : String) -> Array[MessageEvent] {
  let j = @json.parse(body) catch { _ => return [] }
  let d = match json_field_obj(j, "d") {
    Some(d) => d
    None => j
  }
  let author = json_field_obj(d, "author").unwrap_or(Json::null())
  let content = json_field_string(d, "content").unwrap_or("")
  let chat_id = json_id(d, "channel_id").unwrap_or("")
  if chat_id.is_empty() || content.is_empty() {
    return []
  }
  let mtype = if content.has_prefix("/") { Command } else { Text }
  [
    MessageEvent::new(
      content,
      mtype,
      Discord,
      chat_id,
      user_id?=json_id(author, "id"),
      user_name?=json_field_string(author, "username"),
      message_id?=json_field_string(d, "id"),
      media=[],
      timestamp=now_ms(),
    ),
  ]
}

///|
/// Normalized outbound webhook send (Discord webhook URL with `?wait=true`).
pub async fn discord_webhook_send(
  webhook_url : String,
  content : String,
  username? : String,
) -> SendResult {
  let payload = json_obj([("content", Json::string(content))])
  let payload = obj_with_opt(payload, "username", username)
  match post_json(webhook_url, payload, json_headers()) {
    Err(e) => discord_failure("discord webhook", e)
    Ok(j) => send_ok(discord_message_id(j), j)
  }
}
