///|
/// Adapter and gateway tests: payload builders, inbound parsers, hooks and
/// dispatch.  Mirrors the behavior of Hermes' platform adapters.

///|
/// String value of a Json value (for deep asserts).
fn t_jstr(j : Json) -> String {
  match j {
    String(s) => s
    _ => "<not-a-string>"
  }
}

///|
/// Raw fixtures (statement-position `#|` multiline strings so no escaping is
/// needed inside library JSON/XML samples).
const TG_TEXT : String =
  #|{"update_id":1,"message":{"message_id":42,"date":1700000000,"chat":{"id":-100123,"type":"group"},"from":{"id":7,"username":"ada","first_name":"Ada"},"text":"hello"}}

///|
const TG_PHOTO : String =
  #|{"update_id":2,"message":{"message_id":43,"date":1700000001,"chat":{"id":5},"from":{"id":7},"caption":"look","photo":[{"file_id":"small"},{"file_id":"big"}],"reply_to_message":{"message_id":9,"text":"prev"}}}

///|
const TG_CMD : String =
  #|{"update_id":3,"message":{"message_id":1,"date":1700000000,"chat":{"id":1},"from":{"id":2},"text":"/help@bot"}}

///|
const TG_CB : String =
  #|{"update_id":4,"callback_query":{"id":"cb1","data":"yes","from":{"id":7,"username":"ada"},"message":{"message_id":1,"chat":{"id":5}}}}

///|
const TG_ONE : String =
  #|{"update_id":1,"message":{"message_id":1,"date":1700000000,"chat":{"id":1},"from":{"id":2},"text":"a"}}

///|
const DC_EVENT : String =
  #|{"t":"MESSAGE_CREATE","d":{"id":"m1","channel_id":"123","content":"hi","author":{"id":"7","username":"ada"}}}

///|
const DC_INTERACTION : String =
  #|{"id":"i1","type":2,"channel_id":"123","member":{"user":{"id":"7","username":"ada"}},"data":{"name":"ask","options":[{"name":"q","value":"why"}]}}

///|
const DC_RETRY : String =
  #|{"retry_after":2.5}

///|
const SL_EVENT : String =
  #|{"type":"event_callback","event":{"type":"message","user":"U1","channel":"C1","text":"hi","ts":"1.2"}}

///|
const SL_BOT : String =
  #|{"event":{"type":"message","bot_id":"B1","channel":"C1","text":"hi"}}

///|
const SL_SUB : String =
  #|{"event":{"type":"message","subtype":"channel_join","channel":"C1"}}

///|
const SL_CMD : String =
  #|{"event":{"type":"message","user":"U1","channel":"C1","text":"/roll"}}

///|
const SL_MENTION : String =
  #|{"event":{"type":"app_mention","user":"U1","channel":"C1","text":"hello"}}

///|
const SL_SIG : String =
  #|token=xyzz0WbapA4vBCDEFasx0q6G&team_id=T1DC2JH3J&team_domain=testteamnow&channel_id=G8PSS9T3V&channel_name=foobar&user_id=U2CERLKJA&user_name=roadrunner&command=%2Fwebhook-collect&text=&response_url=https%3A%2F%2Fhooks.slack.com%2Fcommands%2FT1DC2JH3J%2F397700885554%2F96rGlfmibIGlgcZRskXaIFfN&trigger_id=398738663015.47445629121.803a0bc887a14d10d2c447fce8b6703c

///|
const WA_WEBHOOK : String =
  #|{"object":"whatsapp_business_account","entry":[{"id":"1","changes":[{"field":"messages","value":{"messaging_product":"whatsapp","metadata":{"phone_number_id":"123"},"contacts":[{"profile":{"name":"Ada"},"wa_id":"5"}],"messages":[{"from":"5","id":"wamid.1","timestamp":"1700000000","text":{"body":"hi"},"type":"text"}]}}]}]}

///|
const WA_IMG : String =
  #|{"entry":[{"changes":[{"value":{"messages":[{"from":"5","id":"wamid.2","timestamp":"1700000001","type":"image","image":{"id":"media-1","caption":"pic"}}]}}]}]}

///|
const WA_CMD : String =
  #|{"entry":[{"changes":[{"value":{"messages":[{"from":"5","id":"wamid.3","timestamp":"1700000002","text":{"body":"/start"}}]}}]}]}

///|
const SG_RECV : String =
  #|{"envelopes":[{"envelope":{"source":"+1555","sourceUuid":"u1","sourceName":"Ada","dataMessage":{"timestamp":1700000000,"message":"hi"}}}]}

///|
const SG_GROUP : String =
  #|{"envelopes":[{"envelope":{"source":"+1555","dataMessage":{"message":"hi","groupInfo":{"groupId":"g1"},"attachments":[{"contentType":"image/png","id":"att1"},{"contentType":"application/pdf","id":"att2"}]}}}]}

///|
const MX_SYNC : String =
  #|{"rooms":{"join":{"!r:mx":{"timeline":{"events":[
  #|{"type":"m.room.message","event_id":"$1","sender":"@ada:mx","content":{"msgtype":"m.text","body":"hi"}},
  #|{"type":"m.room.message","event_id":"$2","sender":"@bot:mx","content":{"body":"mine"}},
  #|{"type":"m.room.member","event_id":"$3","sender":"@ada:mx","content":{"membership":"join"}}
  #|]}}}}}

///|
const MX_REPLY : String =
  #|{"type":"m.room.message","event_id":"$4","sender":"@ada:mx","content":{"body":"/go","m.relates_to":{"event_id":"$0"}}}

///|
const MM_WEBHOOK : String =
  #|{"text":"hi","channel_id":"c1","user_id":"u1","user_name":"ada","post_id":"p1"}

///|
const FS_CHALLENGE : String =
  #|{"challenge":"c1","type":"url_verification"}

///|
const FS_NOCHALLENGE : String =
  #|{"type":"url_verification"}

///|
const FS_CONTENT : String =
  #|{"message_type":"text","content":"{\"text\":\"hello\"}"}

///|
const DT_CB : String =
  #|{"msgtype":"text","text":{"content":"hi"},"conversationId":"cid","senderId":"u1","senderNick":"Ada","msgId":"m1","sessionWebhook":"https://hook"}

///|
const DT_MD_CB : String =
  #|{"msgtype":"markdown","markdown":{"text":"**hi**"},"conversationId":"cid"}

///|
const WX_IN : String =
  #|{"from_user_id":"u1","msg_id":"5","item_list":[{"type":1,"text_item":{"text":"hello"}},{"type":1,"text_item":{"text":"world"}}]}

///|
const WX_EMPTY : String =
  #|{"item_list":[]}

///|
const WC_JSON : String =
  #|{"msgid":"9","from":"user1","chatid":"chat1","text":{"content":"hi"}}

///|
const WC_XML : String =
  #|<xml><ToUserName><![CDATA[corp]]></ToUserName><FromUserName><![CDATA[user1]]></FromUserName><CreateTime>1700000000</CreateTime><MsgType><![CDATA[text]]></MsgType><Content><![CDATA[hello]]></Content><MsgId>123</MsgId><AgentID>7</AgentID></xml>

///|
const BB_MINE : String =
  #|{"type":"new-message","data":{"guid":"g1","text":"hi","isFromMe":true,"chats":[{"guid":"c1"}]}}

///|
const BB_EVENT : String =
  #|{"type":"new-message","data":{"guid":"g2","text":"hi","isFromMe":false,"chats":[{"guid":"c1"}],"handle":{"address":"+1555"}}}

///|
const BB_TYPING : String =
  #|{"type":"typing-indicator","data":{}}

///|
const BB_TOP : String =
  #|{"guid":"g3","text":"/cmd","chats":[{"guid":"c2"}]}

///|
const EMAIL_RAW : String =
  #|From: Ada <ada@x.com>
  #|Subject: hi
  #|Message-ID: <m1@x>
  #|In-Reply-To: <m0@x>
  #|
  #|Hello there
  #|

///|
const EMAIL_CMD : String =
  #|From: bob@x.com
  #|
  #|/status
  #|

///|
const EMAIL_DISP : String =
  #|From: a@x.com
  #|
  #|hi
  #|

///|
const HA_EVENT : String =
  #|{"text":"turn on","chat_id":"notify.ada","user_id":"u1"}

///|
const HA_DEFAULT : String =
  #|{"message":"hi"}

///|
const HA_NONE : String =
  #|{}

///|
const XML_SAMPLE : String =
  #|<xml><FromUserName><![CDATA[user1]]></FromUserName><MsgId>123</MsgId></xml>

///|
const JSON_OBJ : String =
  #|{"id":7,"n":2.5,"ok":true,"s":"x","o":{"k":"v"},"a":[1,2]}

///|
const DISP_TG : String =
  #|{"update_id":1,"message":{"message_id":1,"chat":{"id":1},"from":{"id":2},"text":"hi"}}

///|
const DISP_DC : String =
  #|{"id":"i1","type":2,"channel_id":"123","member":{"user":{"id":"7"}},"data":{"name":"ask"}}

///|
const DISP_SL : String =
  #|{"event":{"type":"message","user":"U1","channel":"C1","text":"hi"}}

///|
const DISP_WA : String =
  #|{"entry":[{"changes":[{"value":{"messages":[{"from":"5","id":"w","timestamp":"1700000000","text":{"body":"hi"}}]}}]}]}

///|
const DISP_SG : String =
  #|{"envelopes":[{"envelope":{"source":"+1","dataMessage":{"timestamp":1,"message":"hi"}}}]}

///|
const DISP_MX : String =
  #|{"rooms":{"join":{"!r:mx":{"timeline":{"events":[{"type":"m.room.message","event_id":"$1","sender":"@ada:mx","content":{"body":"hi"}}]}}}}}

///|
const DISP_MM : String =
  #|{"text":"hi","channel_id":"c1"}

///|
const DISP_FS : String =
  #|{"event":{"sender":{"sender_type":"user","sender_id":{"open_id":"ou1"}},"message":{"chat_id":"oc1","message_type":"text","content":"{\"text\":\"hi\"}"}}}

///|
const DISP_DT : String =
  #|{"msgtype":"text","text":{"content":"hi"},"conversationId":"cid"}

///|
const DISP_WX : String =
  #|{"msgs":[{"from_user_id":"u1","msg_id":"5","item_list":[{"type":1,"text_item":{"text":"hi"}}]}]}

///|
const DISP_WC : String =
  #|<xml><FromUserName><![CDATA[user1]]></FromUserName><Content><![CDATA[hi]]></Content></xml>

///|
const DISP_BB : String =
  #|{"data":{"guid":"g","text":"hi","chats":[{"guid":"c"}]}}

///|
const DISP_HA : String =
  #|{"text":"hi","chat_id":"notify"}

///|
test "util: strip_cdata and xml_text" {
  assert_eq(@imrelay.strip_cdata("<![CDATA[hello]]>"), "hello")
  assert_eq(@imrelay.strip_cdata("plain"), "plain")
  assert_eq(@imrelay.xml_text(XML_SAMPLE, "FromUserName"), Some("user1"))
  assert_eq(@imrelay.xml_text(XML_SAMPLE, "MsgId"), Some("123"))
  assert_eq(@imrelay.xml_text("<xml></xml>", "nope"), None)
}

///|
test "util: strip_markdown and truncate" {
  assert_eq(
    @imrelay.strip_markdown("**Hi** #this `code` looks"),
    "Hi this code looks",
  )
  assert_eq(@imrelay.strip_markdown("plain"), "plain")
  assert_eq(@imrelay.truncate("hi", 5), "hi")
  assert_eq(@imrelay.truncate("hello world", 5), "hello...")
  assert_eq(@imrelay.truncate("hello world", 11), "hello world")
}

