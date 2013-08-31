#include <sourcemod>
#include <sdktools>
#include <sourcepunish>
#include <sourcepunish_punishment>

public Plugin:myinfo = {
	name = "SourcePunish Gag",
	author = "Alex",
	description = "Gag plugin for SourcePunish",
	version = "0.1",
	url = "https://github.com/Krenair/SourcePunish"
};

new mutedPlayers[MAXPLAYERS + 1];

public OnAllPluginsLoaded() {
	RegisterPunishment("gag", "Gag", GagPlayer, UngagPlayer, 0, ADMFLAG_CHAT);
	AddCommandListener(Command_Say, "say");
	AddCommandListener(Command_Say, "say2");
	AddCommandListener(Command_Say, "say_team");
}

public Action:Command_Say(client, const String:command[], argc) {
	if (mutedPlayers[client]) {
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

public OnClientDisconnect(client) {
	mutedPlayers[client] = false;
}

public GagPlayer(client, String:reason[], String:adminName[]) {
	mutedPlayers[client] = true;
}

public UngagPlayer(client) {
	mutedPlayers[client] = false;
}
