// WeCom (Enterprise WeChat) adapter.
//
// Mirrors Hermes `plugins/platforms/wecom/adapter.py`: an access token is
// fetched from `cgi-bin/gettoken`, application messages go through
// `cgi-bin/message/send` (markdown for rich text), and inbound traffic arrives
// as a callback body — either the classic encrypted XML envelope (decrypted by
// the relay) or the newer JSON `aibot` shape.

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
