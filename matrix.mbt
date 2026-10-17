// Matrix Client-Server API adapter.
//
// Mirrors Hermes `plugins/platforms/matrix/adapter.py`: messages are sent with
// `PUT /_matrix/client/v3/rooms/{roomId}/send/m.room.message/{txnId}`, replies
// use `m.relates_to`, and inbound traffic is consumed from `/sync` timelines.
// Access is via `MATRIX_ACCESS_TOKEN`, or `MATRIX_PASSWORD` login when no
// token is configured.

///|
/// Cached access tokens keyed by `homeserver|user`.
let matrix_token_cache : Map[String, String] = Map([])

///|
/// Cached `@user:server` ids for typing indicators.
let matrix_user_cache : Map[String, String] = Map([])

///|
/// Homeserver base URL (`MATRIX_HOMESERVER`), without a trailing slash.
pub fn matrix_homeserver(cfg : PlatformConfig) -> String {
  let url = cfg.extra_str("homeserver", "")
  if url.has_suffix("/") {
    url[:url.length() - 1].to_owned()
  } else {
    url
  }
}

///|
/// `/_matrix/client/v3` root.
pub fn matrix_api_base(cfg : PlatformConfig) -> String {
  "\{matrix_homeserver(cfg)}/_matrix/client/v3"
}

///|
/// `PUT …/send/m.room.message/{txnId}` payload.
pub fn matrix_send_payload(body : String, reply_to : String?) -> Json {
  let payload = json_obj([
    ("msgtype", Json::string("m.text")),
    ("body", Json::string(body)),
  ])
  match reply_to {
    Some(mid) =>
      if payload is Object(m) {
        m.set(
          "m.relates_to",
          json_obj([
            ("m.in_reply_to", json_obj([("event_id", Json::string(mid))])),
          ]),
        )
      }
    None => ()
  }
  payload
}

///|
/// `m.replace` edit payload.
pub fn matrix_edit_payload(new_text : String, message_id : String) -> Json {
  json_obj([
    ("msgtype", Json::string("m.text")),
    ("body", Json::string("* \{new_text}")),
    (
      "m.new_content",
      json_obj([
        ("msgtype", Json::string("m.text")),
        ("body", Json::string(new_text)),
      ]),
    ),
    (
      "m.relates_to",
      json_obj([
        ("rel_type", Json::string("m.replace")),
        ("event_id", Json::string(message_id)),
      ]),
    ),
  ])
}

///|
/// `m.annotation` reaction payload.
pub fn matrix_reaction_payload(message_id : String, emoji : String) -> Json {
  json_obj([
    (
      "m.relates_to",
      json_obj([
        ("rel_type", Json::string("m.annotation")),
        ("event_id", Json::string(message_id)),
        ("key", Json::string(emoji)),
      ]),
    ),
  ])
}

///|
/// `Authorization: Bearer` headers for Matrix.
pub fn matrix_headers(token : String) -> Map[String, String] {
  bearer_headers(token)
}

///|
/// Log in with `MATRIX_USER_ID` + `MATRIX_PASSWORD` and cache the token.
async fn matrix_login(cfg : PlatformConfig) -> String? {
  let user = cfg.extra_str("user_id", "")
  let password = cfg.extra_str("password", "")
  if user.is_empty() || password.is_empty() || matrix_homeserver(cfg).is_empty() {
    return None
  }
  let body = json_obj([
    ("type", Json::string("m.login.password")),
    (
      "identifier",
      json_obj([
        ("type", Json::string("m.id.user")),
        ("user", Json::string(user)),
      ]),
    ),
    ("password", Json::string(password)),
  ])
  let url = "\{matrix_api_base(cfg)}/login"
  match post_json(url, body, json_headers()) {
    Err(_) => None
    Ok(j) =>
      match json_field_string(j, "access_token") {
        Some(token) => {
          matrix_token_cache.set("\{matrix_homeserver(cfg)}|\{user}", token)
          match json_field_string(j, "user_id") {
            Some(uid) => matrix_user_cache.set(matrix_homeserver(cfg), uid)
            None => ()
          }
          Some(token)
        }
        None => None
      }
  }
}

