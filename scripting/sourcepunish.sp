/*
 * Copyright (C) 2013 Alexander Monk, Alfie Day, Rob Warner.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
 * http://www.gnu.org/copyleft/gpl.html
 */

//TODO: Internationalisation/localisation
//TODO: Decide what to do with Punish_Auth_Type
//TODO: Punish_All_Servers - need some way to set this without SQL access
//TODO: Punish_All_Mods - SQL queries need to check this and needs to be changeable without SQL access
//TODO: Determine how web panel is going to communicate with this plugin.

#include <sourcemod>
#include <sourcepunish>

#undef REQUIRE_PLUGIN
#include <adminmenu>

public Plugin:myinfo = {
	name = "SourcePunish",
	author = "Alex, Azelphur and MonsterKiller",
	description = "Punishment management system",
	version = "0.06",
	url = "https://github.com/Krenair/SourcePunish"
}

enum punishmentType {
	Handle:addCallback,
	Handle:removeCallback,
	String:name[64], // Eg, "ban" or "spray", database safe name
	String:displayName[64], // Eg, "Ban" or "Spray", display name for menus, etc.
	flags,
}

enum adminMenuStatus {
	bool:adding,
	String:punishmentTypeStr[64],
}

new Handle:punishments = INVALID_HANDLE;
new Handle:punishmentTypes = INVALID_HANDLE;
new Handle:punishmentRemovalTimers[MAXPLAYERS + 1];
new Handle:db = INVALID_HANDLE;
new Handle:adminMenu = INVALID_HANDLE;
new Handle:adminMenuPunishmentItemsToAdd = INVALID_HANDLE;
new Handle:adminMenuPunishmentItems = INVALID_HANDLE;
new bool:adminMenuClientStatusAdding[MAXPLAYERS + 1];
new String:adminMenuClientStatusType[MAXPLAYERS + 1][64];
new adminMenuClientStatusTarget[MAXPLAYERS + 1];
new adminMenuClientStatusDuration[MAXPLAYERS + 1];
new adminMenuClientStatusInDurationMenu[MAXPLAYERS + 1];
new adminMenuClientStatusInReasonMenu[MAXPLAYERS + 1];
new serverID;
new configSection = 0;
new Handle:defaultReasons = INVALID_HANDLE;
new Handle:defaultTimes = INVALID_HANDLE;
new Handle:defaultTimeKeys = INVALID_HANDLE;

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

	defaultReasons = CreateArray(100);
	defaultTimes = CreateTrie();
	defaultTimeKeys = CreateArray(16);

	new Handle:smc = SMC_CreateParser();
	SMC_SetReaders(smc, SMC_NewSection, SMC_KeyValue, SMC_EndSection);
	SMC_ParseFile(smc, keyValueFile);

	if (serverID < 1) {
		SetFailState("Server ID in config is invalid! Should be at least 1");
	}

	// If the admin menu is already ready, run the hook manually.
	if (LibraryExists("adminmenu") && ((adminMenu = GetAdminTopMenu()) != INVALID_HANDLE)) {
		OnAdminMenuReady(adminMenu);
	}

	punishments = CreateTrie();
	punishmentTypes = CreateArray(64);
	adminMenuPunishmentItemsToAdd = CreateArray();
	adminMenuPunishmentItems = CreateTrie();
	LoadTranslations("common.phrases");

	AddCommandListener(Command_Say, "say");
	AddCommandListener(Command_Say, "say2");
	AddCommandListener(Command_Say, "say_team");
}

public SMCResult:SMC_KeyValue(Handle:smc, const String:key[], const String:value[], bool:key_quotes, bool:value_quotes) {
	switch (configSection) {
		case 0: {
			if (StrEqual(key, "ServerID")) {
				serverID = StringToInt(value);
			}
		}
		case 1: {
			PushArrayString(defaultReasons, value);
		}
		case 2: {
			PushArrayString(defaultTimeKeys, key);
			SetTrieString(defaultTimes, key, value);
		}
	}
	return SMCParse_Continue;
}

