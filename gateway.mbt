// Gateway runtime: webhook server, long-pollers and the event loop.
//
// Mirrors Hermes' gateway loop: inbound events from every configured platform
// are normalized, folded into a per-chat `Session`, answered by the agent
// callback, and delivered back through the platform adapter (chunked, with
// typing indicators and silence-token suppression).

///|
/// The agent callback. Receives the inbound event and returns the reply text;
/// an empty string (or a silence token) suppresses delivery.
pub(all) struct Gateway {
  cfg : GatewayConfig
  store : SessionStore
  handler : async (MessageEvent, Session) -> String
} derive(Debug)

///|
/// Build a gateway over ``cfg`` with ``handler`` as the agent.
pub fn Gateway::new(
  cfg : GatewayConfig,
  handler : async (MessageEvent, Session) -> String,
  max_history~ : Int32 = 24,
) -> Gateway {
  { cfg, store: SessionStore::new(max_history~), handler, }
}

///|
/// Whether a sender may talk to the agent. `allow_all_users` admits everyone;
/// otherwise the user id (falling back to the chat id when the platform has no
/// per-user id) must appear in the platform or gateway allowlist — or match
/// the `*` wildcard. With no allowlist configured and no opt-in the gate is
/// closed (Hermes' `GATEWAY_ALLOW_ALL_USERS` posture).
pub fn user_allowed(
  cfg : GatewayConfig,
  pcfg : PlatformConfig,
  user_id : String?,
  chat_id : String,
) -> Bool {
  if cfg.allow_all_users {
    return true
  }
  if pcfg.allowed_users.length() == 0 && cfg.allowed_users.length() == 0 {
    return false
  }
  let who = match user_id {
    Some(u) => if u.is_empty() { chat_id } else { u }
    None => chat_id
  }
  for entry in pcfg.allowed_users {
    if entry == "*" || entry == who {
      return true
    }
  }
  for entry in cfg.allowed_users {
    if entry == "*" || entry == who {
      return true
    }
  }
  false
}

///|
/// Handle one inbound event: record the turn, answer slash commands locally,
/// otherwise call the agent and deliver the reply.
pub async fn Gateway::handle_event(self : Gateway, ev : MessageEvent) -> Unit {
  match self.cfg.get(ev.platform) {
    None => ()
    Some(pcfg) => {
      if !pcfg.enabled {
        return
      }
      if !user_allowed(self.cfg, pcfg, ev.user_id, ev.chat_id) {
        log_line(
          "[imrelay] ignored \{ev.platform.value()} message from unauthorized sender \{ev.user_id.unwrap_or(ev.chat_id)} (chat \{ev.chat_id}); configure allowed_users or allow_all_users",
        )
        return
      }
      let session = self.store.session(ev.platform, ev.chat_id)
      match ev.message_id {
        Some(id) => session.set_last_message_id(id)
        None => ()
      }
      match ev.reply_to_message_id {
        Some(t) => session.set_thread_id(t)
        None => ()
      }
      match parse_command(ev.text) {
        Some(cmd) =>
          match command_reply(cmd, self.cfg, session) {
            Some(reply) => deliver_reply(pcfg, session, ev, reply)
            None => {
              session.push("user", ev.text)
              self.answer(pcfg, session, ev)
            }
          }
        None => {
          session.push("user", ev.text)
          self.answer(pcfg, session, ev)
        }
      }
    }
  }
}

///|
/// Invoke the agent with a typing indicator, then deliver the reply.
async fn Gateway::answer(
  self : Gateway,
  pcfg : PlatformConfig,
  session : Session,
  ev : MessageEvent,
) -> Unit {
  send_typing(pcfg, ev.chat_id, thread_id?=session.thread_id())
  let reply = (self.handler)(ev, session)
  session.push("assistant", reply)
  deliver_reply(pcfg, session, ev, reply)
}