///|
/// Resolve the access token, logging in when only a password is configured.
pub async fn matrix_resolve_token(cfg : PlatformConfig) -> String? {
  match cfg.token_of() {
    Some(t) => Some(t)
    None => {
      let user = cfg.extra_str("user_id", "")
      let key = "\{matrix_homeserver(cfg)}|\{user}"
      match matrix_token_cache.get(key) {
        Some(t) => Some(t)
        None => matrix_login(cfg)
      }
    }
  }
}

///|
/// The bot's own `@user:server` id — from the login/typing cache or
/// `/account/whoami`, falling back to the configured `user_id`.
pub async fn matrix_self_user(cfg : PlatformConfig, token : String) -> String {
  let key = matrix_homeserver(cfg)
  match matrix_user_cache.get(key) {
    Some(u) => u
    None => {
      let url = "\{matrix_api_base(cfg)}/account/whoami"
      match get_json(url, matrix_headers(token)) {
        Ok(j) =>
          match json_field_string(j, "user_id") {
            Some(u) => {
              matrix_user_cache.set(key, u)
              u
            }
            None => cfg.extra_str("user_id", "")
          }
        Err(_) => cfg.extra_str("user_id", "")
      }
    }
  }
}

///|
/// `GET /_matrix/client/v3/sync`, long-polling for up to ``timeout_ms``.
pub async fn matrix_sync(
  cfg : PlatformConfig,
  token : String,
  since : String,
  timeout_ms : Int32,
) -> Result[Json, ApiError] {
  let mut url = "\{matrix_api_base(cfg)}/sync?timeout=\{timeout_ms}"
  if !since.is_empty() {
    url = "\{url}&since=\{url_quote(since)}"
  }
  get_json(url, matrix_headers(token))
}

///|
/// One Matrix call; PUT/POST JSON and map errors.
async fn matrix_call(
  cfg : PlatformConfig,
  token : String,
  meth : String,
  path : String,
  payload : Json,
) -> SendResult {
  let url = "\{matrix_api_base(cfg)}\{path}"
  let res = match meth {
    "PUT" => put_json(url, payload, matrix_headers(token))
    "POST" => post_json(url, payload, matrix_headers(token))
    _ => get_json(url, matrix_headers(token))
  }
  match res {
    Err(e) => send_failure("matrix", e)
    Ok(j) => send_ok(json_field_string(j, "event_id"), j)
  }
}

///|
/// Send ``content`` to a room, chunked at Matrix's 60000-char limit.
pub async fn matrix_send(
  cfg : PlatformConfig,
  chat_id : String,
  content : String,
  reply_to? : String,
  thread_id? : String,
) -> SendResult {
  ignore(thread_id)
  matrix_send_with_token(cfg, chat_id, content, reply_to)
}

