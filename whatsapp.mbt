// WhatsApp Cloud API adapter (`graph.facebook.com/v…/{phone_number_id}`).
//
// Mirrors Hermes `plugins/platforms/whatsapp_cloud/adapter.py`: text sends use
// `POST /messages` with `messaging_product: whatsapp`, and inbound updates
// arrive through the webhook `entry[].changes[].value` envelope. Within the
// 24-hour customer-service window any content works; outside it only approved
// templates are accepted.

///|
/// Graph API version, overridable with `[whatsapp.extra] api_version`.
pub fn whatsapp_api_version(cfg : PlatformConfig) -> String {
  cfg.extra_str("api_version", "v21.0")
}

///|
/// Phone-number id (`WHATSAPP_CLOUD_PHONE_NUMBER_ID`).
pub fn whatsapp_phone_number_id(cfg : PlatformConfig) -> String? {
  cfg.extra_first(["phone_number_id", "phone_id"])
}

///|
/// API root, overridable with `[whatsapp.extra] api_base`.
pub fn whatsapp_api_base(cfg : PlatformConfig) -> String {
  let base = cfg.extra_str("api_base", "https://graph.facebook.com")
  let trimmed = if base.has_suffix("/") {
    base[:base.length() - 1].to_owned()
  } else {
    base
  }
  let phone = whatsapp_phone_number_id(cfg).unwrap_or("")
  "\{trimmed}/\{whatsapp_api_version(cfg)}/\{phone}"
}

///|
/// `POST /messages` text payload.
pub fn whatsapp_send_payload(
  to : String,
  body : String,
  reply_to : String?,
) -> Json {
  let payload = json_obj([
    ("messaging_product", Json::string("whatsapp")),
    ("recipient_type", Json::string("individual")),
    ("to", Json::string(to)),
    ("type", Json::string("text")),
    (
      "text",
      json_obj([
        ("body", Json::string(body)),
        ("preview_url", Json::boolean(false)),
      ]),
    ),
  ])
  match reply_to {
    Some(mid) =>
      if payload is Object(m) {
        m.set("context", json_obj([("message_id", Json::string(mid))]))
      }
    None => ()
  }
  payload
}

///|
/// `POST /messages` media payload for a public URL.
pub fn whatsapp_media_payload(
  to : String,
  kind : String,
  url : String,
  caption : String?,
) -> Json {
  let typ = match kind {
    "photo" | "image" => "image"
    "video" => "video"
    "audio" | "voice" => "audio"
    _ => "document"
  }
  let media = json_obj([("link", Json::string(url))])
  let media = if typ == "document" {
    obj_with_opt(media, "filename", caption)
  } else {
    obj_with_opt(media, "caption", caption)
  }
  json_obj([
    ("messaging_product", Json::string("whatsapp")),
    ("recipient_type", Json::string("individual")),
    ("to", Json::string(to)),
    ("type", Json::string(typ)),
    (typ, media),
  ])
}

///|
/// First `messages[0].id` from a Graph send response.
fn whatsapp_message_id(j : Json) -> String? {
  match json_field_array(j, "messages") {
    Some(msgs) =>
      if msgs.length() > 0 {
        json_field_string(msgs[0], "id")
      } else {
        None
      }
    None => None
  }
}

///|
/// Post one payload to `/messages`, mapping Graph errors to `SendResult`.
async fn whatsapp_call(
  cfg : PlatformConfig,
  token : String,
  payload : Json,
) -> SendResult {
  let url = "\{whatsapp_api_base(cfg)}/messages"
  match post_json(url, payload, bearer_headers(token)) {
    Err(e) => {
      let retry_after = whatsapp_retry_after(e.body)
      SendResult::failed(
        "whatsapp: \{api_error_message(e)}",
        retryable=e.is_transient() || retry_after is Some(_),
        retry_after?,
        kind=classify_send_error(e.body),
      )
    }
    Ok(j) =>
      match graph_error_message(j) {
        Some(msg) => send_body_failure("whatsapp", msg)
        None => send_ok(whatsapp_message_id(j), j)
      }
  }
}