///|
/// Deliver a reply, honouring silence tokens and recording the new message id.
async fn deliver_reply(
  pcfg : PlatformConfig,
  session : Session,
  ev : MessageEvent,
  reply : String,
) -> Unit {
  if is_silent_reply(reply) {
    return
  }
  let r = send_message(
    pcfg,
    ev.chat_id,
    reply,
    thread_id?=session.thread_id(),
    context_token?=session.context_token(),
  )
  match r.message_id {
    Some(id) => session.set_last_message_id(id)
    None => ()
  }
  if !r.success {
    let err = r.error.unwrap_or("unknown")
    log_line(
      "[imrelay] send to \{ev.platform.value()}:\{ev.chat_id} failed: \{err}",
    )
  }
}

///|
/// Start the gateway: an HTTP webhook server plus a long-poll loop for every
/// platform configured for polling. Runs until the task group is cancelled.
pub async fn Gateway::run(self : Gateway) -> Unit {
  let addr = @socket.Addr::parse("\{self.cfg.host}:\{self.cfg.port}") catch {
    e => {
      log_line(
        "[imrelay] invalid listen address \{self.cfg.host}:\{self.cfg.port}: \{e}",
      )
      return
    }
  }
  let server = @http.Server(addr, reuse_addr=true)
  log_line(
    "[imrelay] gateway listening on \{self.cfg.host}:\{self.cfg.port} (platforms: \{self.cfg.enabled_platforms().length()})",
  )
  if !self.cfg.allow_all_users && !self.cfg.has_any_allowed_users() {
    log_line(
      "[imrelay] warning: no allowed_users configured and allow_all_users is false — inbound messages will be ignored (set [gateway] allowed_users, per-platform allowed_users, or allow_all_users = true)",
    )
  }
  @async.with_task_group(group => {
    for platform in self.cfg.enabled_platforms() {
      match self.cfg.get(platform) {
        Some(pcfg) => {
          if platform == Telegram {
            match pcfg.token_of() {
              Some(token) =>
                if pcfg.extra_bool("polling", true) {
                  let gw = self
                  group.spawn_bg(no_wait=true, () => {
                    poll_telegram(gw, pcfg, token)
                  })
                }
              None => ()
            }
          }
          if platform == Weixin {
            match pcfg.token_of() {
              Some(token) =>
                if pcfg.extra_bool("polling", true) {
                  let gw = self
                  group.spawn_bg(no_wait=true, () => {
                    poll_weixin(gw, pcfg, token)
                  })
                }
              None => ()
            }
          }
          if platform == Dingtalk {
            // Stream Mode: no public callback URL needed. Needs the app
            // key/secret; `[dingtalk.extra] stream = false` opts out.
            if dingtalk_stream_enabled(pcfg) {
              let gw = self
              group.spawn_bg(no_wait=true, () => poll_dingtalk_stream(gw, pcfg))
            }
          }
          if platform == Matrix {
            if pcfg.extra_bool("polling", true) &&
              !matrix_homeserver(pcfg).is_empty() {
              let gw = self
              group.spawn_bg(no_wait=true, () => {
                match matrix_resolve_token(pcfg) {
                  Some(token) => {
                    let self_user = matrix_self_user(pcfg, token)
                    if self_user.is_empty() {
                      log_line(
                        "[imrelay] matrix: could not resolve the bot user id; own messages may echo back (set [matrix.extra] user_id)",
                      )
                    }
                    poll_matrix(gw, pcfg, token, self_user)
                  }
                  None =>
                    log_line(
                      "[imrelay] matrix: no access token (set token / MATRIX_ACCESS_TOKEN, or user_id + password)",
                    )
                }
              })
            }
          }
        }
        None => ()
      }
    }
    server.run_forever((request, body, conn) => {
      self.handle_webhook(request, body, conn)
    })
  })
}

