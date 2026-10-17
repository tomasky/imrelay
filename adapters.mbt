// Shared plumbing used by every platform adapter.
//
// Keeps the per-platform files small: header construction, `SendResult`
// mapping, config accessors and the chunked-send bookkeeping that all
// adapters share (Hermes `gateway/platforms/base.py` equivalents).

///|
/// `Content-Type: application/json` header map.
pub fn json_headers() -> Map[String, String] {
  let m : Map[String, String] = Map([])
  m.set("Content-Type", "application/json")
  m
}

///|
/// JSON headers plus `Authorization: Bearer <token>`.
pub fn bearer_headers(token : String) -> Map[String, String] {
  let m = json_headers()
  m.set("Authorization", "Bearer \{token}")
  m
}

///|
/// JSON headers plus `Authorization: Bot <token>` (Discord style).
pub fn bot_headers(token : String) -> Map[String, String] {
  let m = json_headers()
  m.set("Authorization", "Bot \{token}")
  m
}

///|
/// Human-readable message for an `ApiError` (negative code = transport error).
pub fn api_error_message(e : ApiError) -> String {
  if e.code < 0 {
    e.body
  } else {
    "HTTP \{e.code}: \{e.body}"
  }
}

///|
/// Map a failed HTTP exchange onto a classified `SendResult`.
pub fn send_failure(prefix : String, e : ApiError) -> SendResult {
  SendResult::failed(
    "\{prefix}: \{api_error_message(e)}",
    retryable=e.is_transient(),
    kind=classify_send_error(e.body),
  )
}

///|
/// Build a failure from a platform-level error string (HTTP 200 + error body).
pub fn send_body_failure(prefix : String, body : String) -> SendResult {
  SendResult::failed("\{prefix}: \{body}", kind=classify_send_error(body))
}

///|
/// `SendResult` for a missing credential.
pub fn missing_config(platform : Platform, what : String) -> SendResult {
  SendResult::failed("\{platform.value()}: missing \{what}", kind=Forbidden)
}

///|
/// Non-empty `token`, if configured.
pub fn PlatformConfig::token_of(self : PlatformConfig) -> String? {
  match self.token {
    Some(t) => if t.is_empty() { None } else { Some(t) }
    None => None
  }
}

///|
/// Non-empty `api_key`, if configured.
pub fn PlatformConfig::api_key_of(self : PlatformConfig) -> String? {
  match self.api_key {
    Some(k) => if k.is_empty() { None } else { Some(k) }
    None => None
  }
}

///|
/// Read a string from `[platform.extra]` (or the legacy flat section).
pub fn PlatformConfig::extra_str(
  self : PlatformConfig,
  key : String,
  default : String,
) -> String {
  self.extra.get(key).unwrap_or(default)
}

///|
/// Read an integer from `[platform.extra]`.
pub fn PlatformConfig::extra_int(
  self : PlatformConfig,
  key : String,
  default : Int32,
) -> Int32 {
  match self.extra.get(key) {
    Some(s) => @string.parse_int(s) catch { _ => default }
    None => default
  }
}

///|
/// Read a boolean from `[platform.extra]` (`true`/`1`/`yes`).
pub fn PlatformConfig::extra_bool(
  self : PlatformConfig,
  key : String,
  default : Bool,
) -> Bool {
  match self.extra.get(key) {
    Some(s) =>
      match s.to_lower() {
        "true" | "1" | "yes" | "on" => true
        "false" | "0" | "no" | "off" => false
        _ => default
      }
    None => default
  }
}

///|
/// First non-empty value among ``keys`` in `[platform.extra]`.
pub fn PlatformConfig::extra_first(
  self : PlatformConfig,
  keys : Array[String],
) -> String? {
  for k in keys {
    match self.extra.get(k) {
      Some(v) => if !v.is_empty() { return Some(v) }
      None => ()
    }
  }
  None
}

///|
/// Pull a nested object out of `result` (e.g. Telegram `{"ok":true,"result":{…}}`).
pub fn result_object(
  res : Result[Json, ApiError],
  prefix : String,
) -> Result[Json, SendResult] {
  match res {
    Err(e) => Err(send_failure(prefix, e))
    Ok(j) => Ok(j)
  }
}

///|
/// Success result carrying an optional platform message id and raw body.
pub fn send_ok(message_id : String?, raw : Json) -> SendResult {
  SendResult::ok(message_id?, raw=raw.stringify())
}

///|
/// `true` when ``s`` looks like a WhatsApp/Graph error payload.
pub fn graph_error_message(j : Json) -> String? {
  match json_field_obj(j, "error") {
    Some(e) =>
      match json_field_string(e, "message") {
        Some(m) => Some(m)
        None => Some(e.stringify())
      }
    None => None
  }
}

///|
/// Deliver ``text`` in platform-sized chunks, calling ``send_one`` per chunk
/// and stopping at the first failure. A successful single-chunk send returns
/// the chunk's `SendResult`; multi-chunk sends return the last success with
/// the first chunk's id preserved.
pub async fn send_chunks(
  text : String,
  max_len : Int32,
  send_one : async (String) -> SendResult,
) -> SendResult {
  let chunks = chunk_text(text, max_len)
  let mut last = SendResult::ok()
  let mut first_id : String? = None
  for c in chunks {
    let r = send_one(c)
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
/// Retry a send up to ``max_attempts`` times while the failure is transient
/// (Hermes `_send_with_retry`). Honours `retry_after` seconds when the
/// platform supplied one (e.g. Telegram 429 `parameters.retry_after`).
pub async fn send_with_retry(
  send_one : async () -> SendResult,
  max_attempts~ : Int32 = 3,
) -> SendResult {
  let mut attempt = 1
  let mut r = SendResult::ok()
  while attempt <= max_attempts {
    r = send_one()
    if r.success || !r.retryable {
      return r
    }
    let wait_ms = match r.retry_after {
      Some(s) => (s * 1000.0).to_int()
      None => 500 * attempt
    }
    @async.sleep(wait_ms)
    attempt = attempt + 1
  }
  r
}
