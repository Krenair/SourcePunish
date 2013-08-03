#include <sourcemod>
#include <sdktools>
#include <sourcepunish>

public Plugin:myinfo = {
    name = "SourcePunish Kick",
    author = "Alex",
    description = "Kick plugin for SourcePunish",
    version = "0.1",
    url = "https://github.com/Krenair/SourcePunish"
};

public OnAllPluginsLoaded() {
	RegisterPunishment("kick", "Kick", KickPlayer, RemovePunishment, SP_NOREMOVE | SP_NOTIME);
}

public KickPlayer(client, String:reason[]) {
	KickClient(client, reason);
}

public RemovePunishment(client) {}