///|
/// Route one inbound webhook request.
async fn Gateway::handle_webhook(
  self : Gateway,
  request : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  let route = match request.path.split_once("?") {
    Some((p, _)) => p.to_owned()
    None => request.path
  }
  let seg = if route.has_prefix("/") { route[1:].to_owned() } else { route }
  let raw = body.read_all().text() catch { _ => "" }
  if seg.is_empty() {
    respond_html(conn, 200, self.landing_html())
    return
  }
  if seg == "health" {
    respond_text(
      conn,
      200,
      "OK",
      "{\"ok\":true,\"platforms\":\{self.cfg.enabled_platforms().length()}}",
    )
    return
  }
  match Platform::of_value(seg) {
    None =>
      respond_text(
        conn,
        404,
        "Not Found",
        "{\"error\":\"unknown platform\",\"path\":\"\{seg}\"}",
      )
    Some(platform) => {
      let pcfg = match self.cfg.get(platform) {
        Some(p) => p
        None => {
          respond_text(
            conn,
            404,
            "Not Found",
            "{\"error\":\"platform not configured\",\"platform\":\"\{platform.value()}\"}",
          )
          return
        }
      }
      if !pcfg.enabled {
        respond_text(
          conn,
          404,
          "Not Found",
          "{\"error\":\"platform disabled\",\"platform\":\"\{platform.value()}\"}",
        )
        return
      }
      if platform == Whatsapp {
        // The subscription handshake (`hub.*` GET) authenticates with
        // `verify_token`, not with a body signature.
        match whatsapp_hub_params(request.path) {
          Some(_) => {
            ignore(self.handle_verification(platform, request, raw, conn))
            return
          }
          None => ()
        }
      }
      if platform == Wecom {
        // The URL-verification handshake carries `msg_signature` in its query
        // and must answer the decrypted `echostr`.
        match wecom_callback_params(request.path).echostr {
          Some(_) => {
            ignore(self.handle_verification(platform, request, raw, conn))
            return
          }
          None => ()
        }
      }
      let (status, reason) = webhook_auth_status(platform, pcfg, request, raw)
      if status != 0 {
        respond_text(
          conn,
          status,
          http_reason(status),
          "{\"error\":\"webhook rejected\",\"reason\":\"\{reason}\"}",
        )
        return
      }
      let handled = self.handle_verification(platform, request, raw, conn)
      if handled {
        return
      }
      let body = match platform {
        Wecom =>
          match wecom_unwrap_callback(pcfg, raw) {
            Ok(b) => b
            Err(reason) => {
              respond_text(
                conn,
                400,
                "Bad Request",
                "{\"error\":\"wecom callback rejected\",\"reason\":\"\{reason}\"}",
              )
              return
            }
          }
        _ => raw
      }
      let events = parse_inbound(platform, body, cfg=pcfg)
      if platform == Wecom {
        // WeCom expects the literal `success` text (or an empty body).
        respond_text(conn, 200, "OK", "success")
      } else {
        respond_text(
          conn,
          200,
          "OK",
          "{\"ok\":true,\"accepted\":\{events.length()}}",
        )
      }
      for ev in events {
        self.handle_event(ev)
      }
    }
  }
}