///|
test "util: or_opt and parse_ms" {
  assert_eq(@imrelay.or_opt(Some("a"), Some("b")), Some("a"))
  assert_eq(@imrelay.or_opt(None, Some("b")), Some("b"))
  assert_eq(@imrelay.or_opt(None, None), None)
  assert_eq(@imrelay.parse_ms(Some("1700000000")), 1700000000000L)
  assert_eq(@imrelay.parse_ms(Some("1700000000000")), 1700000000000L)
}

///|
test "util: json helpers" {
  let j = t_json(JSON_OBJ)
  assert_eq(@imrelay.json_id(j, "id"), Some("7"))
  assert_eq(@imrelay.json_field_int(j, "n"), Some(2)) // floats truncate to Int
  assert_eq(@imrelay.json_field_bool(j, "ok"), Some(true))
  assert_eq(@imrelay.json_field_string(j, "s"), Some("x"))
  assert_eq(@imrelay.json_field_string(t_obj(j, "o"), "k"), Some("v"))
  assert_eq(@imrelay.json_field_array(j, "a").unwrap().length(), 2)
  assert_eq(@imrelay.json_field_array(j, "missing"), None)
  assert_eq(
    @imrelay.json_obj([("a", Json::string("b"))]).stringify(),
    "{\"a\":\"b\"}",
  )
}

///|
test "util: random_hex looks right" {
  let h1 = @imrelay.random_hex(16)
  let h2 = @imrelay.random_hex(16)
  assert_eq(h1.length(), 16)
  assert_eq(h2.length(), 16)
  let mut all_hex = true
  for i in 0..<h1.length() {
    let c = h1[i]
    if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
      all_hex = false
    }
  }
  assert_true(all_hex)
}

///|
test "util: url_quote" {
  assert_eq(@imrelay.url_quote("p@ss"), "p%40ss")
  assert_eq(@imrelay.url_quote("a b"), "a%20b")
}

///|
test "telegram: send payload and parse mode" {
  let p = @imrelay.telegram_send_payload(
    "1",
    "hi",
    Some("9"),
    Some("3"),
    Some("MarkdownV2"),
  )
  assert_eq(t_s(p, "chat_id"), "1")
  assert_eq(t_s(p, "text"), "hi")
  assert_eq(t_id(p, "reply_to_message_id"), "9")
  assert_eq(t_id(p, "message_thread_id"), "3")
  assert_eq(t_s(p, "parse_mode"), "MarkdownV2")
  let bare = @imrelay.telegram_send_payload("1", "hi", None, None, None)
  assert_eq(t_s(bare, "parse_mode"), "<none>")
  assert_eq(t_s(bare, "reply_to_message_id"), "<none>")
  let cfg = t_pcfg(@imrelay.Telegram, [
    ("api_base", "https://tg.local/"),
    ("parse_mode", "HTML"),
  ])
  assert_eq(@imrelay.telegram_api_base(cfg, "TOK"), "https://tg.local/botTOK")
  assert_eq(
    @imrelay.telegram_api_base(t_pcfg(@imrelay.Telegram, []), "T"),
    "https://api.telegram.org/botT",
  )
  assert_eq(@imrelay.telegram_parse_mode(cfg), Some("HTML"))
  assert_eq(@imrelay.telegram_parse_mode(t_pcfg(@imrelay.Telegram, [])), None)
}

///|
test "telegram: typing payload" {
  let p = @imrelay.telegram_typing_payload("1", Some("3"))
  assert_eq(t_s(p, "action"), "typing")
  assert_eq(t_id(p, "message_thread_id"), "3")
  let bare = @imrelay.telegram_typing_payload("1", None)
  assert_eq(t_s(bare, "message_thread_id"), "<none>")
}

///|
test "telegram: media helpers" {
  assert_eq(@imrelay.telegram_media_method("photo"), "sendPhoto")
  assert_eq(@imrelay.telegram_media_method("image"), "sendPhoto")
  assert_eq(@imrelay.telegram_media_method("video"), "sendVideo")
  assert_eq(@imrelay.telegram_media_method("voice"), "sendVoice")
  assert_eq(@imrelay.telegram_media_method("sticker"), "sendSticker")
  assert_eq(@imrelay.telegram_media_method("weird"), "sendDocument")
  let p = @imrelay.telegram_media_payload(
    "1",
    "video",
    "https://x/y.mp4",
    Some("cap"),
    None,
  )
  assert_eq(t_s(p, "video"), "https://x/y.mp4")
  assert_eq(t_s(p, "caption"), "cap")
  assert_eq(t_s(p, "photo"), "<none>")
}

///|
test "telegram: parse a text update" {
  let evs = @imrelay.telegram_parse_update(t_json(TG_TEXT))
  assert_eq(evs.length(), 1)
  let ev = evs[0]
  assert_eq(ev.platform, @imrelay.Telegram)
  assert_eq(ev.chat_id, "-100123")
  assert_eq(ev.text, "hello")
  assert_eq(ev.message_type, @imrelay.Text)
  assert_eq(ev.user_id, Some("7"))
  assert_eq(ev.user_name, Some("ada"))
  assert_eq(ev.message_id, Some("42"))
  assert_eq(ev.timestamp, 1700000000000L)
  assert_eq(ev.media.length(), 0)
}

///|
test "telegram: parse a photo with caption and reply" {
  let evs = @imrelay.telegram_parse_update(t_json(TG_PHOTO))
  assert_eq(evs.length(), 1)
  let ev = evs[0]
  assert_eq(ev.text, "look")
  assert_eq(ev.message_type, @imrelay.Photo)
  assert_eq(ev.media.length(), 1)
  assert_eq(ev.media[0].url, "big")
  assert_eq(ev.media[0].kind, "photo")
  assert_eq(ev.reply_to_message_id, Some("9"))
  assert_eq(ev.reply_to_text, Some("prev"))
}

///|
test "telegram: command detection and callbacks" {
  assert_eq(
    @imrelay.telegram_parse_update(t_json(TG_CMD))[0].message_type,
    @imrelay.Command,
  )
  let evs = @imrelay.telegram_parse_update(t_json(TG_CB))
  assert_eq(evs.length(), 1)
  assert_eq(evs[0].text, "yes")
  assert_eq(evs[0].message_type, @imrelay.Command)
  assert_eq(evs[0].chat_id, "5")
  assert_eq(evs[0].message_id, Some("cb1"))
}

///|
test "telegram: parse_updates flattens" {
  assert_eq(
    @imrelay.telegram_parse_updates([t_json(TG_ONE), t_json(TG_ONE)]).length(),
    2,
  )
  assert_eq(@imrelay.telegram_parse_updates([]).length(), 0)
}

///|
test "telegram: webhook secret token check" {
  assert_true(@imrelay.telegram_webhook_authorized("s3cr3t", Some("s3cr3t")))
  assert_true(!@imrelay.telegram_webhook_authorized("s3cr3t", Some("other")))
  assert_true(!@imrelay.telegram_webhook_authorized("s3cr3t", None))
  assert_true(!@imrelay.telegram_webhook_authorized("", Some("")))
}

///|
test "discord: send payload with reply reference" {
  let p = @imrelay.discord_send_payload("hi", Some("9"))
  assert_eq(t_s(p, "content"), "hi")
  assert_eq(t_s(t_obj(p, "message_reference"), "message_id"), "9")
  assert_eq(
    @imrelay.json_field_bool(
      t_obj(p, "message_reference"),
      "fail_if_not_exists",
    ),
    Some(false),
  )
  assert_eq(
    t_s(@imrelay.discord_send_payload("hi", None), "message_reference"),
    "<none>",
  )
}

///|
test "discord: media payload embeds" {
  let p = @imrelay.discord_media_payload(
    "photo",
    "https://x/y.png",
    Some("cap"),
  )
  assert_eq(t_s(p, "content"), "cap")
  let embeds = @imrelay.json_field_array(p, "embeds").unwrap()
  assert_eq(embeds.length(), 1)
  assert_eq(t_s(t_obj(embeds[0], "image"), "url"), "https://x/y.png")
}

///|
test "discord: parse a gateway message event" {
  let evs = @imrelay.discord_parse_message_event(DC_EVENT)
  assert_eq(evs.length(), 1)
  assert_eq(evs[0].platform, @imrelay.Discord)
  assert_eq(evs[0].chat_id, "123")
  assert_eq(evs[0].text, "hi")
  assert_eq(evs[0].user_id, Some("7"))
  assert_eq(evs[0].user_name, Some("ada"))
  assert_eq(evs[0].message_id, Some("m1"))
}

///|
test "discord: parse an interaction" {
  let evs = @imrelay.discord_parse_interaction(DC_INTERACTION)
  assert_eq(evs.length(), 1)
  assert_eq(evs[0].text, "/ask q:why")
  assert_eq(evs[0].message_type, @imrelay.Command)
  assert_eq(evs[0].chat_id, "123")
  assert_eq(evs[0].user_name, Some("ada"))
  assert_eq(@imrelay.discord_parse_interaction("{}").length(), 0)
}

///|
test "discord: channel types and retry_after" {
  assert_eq(@imrelay.discord_channel_type(0), "text")
  assert_eq(@imrelay.discord_channel_type(1), "dm")
  assert_eq(@imrelay.discord_channel_type(3), "group_dm")
  assert_eq(@imrelay.discord_channel_type(11), "thread")
  assert_eq(@imrelay.discord_channel_type(99), "channel")
  assert_eq(@imrelay.discord_retry_after(DC_RETRY), Some(2.5))
  assert_eq(@imrelay.discord_retry_after("not json"), None)
}

///|
test "slack: send and update payloads" {
  let p = @imrelay.slack_send_payload("C1", "hi", Some("9.1"))
  assert_eq(t_s(p, "channel"), "C1")
  assert_eq(t_s(p, "text"), "hi")
  assert_eq(t_s(p, "thread_ts"), "9.1")
  assert_eq(
    t_s(@imrelay.slack_send_payload("C1", "hi", None), "thread_ts"),
    "<none>",
  )
  let u = @imrelay.slack_update_payload("C1", "9.1", "new")
  assert_eq(t_s(u, "channel"), "C1")
  assert_eq(t_s(u, "ts"), "9.1")
  assert_eq(t_s(u, "text"), "new")
}

///|
test "slack: signature verification" {
  let sig = @imrelay.slack_signature(
    "8f742231b10e8888abcd99yyyzzz85a5",
    "1531420618",
    SL_SIG,
  )
  assert_eq(
    sig, "v0=a2114d57b48eac39b9ad189dd8316235a7b4a8d21a10bd27519666489c69b503",
  )
  assert_true(
    @imrelay.slack_verify_signature(
      "8f742231b10e8888abcd99yyyzzz85a5",
      "1531420618",
      SL_SIG,
      sig,
    ),
  )
  assert_eq(
    @imrelay.slack_verify_signature(
      "8f742231b10e8888abcd99yyyzzz85a5",
      "1531420618",
      SL_SIG,
      "v0=deadbeef",
    ),
    false,
  )
  let simple = @imrelay.slack_signature("secret", "1234", "hello world")
  assert_eq(
    simple, "v0=0c0e180adb05fcc788b5e85c6015f99bcfddb3380b04527aeb1b02cf631d16b7",
  )
}

