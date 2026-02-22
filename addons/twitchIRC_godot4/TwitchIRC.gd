extends Node
class_name TwitchIRC

# TwitchIRC 1.1 (4.0+) logs into the provided channel's IRC and broadcasts incoming chat messages in realtime via the chat_message signal
# please see the attached test_scene.tscn for a usage example

# for anonymous READ ONLY mode, leave OAUTH blank.
# to POST to chat, enter your account's OAUTH token and your twitch USERNAME. Then use send_chat_message to post.

# You can retrieve an OAUTH token by going to https://twitchtokengenerator.com/
# save the Access Token it provides and paste into the OAUTH field (with an "oauth:" prefix)

## !! DO NOT SAVE YOUR ACCOUNT DETAILS ANYWHERE IN YOUR PROJECT !! ##

# 1.1 features *correct* USERNOTICE and PRIVMSG handling, all USERNOTICE events are now properly parsed
# you can also use the new build_privmsg and build_usernotice funcs to make fake messages for testing (or gameplay?) purposes.

signal chat_message(msg:Dictionary)

# channel to join
@export var channel:String = "twitch_channel_name"

# account details
@export var OAUTH:String = ""    # your twitch OAUTH token (oauth:xxxxxxxxxxxx format)
@export var USERNAME:String = "" # your twitch username
var self_user_tags:Dictionary = {}

# server connection
@export var max_reconnect_attempts:int = 5
const SERVER:String = "irc.chat.twitch.tv"
const PORT:int = 6667

# internal state
@export var dbp:bool = true # debug print toggle
var tcp:StreamPeerTCP = StreamPeerTCP.new()
var connected:bool = false
var joined_channel:bool = false
var oauth_login:bool = false

# regex helpers
var chat_regex:RegEx = RegEx.new()
var user_regex:RegEx = RegEx.new()

# setup
func _ready()->void:
	chat_regex.compile("PRIVMSG #[^ ]+ :(.+)")
	user_regex.compile("^:(\\w+)!")
	
	var err:int = tcp.connect_to_host(SERVER, PORT)
	if err != OK:
		if dbp: print("[TwitchIRC] Failed to connect to Twitch IRC.")
		return

func _process(_delta:float)->void:
	# poll connection
	tcp.poll()
	
	# detect lost connection
	if connected and tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		if dbp: print("[TwitchIRC] Lost connection to Twitch IRC.")
		reconnect()
		return
	
	# wait for connection
	if not connected:
		if tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			connected = true
			reconnect_attempts = 0  # reset attempts on success
			if dbp: print("[TwitchIRC] Connected to Twitch IRC, logging in...")
			_login()
		return
	
	# read incoming data
	if tcp.get_available_bytes() > 0:
		var response:String = tcp.get_utf8_string(tcp.get_available_bytes())
		_handle_response(response)

# IRC login
func _login()->void:
	# ask to receive details from posts
	_send("CAP REQ :twitch.tv/tags twitch.tv/commands twitch.tv/membership")
	
	# attempt oauth login
	if not OAUTH.is_empty():
		# login with username and oauth token
		_send("PASS %s" % OAUTH)
		_send("NICK %s" % USERNAME)
	# attempt anonymous login
	else:
		_send("PASS SCHMOOPIIE")
		_send("NICK justinfan" + str(randi_range(10000, 99999)))
	
	if dbp: print("[TwitchIRC] Sent login commands, waiting for welcome message...")

# IRC logout
func _logout()->void:
	if connected:
		_send("QUIT :Client disconnecting")
	
	tcp.disconnect_from_host()
	connected = false
	joined_channel = false
	if dbp: print("[TwitchIRC] Disconnected from Twitch IRC.")