///|
/// Authenticate one inbound webhook request: `(0, "")` when the request may be
/// processed, or an HTTP status and reason when it must be rejected. Webhook
/// payloads that carry a platform signature (`slack`, `whatsapp`, `telegram`)
/// fail closed while no secret is configured; platforms with no signature
/// scheme only check once a shared secret is configured. WeCom checks
/// `msg_signature` once callback crypto (`encoding_aes_key`) is configured.
pub fn webhook_auth_status(
  platform : Platform,
  pcfg : PlatformConfig,
  request : @http.Request,
  raw : String,
) -> (Int32, String) {
  let query = match request.path.split_once("?") {
    Some((_, q)) => q.to_owned()
    None => ""
  }
  match platform {
    Telegram => {
      let secret = pcfg.extra_str("webhook_secret", "")
      if secret.is_empty() {
        (
          503, "telegram webhook_secret not configured (set [telegram.extra] webhook_secret / TELEGRAM_WEBHOOK_SECRET)",
        )
      } else if telegram_webhook_authorized(
          secret,
          header_of(request, "X-Telegram-Bot-Api-Secret-Token"),
        ) {
        (0, "")
      } else {
        (401, "invalid X-Telegram-Bot-Api-Secret-Token")
      }
    }
    Slack => {
      let secret = pcfg.extra_str("signing_secret", "")
      if secret.is_empty() {
        (
          503, "slack signing_secret not configured (set [slack.extra] signing_secret / SLACK_SIGNING_SECRET)",
        )
      } else if slack_request_verified(
          secret,
          header_of(request, "X-Slack-Request-Timestamp").unwrap_or(""),
          raw,
          header_of(request, "X-Slack-Signature").unwrap_or(""),
          now_ms() / 1000L,
        ) {
        (0, "")
      } else {
        (401, "invalid X-Slack-Signature")
      }
    }
    Whatsapp => {
      let secret = pcfg.extra_str("app_secret", "")
      if secret.is_empty() {
        (
          503, "whatsapp app_secret not configured (set [whatsapp.extra] app_secret / WHATSAPP_CLOUD_APP_SECRET)",
        )
      } else if whatsapp_verify_signature(
          secret,
          raw,
          header_of(request, "X-Hub-Signature-256").unwrap_or(""),
        ) {
        (0, "")
      } else {
        (401, "invalid X-Hub-Signature-256")
      }
    }
    Bluebubbles => {
      let password = pcfg.extra_str("password", "")
      if password.is_empty() {
        (0, "")
      } else {
        match
          bluebubbles_webhook_token(query, header_of(request, "x-password")) {
          Some(t) =>
            if constant_time_eq(password, t) {
              (0, "")
            } else {
              (401, "invalid BlueBubbles webhook password")
            }
          None => (401, "missing BlueBubbles webhook password")
        }
      }
    }
    Mattermost => {
      let expected = pcfg.extra_str("webhook_token", "")
      if expected.is_empty() {
        (0, "")
      } else {
        match mattermost_webhook_token(raw) {
          Some(t) =>
            if constant_time_eq(expected, t) {
              (0, "")
            } else {
              (401, "invalid Mattermost webhook token")
            }
          None => (401, "missing Mattermost webhook token")
        }
      }
    }
    Wecom => {
      // Callback crypto is opt-in: when `encoding_aes_key` is set, every
      // request must carry a valid `msg_signature` over its `<Encrypt>`;
      // otherwise bodies pass through (relay mode).
      let aes_key = wecom_encoding_aes_key(pcfg)
      if aes_key.is_empty() {
        (0, "")
      } else {
        let token = wecom_callback_token(pcfg)
        if token.is_empty() {
          (
            503, "wecom callback_token not configured (set [wecom.extra] callback_token / WECOM_CALLBACK_TOKEN)",
          )
        } else {
          let params = wecom_callback_params(request.path)
          match xml_text(raw, "Encrypt") {
            None => (400, "missing <Encrypt> in wecom callback body")
            Some(encrypt) =>
              if wecom_verify_msg_signature(
                  token,
                  params.timestamp,
                  params.nonce,
                  encrypt,
                  params.msg_signature,
                ) {
                (0, "")
              } else {
                (401, "invalid WeCom msg_signature")
              }
          }
        }
      }
    }
    _ => (0, "")
  }
}

///|
/// Case-insensitive request-header lookup.
fn header_of(request : @http.Request, name : String) -> String? {
  request.headers.get(@http.CaseInsensitiveString(name))
}

///|
/// Reason phrase for the webhook-rejection status codes.
fn http_reason(code : Int32) -> String {
  match code {
    401 => "Unauthorized"
    403 => "Forbidden"
    503 => "Service Unavailable"
    _ => "Error"
  }
}