///|
test "slack: request verification (signature + replay window)" {
  let secret = "s3cr3t"
  let ts = "1700000000"
  let body = "{\"type\":\"event_callback\"}"
  let sig = @imrelay.slack_signature(secret, ts, body)
  assert_true(
    @imrelay.slack_request_verified(secret, ts, body, sig, 1700000000L),
  )
  assert_true(
    @imrelay.slack_request_verified(secret, ts, body, sig, 1700000300L),
  )
  assert_true(
    !@imrelay.slack_request_verified(secret, ts, body, sig, 1700000301L),
  )
  assert_true(
    !@imrelay.slack_request_verified(
      secret, ts, body, "v0=deadbeef", 1700000000L,
    ),
  )
  assert_true(
    !@imrelay.slack_request_verified(secret, "nope", body, sig, 1700000000L),
  )
  assert_true(
    !@imrelay.slack_request_verified("other", ts, body, sig, 1700000000L),
  )
}

///|
test "slack: challenge and event parsing" {
  assert_eq(
    @imrelay.slack_challenge(
      "{\"type\":\"url_verification\",\"challenge\":\"c1\"}",
    ),
    Some("c1"),
  )
  assert_eq(@imrelay.slack_challenge("{\"type\":\"event_callback\"}"), None)
  let evs = @imrelay.slack_parse_event(SL_EVENT)
  assert_eq(evs.length(), 1)
  assert_eq(evs[0].platform, @imrelay.Slack)
  assert_eq(evs[0].chat_id, "C1")
  assert_eq(evs[0].text, "hi")
  assert_eq(evs[0].user_id, Some("U1"))
  assert_eq(evs[0].message_id, Some("1.2"))
  assert_eq(@imrelay.slack_parse_event(SL_BOT).length(), 0)
  assert_eq(@imrelay.slack_parse_event(SL_SUB).length(), 0)
  assert_eq(
    @imrelay.slack_parse_event(SL_CMD)[0].message_type,
    @imrelay.Command,
  )
  assert_eq(@imrelay.slack_parse_event(SL_MENTION)[0].text, "hello")
}

///|
test "whatsapp: send and media payloads" {
  let p = @imrelay.whatsapp_send_payload("1555", "hi", Some("wamid.1"))
  assert_eq(t_s(p, "messaging_product"), "whatsapp")
  assert_eq(t_s(p, "to"), "1555")
  assert_eq(t_s(t_obj(p, "text"), "body"), "hi")
  assert_eq(t_s(t_obj(p, "context"), "message_id"), "wamid.1")
  assert_eq(
    t_s(@imrelay.whatsapp_send_payload("1", "x", None), "context"),
    "<none>",
  )
  let img = @imrelay.whatsapp_media_payload(
    "1555",
    "photo",
    "https://x/y.png",
    Some("cap"),
  )
  assert_eq(t_s(img, "type"), "image")
  assert_eq(t_s(t_obj(img, "image"), "link"), "https://x/y.png")
  assert_eq(t_s(t_obj(img, "image"), "caption"), "cap")
  let doc = @imrelay.whatsapp_media_payload(
    "1",
    "document",
    "https://x/y.pdf",
    Some("y.pdf"),
  )
  assert_eq(t_s(doc, "type"), "document")
  assert_eq(t_s(t_obj(doc, "document"), "filename"), "y.pdf")
}

///|
test "whatsapp: api base and version" {
  let cfg = t_pcfg(@imrelay.Whatsapp, [
    ("phone_number_id", "123"),
    ("api_version", "v20.0"),
  ])
  assert_eq(@imrelay.whatsapp_api_version(cfg), "v20.0")
  assert_eq(@imrelay.whatsapp_phone_number_id(cfg), Some("123"))
  assert_eq(
    @imrelay.whatsapp_api_base(cfg),
    "https://graph.facebook.com/v20.0/123",
  )
}

///|
test "whatsapp: webhook verification" {
  assert_eq(
    @imrelay.whatsapp_verify("subscribe", "tok", "42", "tok"),
    Some("42"),
  )
  assert_eq(@imrelay.whatsapp_verify("subscribe", "bad", "42", "tok"), None)
  assert_eq(@imrelay.whatsapp_verify("subscribe", "tok", "42", ""), Some("42"))
  assert_eq(@imrelay.whatsapp_verify("unsubscribe", "tok", "42", "tok"), None)
}

///|
test "whatsapp: X-Hub-Signature-256 verification" {
  let secret = "app-secret"
  let body = "{\"entry\":[]}"
  let header = @imrelay.whatsapp_signature(secret, body)
  let hex = header[7:].to_owned()
  assert_true(header.has_prefix("sha256="))
  assert_true(@imrelay.whatsapp_verify_signature(secret, body, header))
  assert_true(
    @imrelay.whatsapp_verify_signature(secret, body, "sha256=\{hex.to_upper()}"),
  )
  assert_true(!@imrelay.whatsapp_verify_signature(secret, body + " ", header))
  assert_true(!@imrelay.whatsapp_verify_signature("other", body, header))
  assert_true(!@imrelay.whatsapp_verify_signature("", body, header))
  assert_true(!@imrelay.whatsapp_verify_signature(secret, body, hex))
}

///|
test "whatsapp: parse an inbound text webhook" {
  let evs = @imrelay.whatsapp_parse_webhook(WA_WEBHOOK)
  assert_eq(evs.length(), 1)
  assert_eq(evs[0].platform, @imrelay.Whatsapp)
  assert_eq(evs[0].chat_id, "5")
  assert_eq(evs[0].text, "hi")
  assert_eq(evs[0].user_name, Some("Ada"))
  assert_eq(evs[0].message_id, Some("wamid.1"))
  assert_eq(evs[0].timestamp, 1700000000000L)
  let evs2 = @imrelay.whatsapp_parse_webhook(WA_IMG)
  assert_eq(evs2.length(), 1)
  assert_eq(evs2[0].message_type, @imrelay.Photo)
  assert_eq(evs2[0].text, "pic")
  assert_eq(evs2[0].media[0].url, "media-1")
  assert_eq(evs2[0].media[0].kind, "image")
  // Hermes marks WhatsApp "/"-commands as plain Text; the gateway layer
  // dispatches commands via parse_command instead of the message type.
  assert_eq(@imrelay.whatsapp_parse_webhook(WA_CMD)[0].text, "/start")
  assert_eq(
    @imrelay.whatsapp_parse_webhook(WA_CMD)[0].message_type,
    @imrelay.Text,
  )
  assert_eq(@imrelay.whatsapp_parse_webhook("{}").length(), 0)
}

///|
test "whatsapp: retry_after parsing" {
  assert_eq(
    @imrelay.whatsapp_retry_after("Please retry after 30 seconds"),
    Some(30.0),
  )
  assert_eq(@imrelay.whatsapp_retry_after("Try again later"), None)
  assert_eq(@imrelay.whatsapp_retry_after("retry after 2.5"), Some(2.5))
}

///|
test "signal: send params for direct chat and group" {
  let p = @imrelay.signal_send_params("acct", "+1555", "hi")
  assert_eq(t_s(p, "jsonrpc"), "2.0")
  assert_eq(t_s(p, "method"), "send")
  assert_true(t_s(p, "id").has_prefix("send_"))
  let params = t_obj(p, "params")
  assert_eq(t_s(params, "account"), "acct")
  assert_eq(t_s(params, "message"), "hi")
  let recipients = @imrelay.json_field_array(params, "recipient").unwrap()
  assert_eq(recipients.length(), 1)
  assert_eq(t_jstr(recipients[0]), "+1555")
  let g = t_obj(@imrelay.signal_send_params("a", "group:g1", "hi"), "params")
  assert_eq(t_s(g, "groupId"), "g1")
  assert_eq(@imrelay.json_field_array(g, "recipient"), None)
}

///|
test "signal: parse a receive response" {
  let evs = @imrelay.signal_parse_receive(SG_RECV)
  assert_eq(evs.length(), 1)
  assert_eq(evs[0].platform, @imrelay.Signal)
  assert_eq(evs[0].chat_id, "+1555")
  assert_eq(evs[0].user_id, Some("u1"))
  assert_eq(evs[0].user_name, Some("Ada"))
  assert_eq(evs[0].message_id, Some("1700000000"))
  assert_eq(evs[0].text, "hi")
}

///|
test "signal: group chat with attachments" {
  let evs = @imrelay.signal_parse_receive(SG_GROUP)
  assert_eq(evs.length(), 1)
  assert_eq(evs[0].chat_id, "group:g1")
  assert_eq(evs[0].media.length(), 2)
  assert_eq(evs[0].media[0].kind, "photo")
  assert_eq(evs[0].media[1].kind, "document")
  assert_eq(@imrelay.signal_parse_receive("[]").length(), 0)
}

///|
test "matrix: send, edit and reaction payloads" {
  let p = @imrelay.matrix_send_payload("hi", Some("$e1"))
  assert_eq(t_s(p, "msgtype"), "m.text")
  assert_eq(t_s(p, "body"), "hi")
  assert_eq(
    t_s(t_obj(t_obj(p, "m.relates_to"), "m.in_reply_to"), "event_id"),
    "$e1",
  )
  assert_eq(
    t_s(@imrelay.matrix_send_payload("hi", None), "m.relates_to"),
    "<none>",
  )
  let e = @imrelay.matrix_edit_payload("new", "$e1")
  assert_eq(t_s(e, "body"), "* new")
  assert_eq(t_s(t_obj(e, "m.new_content"), "body"), "new")
  assert_eq(t_s(t_obj(e, "m.relates_to"), "rel_type"), "m.replace")
  let r = @imrelay.matrix_reaction_payload("$e1", "👍")
  assert_eq(t_s(t_obj(r, "m.relates_to"), "rel_type"), "m.annotation")
  assert_eq(t_s(t_obj(r, "m.relates_to"), "key"), "👍")
}

///|
test "matrix: homeserver and api base" {
  assert_eq(
    @imrelay.matrix_homeserver(
      t_pcfg(@imrelay.Matrix, [("homeserver", "https://mx.local/")]),
    ),
    "https://mx.local",
  )
  assert_eq(@imrelay.matrix_homeserver(t_pcfg(@imrelay.Matrix, [])), "")
  assert_eq(
    @imrelay.matrix_api_base(
      t_pcfg(@imrelay.Matrix, [("homeserver", "https://mx.local")]),
    ),
    "https://mx.local/_matrix/client/v3",
  )
  assert_eq(
    @imrelay.matrix_headers("tok").get("Authorization"),
    Some("Bearer tok"),
  )
}

///|
test "matrix: parse a sync response" {
  let evs = @imrelay.matrix_parse_sync(MX_SYNC, self_user="@bot:mx")
  assert_eq(evs.length(), 1)
  assert_eq(evs[0].platform, @imrelay.Matrix)
  assert_eq(evs[0].chat_id, "!r:mx")
  assert_eq(evs[0].text, "hi")
  assert_eq(evs[0].user_id, Some("@ada:mx"))
  assert_eq(evs[0].message_id, Some("$1"))
  let ev2 = @imrelay.matrix_parse_event(
    "!r:mx",
    t_json(MX_REPLY),
    self_user="@bot:mx",
  ).unwrap()
  assert_eq(ev2.text, "/go")
  assert_eq(ev2.message_type, @imrelay.Command)
  assert_eq(ev2.reply_to_message_id, Some("$0"))
}