# IRC reconnect
var reconnect_attempts:int = 0
func reconnect()->void:
	if reconnect_attempts >= max_reconnect_attempts:
		if dbp: print("[TwitchIRC] Max reconnect attempts reached. Giving up.")
		emit_signal("chat_message", {"username":"[TwitchIRC]","message":"Failed to reconnect after %d attempts." % max_reconnect_attempts})
		return
	
	reconnect_attempts += 1
	if dbp: print("[TwitchIRC] Attempting reconnect (%d/%d)..." % [reconnect_attempts, max_reconnect_attempts])
	
	_logout()  # clear state
	
	var err:int = tcp.connect_to_host(SERVER, PORT)
	if err != OK:
		if dbp: print("[TwitchIRC] Reconnect failed with error:", err)
		# retry after delay
		await get_tree().create_timer(5.0).timeout
		reconnect()
	else:
		if dbp: print("[TwitchIRC] Reconnect initiated, waiting for connection...")

# send commands
func _send(cmd:String)->void:
	tcp.put_data((cmd + "\r\n").to_utf8_buffer())

# send message to channel (requires oauth_login)
func send_chat_message(text: String) -> void:
	if not joined_channel or not oauth_login or text.is_empty():
		return
	var line: String = "PRIVMSG #%s :%s" % [channel.to_lower(), text]
	_send(line)
	
	# local echo of our sent message
	var fake_line: String = ":%s!%s@%s.tmi.twitch.tv PRIVMSG #%s :%s" % [
		USERNAME, USERNAME, USERNAME, channel.to_lower(), text
	]
	var msg: Dictionary = _parse_message(fake_line, self_user_tags)
	emit_signal("chat_message", msg)


# IRC Message Handling
func _handle_response(response: String) -> void:
	var lines: Array = response.split("\r\n", false)
	for line in lines:
		if line.is_empty():
			continue
		
		if line.begins_with("PING"):
			_send("PONG " + line.substr(5))
			continue
		
		if not joined_channel and line.find("001") != -1:
			_send("JOIN #%s" % channel.to_lower())
			joined_channel = true
			oauth_login = not OAUTH.is_empty()
			continue
		
		# if we're using oauth, cache user details
		if line.find("USERSTATE") != -1 and oauth_login:
			self_user_tags = _parse_tags(line)
			continue
		
		var tags: Dictionary = _parse_tags(line)
		var msg: Dictionary = _parse_message(line, tags)
		if not msg["message"].is_empty():
			emit_signal("chat_message", msg)


# tag parsing
func _parse_tags(line:String)->Dictionary:
	var tags:Dictionary = {}
	
	if line.begins_with("@"):
		var tag_str:String = line.substr(1, line.find(" "))
		var parts:Array = tag_str.split(";")
		for part in parts:
			var kv:Array = part.split("=")
			if kv.size() == 2:
				tags[kv[0]] = kv[1]
	
	return tags

