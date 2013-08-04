//TODO: Menu
//TODO: Separate commands

#include <sourcemod>
#include <sdktools>
#include <sourcepunish>

public Plugin:myinfo = {
	name = "SourcePunish",
	author = "Alex, Azelphur and MonsterKiller",
	description = "Punishment management system",
	version = "0.03",
	url = "https://github.com/Krenair/SourcePunish"
}

enum punishmentType {
	Handle:addCallback,
	Handle:removeCallback,
	String:name[64], // Eg, "ban" or "spray", database safe name
	String:displayName[64], // Eg, "Ban" or "Spray", display name for menus, etc.
	flags,
}

new Handle:punishments = INVALID_HANDLE;
new Handle:punishmentRemovalTimers[MAXPLAYERS + 1];
new Handle:db = INVALID_HANDLE;
new Handle:configKeyValues = INVALID_HANDLE;
new serverID;

public OnPluginStart() {
	punishments = CreateTrie();
	LoadTranslations("common.phrases");
	RegAdminCmd("sm_punish", Command_Punish, ADMFLAG_GENERIC, "Punishes a player");

	SQL_TConnect(SQLConnected, "default");

	new String:keyValueFile[128];
	BuildPath(Path_SM, keyValueFile, sizeof(keyValueFile), "configs/sourcepunish.cfg");
	if (!FileExists(keyValueFile)) {
		ThrowError("configs/sourcepunish.cfg does not exist!");
	}
	configKeyValues = CreateKeyValues("SourcePunish");
	FileToKeyValues(configKeyValues, keyValueFile);

	if (!KvJumpToKey(configKeyValues, "Settings")) {
		ThrowError("Settings key in config does not exist!");
	}

	serverID = KvGetNum(configKeyValues, "ServerID", 0);
	if (serverID < 1) {
		ThrowError("Server ID in config is invalid! Should be at least 1");
	}
}

public SQLConnected(Handle:owner, Handle:databaseHandle, const String:error[], any:data) {
	if (databaseHandle == INVALID_HANDLE) {
		ThrowError("Error connecting to DB: %s", error);
	}
	db = databaseHandle;
	decl String:query[512];
	Format(query, sizeof(query), "SELECT Punish_Type, Punish_Admin_ID, Punish_Admin_Name, Punish_Player_ID, Punish_Time, Punish_Length FROM sourcepunish_punishments WHERE UnPunish = 0 AND (Punish_Server_ID = %i OR Punish_All_Servers = 1) AND (Punish_Time + (Punish_Length * 60)) > UNIX_TIMESTAMP(NOW());", serverID);
	SQL_TQuery(db, ActivePunishmentsLookupComplete, query);
}

public ActivePunishmentsLookupComplete(Handle:owner, Handle:query, const String:error[], any:data) {
	if (query == INVALID_HANDLE) {
		ThrowError("Error querying DB: %s", error);
	}
	decl String:clientAuths[MAXPLAYERS + 1][64];
	for (new i = 1; i <= MaxClients; i++) {
		if (IsClientConnected(i)) {
			decl String:auth[64];
			GetClientAuthString(i, auth, sizeof(auth));
			strcopy(clientAuths[i], sizeof(clientAuths[]), auth);
		}
	}

	while (SQL_FetchRow(query)) {
		decl String:type[64], String:punisherAuth[64], String:punisherName[64], String:punishedAuth[64];
		SQL_FetchString(query, 0, type, sizeof(type));
		SQL_FetchString(query, 1, punisherAuth, sizeof(punisherAuth));
		SQL_FetchString(query, 2, punisherName, sizeof(punisherName));
		SQL_FetchString(query, 3, punishedAuth, sizeof(punishedAuth));
		new startTime = SQL_FetchInt(query, 4);

		for (new i = 1; i <= MaxClients; i++) {
			decl String:auth[64];
			strcopy(auth, sizeof(auth), clientAuths[i]);
			if (StrEqual(punishedAuth, auth)) {
				decl pmethod[punishmentType];
				// TODO: Race condition here. If this code is run before any plugins have registered (e.g. if SourcePunish is reloaded) we won't know about any punishment types.
				if (!GetTrieArray(punishments, type, pmethod, sizeof(pmethod))) {
					PrintToServer("Loaded an active punishment with unknown type %s", type);
				}

				if (!(pmethod[flags] & SP_NOREMOVE) && !(pmethod[flags] & SP_NOTIME)) {
					new Handle:punishmentInfoPack = CreateDataPack();
					WritePackString(punishmentInfoPack, type);
					WritePackCell(punishmentInfoPack, i);
					WritePackString(punishmentInfoPack, punisherName);
					WritePackCell(punishmentInfoPack, startTime);
					ResetPack(punishmentInfoPack); // Move index back to beginning so we can read from it.
					new endTime = startTime + (SQL_FetchInt(query, 5) * 60);
					punishmentRemovalTimers[i] = CreateTimer(float(GetTime() - endTime), PunishmentExpire, punishmentInfoPack);
				}
				break;
			}
		}
	}
}

