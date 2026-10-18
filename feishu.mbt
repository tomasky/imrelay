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
/// Event-callback URL verification challenge. Runs on the *decrypted* body:
/// with an `encrypt_key` configured the `challenge` only exists inside the
/// encrypted payload.
pub fn feishu_challenge(body : String) -> String? {
  let j = @json.parse(body) catch { _ => return None }
  json_field_string(j, "challenge")
}

// --- Callback verification -------------------------------------------------
//
// Mirrors the official `lark-oapi` `EventDispatcherHandler` (and Hermes'
// webhook mode): the URL handshake token is checked, `X-Lark-Signature` is
// `sha256(timestamp + nonce + encrypt_key + raw_body)` (hex), and — when an
// `encrypt_key` is configured — every body arrives as `{"encrypt": "…"}`
// = base64(IV ‖ AES-256-CBC(SHA256(encrypt_key), IV, PKCS#7(JSON))).
// The challenge response itself is plain JSON.

///|
/// Callback verification token (`FEISHU_VERIFICATION_TOKEN` /
/// `[feishu.extra] verification_token`).
pub fn feishu_verification_token(cfg : PlatformConfig) -> String {
  cfg.extra_str("verification_token", "")
}

///|
/// Callback encrypt key (`FEISHU_ENCRYPT_KEY` / `[feishu.extra] encrypt_key`):
/// enables `X-Lark-Signature` verification and payload decryption.
pub fn feishu_encrypt_key(cfg : PlatformConfig) -> String {
  cfg.extra_str("encrypt_key", "")
}

///|
/// `X-Lark-Signature` value: `sha256(timestamp + nonce + encrypt_key + body)`,
/// lowercase hex.
pub fn feishu_signature(
  timestamp : String,
  nonce : String,
  encrypt_key : String,
  body : String,
) -> String {
  hex_encode(
    Bytes::from_array(
      @crypto.sha256(@utf8.encode("\{timestamp}\{nonce}\{encrypt_key}\{body}"))[:],
    ),
  )
}

///|
/// Constant-time `X-Lark-Signature` check.
pub fn feishu_verify_signature(
  encrypt_key : String,
  timestamp : String,
  nonce : String,
  body : String,
  signature : String,
) -> Bool {
  constant_time_eq(
    feishu_signature(timestamp, nonce, encrypt_key, body),
    signature,
  )
}

///|
/// AES key for Feishu payloads: `sha256(encrypt_key)` (32 bytes → AES-256).
pub fn feishu_aes_key(encrypt_key : String) -> Bytes {
  Bytes::from_array(@crypto.sha256(@utf8.encode(encrypt_key))[:])
}

///|
/// PKCS#7 pad to the 16-byte AES block boundary.
pub fn feishu_pkcs7_pad(data : Bytes) -> Bytes {
  let block = 16
  let pad_len = block - data.length() % block
  let out : Array[Byte] = []
  for i in 0..<data.length() {
    out.push(data.get(i).unwrap_or(byte_of_int(0)))
  }
  let b = byte_of_int(pad_len)
  for _ in 0..<pad_len {
    out.push(b)
  }
  Bytes::from_array(out[:])
}

///|
/// Strip 16-byte PKCS#7 padding; `None` when malformed.
pub fn feishu_pkcs7_unpad(data : Bytes) -> Bytes? {
  let n = data.length()
  if n == 0 {
    return None
  }
  let pad = data.get(n - 1).unwrap_or(byte_of_int(0)).to_int64().to_int()
  if pad < 1 || pad > 16 || n < pad {
    return None
  }
  for i in 0..<pad {
    if data.get(n - 1 - i).unwrap_or(byte_of_int(0)).to_int64().to_int() != pad {
      return None
    }
  }
  Some(data.exact_view(start=0, end=n - pad).to_owned())
}

