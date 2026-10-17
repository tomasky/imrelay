// Core unit tests: JSON/string utilities, shared types, session handling and
// TOML gateway configuration.

///|
/// Parse JSON, falling back to a null node so a bad fixture cannot raise.
fn t_json(s : String) -> Json {
  @json.parse(s) catch {
    _ => Json::null()
  }
}

///|
/// String field of a JSON object, or `"<none>"`.
fn t_s(j : Json, k : String) -> String {
  @imrelay.json_field_string(j, k).unwrap_or("<none>")
}

///|
/// Id field of a JSON object, or `"<none>"`.
fn t_id(j : Json, k : String) -> String {
  @imrelay.json_id(j, k).unwrap_or("<none>")
}

///|
/// Object field of a JSON object, or null.
fn t_obj(j : Json, k : String) -> Json {
  @imrelay.json_field_obj(j, k).unwrap_or(Json::null())
}

///|
/// A `PlatformConfig` carrying only `extra` entries.
fn t_pcfg(
  platform : @imrelay.Platform,
  extra : Array[(String, String)],
) -> @imrelay.PlatformConfig {
  let m : Map[String, String] = Map([])
  for kv in extra {
    m.set(kv.0, kv.1)
  }
  @imrelay.PlatformConfig::new(platform, extra=m)
}

///|
/// `GatewayConfig::from_toml` that never raises (tests supply valid TOML).
fn t_cfg(text : String) -> @imrelay.GatewayConfig {
  @imrelay.GatewayConfig::from_toml(text) catch {
    _ => @imrelay.GatewayConfig::default_config()
  }
}

///|
/// A representative `gateway.toml` covering every supported key.
const TOML_SAMPLE : String =
  #|[gateway]
  #|name = "my-gateway"
  #|host = "127.0.0.1"
  #|port = 9090
  #|public_url = "https://chat.example.com/"
  #|allowed_users = ["alice", "bob"]
  #|
  #|[platforms.telegram]
  #|token = "tg-token"
  #|home_channel = "-100"
  #|home_channel_name = "Ops"
  #|home_channel_thread = "42"
  #|allowed_users = ["alice"]
  #|
  #|[platforms.telegram.extra]
  #|parse_mode = "MarkdownV2"
  #|api_base = "https://tg.local"
  #|
  #|[platforms.discord]
  #|enabled = false
  #|token = "dc-token"
  #|
  #|[platforms.slack]
  #|token = "sl-token"
  #|api_key = "sl-key"

// --- utilities ------------------------------------------------------------

///|
test "util: json_obj and accessors" {
  let j = @imrelay.json_obj([("a", Json::string("x")), ("n", Json::number(3.0))])
  assert_eq(t_s(j, "a"), "x")
  assert_eq(t_s(j, "missing"), "<none>")
  assert_eq(@imrelay.json_field_int(j, "n"), Some(3))
  let nested = t_json("{\"a\": {\"b\": \"1\"}}")
  assert_eq(@imrelay.json_field_string(t_obj(nested, "a"), "b"), Some("1"))
}

///|
test "util: obj_with_opt only writes present values" {
  let a = @imrelay.obj_with_opt(Json::object(Map([])), "k", Some("v"))
  assert_eq(t_s(a, "k"), "v")
  let b = @imrelay.obj_with_opt(Json::object(Map([])), "k", None)
  assert_eq(t_s(b, "k"), "<none>")
}

///|
test "util: json_id reads numbers and strings" {
  let j = t_json("{\"n\": -100123, \"s\": \"abc\", \"f\": 1.5, \"b\": true}")
  assert_eq(t_id(j, "n"), "-100123")
  assert_eq(t_id(j, "s"), "abc")
  assert_eq(t_id(j, "f"), "1.5")
  assert_eq(t_id(j, "b"), "<none>")
}

///|
test "util: json field readers on non-objects" {
  let j = t_json("[1, 2]")
  assert_eq(@imrelay.json_field_string(j, "a"), None)
  assert_eq(@imrelay.json_field_array(j, "a"), None)
  assert_eq(@imrelay.json_field_obj(j, "a"), None)
  assert_eq(@imrelay.json_field_bool(j, "a"), None)
}

///|
test "util: json_field_bool and array" {
  let j = t_json("{\"ok\": true, \"xs\": [1, 2, 3]}")
  assert_eq(@imrelay.json_field_bool(j, "ok"), Some(true))
  assert_eq(@imrelay.json_field_array(j, "xs").unwrap().length(), 3)
}

