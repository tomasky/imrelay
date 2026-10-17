// WeChat (personal) adapter via the iLink bot API.
//
// Mirrors Hermes `plugins/platforms/weixin/adapter.py`: all calls are JSON
// `POST`s to `https://ilinkai.weixin.qq.com/ilink/bot/…` carrying the
// `ilink_bot_token` authorization type, an `X-WECHAT-UIN` header and a
// `base_info.channel_version` field. Inbound traffic is long-polled from
// `ilink/bot/getupdates`; replies may quote the stored `context_token` for a
// session-accurate send.

///|
/// iLink app id (`"bot"`).
pub fn weixin_app_id(cfg : PlatformConfig) -> String {
  cfg.extra_str("app_id", "bot")
}

///|
/// Channel version advertised in `base_info`.
pub fn weixin_channel_version(cfg : PlatformConfig) -> String {
  cfg.extra_str("channel_version", "2.2.0")
}

///|
/// Client version integer (`(2<<16)|(2<<8)` = 131584).
pub fn weixin_client_version(cfg : PlatformConfig) -> String {
  cfg.extra_int("client_version", (2 << 16) | (2 << 8)).to_string()
}

///|
/// API root, overridable with `[weixin.extra] base_url`.
pub fn weixin_base_url(cfg : PlatformConfig) -> String {
  let base = cfg.extra_str("base_url", "https://ilinkai.weixin.qq.com")
  if base.has_suffix("/") {
    base[:base.length() - 1].to_owned()
  } else {
    base
  }
}

///|
/// iLink request headers.
pub fn weixin_headers(
  cfg : PlatformConfig,
  token : String?,
) -> Map[String, String] {
  let headers = json_headers()
  headers.set("AuthorizationType", "ilink_bot_token")
  headers.set("iLink-App-Id", weixin_app_id(cfg))
  headers.set("iLink-App-ClientVersion", weixin_client_version(cfg))
  headers.set("X-WECHAT-UIN", @base64.encode(@utf8.encode(uin_text())))
  match token {
    Some(t) => if !t.is_empty() { headers.set("Authorization", "Bearer \{t}") }
    None => ()
  }
  headers
}

///|
/// `base64(int(bytes4))` per the iLink spec.
fn uin_text() -> String {
  let rand = @random.Rand()
  rand.int(limit=65536).to_string()
}

///|
/// `item_list` entry for a text message (`ITEM_TEXT` = 1).
pub fn weixin_text_item(text : String) -> Json {
  json_obj([
    ("type", Json::number(1.0)),
    ("text_item", json_obj([("text", Json::string(text))])),
  ])
}

///|
/// Full `sendmessage` payload (message wrapper + `base_info`).
pub fn weixin_send_payload(
  cfg : PlatformConfig,
  to : String,
  text : String,
  context_token : String?,
) -> Json {
  let msg = json_obj([
    ("from_user_id", Json::string("")),
    ("to_user_id", Json::string(to)),
    ("client_id", Json::string(random_hex(16))),
    ("message_type", Json::number(2.0)),
    ("message_state", Json::number(2.0)),
    ("item_list", Json::array([weixin_text_item(text)])),
  ])
  let msg = obj_with_opt(msg, "context_token", context_token)
  json_obj([
    ("msg", msg),
    (
      "base_info",
      json_obj([("channel_version", Json::string(weixin_channel_version(cfg)))]),
    ),
  ])
}

///|
/// Map an iLink `{ret, errcode, errmsg}` envelope onto a `SendResult`.
fn weixin_result(j : Json) -> SendResult {
  let ret = json_field_int(j, "ret").unwrap_or(0)
  let errcode = json_field_int(j, "errcode").unwrap_or(0)
  if ret == 0 && errcode == 0 {
    return send_ok(None, j)
  }
  let msg = or_opt(json_field_string(j, "errmsg"), json_field_string(j, "msg")).unwrap_or(
    j.stringify(),
  )
  SendResult::failed(
    "weixin: ret=\{ret} errcode=\{errcode} \{msg}",
    retryable=ret == -14 ||
      errcode == -14 ||
      classify_send_error(msg) == RateLimited,
    kind=classify_send_error(msg),
    raw=j.stringify(),
  )
}