# message parsing
func _parse_message(line:String, tags:Dictionary) -> Dictionary:
	var msg:Dictionary = {
		## PRIVMSG specific ##
		"user_id": "",
		"room_id": "",
		"username": "",
		"namecolor": Color.WHITE,
		"message": "",
		"is_subscriber": false,
		"is_mod": false,
		"badge_info": "",
		"is_turbo": false,
		"at_streamer": false,
		"is_action": false,
		"is_first_message": false,
		"is_vip": false,
		"is_streamer": false,
		"is_reply": false,
		"bits": "0",
		"is_cheer": false,
		"reply_parent_id": "",
		"reply_parent_user": "",
		"is_thread_reply": false,
		"is_highlighted": false,
		## USERNOTICE specific ##
		"is_usernotice": false,
		# bits
		"is_bits_milestone": false,
		"bits_milestone": "0",
		# announcements
		"is_announcement": false,
		"announcement_color": Color("#9147FF"), # (twitch purple)
		# subs
		"is_sub": false, # first time sub
		"sub_tier": "1000", # Tier 1 by default
		"is_resub": false, # continuous sub
		"sub_streak": -1, # uninterrupted sub streak (in months)
		"subbed_months": 0, # total number of months subbed
		"is_sub_gift": false,
		"is_anon_sub_gift": false,
		"gift_recipient": "",
		"months_gifted": "",
		"gift_tier": "1000",
		"is_mysterygift": false,
		"mysterygift_recipient": "",
		"mysterygift_amount": "0",
		# raids
		"is_raid": false,
		"raider": "",
		"raidercount": "0",
		# charity
		"is_charity_donation": false,
		"is_charity_alert": false,
		"charity_name": "",
		"charity_donation_amount": "0",
		"charity_currency": "USD",
	}
	
	# username
	if tags.has("display-name") and tags["display-name"] != "":
		msg.username = tags["display-name"]
	else:
		var m:RegExMatch = user_regex.search(line)
		if m:
			msg.username = m.get_string(1)
	
	# name color
	if tags.has("color") and tags["color"] != "":
		msg.namecolor = Color(tags["color"])
	
	# subscriber
	msg.is_subscriber = tags.get("subscriber", "0") == "1"
	
	# mod
	msg.is_mod = tags.get("mod", "0") == "1"
	
	# message body
	var chat_match:RegExMatch = chat_regex.search(line)
	if chat_match:
		msg.message = chat_match.get_string(1).strip_edges()
	
	# /me ACTION messages
	if msg.message.begins_with(char(1) + "ACTION "):
		msg.is_action = true
		msg.message = msg.message.replace(char(1) + "ACTION ", "").replace(char(1), "")
	
	# first-time chatter
	msg.is_first_message = tags.get("first-msg", "0") == "1"
	
	# VIP
	if tags.has("badges") and tags["badges"].find("vip") != -1:
		msg.is_vip = true
	
	# streamer
	if tags.has("badges") and tags["badges"].find("broadcaster") != -1:
		msg.is_streamer = true
	
	# @reply detection
	if msg.message.find("@") != -1:
		msg.is_reply = true
	
	# @streamer detection
	var streamer_tag:String = "@" + channel.to_lower()
	if msg.message.to_lower().find(streamer_tag) != -1:
		msg.at_streamer = true
	
	# bits
	msg.bits = int(tags.get("bits", "0"))
	msg.is_cheer = tags.get("msg-id", "") == "cheer"
	
	# highlighted message
	msg.is_highlighted = tags.get("msg-id", "") == "highlighted-message"
	
	# threaded reply system
	msg.reply_parent_id = tags.get("reply-parent-msg-id", "")
	msg.reply_parent_user = tags.get("reply-parent-display-name", "")
	msg.is_thread_reply = msg.reply_parent_id != ""
	
	# user ID
	msg.user_id = tags.get("user-id", "")
	
	# room ID
	msg.room_id = tags.get("room-id", "")
	
	# turbo badge
	msg.is_turbo = tags.get("turbo", "0") == "1"
	
	# badge info
	msg.badge_info = tags.get("badge-info", "")
	
	# is a USERNOTICE
	msg.is_usernotice = line.find("USERNOTICE") != -1
	
	# USERNOTICE chat events (sets the USERNOTICE text to the 'message' field to be read)
	if msg.is_usernotice:
		var event_type:String = tags.get("msg-id", "")
		if event_type == "announcement":
			msg.message = _get_usernotice_text(tags)
			
			msg.is_announcement = true
		
		if event_type == "sub": # first-time sub
			msg.message = _get_usernotice_text(tags)
			# sub tier (1000 = tier 1, 2000 = tier 2, 3000 = tier 3, "Prime" free prime sub)
			msg.sub_tier = str(tags.get("msg-param-sub-plan","1000"))
			
			msg.is_sub = true
		
		if event_type == "resub": # resub
			msg.message = _get_usernotice_text(tags)
			# sub tier (1000 = tier 1, 2000 = tier 2, 3000 = tier 3, "Prime" free prime sub)
			msg.sub_tier = str(tags.get("msg-param-sub-plan","1000"))
			msg.subbed_months = tags.get("msg-param-cumulative-months","0")
			if tags.get("msg-param-should-share-streak") == 1:
				msg.sub_streak = tags.get("msg-param-streak-months","0")
			
			msg.is_resub = true
		
		if event_type == "subgift": # giftsub
			msg.message = _get_usernotice_text(tags)
			# sub tier (1000 = tier 1, 2000 = tier 2, 3000 = tier 3, "Prime" free prime sub)
			msg.gift_tier = tags.get("msg-param-sub-plan","1000")
			msg.months_gifted = str(tags.get("msg-param-months","1000"))
			msg.gift_recipient = tags.get("msg-param-recipient-display-name","")
			
			msg.is_sub_gift = true
		
		if event_type == "anonsubgift": # anonymous gift sub
			msg.message = _get_usernotice_text(tags)
			# sub tier (1000 = tier 1, 2000 = tier 2, 3000 = tier 3, "Prime" free prime sub)
			msg.gift_tier = tags.get("msg-param-sub-plan","1000")
			msg.mysterygift_amount = tags.get("msg-param-mass-gift-count","0")
			msg.mysterygift_recipient = tags.get("msg-param-recipient-display-name","")
			
			msg.is_anon_sub_gift = true
		
		if event_type == "submysterygift": # mass gift sub
			msg.message = _get_usernotice_text(tags)
			# sub tier (1000 = tier 1, 2000 = tier 2, 3000 = tier 3, "Prime" free prime sub)
			msg.gift_tier = tags.get("msg-param-sub-plan","1000")
			msg.mysterygift_amount = tags.get("msg-param-mass-gift-count","0")
			
			msg.is_mysterygift = true
		
		if event_type == "bitsbadgetier": # bits badge milestone
			msg.message = _get_usernotice_text(tags)
			msg.bits_milestone = tags.get("msg-param-threshold","0")
			
			msg.is_bits_milestone = true
		
		if event_type == "raid": # raid
			msg.message = _get_usernotice_text(tags)
			msg.raider = tags.get("msg-param-displayName","") # streamer raiding
			msg.raidercount = int(tags.get("msg-param-viewerCount","0")) # viewers raiding
			
			msg.is_raid = true
		
		if event_type == "charitydonation": # charity donation
			msg.message = _get_usernotice_text(tags)
			msg.charity_name = tags.get("msg-param-charity-name","") # name of charity
			msg.charity_donation_amount = tags.get("msg-param-donation-amount","0") # in cents, 100 = 1.00 USD
			msg.charity_currency = tags.get("msg-param-donation-currency","USD") # currency code
			
			msg.is_charity_donation = true
		
		if event_type == "charitycampaignprogress": # occasional charity progress update
			msg.message = _get_usernotice_text(tags)
			msg.charity_name = tags.get("msg-param-charity-name","") # name of charity
			msg.charity_donation_amount = tags.get("msg-param-donation-amount","0") # in cents, 100 = 1.00 USD
			msg.charity_currency = tags.get("msg-param-donation-currency","USD") # currency code
			
			msg.is_charity_alert = true
		
		if event_type == "announcement": # announcement
			msg.message = _get_usernotice_text(tags)
			if tags.has("msg-param-color"): # pass announcement color
				match tags["msg-param-color"].to_upper():
					"PRIMARY":
						msg.announcement_color = "#9147FF" # twitch purple
					"BLUE":
						msg.announcement_color = "#1F6FEB"
					"GREEN":
						msg.announcement_color = "#2BA640"
					"ORANGE":
						msg.announcement_color = "#E69900"
					"PURPLE":
						msg.announcement_color = "#A970FF"
					_:
						msg.announcement_color = "#9147FF" # fallback
	
	return msg

