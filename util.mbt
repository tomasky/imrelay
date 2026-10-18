// Internal helpers shared by every adapter: JSON construction and accessors,
// message chunking (Hermes `truncate_message`), plain-text rendering, and the
// send-failure classifier (Hermes `classify_send_error`).

///|
/// Raised when a required field is missing or a send was refused.
pub suberror UtilsError {
  SendRefused(String)
  MissingConfig(String)
  InvalidArgument(String)
}

///|
/// Build a JSON object from explicit fields.
pub fn json_obj(fields : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for f in fields {
    m.set(f.0, f.1)
  }
  Json::object(m)
}

///|
/// Add ``key`` to ``obj`` only when ``value`` is `Some` (absent keys stay
/// absent — platforms reject `null` where a field must not exist).
pub fn obj_with_opt(obj : Json, key : String, value : String?) -> Json {
  match value {
    Some(s) => if obj is Object(m) { m.set(key, Json::string(s)) }
    None => ()
  }
  obj
}

///|
/// Read a string field from a JSON object.
pub fn json_field_string(obj : Json, key : String) -> String? {
  match obj {
    Object(m) =>
      match m.get(key) {
        Some(String(s)) => Some(s)
        _ => None
      }
    _ => None
  }
}

///|
/// Read a numeric field from a JSON object as `Int`.
pub fn json_field_int(obj : Json, key : String) -> Int32? {
  match obj {
    Object(m) =>
      match m.get(key) {
        Some(Number(n, ..)) => Some(n.to_int())
        Some(String(s)) => Some(@string.parse_int(s)) catch { _ => None }
        _ => None
      }
    _ => None
  }
}

///|
/// Read a large numeric field (epoch-milliseconds) as `Int64`.
pub fn json_field_int64(obj : Json, key : String) -> Int64? {
  match obj {
    Object(m) =>
      match m.get(key) {
        Some(Number(n, ..)) => Some(n.to_int64())
        _ => None
      }
    _ => None
  }
}

///|
/// Read a boolean field from a JSON object.
pub fn json_field_bool(obj : Json, key : String) -> Bool? {
  match obj {
    Object(m) =>
      match m.get(key) {
        Some(True) => Some(true)
        Some(False) => Some(false)
        _ => None
      }
    _ => None
  }
}

///|
/// Read a nested object field.
pub fn json_field_obj(obj : Json, key : String) -> Json? {
  match obj {
    Object(m) =>
      match m.get(key) {
        Some(Object(_) as o) => Some(o)
        _ => None
      }
    _ => None
  }
}

///|
/// Read an array field.
pub fn json_field_array(obj : Json, key : String) -> Array[Json]? {
  match obj {
    Object(m) =>
      match m.get(key) {
        Some(Array(a)) => Some(a)
        _ => None
      }
    _ => None
  }
}

///|
/// Read a string-or-number field as a string id (platform payloads often mix
/// the two, e.g. Telegram `chat.id`).
pub fn json_id(obj : Json, key : String) -> String? {
  match obj {
    Object(m) =>
      match m.get(key) {
        Some(String(s)) => Some(s)
        Some(Number(n, ..)) =>
          if n == n.to_int().to_double() {
            Some(n.to_int().to_string())
          } else {
            Some(n.to_string())
          }
        _ => None
      }
    _ => None
  }
}

///|
/// Split ``text`` into chunks no longer than ``max_len`` characters, breaking
/// on paragraph (blank-line) boundaries first, then on character boundaries.
/// Returns at least one chunk even when the input is empty.
pub fn chunk_text(text : String, max_len : Int32) -> Array[String] {
  if max_len <= 0 {
    return [text]
  }
  if text.length() <= max_len {
    return [text]
  }
  let out : Array[String] = []
  for para in text.split("\n\n") {
    let p = para.to_owned()
    if p.is_empty() {
      continue
    }
    if p.length() <= max_len {
      out.push(p)
      continue
    }
    let sb = StringBuilder()
    let mut n = 0
    for ch in p {
      if n >= max_len {
        out.push(sb.to_string())
        sb.reset()
        n = 0
      }
      sb.write_char(ch)
      n = n + 1
    }
    if n > 0 {
      out.push(sb.to_string())
    }
  }
  if out.is_empty() {
    out.push("")
  }
  out
}

