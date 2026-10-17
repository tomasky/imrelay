// Email adapter: SMTP send plus RFC 5322 parsing.
//
// Mirrors Hermes `plugins/platforms/email/adapter.py` in spirit: outbound mail
// is composed as a UTF-8 `text/plain` message (base64 "encoded-word" subject
// when needed) and delivered over SMTP, with implicit TLS (465), STARTTLS
// (587) or plain (25) transports. Inbound mail is parsed from a raw RFC 5322
// message — hand a copy from IMAP (or a mail-to-webhook relay) to
// `email_parse_message`.

///|
/// SMTP settings resolved from `[email.extra]` (Hermes `EMAIL_*` keys).
pub(all) struct SmtpConfig {
  host : String
  port : Int32
  user : String
  password : String
  /// `ssl` (implicit TLS) | `starttls` | `none`
  tls : String
  from : String
  from_name : String
} derive(Debug)

///|
/// Resolve SMTP settings, inferring the TLS mode from the port when unset.
pub fn email_smtp_config(cfg : PlatformConfig) -> SmtpConfig {
  let port = cfg.extra_int("smtp_port", 587)
  let user = cfg.extra_str("smtp_user", "")
  let password = match cfg.extra_first(["smtp_password"]) {
    Some(p) => p
    None => cfg.token_of().unwrap_or("")
  }
  let tls = match cfg.extra_first(["smtp_tls", "smtp_security"]) {
    Some(t) => t
    None =>
      if port == 465 {
        "ssl"
      } else if port == 587 || port == 25 {
        "starttls"
      } else {
        "none"
      }
  }
  {
    host: cfg.extra_str("smtp_host", ""),
    port,
    user,
    password,
    tls: tls.to_lower(),
    from: cfg.extra_str("from_address", user),
    from_name: cfg.extra_str("from_name", ""),
  }
}

///|
/// Encode a header value: ASCII passes through, anything else becomes a
/// base64 "encoded-word" (RFC 2047).
pub fn email_header_encode(value : String) -> String {
  let mut ascii = true
  for c in value {
    if c.to_int() > 126 {
      ascii = false
    }
  }
  if ascii {
    value
  } else {
    "=?UTF-8?B?\{@base64.encode(@utf8.encode(value)[:])}?="
  }
}

///|
/// Civil date (year, month, day) from a Unix day number (Howard Hinnant's
/// `civil_from_days`).
fn civil_from_days(days : Int64) -> (Int64, Int64, Int64) {
  let z = days + 719468L
  let era = (if z >= 0L { z } else { z - 146096L }) / 146097L
  let doe = z - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let y0 = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let d = doy - (153L * mp + 2L) / 5L + 1L
  let m = if mp < 10L { mp + 3L } else { mp - 9L }
  let y = if m <= 2L { y0 + 1L } else { y0 }
  (y, m, d)
}

///|
/// RFC 5322 `Date:` header for an epoch-millisecond timestamp.
pub fn format_rfc5322_date(ms : Int64) -> String {
  let seconds = if ms < 0L { 0L } else { ms / 1000L }
  let mut days = seconds / 86400L
  let mut rem = seconds % 86400L
  if rem < 0L {
    rem = rem + 86400L
    days = days - 1L
  }
  let (y, m, d) = civil_from_days(days)
  let weekday = ((days + 4L) % 7L + 7L) % 7L
  let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  let months = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov",
    "Dec",
  ]
  let hh = rem / 3600L
  let mm = rem % 3600L / 60L
  let ss = rem % 60L
  let wd = names[weekday.to_int()]
  let mon = months[(m - 1L).to_int()]
  "\{wd}, \{pad2(d)} \{mon} \{y} \{pad2(hh)}:\{pad2(mm)}:\{pad2(ss)} +0000"
}

///|
/// Zero-pad a number to two digits.
fn pad2(n : Int64) -> String {
  if n < 10L {
    "0\{n}"
  } else {
    n.to_string()
  }
}

///|
/// Compose an RFC 5322 message.
pub fn email_build_message(
  from : String,
  from_name : String,
  to : String,
  subject : String,
  body : String,
  in_reply_to? : String,
  references? : String,
  date_ms? : Int64,
) -> String {
  let sb = StringBuilder()
  if from_name.is_empty() {
    sb.write_string("From: \{from}\r\n")
  } else {
    sb.write_string("From: \{email_header_encode(from_name)} <\{from}>\r\n")
  }
  sb.write_string("To: \{to}\r\n")
  sb.write_string("Subject: \{email_header_encode(subject)}\r\n")
  let stamp = match date_ms {
    Some(ms) => ms
    None => now_ms()
  }
  sb.write_string("Date: \{format_rfc5322_date(stamp)}\r\n")
  let domain = match from.split_once("@") {
    Some((_, d)) => d.to_owned()
    None => "imrelay"
  }
  sb.write_string("Message-ID: <\{random_hex(20)}@\{domain}>\r\n")
  match in_reply_to {
    Some(id) => sb.write_string("In-Reply-To: <\{id}>\r\n")
    None => ()
  }
  match references {
    Some(r) => sb.write_string("References: <\{r}>\r\n")
    None => ()
  }
  sb.write_string("MIME-Version: 1.0\r\n")
  sb.write_string("Content-Type: text/plain; charset=UTF-8\r\n")
  sb.write_string("Content-Transfer-Encoding: 8bit\r\n")
  sb.write_string("\r\n")
  sb.write_string(body.replace_all(old="\n", new="\r\n"))
  sb.to_string()
}

