// Gateway configuration.
//
// Two sources are supported, mirroring Hermes:
//
//  1. A TOML file (preferred) — `gateway.toml`, parsed by
//     `moonbit-community/toml`. This is the format `example/gateway.toml`
//     documents.
//  2. The process environment — the same variables that configure Hermes
//     (`TELEGRAM_BOT_TOKEN`, `DISCORD_BOT_TOKEN`, ... see `from_env`).
//
// `GatewayConfig::load` prefers an explicit TOML path when given one and falls
// back to the environment otherwise.

///|
/// Per-platform settings, mirroring Hermes' `PlatformConfig`.
pub(all) struct PlatformConfig {
  platform : Platform
  enabled : Bool
  token : String?
  api_key : String?
  /// Platform-specific fields Hermes would keep in `PlatformConfig.extra`
  /// (URLs, ids, modes); see each adapter for the keys it reads.
  extra : Map[String, String]
  home_channel : HomeChannel?
  /// Allowlisted user ids (`allow_from` in Hermes).
  allowed_users : Array[String]
} derive(Debug)

///|
pub fn PlatformConfig::new(
  platform : Platform,
  enabled~ : Bool = true,
  token? : String,
  api_key? : String,
  extra~ : Map[String, String] = Map([]),
  home_channel? : HomeChannel,
  allowed_users~ : Array[String] = [],
) -> PlatformConfig {
  { platform, enabled, token, api_key, extra, home_channel, allowed_users, }
}

///|
pub fn PlatformConfig::get(self : PlatformConfig, key : String) -> String? {
  self.extra.get(key)
}

///|
pub fn PlatformConfig::get_or(
  self : PlatformConfig,
  key : String,
  default : String,
) -> String {
  self.extra.get(key).unwrap_or(default)
}

///|
pub fn PlatformConfig::require(
  self : PlatformConfig,
  key : String,
  what : String,
) -> String raise {
  match self.extra.get(key) {
    Some(v) =>
      if v.is_empty() {
        raise UtilsError::MissingConfig("\{what}: missing \{key}")
      } else {
        v
      }
    None => raise UtilsError::MissingConfig("\{what}: missing \{key}")
  }
}

///|
/// The credential an adapter should authenticate with: `token` first, then
/// `api_key` (Hermes treats both as the platform bearer).
pub fn PlatformConfig::bearer(self : PlatformConfig) -> String? {
  match self.token {
    Some(t) => if t.is_empty() { self.api_key } else { Some(t) }
    None => self.api_key
  }
}

///|
/// The whole gateway: one config per platform plus process-wide settings.
pub(all) struct GatewayConfig {
  platforms : Map[Platform, PlatformConfig]
  /// Gateway display name (`[gateway] name`).
  mut name : String
  /// Webhook listen host (`[gateway] host`).
  mut host : String
  /// Webhook listen port (`[gateway] port`).
  mut port : Int32
  /// Public base URL used to build webhook URLs (`[gateway] public_url`).
  mut public_url : String?
  /// Global allowlist (`GATEWAY_ALLOWED_USERS`).
  mut allowed_users : Array[String]
  /// Explicit allow-all switch (`GATEWAY_ALLOW_ALL_USERS`).
  mut allow_all_users : Bool
} derive(Debug)

///|
pub fn GatewayConfig::default_config() -> GatewayConfig {
  {
    platforms: Map([]),
    name: "imrelay",
    host: "0.0.0.0",
    port: 8080,
    public_url: None,
    allowed_users: [],
    allow_all_users: false,
  }
}

///|
/// Which platforms ended up enabled (Hermes `get_connected_platforms()`).
pub fn GatewayConfig::enabled_platforms(
  self : GatewayConfig,
) -> Array[Platform] {
  let out : Array[Platform] = []
  for p, c in self.platforms {
    if c.enabled {
      out.push(p)
    }
  }
  out
}

