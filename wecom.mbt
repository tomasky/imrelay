// WeCom (Enterprise WeChat) adapter.
//
// Mirrors Hermes `plugins/platforms/wecom/adapter.py`: an access token is
// fetched from `cgi-bin/gettoken`, application messages go through
// `cgi-bin/message/send` (markdown for rich text), and inbound traffic arrives
// as a callback body — either the classic encrypted XML envelope (decrypted
// in-gateway when `encoding_aes_key` is configured, relay-decrypted otherwise)
// or the newer JSON `aibot` shape.

///|
/// API root, overridable with `[wecom.extra] api_base`.
pub fn wecom_api_base(cfg : PlatformConfig) -> String {
  let base = cfg.extra_str("api_base", "https://qyapi.weixin.qq.com")
  if base.has_suffix("/") {
    base[:base.length() - 1].to_owned()
  } else {
    base
  }
}

///|
/// Corp id (`WECOM_CALLBACK_CORP_ID`).
pub fn wecom_corp_id(cfg : PlatformConfig) -> String {
  cfg.extra_str("corp_id", "")
}

///|
/// Corp secret (`WECOM_CALLBACK_CORP_SECRET`), also accepted as `token`.
pub fn wecom_corp_secret(cfg : PlatformConfig) -> String? {
  match cfg.extra_first(["corp_secret"]) {
    Some(s) => Some(s)
    None => cfg.token_of()
  }
}

///|
/// Agent id (`agentid`) required by `message/send`.
pub fn wecom_agent_id(cfg : PlatformConfig) -> Int32? {
  match cfg.extra_first(["agent_id", "agentid"]) {
    Some(s) => Some(@string.parse_int(s)) catch { _ => None }
    None => None
  }
}

///|
/// Callback token used to build/check `msg_signature`
/// (`WECOM_CALLBACK_TOKEN` / `[wecom.extra] callback_token`).
pub fn wecom_callback_token(cfg : PlatformConfig) -> String {
  cfg.extra_str("callback_token", "")
}

///|
/// Callback encryption key (`WECOM_CALLBACK_ENCODING_AES_KEY` /
/// `[wecom.extra] encoding_aes_key`): 43 base64 characters decoding to 32 AES
/// key bytes (the first 16 of which double as the CBC IV).
pub fn wecom_encoding_aes_key(cfg : PlatformConfig) -> String {
  cfg.extra_str("encoding_aes_key", "")
}

///|
/// Cached access tokens keyed by corp id.
let wecom_token_cache : Map[String, String] = Map([])

///|
/// Fetch (and cache) a WeCom access token.
pub async fn wecom_access_token(cfg : PlatformConfig) -> String? {
  let corp = wecom_corp_id(cfg)
  let secret = match wecom_corp_secret(cfg) {
    Some(s) => s
    None => return None
  }
  if corp.is_empty() {
    return None
  }
  match wecom_token_cache.get(corp) {
    Some(t) => return Some(t)
    None => ()
  }
  let url = "\{wecom_api_base(cfg)}/cgi-bin/gettoken?corpid=\{url_quote(corp)}&corpsecret=\{url_quote(secret)}"
  match get_json(url, json_headers()) {
    Err(_) => None
    Ok(j) =>
      match json_field_string(j, "access_token") {
        Some(t) => {
          wecom_token_cache.set(corp, t)
          Some(t)
        }
        None => None
      }
  }
}

///|
/// `message/send` payload.
pub fn wecom_send_payload(
  to : String,
  content : String,
  agent_id : Int32?,
  markdown : Bool,
) -> Json {
  let payload = json_obj([
    ("touser", Json::string(to)),
    ("msgtype", Json::string(if markdown { "markdown" } else { "text" })),
  ])
  let payload = if markdown {
    if payload is Object(m) {
      m.set("markdown", json_obj([("content", Json::string(content))]))
    }
    payload
  } else {
    if payload is Object(m) {
      m.set("text", json_obj([("content", Json::string(content))]))
    }
    payload
  }
  match agent_id {
    Some(a) =>
      if payload is Object(m) {
        m.set("agentid", Json::number(a.to_double()))
        m.set("safe", Json::number(0.0))
      }
    None => ()
  }
  payload
}