///|
test "mattermost: api base, payload and webhook" {
  let cfg = t_pcfg(@imrelay.Mattermost, [("url", "https://mm.local/")])
  assert_eq(@imrelay.mattermost_api_base(cfg), "https://mm.local/api/v4")
  assert_eq(
    @imrelay.mattermost_api_base(
      t_pcfg(@imrelay.Mattermost, [("api_base", "https://mm.local/api/v5/")]),
    ),
    "https://mm.local/api/v5",
  )
  let p = @imrelay.mattermost_send_payload("c1", "hi", Some("post1"))
  assert_eq(t_s(p, "channel_id"), "c1")
  assert_eq(t_s(p, "message"), "hi")
  assert_eq(t_s(p, "root_id"), "post1")
  assert_eq(
    @imrelay.json_field_bool(t_obj(p, "props"), "disable_mentions"),
    Some(true),
  )
  let evs = @imrelay.mattermost_parse_webhook(MM_WEBHOOK)
  assert_eq(evs.length(), 1)
  assert_eq(evs[0].platform, @imrelay.Mattermost)
  assert_eq(evs[0].text, "hi")
  assert_eq(evs[0].chat_id, "c1")
  assert_eq(evs[0].user_id, Some("u1"))
  assert_eq(evs[0].message_id, Some("p1"))
  assert_eq(@imrelay.mattermost_parse_webhook("{\"text\":\"hi\"}").length(), 0)
}

///|
test "mattermost: outgoing-webhook token" {
  assert_eq(
    @imrelay.mattermost_webhook_token("{\"token\":\"abc\",\"text\":\"hi\"}"),
    Some("abc"),
  )
  assert_eq(@imrelay.mattermost_webhook_token("{\"text\":\"hi\"}"), None)
  assert_eq(@imrelay.mattermost_webhook_token("not json"), None)
}

///|
test "feishu: challenge and message text" {
  assert_eq(@imrelay.feishu_challenge(FS_CHALLENGE), Some("c1"))
  assert_eq(@imrelay.feishu_challenge(FS_NOCHALLENGE), None)
  assert_eq(@imrelay.feishu_message_text(t_json(FS_CONTENT)), "hello")
}

///|
test "feishu: parse an im.message.receive event" {
  let content = @imrelay.json_obj([("text", Json::string("hello"))]).stringify()
  let body = @imrelay.json_obj([
    (
      "header",
      @imrelay.json_obj([("event_type", Json::string("im.message.receive_v1"))]),
    ),
    (
      "event",
      @imrelay.json_obj([
        (
          "sender",
          @imrelay.json_obj([
            ("sender_type", Json::string("user")),
            (
              "sender_id",
              @imrelay.json_obj([("open_id", Json::string("ou_1"))]),
            ),
          ]),
        ),
        (
          "message",
          @imrelay.json_obj([
            ("chat_id", Json::string("oc_1")),
            ("message_id", Json::string("om_1")),
            ("message_type", Json::string("text")),
            ("content", Json::string(content)),
            ("create_time", Json::string("1700000000000")),
          ]),
        ),
      ]),
    ),
  ]).stringify()
  let evs = @imrelay.feishu_parse_event(body)
  assert_eq(evs.length(), 1)
  assert_eq(evs[0].platform, @imrelay.Feishu)
  assert_eq(evs[0].text, "hello")
  assert_eq(evs[0].chat_id, "oc_1")
  assert_eq(evs[0].user_id, Some("ou_1"))
  assert_eq(evs[0].message_id, Some("om_1"))
  assert_eq(evs[0].timestamp, 1700000000000L)
  let bot = @imrelay.json_obj([
    (
      "event",
      @imrelay.json_obj([
        ("sender", @imrelay.json_obj([("sender_type", Json::string("bot"))])),
        (
          "message",
          @imrelay.json_obj([
            ("chat_id", Json::string("oc_1")),
            ("content", Json::string("{}")),
          ]),
        ),
      ]),
    ),
  ]).stringify()
  assert_eq(@imrelay.feishu_parse_event(bot).length(), 0)
}

///|
test "dingtalk: payloads and callback" {
  let md = @imrelay.dingtalk_send_payload("**hi**", "T", true)
  assert_eq(t_s(md, "msgtype"), "markdown")
  assert_eq(t_s(t_obj(md, "markdown"), "text"), "**hi**")
  assert_eq(t_s(t_obj(md, "markdown"), "title"), "T")
  let txt = @imrelay.dingtalk_send_payload("hi", "T", false)
  assert_eq(t_s(txt, "msgtype"), "text")
  assert_eq(t_s(t_obj(txt, "text"), "content"), "hi")
  let evs = @imrelay.dingtalk_parse_callback(DT_CB)
  assert_eq(evs.length(), 1)
  assert_eq(evs[0].platform, @imrelay.Dingtalk)
  assert_eq(evs[0].chat_id, "cid")
  assert_eq(evs[0].user_id, Some("u1"))
  assert_eq(evs[0].user_name, Some("Ada"))
  assert_eq(evs[0].message_id, Some("m1"))
  assert_eq(evs[0].reply_to_text, Some("https://hook"))
  assert_eq(@imrelay.dingtalk_parse_callback(DT_MD_CB)[0].text, "**hi**")
}

///|
test "dingtalk: credentials" {
  let cfg = t_pcfg(@imrelay.Dingtalk, [
    ("client_id", "k"),
    ("client_secret", "s"),
  ])
  assert_eq(@imrelay.dingtalk_app_key(cfg), Some("k"))
  assert_eq(@imrelay.dingtalk_app_secret(cfg), Some("s"))
  assert_eq(@imrelay.dingtalk_robot_token(cfg), None)
  assert_eq(
    @imrelay.dingtalk_robot_token(
      @imrelay.PlatformConfig::new(@imrelay.Dingtalk, token="tok"),
    ),
    Some("tok"),
  )
  assert_eq(@imrelay.dingtalk_app_secret(t_pcfg(@imrelay.Dingtalk, [])), None)
}

///|
test "dingtalk: session webhook cache" {
  assert_true(
    @imrelay.dingtalk_session_webhook_url(
      "https://api.dingtalk.com/v1.0/robot/sendBySession?session=x",
    ),
  )
  assert_true(
    @imrelay.dingtalk_session_webhook_url(
      "https://oapi.dingtalk.com/robot/sendBySession?session=x",
    ),
  )
  assert_false(
    @imrelay.dingtalk_session_webhook_url("https://evil.example.com/robot"),
  )
  assert_false(@imrelay.dingtalk_session_webhook_url("https://hook"))
  let future = @imrelay.now_ms() + 3_600_000L
  @imrelay.dingtalk_remember_session(
    "t-c1", "https://api.dingtalk.com/w1", future, "staff1", true,
  )
  let s = @imrelay.dingtalk_chat_session("t-c1").unwrap()
  assert_eq(s.sender_id, "staff1")
  assert_true(s.group)
  // An expiry inside the five-minute safety margin is treated as stale.
  @imrelay.dingtalk_remember_session(
    "t-c2",
    "https://api.dingtalk.com/w2",
    @imrelay.now_ms() + 60_000L,
    "u2",
    false,
  )
  assert_true(@imrelay.dingtalk_chat_session("t-c2") is None)
  // Unknown expiry (0) is kept.
  @imrelay.dingtalk_remember_session(
    "t-c3", "https://api.dingtalk.com/w3", 0L, "", false,
  )
  assert_true(@imrelay.dingtalk_chat_session("t-c3") is Some(_))
  assert_true(@imrelay.dingtalk_chat_session("t-missing") is None)
}

///|
test "dingtalk: parse remembers the session webhook" {
  let body = @imrelay.json_obj([
    ("msgtype", Json::string("text")),
    ("text", @imrelay.json_obj([("content", Json::string("hi"))])),
    ("conversationId", Json::string("t-cid-web")),
    ("conversationType", Json::string("2")),
    ("senderId", Json::string("u9")),
    ("senderStaffId", Json::string("staff9")),
    ("msgId", Json::string("m9")),
    (
      "sessionWebhook",
      Json::string("https://api.dingtalk.com/v1.0/x?session=s1"),
    ),
    ("sessionWebhookExpiredTime", Json::number(3700000000000.0)),
  ]).stringify()
  let evs = @imrelay.dingtalk_parse_callback(body)
  assert_eq(evs.length(), 1)
  assert_eq(evs[0].user_id, Some("u9"))
  let s = @imrelay.dingtalk_chat_session("t-cid-web").unwrap()
  assert_eq(s.webhook, "https://api.dingtalk.com/v1.0/x?session=s1")
  assert_eq(s.sender_id, "staff9")
  assert_eq(s.expires_at, 3700000000000L)
  assert_true(s.group)
  // A webhook URL outside dingtalk.com is not remembered.
  let bad = @imrelay.json_obj([
    ("text", @imrelay.json_obj([("content", Json::string("hi"))])),
    ("conversationId", Json::string("t-cid-bad")),
    ("sessionWebhook", Json::string("https://evil.example.com/x")),
  ]).stringify()
  assert_eq(@imrelay.dingtalk_parse_callback(bad).length(), 1)
  assert_true(@imrelay.dingtalk_chat_session("t-cid-bad") is None)
}

///|
test "dingtalk: group trigger rules" {
  let cfg = t_pcfg(@imrelay.Dingtalk, [
    ("require_mention", "true"),
    ("free_response_chats", "t-cid-free, t-cid-other"),
    ("mention_patterns", "[\"hey bot\"]"),
  ])
  let mk = (chat : String, content : String, in_at : Bool, conv : String) => {
    @imrelay.json_obj([
      ("msgtype", Json::string("text")),
      ("text", @imrelay.json_obj([("content", Json::string(content))])),
      ("conversationId", Json::string(chat)),
      ("conversationType", Json::string(conv)),
      ("senderId", Json::string("u1")),
      ("isInAtList", Json::boolean(in_at)),
    ]).stringify()
  }
  // DMs always pass.
  assert_eq(
    @imrelay.dingtalk_parse_callback(mk("t-cid-dm", "hi", false, "1"), cfg~).length(),
    1,
  )
  // Group without a mention: dropped.
  assert_eq(
    @imrelay.dingtalk_parse_callback(mk("t-cid-g", "hi", false, "2"), cfg~).length(),
    0,
  )
  // The bot was @-mentioned.
  assert_eq(
    @imrelay.dingtalk_parse_callback(mk("t-cid-g", "hi", true, "2"), cfg~).length(),
    1,
  )
  // free_response_chats entry.
  assert_eq(
    @imrelay.dingtalk_parse_callback(mk("t-cid-free", "hi", false, "2"), cfg~).length(),
    1,
  )
  // mention_patterns substring, case-insensitive.
  assert_eq(
    @imrelay.dingtalk_parse_callback(
      mk("t-cid-g", "Hey Bot ping", false, "2"),
      cfg~,
    ).length(),
    1,
  )
  // require_mention off (the default): group messages pass.
  assert_eq(
    @imrelay.dingtalk_parse_callback(
      mk("t-cid-g", "hi", false, "2"),
      cfg=t_pcfg(@imrelay.Dingtalk, []),
    ).length(),
    1,
  )
}