///|
pub fn GatewayConfig::get(
  self : GatewayConfig,
  platform : Platform,
) -> PlatformConfig? {
  self.platforms.get(platform)
}

///|
/// Whether any allowlist (gateway-wide or per platform) is configured.
pub fn GatewayConfig::has_any_allowed_users(self : GatewayConfig) -> Bool {
  if self.allowed_users.length() > 0 {
    return true
  }
  for _, c in self.platforms {
    if c.allowed_users.length() > 0 {
      return true
    }
  }
  false
}

///|
/// Webhook callback URL for a platform, e.g. `https://host/telegram`.
pub fn GatewayConfig::webhook_url(
  self : GatewayConfig,
  path : String,
) -> String? {
  match self.public_url {
    Some(base) =>
      if base.is_empty() {
        None
      } else {
        let b = if base.has_suffix("/") {
          base[:base.length() - 1].to_owned()
        } else {
          base
        }
        let p = if path.has_prefix("/") { path[1:].to_owned() } else { path }
        Some("\{b}/\{p}")
      }
    None => None
  }
}

///|
/// Split a comma-separated allowlist string, trimming blanks.
fn split_list(s : String) -> Array[String] {
  let out : Array[String] = []
  for part in s.split(",") {
    let t = part.trim().to_owned()
    if !t.is_empty() {
      out.push(t)
    }
  }
  out
}

// --- TOML loading ---------------------------------------------------------

///|
fn toml_str(v : @toml.TomlValue) -> String? {
  match v {
    @toml.TomlString(s) => Some(s)
    _ => None
  }
}

///|
fn toml_bool(v : @toml.TomlValue) -> Bool? {
  match v {
    @toml.TomlBoolean(b) => Some(b)
    _ => None
  }
}

///|
fn toml_int(v : @toml.TomlValue) -> Int32? {
  match v {
    @toml.TomlInteger(i) => Some(i.to_int())
    @toml.TomlString(s) => Some(@string.parse_int(s)) catch { _ => None }
    _ => None
  }
}

///|
fn toml_str_array(v : @toml.TomlValue) -> Array[String] {
  match v {
    @toml.TomlArray(a) => {
      let out : Array[String] = []
      for item in a {
        match item {
          @toml.TomlString(s) => out.push(s)
          @toml.TomlInteger(i) => out.push(i.to_string())
          _ => ()
        }
      }
      out
    }
    @toml.TomlString(s) => if s.is_empty() { [] } else { split_list(s) }
    _ => []
  }
}

///|
fn toml_table(v : @toml.TomlValue) -> Map[String, @toml.TomlValue]? {
  match v {
    @toml.TomlTable(t) => Some(t)
    _ => None
  }
}

///|
/// Reserved per-platform keys read directly from `extra` into typed fields;
/// everything else lands in `PlatformConfig.extra`.
fn is_known_platform_key(key : String) -> Bool {
  match key {
    "enabled"
    | "token"
    | "api_key"
    | "home_channel"
    | "home_channel_name"
    | "home_channel_thread"
    | "allowed_users"
    | "extra" => true
    _ => false
  }
}