///|
/// Send ``content``, chunked at WeChat's 4000-char limit. ``context_token``
/// opts into session-accurate delivery for the same chat.
pub async fn weixin_send(
  cfg : PlatformConfig,
  chat_id : String,
  content : String,
  reply_to? : String,
  context_token? : String,
) -> SendResult {
  ignore(reply_to)
  match cfg.token_of() {
    None => missing_config(Weixin, "WEIXIN_TOKEN")
    Some(token) =>
      if content.is_empty() {
        return SendResult::ok()
      } else {
        let url = "\{weixin_base_url(cfg)}/ilink/bot/sendmessage"
        let mut last = SendResult::ok()
        for chunk in chunk_text(content, Platform::max_message_length(Weixin)) {
          let body = weixin_send_payload(cfg, chat_id, chunk, context_token)
          let r = send_with_retry(() => {
            match post_json(url, body, weixin_headers(cfg, Some(token))) {
              Err(e) => send_failure("weixin sendmessage", e)
              Ok(j) => weixin_result(j)
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
/// Typing indicator (`ilink/bot/sendtyping`), failures ignored.
pub async fn weixin_typing(cfg : PlatformConfig, chat_id : String) -> Unit {
  match cfg.token_of() {
    None => ()
    Some(token) => {
      let url = "\{weixin_base_url(cfg)}/ilink/bot/sendtyping"
      let body = json_obj([
        ("to_user_id", Json::string(chat_id)),
        (
          "base_info",
          json_obj([
            ("channel_version", Json::string(weixin_channel_version(cfg))),
          ]),
        ),
      ])
      ignore(post_json(url, body, weixin_headers(cfg, Some(token))))
    }
  }
}

///|
/// Long-poll updates (`ilink/bot/getupdates`), surfacing failures so pollers
/// can back off. Returns the raw `msgs` array and the new sync buffer.
pub async fn weixin_get_updates_result(
  cfg : PlatformConfig,
  token : String,
  sync_buf : String,
) -> Result[(Array[Json], String), ApiError] {
  let url = "\{weixin_base_url(cfg)}/ilink/bot/getupdates"
  let body = json_obj([
    ("get_updates_buf", Json::string(sync_buf)),
    (
      "base_info",
      json_obj([("channel_version", Json::string(weixin_channel_version(cfg)))]),
    ),
  ])
  match post_json(url, body, weixin_headers(cfg, Some(token))) {
    Err(e) => Err(e)
    Ok(j) => {
      let msgs = json_field_array(j, "msgs").unwrap_or([])
      let buf = json_field_string(j, "get_updates_buf").unwrap_or(sync_buf)
      Ok((msgs, buf))
    }
  }
}

///|
/// Long-poll updates (`ilink/bot/getupdates`). Returns the raw `msgs` array
/// and the new sync buffer; failures yield an empty batch (see
/// `weixin_get_updates_result`).
pub async fn weixin_get_updates(
  cfg : PlatformConfig,
  token : String,
  sync_buf : String,
) -> (Array[Json], String) {
  match weixin_get_updates_result(cfg, token, sync_buf) {
    Ok(pair) => pair
    Err(_) => ([], sync_buf)
  }
}

///|
/// Parse an iLink update message (`{from_user_id, msg_id, item_list, …}`).
pub fn weixin_parse_message(msg : Json) -> MessageEvent? {
  let chat_id = or_opt(json_id(msg, "from_user_id"), json_id(msg, "chat_id")).unwrap_or(
    "",
  )
  if chat_id.is_empty() {
    return None
  }
  let text = weixin_item_text(msg)
  let media : Array[MediaAttachment] = []
  let mtype = if text.has_prefix("/") { Command } else { Text }
  Some(
    MessageEvent::new(
      text,
      mtype,
      Weixin,
      chat_id,
      user_id?=json_id(msg, "from_user_id"),
      message_id?=json_id(msg, "msg_id"),
      media~,
      timestamp=now_ms(),
    ),
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// iLink gap closure — encrypted CDN media + QR login (Hermes parity:
// `_pkcs7_pad`/`_aes128_ecb_{en,de}crypt`, `_ITEM_SHAPES`, `_INBOUND_MEDIA`,
// `_download_and_decrypt_media`, `_media_item`, `qr_login`).
// ─────────────────────────────────────────────────────────────────────────────

///|
/// item_list entry types (Hermes `ITEM_TEXT..ITEM_VIDEO`).
const WX_ITEM_TEXT : Int32 = 1

///|
const WX_ITEM_IMAGE : Int32 = 2

///|
const WX_ITEM_VOICE : Int32 = 3

///|
const WX_ITEM_FILE : Int32 = 4

///|
const WX_ITEM_VIDEO : Int32 = 5

///|
/// getuploadurl `media_type` values (Hermes `MEDIA_IMAGE..MEDIA_VOICE`).
const WX_MEDIA_IMAGE : Int32 = 1

///|
const WX_MEDIA_VIDEO : Int32 = 2

///|
const WX_MEDIA_FILE : Int32 = 3

///|
const WX_MEDIA_VOICE : Int32 = 4

///|
/// iLink error codes (Hermes `SESSION_EXPIRED_ERRCODE` / `RATE_LIMIT_ERRCODE`).
const WX_SESSION_EXPIRED : Int32 = -14

///|
const WX_RATE_LIMIT : Int32 = -2

///|
/// Encrypted media CDN root (Hermes `WEIXIN_CDN_BASE_URL`).
const WX_CDN_DEFAULT : String = "https://novac2c.cdn.weixin.qq.com/c2c"

///|
/// CDN root, overridable via `[weixin.extra] cdn_base_url` (trailing `/` trimmed).
pub fn weixin_cdn_base_url(cfg : PlatformConfig) -> String {
  let base = cfg.extra_str("cdn_base_url", WX_CDN_DEFAULT)
  if base.has_suffix("/") {
    base[:base.length() - 1].to_owned()
  } else {
    base
  }
}

///|
/// WeChat CDN host allowlist (Hermes `_WEIXIN_CDN_ALLOWLIST`) — SSRF guard for
/// `full_url` downloads.
pub fn weixin_cdn_host_allowed(url : String) -> Bool {
  let hosts = [
    "novac2c.cdn.weixin.qq.com", "ilinkai.weixin.qq.com", "wx.qlogo.cn", "thirdwx.qlogo.cn",
    "res.wx.qq.com", "mmbiz.qpic.cn", "mmbiz.qlogo.cn",
  ]
  for h in hosts {
    if url.has_prefix("https://\{h}/") || url.has_prefix("http://\{h}/") {
      return true
    }
  }
  false
}

///|
/// CDN download URL for an encrypted media item.
pub fn weixin_media_download_url(
  cdn_base : String,
  encrypted_query_param : String,
) -> String {
  "\{cdn_base}/download?encrypted_query_param=\{url_quote(encrypted_query_param)}"
}

///|
/// CDN upload URL constructed from `upload_param` (Hermes fallback path).
pub fn weixin_media_upload_url(
  cdn_base : String,
  upload_param : String,
  filekey : String,
) -> String {
  "\{cdn_base}/upload?encrypted_query_param=\{url_quote(upload_param)}&filekey=\{url_quote(filekey)}"
}

///|
/// PKCS#7 padding to a 16-byte block boundary (Hermes `_pkcs7_pad`).
pub fn weixin_pkcs7_pad(data : Bytes) -> Bytes {
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
/// Strip PKCS#7 padding when well-formed, else return the raw data (Hermes
/// `_aes128_ecb_decrypt`).
pub fn weixin_pkcs7_unpad(data : Bytes) -> Bytes {
  if data.length() == 0 {
    return data
  }
  let n = data.length()
  let pad = data.get(n - 1).unwrap_or(byte_of_int(0)).to_int64().to_int()
  if pad >= 1 && pad <= 16 && n >= pad {
    let mut ok = true
    for i in 0..<pad {
      if data.get(n - 1 - i).unwrap_or(byte_of_int(0)).to_int64().to_int() !=
        pad {
        ok = false
        break
      }
    }
    if ok {
      return data.exact_view(start=0, end=n - pad).to_owned()
    }
  }
  data
}

///|
/// Parse an iLink `aes_key` value (Hermes `_parse_aes_key`): either base64 of
/// 16 raw key bytes, or base64 of the ASCII hex key.
pub fn weixin_aes_key(key_b64 : String) -> Result[Bytes, String] {
  let decoded = @base64.decode(key_b64) catch {
    _ => return Err("bad aes_key base64")
  }
  if decoded.length() == 16 {
    return Ok(decoded)
  }
  if decoded.length() == 32 {
    // Hermes decodes the 32 bytes as ASCII hex text (`_parse_aes_key`).
    let text = @utf8.decode(decoded[:]) catch {
      _ => return Err("aes_key hex not valid utf8")
    }
    return match hex_decode(text) {
      Some(b) => Ok(b)
      None => Err("aes_key hex decode failed")
    }
  }
  Err("unexpected aes_key length \{decoded.length()}")
}

///|
/// AES-128-ECB encrypt with PKCS#7 padding.
pub fn weixin_media_encrypt(plaintext : Bytes, key : Bytes) -> Bytes raise {
  @crypto.aes_ecb_encrypt(key[:], weixin_pkcs7_pad(plaintext)[:])
}

///|
/// AES-128-ECB decrypt then strip PKCS#7 padding.
pub fn weixin_media_decrypt(ciphertext : Bytes, key : Bytes) -> Bytes raise {
  weixin_pkcs7_unpad(@crypto.aes_ecb_decrypt(key[:], ciphertext[:]))
}

///|
/// `media_type` (getuploadurl) for a local file name (Hermes
/// `_outbound_media_builder`).
pub fn weixin_media_type_of(filename : String) -> Int32 {
  let lower = filename.to_lower()
  if lower.has_suffix(".jpg") ||
    lower.has_suffix(".jpeg") ||
    lower.has_suffix(".png") ||
    lower.has_suffix(".gif") ||
    lower.has_suffix(".webp") ||
    lower.has_suffix(".bmp") {
    WX_MEDIA_IMAGE
  } else if lower.has_suffix(".mp4") ||
    lower.has_suffix(".mov") ||
    lower.has_suffix(".webm") {
    WX_MEDIA_VIDEO
  } else if lower.has_suffix(".silk") {
    WX_MEDIA_VOICE
  } else {
    WX_MEDIA_FILE
  }
}

///|
/// Guess a MIME type from a file name.
pub fn weixin_mime_of(filename : String) -> String {
  let lower = filename.to_lower()
  if lower.has_suffix(".jpg") || lower.has_suffix(".jpeg") {
    "image/jpeg"
  } else if lower.has_suffix(".png") {
    "image/png"
  } else if lower.has_suffix(".gif") {
    "image/gif"
  } else if lower.has_suffix(".webp") {
    "image/webp"
  } else if lower.has_suffix(".mp4") {
    "video/mp4"
  } else if lower.has_suffix(".silk") {
    "audio/silk"
  } else if lower.has_suffix(".mp3") {
    "audio/mpeg"
  } else if lower.has_suffix(".pdf") {
    "application/pdf"
  } else if lower.has_suffix(".txt") {
    "text/plain"
  } else if lower.has_suffix(".zip") {
    "application/zip"
  } else {
    "application/octet-stream"
  }
}

///|
/// Describe an inbound media item →
/// `(kind, mime, filename, payload_key)` or `None` when not a media item.
pub fn weixin_media_descriptor(
  item : Json,
) -> (String, String, String, String)? {
  let t = json_field_int(item, "type").unwrap_or(0)
  let spec = match t {
    WX_ITEM_IMAGE => ("photo", "image/jpeg", "image.jpg", "image_item")
    WX_ITEM_VIDEO => ("video", "video/mp4", "video.mp4", "video_item")
    WX_ITEM_FILE => ("document", "", "document.bin", "file_item")
    WX_ITEM_VOICE => ("voice", "audio/silk", "voice.silk", "voice_item")
    _ => return None
  }
  let payload = json_field_obj(item, spec.3).unwrap_or(Json::null())
  let default_mime = spec.1
  let filename = or_opt(json_field_string(payload, "file_name"), Some(spec.2)).unwrap_or(
    spec.2,
  )
  let mime = if default_mime.is_empty() {
    weixin_mime_of(filename)
  } else {
    default_mime
  }
  Some((spec.0, mime, filename, spec.3))
}

///|
/// Map a previously-collected media kind list onto a `MessageType` (Hermes
/// `_message_type_from_media`): media wins over text/command classification.
pub fn weixin_message_type_from_kinds(kinds : Array[String]) -> MessageType {
  for k in kinds {
    match k {
      "photo" => return Photo
      "video" => return Video
      "voice" | "audio" => return Voice
      "document" | "file" => return Document
      _ => ()
    }
  }
  Text
}

///|
/// Extract text from a single item (text_item) — used for quoted messages.
pub fn weixin_text_of(item : Json) -> String {
  match json_field_obj(item, "text_item") {
    Some(t) => json_field_string(t, "text").unwrap_or("")
    None => ""
  }
}

///|
/// Concatenate the `text_item` entries of an iLink message (Hermes
/// `_extract_text`): first text item wins (quoting handled), then a voice-item
/// STT fallback for transcripts with no raw audio.
pub fn weixin_item_text(msg : Json) -> String {
  let items = json_field_array(msg, "item_list").unwrap_or([])
  for item in items {
    if json_field_int(item, "type").unwrap_or(0) == WX_ITEM_TEXT {
      let text = weixin_text_of(item)
      match json_field_obj(item, "ref_msg") {
        Some(quoted) => {
          let title = json_field_string(quoted, "title").unwrap_or("")
          match json_field_obj(quoted, "message_item") {
            Some(ri) => {
              let rt = json_field_int(ri, "type").unwrap_or(0)
              if rt == WX_ITEM_IMAGE ||
                rt == WX_ITEM_VIDEO ||
                rt == WX_ITEM_FILE ||
                rt == WX_ITEM_VOICE {
                let inner = if title.is_empty() {
                  "[引用媒体]"
                } else {
                  "[引用媒体: \{title}]"
                }
                return "\{inner}\n\{text}".trim().to_owned()
              }
              let parts : Array[String] = []
              if !title.is_empty() {
                parts.push(title)
              }
              let sub = weixin_text_of(ri)
              if !sub.is_empty() {
                parts.push(sub)
              }
              if parts.length() > 0 {
                return "[引用: \{parts.join(" | ")}]\n\{text}"
                  .trim()
                  .to_owned()
              }
              return text
            }
            None => return text
          }
        }
        None => return text
      }
    }
  }
  // Voice fallback: iLink STT transcript without raw audio (Hermes #27300).
  for item in items {
    if json_field_int(item, "type").unwrap_or(0) == WX_ITEM_VOICE {
      match json_field_obj(item, "voice_item") {
        Some(v) => {
          let has_media = match json_field_obj(v, "media") {
            Some(_) => true
            None => false
          }
          let voice_text = json_field_string(v, "text").unwrap_or("")
          if !has_media && !voice_text.is_empty() {
            return "[Voice transcription provided by Weixin]\n\{voice_text}"
          }
        }
        None => ()
      }
    }
  }
  ""
}

///|
/// Build an outbound media item (Hermes `_media_item` + `_ITEM_SHAPES`);
/// `aes_key` is shipped as base64(hex string), not base64(raw key).
pub fn weixin_media_item(
  media_type : Int32,
  encrypted_query_param : String,
  aes_key_hex : String,
  ciphertext_size : Int32,
  plaintext_size : Int32,
  filename : String,
  rawfilemd5 : String,
) -> Json {
  let media = json_obj([
    ("encrypt_query_param", Json::string(encrypted_query_param)),
    ("aes_key", Json::string(@base64.encode(@utf8.encode(aes_key_hex)))),
    ("encrypt_type", Json::number(1.0)),
  ])
  let (item_type, key, fields) : (Int32, String, Array[(String, Json)]) = match
    media_type {
    WX_MEDIA_IMAGE =>
      (
        WX_ITEM_IMAGE,
        "image_item",
        [
          ("media", media),
          ("mid_size", Json::number(ciphertext_size.to_double())),
        ],
      )
    WX_MEDIA_VIDEO =>
      (
        WX_ITEM_VIDEO,
        "video_item",
        [
          ("media", media),
          ("video_size", Json::number(ciphertext_size.to_double())),
          ("play_length", Json::number(0.0)),
          ("video_md5", Json::string(rawfilemd5)),
        ],
      )
    WX_MEDIA_FILE =>
      (
        WX_ITEM_FILE,
        "file_item",
        [
          ("media", media),
          ("file_name", Json::string(filename)),
          ("len", Json::string(plaintext_size.to_string())),
        ],
      )
    WX_MEDIA_VOICE =>
      (
        WX_ITEM_VOICE,
        "voice_item",
        [
          ("media", media),
          ("encode_type", Json::number(6.0)),
          ("bits_per_sample", Json::number(16.0)),
          ("sample_rate", Json::number(24000.0)),
          ("playtime", Json::number(0.0)),
        ],
      )
    _ => return json_obj([])
  }
  json_obj([
    ("type", Json::number(item_type.to_double())),
    (key, json_obj(fields)),
  ])
}

///|
/// Outbound `sendmessage` envelope for an arbitrary `item_list`.
fn weixin_items_payload(
  cfg : PlatformConfig,
  to : String,
  items : Array[Json],
  context_token : String?,
) -> Json {
  let msg = json_obj([
    ("from_user_id", Json::string("")),
    ("to_user_id", Json::string(to)),
    ("client_id", Json::string(random_hex(16))),
    ("message_type", Json::number(2.0)),
    ("message_state", Json::number(2.0)),
    ("item_list", Json::array(items)),
  ])
  let msg = obj_with_opt(msg, "context_token", context_token)
  json_obj([
    ("msg", msg),
    (
      "base_info",
      json_obj([("channel_version", Json::string(weixin_channel_version(cfg)))]),
    ),
  ])
}

///|
/// iLink stale-session variance of the -2 frequency limit (Hermes
/// `_is_stale_session_ret`).
pub fn weixin_is_stale_session(
  ret : Int32,
  errcode : Int32,
  errmsg : String,
) -> Bool {
  (ret == WX_RATE_LIMIT || errcode == WX_RATE_LIMIT) &&
  (
    errmsg.to_lower() == "unknown error" ||
    errmsg.to_lower() == "prepare failed"
  )
}

///|
/// A response that means the session context went stale (Hermes
/// `_is_session_expired`).
pub fn weixin_is_session_expired(
  ret : Int32,
  errcode : Int32,
  errmsg : String,
) -> Bool {
  ret == WX_SESSION_EXPIRED ||
  errcode == WX_SESSION_EXPIRED ||
  weixin_is_stale_session(ret, errcode, errmsg)
}

///|
/// `SendResult` whose raw payload is an expired-session iLink envelope.
fn weixin_is_expired_result(r : SendResult) -> Bool {
  match r.raw {
    None => false
    Some(raw) => {
      let j = @json.parse(raw) catch { _ => return false }
      weixin_is_session_expired(
        json_field_int(j, "ret").unwrap_or(0),
        json_field_int(j, "errcode").unwrap_or(0),
        or_opt(json_field_string(j, "errmsg"), json_field_string(j, "msg")).unwrap_or(
          "",
        ),
      )
    }
  }
}

///|
/// Upload one media file to the encrypted CDN and return the iLink item seed
/// (`encrypted_query_param`, `aes_key` hex, sizes, md5).
pub async fn weixin_upload_media(
  cfg : PlatformConfig,
  token : String,
  chat_id : String,
  data : Bytes,
  filename : String,
) -> Result[Json, String] {
  let media_type = weixin_media_type_of(filename)
  let rawfilemd5 = md5_hex(data)
  let rawsize = data.length()
  let aes_key = random_bytes(16)
  let ciphertext = weixin_media_encrypt(data, aes_key) catch {
    e => return Err("encrypt failed: \{e}")
  }
  let filesize = (rawsize + 15) / 16 * 16
  let aeskey_hex = hex_encode(aes_key)
  let filekey = random_hex(16)
  let payload = json_obj([
    ("filekey", Json::string(filekey)),
    ("media_type", Json::number(media_type.to_double())),
    ("to_user_id", Json::string(chat_id)),
    ("rawsize", Json::number(rawsize.to_double())),
    ("rawfilemd5", Json::string(rawfilemd5)),
    ("filesize", Json::number(filesize.to_double())),
    ("no_need_thumb", Json::boolean(true)),
    ("aeskey", Json::string(aeskey_hex)),
  ])
  let url = "\{weixin_base_url(cfg)}/ilink/bot/getuploadurl"
  let resp = match post_json(url, payload, weixin_headers(cfg, Some(token))) {
    Err(e) => return Err("getuploadurl failed: \{e.body}")
    Ok(j) => j
  }
  let upload_param = json_field_string(resp, "upload_param").unwrap_or("")
  let upload_full_url = json_field_string(resp, "upload_full_url").unwrap_or("")
  let upload_url = if !upload_full_url.is_empty() {
    upload_full_url
  } else if !upload_param.is_empty() {
    weixin_media_upload_url(weixin_cdn_base_url(cfg), upload_param, filekey)
  } else {
    return Err("getuploadurl returned neither upload_param nor upload_full_url")
  }
  let headers = json_headers()
  headers.set("Content-Type", "application/octet-stream")
  ignore(headers)
  let up = match post_octet(upload_url, ciphertext, headers) {
    Err(e) => return Err("cdn upload failed: \{e.body}")
    Ok(r) => r
  }
  if up.code < 200 || up.code >= 300 {
    return Err("cdn upload HTTP \{up.code}: \{up.body_bytes.to_string()}")
  }
  match up.headers.get(@http.CaseInsensitiveString("x-encrypted-param")) {
    Some(encrypted_param) =>
      Ok(
        json_obj([
          ("encrypted_query_param", Json::string(encrypted_param)),
          ("aes_key_hex", Json::string(aeskey_hex)),
          ("media_type", Json::number(media_type.to_double())),
          ("ciphertext_size", Json::number(ciphertext.length().to_double())),
          ("plaintext_size", Json::number(rawsize.to_double())),
          ("filename", Json::string(filename)),
          ("rawfilemd5", Json::string(rawfilemd5)),
        ]),
      )
    None => Err("cdn upload missing x-encrypted-param header")
  }
}

///|
/// Send one media file (image/video/file/voice by extension) with caption-less
/// delivery; stale sessions retry once without `context_token`.
pub async fn weixin_send_media(
  cfg : PlatformConfig,
  chat_id : String,
  data : Bytes,
  filename : String,
  context_token? : String,
) -> SendResult {
  match cfg.token_of() {
    None => missing_config(Weixin, "WEIXIN_TOKEN")
    Some(token) => {
      let seed = match
        weixin_upload_media(cfg, token, chat_id, data, filename) {
        Err(e) =>
          return SendResult::failed(
            "weixin media upload: \{e}",
            kind=Unknown,
            raw="",
          )
        Ok(j) => j
      }
      let item = weixin_media_item(
        json_field_int(seed, "media_type").unwrap_or(0),
        json_field_string(seed, "encrypted_query_param").unwrap_or(""),
        json_field_string(seed, "aes_key_hex").unwrap_or(""),
        json_field_int(seed, "ciphertext_size").unwrap_or(0),
        json_field_int(seed, "plaintext_size").unwrap_or(0),
        json_field_string(seed, "filename").unwrap_or("document.bin"),
        json_field_string(seed, "rawfilemd5").unwrap_or(""),
      )
      let mut ctx = context_token
      let mut attempt = 0
      while attempt < 2 {
        attempt += 1
        let url = "\{weixin_base_url(cfg)}/ilink/bot/sendmessage"
        let body = weixin_items_payload(cfg, chat_id, [item], ctx)
        let r = send_with_retry(() => {
          match post_json(url, body, weixin_headers(cfg, Some(token))) {
            Err(e) => send_failure("weixin sendmessage", e)
            Ok(j) => weixin_result(j)
          }
        })
        if r.success {
          return r
        }
        if ctx is Some(_) && weixin_is_expired_result(r) {
          ctx = None
          continue
        }
        return r
      }
      SendResult::failed("weixin sendmessage exhausted", kind=Transient, raw="")
    }
  }
}

///|
/// Download + decrypt one inbound media item into a `data:` URL attachment.
pub async fn weixin_download_media(
  cfg : PlatformConfig,
  item : Json,
) -> MediaAttachment? {
  match weixin_media_descriptor(item) {
    None => None
    Some((kind, mime, _filename, payload_key)) => {
      let payload = json_field_obj(item, payload_key).unwrap_or(Json::null())
      let media = json_field_obj(payload, "media").unwrap_or(Json::null())
      // image_item may carry a raw hex `aeskey` beside the media block
      let mut aes_key_b64 = json_field_string(media, "aes_key")
      match json_field_string(payload, "aeskey") {
        Some(hex) => aes_key_b64 = Some(@base64.encode(@utf8.encode(hex)))
        None => ()
      }
      let url = match json_field_string(media, "encrypt_query_param") {
        Some(p) => weixin_media_download_url(weixin_cdn_base_url(cfg), p)
        None =>
          match json_field_string(media, "full_url") {
            Some(u) => if weixin_cdn_host_allowed(u) { u } else { return None }
            None => return None
          }
      }
      let data = match get_bytes(url, json_headers()) {
        Err(_) => return None
        Ok(b) => b
      }
      let plain = match aes_key_b64 {
        Some(k) =>
          match weixin_aes_key(k) {
            Ok(key) =>
              weixin_media_decrypt(data, key) catch {
                _ => return None
              }
            Err(_) => data
          }
        None => data
      }
      Some({ url: data_url(mime, plain), kind, })
    }
  }
}

///|
/// Download + decrypt every media item (and quoted media) of an update message.
pub async fn weixin_media_attachments(
  cfg : PlatformConfig,
  msg : Json,
) -> Array[MediaAttachment] {
  let out : Array[MediaAttachment] = []
  for item in json_field_array(msg, "item_list").unwrap_or([]) {
    let candidates : Array[Json] = [item]
    match json_field_obj(item, "ref_msg") {
      Some(quoted) =>
        match json_field_obj(quoted, "message_item") {
          Some(mi) => candidates.push(mi)
          None => ()
        }
      None => ()
    }
    for c in candidates {
      match weixin_download_media(cfg, c) {
        Some(a) => out.push(a)
        None => ()
      }
    }
  }
  out
}

///|
/// Rebuild an event with media attachments and the media-derived message type.
pub fn weixin_with_media(
  ev : MessageEvent,
  media : Array[MediaAttachment],
) -> MessageEvent {
  let kinds : Array[String] = media.map(fn(att) { att.kind })
  MessageEvent::new(
    ev.text,
    weixin_message_type_from_kinds(kinds),
    ev.platform,
    ev.chat_id,
    user_id?=ev.user_id,
    user_name?=ev.user_name,
    message_id?=ev.message_id,
    reply_to_message_id?=ev.reply_to_message_id,
    reply_to_text?=ev.reply_to_text,
    media~,
    timestamp=ev.timestamp,
  )
}

///|
/// Fetch the QR login payload (`get_bot_qrcode`), keyed by ``bot_type``
/// (Hermes default `"3"`).
pub async fn weixin_get_qrcode(
  cfg : PlatformConfig,
  bot_type? : String,
) -> Json? {
  let bt = bot_type.unwrap_or("3")
  let url = "\{weixin_base_url(cfg)}/ilink/bot/get_bot_qrcode?bot_type=\{url_quote(bt)}"
  match get_json(url, weixin_headers(cfg, None)) {
    Ok(j) =>
      if json_field_string(j, "qrcode") is Some(_) {
        Some(j)
      } else {
        None
      }
    Err(_) => None
  }
}

///|
/// Poll QR login status (`get_qrcode_status?qrcode=…`).
pub async fn weixin_qr_status(cfg : PlatformConfig, qrcode : String) -> Json? {
  let url = "\{weixin_base_url(cfg)}/ilink/bot/get_qrcode_status?qrcode=\{url_quote(qrcode)}"
  match get_json(url, weixin_headers(cfg, None)) {
    Ok(j) => Some(j)
    Err(_) => None
  }
}

///|
/// Extract confirmed credentials from the QR status payload →
/// `{account_id, token, base_url, user_id}` or `None`.
pub fn weixin_qr_creds(status : Json) -> Json? {
  let account_id = json_field_string(status, "ilink_bot_id").unwrap_or("")
  let token = json_field_string(status, "bot_token").unwrap_or("")
  if account_id.is_empty() || token.is_empty() {
    return None
  }
  let base_url = or_opt(
    json_field_string(status, "baseurl"),
    Some(weixin_base_url_default()),
  ).unwrap_or("")
  Some(
    json_obj([
      ("account_id", Json::string(account_id)),
      ("token", Json::string(token)),
      ("base_url", Json::string(base_url)),
      (
        "user_id",
        Json::string(json_field_string(status, "ilink_user_id").unwrap_or("")),
      ),
    ]),
  )
}

///|
/// The default iLink base URL (`ilinkai.weixin.qq.com`).
pub fn weixin_base_url_default() -> String {
  "https://ilinkai.weixin.qq.com"
}

///|
/// Drive the QR login state machine (Hermes `qr_login`): prints the liteapp
/// URL via `on_qr`, polls until confirmed (persisting credentials via
/// `persist`), refreshes expired QRs, follows `scaned_but_redirect` hosts.
pub async fn weixin_qr_login(
  cfg : PlatformConfig,
  on_qr : (String) -> Unit,
  persist : (Json) -> Unit,
  timeout_seconds? : Int32,
) -> Json? {
  let deadline_ms = now_ms() + timeout_seconds.unwrap_or(480).to_int64() * 1000L
  let mut qrcode = ""
  let mut qr_url = ""
  let mut refresh = 0
  let mut base_cfg = cfg
  match weixin_get_qrcode(base_cfg) {
    Some(j) => {
      qrcode = json_field_string(j, "qrcode").unwrap_or("")
      qr_url = json_field_string(j, "qrcode_img_content").unwrap_or("")
    }
    None => ()
  }
  if qrcode.is_empty() {
    return None
  }
  on_qr(if qr_url.is_empty() { qrcode } else { qr_url })
  while now_ms() < deadline_ms {
    let status = match weixin_qr_status(base_cfg, qrcode) {
      Some(j) => j
      None => {
        @async.sleep(1000)
        continue
      }
    }
    let st = json_field_string(status, "status").unwrap_or("wait")
    if st == "wait" {
      @async.sleep(1000)
      continue
    }
    if st == "scaned" {
      @async.sleep(1000)
      continue
    }
    if st == "confirmed" {
      let creds = weixin_qr_creds(status)
      match creds {
        Some(c) => {
          persist(c)
          return Some(c)
        }
        None => return None
      }
    }
    if st == "scaned_but_redirect" {
      match json_field_string(status, "redirect_host") {
        Some(host) =>
          if !host.is_empty() {
            let extra : Map[String, String] = Map([
              ("base_url", "https://\{host}"),
            ])
            base_cfg = PlatformConfig::new(Weixin, extra~)
          }
        None => ()
      }
      @async.sleep(1000)
      continue
    }
    // "expired": refresh the QR a few times
    if refresh >= 3 {
      return None
    }
    refresh += 1
    base_cfg = cfg
    match weixin_get_qrcode(cfg) {
      Some(j) => {
        qrcode = json_field_string(j, "qrcode").unwrap_or("")
        qr_url = json_field_string(j, "qrcode_img_content").unwrap_or("")
        if qrcode.is_empty() {
          return None
        }
        on_qr(if qr_url.is_empty() { qrcode } else { qr_url })
      }
      None => return None
    }
    @async.sleep(1000)
  }
  None
}