///|
/// Answer platform verification handshakes (Slack/Feishu challenge, WhatsApp
/// `hub.challenge`, WeCom `echostr`). Returns `true` when the request was
/// fully handled.
async fn Gateway::handle_verification(
  self : Gateway,
  platform : Platform,
  request : @http.Request,
  raw : String,
  conn : @http.ServerConnection,
) -> Bool {
  match platform {
    Slack =>
      match slack_challenge(raw) {
        Some(challenge) => {
          respond_text(conn, 200, "OK", challenge)
          true
        }
        None => false
      }
    Feishu =>
      match feishu_challenge(raw) {
        Some(challenge) => {
          respond_text(conn, 200, "OK", "{\"challenge\":\"\{challenge}\"}")
          true
        }
        None => false
      }
    Whatsapp =>
      match whatsapp_hub_params(request.path) {
        Some(hub) => {
          let expected = match self.cfg.get(Whatsapp) {
            Some(p) => p.extra_str("verify_token", "")
            None => ""
          }
          match whatsapp_verify(hub.mode, hub.token, hub.challenge, expected) {
            Some(ch) => {
              respond_text(conn, 200, "OK", ch)
              true
            }
            None => {
              respond_text(conn, 403, "Forbidden", "verification failed")
              true
            }
          }
        }
        None => false
      }
    Wecom =>
      match self.cfg.get(Wecom) {
        None => false
        Some(pcfg) => {
          let params = wecom_callback_params(request.path)
          match params.echostr {
            None => false
            Some(echostr) => {
              let token = wecom_callback_token(pcfg)
              let aes_key = wecom_encoding_aes_key(pcfg)
              if token.is_empty() || aes_key.is_empty() {
                respond_text(
                  conn, 403, "Forbidden", "wecom callback crypto not configured (set callback_token / encoding_aes_key)",
                )
              } else {
                match
                  wecom_decrypt_message(
                    token,
                    aes_key,
                    wecom_corp_id(pcfg),
                    params.msg_signature,
                    params.timestamp,
                    params.nonce,
                    echostr,
                  ) {
                  Some(plain) => respond_text(conn, 200, "OK", plain)
                  None =>
                    respond_text(
                      conn, 403, "Forbidden", "wecom URL verification failed (msg_signature mismatch)",
                    )
                }
              }
              true
            }
          }
        }
      }
    _ => false
  }
}

///|
/// WhatsApp webhook verification parameters (`hub.*` query keys).
pub(all) struct HubParams {
  mode : String
  token : String
  challenge : String
} derive(Debug)

///|
/// Extract `hub.mode` / `hub.verify_token` / `hub.challenge` from a path.
pub fn whatsapp_hub_params(path : String) -> HubParams? {
  let query = match path.split_once("?") {
    Some((_, q)) => q.to_owned()
    None => return None
  }
  let mode = query_param(query, "hub.mode").unwrap_or("")
  if mode.is_empty() {
    return None
  }
  Some({
    mode,
    token: query_param(query, "hub.verify_token").unwrap_or(""),
    challenge: query_param(query, "hub.challenge").unwrap_or(""),
  })
}

///|
/// Read a `name=value` pair from a URL query string (percent-decoded).
pub fn query_param(query : String, name : String) -> String? {
  for pair in query.split("&") {
    match pair.split_once("=") {
      Some((k, v)) =>
        if k.to_owned() == name {
          return Some(percent_decode_value(v))
        }
      None => ()
    }
  }
  None
}

///|
/// Percent-decode one URL query component (raw text when not valid UTF-8).
fn percent_decode_value(v : StringView) -> String {
  let bytes = @percent.decode(v)
  @utf8.decode(bytes[:]) catch {
    _ => v.to_owned()
  }
}

///|
/// Long-poll Telegram `getUpdates` and feed events into the gateway.
async fn poll_telegram(
  gw : Gateway,
  pcfg : PlatformConfig,
  token : String,
) -> Unit {
  ignore(telegram_delete_webhook(pcfg, token))
  let mut offset = 0
  while true {
    let started = now_ms()
    match telegram_get_updates_result(pcfg, token, offset, 25) {
      Ok(updates) => {
        for u in updates {
          offset = json_field_int(u, "update_id").unwrap_or(offset) + 1
          for ev in telegram_parse_update(u) {
            gw.handle_event(ev)
          }
        }
        if updates.length() == 0 && now_ms() - started < 1000L {
          @async.sleep(1000)
        }
      }
      Err(e) => {
        log_line(
          "[imrelay] telegram getUpdates failed: \{api_error_message(e)}",
        )
        @async.sleep(2000)
      }
    }
  }
}

