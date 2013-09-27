#include <sourcemod>
#include <sdktools>
#include <sourcepunish>
#include <sourcepunish_punishment>

public Plugin:myinfo = {
	name = "SourcePunish Ban",
	author = "Alex",
	description = "Ban plugin for SourcePunish",
	version = "0.2",
	url = "https://github.com/Krenair/SourcePunish"
};

public OnAllPluginsLoaded() {
	RegisterPunishment("ban", "Ban", AddPunishment, RemovePunishment, SP_NOREMOVE, ADMFLAG_BAN);
}

public AddPunishment(client, String:reason[], String:adminName[]) {
	KickClient(client, "Banned by %s with reason: %s", adminName, reason);
}

public RemovePunishment(client) {}
