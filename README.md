## TwitchIRC for Godot

This is a lightweight, single-script addon for Godot 3.2+ that can connect to a Twitch channel's IRC chatroom. It reads, parses, and formats incoming chat messages into a human-readable Dictionary for use in your Godot projects.

### Features
- Anonymous login that requires no credentials or tokens *(Read Only)*
- Oauth token login that allows posting to the chat via Godot
- Chat messages are broadcast in a readable `Dictionary` via the `chat_message` signal
- The Dictionary has over a dozen details on the user, including things like bits, cheers, highlighted messages, announcements, sub gifts, and *many* more.

### Installation and Usage
Add TwitchIRC to your Godot project's addons folder, assign `TwitchIRC.gd` to a basic Node, set the channel and login details and then add the script to the scene tree.

For an example on usage, check the example in `test_scene.tscn`, which will read the chatroom and publish the messages to the Output window as well as a RichTextLabel node. If you have an oauth token, you can login and send messages in the LineEdit element in the scene.

### Notes:
This addon does *not* have emote support. It's designed only to retrieve user data and the raw text messages they send.

This implementation is extremely bare-bones, it has a simple reconnect feature but not much else. In my testing it has had no issues, but your mileage may vary.
