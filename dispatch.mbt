// Platform dispatch: one entry point per gateway capability, routed to the
// right adapter. Mirrors Hermes' `Platform`-keyed registry in
// `gateway/platforms/__init__.py` — `send_message`, `send_typing`,
// `send_media` and `parse_inbound_event`.

///|
/// Webhook path for a platform (`/telegram`, `/whatsapp`, …).
pub fn webhook_path(platform : Platform) -> String {
  platform.value()
}

///|
/// Send a message through the platform's adapter. ``thread_id`` is forwarded
/// where the platform has a thread concept; ``context_token`` is the WeChat
/// iLink session token.
pub async fn send_message(
  cfg : PlatformConfig,
  chat_id : String,
  content : String,
  reply_to? : String,
  thread_id? : String,
  context_token? : String,
) -> SendResult {
  match cfg.platform {
    Telegram => telegram_send(cfg, chat_id, content, reply_to?, thread_id?)
    Discord => discord_send(cfg, chat_id, content, reply_to?)
    Slack => slack_send(cfg, chat_id, content, reply_to?, thread_ts?=thread_id)
    Whatsapp => whatsapp_send(cfg, chat_id, content, reply_to?)
    Signal => signal_send(cfg, chat_id, content, reply_to?)
    Email =>
      email_send(
        cfg,
        chat_id,
        cfg.extra_str("default_subject", "Message from imrelay"),
        content,
        in_reply_to?=reply_to,
      )
    Mattermost => mattermost_send(cfg, chat_id, content, reply_to?)
    Matrix => matrix_send(cfg, chat_id, content, reply_to?, thread_id?)
    Dingtalk => dingtalk_send(cfg, chat_id, content, reply_to?)
    Feishu => feishu_send(cfg, chat_id, content, reply_to?)
    Weixin => weixin_send(cfg, chat_id, content, reply_to?, context_token?)
    Wecom => wecom_send(cfg, chat_id, content, reply_to?)
    Bluebubbles => bluebubbles_send(cfg, chat_id, content, reply_to?)
    HomeAssistant => homeassistant_send(cfg, chat_id, content, reply_to?)
  }
}

///|
/// Send a typing indicator. Platforms without one are a silent no-op.
pub async fn send_typing(
  cfg : PlatformConfig,
  chat_id : String,
  thread_id? : String,
) -> Unit {
  match cfg.platform {
    Telegram => telegram_typing(cfg, chat_id, thread_id?)
    Discord => discord_typing(cfg, chat_id)
    Slack => slack_typing(cfg, chat_id, thread_ts?=thread_id)
    Signal => signal_typing(cfg, chat_id)
    Matrix => matrix_typing(cfg, chat_id)
    Weixin => weixin_typing(cfg, chat_id)
    Bluebubbles => bluebubbles_typing(cfg, chat_id)
    Whatsapp => ()
    Email => ()
    Mattermost => ()
    Dingtalk => ()
    Feishu => ()
    Wecom => ()
    HomeAssistant => ()
  }
}

///|
/// Send a media URL (or, for BlueBubbles, a local path).
pub async fn send_media(
  cfg : PlatformConfig,
  chat_id : String,
  kind : String,
  url : String,
  caption? : String,
) -> SendResult {
  match cfg.platform {
    Telegram => telegram_send_media(cfg, chat_id, kind, url, caption?)
    Discord => discord_send_media(cfg, chat_id, kind, url, caption?)
    Whatsapp => whatsapp_send_media(cfg, chat_id, kind, url, caption?)
    Bluebubbles => bluebubbles_send_attachment(cfg, chat_id, url)
    _ => {
      let text = match caption {
        Some(c) => "\{c}\n\{url}"
        None => url
      }
      send_message(cfg, chat_id, text)
    }
  }
}

///|
/// React to a message, where the platform supports reactions.
pub async fn send_reaction(
  cfg : PlatformConfig,
  chat_id : String,
  message_id : String,
  emoji : String,
) -> SendResult {
  match cfg.platform {
    Telegram => telegram_react(cfg, chat_id, message_id, emoji)
    Discord => discord_react(cfg, chat_id, message_id, emoji)
    Slack => slack_react(cfg, chat_id, message_id, emoji)
    Matrix => matrix_react(cfg, chat_id, message_id, emoji)
    _ =>
      SendResult::failed(
        "\{cfg.platform.value()}: reactions unsupported",
        kind=Forbidden,
      )
  }
}