///|
/// Decrypt one `encrypt` value back into the callback JSON (official
/// `AESCipher.decrypt_str`): base64 → IV is the first 16 bytes → AES-256-CBC
/// → PKCS#7 unpad → UTF-8. `None` on any malformed input.
pub fn feishu_decrypt_envelope(
  encrypt_key : String,
  encrypt : String,
) -> String? {
  let key = feishu_aes_key(encrypt_key)
  let data = @base64.decode(encrypt) catch { _ => return None }
  if data.length() < 32 || data.length() % 16 != 0 {
    return None
  }
  let plain = @crypto.aes_cbc_decrypt(
    key[:],
    data.exact_view(start=0, end=16),
    data.exact_view(start=16, end=data.length()),
  ) catch {
    _ => return None
  }
  let unpadded = match feishu_pkcs7_unpad(plain) {
    Some(d) => d
    None => return None
  }
  let text = @utf8.decode(unpadded[:]) catch { _ => return None }
  Some(text)
}

///|
/// Encrypt a plaintext into Feishu's `{"encrypt": "…"}` value (IV-prefixed
/// AES-256-CBC; used by tests and tools).
pub fn feishu_encrypt_message(
  encrypt_key : String,
  plaintext : String,
) -> String? {
  let key = feishu_aes_key(encrypt_key)
  let iv = random_bytes(16)
  let padded = feishu_pkcs7_pad(@utf8.encode(plaintext))
  let cipher = @crypto.aes_cbc_encrypt(key[:], iv[:], padded[:]) catch {
    _ => return None
  }
  let out : Array[Byte] = []
  for i in 0..<16 {
    out.push(iv.get(i).unwrap_or(byte_of_int(0)))
  }
  for i in 0..<cipher.length() {
    out.push(cipher.get(i).unwrap_or(byte_of_int(0)))
  }
  Some(@base64.encode(Bytes::from_array(out[:])))
}

///|
/// Verification token carried by a Feishu callback (`header.token` for
/// schema-2.0 events, top-level `token` for v1 events and the URL handshake).
pub fn feishu_body_token(body : String) -> String? {
  let j = @json.parse(body) catch { _ => return None }
  match json_field_obj(j, "header") {
    Some(h) =>
      match json_field_string(h, "token") {
        Some(t) => Some(t)
        None => json_field_string(j, "token")
      }
    None => json_field_string(j, "token")
  }
}

///|
/// Token check for a Feishu callback whose body has already been decrypted:
/// `(0, "")` when it may be processed. Fails closed while `verification_token`
/// is configured (missing or incorrect token → 401).
pub fn feishu_token_status(
  cfg : PlatformConfig,
  body : String,
) -> (Int32, String) {
  let expected = feishu_verification_token(cfg)
  if expected.is_empty() {
    return (0, "")
  }
  match feishu_body_token(body) {
    Some(t) =>
      if constant_time_eq(expected, t) {
        (0, "")
      } else {
        (401, "invalid Feishu verification token")
      }
    None => (401, "missing Feishu verification token")
  }
}

///|
/// Decrypt one inbound Feishu callback when `encrypt_key` is configured
/// (`{"encrypt": …}` → plaintext JSON); without a key bodies pass through
/// unchanged. Fails closed on a missing or undecryptable envelope.
pub fn feishu_unwrap_callback(
  cfg : PlatformConfig,
  raw : String,
) -> Result[String, String] {
  let key = feishu_encrypt_key(cfg)
  if key.is_empty() {
    return Ok(raw)
  }
  let j = @json.parse(raw) catch {
    _ => return Err("invalid JSON callback body")
  }
  match json_field_string(j, "encrypt") {
    Some(encrypt) =>
      match feishu_decrypt_envelope(key, encrypt) {
        Some(plain) => Ok(plain)
        None => Err("decryption failed (bad key, padding or ciphertext)")
      }
    None => Err("missing encrypt field (encrypt_key is configured)")
  }
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