///|
async fn matrix_send_with_token(
  cfg : PlatformConfig,
  chat_id : String,
  content : String,
  reply_to : String?,
) -> SendResult {
  match matrix_resolve_token(cfg) {
    None => missing_config(Matrix, "MATRIX_ACCESS_TOKEN")
    Some(token) =>
      if content.is_empty() {
        return SendResult::ok()
      } else {
        let room = url_quote(chat_id)
        let mut first = true
        let mut last = SendResult::ok()
        let mut first_id : String? = None
        for chunk in chunk_text(content, Platform::max_message_length(Matrix)) {
          let reply = if first { reply_to } else { None }
          let txn = random_hex(16)
          let r = matrix_call(
            cfg,
            token,
            "PUT",
            "/rooms/\{room}/send/m.room.message/\{txn}",
            matrix_send_payload(chunk, reply),
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
/// Typing indicator (`PUT /rooms/{room}/typing/{userId}`).
pub async fn matrix_typing(cfg : PlatformConfig, chat_id : String) -> Unit {
  match matrix_resolve_token(cfg) {
    None => ()
    Some(token) => {
      let key = matrix_homeserver(cfg)
      let user = match matrix_user_cache.get(key) {
        Some(u) => u
        None => {
          let url = "\{matrix_api_base(cfg)}/account/whoami"
          match get_json(url, matrix_headers(token)) {
            Ok(j) =>
              match json_field_string(j, "user_id") {
                Some(u) => {
                  matrix_user_cache.set(key, u)
                  u
                }
                None => ""
              }
            Err(_) => ""
          }
        }
      }
      if user.is_empty() {
        return
      }
      let payload = json_obj([
        ("typing", Json::boolean(true)),
        ("timeout", Json::number(30000.0)),
      ])
      ignore(
        matrix_call(
          cfg,
          token,
          "PUT",
          "/rooms/\{url_quote(chat_id)}/typing/\{url_quote(user)}",
          payload,
        ),
      )
    }
  }
}

///|
/// Edit a message with `m.replace`.
pub async fn matrix_edit(
  cfg : PlatformConfig,
  chat_id : String,
  message_id : String,
  content : String,
) -> SendResult {
  match matrix_resolve_token(cfg) {
    None => missing_config(Matrix, "MATRIX_ACCESS_TOKEN")
    Some(token) =>
      matrix_call(
        cfg,
        token,
        "PUT",
        "/rooms/\{url_quote(chat_id)}/send/m.room.message/\{random_hex(16)}",
        matrix_edit_payload(content, message_id),
      )
  }
}

///|
/// React with `m.annotation`.
pub async fn matrix_react(
  cfg : PlatformConfig,
  chat_id : String,
  message_id : String,
  emoji : String,
) -> SendResult {
  match matrix_resolve_token(cfg) {
    None => missing_config(Matrix, "MATRIX_ACCESS_TOKEN")
    Some(token) =>
      matrix_call(
        cfg,
        token,
        "PUT",
        "/rooms/\{url_quote(chat_id)}/send/m.reaction/\{random_hex(16)}",
        matrix_reaction_payload(message_id, emoji),
      )
  }
}

///|
/// Room name via `GET /rooms/{roomId}/state/m.room.name`.
pub async fn matrix_get_chat(
  cfg : PlatformConfig,
  chat_id : String,
) -> ChatInfo? {
  match matrix_resolve_token(cfg) {
    None => None
    Some(token) => {
      let url = "\{matrix_api_base(cfg)}/rooms/\{url_quote(chat_id)}/state/m.room.name"
      match get_json(url, matrix_headers(token)) {
        Err(_) => None
        Ok(j) =>
          Some({
            name: json_field_string(j, "name").unwrap_or(chat_id),
            chat_type: "room",
            chat_id,
          })
      }
    }
  }
}

///|
/// Parse a `/sync` response (or a bare timeline) into message events.
/// The caller's own user id (``self_user``) is echoed out.
pub fn matrix_parse_sync(
  body : String,
  self_user? : String,
) -> Array[MessageEvent] {
  let out : Array[MessageEvent] = []
  let j = @json.parse(body) catch { _ => return out }
  let rooms = json_field_obj(j, "rooms").unwrap_or(Json::null())
  let joined = json_field_obj(rooms, "join").unwrap_or(Json::null())
  match joined {
    Object(m) =>
      for room_id, room in m {
        let timeline = json_field_obj(room, "timeline").unwrap_or(Json::null())
        for ev in json_field_array(timeline, "events").unwrap_or([]) {
          match matrix_parse_event(room_id, ev, self_user?) {
            Some(e) => out.push(e)
            None => ()
          }
        }
      }
    _ => ()
  }
  out
}

///|
/// Convert one room event into a `MessageEvent`.
pub fn matrix_parse_event(
  room_id : String,
  ev : Json,
  self_user? : String,
) -> MessageEvent? {
  if json_field_string(ev, "type").unwrap_or("") != "m.room.message" {
    return None
  }
  let sender = json_field_string(ev, "sender").unwrap_or("")
  match self_user {
    Some(u) => if u == sender { return None }
    None => ()
  }
  let content = json_field_obj(ev, "content").unwrap_or(Json::null())
  let text = json_field_string(content, "body").unwrap_or("")
  if text.is_empty() {
    return None
  }
  let reply = match json_field_obj(content, "m.relates_to") {
    Some(r) => json_field_string(r, "event_id")
    None => None
  }
  let mtype = if text.has_prefix("/") { Command } else { Text }
  Some(
    MessageEvent::new(
      text,
      mtype,
      Matrix,
      room_id,
      user_id=sender,
      message_id?=json_field_string(ev, "event_id"),
      reply_to_message_id?=reply,
      media=[],
      timestamp=now_ms(),
    ),
  )
}
