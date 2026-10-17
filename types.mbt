// Shared types for the integrated chat-gateway SDK.
//
// The shapes mirror Hermes Agent's gateway (`gateway/platforms/base.py`,
// `gateway/platforms/event.py` and the per-platform plugin adapters), so code
// written against this SDK maps onto Hermes' adapter vocabulary:
// `SendResult` / `MessageEvent` / `HomeChannel` / the `Platform` enum.

///|
/// The messaging platforms this SDK can talk to. Values follow Hermes'
/// `Platform` enum (`gateway/config.py`) and the plugin directory names.
pub(all) enum Platform {
  Telegram
  Discord
  Slack
  Whatsapp
  Signal
  Email
  Mattermost
  Matrix
  Dingtalk
  Feishu
  Weixin
  Wecom
  Bluebubbles
  HomeAssistant
} derive(Eq, Hash, Debug)

///|
/// Hermes canonical value (the `Platform(...)` enum value / env-prefix base).
pub fn Platform::value(self : Platform) -> String {
  match self {
    Telegram => "telegram"
    Discord => "discord"
    Slack => "slack"
    Whatsapp => "whatsapp"
    Signal => "signal"
    Email => "email"
    Mattermost => "mattermost"
    Matrix => "matrix"
    Dingtalk => "dingtalk"
    Feishu => "feishu"
    Weixin => "weixin"
    Wecom => "wecom"
    Bluebubbles => "bluebubbles"
    HomeAssistant => "homeassistant"
  }
}

///|
pub fn Platform::of_value(s : String) -> Platform? {
  match s {
    "telegram" => Some(Telegram)
    "discord" => Some(Discord)
    "slack" => Some(Slack)
    "whatsapp" | "whatsapp_cloud" => Some(Whatsapp)
    "signal" => Some(Signal)
    "email" => Some(Email)
    "mattermost" => Some(Mattermost)
    "matrix" => Some(Matrix)
    "dingtalk" => Some(Dingtalk)
    "feishu" | "lark" => Some(Feishu)
    "weixin" | "wechat" => Some(Weixin)
    "wecom" => Some(Wecom)
    "bluebubbles" => Some(Bluebubbles)
    "homeassistant" => Some(HomeAssistant)
    _ => None
  }
}

///|
/// Human-readable name (Hermes `Platform` display names).
pub fn Platform::name(self : Platform) -> String {
  match self {
    Telegram => "Telegram"
    Discord => "Discord"
    Slack => "Slack"
    Whatsapp => "WhatsApp"
    Signal => "Signal"
    Email => "Email"
    Mattermost => "Mattermost"
    Matrix => "Matrix"
    Dingtalk => "DingTalk"
    Feishu => "Feishu/Lark"
    Weixin => "WeChat"
    Wecom => "WeCom (Enterprise WeChat)"
    Bluebubbles => "BlueBubbles"
    HomeAssistant => "Home Assistant"
  }
}

///|
/// Maximum characters the platform accepts in one message; sends are chunked
/// at this boundary (Hermes' per-adapter `MAX_MESSAGE_LENGTH`).
pub fn Platform::max_message_length(self : Platform) -> Int32 {
  match self {
    Telegram => 4096
    Discord => 2000
    Slack => 39000
    Whatsapp => 4096
    Signal => 8000
    Email => 100000
    Mattermost => 16383
    Matrix => 60000
    Dingtalk => 20000
    Feishu => 30000
    Weixin => 4000
    Wecom => 4096
    Bluebubbles => 4000
    HomeAssistant => 4000
  }
}

///|
/// Inbound message kinds, mirroring `gateway/platforms/event.py::MessageType`.
pub(all) enum MessageType {
  Text
  Location
  Photo
  Video
  Audio
  Voice
  Document
  Sticker
  Command
} derive(Eq, Debug)

///|
pub fn MessageType::value(self : MessageType) -> String {
  match self {
    Text => "text"
    Location => "location"
    Photo => "photo"
    Video => "video"
    Audio => "audio"
    Voice => "voice"
    Document => "document"
    Sticker => "sticker"
    Command => "command"
  }
}

///|
/// Platform-neutral send-failure kinds, mirroring Hermes' `SEND_ERROR_KINDS`
/// (`gateway/platforms/base.py`). Consumers branch on these instead of
/// substring-matching `error`.
pub(all) enum SendErrorKind {
  TooLong
  BadFormat
  Forbidden
  NotFound
  RateLimited
  Transient
  Unknown
} derive(Eq, Debug)