///|
test "dingtalk: stream frames, acks and dedup" {
  let frame_raw = @imrelay.json_obj([
    ("specVersion", Json::string("1.0")),
    ("type", Json::string("CALLBACK")),
    (
      "headers",
      @imrelay.json_obj([
        ("messageId", Json::string("mid-1")),
        ("topic", Json::string("/v1.0/im/bot/messages/get")),
        ("contentType", Json::string("application/json")),
      ]),
    ),
    ("data", Json::string(DT_CB)),
  ]).stringify()
  let f = @imrelay.dingtalk_stream_frame(frame_raw).unwrap()
  assert_eq(f.kind, "CALLBACK")
  assert_eq(f.topic, @imrelay.dingtalk_stream_robot_topic)
  assert_eq(f.message_id, "mid-1")
  let data = match f.data {
    String(s) => s
    _ => "<none>"
  }
  assert_eq(@imrelay.dingtalk_parse_callback(data)[0].chat_id, "cid")
  // SYSTEM ping frames echo the server's own headers and data.
  let ping = @imrelay.dingtalk_stream_frame(
    @imrelay.json_obj([
      ("type", Json::string("SYSTEM")),
      ("headers", @imrelay.json_obj([("topic", Json::string("ping"))])),
      ("data", Json::string("{}")),
    ]).stringify(),
  ).unwrap()
  assert_eq(ping.topic, "ping")
  let echo = @imrelay.dingtalk_stream_echo_reply(ping.headers, ping.data)
  assert_eq(@imrelay.json_field_int(echo, "code"), Some(200))
  assert_eq(@imrelay.json_field_string(echo, "message"), Some("OK"))
  assert_eq(@imrelay.json_field_string(echo, "data"), Some("{}"))
  // The CALLBACK ack carries the frame id and a SUCCESS payload.
  let ack = @imrelay.dingtalk_stream_callback_ack("mid-1")
  assert_eq(
    @imrelay.json_field_string(t_obj(ack, "headers"), "messageId"),
    Some("mid-1"),
  )
  assert_eq(
    @imrelay.json_field_string(ack, "data"),
    Some("{\"status\":\"SUCCESS\"}"),
  )
  // Malformed frames are rejected.
  assert_true(@imrelay.dingtalk_stream_frame("not json") is None)
  assert_true(@imrelay.dingtalk_stream_frame("[1,2]") is None)
  // Frame-id dedup: the first sight wins, redeliveries are dropped.
  let id = "dedup-\{@imrelay.random_hex(4)}"
  assert_false(@imrelay.dingtalk_stream_duplicate(id))
  assert_true(@imrelay.dingtalk_stream_duplicate(id))
}

///|
test "dingtalk: stream enablement and session payloads" {
  let cfg = t_pcfg(@imrelay.Dingtalk, [
    ("client_id", "k"),
    ("client_secret", "s"),
  ])
  assert_true(@imrelay.dingtalk_stream_enabled(cfg))
  assert_eq(@imrelay.dingtalk_robot_code(cfg), Some("k"))
  assert_false(
    @imrelay.dingtalk_stream_enabled(
      t_pcfg(@imrelay.Dingtalk, [
        ("client_id", "k"),
        ("client_secret", "s"),
        ("stream", "false"),
      ]),
    ),
  )
  assert_false(
    @imrelay.dingtalk_stream_enabled(
      t_pcfg(@imrelay.Dingtalk, [("client_id", "k")]),
    ),
  )
  assert_false(@imrelay.dingtalk_stream_enabled(t_pcfg(@imrelay.Dingtalk, [])))
  assert_eq(
    @imrelay.dingtalk_robot_code(
      t_pcfg(@imrelay.Dingtalk, [("robot_code", "rc"), ("client_id", "k")]),
    ),
    Some("rc"),
  )
  // The open-connection payload subscribes to the robot topic.
  let body = @imrelay.dingtalk_stream_open_payload(cfg)
  assert_eq(t_s(body, "clientId"), "k")
  assert_eq(t_s(body, "clientSecret"), "s")
  let subs = @imrelay.json_field_array(body, "subscriptions").unwrap()
  assert_eq(t_s(subs[0], "type"), "CALLBACK")
  assert_eq(t_s(subs[0], "topic"), "/v1.0/im/bot/messages/get")
  // Session-webhook payloads are markdown; a mention adds the `at` block.
  let quiet = @imrelay.dingtalk_session_payload("hi", "T", None)
  assert_eq(t_s(quiet, "msgtype"), "markdown")
  assert_eq(t_s(t_obj(quiet, "markdown"), "text"), "hi")
  assert_eq(t_s(t_obj(quiet, "markdown"), "title"), "T")
  assert_true(@imrelay.json_field_obj(quiet, "at") is None)
  let loud = @imrelay.dingtalk_session_payload("hi", "T", Some("staff1"))
  let ids = @imrelay.json_field_array(t_obj(loud, "at"), "atUserIds").unwrap()
  assert_true(
    match ids[0] {
      Json::String(s) => s == "staff1"
      _ => false
    },
  )
  assert_eq(@imrelay.json_field_bool(t_obj(loud, "at"), "isAtAll"), Some(false))
}

///|
test "weixin: config and send payload" {
  let cfg = t_pcfg(@imrelay.Weixin, [
    ("app_id", "bot"),
    ("base_url", "https://ilink.local/"),
  ])
  assert_eq(@imrelay.weixin_base_url(cfg), "https://ilink.local")
  assert_eq(@imrelay.weixin_app_id(cfg), "bot")
  let p = @imrelay.weixin_send_payload(cfg, "u2", "hi", Some("ctx"))
  let msg = t_obj(p, "msg")
  assert_eq(t_id(msg, "to_user_id"), "u2")
  assert_eq(t_s(msg, "context_token"), "ctx")
  assert_eq(
    t_s(t_obj(p, "base_info"), "channel_version"),
    @imrelay.weixin_channel_version(cfg),
  )
  let items = @imrelay.json_field_array(msg, "item_list").unwrap()
  assert_eq(items.length(), 1)
  assert_eq(@imrelay.json_field_int(items[0], "type"), Some(1))
  assert_eq(t_s(t_obj(items[0], "text_item"), "text"), "hi")
  let h = @imrelay.weixin_headers(cfg, Some("t"))
  assert_eq(h.get("Authorization"), Some("Bearer t"))
  assert_eq(h.get("AuthorizationType"), Some("ilink_bot_token"))
  assert_eq(h.get("iLink-App-Id"), Some("bot"))
  assert_eq(
    t_s(t_obj(@imrelay.weixin_text_item("yo"), "text_item"), "text"),
    "yo",
  )
}

///|
test "weixin: parse an inbound message" {
  let ev = @imrelay.weixin_parse_message(t_json(WX_IN)).unwrap()
  assert_eq(ev.platform, @imrelay.Weixin)
  assert_eq(ev.chat_id, "u1")
  // Hermes `_extract_text` takes the FIRST text item only.
  assert_eq(ev.text, "hello")
  assert_eq(ev.message_id, Some("5"))
  assert_true(@imrelay.weixin_parse_message(t_json(WX_EMPTY)) is None)
}

///|
test "wecom: config and send payload" {
  let cfg = t_pcfg(@imrelay.Wecom, [
    ("corp_id", "corp"),
    ("corp_secret", "sec"),
    ("agent_id", "7"),
    ("api_base", "https://qy.local/"),
  ])
  assert_eq(@imrelay.wecom_corp_id(cfg), "corp")
  assert_eq(@imrelay.wecom_corp_secret(cfg), Some("sec"))
  assert_eq(@imrelay.wecom_agent_id(cfg), Some(7))
  assert_eq(@imrelay.wecom_api_base(cfg), "https://qy.local")
  let p = @imrelay.wecom_send_payload("user1", "hi", Some(7), false)
  assert_eq(t_s(p, "touser"), "user1")
  assert_eq(t_s(p, "msgtype"), "text")
  assert_eq(t_s(t_obj(p, "text"), "content"), "hi")
  assert_eq(@imrelay.json_field_int(p, "agentid"), Some(7))
  let md = @imrelay.wecom_send_payload("user1", "hi", None, true)
  assert_eq(t_s(md, "msgtype"), "markdown")
  assert_eq(t_s(t_obj(md, "markdown"), "content"), "hi")
  assert_eq(@imrelay.json_field_int(md, "agentid"), None)
}

///|
test "wecom: parse JSON and XML callbacks" {
  let evs = @imrelay.wecom_parse_callback(WC_JSON)
  assert_eq(evs.length(), 1)
  assert_eq(evs[0].platform, @imrelay.Wecom)
  assert_eq(evs[0].chat_id, "chat1")
  assert_eq(evs[0].text, "hi")
  assert_eq(evs[0].user_id, Some("user1"))
  assert_eq(evs[0].message_id, Some("9"))
  let evx = @imrelay.wecom_parse_callback(WC_XML)
  assert_eq(evx.length(), 1)
  assert_eq(evx[0].chat_id, "user1")
  assert_eq(evx[0].text, "hello")
  assert_eq(evx[0].message_id, Some("123"))
  assert_eq(@imrelay.wecom_parse_callback("garbage").length(), 0)
}

///|
/// Official Tencent `WXBizMsgCrypt` sample (docs: 加解密方案说明): token
/// `QDG6eK`, corp id `wx5823bf96d3bd56c7` and its URL-verification `echostr`.
const WC_TOKEN : String = "QDG6eK"

///|
const WC_AES_KEY : String = "jWmYm7qr5nMoAUwZRjGtBxmz3KA1tkAj3ykkR6q2B2C"

///|
const WC_CORP : String = "wx5823bf96d3bd56c7"

///|
const WC_ECHOSTR : String = "P9nAzCzyDtyTWESHep1vC5X9xho/qYX3Zpb4yKa9SKld1DsH3Iyt3tP3zNdtp+4RPcs8TgAE7OaBO+FZXvnaqQ=="

///|
const WC_ECHOSTR_SIG : String = "5c45ff5e21c57e6ad56bac8758b79b1d9ac89fd3"

///|
const WC_XML_PLAIN : String =
  #|<xml><ToUserName><![CDATA[wx5823bf96d3bd56c7]]></ToUserName><FromUserName><![CDATA[user001]]></FromUserName><CreateTime>1729000000</CreateTime><MsgType><![CDATA[text]]></MsgType><Content><![CDATA[hello imrelay]]></Content><MsgId>1234567890123456</MsgId><AgentID>1000002</AgentID></xml>

///|
test "wecom crypto: official signature and echostr vector" {
  assert_eq(
    @imrelay.wecom_msg_signature(
      WC_TOKEN,
      "1409659589",
      "263014780",
      WC_ECHOSTR,
    ),
    WC_ECHOSTR_SIG,
  )
  assert_true(
    @imrelay.wecom_verify_msg_signature(
      WC_TOKEN,
      "1409659589",
      "263014780",
      WC_ECHOSTR,
      WC_ECHOSTR_SIG,
    ),
  )
  assert_false(
    @imrelay.wecom_verify_msg_signature(
      WC_TOKEN,
      "1409659589",
      "263014781",
      WC_ECHOSTR,
      WC_ECHOSTR_SIG,
    ),
  )
  // Sort-order pin: the parts sort differently from their argument order.
  assert_eq(
    @imrelay.wecom_msg_signature("ztoken", "1", "2", "aenc"),
    "c411e13bd2547aaf91caf5afb003405e2b582cdb",
  )
  assert_eq(
    @imrelay.wecom_decrypt_message(
      WC_TOKEN,
      WC_AES_KEY,
      WC_CORP,
      WC_ECHOSTR_SIG,
      "1409659589",
      "263014780",
      WC_ECHOSTR,
    ),
    Some("1616140317555161061"),
  )
  // Wrong receive_id, tampered payload, bad signature.
  assert_eq(
    @imrelay.wecom_decrypt_message(
      WC_TOKEN,
      WC_AES_KEY,
      "wx-other",
      WC_ECHOSTR_SIG,
      "1409659589",
      "263014780",
      WC_ECHOSTR,
    ),
    None,
  )
  let tampered = "\{WC_ECHOSTR[:WC_ECHOSTR.length() - 3]}R=="
  assert_eq(
    @imrelay.wecom_decrypt_message(
      WC_TOKEN,
      WC_AES_KEY,
      WC_CORP,
      WC_ECHOSTR_SIG,
      "1409659589",
      "263014780",
      tampered,
    ),
    None,
  )
  assert_eq(
    @imrelay.wecom_decrypt_message(
      WC_TOKEN,
      WC_AES_KEY,
      WC_CORP,
      "0000000000000000000000000000000000000000",
      "1409659589",
      "263014780",
      WC_ECHOSTR,
    ),
    None,
  )
  assert_eq(@imrelay.wecom_aes_key(WC_AES_KEY).unwrap().length(), 32)
  assert_eq(@imrelay.wecom_aes_key("too-short"), None)
}