public SMCResult:SMC_NewSection(Handle:smc, const String:sectionName[], bool:opt_quotes) {
	configSection = 0;
	if (StrEqual(sectionName, "DefaultReasons", false)) {
		configSection = 1;
	} else if (StrEqual(sectionName, "DefaultTimes", false)) {
		configSection = 2;
	}
	return SMCParse_Continue;
}

public SMCResult:SMC_EndSection(Handle:smc) {
	configSection = 0;
	return SMCParse_Continue;
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
	if (client) {
		GetClientName(client, setBy, sizeof(setBy));
		GetClientAuthString(client, setByAuth, sizeof(setByAuth));
	} else {
		strcopy(setBy, sizeof(setBy), "Console");
		strcopy(setByAuth, sizeof(setByAuth), "Console");
	}

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
		ReplyToCommand(client, "[SM] Punished %s with %s for %s minutes because %s", target, type, time, reason);
		PrintToChat(target_list[i], "[SM] %s has punished you with %s for %s minutes with reason: %s", setBy, pmethod[name], time, reason);
	}
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

	decl String:escapedType[64], String:query[512];
	SQL_EscapeString(db, type, escapedType, sizeof(escapedType));
	Format(query, sizeof(query), "SELECT Punish_Player_ID FROM sourcepunish_punishments WHERE UnPunish = 0 AND (Punish_Server_ID = %i OR Punish_All_Servers = 1) AND (Punish_Time + (Punish_Length * 60)) > UNIX_TIMESTAMP(NOW()) AND Punish_Type = '%s';", serverID, escapedType);
	new Handle:commandInfoPack = CreateDataPack();
	WritePackCell(commandInfoPack, client);
	WritePackString(commandInfoPack, target);
	WritePackString(commandInfoPack, type);
	WritePackCell(commandInfoPack, timestamp);
	WritePackString(commandInfoPack, reason);
	WritePackCell(commandInfoPack, target_count);
	// Can't send arrays through a DataPack... Put everything in an adt_array instead
	new Handle:targetListADT = CreateArray();
	for (new i = 0; i < target_count; i++) {
		PushArrayCell(targetListADT, target_list[i]);
	}
	WritePackCell(commandInfoPack, _:targetListADT);
	ResetPack(commandInfoPack);
	SQL_TQuery(db, ProcessUnpunishCommand, query, commandInfoPack);
	return Plugin_Handled;
}