///|
pub fn SendErrorKind::value(self : SendErrorKind) -> String {
  match self {
    TooLong => "too_long"
    BadFormat => "bad_format"
    Forbidden => "forbidden"
    NotFound => "not_found"
    RateLimited => "rate_limited"
    Transient => "transient"
    Unknown => "unknown"
  }
}

///|
/// Result of a send, mirroring `gateway/platforms/base.py::SendResult`.
pub(all) struct SendResult {
  success : Bool
  message_id : String?
  error : String?
  retryable : Bool
  retry_after : Double?
  error_kind : SendErrorKind?
  /// Raw response payload (JSON text), when the platform returned one.
  raw : String?
} derive(Debug)

///|
pub fn SendResult::ok(message_id? : String, raw? : String) -> SendResult {
  {
    success: true,
    message_id,
    error: None,
    retryable: false,
    retry_after: None,
    error_kind: None,
    raw,
  }
}

///|
pub fn SendResult::failed(
  error : String,
  retryable~ : Bool = false,
  retry_after? : Double,
  kind? : SendErrorKind,
  raw? : String,
) -> SendResult {
  {
    success: false,
    message_id: None,
    error: Some(error),
    retryable,
    retry_after,
    error_kind: kind,
    raw,
  }
}

///|
/// Raise on failure, return `message_id` otherwise. Handy for call sites
/// that treat a refused send as an error.
pub fn SendResult::unwrap(self : SendResult) -> String raise {
  if self.success {
    self.message_id.unwrap_or("")
  } else {
    raise UtilsError::SendRefused(self.error.unwrap_or("unknown send error"))
  }
}

///|
/// Default delivery target for a platform (Hermes `HomeChannel`): used by
/// cron/notification delivery when no explicit chat is named.
pub(all) struct HomeChannel {
  platform : Platform
  chat_id : String
  name : String
  thread_id : String?
} derive(Debug)

///|
pub fn HomeChannel::new(
  platform : Platform,
  chat_id : String,
  name~ : String = "Home",
  thread_id? : String,
) -> HomeChannel {
  { platform, chat_id, name, thread_id, }
}

///|
/// Static info about a chat, mirroring `get_chat_info` results.
pub(all) struct ChatInfo {
  name : String
  chat_type : String
  chat_id : String
} derive(Debug)

///|
/// A media attachment carried by an inbound `MessageEvent`.
pub(all) struct MediaAttachment {
  url : String
  kind : String // "photo" | "video" | "audio" | "voice" | "document"
} derive(Debug)

///|
/// Normalized inbound message (Hermes `MessageEvent`). Adapters on the
/// receive side produce one of these; this SDK consumes them for send-side
/// routing (e.g. replying in the same thread).
pub(all) struct MessageEvent {
  text : String
  message_type : MessageType
  platform : Platform
  chat_id : String
  user_id : String?
  user_name : String?
  message_id : String?
  reply_to_message_id : String?
  reply_to_text : String?
  media : Array[MediaAttachment]
  timestamp : Int64
} derive(Debug)

///|
pub fn MessageEvent::new(
  text : String,
  message_type : MessageType,
  platform : Platform,
  chat_id : String,
  user_id? : String,
  user_name? : String,
  message_id? : String,
  reply_to_message_id? : String,
  reply_to_text? : String,
  media~ : Array[MediaAttachment] = [],
  timestamp~ : Int64 = 0L,
) -> MessageEvent {
  {
    text,
    message_type,
    platform,
    chat_id,
    user_id,
    user_name,
    message_id,
    reply_to_message_id,
    reply_to_text,
    media,
    timestamp,
  }
}

///|
/// `true` for `/command`-style inbound text.
pub fn MessageEvent::is_command(self : MessageEvent) -> Bool {
  self.message_type == Command || self.text.has_prefix("/")
}

///|
/// The command token (without the leading slash or `@bot` suffix), if any.
pub fn MessageEvent::get_command(self : MessageEvent) -> String? {
  if !self.is_command() {
    return None
  }
  let token = self.text.before(" ").unwrap_or(self.text[:]).to_owned()
  if token.length() < 2 {
    return None
  }
  let name = token[1:].to_owned()
  match name.split_once("@") {
    Some((head, _)) => Some(head.to_owned())
    None => Some(name)
  }
}