///|
/// Long-poll the WeChat iLink `getupdates` endpoint.
async fn poll_weixin(
  gw : Gateway,
  pcfg : PlatformConfig,
  token : String,
) -> Unit {
  let mut buf = ""
  while true {
    let started = now_ms()
    match weixin_get_updates_result(pcfg, token, buf) {
      Ok((msgs, new_buf)) => {
        buf = new_buf
        for m in msgs {
          match weixin_parse_message(m) {
            Some(ev) => {
              let session = gw.store.session(Weixin, ev.chat_id)
              match json_field_string(m, "context_token") {
                Some(t) => session.set_context_token(t)
                None => ()
              }
              // Download + decrypt any iLink media so the agent sees attachments.
              let ev = weixin_with_media(ev, weixin_media_attachments(pcfg, m))
              gw.handle_event(ev)
            }
            None => ()
          }
        }
        if msgs.length() == 0 && now_ms() - started < 1000L {
          @async.sleep(1000)
        }
      }
      Err(e) => {
        log_line("[imrelay] weixin getupdates failed: \{api_error_message(e)}")
        @async.sleep(2000)
      }
    }
  }
}

///|
/// Long-poll Matrix `/sync` and feed events into the gateway. The bot's own
/// events are filtered out via ``self_user`` (Prevents reply echo loops.)
async fn poll_matrix(
  gw : Gateway,
  pcfg : PlatformConfig,
  token : String,
  self_user : String,
) -> Unit {
  // Prime `next_batch` without replaying history: the first sync's timeline is
  // consumed for the token only (Hermes skips the initial sync the same way).
  let mut since = ""
  match matrix_sync(pcfg, token, "", 0) {
    Ok(j) =>
      match json_field_string(j, "next_batch") {
        Some(b) => if !b.is_empty() { since = b }
        None => ()
      }
    Err(e) =>
      log_line("[imrelay] matrix initial sync failed: \{api_error_message(e)}")
  }
  while true {
    let started = now_ms()
    match matrix_sync(pcfg, token, since, 30000) {
      Ok(j) => {
        match json_field_string(j, "next_batch") {
          Some(b) => if !b.is_empty() { since = b }
          None => ()
        }
        for ev in matrix_parse_sync(j.stringify(), self_user~) {
          gw.handle_event(ev)
        }
        if now_ms() - started < 1000L {
          @async.sleep(1000)
        }
      }
      Err(e) => {
        log_line("[imrelay] matrix sync failed: \{api_error_message(e)}")
        @async.sleep(2000)
      }
    }
  }
}