public Action:Command_Punish(client, args) {
	new timestamp = GetTime();
	if (args < 2) {
		ReplyToCommand(client, "[SM] Usage: sm_punish <type> <target> [time|0] [reason]");
		return Plugin_Handled;
	}

	decl String:type[64];
	GetCmdArg(1, type, sizeof(type));
	decl pmethod[punishmentType];
	if (!GetTrieArray(punishments, type, pmethod, sizeof(pmethod))) {
		ReplyToCommand(client, "[SM] Punishment type %s not found.", type);
		return Plugin_Handled;
	}

	decl String:target[64];

	new reasonArgumentNum = 3;
	decl String:time[64];
	if (!(pmethod[flags] & SP_NOTIME)) {
		reasonArgumentNum = 4;
	}

	decl String:fullArgString[64];
	GetCmdArgString(fullArgString, sizeof(fullArgString));
	new pos = BreakString(fullArgString, type, sizeof(type));
	pos = pos + BreakString(fullArgString[pos], target, sizeof(target));

	decl String:reason[64];
	if (args >= reasonArgumentNum) {
		if (reasonArgumentNum == 4) {
			pos = pos + BreakString(fullArgString[pos], time, sizeof(time));
		} else {
			strcopy(time, sizeof(time), "0");
		}
		strcopy(reason, sizeof(reason), fullArgString[pos]);
	} else {
		reason[0] = '\0'; // Make it safe per http://wiki.alliedmods.net/Introduction_to_SourcePawn#Caveats
	}

	new String:target_name[MAX_TARGET_LENGTH]; // Stores the noun identifying the target(s)
	new target_list[MAXPLAYERS], target_count; // Array to store the clients, and also a variable to store the number of clients
	new bool:tn_is_ml; // Stores whether the noun must be translated

	if ((target_count = ProcessTargetString(
		target,
		client,
		target_list,
		MAXPLAYERS,
		COMMAND_FILTER_CONNECTED, // We want to allow targetting even players who are not fully in-game but connected
		target_name,
		sizeof(target_name),
		tn_is_ml
	)) <= 0) {
		// Reply to the admin with a failure message
		ReplyToTargetError(client, target_count);
		return Plugin_Handled;
	}

	decl String:setBy[64], String:setByAuth[64];
	GetClientName(client, setBy, sizeof(setBy));
	GetClientAuthString(client, setByAuth, sizeof(setByAuth));

	for (new i = 0; i < target_count; i++) {
		decl String:targetName[64], String:targetAuth[64], String:targetIP[64];
		GetClientName(target_list[i], targetName, sizeof(targetName));
		GetClientAuthString(target_list[i], targetAuth, sizeof(targetAuth));
		GetClientIP(target_list[i], targetIP, sizeof(targetIP));

		RecordPunishmentInDB(type, setByAuth, setBy, targetAuth, targetName, targetIP, timestamp, StringToInt(time), reason); //TODO: Use this.
		Call_StartForward(pmethod[addCallback]);
		Call_PushCell(target_list[i]);
		Call_PushString(reason);
		decl result; //TODO: Use this.
		Call_Finish(result);

		if (!(pmethod[flags] & SP_NOREMOVE) && !(pmethod[flags] & SP_NOTIME) && !StrEqual(time, "0")) {
			new Handle:punishmentInfoPack = CreateDataPack();
			WritePackString(punishmentInfoPack, type);
			WritePackCell(punishmentInfoPack, target_list[i]);
			WritePackString(punishmentInfoPack, setBy);
			WritePackCell(punishmentInfoPack, timestamp);
			ResetPack(punishmentInfoPack); // Move index back to beginning so we can read from it.
			punishmentRemovalTimers[target_list[i]] = CreateTimer(StringToFloat(time) * 60, PunishmentExpire, punishmentInfoPack);
		}
	}

	ReplyToCommand(client, "[SM] Punish %s with %s for %s minutes because %s", target, type, time, reason);
	return Plugin_Handled;
}

