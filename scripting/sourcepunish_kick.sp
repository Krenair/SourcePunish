#include <sourcemod>
#include <sdktools>
#include <sourcepunish>
#include <sourcepunish_punishment>

public Plugin:myinfo = {
	name = "SourcePunish Kick",
	author = "Alex",
	description = "Kick plugin for SourcePunish",
	version = "0.1",
	url = "https://github.com/Krenair/SourcePunish"
};

public OnAllPluginsLoaded() {
	RegisterPunishment("kick", "Kick", KickPlayer, RemovePunishment, SP_NOREMOVE | SP_NOTIME, ADMFLAG_KICK);
}

public KickPlayer(client, String:reason[], String:adminName[]) {
	KickClient(client, "Kicked by %s with reason: %s", adminName, reason);
}

public RemovePunishment(client) {}