public ProcessUnpunishCommand(Handle:owner, Handle:query, const String:error[], any:commandInfoPack) {
	new client = ReadPackCell(commandInfoPack);
	if (query == INVALID_HANDLE) {
		PrintToServer("Error while checking existence of punishment for removal: %s", error);
		PrintToChat(client, "DB error while checking existence of punishment for removal.");
		return;
	}
	new Handle:authsWithPunishmentType = CreateArray(64);
	while (SQL_FetchRow(query)) {
		decl String:auth[64];
		SQL_FetchString(query, 0, auth, sizeof(auth));
		PushArrayString(authsWithPunishmentType, auth);
	}

	decl String:target[64], String:type[64], pmethod[punishmentType], String:reason[64];
	ReadPackString(commandInfoPack, target, sizeof(target));
	ReadPackString(commandInfoPack, type, sizeof(type));
	GetTrieArray(punishments, type, pmethod, sizeof(pmethod));
	new timestamp = ReadPackCell(commandInfoPack);
	ReadPackString(commandInfoPack, reason, sizeof(reason));
	new target_count = ReadPackCell(commandInfoPack);
	new Handle:targetListADT = Handle:ReadPackCell(commandInfoPack);

	decl String:escapedType[64], String:adminName[64], String:adminAuth[64], String:escapedAdminName[64], String:escapedAdminAuth[64];
	SQL_EscapeString(db, pmethod[name], escapedType, sizeof(escapedType));
	if (client) {
		GetClientName(client, adminName, sizeof(adminName));
		GetClientAuthString(client, adminAuth, sizeof(adminAuth));
		SQL_EscapeString(db, adminName, escapedAdminName, sizeof(escapedAdminName));
		SQL_EscapeString(db, adminAuth, escapedAdminAuth, sizeof(escapedAdminAuth));
	} else {
		strcopy(adminName, sizeof(adminName), "Console");
		strcopy(adminAuth, sizeof(adminAuth), "Console");
	}

	for (new i = 0; i < target_count; i++) {
		new targetClientID = GetArrayCell(targetListADT, i);
		decl String:targetName[64], String:targetAuth[64], String:targetIP[64];
		GetClientName(targetClientID, targetName, sizeof(targetName));
		GetClientAuthString(targetClientID, targetAuth, sizeof(targetAuth));
		GetClientIP(targetClientID, targetIP, sizeof(targetIP));

		new bool:found = false;
		for (new j = 0; j < GetArraySize(authsWithPunishmentType); j++) {
			decl String:checkAuth[64];
			GetArrayString(authsWithPunishmentType, j, checkAuth, sizeof(checkAuth));
			if (StrEqual(targetAuth, checkAuth)) {
				found = true;
				break;
			}
		}
		if (!found) {
			if (client) {
				PrintToChat(client, "[SM] %s has not been punished with %s...", targetName, pmethod[name]);
			} else {
				PrintToServer("[SM] %s has not been punished with %s...", targetName, pmethod[name]);
			}
			continue;
		}

		Call_StartForward(pmethod[removeCallback]);
		Call_PushCell(targetClientID);
		Call_Finish();

		decl String:updateQuery[512], String:escapedTargetAuth[64];
		SQL_EscapeString(db, targetAuth, escapedTargetAuth, sizeof(escapedTargetAuth));
		Format(updateQuery, sizeof(updateQuery), "UPDATE sourcepunish_punishments SET UnPunish = 1, UnPunish_Admin_Name = '%s', UnPunish_Admin_ID = '%s', UnPunish_Time = %i, UnPunish_Reason = '%s' WHERE UnPunish = 0 AND (Punish_Server_ID = %i || Punish_All_Servers = 1) AND Punish_Player_ID = '%s' AND Punish_Type = '%s' AND (Punish_Time + (Punish_Length * 60)) > UNIX_TIMESTAMP(NOW());", escapedAdminName, escapedAdminAuth, timestamp, reason, serverID, escapedTargetAuth, escapedType);

		new Handle:punishmentRemovalInfoPack = CreateDataPack();
		WritePackCell(punishmentRemovalInfoPack, client);
		WritePackCell(punishmentRemovalInfoPack, targetClientID);
		WritePackString(punishmentRemovalInfoPack, pmethod[name]);
		WritePackString(punishmentRemovalInfoPack, adminName);
		WritePackString(punishmentRemovalInfoPack, targetName);
		ResetPack(punishmentRemovalInfoPack); // Move index back to beginning so we can read from it.

		SQL_TQuery(db, UnpunishedUser, updateQuery, punishmentRemovalInfoPack);

		new Handle:timer = INVALID_HANDLE;
		GetTrieValue(punishmentRemovalTimers[targetClientID], pmethod[name], timer);
		KillTimer(timer);
		SetTrieValue(punishmentRemovalTimers[targetClientID], pmethod[name], INVALID_HANDLE);
	}
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

		if (adminClient) {
			PrintToChat(adminClient, "[SM] Removed %s punishment from %s.", type, targetName);
		} else {
			PrintToServer("[SM] Removed %s punishment from %s.", type, targetName);
		}
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
				punishmentRemovalTimers[client] = CreateTrie();
			}
			SetTrieValue(punishmentRemovalTimers[client], type, timer);
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

	RemoveFromTrie(punishmentRemovalTimers[targetClient], type); // This timer is done, no need to try to make it more dead later.
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

	if (adminMenu == INVALID_HANDLE) {
		new Handle:itemInfoPack = CreateDataPack();
		WritePackString(itemInfoPack, type);
		WritePackString(itemInfoPack, mainAddCommand);
		WritePackString(itemInfoPack, mainRemoveCommand);
		ResetPack(itemInfoPack); // Move index back to beginning so we can read from it.
		PushArrayCell(adminMenuPunishmentItemsToAdd, itemInfoPack);
	} else {
		AddPunishmentMenuItems(pmethod, mainAddCommand, mainRemoveCommand);
	}

	decl String:query[512];
	Format(query, sizeof(query), "SELECT Punish_Type, Punish_Admin_Name, Punish_Player_ID, Punish_Reason, Punish_Time, Punish_Length FROM sourcepunish_punishments WHERE Punish_Type = '%s' AND UnPunish = 0 AND (Punish_Server_ID = %i OR Punish_All_Servers = 1) AND (Punish_Time + (Punish_Length * 60)) > UNIX_TIMESTAMP(NOW());", type, serverID);
	SQL_TQuery(db, ActivePunishmentsLookupComplete, query);

	return true;
}

