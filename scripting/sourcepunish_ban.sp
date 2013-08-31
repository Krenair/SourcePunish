#include <sourcemod>
#include <sdktools>
#include <sourcepunish>
#include <sourcepunish_punishment>

public Plugin:myinfo = {
	name = "SourcePunish Ban",
	author = "Alex",
	description = "Ban plugin for SourcePunish",
	version = "0.1",
	url = "https://github.com/Krenair/SourcePunish"
};

public OnAllPluginsLoaded() {
	RegisterPunishment("ban", "Ban", AddPunishment, RemovePunishment, SP_NOREMOVE, ADMFLAG_BAN);
}

public AddPunishment(client, String:reason[]) {
	KickClient(client, "Banned: %s", reason);
}

public RemovePunishment(client) {}