///|
fn platform_from_toml(
  platform : Platform,
  t : Map[String, @toml.TomlValue],
) -> PlatformConfig {
  let mut enabled = true
  let mut token : String? = None
  let mut api_key : String? = None
  let mut allowed_users : Array[String] = []
  let mut home_channel : HomeChannel? = None
  let extra : Map[String, String] = Map([])

  for key, value in t {
    match key {
      "enabled" =>
        match toml_bool(value) {
          Some(b) => enabled = b
          None => ()
        }
      "token" =>
        match toml_str(value) {
          Some(s) => token = Some(s)
          None => ()
        }
      "api_key" =>
        match toml_str(value) {
          Some(s) => api_key = Some(s)
          None => ()
        }
      "allowed_users" => allowed_users = toml_str_array(value)
      "home_channel" =>
        match toml_str(value) {
          Some(chat_id) => {
            let name = match t.get("home_channel_name") {
              Some(@toml.TomlString(n)) => n
              _ => "Home"
            }
            let thread_id = match t.get("home_channel_thread") {
              Some(@toml.TomlString(x)) => Some(x)
              _ => None
            }
            home_channel = Some(
              HomeChannel::new(platform, chat_id, name~, thread_id?),
            )
          }
          None => ()
        }
      "home_channel_name" | "home_channel_thread" => ()
      "extra" =>
        match toml_table(value) {
          Some(sub) =>
            for k, v in sub {
              match toml_scalar_string(v) {
                Some(s) => extra.set(k, s)
                None => ()
              }
            }
          None => ()
        }
      _ =>
        if !is_known_platform_key(key) {
          match toml_scalar_string(value) {
            Some(s) => extra.set(key, s)
            None => ()
          }
        }
    }
  }
  PlatformConfig::new(
    platform,
    enabled~,
    token?,
    api_key?,
    extra~,
    home_channel?,
    allowed_users~,
  )
}

///|
/// Render any scalar TOML value as the string form `extra` stores.
fn toml_scalar_string(v : @toml.TomlValue) -> String? {
  match v {
    @toml.TomlString(s) => Some(s)
    @toml.TomlInteger(i) => Some(i.to_string())
    @toml.TomlFloat(f) => Some(f.to_string())
    @toml.TomlBoolean(b) => Some(b.to_string())
    @toml.TomlArray(_) => None
    @toml.TomlTable(_) => None
    @toml.TomlDateTime(_) => None
  }
}

///|
/// Parse a `gateway.toml` document into a `GatewayConfig`.
pub fn GatewayConfig::from_toml(text : String) -> GatewayConfig raise {
  let root = @toml.parse(text)
  let table = match root {
    @toml.TomlTable(t) => t
    _ => raise UtilsError::InvalidArgument("gateway.toml: root must be a table")
  }
  let cfg = GatewayConfig::default_config()
  match table.get("gateway") {
    Some(@toml.TomlTable(g)) =>
      for key, value in g {
        match key {
          "name" =>
            match toml_str(value) {
              Some(s) => cfg.name = s
              None => ()
            }
          "host" =>
            match toml_str(value) {
              Some(s) => cfg.host = s
              None => ()
            }
          "port" =>
            match toml_int(value) {
              Some(p) => cfg.port = p
              None => ()
            }
          "public_url" =>
            match toml_str(value) {
              Some(s) => cfg.public_url = Some(s)
              None => ()
            }
          "allowed_users" => cfg.allowed_users = toml_str_array(value)
          "allow_all_users" =>
            match toml_bool(value) {
              Some(b) => cfg.allow_all_users = b
              None => ()
            }
          _ => ()
        }
      }
    _ => ()
  }
  match table.get("platforms") {
    Some(@toml.TomlTable(ps)) =>
      for name, value in ps {
        match Platform::of_value(name) {
          Some(p) =>
            match toml_table(value) {
              Some(pt) => cfg.platforms.set(p, platform_from_toml(p, pt))
              None => ()
            }
          None => ()
        }
      }
    _ => ()
  }
  cfg
}

///|
/// Read and parse a TOML config file.
pub async fn GatewayConfig::from_toml_file(path : String) -> GatewayConfig {
  let content = @fs.read_file(path).text()
  GatewayConfig::from_toml(content)
}

// --- Environment loading --------------------------------------------------

///|
fn env(name : String) -> String? {
  match @env.get_env_var(name) {
    Some(s) => if s.is_empty() { None } else { Some(s) }
    None => None
  }
}

///|
fn env_truthy(names : Array[String]) -> Bool {
  for name in names {
    match env(name) {
      Some(_) => return true
      None => ()
    }
  }
  false
}

///|
fn all_env(names : Array[String]) -> Bool {
  for name in names {
    match env(name) {
      Some(_) => continue
      None => return false
    }
  }
  true
}

