//TODO: Menu

//TODO: Internationalisation/localisation
//TODO: Decide what to do with Punish_Auth_Type
//TODO: Punish_All_Servers - need some way to set this without SQL access
//TODO: Punish_All_Mods - SQL queries need to check this and needs to be changeable without SQL access
//TODO: Determine how web panel is going to communicate with this plugin.
//TODO: Add a README and licensing information

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
new Handle:punishmentTypes = INVALID_HANDLE;
new Handle:punishmentRemovalTimers[MAXPLAYERS + 1];
new Handle:db = INVALID_HANDLE;
new Handle:configKeyValues = INVALID_HANDLE;
new serverID;

public OnPluginStart() {
	decl String:error[64];
	db = SQL_Connect("default", true, error, sizeof(error));
	if (db == INVALID_HANDLE) {
		SetFailState("Failed to connect to database: %s", error);
	}

	new String:keyValueFile[128];
	BuildPath(Path_SM, keyValueFile, sizeof(keyValueFile), "configs/sourcepunish.cfg");
	if (!FileExists(keyValueFile)) {
		SetFailState("configs/sourcepunish.cfg does not exist!");
	}
	configKeyValues = CreateKeyValues("SourcePunish");
	FileToKeyValues(configKeyValues, keyValueFile);

	if (!KvJumpToKey(configKeyValues, "Settings")) {
		SetFailState("Settings key in config does not exist!");
	}

	serverID = KvGetNum(configKeyValues, "ServerID", 0);
	if (serverID < 1) {
		SetFailState("Server ID in config is invalid! Should be at least 1");
	}

	punishments = CreateTrie();
	punishmentTypes = CreateArray();
	LoadTranslations("common.phrases");
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
		decl String:type[64], String:punisherName[64], String:punishedAuth[64], String:reason[64];
		SQL_FetchString(query, 0, type, sizeof(type));
		SQL_FetchString(query, 1, punisherName, sizeof(punisherName));
		SQL_FetchString(query, 2, punishedAuth, sizeof(punishedAuth));
		SQL_FetchString(query, 3, reason, sizeof(reason));
		new startTime = SQL_FetchInt(query, 4);

		for (new i = 1; i <= MaxClients; i++) {
			decl String:auth[64];
			strcopy(auth, sizeof(auth), clientAuths[i]);
			if (StrEqual(punishedAuth, auth)) {
				decl pmethod[punishmentType];
				if (!GetTrieArray(punishments, type, pmethod, sizeof(pmethod))) {
					PrintToServer("Loaded an active punishment with unknown type %s", type);
				}

				Call_StartForward(pmethod[addCallback]);
				Call_PushCell(i);
				Call_PushString(reason);
				Call_Finish();

				if (!(pmethod[flags] & SP_NOREMOVE) && !(pmethod[flags] & SP_NOTIME)) {
					new Handle:punishmentInfoPack = CreateDataPack();
					WritePackString(punishmentInfoPack, type);
					WritePackCell(punishmentInfoPack, i);
					WritePackString(punishmentInfoPack, punisherName);
					WritePackCell(punishmentInfoPack, startTime);
					ResetPack(punishmentInfoPack); // Move index back to beginning so we can read from it.
					new endTime = startTime + (SQL_FetchInt(query, 5) * 60);
					new Handle:timer = CreateTimer(float(endTime - GetTime()), PunishmentExpire, punishmentInfoPack);
					if (punishmentRemovalTimers[i] == INVALID_HANDLE) {
						punishmentRemovalTimers[i] = CreateTrie();
					}
					SetTrieValue(punishmentRemovalTimers[i], type, timer);
				}
				break;
			}
		}
	}
}

