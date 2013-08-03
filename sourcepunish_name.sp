#include <sourcemod>
#include <sdktools>
#include <sourcepunish>

public Plugin:myinfo = {
    name = "SourcePunish Block name change",
    author = "Alex",
    description = "Block name change plugin for SourcePunish",
    version = "0.1",
    url = ""
};

new g_bNameBlocked[MAXPLAYERS+1];

public OnAllPluginsLoaded() {
    RegisterPunishment("name", "Name change", AddPunishment, RemovePunishment);
    HookEvent("player_changename", Event_PlayerChangeName, EventHookMode_Pre);
}

public Action:Command_Say(client, const String:command[], argc) {
    if (g_bNameBlocked[client]) {
        return Plugin_Handled;
    }
    return Plugin_Continue;
}

public AddPunishment(client, String:reason[]) {
    g_bNameBlocked[client] = true;
}

public RemovePunishment(client) {
    g_bNameBlocked[client] = false;
}

public OnClientDisconnect(client) {
    g_bNameBlocked[client] = false;
}

public Action:Event_PlayerChangeName(Handle:event, const String:name[], bool:dontBroadcast)
{
    new userid = GetEventInt(event, "userid");
    new client = GetClientOfUserId(userid);
    if (client != 0 && g_bNameBlocked[client])
        return Plugin_Handled;
    return Plugin_Continue;
}