///|
test "util: or_opt prefers the first present value" {
  assert_eq(@imrelay.or_opt(Some("a"), Some("b")), Some("a"))
  assert_eq(@imrelay.or_opt(None, Some("b")), Some("b"))
  assert_eq(@imrelay.or_opt(None, None), None)
}

///|
test "util: chunk_text keeps short text intact" {
  assert_eq(@imrelay.chunk_text("hello", 10).length(), 1)
  assert_eq(@imrelay.chunk_text("hello", 10)[0], "hello")
  assert_eq(@imrelay.chunk_text("", 10).length(), 1)
  assert_eq(@imrelay.chunk_text("hello", 0).length(), 1)
}

///|
test "util: chunk_text splits on the limit and rejoins losslessly" {
  let text = "abcdefghijklmnopqrstuvwxy"
  let chunks = @imrelay.chunk_text(text, 10)
  assert_eq(chunks.length(), 3)
  assert_eq(chunks[0].length(), 10)
  assert_eq(chunks[1].length(), 10)
  assert_eq(chunks[2].length(), 5)
  assert_eq(chunks[0] + chunks[1] + chunks[2], text)
}

///|
test "util: chunk_text prefers paragraph boundaries" {
  let whole = @imrelay.chunk_text("one\n\ntwo\n\nthree", 100)
  assert_eq(whole.length(), 1)
  assert_eq(whole[0], "one\n\ntwo\n\nthree")
  let chunks = @imrelay.chunk_text("one\n\ntwo\n\nthree", 10)
  assert_eq(chunks.length(), 3)
  assert_eq(chunks[0], "one")
  assert_eq(chunks[1], "two")
  assert_eq(chunks[2], "three")
}

///|
test "util: truncate" {
  assert_eq(@imrelay.truncate("abcdef", 3), "abc...")
  assert_eq(@imrelay.truncate("abc", 3), "abc")
  assert_eq(@imrelay.truncate("abcdef", 3, suffix="!"), "abc!")
}

///|
test "util: strip_markdown removes common markup" {
  assert_eq(@imrelay.strip_markdown("**bold**"), "bold")
  assert_eq(@imrelay.strip_markdown("`code`"), "code")
  assert_eq(@imrelay.strip_markdown("# H"), " H")
  assert_eq(@imrelay.strip_markdown("a*b"), "ab")
}

///|
test "util: classify_send_error maps platform errors" {
  assert_eq(
    @imrelay.classify_send_error("Bad Request: message is too long"),
    @imrelay.TooLong,
  )
  assert_eq(
    @imrelay.classify_send_error("Bad Request: can't parse entities"),
    @imrelay.BadFormat,
  )
  assert_eq(
    @imrelay.classify_send_error("Forbidden: bot was blocked by the user"),
    @imrelay.Forbidden,
  )
  assert_eq(
    @imrelay.classify_send_error("Bad Request: chat not found"),
    @imrelay.NotFound,
  )
  assert_eq(
    @imrelay.classify_send_error("Too Many Requests: retry after 5"),
    @imrelay.RateLimited,
  )
  assert_eq(
    @imrelay.classify_send_error("ConnectionResetError: peer reset"),
    @imrelay.Transient,
  )
  assert_eq(
    @imrelay.classify_send_error("Bad Request: invalid payload"),
    @imrelay.Unknown,
  )
  assert_eq(
    @imrelay.classify_send_error("something else entirely"),
    @imrelay.Unknown,
  )
}

///|
test "util: is_chat_level_not_found" {
  assert_true(@imrelay.is_chat_level_not_found("Bad Request: chat not found"))
  assert_eq(
    @imrelay.is_chat_level_not_found("message to edit not found"),
    false,
  )
  assert_eq(
    @imrelay.is_chat_level_not_found(
      "chat not found: message to edit not found",
    ),
    false,
  )
}

///|
test "util: random_hex" {
  assert_eq(@imrelay.random_hex(8).length(), 8)
  assert_eq(@imrelay.random_hex(0), "")
  assert_true(@imrelay.random_hex(16) != @imrelay.random_hex(16))
}

///|
test "util: now_ms is a plausible epoch timestamp" {
  assert_true(@imrelay.now_ms() > 1600000000000L)
}

///|
test "util: url_quote escapes reserved characters" {
  assert_eq(@imrelay.url_quote("abc"), "abc")
  assert_eq(@imrelay.url_quote("a b"), "a%20b")
  assert_eq(@imrelay.url_quote("a+b&c"), "a%2Bb%26c")
}

