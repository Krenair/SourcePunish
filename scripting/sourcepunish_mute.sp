#include <sourcemod>
#include <sdktools>
#include <sourcepunish>
#include <sourcepunish_punishment>

public Plugin:myinfo = {
	name = "SourcePunish Mute",
	author = "Azelphur",
	description = "Mute plugin for SourcePunish",
	version = "0.2",
	url = "https://github.com/Krenair/SourcePunish"
};

public OnAllPluginsLoaded() {
	RegisterPunishment("mute", "Mute", AddPunishment, RemovePunishment, 0, ADMFLAG_CHAT);
}

public AddPunishment(client, String:reason[], String:adminName[]) {
	SetClientListeningFlags(client, VOICE_MUTED);
}

public RemovePunishment(client) {
	new Handle:hDeadTalk = FindConVar("sm_deadtalk");
	if (hDeadTalk != INVALID_HANDLE) {
		if (GetConVarInt(hDeadTalk) == 1 && !IsPlayerAlive(client)) {
			SetClientListeningFlags(client, VOICE_LISTENALL);
		} else if (GetConVarInt(hDeadTalk) == 2 && !IsPlayerAlive(client)) {
			SetClientListeningFlags(client, VOICE_TEAM);
		} else {
			SetClientListeningFlags(client, VOICE_NORMAL);
		}
	} else {
		SetClientListeningFlags(client, VOICE_NORMAL);
	}
}