public RecordPunishmentInDB(
	String:type[],
	String:punisherAuth[],
	String:punisherName[],
	String:punishedAuth[],
	String:punishedName[],
	String:punishedIP[],
	startTime,
	length,
	String:reason[]
) {
	// Unfortunately you can't do threaded queries for prepared statements - this is https://bugs.alliedmods.net/show_bug.cgi?id=3519
	decl String:unformattedQuery[300] = "INSERT INTO sourcepunish_punishments\
(Punish_Time, Punish_Server_ID, Punish_Player_Name, Punish_Player_ID, Punish_Player_IP, Punish_Type, Punish_Length, Punish_Reason, Punish_Admin_Name, Punish_Admin_ID)\
VALUES (%i, %i, \"%s\", \"%s\", \"%s\", \"%s\", %i, \"%s\", \"%s\", \"%s\");";
	//TODO: deal with Punish_Auth_Type, Punish_All_Servers, Punish_All_Mods
	decl String:escapedType[129], String:escapedPunisherAuth[511], String:escapedPunisherName[511], String:escapedPunishedAuth[511], String:escapedPunishedName[511], String:escapedReason[511];
	SQL_EscapeString(db, type, escapedType, sizeof(escapedType));
	SQL_EscapeString(db, punisherAuth, escapedPunisherAuth, sizeof(escapedPunisherAuth));
	SQL_EscapeString(db, punisherName, escapedPunisherName, sizeof(escapedPunisherName));
	SQL_EscapeString(db, punishedAuth, escapedPunishedAuth, sizeof(escapedPunishedAuth));
	SQL_EscapeString(db, punishedName, escapedPunishedName, sizeof(escapedPunishedName));
	SQL_EscapeString(db, reason, escapedReason, sizeof(escapedReason));

	decl String:query[1024];
	Format(query, sizeof(query), unformattedQuery, startTime, serverID, escapedPunishedName, escapedPunishedAuth, punishedIP, escapedType, length, escapedReason, escapedPunisherName, escapedPunisherAuth);

	SQL_TQuery(db, PunishmentRecorded, query);
}

public PunishmentRecorded(Handle:owner, Handle:hndl, const String:error[], any:data) {
	if (hndl == INVALID_HANDLE) {
		ThrowError("Error while recording punishment: %s", error);
	}
}

public OnClientDisconnect(client) {
	if (punishmentRemovalTimers[client] != INVALID_HANDLE) {
		KillTimer(punishmentRemovalTimers[client]);
		punishmentRemovalTimers[client] = INVALID_HANDLE;
	}
}

public Action:PunishmentExpire(Handle:timer, Handle:punishmentInfoPack) {
	decl String:type[64];
	ReadPackString(punishmentInfoPack, type, sizeof(type));
	new targetClient = ReadPackCell(punishmentInfoPack);
	decl String:setBy[64];
	ReadPackString(punishmentInfoPack, setBy, sizeof(setBy));
	new setTimestamp = ReadPackCell(punishmentInfoPack);

	decl pmethod[punishmentType];
	if (!GetTrieArray(punishments, type, pmethod, sizeof(pmethod))) {
		decl String:targetClientName[64];
		GetClientName(targetClient, targetClientName, sizeof(targetClientName));
		PrintToServer("[SM] Punishment type %s not found when trying to end expired punishment for %s", type, targetClientName);
	}

	decl String:setReadableTime[64];
	FormatTime(setReadableTime, sizeof(setReadableTime), "%F at %R (UTC)", setTimestamp); // E.g. "2013-08-03 at 00:12 (UTC)"

	PrintToChat(targetClient, "[SM] Punishment of type %s set by %s on %s expired", type, setBy, setReadableTime);

	Call_StartForward(pmethod[removeCallback]);
	Call_PushCell(targetClient);
	decl result;
	Call_Finish(result);
}

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max) {
   CreateNative("RegisterPunishment", Native_RegisterPunishment);
   return APLRes_Success;
}

public Native_RegisterPunishment(Handle:plugin, numParams) {
	decl String:type[64];
	GetNativeString(1, type, sizeof(type));

	decl String:typeDisplayName[64];
	GetNativeString(2, typeDisplayName, sizeof(typeDisplayName));

	decl pmethod[punishmentType];
	strcopy(pmethod[name], sizeof(pmethod[name]), type);
	strcopy(pmethod[displayName], sizeof(pmethod[displayName]), typeDisplayName);

	new Handle:af = CreateForward(ET_Event, Param_Cell, Param_String);
	AddToForward(af, plugin, GetNativeCell(3));
	pmethod[addCallback] = af;

	new Handle:rf = CreateForward(ET_Event, Param_Cell, Param_String);
	AddToForward(rf, plugin, GetNativeCell(4));
	pmethod[removeCallback] = rf;

	pmethod[flags] = GetNativeCell(5);

	SetTrieArray(punishments, type, pmethod, sizeof(pmethod));

	return true;
}