///|
fn env_list(names : Array[String]) -> Array[String] {
  for name in names {
    match env(name) {
      Some(s) => return split_list(s)
      None => ()
    }
  }
  []
}

///|
fn home_channel(
  env_base : String,
  name_env : String,
  platform : Platform,
) -> HomeChannel? {
  match env(env_base) {
    Some(chat_id) =>
      Some(
        HomeChannel::new(
          platform,
          chat_id,
          name=env(name_env).unwrap_or("Home"),
        ),
      )
    None => None
  }
}

///|
/// Build the gateway from a single TOML document when available, otherwise
/// from the process environment (Hermes-compatible variable names).
pub fn GatewayConfig::load(toml_text : String?) -> GatewayConfig raise {
  match toml_text {
    Some(text) => GatewayConfig::from_toml(text)
    None => GatewayConfig::from_env()
  }
}

///|
/// Build from the process environment, Hermes-style: a platform is enabled
/// when its required credentials are present (all-of; Matrix accepts the
/// access token *or* a password).
pub fn GatewayConfig::from_env() -> GatewayConfig {
  let cfg = GatewayConfig::default_config()
  let global_users = env_list(["GATEWAY_ALLOWED_USERS"])
  cfg.allowed_users = global_users
  cfg.allow_all_users = env_truthy(["GATEWAY_ALLOW_ALL_USERS"])

  // Telegram
  if all_env(["TELEGRAM_BOT_TOKEN"]) {
    let extra : Map[String, String] = Map([])
    match env("TELEGRAM_WEBHOOK_SECRET") {
      Some(v) => extra.set("webhook_secret", v)
      None => ()
    }
    cfg.platforms.set(
      Telegram,
      PlatformConfig::new(
        Telegram,
        token?=env("TELEGRAM_BOT_TOKEN"),
        extra~,
        home_channel?=home_channel(
          "TELEGRAM_HOME_CHANNEL",
          "TELEGRAM_HOME_CHANNEL_NAME",
          Telegram,
        ),
        allowed_users=env_list(["TELEGRAM_ALLOWED_USERS"]),
      ),
    )
  }
  // Discord
  if all_env(["DISCORD_BOT_TOKEN"]) {
    cfg.platforms.set(
      Discord,
      PlatformConfig::new(
        Discord,
        token?=env("DISCORD_BOT_TOKEN"),
        home_channel?=home_channel(
          "DISCORD_HOME_CHANNEL",
          "DISCORD_HOME_CHANNEL_NAME",
          Discord,
        ),
        allowed_users=env_list(["DISCORD_ALLOWED_USERS"]),
      ),
    )
  }
  // Slack
  if all_env(["SLACK_BOT_TOKEN"]) {
    let extra : Map[String, String] = Map([])
    match env("SLACK_APP_TOKEN") {
      Some(t) => extra.set("app_token", t)
      None => ()
    }
    match env("SLACK_SIGNING_SECRET") {
      Some(v) => extra.set("signing_secret", v)
      None => ()
    }
    cfg.platforms.set(
      Slack,
      PlatformConfig::new(
        Slack,
        token?=env("SLACK_BOT_TOKEN"),
        extra~,
        home_channel?=home_channel(
          "SLACK_HOME_CHANNEL",
          "SLACK_HOME_CHANNEL_NAME",
          Slack,
        ),
        allowed_users=env_list(["SLACK_ALLOWED_USERS"]),
      ),
    )
  }
  // WhatsApp Cloud API (Meta) — phone number id + access token
  if all_env(["WHATSAPP_CLOUD_PHONE_NUMBER_ID", "WHATSAPP_CLOUD_ACCESS_TOKEN"]) {
    let extra : Map[String, String] = Map([])
    extra.set(
      "phone_number_id",
      env("WHATSAPP_CLOUD_PHONE_NUMBER_ID").unwrap_or(""),
    )
    match env("WHATSAPP_CLOUD_API_VERSION") {
      Some(v) => extra.set("api_version", v)
      None => ()
    }
    match env("WHATSAPP_CLOUD_VERIFY_TOKEN") {
      Some(v) => extra.set("verify_token", v)
      None => ()
    }
    match env("WHATSAPP_CLOUD_APP_SECRET") {
      Some(v) => extra.set("app_secret", v)
      None => ()
    }
    cfg.platforms.set(
      Whatsapp,
      PlatformConfig::new(
        Whatsapp,
        api_key?=env("WHATSAPP_CLOUD_ACCESS_TOKEN"),
        extra~,
        home_channel?=home_channel(
          "WHATSAPP_CLOUD_HOME_CHANNEL",
          "WHATSAPP_CLOUD_HOME_CHANNEL_NAME",
          Whatsapp,
        ),
        allowed_users=env_list(["WHATSAPP_ALLOWED_USERS"]),
      ),
    )
  }
  // Signal (signal-cli HTTP daemon)
  if all_env(["SIGNAL_HTTP_URL", "SIGNAL_ACCOUNT"]) {
    let extra : Map[String, String] = Map([])
    extra.set("http_url", env("SIGNAL_HTTP_URL").unwrap_or(""))
    extra.set("account", env("SIGNAL_ACCOUNT").unwrap_or(""))
    cfg.platforms.set(
      Signal,
      PlatformConfig::new(
        Signal,
        extra~,
        home_channel?=home_channel(
          "SIGNAL_HOME_CHANNEL",
          "SIGNAL_HOME_CHANNEL_NAME",
          Signal,
        ),
        allowed_users=env_list(["SIGNAL_ALLOWED_USERS"]),
      ),
    )
  }
  // Email
  if all_env(["EMAIL_ADDRESS", "EMAIL_PASSWORD", "EMAIL_SMTP_HOST"]) {
    let extra : Map[String, String] = Map([])
    extra.set("address", env("EMAIL_ADDRESS").unwrap_or(""))
    extra.set("smtp_host", env("EMAIL_SMTP_HOST").unwrap_or(""))
    match env("EMAIL_SMTP_PORT") {
      Some(v) => extra.set("smtp_port", v)
      None => ()
    }
    extra.set("password", env("EMAIL_PASSWORD").unwrap_or(""))
    match env("EMAIL_IMAP_HOST") {
      Some(v) => extra.set("imap_host", v)
      None => ()
    }
    cfg.platforms.set(
      Email,
      PlatformConfig::new(
        Email,
        extra~,
        home_channel?=home_channel(
          "EMAIL_HOME_ADDRESS",
          "EMAIL_HOME_ADDRESS_NAME",
          Email,
        ),
        allowed_users=env_list(["EMAIL_ALLOWED_USERS"]),
      ),
    )
  }
  // Mattermost
  if all_env(["MATTERMOST_TOKEN"]) {
    let extra : Map[String, String] = Map([])
    match env("MATTERMOST_URL") {
      Some(v) => extra.set("url", v)
      None => ()
    }
    match env("MATTERMOST_WEBHOOK_TOKEN") {
      Some(v) => extra.set("webhook_token", v)
      None => ()
    }
    cfg.platforms.set(
      Mattermost,
      PlatformConfig::new(
        Mattermost,
        token?=env("MATTERMOST_TOKEN"),
        extra~,
        home_channel?=home_channel(
          "MATTERMOST_HOME_CHANNEL",
          "MATTERMOST_HOME_CHANNEL_NAME",
          Mattermost,
        ),
        allowed_users=env_list(["MATTERMOST_ALLOWED_USERS"]),
      ),
    )
  }
  // Matrix (homeserver required; access token XOR password)
  if env_truthy(["MATRIX_HOMESERVER"]) &&
    (env_truthy(["MATRIX_ACCESS_TOKEN"]) || env_truthy(["MATRIX_PASSWORD"])) {
    let extra : Map[String, String] = Map([])
    extra.set("homeserver", env("MATRIX_HOMESERVER").unwrap_or(""))
    match env("MATRIX_USER_ID") {
      Some(v) => extra.set("user_id", v)
      None => ()
    }
    match env("MATRIX_PASSWORD") {
      Some(v) => extra.set("password", v)
      None => ()
    }
    cfg.platforms.set(
      Matrix,
      PlatformConfig::new(
        Matrix,
        token?=env("MATRIX_ACCESS_TOKEN"),
        extra~,
        home_channel?=home_channel(
          "MATRIX_HOME_ROOM",
          "MATRIX_HOME_ROOM_NAME",
          Matrix,
        ),
        allowed_users=env_list(["MATRIX_ALLOWED_USERS"]),
      ),
    )
  }
  // DingTalk (app key/secret for Stream Mode + app-robot API; a static group
  // robot webhook works on its own)
  if all_env(["DINGTALK_CLIENT_ID", "DINGTALK_CLIENT_SECRET"]) ||
    env_truthy(["DINGTALK_WEBHOOK_URL"]) {
    let extra : Map[String, String] = Map([])
    match env("DINGTALK_CLIENT_ID") {
      Some(v) => extra.set("client_id", v)
      None => ()
    }
    match env("DINGTALK_CLIENT_SECRET") {
      Some(v) => extra.set("client_secret", v)
      None => ()
    }
    match env("DINGTALK_WEBHOOK_URL") {
      Some(v) => extra.set("webhook_url", v)
      None => ()
    }
    match env("DINGTALK_ROBOT_CODE") {
      Some(v) => extra.set("robot_code", v)
      None => ()
    }
    match env("DINGTALK_STREAM") {
      Some(v) => extra.set("stream", v)
      None => ()
    }
    match env("DINGTALK_REQUIRE_MENTION") {
      Some(v) => extra.set("require_mention", v)
      None => ()
    }
    match env("DINGTALK_FREE_RESPONSE_CHATS") {
      Some(v) => extra.set("free_response_chats", v)
      None => ()
    }
    match env("DINGTALK_MENTION_PATTERNS") {
      Some(v) => extra.set("mention_patterns", v)
      None => ()
    }
    cfg.platforms.set(
      Dingtalk,
      PlatformConfig::new(
        Dingtalk,
        extra~,
        home_channel?=home_channel(
          "DINGTALK_HOME_CHANNEL",
          "DINGTALK_HOME_CHANNEL_NAME",
          Dingtalk,
        ),
        allowed_users=env_list(["DINGTALK_ALLOWED_USERS"]),
      ),
    )
  }
  // Feishu / Lark
  if all_env(["FEISHU_APP_ID", "FEISHU_APP_SECRET"]) {
    let extra : Map[String, String] = Map([])
    extra.set("app_id", env("FEISHU_APP_ID").unwrap_or(""))
    extra.set("app_secret", env("FEISHU_APP_SECRET").unwrap_or(""))
    match env("FEISHU_DOMAIN") {
      Some(v) => extra.set("domain", v)
      None => ()
    }
    cfg.platforms.set(
      Feishu,
      PlatformConfig::new(
        Feishu,
        extra~,
        home_channel?=home_channel(
          "FEISHU_HOME_CHANNEL",
          "FEISHU_HOME_CHANNEL_NAME",
          Feishu,
        ),
        allowed_users=env_list(["FEISHU_ALLOWED_USERS"]),
      ),
    )
  }
  // Weixin (personal WeChat via the third-party iLink Bot bridge)
  if all_env(["WEIXIN_ACCOUNT_ID", "WEIXIN_TOKEN"]) {
    let extra : Map[String, String] = Map([])
    extra.set("account_id", env("WEIXIN_ACCOUNT_ID").unwrap_or(""))
    extra.set("token", env("WEIXIN_TOKEN").unwrap_or(""))
    match env("WEIXIN_BASE_URL") {
      Some(v) => extra.set("base_url", v)
      None => ()
    }
    cfg.platforms.set(
      Weixin,
      PlatformConfig::new(
        Weixin,
        extra~,
        home_channel?=home_channel(
          "WEIXIN_HOME_CHANNEL",
          "WEIXIN_HOME_CHANNEL_NAME",
          Weixin,
        ),
        allowed_users=env_list(["WEIXIN_ALLOWED_USERS"]),
      ),
    )
  }
  // WeCom (Enterprise WeChat, self-built app REST; optional group-robot webhook)
  if all_env(["WECOM_CALLBACK_CORP_ID", "WECOM_CALLBACK_CORP_SECRET"]) {
    let extra : Map[String, String] = Map([])
    extra.set("corp_id", env("WECOM_CALLBACK_CORP_ID").unwrap_or(""))
    extra.set("corp_secret", env("WECOM_CALLBACK_CORP_SECRET").unwrap_or(""))
    match env("WECOM_CALLBACK_AGENT_ID") {
      Some(v) => extra.set("agent_id", v)
      None => ()
    }
    match env("WECOM_CALLBACK_TOKEN") {
      Some(v) => extra.set("callback_token", v)
      None => ()
    }
    match env("WECOM_CALLBACK_ENCODING_AES_KEY") {
      Some(v) => extra.set("encoding_aes_key", v)
      None => ()
    }
    match env("WECOM_GROUP_ROBOT_WEBHOOK") {
      Some(v) => extra.set("group_robot_webhook", v)
      None => ()
    }
    cfg.platforms.set(
      Wecom,
      PlatformConfig::new(
        Wecom,
        extra~,
        home_channel?=home_channel(
          "WECOM_HOME_CHANNEL",
          "WECOM_HOME_CHANNEL_NAME",
          Wecom,
        ),
        allowed_users=env_list(["WECOM_ALLOWED_USERS"]),
      ),
    )
  }
  // BlueBubbles
  if all_env(["BLUEBUBBLES_SERVER_URL", "BLUEBUBBLES_PASSWORD"]) {
    let extra : Map[String, String] = Map([])
    extra.set("server_url", env("BLUEBUBBLES_SERVER_URL").unwrap_or(""))
    extra.set("password", env("BLUEBUBBLES_PASSWORD").unwrap_or(""))
    cfg.platforms.set(
      Bluebubbles,
      PlatformConfig::new(
        Bluebubbles,
        extra~,
        home_channel?=home_channel(
          "BLUEBUBBLES_HOME_CHANNEL",
          "BLUEBUBBLES_HOME_CHANNEL_NAME",
          Bluebubbles,
        ),
        allowed_users=env_list(["BLUEBUBBLES_ALLOWED_USERS"]),
      ),
    )
  }
  // Home Assistant (plugin-documented HASS_* variables)
  if env_truthy(["HASS_TOKEN"]) {
    let extra : Map[String, String] = Map([])
    match env("HASS_URL") {
      Some(v) => extra.set("url", v)
      None => ()
    }
    cfg.platforms.set(
      HomeAssistant,
      PlatformConfig::new(
        HomeAssistant,
        token?=env("HASS_TOKEN"),
        extra~,
        home_channel?=home_channel(
          "HASS_HOME_CHANNEL",
          "HASS_HOME_CHANNEL_NAME",
          HomeAssistant,
        ),
        allowed_users=env_list(["HASS_ALLOWED_USERS"]),
      ),
    )
  }
  cfg
}

///|
/// Load configuration the way the gateway binary wants it: `$IMRELAY_CONFIG`
/// (or `gateway.toml` in the working directory) when that file exists,
/// otherwise the Hermes-style environment variables.
pub async fn GatewayConfig::load_default() -> GatewayConfig {
  let path = match @env.get_env_var("IMRELAY_CONFIG") {
    Some(p) => p
    None => "gateway.toml"
  }
  if @fs.exists(path) {
    let text = @fs.read_file(path).text()
    GatewayConfig::from_toml(text)
  } else {
    GatewayConfig::from_env()
  }
}