public OnLibraryRemoved(const String:libraryName[]) {
	if (StrEqual(libraryName, "adminmenu")) {
		adminMenu = INVALID_HANDLE;
	}
}

AddPunishmentMenuItems(pmethod[punishmentType], String:mainAddCommand[], String:mainRemoveCommand[]) {
	new TopMenuObject:playerCommands = FindTopMenuCategory(adminMenu, ADMINMENU_PLAYERCOMMANDS);
	decl String:addObjectName[76], String:removeObjectName[78];

	Format(addObjectName, sizeof(addObjectName), "%s_menuitem", mainAddCommand[3]);
	SetTrieArray(adminMenuPunishmentItems, addObjectName, pmethod, sizeof(pmethod), true);
	AddToTopMenu(adminMenu, addObjectName, TopMenuObject_Item, AdminMenu_AddPunishment, playerCommands, mainAddCommand, ADMFLAG_GENERIC);

	if (!(pmethod[flags] & SP_NOREMOVE)) {
		Format(removeObjectName, sizeof(removeObjectName), "%s_menuitem", mainRemoveCommand[3]);
		SetTrieArray(adminMenuPunishmentItems, removeObjectName, pmethod, sizeof(pmethod), true);
		AddToTopMenu(adminMenu, removeObjectName, TopMenuObject_Item, AdminMenu_RemovePunishment, playerCommands, mainAddCommand, ADMFLAG_GENERIC);
	}
}

public OnAdminMenuReady(Handle:topMenu) {
	adminMenu = topMenu;
	if (adminMenuPunishmentItemsToAdd == INVALID_HANDLE) {
		return;
	}
	for (new i = 0; i < GetArraySize(adminMenuPunishmentItemsToAdd); i++) {
		new Handle:itemInfoPack = GetArrayCell(adminMenuPunishmentItemsToAdd, i);

		decl pmethod[punishmentType], String:type[64], String:mainAddCommand[67], String:mainRemoveCommand[69];
		ReadPackString(itemInfoPack, type, sizeof(type));
		ReadPackString(itemInfoPack, mainAddCommand, sizeof(mainAddCommand));
		ReadPackString(itemInfoPack, mainRemoveCommand, sizeof(mainRemoveCommand));
		ResetPack(itemInfoPack); // Move index back to beginning so we can read from it.
		GetTrieArray(punishments, type, pmethod, sizeof(pmethod));

		AddPunishmentMenuItems(pmethod, mainAddCommand, mainRemoveCommand);
	}
}

IdentifyPunishmentTypeFromMenuObjectID(pmethod[punishmentType], TopMenuObject:objectID) {
	decl String:objName[64];
	GetTopMenuObjName(adminMenu, objectID, objName, sizeof(objName));
	GetTrieArray(adminMenuPunishmentItems, objName, pmethod, sizeof(pmethod));
}

GetDisplayTextForTypeAndAction(String:type[], bool:addingPunishment, String:buffer[], maxlen) {
	if (addingPunishment) {
		Format(buffer, maxlen, "%s", type);
	} else {
		decl String:typeCopy[64];
		strcopy(typeCopy, sizeof(typeCopy), type);
		typeCopy[0] = CharToLower(typeCopy[0]);
		Format(buffer, maxlen, "Un%s", typeCopy);
	}
}

public AdminMenu_AddPunishment(Handle:topMenu, TopMenuAction:action, TopMenuObject:objectID, client, String:buffer[], maxlength) {
	decl String:typeDisplayText[100], pmethod[punishmentType];
	IdentifyPunishmentTypeFromMenuObjectID(pmethod, objectID);
	GetDisplayTextForTypeAndAction(pmethod[displayName], true, typeDisplayText, sizeof(typeDisplayText));
	AdminMenu_PunishmentProcessAction(action, client, buffer, maxlength, typeDisplayText, pmethod, true);
}

