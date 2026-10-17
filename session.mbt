// Per-chat session state and slash-command handling.
//
// Mirrors Hermes' conversation session handling: each `(platform, chat_id)`
// pair keeps a sliding history window plus the routing state needed for
// follow-up sends (`last_message_id`, `thread_id`, `context_token`). Slash
// commands (`/help`, `/reset`, `/status`, `/new`) are answered locally without
// invoking the agent.

///|
/// One conversation. `history` and `state` are reference types, so mutating a
/// session obtained from a `SessionStore` mutates the stored session.
pub(all) struct Session {
  platform : Platform
  chat_id : String
  /// Sliding window of `(role, content)` turns.
  history : Array[(String, String)]
  /// Routing state: `last_message_id`, `thread_id`, `context_token`, `user_name`.
  state : Map[String, String]
  /// History window size.
  max_history : Int32
} derive(Debug)

///|
/// Session registry keyed by `platform:chat_id`.
pub(all) struct SessionStore {
  sessions : Map[String, Session]
  max_history : Int32
} derive(Debug)

///|
pub fn SessionStore::new(max_history~ : Int32 = 24) -> SessionStore {
  { sessions: Map([]), max_history, }
}

///|
/// Fetch (or create) the session for a chat.
pub fn SessionStore::session(
  self : SessionStore,
  platform : Platform,
  chat_id : String,
) -> Session {
  let key = "\{platform.value()}:\{chat_id}"
  match self.sessions.get(key) {
    Some(s) => s
    None => {
      let history : Array[(String, String)] = []
      let s : Session = {
        platform,
        chat_id,
        history,
        state: Map([]),
        max_history: self.max_history,
      }
      self.sessions.set(key, s)
      s
    }
  }
}

///|
/// Number of tracked sessions.
pub fn SessionStore::len(self : SessionStore) -> Int32 {
  self.sessions.length()
}

///|
/// Append a turn, trimming the window to `max_history`.
pub fn Session::push(self : Session, role : String, content : String) -> Unit {
  self.history.push((role, content))
  while self.history.length() > self.max_history {
    ignore(self.history.remove(0))
  }
}

///|
/// Drop all history for this session.
pub fn Session::reset(self : Session) -> Unit {
  self.history.clear()
  self.state.clear()
}

///|
/// Record the id of the last message this gateway sent (reply target).
pub fn Session::set_last_message_id(self : Session, id : String) -> Unit {
  self.state.set("last_message_id", id)
}

///|
/// The last message id this gateway sent, if any.
pub fn Session::last_message_id(self : Session) -> String? {
  self.state.get("last_message_id")
}

///|
/// Remember a thread id for follow-up sends.
pub fn Session::set_thread_id(self : Session, id : String) -> Unit {
  self.state.set("thread_id", id)
}

///|
/// The stored thread id, if any.
pub fn Session::thread_id(self : Session) -> String? {
  self.state.get("thread_id")
}

///|
/// Remember the WeChat iLink `context_token` so replies stay in session.
pub fn Session::set_context_token(self : Session, token : String) -> Unit {
  self.state.set("context_token", token)
}

///|
/// The stored iLink `context_token`, if any.
pub fn Session::context_token(self : Session) -> String? {
  self.state.get("context_token")
}

///|
/// Render the history as an OpenAI-style `messages` array.
pub fn Session::messages_json(self : Session) -> Json {
  let items : Array[Json] = []
  for turn in self.history {
    items.push(
      json_obj([
        ("role", Json::string(turn.0)),
        ("content", Json::string(turn.1)),
      ]),
    )
  }
  Json::array(items)
}

///|
/// Parsed slash command: `(name, argument tail)`, lower-cased name and no
/// leading slash.
pub fn parse_command(text : String) -> (String, String)? {
  if !text.has_prefix("/") {
    return None
  }
  let token = match text.split_once(" ") {
    Some((head, tail)) => (head.to_owned(), tail.to_owned())
    None => (text, "")
  }
  let raw = token.0[1:].to_owned()
  let name = match raw.split_once("@") {
    Some((head, _)) => head.to_owned().to_lower()
    None => raw.to_lower()
  }
  if name.is_empty() {
    return None
  }
  Some((name, token.1.trim().to_owned()))
}

///|
/// Answer a built-in slash command locally. Returns `None` for commands the
/// agent should handle (and for plain messages).
pub fn command_reply(
  command : (String, String),
  cfg : GatewayConfig,
  session : Session,
) -> String? {
  match command.0 {
    "help" | "commands" =>
      Some(
        "imrelay commands:\n" +
        "/help — show this message\n" +
        "/reset — clear this chat's context\n" +
        "/new — start a fresh conversation\n" +
        "/status — show the session state\n" +
        "/platforms — list configured platforms",
      )
    "reset" | "new" | "clear" => {
      session.reset()
      Some("Context cleared.")
    }
    "status" =>
      Some(
        "platform: \{session.platform.value()}\n" +
        "chat: \{session.chat_id}\n" +
        "turns: \{session.history.length()}/\{session.max_history}\n" +
        "thread: \{session.thread_id().unwrap_or("-")}",
      )
    "platforms" => {
      let sb = StringBuilder()
      sb.write_string("Configured platforms:\n")
      for p in cfg.enabled_platforms() {
        sb.write_string("- \{p.name()} (\{p.value()})\n")
      }
      Some(sb.to_string())
    }
    _ => None
  }
}

///|
/// Hermes' silence contract: a reply equal to one of these markers is
/// suppressed instead of sent (§"silent" tokens). Case-insensitive.
pub fn is_silent_reply(text : String) -> Bool {
  let t = text.trim().to_lower()
  t == "[silent]" ||
  t == "no_reply" ||
  t == "no reply" ||
  t == "[no reply]" ||
  t.is_empty()
}