///|
test "wecom crypto: pkcs7 pad and unpad at block 32" {
  let short = @imrelay.hex_decode("414243").unwrap()
  let padded = @imrelay.wecom_pkcs7_pad(short)
  assert_eq(padded.length(), 32)
  assert_eq(@imrelay.wecom_pkcs7_unpad(padded).unwrap(), short)
  // A 32-byte-aligned payload still gains a whole block.
  let full = @imrelay.hex_decode(
    "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
  ).unwrap()
  assert_eq(full.length(), 32)
  assert_eq(@imrelay.wecom_pkcs7_pad(full).length(), 64)
  // Malformed padding: empty, zero pad, oversized pad.
  assert_eq(@imrelay.wecom_pkcs7_unpad(@imrelay.hex_decode("").unwrap()), None)
  assert_eq(
    @imrelay.wecom_pkcs7_unpad(
      @imrelay.hex_decode(
        "0000000000000000000000000000000000000000000000000000000000000000",
      ).unwrap(),
    ),
    None,
  )
  assert_eq(
    @imrelay.wecom_pkcs7_unpad(
      @imrelay.hex_decode(
        "0000000000000000000000000000000000000000000000000000000000000021",
      ).unwrap(),
    ),
    None,
  )
}

///|
test "wecom crypto: encrypted callback roundtrip feeds the parser" {
  let env = @imrelay.wecom_encrypt_message(
    WC_TOKEN,
    WC_AES_KEY,
    WC_CORP,
    WC_XML_PLAIN,
    "1729000000",
    "nonce01",
  ).unwrap()
  let encrypt = @imrelay.xml_text(env, "Encrypt").unwrap()
  let sig = @imrelay.xml_text(env, "MsgSignature").unwrap()
  assert_eq(@imrelay.xml_text(env, "TimeStamp"), Some("1729000000"))
  assert_eq(@imrelay.xml_text(env, "Nonce"), Some("nonce01"))
  let decrypted = @imrelay.wecom_decrypt_message(
    WC_TOKEN,
    WC_AES_KEY,
    WC_CORP,
    sig,
    "1729000000",
    "nonce01",
    encrypt,
  )
  assert_eq(decrypted, Some(WC_XML_PLAIN))
  let evs = @imrelay.parse_inbound(@imrelay.Wecom, decrypted.unwrap())
  assert_eq(evs.length(), 1)
  assert_eq(evs[0].text, "hello imrelay")
  assert_eq(evs[0].user_id, Some("user001"))
  // A different timestamp no longer matches the signature.
  assert_eq(
    @imrelay.wecom_decrypt_message(
      WC_TOKEN,
      WC_AES_KEY,
      WC_CORP,
      sig,
      "1729000001",
      "nonce01",
      encrypt,
    ),
    None,
  )
}

///|
test "wecom crypto: callback params and envelope unwrap" {
  let p = @imrelay.wecom_callback_params(
    "/wecom?msg_signature=s1&timestamp=123&nonce=n+1&echostr=abc%2Bd%3D%3D",
  )
  assert_eq(p.msg_signature, "s1")
  assert_eq(p.timestamp, "123")
  assert_eq(p.nonce, "n+1")
  assert_eq(p.echostr, Some("abc+d=="))
  assert_eq(@imrelay.wecom_callback_params("/wecom?nonce=n1").echostr, None)
  assert_eq(@imrelay.wecom_callback_params("/wecom?echostr=").echostr, None)
  // Relay mode (no AES key): the body passes through untouched.
  let relay_cfg = t_pcfg(@imrelay.Wecom, [("corp_id", WC_CORP)])
  assert_eq(
    @imrelay.wecom_unwrap_callback(relay_cfg, WC_XML_PLAIN),
    Ok(WC_XML_PLAIN),
  )
  // Crypto mode: the enveloped body decrypts.
  let crypto_cfg = t_pcfg(@imrelay.Wecom, [
    ("corp_id", WC_CORP),
    ("callback_token", WC_TOKEN),
    ("encoding_aes_key", WC_AES_KEY),
  ])
  let env = @imrelay.wecom_encrypt_message(
    WC_TOKEN,
    WC_AES_KEY,
    WC_CORP,
    WC_XML_PLAIN,
    "1729000000",
    "nonce01",
  ).unwrap()
  assert_eq(@imrelay.wecom_unwrap_callback(crypto_cfg, env), Ok(WC_XML_PLAIN))
  assert_eq(
    @imrelay.wecom_unwrap_callback(
      crypto_cfg, "<xml><Encrypt>AAAA</Encrypt></xml>",
    ).to_option(),
    None,
  )
  assert_eq(
    @imrelay.wecom_unwrap_callback(crypto_cfg, WC_XML_PLAIN).to_option(),
    None,
  )
}

///|
test "bluebubbles: url and send payload" {
  let cfg = t_pcfg(@imrelay.Bluebubbles, [("server_url", "https://bb.local/")])
  assert_eq(@imrelay.bluebubbles_api_base(cfg), "https://bb.local/api/v1")
  assert_eq(
    @imrelay.bluebubbles_url(cfg, "/ping"),
    "https://bb.local/api/v1/ping",
  )
  let pw = @imrelay.PlatformConfig::new(
    @imrelay.Bluebubbles,
    token="p@ss",
    extra=cfg.extra,
  )
  assert_eq(
    @imrelay.bluebubbles_url(pw, "/ping"),
    "https://bb.local/api/v1/ping?password=p%40ss",
  )
  let p = @imrelay.bluebubbles_send_payload(
    "iMessage;-;+1555",
    "hi",
    Some("guid-1"),
  )
  assert_eq(t_s(p, "chatGuid"), "iMessage;-;+1555")
  assert_eq(t_s(p, "message"), "hi")
  assert_eq(t_s(p, "method"), "apple-script")
  assert_true(t_s(p, "tempGuid").has_prefix("temp-"))
  assert_eq(t_s(p, "selectedMessageGuid"), "guid-1")
  assert_eq(
    t_s(
      @imrelay.bluebubbles_send_payload("c", "m", None),
      "selectedMessageGuid",
    ),
    "<none>",
  )
}

///|
test "bluebubbles: parse new-message events" {
  assert_eq(@imrelay.bluebubbles_parse_event(BB_MINE).length(), 0)
  let evs = @imrelay.bluebubbles_parse_event(BB_EVENT)
  assert_eq(evs.length(), 1)
  assert_eq(evs[0].platform, @imrelay.Bluebubbles)
  assert_eq(evs[0].chat_id, "c1")
  assert_eq(evs[0].text, "hi")
  assert_eq(evs[0].user_id, Some("+1555"))
  assert_eq(evs[0].message_id, Some("g2"))
  assert_eq(@imrelay.bluebubbles_parse_event(BB_TYPING).length(), 0)
  assert_eq(
    @imrelay.bluebubbles_parse_event(BB_TOP)[0].message_type,
    @imrelay.Command,
  )
}

///|
test "bluebubbles: webhook credential extraction" {
  assert_eq(
    @imrelay.bluebubbles_webhook_token("password=p%40ss%2Fword", None),
    Some("p@ss/word"),
  )
  assert_eq(
    @imrelay.bluebubbles_webhook_token("other=1", Some("hdr")),
    Some("hdr"),
  )
  assert_eq(@imrelay.bluebubbles_webhook_token("other=1", None), None)
  assert_eq(@imrelay.bluebubbles_webhook_token("password=", None), None)
}

///|
test "email: dot stuffing and header encoding" {
  assert_eq(@imrelay.smtp_dot_stuff("a\r\n.b\r\nc"), "a\r\n..b\r\nc")
  assert_eq(@imrelay.smtp_dot_stuff(".a"), "..a")
  assert_eq(@imrelay.smtp_dot_stuff("plain"), "plain")
  assert_eq(@imrelay.email_header_encode("Hi"), "Hi")
  assert_true(@imrelay.email_header_encode("Héllo").has_prefix("=?UTF-8?B?"))
}

///|
test "email: build message headers" {
  let msg = @imrelay.email_build_message(
    "a@x.com",
    "Ada",
    "b@y.com",
    "Hi",
    "body",
    in_reply_to="m1",
    references="m1",
    date_ms=1700000000000L,
  )
  assert_true(msg.has_prefix("From: Ada <a@x.com>\r\n"))
  assert_true(msg.contains("To: b@y.com\r\n"))
  assert_true(msg.contains("Subject: Hi\r\n"))
  assert_true(msg.contains("Date: Tue, 14 Nov 2023 22:13:20 +0000\r\n"))
  assert_true(msg.contains("In-Reply-To: <m1>\r\n"))
  assert_true(msg.contains("References: <m1>\r\n"))
  assert_true(msg.contains("MIME-Version: 1.0\r\n"))
  assert_true(msg.contains("\r\n\r\nbody"))
  let bare = @imrelay.email_build_message(
    "a@x.com",
    "",
    "b@y.com",
    "Hi",
    "b",
    date_ms=0L,
  )
  assert_true(bare.has_prefix("From: a@x.com\r\n"))
  assert_eq(bare.contains("In-Reply-To"), false)
}

///|
test "email: parse a message" {
  let ev = @imrelay.email_parse_message(EMAIL_RAW).unwrap()
  assert_eq(ev.platform, @imrelay.Email)
  assert_eq(ev.text, "Hello there")
  assert_eq(ev.chat_id, "ada@x.com")
  assert_eq(ev.user_id, Some("ada@x.com"))
  assert_eq(ev.user_name, Some("Ada"))
  assert_eq(ev.message_id, Some("m1@x"))
  assert_eq(ev.reply_to_message_id, Some("m0@x"))
  assert_true(@imrelay.email_parse_message("no headers here") is None)
  assert_eq(
    @imrelay.email_parse_message(EMAIL_CMD).unwrap().message_type,
    @imrelay.Command,
  )
}

///|
test "email: smtp config from extra" {
  let cfg = t_pcfg(@imrelay.Email, [
    ("smtp_host", "smtp.x.com"),
    ("smtp_port", "465"),
    ("from_address", "bot@x.com"),
    ("from_name", "Bot"),
  ])
  let s = @imrelay.email_smtp_config(cfg)
  assert_eq(s.host, "smtp.x.com")
  assert_eq(s.port, 465)
  assert_eq(s.tls, "ssl")
  assert_eq(s.from, "bot@x.com")
  assert_eq(s.from_name, "Bot")
  let d = @imrelay.email_smtp_config(
    t_pcfg(@imrelay.Email, [("smtp_host", "h")]),
  )
  assert_eq(d.port, 587)
  assert_eq(d.tls, "starttls")
  assert_eq(d.from, "")
}

///|
test "homeassistant: url, service and payload" {
  let cfg = t_pcfg(@imrelay.HomeAssistant, [
    ("url", "https://ha.local/"),
    ("notify_domain", "notify"),
  ])
  assert_eq(@imrelay.homeassistant_url(cfg), "https://ha.local")
  assert_eq(@imrelay.homeassistant_domain(cfg), "notify")
  assert_eq(
    @imrelay.homeassistant_service(cfg, "mobile_app_ada"),
    "mobile_app_ada",
  )
  let withsvc = t_pcfg(@imrelay.HomeAssistant, [
    ("notify_service", "persistent_notification"),
  ])
  assert_eq(
    @imrelay.homeassistant_service(withsvc, "x"),
    "persistent_notification",
  )
  let p = @imrelay.homeassistant_send_payload(
    "hi",
    Some("T"),
    Some(t_json("{\"a\":1}")),
  )
  assert_eq(t_s(p, "message"), "hi")
  assert_eq(t_s(p, "title"), "T")
  assert_eq(@imrelay.json_field_int(t_obj(p, "data"), "a"), Some(1))
  let bare = @imrelay.homeassistant_send_payload("hi", None, None)
  assert_eq(t_s(bare, "title"), "<none>")
  assert_eq(t_s(bare, "data"), "<none>")
}

