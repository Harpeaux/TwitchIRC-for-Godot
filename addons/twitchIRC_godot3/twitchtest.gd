extends Control

# This is a basic example of how to pull chat messages from TwitchIRC

var twitch:TwitchIRC = preload("res://addons/twitchIRC/TwitchIRC.gd").new()

var msg_processed:bool = true
var message_buffer:Dictionary = {}

func _ready()->void:
	# set channel first
	twitch.channel = ""
	
	# if using oauth login method, add OAUTH and USERNAME
	# twitch.OAUTH = "oauth:xxxxxxxxxxxx"
	# twitch.USERNAME = "my_username"
	
	# connect to outgoing chat signal
	twitch.connect("chat_message",self,"_on_chat_message")
	
	# add to scene tree
	add_child(twitch)

# receives msg dictionary when a message is posted
func _on_chat_message(msg:Dictionary)->void:
	# if we perform anything async here, we can refuse new messages until we're done processing data
	if not msg_processed : return
	msg_processed = false
	
	# save incoming message to a buffer var
	message_buffer = msg
	
	# you can do something like this to colorize the username
	var color_hex:String = Color(message_buffer.namecolor).to_html()
	var username_bbcode:String = "[color=#%s]%s: [/color] " % [color_hex, message_buffer.username]
	
	# push message to scene label
	$message.bbcode_text = "[center]" + username_bbcode + message_buffer.message + "[/center]"
	
	# print message to Output
	print("%s: %s" % [msg.username, message_buffer.message])
	
	# ready for next message
	msg_processed = true

# sends message to chatroom if properly logged in
func _on_post_text_entered(new_text):
	twitch.send_chat_message(new_text)
	$post.text = ""
