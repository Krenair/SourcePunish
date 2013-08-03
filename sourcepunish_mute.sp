#include <sourcemod>
#include <sdktools>
#include <sourcepunish>

public Plugin:myinfo = {
    name = "SourcePunish Mute",
    author = "Alex",
    description = "Mute plugin for SourcePunish",
    version = "0.1",
    url = ""
};

public OnAllPluginsLoaded() {
    RegisterPunishment("mute", "Mute", AddPunishment, RemovePunishment);
}

public AddPunishment(client, String:reason[]) {
    SetClientListeningFlags(client, VOICE_MUTED);
}

public RemovePunishment(client) {
    new Handle:hDeadTalk = FindConVar("sm_deadtalk");
    if (hDeadTalk != INVALID_HANDLE)
    {
        if (GetConVarInt(hDeadTalk) == 1 && !IsPlayerAlive(client))
        {
            SetClientListeningFlags(client, VOICE_LISTENALL);
        }
        else if (GetConVarInt(hDeadTalk) == 2 && !IsPlayerAlive(client))
        {
            SetClientListeningFlags(client, VOICE_TEAM);
        }
        else
        {
            SetClientListeningFlags(client, VOICE_NORMAL);
        }
    }
    else
    {
        SetClientListeningFlags(client, VOICE_NORMAL);
    }
}