///|
/// Map a WeCom `{errcode, errmsg}` response onto a `SendResult`.
fn wecom_result(j : Json) -> SendResult {
  match json_field_int(j, "errcode") {
    Some(0) => send_ok(None, j)
    Some(code) => {
      let msg = json_field_string(j, "errmsg").unwrap_or(j.stringify())
      SendResult::failed(
        "wecom: \{msg} (code \{code})",
        retryable=code == 45009 || code == -1,
        kind=classify_send_error(msg),
        raw=j.stringify(),
      )
    }
    None => send_ok(None, j)
  }
}

///|
/// Send ``content`` to a user or party (`@all` for everyone).
pub async fn wecom_send(
  cfg : PlatformConfig,
  chat_id : String,
  content : String,
  reply_to? : String,
) -> SendResult {
  ignore(reply_to)
  match wecom_access_token(cfg) {
    None =>
      missing_config(
        Wecom,
        "WECOM_CALLBACK_CORP_ID / WECOM_CALLBACK_CORP_SECRET",
      )
    Some(token) =>
      if content.is_empty() {
        return SendResult::ok()
      } else {
        let url = "\{wecom_api_base(cfg)}/cgi-bin/message/send?access_token=\{url_quote(token)}"
        let markdown = cfg.extra_bool("markdown", true)
        let agent = wecom_agent_id(cfg)
        let mut last = SendResult::ok()
        for chunk in chunk_text(content, Platform::max_message_length(Wecom)) {
          let body = wecom_send_payload(chat_id, chunk, agent, markdown)
          let r = send_with_retry(() => {
            match post_json(url, body, json_headers()) {
              Err(e) => send_failure("wecom", e)
              Ok(j) => wecom_result(j)
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
/// Extract the text of the first ``tag`` element in an XML document.
pub fn xml_text(xml : String, tag : String) -> String? {
  let open = "<\{tag}>"
  let close = "</\{tag}>"
  match xml.find(open) {
    Some(i) => {
      let rest = xml[i + open.length():].to_owned()
      match rest.find(close) {
        Some(j) => Some(strip_cdata(rest[:j].to_owned()))
        None => None
      }
    }
    None => None
  }
}

///|
/// Strip a surrounding `<![CDATA[ … ]]>` wrapper.
pub fn strip_cdata(s : String) -> String {
  let t = if s.has_prefix("<![CDATA[") { s[9:].to_owned() } else { s }
  if t.has_suffix("]]>") {
    t[:t.length() - 3].to_owned()
  } else {
    t
  }
}

///|
/// Parse a WeCom callback (classic XML or the newer JSON `aibot` shape).
pub fn wecom_parse_callback(body : String) -> Array[MessageEvent] {
  let out : Array[MessageEvent] = []
  if body.has_prefix("{") {
    let j = @json.parse(body) catch { _ => return out }
    let chat_id = or_opt(json_id(j, "chatid"), json_field_string(j, "from"))
    let chat_id = match chat_id {
      Some(c) => c
      None =>
        match json_field_obj(j, "from") {
          Some(f) => json_id(f, "userid").unwrap_or("")
          None => ""
        }
    }
    if chat_id.is_empty() {
      return out
    }
    let text = match json_field_obj(j, "text") {
      Some(t) => json_field_string(t, "content").unwrap_or("")
      None => json_field_string(j, "content").unwrap_or("")
    }
    let mtype = if text.has_prefix("/") { Command } else { Text }
    out.push(
      MessageEvent::new(
        text,
        mtype,
        Wecom,
        chat_id,
        user_id?=json_field_string(j, "from"),
        message_id?=json_field_string(j, "msgid"),
        media=[],
        timestamp=now_ms(),
      ),
    )
    return out
  }
  let from = xml_text(body, "FromUserName").unwrap_or("")
  if from.is_empty() {
    return out
  }
  let chat_id = match xml_text(body, "ChatId") {
    Some(c) => if c.is_empty() { from } else { c }
    None => from
  }
  let text = or_opt(xml_text(body, "Content"), xml_text(body, "Recognition")).unwrap_or(
    "",
  )
  let mtype = if text.has_prefix("/") { Command } else { Text }
  out.push(
    MessageEvent::new(
      text,
      mtype,
      Wecom,
      chat_id,
      user_id=from,
      message_id?=xml_text(body, "MsgId"),
      media=[],
      timestamp=now_ms(),
    ),
  )
  out
}

// ---------------------------------------------------------------------------
// Callback crypto: `msg_signature` + AES-256-CBC, parity with Hermes
// `plugins/platforms/wecom/wecom_crypto.py` (Tencent's official
// `WXBizMsgCrypt`).

///|
/// Query parameters of a WeCom callback request (percent-decoded); the GET
/// URL-verification handshake additionally carries `echostr`.
pub(all) struct WecomCallbackParams {
  msg_signature : String
  timestamp : String
  nonce : String
  echostr : String?
}

///|
/// Parse `msg_signature` / `timestamp` / `nonce` / `echostr` from a callback
/// path's query string.
pub fn wecom_callback_params(path : String) -> WecomCallbackParams {
  let query = match path.split_once("?") {
    Some((_, q)) => q.to_owned()
    None => ""
  }
  let echostr = match query_param(query, "echostr") {
    Some(e) => if e.is_empty() { None } else { Some(e) }
    None => None
  }
  {
    msg_signature: query_param(query, "msg_signature").unwrap_or(""),
    timestamp: query_param(query, "timestamp").unwrap_or(""),
    nonce: query_param(query, "nonce").unwrap_or(""),
    echostr,
  }
}

///|
/// Raw AES key bytes from the 43-char `encoding_aes_key` (Hermes appends `=`
/// before base64-decoding). `None` unless exactly 32 bytes come out.
pub fn wecom_aes_key(encoding_aes_key : String) -> Bytes? {
  let decoded = @base64.decode("\{encoding_aes_key}=") catch {
    _ => return None
  }
  if decoded.length() == 32 {
    Some(decoded)
  } else {
    None
  }
}

///|
/// PKCS#7 pad to the 32-byte WeCom block boundary (Hermes `PKCS7Encoder`).
/// A payload already aligned to 32 still gains a full block.
pub fn wecom_pkcs7_pad(data : Bytes) -> Bytes {
  let block = 32
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
/// Strip 32-byte PKCS#7 padding; `None` when malformed (Hermes
/// `PKCS7Encoder.decode`).
pub fn wecom_pkcs7_unpad(data : Bytes) -> Bytes? {
  let n = data.length()
  if n == 0 {
    return None
  }
  let pad = data.get(n - 1).unwrap_or(byte_of_int(0)).to_int64().to_int()
  if pad < 1 || pad > 32 || n < pad {
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
/// Byte value of `data[i]` as `Int` (out-of-range reads as 0).
fn wecom_byte_at(data : Bytes, i : Int32) -> Int32 {
  data.get(i).unwrap_or(byte_of_int(0)).to_int64().to_int()
}

///|
/// WeCom callback signature (Hermes `_sha1_signature`): SHA1 over the four
/// parts sorted lexicographically and concatenated, lowercase hex.
pub fn wecom_msg_signature(
  token : String,
  timestamp : String,
  nonce : String,
  encrypt : String,
) -> String {
  let parts = [token, timestamp, nonce, encrypt]
  parts.sort_by(fn(a, b) { a.lexical_compare(b) })
  hex_encode(Bytes::from_array(@crypto.sha1(@utf8.encode(parts.join("")))[:]))
}

///|
/// Constant-time `msg_signature` check.
pub fn wecom_verify_msg_signature(
  token : String,
  timestamp : String,
  nonce : String,
  encrypt : String,
  msg_signature : String,
) -> Bool {
  constant_time_eq(
    wecom_msg_signature(token, timestamp, nonce, encrypt),
    msg_signature,
  )
}

///|
/// Decrypt one encrypted WeCom envelope (Hermes `WXBizMsgCrypt.decrypt`
/// without the signature step): base64 → AES-256-CBC (IV = first 16 key
/// bytes) → strip 32-byte PKCS#7 → skip the 16-byte random prefix → 4-byte
/// big-endian length → message → the trailing `receive_id` must match.
/// `None` on any malformed input or mismatch.
pub fn wecom_decrypt_envelope(
  encoding_aes_key : String,
  receive_id : String,
  encrypt : String,
) -> String? {
  let key = match wecom_aes_key(encoding_aes_key) {
    Some(k) => k
    None => return None
  }
  let cipher = @base64.decode(encrypt) catch { _ => return None }
  let plain = @crypto.aes_cbc_decrypt(
    key[:],
    key.exact_view(start=0, end=16),
    cipher[:],
  ) catch {
    _ => return None
  }
  let unpadded = match wecom_pkcs7_unpad(plain) {
    Some(d) => d
    None => return None
  }
  if unpadded.length() < 20 {
    return None
  }
  let msg_len = (wecom_byte_at(unpadded, 16) << 24) |
    (wecom_byte_at(unpadded, 17) << 16) |
    (wecom_byte_at(unpadded, 18) << 8) |
    wecom_byte_at(unpadded, 19)
  if msg_len < 0 || 20 + msg_len > unpadded.length() {
    return None
  }
  let msg = unpadded.exact_view(start=20, end=20 + msg_len).to_owned()
  let tail = unpadded
    .exact_view(start=20 + msg_len, end=unpadded.length())
    .to_owned()
  let recv = @utf8.decode(tail[:]) catch { _ => return None }
  if recv != receive_id {
    return None
  }
  let text = @utf8.decode(msg[:]) catch { _ => return None }
  Some(text)
}

///|
/// Verify `msg_signature` and decrypt one encrypted WeCom payload (Hermes
/// `WXBizMsgCrypt.decrypt`). `None` on a signature mismatch or any
/// decryption/correspondence failure.
pub fn wecom_decrypt_message(
  token : String,
  encoding_aes_key : String,
  receive_id : String,
  msg_signature : String,
  timestamp : String,
  nonce : String,
  encrypt : String,
) -> String? {
  if !wecom_verify_msg_signature(
      token, timestamp, nonce, encrypt, msg_signature,
    ) {
    return None
  }
  wecom_decrypt_envelope(encoding_aes_key, receive_id, encrypt)
}

///|
/// Encrypt one plaintext into the `<xml><Encrypt>…</Encrypt>…</xml>` callback
/// envelope (Hermes `WXBizMsgCrypt.encrypt`): 16 random bytes, the UTF-8
/// length in 4 big-endian bytes, the message, then `receive_id`, PKCS#7
/// padded to 32 and AES-256-CBC encrypted with `iv = key[:16]`.
pub fn wecom_encrypt_message(
  token : String,
  encoding_aes_key : String,
  receive_id : String,
  plaintext : String,
  timestamp : String,
  nonce : String,
) -> String? {
  let key = match wecom_aes_key(encoding_aes_key) {
    Some(k) => k
    None => return None
  }
  let msg = @utf8.encode(plaintext)
  let recv = @utf8.encode(receive_id)
  let payload : Array[Byte] = []
  let prefix = random_bytes(16)
  for i in 0..<16 {
    payload.push(prefix.get(i).unwrap_or(byte_of_int(0)))
  }
  let n = msg.length()
  payload.push(byte_of_int((n >> 24) & 255))
  payload.push(byte_of_int((n >> 16) & 255))
  payload.push(byte_of_int((n >> 8) & 255))
  payload.push(byte_of_int(n & 255))
  for i in 0..<msg.length() {
    payload.push(msg.get(i).unwrap_or(byte_of_int(0)))
  }
  for i in 0..<recv.length() {
    payload.push(recv.get(i).unwrap_or(byte_of_int(0)))
  }
  let padded = wecom_pkcs7_pad(Bytes::from_array(payload[:]))
  let encrypted = @crypto.aes_cbc_encrypt(
    key[:],
    key.exact_view(start=0, end=16),
    padded[:],
  ) catch {
    _ => return None
  }
  let encrypt = @base64.encode(encrypted)
  let signature = wecom_msg_signature(token, timestamp, nonce, encrypt)
  Some(
    "<xml><Encrypt><![CDATA[\{encrypt}]]></Encrypt><MsgSignature><![CDATA[\{signature}]]></MsgSignature><TimeStamp>\{timestamp}</TimeStamp><Nonce><![CDATA[\{nonce}]]></Nonce></xml>",
  )
}

///|
/// Decrypt one inbound WeCom callback body when callback crypto is configured
/// (`encoding_aes_key` set): extract the `<Encrypt>` element and decrypt it
/// against `corp_id`. Without an AES key the body passes through unchanged
/// (relay mode, where an upstream relay already decrypted it).
pub fn wecom_unwrap_callback(
  cfg : PlatformConfig,
  raw : String,
) -> Result[String, String] {
  let aes_key = wecom_encoding_aes_key(cfg)
  if aes_key.is_empty() {
    return Ok(raw)
  }
  match xml_text(raw, "Encrypt") {
    None => Err("missing <Encrypt> element")
    Some(encrypt) =>
      match wecom_decrypt_envelope(aes_key, wecom_corp_id(cfg), encrypt) {
        Some(xml) => Ok(xml)
        None => Err("decryption failed (bad key, padding or corp_id)")
      }
  }
}