///|
/// Truncate ``text`` to at most ``max`` characters, appending ``suffix`` when
/// it was cut (Hermes `_truncate_preview`).
pub fn truncate(text : String, max : Int32, suffix~ : String = "...") -> String {
  if text.length() <= max {
    text
  } else {
    "\{text[:max].to_owned()}\{suffix}"
  }
}

///|
/// Strip common markdown to a platform-safe plain-text rendering. Used by
/// text-only adapters (DingTalk fallback, email, WeCom, WhatsApp body, ...).
pub fn strip_markdown(text : String) -> String {
  let s = text
    .replace_all(old="```", new="")
    .replace_all(old="**", new="")
    .replace_all(old="__", new="")
    .replace_all(old="`", new="")
    .replace_all(old="*", new="")
    .replace_all(old="#", new="")
  s
}

///|
/// Hermes' `SEND_ERROR_KINDS` classifier: map an error string onto a
/// platform-neutral kind. Substring table mirrors `gateway/platforms/base.py`
/// (`_SEND_ERROR_CLASSIFIERS`) so classified failures read identically.
pub fn classify_send_error(msg : String) -> SendErrorKind {
  let blob = msg.to_lower()
  if any_substring(blob, ["message_too_long", "too long", "message is too long"]) {
    return TooLong
  }
  if any_substring(blob, [
      "can't parse entities", "cant parse entities", "can't find end", "unsupported start tag",
    ]) ||
    (blob.contains("entity") && blob.contains("parse")) ||
    (blob.contains("bad request") && blob.contains("entit")) {
    return BadFormat
  }
  if any_substring(blob, [
      "forbidden", "bot was blocked", "blocked by the user", "user is deactivated",
      "not enough rights", "have no rights", "not a member",
    ]) {
    return Forbidden
  }
  if any_substring(blob, chat_level_not_found_needles()) ||
    any_substring(blob, subchat_not_found_needles()) {
    return NotFound
  }
  if any_substring(blob, [
      "flood", "too many requests", "retry after", "rate limit",
    ]) {
    return RateLimited
  }
  if any_substring(blob, [
      "connecterror", "connectionerror", "connectionreset", "connectionrefused",
      "connecttimeout", "network", "broken pipe", "remotedisconnected", "eoferror",
    ]) ||
    blob.contains("connecttimeout") {
    return Transient
  }
  Unknown
}

///|
/// `true` when at least one of ``needles`` occurs in ``blob``.
fn any_substring(blob : String, needles : Array[String]) -> Bool {
  for n in needles {
    if blob.contains(n) {
      return true
    }
  }
  false
}

///|
/// `not_found` markers that mean the whole chat is gone.
fn chat_level_not_found_needles() -> Array[String] {
  ["chat not found"]
}

///|
/// `not_found` markers that leave the parent chat reachable.
fn subchat_not_found_needles() -> Array[String] {
  [
    "message to edit not found", "message to reply not found", "thread not found",
    "topic_deleted", "message_id_invalid",
  ]
}

///|
/// Hermes' `is_chat_level_not_found`: whether a `not_found` failure means the
/// *whole chat* is gone (only that marks a target dead; a deleted topic or an
/// edited-away message leaves the parent chat reachable). When both kinds of
/// marker are present the sub-chat reading wins.
pub fn is_chat_level_not_found(msg : String) -> Bool {
  let blob = msg.to_lower()
  !any_substring(blob, subchat_not_found_needles()) &&
  any_substring(blob, chat_level_not_found_needles())
}

///|
/// Random lowercase-hex string of ``len`` digits (transaction ids, uuids).
pub fn random_hex(len : Int32) -> String {
  let hexchars = "0123456789abcdef"
  let rand = @random.Rand()
  let sb = StringBuilder()
  for _ in 0..<len {
    let n = rand.int(limit=16)
    sb.write_string(hexchars[n:n + 1].to_owned())
  }
  sb.to_string()
}

