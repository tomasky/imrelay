// Home Assistant adapter.
//
// Mirrors Hermes `plugins/platforms/homeassistant/adapter.py`: outbound
// messages call the REST service API
// (`POST /api/services/{domain}/{service}`) with a bearer token, and inbound
// traffic arrives through an automation that POSTs to the gateway webhook.
// `chat_id` is the notify service or entity to target.

///|
/// HA base URL (`HASS_URL`).
pub fn homeassistant_url(cfg : PlatformConfig) -> String {
  let url = cfg.extra_str("url", "")
  if url.has_suffix("/") {
    url[:url.length() - 1].to_owned()
  } else {
    url
  }
}

///|
/// Notify domain, e.g. `notify` (`[homeassistant.extra] notify_domain`).
pub fn homeassistant_domain(cfg : PlatformConfig) -> String {
  cfg.extra_str("notify_domain", "notify")
}

///|
/// Service name; falls back to the chat id (a notify service or entity id).
pub fn homeassistant_service(cfg : PlatformConfig, chat_id : String) -> String {
  let configured = cfg.extra_str("notify_service", "")
  if configured.is_empty() {
    chat_id
  } else {
    configured
  }
}

///|
/// `services/{domain}/{service}` payload.
pub fn homeassistant_send_payload(
  message : String,
  title : String?,
  data : Json?,
) -> Json {
  let payload = json_obj([("message", Json::string(message))])
  let payload = obj_with_opt(payload, "title", title)
  match data {
    Some(d) => if payload is Object(m) { m.set("data", d) }
    None => ()
  }
  payload
}

///|
/// Send ``content`` through the HA service API.
pub async fn homeassistant_send(
  cfg : PlatformConfig,
  chat_id : String,
  content : String,
  reply_to? : String,
) -> SendResult {
  ignore(reply_to)
  let base = homeassistant_url(cfg)
  if base.is_empty() {
    return missing_config(HomeAssistant, "HASS_URL")
  }
  match cfg.token_of() {
    None => missing_config(HomeAssistant, "HASS_TOKEN")
    Some(token) => {
      let service = homeassistant_service(cfg, chat_id)
      let url = "\{base}/api/services/\{homeassistant_domain(cfg)}/\{service}"
      let title = match cfg.extra_first(["title"]) {
        Some(t) => Some(t)
        None => None
      }
      let payload = homeassistant_send_payload(content, title, None)
      let r = send_with_retry(() => {
        match post_json(url, payload, bearer_headers(token)) {
          Err(e) => send_failure("homeassistant", e)
          Ok(j) => send_ok(None, j)
        }
      })
      r
    }
  }
}

///|
/// Entity state (`GET /api/states/{entity_id}`).
pub async fn homeassistant_get_chat(
  cfg : PlatformConfig,
  chat_id : String,
) -> ChatInfo? {
  match cfg.token_of() {
    None => None
    Some(token) => {
      let url = "\{homeassistant_url(cfg)}/api/states/\{chat_id}"
      match get_json(url, bearer_headers(token)) {
        Err(_) => None
        Ok(j) => {
          let name = match json_field_obj(j, "attributes") {
            Some(a) => json_field_string(a, "friendly_name").unwrap_or(chat_id)
            None => chat_id
          }
          Some({
            name,
            chat_type: json_field_string(j, "state").unwrap_or("unknown"),
            chat_id,
          })
        }
      }
    }
  }
}

///|
/// Parse an inbound automation webhook:
/// `{"text":"…","chat_id":"…","user_id":"…"}` (or `message` for `text`).
pub fn homeassistant_parse_event(body : String) -> Array[MessageEvent] {
  let out : Array[MessageEvent] = []
  let j = @json.parse(body) catch { _ => return out }
  let text = or_opt(
    json_field_string(j, "text"),
    json_field_string(j, "message"),
  ).unwrap_or("")
  let chat_id = match json_field_string(j, "chat_id") {
    Some(c) => c
    None => "notify"
  }
  if text.is_empty() {
    return out
  }
  let mtype = if text.has_prefix("/") { Command } else { Text }
  out.push(
    MessageEvent::new(
      text,
      mtype,
      HomeAssistant,
      chat_id,
      user_id?=json_field_string(j, "user_id"),
      user_name?=json_field_string(j, "user_name"),
      media=[],
      timestamp=now_ms(),
    ),
  )
  out
}