## HELPERS ##

func _get_usernotice_text(tags:Dictionary) -> String:
	var txt:String = tags.get("system-msg", "")
	if txt == "":
		return ""
	
	txt = _unescape_irc_tag(txt)
	return txt

func _escape_irc_tag(value:String) -> String:
	value = value.replace("\\", "\\\\")
	value = value.replace(";", "\\:")
	value = value.replace(" ", "\\s")
	value = value.replace("\r", "\\r")
	value = value.replace("\n", "\\n")
	return value

func _unescape_irc_tag(value:String) -> String:
	value = value.replace("\\\\", "\u0000") # placeholder
	
	value = value.replace("\\:", ";")
	value = value.replace("\\s", " ")
	value = value.replace("\\r", "\r")
	value = value.replace("\\n", "\n")
	value = value.replace("\u0000", "\\")
	
	return value


## TEST MESSAGES ##

# these functions can be used to inject fake PRIVMSG and USERNOTICE events into your IRC stream for testing purposes
# use output as an argument in a chat_message signal

# USAGE EXAMPLE:
# var prepped_msg:Dictionary = prep_raw_message(build_privmsg(mychannel,myname,mymsg))
# emit_signal("chat_message",prepped_msg)

func build_privmsg(username:String,body:String,bits:int = 0)->String:
	var display_name:String = _escape_irc_tag(username)
	var escaped_body:String = body
	
	var msg_id:String = ""
	if bits > 0:
		var regex:= RegEx.new()
		regex.compile("(?i)cheer\\d+")
		if regex.search(body):
			msg_id = "cheer"
		else:
			msg_id = "powerup"
	
	var tags:String = "@badge-info=;badges=;color=#1E90FF;"
	tags += "display-name=%s;" % display_name
	tags += "emotes=;flags=;"
	tags += "id=11111111-2222-3333-4444-555555555555;"
	tags += "mod=0;room-id=123456;subscriber=0;"
	tags += "tmi-sent-ts=%d;" % (Time.get_unix_time_from_system() * 1000)
	tags += "turbo=0;user-id=987654;user-type="
	
	if bits > 0:
		tags += ";bits=%d;msg-id=%s" % [bits, msg_id]
	
	var prefix:String = ":%s!%s@%s.tmi.twitch.tv" % [username, username, username]
	var command:String = "PRIVMSG #%s :%s" % [channel, escaped_body]
	
	return "%s %s %s" % [tags, prefix, command]