///|
/// Percent-encode a URL query component (RFC 3986, uppercase hex) — the same
/// encoding Hermes applies with `urllib.parse.quote`.
pub fn url_quote(s : String) -> String {
  @percent.encode(s)
}

///|
/// Current epoch time in milliseconds.
pub fn now_ms() -> Int64 {
  @env.now().reinterpret_as_int64()
}

///|
/// First present of two optional strings (`a` when it is `Some`).
pub fn or_opt(a : String?, b : String?) -> String? {
  match a {
    Some(_) => a
    None => b
  }
}

///|
/// Byte from an int (0..255) — MoonBit has no `Byte::from_int` and int-literal
/// method chains parse as floats.
pub fn byte_of_int(n : Int32) -> Byte {
  n.to_int64().to_byte()
}

///|
/// Lowercase hex encoding of raw bytes.
pub fn hex_encode(data : BytesView) -> String {
  let hex = "0123456789abcdef"
  let sb = StringBuilder()
  for i in 0..<data.length() {
    let v = data.at(i).to_int64().to_int()
    let a = v >> 4
    let b = v & 15
    sb.write_string(hex[a:a + 1].to_owned())
    sb.write_string(hex[b:b + 1].to_owned())
  }
  sb.to_string()
}

///|
/// Decode a lowercase/uppercase hex string into bytes; `None` on malformed
/// input (odd length or non-hex digit).
pub fn hex_decode(s : String) -> Bytes? {
  if s.length() % 2 != 0 {
    return None
  }
  let out : Array[Byte] = []
  let mut i = 0
  while i < s.length() {
    let hi = Some(@string.parse_int(s[i:i + 1].to_owned(), base=16)) catch {
      _ => None
    }
    let lo = Some(@string.parse_int(s[i + 1:i + 2].to_owned(), base=16)) catch {
      _ => None
    }
    match (hi, lo) {
      (Some(h), Some(l)) => out.push(byte_of_int(h * 16 + l))
      _ => return None
    }
    i += 2
  }
  Some(Bytes::from_array(out[:]))
}

///|
/// Cryptographically-ish random bytes via `random_hex` (transaction ids).
pub fn random_bytes(len : Int32) -> Bytes {
  match hex_decode(random_hex(len * 2)) {
    Some(b) => b
    None => Bytes::new(len)
  }
}

///|
/// Lowercase hex MD5 digest (WeChat/WeCom media fingerprints).
pub fn md5_hex(data : BytesView) -> String {
  hex_encode(Bytes::from_array(@crypto.md5(data)[:]))
}

///|
/// Lowercase hex HMAC-SHA256 of ``data`` under ``secret`` (Slack/WhatsApp
/// webhook signatures).
pub fn hmac_sha256_hex(secret : String, data : String) -> String {
  let mac = @crypto.hmac(
    @crypto.SHA256::new(),
    @utf8.encode(secret)[:],
    @utf8.encode(data)[:],
  )
  hex_lower(mac[:])
}

///|
/// Write one log line to stderr, flushed immediately. Logs must not share
/// stdout with protocol output (the `moon test` driver parses test results
/// from stdout), and stderr is unbuffered even when stdout is a pipe.
pub async fn log_line(line : String) -> Unit {
  @stdio.stderr.write("\{line}\n") catch {
    _ => ()
  }
}

///|
/// Constant-time string comparison (no early exit; length differences are
/// absorbed into the accumulated difference).
pub fn constant_time_eq(a : String, b : String) -> Bool {
  let n = if a.length() > b.length() { a.length() } else { b.length() }
  let mut diff = if a.length() == b.length() { 0 } else { 1 }
  for i in 0..<n {
    let x = if i < a.length() { a.code_unit_at(i).to_int() } else { 0 }
    let y = if i < b.length() { b.code_unit_at(i).to_int() } else { 0 }
    diff = diff | (x ^ y)
  }
  diff == 0
}

///|
/// `data:` URL carrying the attachment bytes inline — the MoonBit
/// equivalent of Hermes' cached media paths for self-contained events.
pub fn data_url(mime : String, data : Bytes) -> String {
  "data:\{mime};base64,\{@base64.encode(data)}"
}