public AdminMenu_RemovePunishment(Handle:topMenu, TopMenuAction:action, TopMenuObject:objectID, client, String:buffer[], maxlength) {
	decl String:typeDisplayText[100], pmethod[punishmentType];
	IdentifyPunishmentTypeFromMenuObjectID(pmethod, objectID);
	GetDisplayTextForTypeAndAction(pmethod[displayName], false, typeDisplayText, sizeof(typeDisplayText));
	AdminMenu_PunishmentProcessAction(action, client, buffer, maxlength, typeDisplayText, pmethod, false);
}

AdminMenu_PunishmentProcessAction(TopMenuAction:action, client, String:buffer[], maxlength, String:typeDisplayText[], pmethod[punishmentType], bool:addingPunishment){
	if (action == TopMenuAction_DisplayOption) {
		Format(buffer, maxlength, "[SP] %s player", typeDisplayText);
	} else if (action == TopMenuAction_SelectOption) {
		adminMenuClientStatusAdding[client] = addingPunishment;
		strcopy(adminMenuClientStatusType[client], sizeof(adminMenuClientStatusType[]), pmethod[name]);
		decl String:title[100];
		Format(title, sizeof(title), "%s player", typeDisplayText);

		new Handle:menu = CreateMenu(MenuHandler_Target);
		SetMenuTitle(menu, title);
		SetMenuExitBackButton(menu, true);
		if (addingPunishment) {
			AddTargetsToMenu(menu, 0, false, false);
			DisplayMenu(menu, client, MENU_TIME_FOREVER);
		} else {
			decl String:query[512];
			new Handle:menuSelectDataPack = CreateDataPack();
			WritePackCell(menuSelectDataPack, client);
			WritePackCell(menuSelectDataPack, _:menu);
			ResetPack(menuSelectDataPack);
			Format(query, sizeof(query), "SELECT DISTINCT Punish_Player_ID FROM sourcepunish_punishments WHERE Punish_Type = '%s' AND UnPunish = 0 AND (Punish_Server_ID = %i OR Punish_All_Servers = 1) AND ((Punish_Time + (Punish_Length * 60)) > UNIX_TIMESTAMP(NOW()) || Punish_Length = 0);", pmethod[name], serverID);
			SQL_TQuery(db, FoundPlayersWithActivePunishment, query, menuSelectDataPack);
		}
	}
}