///|
test "homeassistant: parse an automation webhook" {
  let evs = @imrelay.homeassistant_parse_event(HA_EVENT)
  assert_eq(evs.length(), 1)
  assert_eq(evs[0].platform, @imrelay.HomeAssistant)
  assert_eq(evs[0].chat_id, "notify.ada")
  assert_eq(evs[0].text, "turn on")
  assert_eq(evs[0].user_id, Some("u1"))
  assert_eq(@imrelay.homeassistant_parse_event(HA_DEFAULT)[0].chat_id, "notify")
  assert_eq(@imrelay.homeassistant_parse_event(HA_NONE).length(), 0)
}

///|
test "dispatch: webhook paths" {
  assert_eq(@imrelay.webhook_path(@imrelay.Telegram), "telegram")
  assert_eq(@imrelay.webhook_path(@imrelay.HomeAssistant), "homeassistant")
  assert_eq(@imrelay.webhook_path(@imrelay.Bluebubbles), "bluebubbles")
  assert_eq(@imrelay.webhook_path(@imrelay.Mattermost), "mattermost")
}

///|

///|
/// Parse ``body`` for ``platform`` and require exactly one event, so a
/// routing regression fails fast as an assertion instead of a panic.
fn pib(
  platform : @imrelay.Platform,
  body : String,
) -> @imrelay.MessageEvent raise {
  let evs = @imrelay.parse_inbound(platform, body)
  assert_true(evs.length() == 1)
  evs[0]
}

///|
test "dispatch: parse_inbound routes to the right adapter" {
  assert_eq(pib(@imrelay.Telegram, DISP_TG).platform, @imrelay.Telegram)
  assert_eq(pib(@imrelay.Discord, DISP_DC).platform, @imrelay.Discord)
  assert_eq(pib(@imrelay.Slack, DISP_SL).platform, @imrelay.Slack)
  assert_eq(pib(@imrelay.Whatsapp, DISP_WA).platform, @imrelay.Whatsapp)
  assert_eq(pib(@imrelay.Signal, DISP_SG).platform, @imrelay.Signal)
  assert_eq(pib(@imrelay.Matrix, DISP_MX).platform, @imrelay.Matrix)
  assert_eq(pib(@imrelay.Mattermost, DISP_MM).platform, @imrelay.Mattermost)
  assert_eq(pib(@imrelay.Email, EMAIL_DISP).platform, @imrelay.Email)
  assert_eq(pib(@imrelay.Feishu, DISP_FS).platform, @imrelay.Feishu)
  assert_eq(pib(@imrelay.Dingtalk, DISP_DT).platform, @imrelay.Dingtalk)
  assert_eq(pib(@imrelay.Weixin, DISP_WX).platform, @imrelay.Weixin)
  assert_eq(pib(@imrelay.Wecom, DISP_WC).platform, @imrelay.Wecom)
  assert_eq(pib(@imrelay.Bluebubbles, DISP_BB).platform, @imrelay.Bluebubbles)
  assert_eq(
    pib(@imrelay.HomeAssistant, DISP_HA).platform,
    @imrelay.HomeAssistant,
  )
  assert_eq(@imrelay.parse_inbound(@imrelay.Telegram, "not json").length(), 0)
}

///|
test "dispatch: platform_configured" {
  assert_true(
    @imrelay.platform_configured(
      @imrelay.PlatformConfig::new(@imrelay.Telegram, token="t"),
    ),
  )
  assert_eq(@imrelay.platform_configured(t_pcfg(@imrelay.Telegram, [])), false)
  assert_true(
    @imrelay.platform_configured(
      @imrelay.PlatformConfig::new(
        @imrelay.Whatsapp,
        token="t",
        extra=t_pcfg(@imrelay.Whatsapp, [("phone_number_id", "1")]).extra,
      ),
    ),
  )
  assert_eq(
    @imrelay.platform_configured(
      t_pcfg(@imrelay.Signal, [("http_url", "http://s")]),
    ),
    false,
  )
  assert_true(
    @imrelay.platform_configured(
      t_pcfg(@imrelay.Signal, [("http_url", "http://s"), ("account", "+1")]),
    ),
  )
  assert_true(
    @imrelay.platform_configured(
      @imrelay.PlatformConfig::new(@imrelay.Matrix, token="t"),
    ),
  )
  assert_true(
    @imrelay.platform_configured(
      t_pcfg(@imrelay.Matrix, [("homeserver", "https://mx.local")]),
    ),
  )
  assert_true(
    @imrelay.platform_configured(
      t_pcfg(@imrelay.Email, [("smtp_host", "smtp")]),
    ),
  )
  assert_eq(@imrelay.platform_configured(t_pcfg(@imrelay.Email, [])), false)
  assert_true(
    @imrelay.platform_configured(
      t_pcfg(@imrelay.Feishu, [("app_id", "a"), ("app_secret", "s")]),
    ),
  )
  assert_eq(
    @imrelay.platform_configured(t_pcfg(@imrelay.Feishu, [("app_id", "a")])),
    false,
  )
  assert_true(
    @imrelay.platform_configured(
      t_pcfg(@imrelay.Wecom, [("corp_id", "c"), ("corp_secret", "s")]),
    ),
  )
  assert_true(
    @imrelay.platform_configured(
      t_pcfg(@imrelay.Bluebubbles, [("server_url", "https://bb.local")]),
    ),
  )
  assert_eq(
    @imrelay.platform_configured(t_pcfg(@imrelay.Bluebubbles, [])),
    false,
  )
  assert_true(
    @imrelay.platform_configured(
      @imrelay.PlatformConfig::new(
        @imrelay.HomeAssistant,
        token="t",
        extra=t_pcfg(@imrelay.HomeAssistant, [("url", "https://ha.local")]).extra,
      ),
    ),
  )
  assert_eq(
    @imrelay.platform_configured(
      t_pcfg(@imrelay.HomeAssistant, [("url", "https://ha.local")]),
    ),
    false,
  )
}

///|
test "gateway: query_param and whatsapp hub params" {
  assert_eq(
    @imrelay.query_param("hub.mode=subscribe&hub.challenge=42", "hub.mode"),
    Some("subscribe"),
  )
  assert_eq(@imrelay.query_param("a=1", "b"), None)
  let hp = @imrelay.whatsapp_hub_params(
    "/whatsapp?hub.mode=subscribe&hub.verify_token=t&hub.challenge=42",
  ).unwrap()
  assert_eq(hp.mode, "subscribe")
  assert_eq(hp.token, "t")
  assert_eq(hp.challenge, "42")
  assert_true(@imrelay.whatsapp_hub_params("/whatsapp") is None)
  assert_true(@imrelay.whatsapp_hub_params("/whatsapp?x=1") is None)
}

///|
test "gateway: query params are percent-decoded" {
  assert_eq(
    @imrelay.query_param("a=1&b=hello%20world", "b"),
    Some("hello world"),
  )
  assert_eq(
    @imrelay.query_param("password=p%40ss%2Fword", "password"),
    Some("p@ss/word"),
  )
  assert_eq(@imrelay.query_param("a=1&a=2", "a"), Some("1"))
  assert_eq(
    @imrelay.query_param("hub.challenge=1%206", "hub.challenge"),
    Some("1 6"),
  )
}

///|
/// A minimal agent callback for gateway tests.
async fn t_dummy(
  ev : @imrelay.MessageEvent,
  session : @imrelay.Session,
) -> String {
  ignore(ev)
  ignore(session)
  @async.sleep(1)
  "ok"
}

///|
async test "gateway: unconfigured platform events are ignored" {
  let cfg = t_cfg(TOML_SAMPLE)
  let gw = @imrelay.Gateway::new(cfg, t_dummy)
  assert_eq(gw.cfg.name, "my-gateway")
  assert_eq(gw.store.len(), 0)
  let ev = @imrelay.MessageEvent::new(
    "hi",
    @imrelay.Text,
    @imrelay.Matrix,
    "!r:mx",
  )
  gw.handle_event(ev)
  assert_eq(gw.store.len(), 0)
}

///|
test "gateway: user_allowed allowlist rules" {
  let cfg = @imrelay.GatewayConfig::default_config()
  let pcfg = @imrelay.PlatformConfig::new(@imrelay.Telegram)
  // No allowlist and no opt-in: closed.
  assert_true(!@imrelay.user_allowed(cfg, pcfg, Some("alice"), "-100"))
  cfg.allow_all_users = true
  assert_true(@imrelay.user_allowed(cfg, pcfg, Some("mallory"), "-100"))
  cfg.allow_all_users = false
  // Gateway-wide allowlist.
  cfg.allowed_users = ["alice"]
  assert_true(@imrelay.user_allowed(cfg, pcfg, Some("alice"), "-100"))
  assert_true(!@imrelay.user_allowed(cfg, pcfg, Some("bob"), "-100"))
  // Platform allowlist is additive; `*` matches everyone.
  let pcfg2 = @imrelay.PlatformConfig::new(@imrelay.Telegram, allowed_users=[
    "bob",
  ])
  assert_true(@imrelay.user_allowed(cfg, pcfg2, Some("bob"), "-100"))
  assert_true(!@imrelay.user_allowed(cfg, pcfg2, Some("mallory"), "-100"))
  let pcfg3 = @imrelay.PlatformConfig::new(@imrelay.Telegram, allowed_users=[
    "*",
  ])
  assert_true(@imrelay.user_allowed(cfg, pcfg3, Some("mallory"), "-100"))
  // No user id -> the chat id is matched instead.
  let pcfg4 = @imrelay.PlatformConfig::new(@imrelay.Telegram, allowed_users=[
    "-100",
  ])
  assert_true(@imrelay.user_allowed(cfg, pcfg4, None, "-100"))
}

///|
async test "gateway: unauthorized senders are ignored" {
  let toml =
    #|[gateway]
    #|name = "auth-test"
    #|
    #|[platforms.homeassistant]
    #|allowed_users = ["alice"]
  let cfg = t_cfg(toml)
  let gw = @imrelay.Gateway::new(cfg, t_dummy)
  let mk = fn(u : String) {
    @imrelay.MessageEvent::new(
      "hi",
      @imrelay.Text,
      @imrelay.HomeAssistant,
      "conv-1",
      user_id=u,
    )
  }
  gw.handle_event(mk("mallory"))
  assert_eq(gw.store.len(), 0)
  gw.handle_event(mk("alice"))
  assert_eq(gw.store.len(), 1)
  assert_eq(
    gw.store.session(@imrelay.HomeAssistant, "conv-1").history.length(),
    2,
  )
}

// ── weixin: iLink media crypto + QR (Hermes gap closure) ────────────────