///|
/// DingTalk Stream Mode: open a WebSocket long-connection, ack `CALLBACK`
/// frames, echo `SYSTEM` pings and reconnect with exponential backoff.
async fn poll_dingtalk_stream(gw : Gateway, pcfg : PlatformConfig) -> Unit {
  let mut delay : Int64 = 1000L
  let backoff = (d : Int64) => if d >= 60000L { 60000L } else { d * 2L }
  while true {
    match dingtalk_stream_open(pcfg) {
      Err(e) => {
        log_line(
          "[imrelay] dingtalk: stream open failed (\{api_error_message(e)}); retrying in \{delay} ms",
        )
        @async.sleep(delay.to_int())
        delay = backoff(delay)
      }
      Ok((endpoint, ticket)) => {
        let url = "\{endpoint}?ticket=\{url_quote(ticket)}"
        let opened = Some(@websocket.connect(url)) catch {
          e => {
            log_line(
              "[imrelay] dingtalk: stream connect failed: \{e}; retrying in \{delay} ms",
            )
            None
          }
        }
        match opened {
          None => {
            @async.sleep(delay.to_int())
            delay = backoff(delay)
          }
          Some(conn) => {
            log_line("[imrelay] dingtalk: stream connected")
            delay = 1000L
            try {
              for ;; {
                let message = conn.recv()
                let raw = message.read_all().text()
                match dingtalk_stream_frame(raw) {
                  None =>
                    log_line(
                      "[imrelay] dingtalk: ignoring a malformed stream frame",
                    )
                  Some(frame) =>
                    if frame.kind == "SYSTEM" {
                      if frame.topic == "ping" || frame.topic == "disconnect" {
                        conn.send_text(
                          dingtalk_stream_echo_reply(frame.headers, frame.data).stringify(),
                        )
                        if frame.topic == "disconnect" {
                          break
                        }
                      }
                    } else if frame.kind == "CALLBACK" {
                      // Ack first (the server retries after 60 s), then
                      // dispatch; redeliveries are dropped by frame id.
                      if !frame.message_id.is_empty() {
                        conn.send_text(
                          dingtalk_stream_callback_ack(frame.message_id).stringify(),
                        )
                      }
                      if !dingtalk_stream_duplicate(frame.message_id) {
                        let data = match frame.data {
                          String(s) => s
                          other => other.stringify()
                        }
                        for ev in dingtalk_parse_callback(data, cfg=pcfg) {
                          gw.handle_event(ev) catch {
                            e =>
                              log_line(
                                "[imrelay] dingtalk: handling a stream message failed: \{e}",
                              )
                          }
                        }
                      }
                    } else if frame.kind != "" && !frame.message_id.is_empty() {
                      // Unknown callback/event type: ack so it is not retried.
                      conn.send_text(
                        dingtalk_stream_callback_ack(frame.message_id).stringify(),
                      )
                    }
                }
              }
            } catch {
              e => log_line("[imrelay] dingtalk: stream closed: \{e}")
            }
            conn.close()
            @async.sleep(1000)
          }
        }
      }
    }
  }
}

///|
/// Minimal landing page describing the running gateway.
fn Gateway::landing_html(self : Gateway) -> String {
  let sb = StringBuilder()
  sb.write_string(
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>imrelay gateway</title>",
  )
  sb.write_string(
    "<style>body{font-family:ui-sans-serif,system-ui,sans-serif;margin:2rem;max-width:52rem;line-height:1.5;color:#111}h1{margin-bottom:.2rem}code{background:#f4f4f5;padding:.1rem .3rem;border-radius:4px}li{margin:.2rem 0}</style>",
  )
  sb.write_string("</head><body><h1>imrelay</h1>")
  sb.write_string(
    "<p>A MoonBit chat gateway for Telegram, Discord, Slack, WhatsApp, Signal, Email, Home&nbsp;Assistant, Mattermost, Matrix, DingTalk, Feishu/Lark, WeChat, WeCom and BlueBubbles.</p>",
  )
  sb.write_string("<h2>Webhook endpoints</h2><ul>")
  for p in self.cfg.enabled_platforms() {
    sb.write_string("<li><code>POST /\{p.value()}</code> — \{p.name()}</li>")
  }
  sb.write_string("</ul>")
  sb.write_string(
    "<p>Health: <code>/health</code> · Sessions live in memory, keyed by <code>platform:chat_id</code>.</p>",
  )
  sb.write_string("</body></html>")
  sb.to_string()
}

///|
/// Send an HTML HTTP response.
async fn respond_html(
  conn : @http.ServerConnection,
  code : Int32,
  html : String,
) -> Unit {
  conn.send_response(code, "OK", extra_headers={
    "Content-Type": "text/html; charset=utf-8",
  })
  conn.write_string(html)
  conn.end_response()
}

///|
/// Send a plain-text HTTP response.
async fn respond_text(
  conn : @http.ServerConnection,
  code : Int32,
  reason : String,
  text : String,
) -> Unit {
  conn.send_response(code, reason, extra_headers={
    "Content-Type": "text/plain; charset=utf-8",
  })
  conn.write_string(text)
  conn.end_response()
}