///|
test "util: hmac-sha256 known vector" {
  assert_eq(
    @imrelay.hmac_sha256_hex(
      "key", "The quick brown fox jumps over the lazy dog",
    ),
    "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
  )
  assert_eq(
    @imrelay.hmac_sha256_hex("", ""),
    "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad",
  )
}

///|
test "util: constant-time comparison" {
  assert_true(@imrelay.constant_time_eq("abc", "abc"))
  assert_true(@imrelay.constant_time_eq("", ""))
  assert_true(!@imrelay.constant_time_eq("abc", "abd"))
  assert_true(!@imrelay.constant_time_eq("abc", "abcd"))
  assert_true(!@imrelay.constant_time_eq("", "a"))
}

// --- types ----------------------------------------------------------------

///|
test "types: platform values round-trip" {
  let platforms = [
    @imrelay.Telegram,
    @imrelay.Discord,
    @imrelay.Slack,
    @imrelay.Whatsapp,
    @imrelay.Signal,
    @imrelay.Email,
    @imrelay.Mattermost,
    @imrelay.Matrix,
    @imrelay.Dingtalk,
    @imrelay.Feishu,
    @imrelay.Weixin,
    @imrelay.Wecom,
    @imrelay.Bluebubbles,
    @imrelay.HomeAssistant,
  ]
  for p in platforms {
    assert_eq(@imrelay.Platform::of_value(p.value()), Some(p))
  }
}

///|
test "types: platform name aliases" {
  assert_eq(
    @imrelay.Platform::of_value("whatsapp_cloud"),
    Some(@imrelay.Whatsapp),
  )
  assert_eq(@imrelay.Platform::of_value("lark"), Some(@imrelay.Feishu))
  assert_eq(@imrelay.Platform::of_value("wechat"), Some(@imrelay.Weixin))
  assert_eq(@imrelay.Platform::of_value("wecom"), Some(@imrelay.Wecom))
  assert_eq(
    @imrelay.Platform::of_value("homeassistant"),
    Some(@imrelay.HomeAssistant),
  )
  assert_eq(@imrelay.Platform::of_value("nope"), None)
  assert_eq(@imrelay.Platform::of_value("Telegram"), None)
  assert_eq(@imrelay.Platform::of_value(""), None)
}

///|
test "types: platform display names" {
  assert_eq(@imrelay.Telegram.name(), "Telegram")
  assert_eq(@imrelay.Feishu.name(), "Feishu/Lark")
  assert_eq(@imrelay.Wecom.name(), "WeCom (Enterprise WeChat)")
  assert_eq(@imrelay.HomeAssistant.name(), "Home Assistant")
}

///|
test "types: per-platform message limits" {
  assert_eq(@imrelay.Telegram.max_message_length(), 4096)
  assert_eq(@imrelay.Discord.max_message_length(), 2000)
  assert_eq(@imrelay.Slack.max_message_length(), 39000)
  assert_eq(@imrelay.Matrix.max_message_length(), 60000)
  assert_eq(@imrelay.Weixin.max_message_length(), 4000)
}

///|
test "types: message type values" {
  assert_eq(@imrelay.Text.value(), "text")
  assert_eq(@imrelay.Command.value(), "command")
  assert_eq(@imrelay.Location.value(), "location")
  assert_eq(@imrelay.Sticker.value(), "sticker")
}

///|
test "types: send error kind values" {
  assert_eq(@imrelay.TooLong.value(), "too_long")
  assert_eq(@imrelay.RateLimited.value(), "rate_limited")
  assert_eq(@imrelay.Unknown.value(), "unknown")
}

///|
test "types: SendResult ok and failed" {
  let ok = @imrelay.SendResult::ok(message_id="17", raw="{}")
  assert_eq(ok.success, true)
  assert_eq(ok.message_id, Some("17"))
  assert_eq(ok.unwrap(), "17")
  let bad = @imrelay.SendResult::failed(
    "nope",
    retryable=true,
    retry_after=2.5,
    kind=@imrelay.RateLimited,
  )
  assert_eq(bad.success, false)
  assert_eq(bad.retryable, true)
  assert_eq(bad.retry_after, Some(2.5))
  assert_eq(bad.error_kind, Some(@imrelay.RateLimited))
}