///|
test "weixin: pkcs7 pad/unpad roundtrips" {
  assert_true(
    @imrelay.hex_encode(@imrelay.weixin_pkcs7_pad(@utf8.encode("x"))).has_suffix(
      "0f",
    ),
  )
  let p16 = @imrelay.weixin_pkcs7_pad(@utf8.encode("0123456789abcdef"))
  assert_eq(p16.length(), 32) // block-aligned input still pads a full block
  for i in 24..<32 {
    assert_eq(@imrelay.hex_encode(p16[i:i + 1]), "10")
  }
  let t = @utf8.encode("hello world")
  assert_eq(@imrelay.weixin_pkcs7_unpad(@imrelay.weixin_pkcs7_pad(t)), t)
  // odd padding is left as-is
  let trash = @utf8.encode("\u0005\u0005")
  assert_eq(@imrelay.weixin_pkcs7_unpad(trash), trash)
}

///|
test "weixin: aes key parsing (Hermes _parse_aes_key)" {
  let raw_key = @utf8.encode("0123456789abcdef")
  let b64_raw = @base64.encode(raw_key)
  match @imrelay.weixin_aes_key(b64_raw) {
    Ok(k) => assert_eq(k, raw_key)
    Err(_) => assert_true(false)
  }
  // base64 of the ASCII hex key (32 chars)
  let hex = @imrelay.hex_encode(raw_key)
  let b64_hex = @base64.encode(@utf8.encode(hex))
  match @imrelay.weixin_aes_key(b64_hex) {
    Ok(k) => assert_eq(@imrelay.hex_encode(k), hex)
    Err(_) => assert_true(false)
  }
  assert_true(@imrelay.weixin_aes_key("!!") is Err(_))
}

///|
test "weixin: media encrypt/decrypt roundtrip" {
  let key = @utf8.encode("0123456789abcdef")
  let plain = @utf8.encode("hello from iLink CDN")
  let cipher = @imrelay.weixin_media_encrypt(plain, key)
  assert_eq(cipher.length() % 16, 0)
  assert_true(cipher != plain)
  assert_eq(@imrelay.weixin_media_decrypt(cipher, key), plain)
}

///|
test "util: hex and md5 helpers" {
  assert_eq(@imrelay.hex_encode(@utf8.encode("AB")), "4142")
  assert_eq(@imrelay.hex_encode(@imrelay.hex_decode("4142").unwrap()), "4142")
  assert_true(@imrelay.hex_decode("abc") is None)
  assert_true(@imrelay.hex_decode("zz") is None)
  assert_eq(
    @imrelay.md5_hex(@utf8.encode("abc")),
    "900150983cd24fb0d6963f7d28e17f72",
  )
  let dl = @imrelay.data_url("image/jpeg", @utf8.encode("hi"))
  assert_eq(dl, "data:image/jpeg;base64,aGk=")
}

///|
test "weixin: cdn urls and host allowlist" {
  let cfg = t_pcfg(@imrelay.Weixin, [
    ("cdn_base_url", "https://novac2c.cdn.weixin.qq.com/c2c/"),
  ])
  assert_eq(
    @imrelay.weixin_cdn_base_url(cfg),
    "https://novac2c.cdn.weixin.qq.com/c2c",
  )
  assert_eq(
    @imrelay.weixin_media_download_url("https://cdn.x/c2c", "a b&c"),
    "https://cdn.x/c2c/download?encrypted_query_param=a%20b%26c",
  )
  assert_eq(
    @imrelay.weixin_media_upload_url("https://cdn.x/c2c", "u1", "f1"),
    "https://cdn.x/c2c/upload?encrypted_query_param=u1&filekey=f1",
  )
  assert_true(
    @imrelay.weixin_cdn_host_allowed(
      "https://novac2c.cdn.weixin.qq.com/c2c/download?x=1",
    ),
  )
  assert_true(@imrelay.weixin_cdn_host_allowed("http://wx.qlogo.cn/a"))
  assert_true(!@imrelay.weixin_cdn_host_allowed("https://evil.example.com/x"))
  assert_true(
    !@imrelay.weixin_cdn_host_allowed(
      "https://novac2c.cdn.weixin.qq.com.evil.com/x",
    ),
  )
}

///|
test "weixin: media type and mime by extension" {
  assert_eq(@imrelay.weixin_media_type_of("pic.jpg"), 1)
  assert_eq(@imrelay.weixin_media_type_of("clip.MP4"), 2)
  assert_eq(@imrelay.weixin_media_type_of("voice.silk"), 4)
  assert_eq(@imrelay.weixin_media_type_of("doc.pdf"), 3)
  assert_eq(@imrelay.weixin_mime_of("a.png"), "image/png")
  assert_eq(@imrelay.weixin_mime_of("v.mp4"), "video/mp4")
  assert_eq(@imrelay.weixin_mime_of("unknown.bin"), "application/octet-stream")
}

///|
test "weixin: outbound media item shapes (Hermes _media_item/_ITEM_SHAPES)" {
  let img = @imrelay.weixin_media_item(
    1, "ep1", "31323334353637383930616263646566", 100, 90, "a.jpg", "md5x",
  )
  assert_eq(t_id(img, "type"), "2") // item_list type for image
  let ii = t_obj(img, "image_item")
  assert_eq(t_id(t_obj(ii, "media"), "encrypt_query_param"), "ep1")
  assert_eq(
    t_id(t_obj(ii, "media"), "aes_key"),
    "MzEzMjMzMzQzNTM2MzczODM5MzA2MTYyNjM2NDY1NjY=",
  )
  assert_eq(t_id(ii, "mid_size"), "100")
  let f = @imrelay.weixin_media_item(3, "ep2", "k", 80, 70, "doc.pdf", "m2")
  assert_eq(t_id(f, "type"), "4")
  let fi = t_obj(f, "file_item")
  assert_eq(t_s(fi, "file_name"), "doc.pdf")
  assert_eq(t_s(fi, "len"), "70")
  let v = @imrelay.weixin_media_item(2, "ep3", "k", 200, 190, "v.mp4", "m3")
  let vi = t_obj(v, "video_item")
  assert_eq(t_s(vi, "video_md5"), "m3")
  assert_eq(t_id(vi, "video_size"), "200")
}

///|
test "weixin: message type from media kinds" {
  assert_eq(@imrelay.weixin_message_type_from_kinds(["photo"]), @imrelay.Photo)
  assert_eq(@imrelay.weixin_message_type_from_kinds(["video"]), @imrelay.Video)
  assert_eq(@imrelay.weixin_message_type_from_kinds(["voice"]), @imrelay.Voice)
  assert_eq(
    @imrelay.weixin_message_type_from_kinds(["document"]),
    @imrelay.Document,
  )
  assert_eq(@imrelay.weixin_message_type_from_kinds([]), @imrelay.Text)
}

///|
test "weixin: stale-session detection (Hermes _is_session_expired)" {
  assert_true(@imrelay.weixin_is_session_expired(-14, 0, ""))
  assert_true(@imrelay.weixin_is_session_expired(0, -2, "prepare failed"))
  assert_true(@imrelay.weixin_is_stale_session(-2, 0, "UNKNOWN Error"))
  assert_true(!@imrelay.weixin_is_session_expired(0, -2, "freq limited"))
  assert_true(!@imrelay.weixin_is_stale_session(0, 0, ""))
}

///|
test "weixin: item text with quotes and voice fallback" {
  let raw =
    #|{"item_list":[{"type":1,"text_item":{"text":"hi"},"ref_msg":{"title":"Photo.jpg","message_item":{"type":2}}}]}
  assert_eq(
    @imrelay.weixin_item_text(t_json(raw)),
    "[引用媒体: Photo.jpg]\nhi",
  )
  let raw2 =
    #|{"item_list":[{"type":1,"text_item":{"text":"y"},"ref_msg":{"title":"t1","message_item":{"type":1,"text_item":{"text":"inner"}}}}]}
  assert_eq(@imrelay.weixin_item_text(t_json(raw2)), "[引用: t1 | inner]\ny")
  let raw3 =
    #|{"item_list":[{"type":3,"voice_item":{"text":"ni hao"}}]}
  assert_eq(
    @imrelay.weixin_item_text(t_json(raw3)),
    "[Voice transcription provided by Weixin]\nni hao",
  )
  let raw4 =
    #|{"item_list":[{"type":3,"voice_item":{"media":{},"text":"ni hao"}}]}
  assert_eq(@imrelay.weixin_item_text(t_json(raw4)), "")
}

///|
test "weixin: media descriptor for every inbound kind" {
  let image_raw =
    #|{"type":2,"image_item":{"file_name":"a.jpg","media":{"encrypt_query_param":"p","aes_key":"AQ=="}}}
  let image = t_json(image_raw)
  match @imrelay.weixin_media_descriptor(image) {
    Some((kind, mime, name, key)) => {
      assert_eq(kind, "photo")
      assert_eq(mime, "image/jpeg")
      assert_eq(name, "a.jpg")
      assert_eq(key, "image_item")
    }
    None => assert_true(false)
  }
  let vid_raw =
    #|{"type":5,"video_item":{"media":{}}}
  let vid = t_json(vid_raw)
  match @imrelay.weixin_media_descriptor(vid) {
    Some((kind, mime, _, _)) => {
      assert_eq(kind, "video")
      assert_eq(mime, "video/mp4")
    }
    None => assert_true(false)
  }
  let file_raw =
    #|{"type":4,"file_item":{"file_name":"report.PDF"}}
  let file = t_json(file_raw)
  match @imrelay.weixin_media_descriptor(file) {
    Some((kind, mime, name, _)) => {
      assert_eq(kind, "document")
      assert_eq(mime, "application/pdf")
      assert_eq(name, "report.PDF")
    }
    None => assert_true(false)
  }
  let text_item =
    #|{"type":1,"text_item":{"text":"x"}}
  assert_true(@imrelay.weixin_media_descriptor(t_json(text_item)) is None)
}

///|
test "weixin: qr credentials extraction" {
  let ok_raw =
    #|{"status":"confirmed","ilink_bot_id":"bot-1","bot_token":"tok","ilink_user_id":"u@im.bot","baseurl":"https://ilinkai.weixin.qq.com"}
  let ok = t_json(ok_raw)
  let creds = @imrelay.weixin_qr_creds(ok).unwrap()
  assert_eq(t_s(creds, "account_id"), "bot-1")
  assert_eq(t_s(creds, "token"), "tok")
  assert_eq(t_s(creds, "user_id"), "u@im.bot")
  assert_eq(t_s(creds, "base_url"), "https://ilinkai.weixin.qq.com")
  // missing token -> None; missing baseurl -> default
  let no_token =
    #|{"status":"confirmed","ilink_bot_id":"b"}
  assert_true(@imrelay.weixin_qr_creds(t_json(no_token)) is None)
  let no_base_raw =
    #|{"status":"confirmed","ilink_bot_id":"b","bot_token":"t"}
  let no_base = @imrelay.weixin_qr_creds(t_json(no_base_raw)).unwrap()
  assert_eq(t_s(no_base, "base_url"), "https://ilinkai.weixin.qq.com")
  let waiting =
    #|{"status":"wait"}
  assert_true(@imrelay.weixin_qr_creds(t_json(waiting)) is None)
}

///|
test "weixin: event enrichment with media" {
  let raw =
    #|{"from_user_id":"u1","msg_id":"9","item_list":[{"type":1,"text_item":{"text":"/go"}}]}
  let ev = @imrelay.weixin_parse_message(t_json(raw)).unwrap()
  assert_eq(ev.message_type, @imrelay.Command)
  let att : Array[@imrelay.MediaAttachment] = [
    { url: "data:image/jpeg;base64,xx", kind: "photo", },
  ]
  let ev2 = @imrelay.weixin_with_media(ev, att)
  assert_eq(ev2.message_type, @imrelay.Photo)
  assert_eq(ev2.media.length(), 1)
  assert_eq(ev2.text, "/go")
  assert_eq(ev2.chat_id, "u1")
}