///|
/// Escape a message body for SMTP `DATA` (dot-stuffing).
pub fn smtp_dot_stuff(message : String) -> String {
  let out = message.replace_all(old="\r\n.", new="\r\n..")
  if out.has_prefix(".") {
    ".\{out}"
  } else {
    out
  }
}

///|
/// Read a (possibly multi-line) SMTP reply.
async fn[W : @io.Reader] smtp_read_reply(conn : W) -> String {
  let sb = StringBuilder()
  let mut done = false
  while !done {
    match @io.Reader::read_until(conn, "\r\n") {
      None => done = true
      Some(line) => {
        sb.write_string(line)
        sb.write_string("\n")
        if line.length() < 4 {
          done = true
        } else {
          let sep = line[3:4].to_owned()
          if sep != "-" {
            done = true
          }
        }
      }
    }
  }
  sb.to_string()
}

///|
/// First three characters of an SMTP reply (the status code).
fn smtp_code(reply : String) -> String {
  if reply.length() >= 3 {
    reply[:3].to_owned()
  } else {
    reply
  }
}

///|
/// Write a command and read its reply.
async fn[W : @io.Reader + @io.Writer] smtp_cmd(
  conn : W,
  cmd : String,
) -> String {
  @io.Writer::write(conn, "\{cmd}\r\n")
  smtp_read_reply(conn)
}

///|
/// Run the SMTP dialogue after the transport is ready. ``greeting`` is the
/// server banner (empty for the STARTTLS continuation, which re-EHLOs).
async fn[W : @io.Reader + @io.Writer] smtp_converse(
  conn : W,
  smtp : SmtpConfig,
  to : String,
  message : String,
) -> Result[Unit, String] {
  let mut reply = smtp_cmd(conn, "EHLO imrelay")
  if smtp_code(reply) != "250" {
    return Err("EHLO failed: \{reply}")
  }
  if !smtp.user.is_empty() {
    reply = smtp_cmd(conn, "AUTH LOGIN")
    if smtp_code(reply) == "334" {
      ignore(reply)
      reply = smtp_cmd(conn, @base64.encode(@utf8.encode(smtp.user)[:]))
      if smtp_code(reply) != "334" {
        return Err("AUTH user rejected: \{reply}")
      }
      reply = smtp_cmd(conn, @base64.encode(@utf8.encode(smtp.password)[:]))
      if smtp_code(reply) != "235" {
        return Err("AUTH password rejected: \{reply}")
      }
    } else {
      return Err("AUTH LOGIN unsupported: \{reply}")
    }
  }
  reply = smtp_cmd(conn, "MAIL FROM:<\{smtp.from}>")
  if smtp_code(reply) != "250" {
    return Err("MAIL FROM rejected: \{reply}")
  }
  reply = smtp_cmd(conn, "RCPT TO:<\{to}>")
  if smtp_code(reply) != "250" && smtp_code(reply) != "251" {
    return Err("RCPT TO rejected: \{reply}")
  }
  reply = smtp_cmd(conn, "DATA")
  if smtp_code(reply) != "354" {
    return Err("DATA rejected: \{reply}")
  }
  @io.Writer::write(conn, smtp_dot_stuff(message))
  @io.Writer::write(conn, "\r\n.\r\n")
  reply = smtp_read_reply(conn)
  if smtp_code(reply) != "250" {
    return Err("message rejected: \{reply}")
  }
  ignore(smtp_cmd(conn, "QUIT"))
  Ok(())
}

///|
/// Deliver ``body`` as an email to ``to``. ``subject`` defaults to
/// ``[email.extra] default_subject``.
pub async fn email_send(
  cfg : PlatformConfig,
  to : String,
  subject : String,
  body : String,
  in_reply_to? : String,
) -> SendResult {
  let smtp = email_smtp_config(cfg)
  if smtp.host.is_empty() {
    return missing_config(Email, "EMAIL_SMTP_HOST")
  }
  if to.is_empty() {
    return SendResult::failed("email: missing recipient", kind=NotFound)
  }
  let message = email_build_message(
    smtp.from,
    smtp.from_name,
    to,
    subject,
    body,
    in_reply_to?,
  )
  match smtp_deliver(smtp, to, message) {
    Ok(_) => SendResult::ok()
    Err(e) =>
      SendResult::failed(
        "email: \{e}",
        retryable=true,
        kind=classify_send_error(e),
      )
  }
}

