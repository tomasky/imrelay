name = "kupas/imrelay"

version = "0.2.0"

readme = "README.mbt.md"

repository = "https://github.com/tomasky/imrelay"

license = "Apache-2.0"

keywords = [
  "messaging",
  "chat",
  "relay",
  "gateway",
  "agent",
  "hermes",
  "telegram",
  "discord",
  "slack",
]

preferred_target = "native"

description = "Hermes-style agent gateway in MoonBit: bridges 14 messaging platforms (Telegram, Discord, Slack, WhatsApp, Signal, Email, Home Assistant, Mattermost, Matrix, DingTalk, Feishu/Lark, WeChat, WeCom, iMessage via BlueBubbles) into a single agent callback, with retries, chunking, typing indicators, per-chat sessions and slash commands. TOML configuration with Hermes-compatible environment-variable fallback."

import {
  "moonbitlang/async@0.22.5",
  "moonbitlang/x@0.5.5",
  "moonbit-community/toml@0.5.0",
}
