// Runnable imrelay gateway.
//
// Reads `$IMRELAY_CONFIG` (or `gateway.toml`), else Hermes-style environment
// variables, then serves:
//
//   GET  /                 landing page (also the health of the deploy)
//   GET  /health           JSON health/status
//   POST /<platform>       inbound webhook for that platform
//   POST /demo/message     run the agent on a synthetic event
//
// The demo agent below is intentionally trivial — swap `demo_agent` for your
// own model call; it receives the normalized event *and* the chat `Session`,
// so history-aware agents can build their prompt from `session.messages_json()`.

///|
/// The agent callback. Replace with a real model call.
async fn demo_agent(
  ev : @imrelay.MessageEvent,
  session : @imrelay.Session,
) -> String {
  // A real agent would call a model here; the sleep stands in for that RTT.
  @async.sleep(5)
  let text = ev.text.trim()
  let lower = text.to_lower()
  if lower == "ping" {
    return "pong"
  }
  if lower == "history" {
    return session.messages_json().stringify()
  }
  if lower == "time" {
    return "epoch ms: \{@imrelay.now_ms()}"
  }
  if ev.media.length() > 0 {
    return "Received \{ev.media.length()} attachment(s) on \{ev.platform.name()}."
  }
  if text.is_empty() {
    return ""
  }
  "You said: \{text}"
}

///|
async fn main {
  let cfg = @imrelay.GatewayConfig::load_default() catch {
    e => {
      println("[imrelay] config error: \{e}")
      return
    }
  }
  let platforms = cfg.enabled_platforms()
  if platforms.is_empty() {
    println(
      "[imrelay] no platform credentials found — webhook routes and POST /demo/message still work.",
    )
  } else {
    let sb = StringBuilder()
    for p in platforms {
      sb.write_string(" \{p.value()}")
    }
    println("[imrelay] enabled platforms:\{sb.to_string()}")
  }
  let gw = @imrelay.Gateway::new(cfg, demo_agent)
  gw.run()
}