public Action:Command_Punish(client, args) {
	new timestamp = GetTime();
	if (args < 1) {
		ReplyToCommand(client, "[SM] Usage: sm_[add]<type> <target> [time|0] [reason]");
		return Plugin_Handled;
	}

	decl String:command[70], String:prefix[7];
	GetCmdArg(0, command, sizeof(command));
	strcopy(prefix, sizeof(prefix), command); // Get the first 6 characters.
	new typeIndexInCommand = 3; // If the first 6 characters are not "sm_add", the type is after the "sm_" which is 3 characters long.
	if (StrEqual(prefix, "sm_add", false)) {
		typeIndexInCommand = 6; // Otherwise, the type is after "sm_add", which is 6 characters long.
	}

	decl String:type[64], pmethod[punishmentType];
	strcopy(type, sizeof(type), command[typeIndexInCommand]);
	if (!GetTrieArray(punishments, type, pmethod, sizeof(pmethod))) {
		ReplyToCommand(client, "[SM] Punishment type %s not found.", type);
		return Plugin_Handled;
	}

	decl String:target[64], String:time[64], String:fullArgString[64];
	GetCmdArgString(fullArgString, sizeof(fullArgString));
	new pos = BreakString(fullArgString, target, sizeof(target));

	decl String:reason[64];
	new reasonArgumentNum = 2;
	if (!(pmethod[flags] & SP_NOTIME)) {
		reasonArgumentNum = 3;
	}

	if (args >= reasonArgumentNum) {
		if (reasonArgumentNum == 3) {
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

		new Handle:existingTimer = INVALID_HANDLE;
		if (punishmentRemovalTimers[target_list[i]] != INVALID_HANDLE) {
			GetTrieValue(punishmentRemovalTimers[target_list[i]], type, existingTimer);
			if (existingTimer != INVALID_HANDLE) {
				ReplyToCommand(client, "[SM] %s already has a punishment of type %s.", targetName, type);
				return Plugin_Handled;
			}
		}

		GetClientAuthString(target_list[i], targetAuth, sizeof(targetAuth));
		GetClientIP(target_list[i], targetIP, sizeof(targetIP));

		RecordPunishmentInDB(type, setByAuth, setBy, targetAuth, targetName, targetIP, timestamp, StringToInt(time), reason);
		Call_StartForward(pmethod[addCallback]);
		Call_PushCell(target_list[i]);
		Call_PushString(reason);
		Call_Finish();

		if (!(pmethod[flags] & SP_NOREMOVE) && !(pmethod[flags] & SP_NOTIME) && !StrEqual(time, "0")) {
			new Handle:punishmentInfoPack = CreateDataPack();
			WritePackString(punishmentInfoPack, type);
			WritePackCell(punishmentInfoPack, target_list[i]);
			WritePackString(punishmentInfoPack, setBy);
			WritePackCell(punishmentInfoPack, timestamp);
			ResetPack(punishmentInfoPack); // Move index back to beginning so we can read from it.
			new Handle:timer = CreateTimer(StringToFloat(time) * 60, PunishmentExpire, punishmentInfoPack);
			if (punishmentRemovalTimers[target_list[i]] == INVALID_HANDLE) {
				punishmentRemovalTimers[target_list[i]] = CreateTrie();
			}
			SetTrieValue(punishmentRemovalTimers[target_list[i]], type, timer);
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

public Action:Command_UnPunish(client, args) {
	new timestamp = GetTime();
	if (args < 1) {
		ReplyToCommand(client, "[SM] Usage: sm_<un|del><type> <target> [reason]");
		return Plugin_Handled;
	}

	decl String:command[70], String:prefix[7];
	GetCmdArg(0, command, sizeof(command));
	strcopy(prefix, sizeof(prefix), command); // Get the first 6 characters.
	new typeIndexInCommand = 5; // If the first 6 characters are not "sm_del", the type is after the "sm_un" which is 5 characters long.
	if (StrEqual(prefix, "sm_del", false)) {
		typeIndexInCommand = 6; // Otherwise, the type is after "sm_del", which is 6 characters long.
	}

	decl String:type[64], pmethod[punishmentType];
	strcopy(type, sizeof(type), command[typeIndexInCommand]);
	if (!GetTrieArray(punishments, type, pmethod, sizeof(pmethod))) {
		ReplyToCommand(client, "[SM] Punishment type %s not found.", type);
		return Plugin_Handled;
	}

	decl String:target[64], String:fullArgString[64];
	GetCmdArgString(fullArgString, sizeof(fullArgString));
	new pos = BreakString(fullArgString, target, sizeof(target));

	decl String:reason[64];
	new reasonArgumentNum = 2;

	if (args >= reasonArgumentNum) {
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

	decl String:escapedType[64], String:adminName[64], String:adminAuth[64], String:escapedAdminName[64], String:escapedAdminAuth[64];
	SQL_EscapeString(db, type, escapedType, sizeof(escapedType));
	GetClientName(client, adminName, sizeof(adminName));
	SQL_EscapeString(db, adminName, escapedAdminName, sizeof(escapedAdminName));
	GetClientAuthString(client, adminAuth, sizeof(adminAuth));
	SQL_EscapeString(db, adminAuth, escapedAdminAuth, sizeof(escapedAdminAuth));


	for (new i = 0; i < target_count; i++) {
		decl String:targetName[64], String:targetAuth[64], String:targetIP[64];
		GetClientName(target_list[i], targetName, sizeof(targetName));

		new Handle:existingTimer = INVALID_HANDLE;
		if (punishmentRemovalTimers[target_list[i]] == INVALID_HANDLE) {
			ReplyToCommand(client, "[SM] %s has no active punishments.", targetName);
			return Plugin_Handled;
		}
		GetTrieValue(punishmentRemovalTimers[target_list[i]], type, existingTimer);
		if (existingTimer == INVALID_HANDLE) {
			ReplyToCommand(client, "[SM] %s has not been punished with %s...", targetName, type);
			return Plugin_Handled;
		}

		GetClientAuthString(target_list[i], targetAuth, sizeof(targetAuth));
		GetClientIP(target_list[i], targetIP, sizeof(targetIP));

		Call_StartForward(pmethod[removeCallback]);
		Call_PushCell(target_list[i]);
		Call_Finish();

		decl String:query[512], String:escapedTargetAuth[64];
		SQL_EscapeString(db, targetAuth, escapedTargetAuth, sizeof(escapedTargetAuth));
		Format(query, sizeof(query), "UPDATE sourcepunish_punishments SET UnPunish = 1, UnPunish_Admin_Name = '%s', UnPunish_Admin_ID = '%s', UnPunish_Time = %i, UnPunish_Reason = '%s' WHERE UnPunish = 0 AND (Punish_Server_ID = %i || Punish_All_Servers = 1) AND Punish_Player_ID = '%s' AND Punish_Type = '%s' AND (Punish_Time + (Punish_Length * 60)) > UNIX_TIMESTAMP(NOW());", escapedAdminName, escapedAdminAuth, timestamp, reason, serverID, escapedTargetAuth, escapedType);

		new Handle:punishmentRemovalInfoPack = CreateDataPack();
		WritePackCell(punishmentRemovalInfoPack, client);
		WritePackCell(punishmentRemovalInfoPack, target_list[i]);
		WritePackString(punishmentRemovalInfoPack, type);
		WritePackString(punishmentRemovalInfoPack, adminName);
		WritePackString(punishmentRemovalInfoPack, targetName);
		ResetPack(punishmentRemovalInfoPack); // Move index back to beginning so we can read from it.

		SQL_TQuery(db, UnpunishedUser, query, punishmentRemovalInfoPack);

		new Handle:timer = INVALID_HANDLE;
		GetTrieValue(punishmentRemovalTimers[target_list[i]], type, timer);
		KillTimer(timer);
		SetTrieValue(punishmentRemovalTimers[target_list[i]], type, INVALID_HANDLE);
	}
	return Plugin_Handled;
}

public UnpunishedUser(Handle:owner, Handle:query, const String:error[], any:punishmentRemovalInfoPack) {
	new adminClient = ReadPackCell(punishmentRemovalInfoPack);

	if (query == INVALID_HANDLE) {
		ThrowError("Error querying DB: %s", error);
		PrintToChat(adminClient, "[SM] Error while unpunishing user.");
	} else {
		decl String:type[64], String:adminName[64], String:targetName[64];

		new targetClient = ReadPackCell(punishmentRemovalInfoPack);
		ReadPackString(punishmentRemovalInfoPack, type, sizeof(type));
		ReadPackString(punishmentRemovalInfoPack, adminName, sizeof(adminName));
		ReadPackString(punishmentRemovalInfoPack, targetName, sizeof(targetName));

		PrintToChat(adminClient, "[SM] Removed %s punishment from %s.", type, targetName);
		PrintToChat(targetClient, "[SM] Your %s punishment has been removed by %s.", type, adminName);
	}
}

public OnClientDisconnect(client) {
	if (punishmentRemovalTimers[client] != INVALID_HANDLE) {
		for (new i = 0; i < GetArraySize(punishmentTypes); i++) {
			// Check each punishment type applied to this user.
			decl String:punishmentName[64];
			GetArrayString(punishmentTypes, i, punishmentName, sizeof(punishmentName)); // Get punishment type name
			new Handle:timer = INVALID_HANDLE;
			GetTrieValue(punishmentRemovalTimers[client], punishmentName, timer); // Get the timer for this player and punishment type
			if (timer != INVALID_HANDLE) {
				KillTimer(timer);
			}
		}
		punishmentRemovalTimers[client] = INVALID_HANDLE;
	}
}

public OnClientAuthorized(client, const String:auth[]) {
	decl String:escapedAuth[64], String:query[512];
	SQL_EscapeString(db, auth, escapedAuth, sizeof(escapedAuth));
	Format(query, sizeof(query), "SELECT Punish_Type, Punish_Admin_Name, Punish_Reason, Punish_Time, Punish_Length FROM sourcepunish_punishments WHERE Punish_Player_ID = '%s' AND UnPunish = 0 AND (Punish_Server_ID = %i OR Punish_All_Servers = 1) AND (Punish_Time + (Punish_Length * 60)) > UNIX_TIMESTAMP(NOW());", escapedAuth, serverID);
	SQL_TQuery(db, UsersActivePunishmentsLookupComplete, query, client);
}

public UsersActivePunishmentsLookupComplete(Handle:owner, Handle:query, const String:error[], any:client) {
	if (query == INVALID_HANDLE) {
		ThrowError("Error querying DB: %s", error);
	}

	while (SQL_FetchRow(query)) {
		decl String:type[64], String:punisherName[64], String:reason[64];
		SQL_FetchString(query, 0, type, sizeof(type));
		SQL_FetchString(query, 2, reason, sizeof(reason));

		decl pmethod[punishmentType];
		if (!GetTrieArray(punishments, type, pmethod, sizeof(pmethod))) {
			PrintToServer("Loaded an active punishment with unknown type %s", type);
		}

		Call_StartForward(pmethod[addCallback]);
		Call_PushCell(client);
		Call_PushString(reason);
		Call_Finish();

		if (!(pmethod[flags] & SP_NOREMOVE) && !(pmethod[flags] & SP_NOTIME)) {
			SQL_FetchString(query, 1, punisherName, sizeof(punisherName));
			new startTime = SQL_FetchInt(query, 3);
			new Handle:punishmentInfoPack = CreateDataPack();
			WritePackString(punishmentInfoPack, type);
			WritePackCell(punishmentInfoPack, client);
			WritePackString(punishmentInfoPack, punisherName);
			WritePackCell(punishmentInfoPack, startTime);
			ResetPack(punishmentInfoPack); // Move index back to beginning so we can read from it.
			new endTime = startTime + (SQL_FetchInt(query, 4) * 60);
			new Handle:timer = CreateTimer(float(endTime - GetTime()), PunishmentExpire, punishmentInfoPack);
			if (punishmentRemovalTimers[client] == INVALID_HANDLE) {
				punishmentRemovalTimers[client] = CreateArray();
			}
			PushArrayCell(punishmentRemovalTimers[client], timer);
		}
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

	RemoveFromArray(punishmentRemovalTimers[targetClient], FindValueInArray(punishmentRemovalTimers[targetClient], timer)); // This timer is done, no need to try to make it more dead later.
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
	PushArrayString(punishmentTypes, type);

	decl String:mainAddCommand[67] = "sm_",
		 String:mainRemoveCommand[69] = "sm_un",
		 String:addCommandDescription[89] = "Punishes a player with a ",
		 String:removeCommandDescription[103] = "Removes punishment from player of type ";
	StrCat(mainAddCommand, sizeof(mainAddCommand), type);
	StrCat(addCommandDescription, sizeof(addCommandDescription), typeDisplayName);
	RegAdminCmd(mainAddCommand, Command_Punish, ADMFLAG_GENERIC, addCommandDescription);

	StrCat(mainRemoveCommand, sizeof(mainRemoveCommand), type);
	StrCat(removeCommandDescription, sizeof(removeCommandDescription), typeDisplayName);
	RegAdminCmd(mainRemoveCommand, Command_UnPunish, ADMFLAG_GENERIC, removeCommandDescription);

	if (!(pmethod[flags] & SP_NOTIME)) {
		decl String:addCommand[70] = "sm_add", String:removeCommand[70] = "sm_del";
		StrCat(addCommand, sizeof(addCommand), type);
		RegAdminCmd(addCommand, Command_Punish, ADMFLAG_GENERIC, addCommandDescription);

		StrCat(removeCommand, sizeof(removeCommand), type);
		RegAdminCmd(removeCommand, Command_UnPunish, ADMFLAG_GENERIC, removeCommandDescription);
	}

	decl String:query[512];
	Format(query, sizeof(query), "SELECT Punish_Type, Punish_Admin_Name, Punish_Player_ID, Punish_Reason, Punish_Time, Punish_Length FROM sourcepunish_punishments WHERE Punish_Type = '%s' AND UnPunish = 0 AND (Punish_Server_ID = %i OR Punish_All_Servers = 1) AND (Punish_Time + (Punish_Length * 60)) > UNIX_TIMESTAMP(NOW());", type, serverID);
	SQL_TQuery(db, ActivePunishmentsLookupComplete, query);

	return true;
}