public FoundPlayersWithActivePunishment(Handle:owner, Handle:query, const String:error[], any:menuSelectDataPack) {
	new client = ReadPackCell(menuSelectDataPack);
	new Handle:menu = Handle:ReadPackCell(menuSelectDataPack);
	if (query == INVALID_HANDLE) {
		ThrowError("Error querying DB: %s", error);
	}
	new Handle:clientAuths = CreateTrie();
	for (new i = 1; i <= MaxClients; i++) {
		if (IsClientConnected(i)) {
			decl String:auth[64];
			GetClientAuthString(i, auth, sizeof(auth));
			SetTrieValue(clientAuths, auth, i);
		}
	}

	while (SQL_FetchRow(query)) {
		decl String:targetAuth[64];
		SQL_FetchString(query, 0, targetAuth, sizeof(targetAuth));
		new target;
		new online = GetTrieValue(clientAuths, targetAuth, target);
		if (online) {
			decl String:targetUserId[64], String:targetName[256], String:display[100];
			IntToString(GetClientUserId(target), targetUserId, sizeof(targetUserId));
			GetClientName(target, targetName, sizeof(targetName));
			Format(display, sizeof(display), "%s (%s)", targetName, targetUserId);
			AddMenuItem(menu, targetUserId, display);
		}
	}
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public MenuHandler_Target(Handle:menu, MenuAction:action, client, param) {
	// param is either the way of cancelling or the selected item position
	if (action == MenuAction_End) {
		CloseHandle(menu);
	} else if (action == MenuAction_Cancel) {
		if (param == MenuCancel_ExitBack && adminMenu != INVALID_HANDLE) {
			DisplayTopMenu(adminMenu, client, TopMenuPosition_LastCategory);
		}
	} else if (action == MenuAction_Select) {
		decl String:info[32];
		GetMenuItem(menu, param, info, sizeof(info));
		new targetUserid = StringToInt(info), target = GetClientOfUserId(targetUserid);
		if (target == 0) {
			PrintToChat(client, "[SM] %t", "Player no longer available");
		} else if (!CanUserTarget(client, target)) {
			PrintToChat(client, "[SM] %t", "Unable to target");
		} else {
			adminMenuClientStatusTarget[client] = target;

			decl pmethod[punishmentType];
			GetTrieArray(punishments, adminMenuClientStatusType[client], pmethod, sizeof(pmethod));

			decl String:title[100], String:typeForTitle[64], String:targetName[64];
			GetDisplayTextForTypeAndAction(pmethod[displayName], adminMenuClientStatusAdding[client], typeForTitle, sizeof(typeForTitle));
			GetClientName(target, targetName, sizeof(targetName));

			if (adminMenuClientStatusAdding[client] && !(pmethod[flags] & SP_NOTIME)) {
				// Open duration menu if we're adding AND the punishment type does not have the NOTIME bit set
				Format(title, sizeof(title), "%s %s for: (alternatively type number of minutes in chat box)", typeForTitle, targetName);
				new Handle:durationMenu = CreateMenu(MenuHandler_Duration);
				SetMenuTitle(durationMenu, title);
				SetMenuExitBackButton(durationMenu, true);
				for (new i = 0; i < GetArraySize(defaultTimeKeys); i++) {
					decl String:key[16], String:value[32];
					GetArrayString(defaultTimeKeys, i, key, sizeof(key));
					GetTrieString(defaultTimes, key, value, sizeof(value));
					AddMenuItem(durationMenu, key, value);
				}
				DisplayMenu(durationMenu, client, MENU_TIME_FOREVER);
				adminMenuClientStatusInDurationMenu[client] = true;
			} else {
				// Otherwise, open the reason menu
				Format(title, sizeof(title), "%s %s for: (alternatively type reason in chat box)", typeForTitle, targetName);
				CreateReasonMenu(client, title);
			}
		}
	}
}

DurationSelected(client, durationMinutes) {
	adminMenuClientStatusDuration[client] = durationMinutes;
	adminMenuClientStatusInDurationMenu[client] = false;

	decl pmethod[punishmentType];
	GetTrieArray(punishments, adminMenuClientStatusType[client], pmethod, sizeof(pmethod));

	decl String:title[100], String:typeForTitle[64], String:targetName[64];
	GetDisplayTextForTypeAndAction(pmethod[displayName], adminMenuClientStatusAdding[client], typeForTitle, sizeof(typeForTitle));
	GetClientName(adminMenuClientStatusTarget[client], targetName, sizeof(targetName));
	Format(title, sizeof(title), "%s %s for: (alternatively type reason in chat box)", typeForTitle, targetName);

	CreateReasonMenu(client, title);
}

CreateReasonMenu(client, String:title[]) {
	new Handle:reasonMenu = CreateMenu(MenuHandler_Reason);
	SetMenuTitle(reasonMenu, title);
	SetMenuExitBackButton(reasonMenu, true);

	for (new i = 0; i < GetArraySize(defaultReasons); i++) {
		decl String:defaultReason[100], String:key[8];
		IntToString(i, key, sizeof(key));
		GetArrayString(defaultReasons, i, defaultReason, sizeof(defaultReason));
		AddMenuItem(reasonMenu, key, defaultReason);
	}
	DisplayMenu(reasonMenu, client, MENU_TIME_FOREVER);
	adminMenuClientStatusInReasonMenu[client] = true;
}

ReasonSelected(client, String:reason[]) {
	new timestamp = GetTime();
	adminMenuClientStatusInReasonMenu[client] = false;
	decl pmethod[punishmentType];
	GetTrieArray(punishments, adminMenuClientStatusType[client], pmethod, sizeof(pmethod));

	if (!IsClientConnected(adminMenuClientStatusTarget[client])) {
		PrintToChat(client, "[SM] Target is not connected.");
		return;
	}

	decl String:targetName[64], String:targetAuth[64], String:targetIP[64];
	GetClientName(adminMenuClientStatusTarget[client], targetName, sizeof(targetName));
	if (!CanUserTarget(client, adminMenuClientStatusTarget[client])) {
		PrintToChat(client, "[SM] Can't target %s.", targetName);
		return;
	}

	if (adminMenuClientStatusAdding[client]) {
		decl String:setBy[64], String:setByAuth[64];
		GetClientName(client, setBy, sizeof(setBy));
		GetClientAuthString(client, setByAuth, sizeof(setByAuth));

		new Handle:existingTimer = INVALID_HANDLE;
		if (punishmentRemovalTimers[adminMenuClientStatusTarget[client]] != INVALID_HANDLE) {
			GetTrieValue(punishmentRemovalTimers[adminMenuClientStatusTarget[client]], pmethod[name], existingTimer);
			if (existingTimer != INVALID_HANDLE) {
				PrintToChat(client, "[SM] %s already has a punishment of type %s.", targetName, pmethod[name]);
				return;
			}
		}

		GetClientAuthString(adminMenuClientStatusTarget[client], targetAuth, sizeof(targetAuth));
		GetClientIP(adminMenuClientStatusTarget[client], targetIP, sizeof(targetIP));

		RecordPunishmentInDB(pmethod[name], setByAuth, setBy, targetAuth, targetName, targetIP, timestamp, adminMenuClientStatusDuration[client], reason);
		Call_StartForward(pmethod[addCallback]);
		Call_PushCell(adminMenuClientStatusTarget[client]);
		Call_PushString(reason);
		Call_Finish();

		if (!(pmethod[flags] & SP_NOREMOVE) && !(pmethod[flags] & SP_NOTIME) && adminMenuClientStatusDuration[client] != 0) {
			new Handle:punishmentInfoPack = CreateDataPack();
			WritePackString(punishmentInfoPack, pmethod[name]);
			WritePackCell(punishmentInfoPack, adminMenuClientStatusTarget[client]);
			WritePackString(punishmentInfoPack, setBy);
			WritePackCell(punishmentInfoPack, timestamp);
			ResetPack(punishmentInfoPack); // Move index back to beginning so we can read from it.
			new Handle:timer = CreateTimer(float(adminMenuClientStatusDuration[client] * 60), PunishmentExpire, punishmentInfoPack);
			if (punishmentRemovalTimers[adminMenuClientStatusTarget[client]] == INVALID_HANDLE) {
				punishmentRemovalTimers[adminMenuClientStatusTarget[client]] = CreateTrie();
			}
			SetTrieValue(punishmentRemovalTimers[adminMenuClientStatusTarget[client]], pmethod[name], timer);
		}

		PrintToChat(client, "[SM] Punished %s with %s for %i minutes because %s", targetName, pmethod[name], adminMenuClientStatusDuration[client], reason);
		PrintToChat(adminMenuClientStatusTarget[client], "[SM] %s has punished you with %s for %i minutes with reason: %s", setBy, pmethod[name], adminMenuClientStatusDuration[client], reason);
	} else {
		decl String:escapedType[64], String:adminName[64], String:adminAuth[64], String:escapedAdminName[64], String:escapedAdminAuth[64];
		SQL_EscapeString(db, pmethod[name], escapedType, sizeof(escapedType));
		GetClientName(client, adminName, sizeof(adminName));
		SQL_EscapeString(db, adminName, escapedAdminName, sizeof(escapedAdminName));
		GetClientAuthString(client, adminAuth, sizeof(adminAuth));
		SQL_EscapeString(db, adminAuth, escapedAdminAuth, sizeof(escapedAdminAuth));

		GetClientAuthString(adminMenuClientStatusTarget[client], targetAuth, sizeof(targetAuth));
		GetClientIP(adminMenuClientStatusTarget[client], targetIP, sizeof(targetIP));

		Call_StartForward(pmethod[removeCallback]);
		Call_PushCell(adminMenuClientStatusTarget[client]);
		Call_Finish();

		decl String:query[512], String:escapedTargetAuth[64];
		SQL_EscapeString(db, targetAuth, escapedTargetAuth, sizeof(escapedTargetAuth));
		Format(query, sizeof(query), "UPDATE sourcepunish_punishments SET UnPunish = 1, UnPunish_Admin_Name = '%s', UnPunish_Admin_ID = '%s', UnPunish_Time = %i, UnPunish_Reason = '%s' WHERE UnPunish = 0 AND (Punish_Server_ID = %i || Punish_All_Servers = 1) AND Punish_Player_ID = '%s' AND Punish_Type = '%s' AND ((Punish_Time + (Punish_Length * 60)) > UNIX_TIMESTAMP(NOW()) || Punish_Length = 0);", escapedAdminName, escapedAdminAuth, timestamp, reason, serverID, escapedTargetAuth, escapedType);

		new Handle:punishmentRemovalInfoPack = CreateDataPack();
		WritePackCell(punishmentRemovalInfoPack, client);
		WritePackCell(punishmentRemovalInfoPack, adminMenuClientStatusTarget[client]);
		WritePackString(punishmentRemovalInfoPack, pmethod[name]);
		WritePackString(punishmentRemovalInfoPack, adminName);
		WritePackString(punishmentRemovalInfoPack, targetName);
		ResetPack(punishmentRemovalInfoPack); // Move index back to beginning so we can read from it.

		SQL_TQuery(db, UnpunishedUser, query, punishmentRemovalInfoPack);

		if (punishmentRemovalTimers[adminMenuClientStatusTarget[client]] != INVALID_HANDLE) {
			new Handle:timer = INVALID_HANDLE;
			GetTrieValue(punishmentRemovalTimers[adminMenuClientStatusTarget[client]], pmethod[name], timer);
			if (timer != INVALID_HANDLE) {
				KillTimer(timer);
				SetTrieValue(punishmentRemovalTimers[adminMenuClientStatusTarget[client]], pmethod[name], INVALID_HANDLE);
			}
		}
	}
}

public MenuHandler_Duration(Handle:menu, MenuAction:action, client, param) {
	// param is either the way of cancelling or the selected item position
	if (action == MenuAction_End) {
		CloseHandle(menu);
	} else if (action == MenuAction_Cancel) {
		adminMenuClientStatusInDurationMenu[client] = false;
		if (param == MenuCancel_ExitBack && adminMenu != INVALID_HANDLE) {
			DisplayTopMenu(adminMenu, client, TopMenuPosition_LastCategory);
		}
	} else if (action == MenuAction_Select) {
		decl String:durationMinutesStr[32];
		GetMenuItem(menu, param, durationMinutesStr, sizeof(durationMinutesStr));
		DurationSelected(client, StringToInt(durationMinutesStr));
	}
}

public MenuHandler_Reason(Handle:menu, MenuAction:action, client, param) {
	// param is either the way of cancelling or the selected item position
	if (action == MenuAction_End) {
		CloseHandle(menu);
	} else if (action == MenuAction_Cancel) {
		adminMenuClientStatusInReasonMenu[client] = false;
		if (param == MenuCancel_ExitBack && adminMenu != INVALID_HANDLE) {
			DisplayTopMenu(adminMenu, client, TopMenuPosition_LastCategory);
		}
	} else if (action == MenuAction_Select) {
		decl String:reason[64];
		GetArrayString(defaultReasons, param, reason, sizeof(reason));
		ReasonSelected(client, reason);
	}
}

public Action:Command_Say(client, const String:command[], argc) {
	decl String:text[64];
	GetCmdArg(1, text, sizeof(text));

	if (adminMenuClientStatusInDurationMenu[client]) {
		new durationMinutes = StringToInt(text);
		if (durationMinutes) {
			DurationSelected(client, durationMinutes);
		} else {
			PrintToChat(client, "That's not a valid number of minutes! (%s)", text);
		}
		return Plugin_Handled;
	} else if (adminMenuClientStatusInReasonMenu[client]) {
		CancelClientMenu(client, true);
		ReasonSelected(client, text);
		return Plugin_Handled;
	}
	return Plugin_Continue;
}