///|
test "types: SendResult unwrap raises on failure" {
  let mut raised = false
  ignore(@imrelay.SendResult::failed("boom").unwrap()) catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
test "types: HomeChannel defaults" {
  let hc = @imrelay.HomeChannel::new(@imrelay.Telegram, "-100")
  assert_eq(hc.name, "Home")
  assert_eq(hc.thread_id, None)
  let threaded = @imrelay.HomeChannel::new(
    @imrelay.Slack,
    "C1",
    name="Ops",
    thread_id="9.1",
  )
  assert_eq(threaded.name, "Ops")
  assert_eq(threaded.thread_id, Some("9.1"))
}

///|
test "types: MessageEvent command detection" {
  let ev = @imrelay.MessageEvent::new(
    "/help@mybot now",
    @imrelay.Command,
    @imrelay.Telegram,
    "1",
  )
  assert_true(ev.is_command())
  assert_eq(ev.get_command(), Some("help"))
  assert_eq(ev.media.length(), 0)
  assert_eq(ev.timestamp, 0L)
  let plain = @imrelay.MessageEvent::new(
    "hello",
    @imrelay.Text,
    @imrelay.Telegram,
    "1",
  )
  assert_eq(plain.is_command(), false)
  assert_eq(plain.get_command(), None)
}

// --- sessions -------------------------------------------------------------

///|
test "session: store keys sessions by platform and chat" {
  let store = @imrelay.SessionStore::new()
  let a = store.session(@imrelay.Telegram, "1")
  let b = store.session(@imrelay.Discord, "1")
  assert_eq(b.chat_id, "1")
  let a2 = store.session(@imrelay.Telegram, "1")
  assert_eq(store.len(), 2)
  assert_eq(a.chat_id, "1")
  assert_eq(a.platform, @imrelay.Telegram)
  a.push("user", "hi")
  assert_eq(a2.history.length(), 1)
}

///|
test "session: history is trimmed to max_history" {
  let store = @imrelay.SessionStore::new(max_history=2)
  let s = store.session(@imrelay.Telegram, "1")
  s.push("user", "one")
  s.push("assistant", "two")
  s.push("user", "three")
  assert_eq(s.history.length(), 2)
  assert_eq(s.history[0].1, "two")
  assert_eq(s.history[1].1, "three")
  assert_eq(s.max_history, 2)
}

///|
test "session: reset clears history and state" {
  let store = @imrelay.SessionStore::new()
  let s = store.session(@imrelay.Telegram, "1")
  s.push("user", "hi")
  s.set_last_message_id("9")
  s.set_thread_id("3")
  s.set_context_token("tok")
  s.reset()
  assert_eq(s.history.length(), 0)
  assert_eq(s.last_message_id(), None)
  assert_eq(s.thread_id(), None)
  assert_eq(s.context_token(), None)
}

///|
test "session: routing state accessors" {
  let store = @imrelay.SessionStore::new()
  let s = store.session(@imrelay.Telegram, "1")
  assert_eq(s.last_message_id(), None)
  s.set_last_message_id("9")
  assert_eq(s.last_message_id(), Some("9"))
  s.set_thread_id("3")
  assert_eq(s.thread_id(), Some("3"))
  s.set_context_token("tok")
  assert_eq(s.context_token(), Some("tok"))
}

///|
test "session: messages_json renders the history" {
  let store = @imrelay.SessionStore::new()
  let s = store.session(@imrelay.Telegram, "1")
  s.push("user", "hi")
  s.push("assistant", "hello")
  let j = s.messages_json()
  let msgs = match j {
    Array(a) => a
    _ => []
  }
  assert_eq(msgs.length(), 2)
  assert_eq(t_s(msgs[0], "role"), "user")
  assert_eq(t_s(msgs[1], "content"), "hello")
}

///|
test "session: parse_command" {
  assert_eq(@imrelay.parse_command("hello"), None)
  assert_eq(@imrelay.parse_command("/help"), Some(("help", "")))
  assert_eq(@imrelay.parse_command("/Help  me now "), Some(("help", "me now")))
  assert_eq(@imrelay.parse_command("/help@mybot"), Some(("help", "")))
  assert_eq(
    @imrelay.parse_command("/reset@bot extra"),
    Some(("reset", "extra")),
  )
  assert_eq(@imrelay.parse_command("/"), None)
}

///|
test "session: command_reply answers help and resets" {
  let cfg = t_cfg(TOML_SAMPLE)
  let store = @imrelay.SessionStore::new()
  let s = store.session(@imrelay.Telegram, "1")
  let help = @imrelay.command_reply(("help", ""), cfg, s).unwrap()
  assert_true(help.contains("/reset"))
  s.push("user", "hi")
  let reset = @imrelay.command_reply(("reset", ""), cfg, s).unwrap()
  assert_eq(reset, "Context cleared.")
  assert_eq(s.history.length(), 0)
  let status = @imrelay.command_reply(("status", ""), cfg, s).unwrap()
  assert_true(status.contains("platform: telegram"))
  let platforms = @imrelay.command_reply(("platforms", ""), cfg, s).unwrap()
  assert_true(platforms.contains("- Telegram (telegram)"))
  assert_eq(@imrelay.command_reply(("nope", ""), cfg, s), None)
}

///|
test "session: is_silent_reply" {
  assert_true(@imrelay.is_silent_reply("[SILENT]"))
  assert_true(@imrelay.is_silent_reply("no_reply"))
  assert_true(@imrelay.is_silent_reply("   "))
  assert_eq(@imrelay.is_silent_reply("hello"), false)
}

// --- configuration --------------------------------------------------------

///|
test "config: defaults" {
  let cfg = @imrelay.GatewayConfig::default_config()
  assert_eq(cfg.name, "imrelay")
  assert_eq(cfg.host, "0.0.0.0")
  assert_eq(cfg.port, 8080)
  assert_eq(cfg.public_url, None)
  assert_eq(cfg.enabled_platforms().length(), 0)
  assert_true(cfg.get(@imrelay.Telegram) is None)
}

///|
test "config: [gateway] section from TOML" {
  let cfg = t_cfg(TOML_SAMPLE)
  assert_eq(cfg.name, "my-gateway")
  assert_eq(cfg.host, "127.0.0.1")
  assert_eq(cfg.port, 9090)
  assert_eq(cfg.public_url, Some("https://chat.example.com/"))
  assert_eq(cfg.allowed_users.length(), 2)
  assert_eq(cfg.allowed_users[0], "alice")
}

///|
test "config: platforms from TOML" {
  let cfg = t_cfg(TOML_SAMPLE)
  let tg = cfg.get(@imrelay.Telegram).unwrap()
  assert_eq(tg.token, Some("tg-token"))
  assert_eq(tg.enabled, true)
  assert_eq(tg.extra_str("parse_mode", ""), "MarkdownV2")
  assert_eq(tg.extra_str("api_base", ""), "https://tg.local")
  assert_eq(tg.allowed_users.length(), 1)
  let hc = tg.home_channel.unwrap()
  assert_eq(hc.chat_id, "-100")
  assert_eq(hc.name, "Ops")
  assert_eq(hc.thread_id, Some("42"))
  assert_eq(cfg.get(@imrelay.Discord).unwrap().enabled, false)
  assert_eq(cfg.enabled_platforms().length(), 2)
}

///|
test "config: platform name aliases in TOML" {
  let cfg = t_cfg(
    "[platforms.lark]\napp_id = \"a\"\n[platforms.wechat]\ntoken = \"t\"\n[platforms.whatsapp_cloud]\ntoken = \"w\"\n",
  )
  assert_eq(cfg.get(@imrelay.Feishu).unwrap().extra_str("app_id", ""), "a")
  assert_true(cfg.get(@imrelay.Weixin) is Some(_))
  assert_true(cfg.get(@imrelay.Whatsapp) is Some(_))
  assert_eq(cfg.enabled_platforms().length(), 3)
}

///|
test "config: unknown platform sections are ignored" {
  let cfg = t_cfg("[platforms.nonsense]\ntoken = \"x\"\n")
  assert_eq(cfg.enabled_platforms().length(), 0)
}

///|
test "config: nested extra table wins over a flat key" {
  let cfg = t_cfg(
    "[platforms.telegram]\napi_base = \"flat\"\n[platforms.telegram.extra]\napi_base = \"nested\"\n",
  )
  assert_eq(
    cfg.get(@imrelay.Telegram).unwrap().extra_str("api_base", ""),
    "nested",
  )
}

///|
test "config: webhook_url joins the public URL" {
  let cfg = t_cfg(TOML_SAMPLE)
  assert_eq(
    cfg.webhook_url("telegram"),
    Some("https://chat.example.com/telegram"),
  )
  assert_eq(
    cfg.webhook_url("/telegram"),
    Some("https://chat.example.com/telegram"),
  )
  assert_eq(
    @imrelay.GatewayConfig::default_config().webhook_url("telegram"),
    None,
  )
}

///|
test "config: platform accessors" {
  let pc = t_pcfg(@imrelay.Telegram, [
    ("n", "7"),
    ("t", "true"),
    ("empty", ""),
    ("first", "1"),
  ])
  assert_eq(pc.get("n"), Some("7"))
  assert_eq(pc.get("zz"), None)
  assert_eq(pc.get_or("zz", "d"), "d")
  assert_eq(pc.extra_str("zz", "d"), "d")
  assert_eq(pc.extra_int("n", 0), 7)
  assert_eq(pc.extra_int("zz", 5), 5)
  assert_eq(pc.extra_int("empty", 5), 5)
  assert_eq(pc.extra_bool("t", false), true)
  assert_eq(pc.extra_bool("zz", false), false)
  assert_eq(pc.extra_first(["zz", "empty", "first"]), Some("1"))
  assert_eq(pc.extra_first(["zz"]), None)
}

///|
test "config: token_of, api_key_of and bearer" {
  let tok = @imrelay.PlatformConfig::new(@imrelay.Telegram, token="t")
  assert_eq(tok.token_of(), Some("t"))
  assert_eq(tok.api_key_of(), None)
  assert_eq(tok.bearer(), Some("t"))
  let key = @imrelay.PlatformConfig::new(@imrelay.Telegram, api_key="k")
  assert_eq(key.token_of(), None)
  assert_eq(key.api_key_of(), Some("k"))
  assert_eq(key.bearer(), Some("k"))
  let blank = @imrelay.PlatformConfig::new(@imrelay.Telegram, token="")
  assert_eq(blank.token_of(), None)
  assert_eq(blank.bearer(), None)
}

///|
test "config: require raises when the key is missing" {
  let pc = t_pcfg(@imrelay.Telegram, [("have", "v")])
  assert_eq(pc.require("have", "test"), "v")
  let mut raised = false
  ignore(pc.require("gone", "test")) catch {
    _ => raised = true
  }
  assert_true(raised)
}

// --- shared adapter helpers ----------------------------------------------

///|
test "adapters: header helpers" {
  let h = @imrelay.json_headers()
  assert_eq(h.get("Content-Type").unwrap(), "application/json")
  assert_eq(@imrelay.bot_headers("t").get("Authorization").unwrap(), "Bot t")
  assert_eq(
    @imrelay.bearer_headers("t").get("Authorization").unwrap(),
    "Bearer t",
  )
}

///|
test "adapters: error helpers" {
  let e = @imrelay.ApiError::network("socket closed")
  assert_eq(e.code, -1)
  assert_eq(@imrelay.api_error_message(e), "socket closed")
  assert_true(e.is_transient())
  let http = @imrelay.ApiError::http(400, "chat not found")
  assert_eq(@imrelay.api_error_message(http), "HTTP 400: chat not found")
  assert_eq(http.is_transient(), false)
}

///|
test "adapters: send_failure and send_body_failure classify" {
  let net = @imrelay.send_failure(
    "telegram",
    @imrelay.ApiError::network("connection reset"),
  )
  assert_eq(net.success, false)
  assert_eq(net.retryable, true)
  assert_eq(net.error, Some("telegram: connection reset"))
  let long = @imrelay.send_body_failure("discord", "message is too long")
  assert_eq(long.error_kind, Some(@imrelay.TooLong))
  let missing = @imrelay.missing_config(@imrelay.Telegram, "bot token")
  assert_eq(missing.error, Some("telegram: missing bot token"))
  assert_eq(missing.error_kind, Some(@imrelay.Forbidden))
}

///|
test "adapters: send_ok keeps the raw payload" {
  let r = @imrelay.send_ok(Some("5"), t_json("{\"ok\":true}"))
  assert_eq(r.success, true)
  assert_eq(r.message_id, Some("5"))
  assert_true(r.raw.unwrap().contains("true"))
}

///|
test "adapters: result_object unwraps or classifies" {
  match @imrelay.result_object(Ok(t_json("{\"ok\":true}")), "x") {
    Ok(j) => assert_eq(@imrelay.json_field_bool(j, "ok"), Some(true))
    Err(_) => fail("unexpected failure")
  }
  match
    @imrelay.result_object(Err(@imrelay.ApiError::network("timeout")), "x") {
    Ok(_) => fail("unexpected success")
    Err(r) => assert_eq(r.retryable, true)
  }
}

///|
test "adapters: graph_error_message" {
  let j = t_json("{\"error\":{\"message\":\"bad token\"}}")
  assert_eq(@imrelay.graph_error_message(j), Some("bad token"))
  assert_eq(@imrelay.graph_error_message(t_json("{}")), None)
}
