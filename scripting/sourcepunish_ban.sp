#include <sourcemod>
#include <sdktools>
#include <sourcepunish>

public Plugin:myinfo = {
	name = "SourcePunish Ban",
	author = "Alex",
	description = "Ban plugin for SourcePunish",
	version = "0.1",
	url = "https://github.com/Krenair/SourcePunish"
};

public OnAllPluginsLoaded() {
	RegisterPunishment("ban", "Ban", AddPunishment, RemovePunishment, SP_NOREMOVE);
}

public AddPunishment(client, String:reason[]) {
	KickClient(client, "Banned: %s", reason);
}

public RemovePunishment(client) {}