///|
/// Open the transport and run the SMTP dialogue.
async fn smtp_deliver(
  smtp : SmtpConfig,
  to : String,
  message : String,
) -> Result[Unit, String] {
  let tcp = @socket.Tcp::connect_to_host(smtp.host, port=smtp.port) catch {
    e => return Err("connect failed: \{e}")
  }
  if smtp.tls == "ssl" {
    let tls = @tls.Tls::client(tcp, host=smtp.host) catch {
      e => return Err("TLS failed: \{e}")
    }
    let greeting = smtp_read_reply(tls)
    if smtp_code(greeting) != "220" {
      return Err("bad banner: \{greeting}")
    }
    return smtp_converse(tls, smtp, to, message)
  }
  let greeting = smtp_read_reply(tcp)
  if smtp_code(greeting) != "220" {
    return Err("bad banner: \{greeting}")
  }
  if smtp.tls == "starttls" {
    let ehlo = smtp_cmd(tcp, "EHLO imrelay")
    if smtp_code(ehlo) != "250" {
      return Err("EHLO failed: \{ehlo}")
    }
    let reply = smtp_cmd(tcp, "STARTTLS")
    if smtp_code(reply) != "220" {
      return Err("STARTTLS rejected: \{reply}")
    }
    let tls = @tls.Tls::client(tcp, host=smtp.host) catch {
      e => return Err("TLS failed: \{e}")
    }
    return smtp_converse(tls, smtp, to, message)
  }
  smtp_converse(tcp, smtp, to, message)
}

///|
/// Extract the bare address from a `From:` header value.
fn extract_email(value : String) -> String {
  match value.split_once("<") {
    Some((_, rest)) =>
      match rest.split_once(">") {
        Some((addr, _)) => addr.trim().to_owned()
        None => rest.trim().to_owned()
      }
    None => value.trim().to_owned()
  }
}

///|
/// Display name from a `Name <addr>`-style header; empty when there is none.
fn extract_email_name(value : String) -> String {
  match value.split_once("<") {
    Some((name, _)) => name.trim().to_owned()
    None => ""
  }
}

///|
/// Strip `<` `>` around a message id.
fn strip_angle(v : String) -> String {
  let t = if v.has_prefix("<") { v[1:].to_owned() } else { v }
  if t.has_suffix(">") {
    t[:t.length() - 1].to_owned()
  } else {
    t
  }
}

///|
/// Parse a raw RFC 5322 message into a `MessageEvent` (``From`` becomes the
/// chat id, so replies go back to the sender). ``Reply-To`` wins over ``From``
/// when present, matching normal mailing-list behaviour.
pub fn email_parse_message(raw : String) -> MessageEvent? {
  let (head, body) = match raw.find("\r\n\r\n") {
    Some(i) => (raw[:i].to_owned(), raw[i + 4:].to_owned())
    None =>
      match raw.find("\n\n") {
        Some(i) => (raw[:i].to_owned(), raw[i + 2:].to_owned())
        None => (raw, "")
      }
  }
  let headers : Map[String, String] = Map([])
  let mut last_key = ""
  for line in head.split("\n") {
    let l = line.to_owned()
    let clean = if l.has_suffix("\r") {
      l[:l.length() - 1].to_owned()
    } else {
      l
    }
    if clean.has_prefix(" ") || clean.has_prefix("\t") {
      if !last_key.is_empty() {
        let prev = headers.get(last_key).unwrap_or("")
        headers.set(last_key, "\{prev} \{clean.trim()}")
      }
    } else {
      match clean.split_once(":") {
        Some((k, v)) => {
          let key = k.trim().to_owned().to_lower()
          headers.set(key, v.trim().to_owned())
          last_key = key
        }
        None => ()
      }
    }
  }
  let sender = or_opt(headers.get("reply-to"), headers.get("from"))
  let from = match sender {
    Some(f) => extract_email(f)
    None => return None
  }
  if from.is_empty() {
    return None
  }
  let subject = headers.get("subject").unwrap_or("")
  let message_id = headers.get("message-id").map(strip_angle)
  let in_reply_to = headers.get("in-reply-to").map(strip_angle)
  let mut text = body.trim().to_owned()
  if text.is_empty() {
    text = subject
  }
  let mtype = if text.has_prefix("/") { Command } else { Text }
  let user_name = match sender {
    Some(s) => {
      let n = extract_email_name(s)
      if n.is_empty() {
        None
      } else {
        Some(n)
      }
    }
    None => None
  }
  Some(
    MessageEvent::new(
      text,
      mtype,
      Email,
      from,
      user_id=from,
      user_name?,
      message_id?,
      reply_to_message_id?=in_reply_to,
      media=[],
      timestamp=now_ms(),
    ),
  )
}