enum notice_type {
	ANNOUNCEMENT,           # can submit a message color in extras   {"color":"#9147FF"}
	SUB,                    # can submit a sub tier in extras        {"sub_plan":"1000"} or "2000" for tier 2, "3000" for tier 3, "Prime" for Prime
	RESUB,                  # resub extras:                          {"sub_plan":"1000","months":"1","share_streak":"0","streak_months":"0"}
	SUBGIFT,                # subgift extras:                        {"sub_plan":"1000","months":"1","recipient":""}
	ANONSUBGIFT,            # anonsub gift extras:                   {"sub_plan":"1000","months":"1","recipient":""}
	SUBMYSTERYGIFT,         # mass gift extras:                      {"sub_plan":"1000","mass_count":"10"}
	BITSBADGETIER,          # bits badge rankup extra:               {"threshold":"1000"}
	RAID,                   # raid extras:                           {"raider":"","count":"10"}
	CHARITYDONATION,        # charity donation extras:               {"charity":"","amount":"100","currency":"USD"}
	CHARITYCAMPAIGNPROGRESS # charity update extras:                 {"charity":"","amount":"100","currency":"USD"}
}

# use notice_type enum to specify the usernotice type
func build_usernotice(username:String,type:int,extra:Dictionary = {})->String:
	var msg_id:String = ""
	var body:String = ""
	var system_msg:String = ""
	var params:Dictionary = {}
	var subscriber_flag:String = "0"
	
	match type:
		notice_type.ANNOUNCEMENT:
			msg_id = "announcement"
			system_msg = "%s made an announcement" % username
			if extra.has("color"):
				params["msg-param-color"] = extra["color"]
		
		notice_type.SUB:
			msg_id = "sub"
			system_msg = "%s subscribed!" % username
			params["msg-param-sub-plan"] = extra.get("sub_plan", "1000")
			subscriber_flag = "1"
		
		notice_type.RESUB:
			msg_id = "resub"
			system_msg = "%s resubscribed!" % username
			params["msg-param-sub-plan"] = extra.get("sub_plan", "1000")
			params["msg-param-cumulative-months"] = str(extra.get("months", "1"))
			params["msg-param-should-share-streak"] = str(extra.get("share_streak", "0"))
			params["msg-param-streak-months"] = str(extra.get("streak_months", "0"))
			subscriber_flag = "1"
		
		notice_type.SUBGIFT:
			msg_id = "subgift"
			system_msg = "%s gifted a sub!" % username
			params["msg-param-sub-plan"] = extra.get("sub_plan", "1000")
			params["msg-param-months"] = str(extra.get("months", "1"))
			params["msg-param-recipient-display-name"] = extra.get("recipient", "")
			subscriber_flag = "1"
		
		notice_type.ANONSUBGIFT:
			msg_id = "anonsubgift"
			system_msg = "An anonymous user gifted a sub!"
			params["msg-param-sub-plan"] = extra.get("sub_plan", "1000")
			params["msg-param-mass-gift-count"] = str(extra.get("mass_count", "1"))
			params["msg-param-recipient-display-name"] = extra.get("recipient", "")
			subscriber_flag = "1"
		
		notice_type.SUBMYSTERYGIFT:
			msg_id = "submysterygift"
			system_msg = "%s started a mass gift!" % username
			params["msg-param-sub-plan"] = extra.get("sub_plan", "1000")
			params["msg-param-mass-gift-count"] = str(extra.get("mass_count", "1"))
			subscriber_flag = "1"
		
		notice_type.BITSBADGETIER:
			msg_id = "bitsbadgetier"
			system_msg = "%s reached a bits milestone!" % username
			params["msg-param-threshold"] = str(extra.get("threshold", "1000"))
		
		notice_type.RAID:
			msg_id = "raid"
			system_msg = "%s is raiding with viewers!" % username
			params["msg-param-displayName"] = extra.get("raider", username)
			params["msg-param-viewerCount"] = str(extra.get("count", "1"))
		
		notice_type.CHARITYDONATION:
			msg_id = "charitydonation"
			system_msg = "%s donated to charity!" % username
			params["msg-param-charity-name"] = extra.get("charity", "")
			params["msg-param-donation-amount"] = str(extra.get("amount", "0"))
			params["msg-param-donation-currency"] = extra.get("currency", "USD")
		
		notice_type.CHARITYCAMPAIGNPROGRESS:
			msg_id = "charitycampaignprogress"
			system_msg = "%s updated charity progress!" % username
			params["msg-param-charity-name"] = extra.get("charity", "")
			params["msg-param-donation-amount"] = str(extra.get("amount", "0"))
			params["msg-param-donation-currency"] = extra.get("currency", "USD")
	
	# escape for IRC tags
	system_msg = _escape_irc_tag(system_msg)
	body = body.replace("%", "%%")
	
	var param_text:String = ""
	for k in params.keys():
		var v = _escape_irc_tag(str(params[k]))
		param_text += ";%s=%s" % [k, v]
	
	var timestamp:String = str(Time.get_unix_time_from_system() * 1000)
	var uuid:String = "0123456789abcdef" # dummy id
	
	var template:String = "@badge-info=;badges=;color=#9146FF;display-name=%%s;emotes=;flags=;id=%s;login=%%s;mod=0;msg-id=%s%s;room-id=123456;subscriber=%s;system-msg=%s;tmi-sent-ts=%s;turbo=0;user-id=777777;user-type= :%s!%s@%s.tmi.twitch.tv USERNOTICE #%s :%s"
	
	var result:String = template % [
		uuid,
		msg_id,
		param_text,
		subscriber_flag,
		system_msg,
		timestamp,
		username,
		username,
		username,
		channel,
		body
	]
	
	return result

func prep_raw_message(line:String)->Dictionary:
	var tags:Dictionary = _parse_tags(line)
	var msg:Dictionary = _parse_message(line, tags)
	return msg
