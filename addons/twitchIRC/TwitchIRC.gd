extends Node
class_name TwitchIRC

# TwitchIRC (3.2+) logs into the provided channel's IRC and broadcasts incoming chat messages in realtime via the chat_message signal
# please see the attached test_scene.tscn for a usage example

# for anonymous READ ONLY mode, leave OAUTH blank.
# to POST to chat, enter your account's OAUTH token and your twitch USERNAME. Then use send_chat_message to post.

# You can retrieve an OAUTH token by going to https://twitchtokengenerator.com/
# save the Access Token it provides and paste into the OAUTH field (with an "oauth:" prefix)

## !! DO NOT SAVE YOUR ACCOUNT DETAILS ANYWHERE IN YOUR PROJECT !! ##

signal chat_message(msg)

# channel to join
export(String)var channel = "twitch_channel_name"

# account details
export(String)var OAUTH = ""    # your twitch OAUTH token (oauth:xxxxxxxxxxxx format)
export(String)var USERNAME = "" # your twitch username
var self_user_tags:Dictionary = {}

# server connection
export(int) var max_reconnect_attempts:int = 5
const SERVER:String = "irc.chat.twitch.tv"
const PORT:int = 6667

# internal state
export(bool)var dbp = true # debug print toggle
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
		if dbp:print("[TwitchIRC] Failed to connect to Twitch IRC.")
		return

func _process(_delta:float)->void:
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
		var response: String = tcp.get_utf8_string(tcp.get_available_bytes())
		_handle_response(response)

# IRC login
func _login()->void:
	# ask to receive details from posts
	_send("CAP REQ :twitch.tv/tags twitch.tv/commands twitch.tv/membership")
	
	# attempt oauth login
	if not OAUTH.empty():
		# login with username and oauth token
		_send("PASS %s" % OAUTH)
		_send("NICK %s" % USERNAME)
	# attempt anonymous login
	else:
		_send("PASS SCHMOOPIIE")
		_send("NICK justinfan" + str(10000 + int(randi() % 90000)))
	
	if dbp:print("[TwitchIRC] Sent login commands, waiting for welcome message...")

# IRC logout
func _logout()->void:
	if connected:
		_send("QUIT :Client disconnecting")
	
	tcp.disconnect_from_host()
	connected = false
	joined_channel = false
	if dbp:print("[TwitchIRC] Disconnected from Twitch IRC.")

# IRC reconnect
var reconnect_attempts:int = 0
func reconnect()->void:
	if reconnect_attempts >= max_reconnect_attempts:
		if dbp:print("[TwitchIRC] Max reconnect attempts reached. Giving up.")
		emit_signal("chat_message", {"username":"[TwitchIRC]","message":"Failed to reconnect after %d attempts." % max_reconnect_attempts})
		return
	
	reconnect_attempts += 1
	if dbp: print("[TwitchIRC] Attempting reconnect (%d/%d)..." % [reconnect_attempts, max_reconnect_attempts])
	
	_logout()  # clear state
	
	var err:int = tcp.connect_to_host(SERVER, PORT)
	if err != OK:
		if dbp:print("[TwitchIRC] Reconnect failed with error:", err)
		# retry after delay
		yield(get_tree().create_timer(5.0), "timeout")
		reconnect()
	else:
		if dbp: print("[TwitchIRC] Reconnect initiated, waiting for connection...")

# send commands
func _send(cmd:String)->void:
	tcp.put_data((cmd + "\r\n").to_utf8())

# send message to channel (requires oauth_login)
func send_chat_message(text:String) -> void:
	if not joined_channel or not oauth_login or text.empty():
		return
	var line:String = "PRIVMSG #%s :%s" % [channel.to_lower(), text]
	_send(line)
	
	# local echo of our sent message
	var msg:Dictionary = _parse_message(
		":%s!%s@%s.tmi.twitch.tv PRIVMSG #%s :%s" % [USERNAME, USERNAME, USERNAME, channel.to_lower(), text],
		self_user_tags
	)
	emit_signal("chat_message", msg)

# IRC Message Handling
func _handle_response(response:String) -> void:
	var lines:Array = response.split("\r\n", false)
	for line in lines:
		if line == "":
			continue
		
		if line.begins_with("PING"):
			_send("PONG " + line.substr(5))
			continue
		
		if not joined_channel and line.find("001") != -1:
			_send("JOIN #%s" % channel.to_lower())
			joined_channel = true
			oauth_login = not OAUTH.empty()
			continue
		
		# if we're using oauth, cache user details
		if line.find("USERSTATE") != -1 and oauth_login:
			self_user_tags = _parse_tags(line)
			continue
		
		var tags:Dictionary = _parse_tags(line)
		var msg:Dictionary = _parse_message(line, tags)
		if not msg.message.empty():
			emit_signal("chat_message", msg)

# tag parsing
func _parse_tags(line:String) -> Dictionary:
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
func _parse_message(line:String,tags:Dictionary)->Dictionary:
	var msg:Dictionary = {
		"username": "",
		"namecolor": Color.white,
		"message": "",
		"subscriber": false,
		"mod": false,
		"is_reply": false,
		"at_streamer": false,
		"is_action": false,
		"is_first_message": false,
		"is_vip": false,
		"is_broadcaster": false,
		"is_cheer": false,
		"bits": 0,
		"is_announcement": false,
		"is_highlighted": false,
		"is_sub_gifter": false,
		"is_thread_reply": false,
		"reply_parent_id": "",
		"reply_parent_user": "",
		"user_id": "",
		"room_id": "",
		"is_turbo": false,
		"badge_info": ""
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
	msg.subscriber = tags.get("subscriber", "0") == "1"
	
	# mod
	msg.mod = tags.get("mod", "0") == "1"
	
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
	
	# broadcaster
	if tags.has("badges") and tags["badges"].find("broadcaster") != -1:
		msg.is_broadcaster = true
	
	# bits
	msg.bits = int(tags.get("bits", "0"))
	
	# cheers
	msg.is_cheer = msg.bits > 0
	
	# announcement
	msg.is_announcement = tags.get("msg-id", "") == "announcement"
	
	# highlighted message
	msg.is_highlighted = tags.get("msg-id", "") == "highlighted-message"
	
	# sub gifter
	msg.is_sub_gifter = tags.get("msg-id", "") == "subgift"
	
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
	
	# badge info (sub streaks, founder, etc.)
	msg.badge_info = tags.get("badge-info", "")
	
	# @reply detection
	if msg.message.find("@") != -1:
		msg.is_reply = true
	
	# @streamer detection
	var streamer_tag:String = "@" + channel.to_lower()
	if msg.message.to_lower().find(streamer_tag) != -1:
		msg.at_streamer = true
	
	return msg