///|
/// Edit a previously sent message, where the platform supports it.
pub async fn edit_message(
  cfg : PlatformConfig,
  chat_id : String,
  message_id : String,
  content : String,
) -> SendResult {
  match cfg.platform {
    Telegram => telegram_edit(cfg, chat_id, message_id, content)
    Discord => discord_edit(cfg, chat_id, message_id, content)
    Slack => slack_edit(cfg, chat_id, message_id, content)
    Matrix => matrix_edit(cfg, chat_id, message_id, content)
    _ =>
      SendResult::failed(
        "\{cfg.platform.value()}: edit unsupported",
        kind=Forbidden,
      )
  }
}

///|
/// Delete a message, where the platform supports it.
pub async fn delete_message(
  cfg : PlatformConfig,
  chat_id : String,
  message_id : String,
) -> SendResult {
  match cfg.platform {
    Telegram => telegram_delete(cfg, chat_id, message_id)
    Discord => discord_delete(cfg, chat_id, message_id)
    Slack => slack_delete(cfg, chat_id, message_id)
    _ =>
      SendResult::failed(
        "\{cfg.platform.value()}: delete unsupported",
        kind=Forbidden,
      )
  }
}

///|
/// Chat metadata, where the platform exposes it.
pub async fn get_chat_info(cfg : PlatformConfig, chat_id : String) -> ChatInfo? {
  match cfg.platform {
    Telegram => telegram_get_chat(cfg, chat_id)
    Discord => discord_get_chat(cfg, chat_id)
    Slack => slack_get_chat(cfg, chat_id)
    Matrix => matrix_get_chat(cfg, chat_id)
    Mattermost => mattermost_get_chat(cfg, chat_id)
    Feishu => feishu_get_chat(cfg, chat_id)
    Bluebubbles => bluebubbles_get_chat(cfg, chat_id)
    HomeAssistant => homeassistant_get_chat(cfg, chat_id)
    _ => None
  }
}

///|
/// Parse a webhook body into normalized events for ``platform``.
/// Unknown platforms and malformed bodies yield an empty array.
pub fn parse_inbound(platform : Platform, body : String) -> Array[MessageEvent] {
  match platform {
    Telegram => {
      let j = @json.parse(body) catch { _ => return [] }
      telegram_parse_update(j)
    }
    Discord =>
      if body.contains("\"type\"") &&
        (body.contains("\"MESSAGE_CREATE\"") || body.contains("\"t\"")) {
        discord_parse_message_event(body)
      } else {
        discord_parse_interaction(body)
      }
    Slack => slack_parse_event(body)
    Whatsapp => whatsapp_parse_webhook(body)
    Signal => signal_parse_receive(body)
    Email =>
      match email_parse_message(body) {
        Some(ev) => [ev]
        None => []
      }
    Mattermost => mattermost_parse_webhook(body)
    Matrix => matrix_parse_sync(body)
    Dingtalk => dingtalk_parse_callback(body)
    Feishu => feishu_parse_event(body)
    Weixin => {
      let j = @json.parse(body) catch { _ => return [] }
      let out : Array[MessageEvent] = []
      for msg in json_field_array(j, "msgs").unwrap_or([]) {
        match weixin_parse_message(msg) {
          Some(ev) => out.push(ev)
          None => ()
        }
      }
      out
    }
    Wecom => wecom_parse_callback(body)
    Bluebubbles => bluebubbles_parse_event(body)
    HomeAssistant => homeassistant_parse_event(body)
  }
}

///|
/// `true` when the platform has enough configuration to be usable.
pub fn platform_configured(cfg : PlatformConfig) -> Bool {
  match cfg.platform {
    Telegram | Discord | Slack | Weixin => cfg.token_of() is Some(_)
    Whatsapp =>
      cfg.token_of() is Some(_) && whatsapp_phone_number_id(cfg) is Some(_)
    Signal => signal_account(cfg) is Some(_) && !signal_http_url(cfg).is_empty()
    Email => !email_smtp_config(cfg).host.is_empty()
    Mattermost =>
      cfg.token_of() is Some(_) && !mattermost_api_base(cfg).is_empty()
    Matrix => cfg.token_of() is Some(_) || !matrix_homeserver(cfg).is_empty()
    Dingtalk =>
      dingtalk_robot_token(cfg) is Some(_) || dingtalk_app_key(cfg) is Some(_)
    Feishu =>
      !feishu_app_id(cfg).is_empty() && feishu_app_secret(cfg) is Some(_)
    Wecom => !wecom_corp_id(cfg).is_empty() && wecom_corp_secret(cfg) is Some(_)
    Bluebubbles =>
      !bluebubbles_api_base(cfg).is_empty() &&
      bluebubbles_api_base(cfg) != "/api/v1"
    HomeAssistant =>
      cfg.token_of() is Some(_) && !homeassistant_url(cfg).is_empty()
  }
}
