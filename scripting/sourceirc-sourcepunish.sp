#include <sourcemod>
#include <sdktools>
#include <sourcepunish>

public Plugin:myinfo = {
	name = "SourceIRC -> SourcePunish",
	author = "Alex",
	description = "SourcePunish integration plugin for SourceIRC",
	version = "0.1",
	url = "https://github.com/Krenair/SourcePunish"
};

public OnPluginStart() {
	AddToPunishmentRegisteredForward(PunishmentRegistered);
	new Handle:registeredPunishments = GetRegisteredPunishments();
	for (new i = 0; i < GetArraySize(registeredPunishments); i++) {
		decl String:type[64];
		GetArrayString(registeredPunishments, i, type, sizeof(type));
		PunishmentRegistered(type);
	}
}

public PunishmentRegistered(String:type[]) {
	PrintToServer("SourceIRC integration plugin has been told that punishment type %s was registered", type);
}