///|
/// Graph 429 bodies carry `error.message` containing "(#131056) … retry after n".
pub fn whatsapp_retry_after(body : String) -> Double? {
  let needle = "retry after "
  match body.to_lower().find(needle) {
    Some(i) => {
      let rest = body[i + needle.length():].to_owned()
      let digits = StringBuilder()
      for c in rest {
        if (c >= '0' && c <= '9') ||
          (c == '.' && digits.to_string().length() > 0) {
          digits.write_char(c)
        } else {
          break
        }
      }
      let s = digits.to_string()
      if s.is_empty() {
        None
      } else {
        Some(@string.parse_double(s)) catch {
          _ => None
        }
      }
    }
    None => None
  }
}

///|
/// Send ``content``, chunked at WhatsApp's 4096-char limit.
pub async fn whatsapp_send(
  cfg : PlatformConfig,
  chat_id : String,
  content : String,
  reply_to? : String,
) -> SendResult {
  match cfg.token_of() {
    None => missing_config(Whatsapp, "WHATSAPP_CLOUD_ACCESS_TOKEN")
    Some(token) =>
      if whatsapp_phone_number_id(cfg) is None {
        missing_config(Whatsapp, "WHATSAPP_CLOUD_PHONE_NUMBER_ID")
      } else if content.is_empty() {
        SendResult::ok()
      } else {
        let mut first = true
        let mut last = SendResult::ok()
        let mut first_id : String? = None
        for chunk in chunk_text(content, Platform::max_message_length(Whatsapp)) {
          let reply = if first { reply_to } else { None }
          let r = send_with_retry(() => {
            whatsapp_call(
              cfg,
              token,
              whatsapp_send_payload(chat_id, chunk, reply),
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
/// Send a media URL by public link.
pub async fn whatsapp_send_media(
  cfg : PlatformConfig,
  chat_id : String,
  kind : String,
  url : String,
  caption? : String,
) -> SendResult {
  match cfg.token_of() {
    None => missing_config(Whatsapp, "WHATSAPP_CLOUD_ACCESS_TOKEN")
    Some(token) =>
      whatsapp_call(
        cfg,
        token,
        whatsapp_media_payload(chat_id, kind, url, caption),
      )
  }
}

///|
/// Mark an inbound message as read (blue ticks).
pub async fn whatsapp_mark_read(
  cfg : PlatformConfig,
  message_id : String,
) -> Unit {
  match cfg.token_of() {
    None => ()
    Some(token) => {
      let url = "\{whatsapp_api_base(cfg)}/messages"
      let payload = json_obj([
        ("messaging_product", Json::string("whatsapp")),
        ("status", Json::string("read")),
        ("message_id", Json::string(message_id)),
      ])
      ignore(post_json(url, payload, bearer_headers(token)))
    }
  }
}

///|
/// Webhook verification handshake (`hub.mode=subscribe`).
pub fn whatsapp_verify(
  mode : String,
  token : String,
  challenge : String,
  expected : String,
) -> String? {
  if mode == "subscribe" && (expected.is_empty() || token == expected) {
    Some(challenge)
  } else {
    None
  }
}

///|
/// Meta's `X-Hub-Signature-256` value for ``body`` (`sha256=<hex hmac>`).
pub fn whatsapp_signature(secret : String, body : String) -> String {
  "sha256=\{hmac_sha256_hex(secret, body)}"
}

///|
/// Verify a WhatsApp `X-Hub-Signature-256` header: `sha256=<hex>` HMAC of the
/// raw body keyed by `app_secret`, case-insensitive hex, constant-time
/// (Hermes `whatsapp_cloud._verify_signature`).
pub fn whatsapp_verify_signature(
  secret : String,
  body : String,
  header : String,
) -> Bool {
  if secret.is_empty() || !header.has_prefix("sha256=") {
    return false
  }
  let provided = header[7:].to_owned().trim().to_lower()
  constant_time_eq(whatsapp_signature(secret, body), "sha256=\{provided}")
}

///|
/// Parse a WhatsApp webhook POST body into message events.
pub fn whatsapp_parse_webhook(body : String) -> Array[MessageEvent] {
  let out : Array[MessageEvent] = []
  let j = @json.parse(body) catch { _ => return out }
  let entries = match json_field_array(j, "entry") {
    Some(e) => e
    None => return out
  }
  for entry in entries {
    let changes = match json_field_array(entry, "changes") {
      Some(c) => c
      None => continue
    }
    for change in changes {
      let value = match json_field_obj(change, "value") {
        Some(v) => v
        None => continue
      }
      let contacts = json_field_array(value, "contacts")
      for msg in json_field_array(value, "messages").unwrap_or([]) {
        match whatsapp_parse_message(msg, contacts) {
          Some(ev) => out.push(ev)
          None => ()
        }
      }
    }
  }
  out
}

///|
/// Convert one webhook `messages[]` entry.
fn whatsapp_parse_message(msg : Json, contacts : Array[Json]?) -> MessageEvent? {
  let chat_id = json_id(msg, "from")
  match chat_id {
    None => None
    Some(chat_id) => {
      let (mtype, text, media) = whatsapp_content(msg)
      let user_name = match contacts {
        Some(cs) =>
          if cs.length() > 0 {
            match json_field_obj(cs[0], "profile") {
              Some(p) => json_field_string(p, "name")
              None => None
            }
          } else {
            None
          }
        None => None
      }
      let reply = match json_field_obj(msg, "context") {
        Some(c) => json_id(c, "id")
        None => None
      }
      Some(
        MessageEvent::new(
          text,
          mtype,
          Whatsapp,
          chat_id,
          user_name?,
          message_id?=json_id(msg, "id"),
          reply_to_message_id?=reply,
          media~,
          timestamp=parse_ms(json_field_string(msg, "timestamp")),
        ),
      )
    }
  }
}

///|
/// Classify a WhatsApp message payload (`text`, `image`, `location`, …).
fn whatsapp_content(
  msg : Json,
) -> (MessageType, String, Array[MediaAttachment]) {
  let media : Array[MediaAttachment] = []
  let typ = json_field_string(msg, "type").unwrap_or("text")
  match typ {
    "text" =>
      match json_field_obj(msg, "text") {
        Some(t) => (Text, json_field_string(t, "body").unwrap_or(""), media)
        None => (Text, "", media)
      }
    "image" | "video" | "audio" | "document" | "sticker" => {
      let obj = json_field_obj(msg, typ).unwrap_or(Json::null())
      let id = json_id(obj, "id").unwrap_or("")
      let caption = json_field_string(obj, "caption").unwrap_or("")
      media.push({ url: id, kind: typ, })
      let mt = match typ {
        "image" => Photo
        "video" => Video
        "audio" => Audio
        _ => Document
      }
      (mt, caption, media)
    }
    "location" =>
      match json_field_obj(msg, "location") {
        Some(l) => {
          let name = json_field_string(l, "name").unwrap_or("")
          let address = json_field_string(l, "address").unwrap_or("")
          (Location, "\{name} \{address}", media)
        }
        None => (Location, "", media)
      }
    "button" =>
      match json_field_obj(msg, "button") {
        Some(b) => (Text, json_field_string(b, "text").unwrap_or(""), media)
        None => (Text, "", media)
      }
    "interactive" =>
      match json_field_obj(msg, "interactive") {
        Some(i) => {
          let sub = match json_field_obj(i, "button_reply") {
            Some(b) => b
            None =>
              match json_field_obj(i, "list_reply") {
                Some(l) => l
                None => Json::null()
              }
          }
          (Text, json_field_string(sub, "title").unwrap_or(""), media)
        }
        None => (Text, "", media)
      }
    _ => (Text, "", media)
  }
}

///|
/// Parse a platform timestamp (seconds or milliseconds) into epoch ms.
pub fn parse_ms(s : String?) -> Int64 {
  match s {
    Some(v) =>
      try {
        let n = @string.parse_int64(v)
        if n < 100000000000L {
          n * 1000L
        } else {
          n
        }
      } catch {
        _ => now_ms()
      }
    None => now_ms()
  }
}
