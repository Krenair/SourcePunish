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

//TODO: Sort out conflict between sm_kick from basecommands and sourcepunish_kick
//TODO: Sort out conflict between sm_blockspray from SprayTracker and sourcepunish_blockspray
//TODO: Make sure all punishment type display names show up reasonably on menu (including submenu titles etc.)
//TODO: Skip existence check for SP_NOTIME punishments instead of ignoring error
//TODO: Write blockfortwarsprop plugin
//TODO: Fix blockrename plugin
//TODO: Internationalisation/localisation
//TODO: Decide what to do with Punish_Auth_Type
//TODO: Punish_All_Servers - need some way to set this without SQL access
//TODO: Punish_All_Mods - SQL queries need to check this and needs to be changeable without SQL access
//TODO: Determine how web panel is going to communicate with this plugin.

#include <sourcemod>
#include <sourcepunish>
#include <regex>

#undef REQUIRE_PLUGIN
#include <adminmenu>

public Plugin:myinfo = {
	name = "SourcePunish",
	author = "Alex, Azelphur and MonsterKiller",
	description = "Punishment management system",
	version = "0.2",
	url = "https://github.com/Krenair/SourcePunish"
}

enum punishmentType {
	Handle:addCallback,
	Handle:removeCallback,
	String:name[64], // Eg, "ban" or "spray", database safe name
	String:displayName[64], // Eg, "Ban" or "Spray", display name for menus, etc.
	flags,
	adminflag,
	Handle:pluginHandle,
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
new Handle:steamIDRegex;
new Handle:punishmentRegisteredForward = INVALID_HANDLE;
new Handle:punishmentPluginUnloadedForward = INVALID_HANDLE;

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

	steamIDRegex = CompileRegex("^STEAM_[0-7]:[01]:\\d+$");

	punishments = CreateTrie();
	punishmentTypes = CreateArray(64);
	adminMenuPunishmentItemsToAdd = CreateArray();
	adminMenuPunishmentItems = CreateTrie();
	LoadTranslations("common.phrases");

	AddCommandListener(Command_Say, "say");
	AddCommandListener(Command_Say, "say2");
	AddCommandListener(Command_Say, "say_team");

	punishmentRegisteredForward = CreateGlobalForward("PunishmentRegistered", ET_Ignore, Param_String, Param_String, Param_Cell);
	punishmentPluginUnloadedForward = CreateGlobalForward("PunishmentPluginUnloaded", ET_Ignore);
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
		decl String:type[64], String:adminName[64], String:punishedAuth[64], String:reason[64];
		SQL_FetchString(query, 0, type, sizeof(type));
		SQL_FetchString(query, 1, adminName, sizeof(adminName));
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

				if (!(pmethod[flags] & SP_NOTIME)) {
					Call_StartForward(pmethod[addCallback]);
					Call_PushCell(i);
					Call_PushString(reason);
					Call_PushString(adminName);
					Call_Finish();

					new length = SQL_FetchInt(query, 5);
					if (length > 0 && !(pmethod[flags] & SP_NOREMOVE)) {
						new Handle:punishmentInfoPack = CreateDataPack();
						WritePackString(punishmentInfoPack, type);
						WritePackCell(punishmentInfoPack, i);
						WritePackString(punishmentInfoPack, adminName);
						WritePackCell(punishmentInfoPack, startTime);
						ResetPack(punishmentInfoPack); // Move index back to beginning so we can read from it.
						new endTime = startTime + (length * 60);
						new Handle:timer = CreateTimer(float(endTime - GetTime()), PunishmentExpire, punishmentInfoPack);
						if (punishmentRemovalTimers[i] == INVALID_HANDLE) {
							punishmentRemovalTimers[i] = CreateTrie();
						}
						SetTrieValue(punishmentRemovalTimers[i], type, timer);
					}
				}
				break;
			}
		}
	}
}

public Action:Command_Punish(client, args) {
	decl String:command[70], String:twoChars[3], String:threeChars[4];
	GetCmdArg(0, command, sizeof(command));

	strcopy(twoChars, sizeof(twoChars), command[3]); // Get the first 2 characters (sizeof(twoChars) - 1 = 3 (1 char is for \0)).
	strcopy(threeChars, sizeof(threeChars), command[3]); // Get the first 3 characters (sizeof(threeChars) - 1 = 3 (1 char is for \0)).

	new commandType = 0; // Values are 0 = normal punish, 1 = normal unpunish, 2 = offline punish, 3 = offline unpunish
	decl String:type[64];
	if (StrEqual(twoChars, "un", false)) {
		commandType = 1;
		strcopy(type, sizeof(type), command[2 + 3]);
	} else if (StrEqual(threeChars, "add", false)) {
		commandType = 2;
		strcopy(type, sizeof(type), command[3 + 3]);
	} else if (StrEqual(threeChars, "del", false)) {
		commandType = 3;
		strcopy(type, sizeof(type), command[3 + 3]);
	} else {
		strcopy(type, sizeof(type), command[3]);
	}

	decl pmethod[punishmentType];
	if (!GetTrieArray(punishments, type, pmethod, sizeof(pmethod))) {
		ReplyToCommand(client, "[SM] Plugin providing punishment type %s has been unloaded.", type);
		return Plugin_Handled;
	}

	if (args < 1) {
		switch (commandType) {
			case 0: {
				if (pmethod[flags] & SP_NOTIME) {
					ReplyToCommand(client, "Usage: %s <#userid|name> [reason]", type);
				} else {
					ReplyToCommand(client, "Usage: %s <#userid|name> [time|0] [reason]", type);
				}
			}
			case 1: {
				ReplyToCommand(client, "Usage: un%s <#userid|name> [reason]", type);
			}
			case 2: {
				ReplyToCommand(client, "Usage: add%s <steam ID> [reason]", type);
			}
			case 3: {
				ReplyToCommand(client, "Usage: del%s <steam ID> [reason]", type);
			}
		}
		return Plugin_Handled;
	}

	decl String:target[64], String:time[64], String:fullArgString[64];
	GetCmdArgString(fullArgString, sizeof(fullArgString));
	new pos = BreakString(fullArgString, target, sizeof(target));

	decl String:reason[64];
	if (commandType == 0 || commandType == 2) {
		new reasonArgumentNum = 2;
		if (!(pmethod[flags] & SP_NOTIME)) {
			reasonArgumentNum = 3;
		}

		if (args >= reasonArgumentNum) {
			new posAfterTime = -1;
			if (reasonArgumentNum == 3 && pos != -1) {
				posAfterTime = BreakString(fullArgString[pos], time, sizeof(time));
			} else {
				strcopy(time, sizeof(time), "0");
			}

			if (posAfterTime != -1) {
				strcopy(reason, sizeof(reason), fullArgString[pos + posAfterTime]);
			} else if (pmethod[flags] & SP_NOTIME) {
				strcopy(reason, sizeof(reason), fullArgString[pos]);
			} else {
				reason[0] = '\0';
			}
		} else {
			strcopy(time, sizeof(time), "0");
			reason[0] = '\0'; // Make it safe per http://wiki.alliedmods.net/Introduction_to_SourcePawn#Caveats
		}
	} else {
		if (pos != -1) {
			strcopy(reason, sizeof(reason), fullArgString[pos]);
		} else {
			reason[0] = '\0'; // Make it safe per http://wiki.alliedmods.net/Introduction_to_SourcePawn#Caveats
		}
	}

	decl String:adminName[64], String:adminAuth[64];
	if (client) {
		GetClientName(client, adminName, sizeof(adminName));
		GetClientAuthString(client, adminAuth, sizeof(adminAuth));
	} else {
		strcopy(adminName, sizeof(adminName), "Console");
		strcopy(adminAuth, sizeof(adminAuth), "Console");
	}

	new String:target_name[MAX_TARGET_LENGTH]; // Stores the noun identifying the target(s)
	new target_list[MAXPLAYERS], target_count = 0; // Array to store the clients, and also a variable to store the number of clients
	new bool:tn_is_ml; // Stores whether the noun must be translated

	if (commandType > 1) {
		// sm_add commands are for offline players
		if (MatchRegex(steamIDRegex, target) >= 0) {
			if (ProcessTargetString(target, client, target_list, sizeof(target_list), 0, target_name, sizeof(target_name), tn_is_ml)) {
				PrintToChat(client, "[SM] Target is online as %s", target_name);
				return Plugin_Handled;
			}
		} else {
			PrintToChat(client, "[SM] Target should be a Steam ID!");
			return Plugin_Handled;
		}
	} else if ((target_count = ProcessTargetString(
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

	if (commandType == 0) {
		for (new i = 0; i < target_count; i++) {
			PunishClient(type, target_list[i], StringToInt(time), reason, adminName, adminAuth, Command_Punish_Client_Result, client);
		}
	} else if (commandType == 1) {
		for (new i = 0; i < target_count; i++) {
			UnpunishClient(type, target_list[i], reason, adminName, adminAuth, Command_Unpunish_Client_Result, client);
		}
	} else if (commandType == 2) {
		PunishIdentity(type, target, StringToInt(time), reason, adminName, adminAuth, Command_Punish_Identity_Result, client);
	} else if (commandType == 3) {
		UnpunishIdentity(type, target, reason, adminName, adminAuth, Command_Unpunish_Identity_Result, client);
	}
	return Plugin_Handled;
}

public Command_Punish_Client_Result(targetClient, result, String:adminName[], String:adminAuth[], adminClient) {
	decl String:targetName[64];
	GetClientName(targetClient, targetName, sizeof(targetName));
	Command_Punish_Identity_Result(targetName, result, adminName, adminAuth, adminClient);
}

public Command_Punish_Identity_Result(String:identity[], result, String:adminName[], String:adminAuth[], adminClient) {
	switch (result) {
		case SP_SUCCESS: {
			ReplyToCommand(adminClient, "Successfully punished %s", identity);
		}
		case SP_ERROR_TARGET_ALREADY_PUNISHED: {
			ReplyToCommand(adminClient, "%s has already been punished with that", identity);
		}
		case SP_ERROR_SQL: {
			ReplyToCommand(adminClient, "An SQL error occured while punishing %s", identity);
		}
	}
}

public Command_Unpunish_Client_Result(targetClient, result, String:adminName[], String:adminAuth[], adminClient) {
	decl String:targetName[64];
	GetClientName(targetClient, targetName, sizeof(targetName));
	Command_Unpunish_Identity_Result(targetName, result, adminName, adminAuth, adminClient);
}

public Command_Unpunish_Identity_Result(String:identity[], result, String:adminName[], String:adminAuth[], adminClient) {
	switch (result) {
		case SP_SUCCESS: {
			ReplyToCommand(adminClient, "Successfully unpunished %s", identity);
		}
		case SP_ERROR_TARGET_NOT_PUNISHED: {
			ReplyToCommand(adminClient, "%s has not been punished with that", identity);
		}
		case SP_ERROR_SQL: {
			ReplyToCommand(adminClient, "An SQL error occured while unpunishing %s", identity);
		}
	}
}

public OnClientAuthorized(client, const String:auth[]) {
	decl String:escapedAuth[64], String:query[512];
	SQL_EscapeString(db, auth, escapedAuth, sizeof(escapedAuth));
	Format(query, sizeof(query), "SELECT Punish_Type, Punish_Admin_Name, Punish_Reason, Punish_Time, Punish_Length FROM sourcepunish_punishments WHERE Punish_Player_ID = '%s' AND UnPunish = 0 AND (Punish_Server_ID = %i OR Punish_All_Servers = 1) AND ((Punish_Time + (Punish_Length * 60)) > UNIX_TIMESTAMP(NOW()) OR Punish_Length = 0);", escapedAuth, serverID);
	SQL_TQuery(db, UsersActivePunishmentsLookupComplete, query, client);
}

public UsersActivePunishmentsLookupComplete(Handle:owner, Handle:query, const String:error[], any:client) {
	if (query == INVALID_HANDLE) {
		ThrowError("Error querying DB: %s", error);
	}

	while (SQL_FetchRow(query)) {
		decl String:type[64], String:adminName[64], String:reason[64];
		SQL_FetchString(query, 0, type, sizeof(type));
		SQL_FetchString(query, 1, adminName, sizeof(adminName));
		SQL_FetchString(query, 2, reason, sizeof(reason));

		decl pmethod[punishmentType];
		if (!GetTrieArray(punishments, type, pmethod, sizeof(pmethod))) {
			PrintToServer("Loaded an active punishment with unknown type %s", type);
			continue;
		}

		if (!(pmethod[flags] & SP_NOTIME)) {
			Call_StartForward(pmethod[addCallback]);
			Call_PushCell(client);
			Call_PushString(reason);
			Call_PushString(adminName);
			Call_Finish();

			new length = SQL_FetchInt(query, 4);
			if (length > 0 && !(pmethod[flags] & SP_NOREMOVE)) {
				new startTime = SQL_FetchInt(query, 3);
				new Handle:punishmentInfoPack = CreateDataPack();
				WritePackString(punishmentInfoPack, type);
				WritePackCell(punishmentInfoPack, client);
				WritePackString(punishmentInfoPack, adminName);
				WritePackCell(punishmentInfoPack, startTime);
				ResetPack(punishmentInfoPack); // Move index back to beginning so we can read from it.
				new endTime = startTime + (length * 60);
				new Handle:timer = CreateTimer(float(endTime - GetTime()), PunishmentExpire, punishmentInfoPack);
				if (punishmentRemovalTimers[client] == INVALID_HANDLE) {
					punishmentRemovalTimers[client] = CreateTrie();
				}
				SetTrieValue(punishmentRemovalTimers[client], type, timer);
			}
		}
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

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max) {
	RegPluginLibrary("sourcepunish");
	CreateNative("RegisterPunishment", Native_RegisterPunishment);
	CreateNative("PunishmentPluginUnload", Native_PunishmentPluginUnload);
	CreateNative("GetRegisteredPunishmentTypeStrings", Native_GetRegisteredPunishmentTypeStrings);
	CreateNative("GetPunishmentTypeDisplayName", Native_GetPunishmentTypeDisplayName);
	CreateNative("GetPunishmentTypeFlags", Native_GetPunishmentTypeFlags);
	CreateNative("GetPunishmentTypeAdminFlag", Native_GetPunishmentTypeAdminFlag);
	CreateNative("PunishClient", Native_PunishClient);
	CreateNative("PunishIdentity", Native_PunishIdentity);
	CreateNative("UnpunishClient", Native_UnpunishClient);
	CreateNative("UnpunishIdentity", Native_UnpunishIdentity);
	return APLRes_Success;
}

public Native_PunishmentPluginUnload(Handle:plugin, numParams) {
	for (new i = 0; i < GetArraySize(punishmentTypes); i++) {
		decl String:type[64], pmethod[punishmentType];
		GetArrayString(punishmentTypes, i, type, sizeof(type));
		GetTrieArray(punishments, type, pmethod, sizeof(pmethod));
		if (pmethod[pluginHandle] == plugin) {
			RemoveFromArray(punishmentTypes, i);
			RemoveFromTrie(punishments, type);
			for (new j = 0; j < MAXPLAYERS; j++) {
				if (punishmentRemovalTimers[j] != INVALID_HANDLE) {
					new Handle:timer = INVALID_HANDLE;
					GetTrieValue(punishmentRemovalTimers[j], type, timer);
					if (timer != INVALID_HANDLE) {
						KillTimer(timer);
					}
					RemoveFromTrie(punishmentRemovalTimers[j], type);
				}
			}
		}
	}
	Call_StartForward(punishmentPluginUnloadedForward);
	Call_Finish();
}

public Native_PunishClient(Handle:plugin, numParams) {
	new timestamp = GetTime();

	decl String:type[64], String:reason[256], String:adminName[64], String:adminAuth[64];
	GetNativeString(1, type, sizeof(type));
	new targetClient = GetNativeCell(2);
	new durationMinutes = GetNativeCell(3);
	GetNativeString(4, reason, sizeof(reason));
	GetNativeString(5, adminName, sizeof(adminName));
	GetNativeString(6, adminAuth, sizeof(adminAuth));
	new Function:resultCallback = GetNativeCell(7);
	new adminClient = GetNativeCell(8);

	decl pmethod[punishmentType];
	if (!GetTrieArray(punishments, type, pmethod, sizeof(pmethod))) {
		return ThrowNativeError(SP_ERROR_NATIVE, "Punishment type %s not found", type);
	}

	if (!IsClientConnected(targetClient)) {
		return ThrowNativeError(SP_ERROR_NATIVE, "Target client %i is not connected", targetClient);
	}

	new Handle:punishmentInfoPack = CreateDataPack();
	WritePackString(punishmentInfoPack, type);
	WritePackCell(punishmentInfoPack, targetClient);
	WritePackCell(punishmentInfoPack, durationMinutes);
	WritePackString(punishmentInfoPack, reason);
	WritePackString(punishmentInfoPack, adminName);
	WritePackString(punishmentInfoPack, adminAuth);
	WritePackCell(punishmentInfoPack, adminClient);
	WritePackCell(punishmentInfoPack, timestamp);
	WritePackCell(punishmentInfoPack, _:plugin);
	WritePackCell(punishmentInfoPack, _:resultCallback);
	ResetPack(punishmentInfoPack); // Move index back to beginning so we can read from it.

	decl String:targetAuth[64];
	GetClientAuthString(targetClient, targetAuth, sizeof(targetAuth));

	decl String:query[1000], String:escapedType[64], String:escapedTargetAuth[64];
	SQL_EscapeString(db, targetAuth, escapedTargetAuth, sizeof(escapedTargetAuth));
	SQL_EscapeString(db, pmethod[name], escapedType, sizeof(escapedType));
	Format(query, sizeof(query), "SELECT COUNT(*) FROM sourcepunish_punishments WHERE UnPunish = 0 AND (Punish_Server_ID = %i OR Punish_All_Servers = 1) AND ((Punish_Time + (Punish_Length * 60)) > UNIX_TIMESTAMP(NOW()) OR Punish_Length = 0) AND Punish_Type = '%s' AND Punish_Player_ID = '%s';", serverID, escapedType, escapedTargetAuth);
	SQL_TQuery(db, Native_PunishClient_ExistenceCheckCompleted, query, punishmentInfoPack);

	return true;
}

public Native_PunishClient_ExistenceCheckCompleted(Handle:owner, Handle:query, const String:error[], any:punishmentInfoPack) {
	decl String:type[64], String:reason[513], String:adminName[64], String:adminAuth[64];
	ReadPackString(punishmentInfoPack, type, sizeof(type));
	new targetClient = ReadPackCell(punishmentInfoPack);
	new durationMinutes = ReadPackCell(punishmentInfoPack);
	ReadPackString(punishmentInfoPack, reason, sizeof(reason));
	ReadPackString(punishmentInfoPack, adminName, sizeof(adminName));
	ReadPackString(punishmentInfoPack, adminAuth, sizeof(adminAuth));
	new adminClient = ReadPackCell(punishmentInfoPack);
	new timestamp = ReadPackCell(punishmentInfoPack);
	new Handle:plugin = Handle:ReadPackCell(punishmentInfoPack);
	new Function:resultCallback = Function:ReadPackCell(punishmentInfoPack);

	if (query == INVALID_HANDLE) {
		Call_StartFunction(plugin, resultCallback);
		Call_PushCell(targetClient);
		Call_PushCell(SP_ERROR_SQL);
		Call_PushString(adminName);
		Call_PushString(adminAuth);
		Call_PushCell(adminClient);
		Call_Finish();
		ThrowError("Error querying DB: %s", error);
	}

	decl pmethod[punishmentType];
	GetTrieArray(punishments, type, pmethod, sizeof(pmethod));

	SQL_FetchRow(query);
	if (SQL_FetchInt(query, 0) != 0 && !(pmethod[flags] & SP_NOTIME)) {
		Call_StartFunction(plugin, resultCallback);
		Call_PushCell(targetClient);
		Call_PushCell(SP_ERROR_TARGET_ALREADY_PUNISHED);
		Call_PushString(adminName);
		Call_PushString(adminAuth);
		Call_PushCell(adminClient);
		Call_Finish();
		return;
	}

	decl String:targetName[64], String:targetAuth[64], String:targetIP[64];
	GetClientName(targetClient, targetName, sizeof(targetName));
	GetClientAuthString(targetClient, targetAuth, sizeof(targetAuth));
	GetClientIP(targetClient, targetIP, sizeof(targetIP));

	RecordPunishmentInDB(pmethod[name], adminAuth, adminName, targetAuth, targetName, targetIP, timestamp, durationMinutes, reason, plugin, resultCallback, targetClient, adminClient);
}

RecordPunishmentInDB(
	String:type[],
	String:adminAuth[],
	String:adminName[],
	String:punishedAuth[],
	String:punishedName[],
	String:punishedIP[],
	startTime,
	length,
	String:reason[],
	Handle:plugin = INVALID_HANDLE,
	Function:resultCallback = INVALID_FUNCTION,
	targetClient = -1,
	adminClient = 0
) {
	// Unfortunately you can't do threaded queries for prepared statements - this is https://bugs.alliedmods.net/show_bug.cgi?id=3519
	decl String:unformattedQuery[300] = "INSERT INTO sourcepunish_punishments\
(Punish_Time, Punish_Server_ID, Punish_Player_Name, Punish_Player_ID, Punish_Player_IP, Punish_Type, Punish_Length, Punish_Reason, Punish_Admin_Name, Punish_Admin_ID)\
VALUES (%i, %i, \"%s\", \"%s\", \"%s\", \"%s\", %i, \"%s\", \"%s\", \"%s\");";
	//TODO: deal with Punish_Auth_Type, Punish_All_Servers, Punish_All_Mods
	decl String:escapedType[129], String:escapedAdminAuth[511], String:escapedAdminName[511], String:escapedPunishedAuth[511], String:escapedPunishedName[511], String:escapedReason[511];
	SQL_EscapeString(db, type, escapedType, sizeof(escapedType));
	SQL_EscapeString(db, adminAuth, escapedAdminAuth, sizeof(escapedAdminAuth));
	SQL_EscapeString(db, adminName, escapedAdminName, sizeof(escapedAdminName));
	SQL_EscapeString(db, punishedAuth, escapedPunishedAuth, sizeof(escapedPunishedAuth));
	SQL_EscapeString(db, punishedName, escapedPunishedName, sizeof(escapedPunishedName));
	SQL_EscapeString(db, reason, escapedReason, sizeof(escapedReason));

	decl String:query[1024];
	Format(query, sizeof(query), unformattedQuery, startTime, serverID, escapedPunishedName, escapedPunishedAuth, punishedIP, escapedType, length, escapedReason, escapedAdminName, escapedAdminAuth);

	new Handle:resultCallbackDataPack = CreateDataPack();
	WritePackCell(resultCallbackDataPack, _:plugin);
	WritePackCell(resultCallbackDataPack, _:resultCallback);
	WritePackCell(resultCallbackDataPack, targetClient);
	WritePackString(resultCallbackDataPack, punishedAuth);
	WritePackString(resultCallbackDataPack, adminName);
	WritePackString(resultCallbackDataPack, adminAuth);
	WritePackCell(resultCallbackDataPack, adminClient);
	WritePackString(resultCallbackDataPack, type);
	WritePackCell(resultCallbackDataPack, length);
	WritePackString(resultCallbackDataPack, reason);
	WritePackCell(resultCallbackDataPack, startTime);
	ResetPack(resultCallbackDataPack);
	SQL_TQuery(db, PunishmentRecorded, query, resultCallbackDataPack);
}

public PunishmentRecorded(Handle:owner, Handle:query, const String:error[], any:resultCallbackDataPack) {
	decl String:punishedAuth[512], String:adminName[512], String:adminAuth[512], String:type[64], String:reason[512];

	new Handle:plugin = Handle:ReadPackCell(resultCallbackDataPack);
	new Function:resultCallback = Function:ReadPackCell(resultCallbackDataPack);
	new targetClient = ReadPackCell(resultCallbackDataPack);
	ReadPackString(resultCallbackDataPack, punishedAuth, sizeof(punishedAuth));
	ReadPackString(resultCallbackDataPack, adminName, sizeof(adminName));
	ReadPackString(resultCallbackDataPack, adminAuth, sizeof(adminAuth));
	new adminClient = ReadPackCell(resultCallbackDataPack);
	ReadPackString(resultCallbackDataPack, type, sizeof(type));
	new durationMinutes = ReadPackCell(resultCallbackDataPack);
	ReadPackString(resultCallbackDataPack, reason, sizeof(reason));
	new timestamp = ReadPackCell(resultCallbackDataPack);

	if (resultCallback != INVALID_FUNCTION) {
		Call_StartFunction(plugin, resultCallback);
		if (targetClient == -1) {
			Call_PushString(punishedAuth);
		} else {
			Call_PushCell(targetClient);
		}
		if (query == INVALID_HANDLE) {
			Call_PushCell(SP_ERROR_SQL);
		} else {
			Call_PushCell(SP_SUCCESS);
		}
		Call_PushString(adminName);
		Call_PushString(adminAuth);
		Call_PushCell(adminClient);
		Call_Finish();
	}

	if (query == INVALID_HANDLE) {
		ThrowError("Error while recording punishment: %s", error);
	} else if (targetClient != -1 && IsClientInGame(targetClient)) {
		PrintToChat(targetClient, "[SM] You have been punished with %s by %s for %i minutes with reason: %s", type, adminName, durationMinutes, reason);
	}

	decl pmethod[punishmentType];
	GetTrieArray(punishments, type, pmethod, sizeof(pmethod));

	Call_StartForward(pmethod[addCallback]);
	Call_PushCell(targetClient);
	Call_PushString(reason);
	Call_PushString(adminName);
	Call_Finish();

	if (!(pmethod[flags] & SP_NOREMOVE) && !(pmethod[flags] & SP_NOTIME) && durationMinutes != 0) {
		new Handle:punishmentExpiryInfoPack = CreateDataPack();
		WritePackString(punishmentExpiryInfoPack, pmethod[name]);
		WritePackCell(punishmentExpiryInfoPack, targetClient);
		WritePackString(punishmentExpiryInfoPack, adminName);
		WritePackCell(punishmentExpiryInfoPack, timestamp);
		ResetPack(punishmentExpiryInfoPack); // Move index back to beginning so we can read from it.
		new Handle:timer = CreateTimer(float(durationMinutes * 60), PunishmentExpire, punishmentExpiryInfoPack);
		if (punishmentRemovalTimers[targetClient] == INVALID_HANDLE) {
			punishmentRemovalTimers[targetClient] = CreateTrie();
		}
		SetTrieValue(punishmentRemovalTimers[targetClient], pmethod[name], timer);
	}
}

public Native_PunishIdentity(Handle:plugin, numParams) {
	new timestamp = GetTime();

	decl String:type[64], String:identity[64], String:reason[256], String:adminName[64], String:adminAuth[64], pmethod[punishmentType];
	GetNativeString(1, type, sizeof(type));
	GetNativeString(2, identity, sizeof(identity));
	new durationMinutes = GetNativeCell(3);
	GetNativeString(4, reason, sizeof(reason));
	GetNativeString(5, adminName, sizeof(adminName));
	GetNativeString(6, adminAuth, sizeof(adminAuth));
	new Function:resultCallback = GetNativeCell(7);
	new adminClient = GetNativeCell(8);

	if (!GetTrieArray(punishments, type, pmethod, sizeof(pmethod))) {
		return ThrowNativeError(SP_ERROR_NATIVE, "Punishment type %s not found", type);
	}

	new Handle:punishmentInfoPack = CreateDataPack();
	WritePackString(punishmentInfoPack, type);
	WritePackString(punishmentInfoPack, identity);
	WritePackCell(punishmentInfoPack, durationMinutes);
	WritePackString(punishmentInfoPack, reason);
	WritePackString(punishmentInfoPack, adminName);
	WritePackString(punishmentInfoPack, adminAuth);
	WritePackCell(punishmentInfoPack, adminClient);
	WritePackCell(punishmentInfoPack, timestamp);
	WritePackCell(punishmentInfoPack, _:plugin);
	WritePackCell(punishmentInfoPack, _:resultCallback);
	ResetPack(punishmentInfoPack); // Move index back to beginning so we can read from it.

	decl String:query[1000], String:escapedType[64], String:escapedTargetAuth[64];
	SQL_EscapeString(db, identity, escapedTargetAuth, sizeof(escapedTargetAuth));
	SQL_EscapeString(db, pmethod[name], escapedType, sizeof(escapedType));
	Format(query, sizeof(query), "SELECT COUNT(*) FROM sourcepunish_punishments WHERE UnPunish = 0 AND (Punish_Server_ID = %i OR Punish_All_Servers = 1) AND ((Punish_Time + (Punish_Length * 60)) > UNIX_TIMESTAMP(NOW()) OR Punish_Length = 0) AND Punish_Type = '%s' AND Punish_Player_ID = '%s';", serverID, escapedType, escapedTargetAuth);
	SQL_TQuery(db, Native_PunishIdentity_ExistenceCheckCompleted, query, punishmentInfoPack);

	return true;
}

public Native_PunishIdentity_ExistenceCheckCompleted(Handle:owner, Handle:query, const String:error[], any:punishmentInfoPack) {
	decl String:type[64], String:identity[64], String:adminName[64], String:adminAuth[64], String:reason[64];
	ReadPackString(punishmentInfoPack, type, sizeof(type));
	ReadPackString(punishmentInfoPack, identity, sizeof(identity));
	new durationMinutes = ReadPackCell(punishmentInfoPack);
	ReadPackString(punishmentInfoPack, reason, sizeof(reason));
	ReadPackString(punishmentInfoPack, adminName, sizeof(adminName));
	ReadPackString(punishmentInfoPack, adminAuth, sizeof(adminAuth));
	new adminClient = ReadPackCell(punishmentInfoPack);
	new timestamp = ReadPackCell(punishmentInfoPack);
	new Handle:plugin = Handle:ReadPackCell(punishmentInfoPack);
	new Function:resultCallback = Function:ReadPackCell(punishmentInfoPack);

	if (query == INVALID_HANDLE) {
		Call_StartFunction(plugin, resultCallback);
		Call_PushString(identity);
		Call_PushCell(SP_ERROR_SQL);
		Call_PushString(adminName);
		Call_PushString(adminAuth);
		Call_PushCell(adminClient);
		Call_Finish();
		ThrowError("Error querying DB: %s", error);
	}

	decl pmethod[punishmentType];
	GetTrieArray(punishments, type, pmethod, sizeof(pmethod));

	SQL_FetchRow(query);
	if (SQL_FetchInt(query, 0) != 0 && !(pmethod[flags] & SP_NOTIME)) {
		Call_StartFunction(plugin, resultCallback);
		Call_PushString(identity);
		Call_PushCell(SP_ERROR_TARGET_ALREADY_PUNISHED);
		Call_PushString(adminName);
		Call_PushString(adminAuth);
		Call_PushCell(adminClient);
		Call_Finish();
		return;
	}

	RecordPunishmentInDB(type, adminAuth, adminName, identity, "", "", timestamp, durationMinutes, reason, plugin, resultCallback, -1, adminClient);
}

public Native_UnpunishClient(Handle:plugin, numParams) {
	new timestamp = GetTime();

	decl String:type[64], pmethod[punishmentType], String:reason[64], String:adminName[64], String:adminAuth[64];
	GetNativeString(1, type, sizeof(type));
	new targetClient = GetNativeCell(2);
	GetNativeString(3, reason, sizeof(reason));
	GetNativeString(4, adminName, sizeof(adminName));
	GetNativeString(5, adminAuth, sizeof(adminAuth));
	new Function:resultCallback = GetNativeCell(6);
	new adminClient = GetNativeCell(7);

	if (!GetTrieArray(punishments, type, pmethod, sizeof(pmethod))) {
		return ThrowNativeError(SP_ERROR_NATIVE, "Punishment type %s not found", type);
	}

	if (!IsClientConnected(targetClient)) {
		return ThrowNativeError(SP_ERROR_NATIVE, "Target client %i is not connected", targetClient);
	}

	decl String:targetName[64], String:targetAuth[64];
	GetClientName(targetClient, targetName, sizeof(targetName));
	GetClientAuthString(targetClient, targetAuth, sizeof(targetAuth));

	new Handle:punishmentRemovalInfoPack = CreateDataPack();
	WritePackCell(punishmentRemovalInfoPack, targetClient);
	WritePackCell(punishmentRemovalInfoPack, timestamp);
	WritePackString(punishmentRemovalInfoPack, pmethod[name]);
	WritePackString(punishmentRemovalInfoPack, adminName);
	WritePackString(punishmentRemovalInfoPack, adminAuth);
	WritePackCell(punishmentRemovalInfoPack, adminClient);
	WritePackString(punishmentRemovalInfoPack, targetName);
	WritePackString(punishmentRemovalInfoPack, targetAuth);
	WritePackString(punishmentRemovalInfoPack, reason);
	WritePackCell(punishmentRemovalInfoPack, _:plugin);
	WritePackCell(punishmentRemovalInfoPack, _:resultCallback);
	ResetPack(punishmentRemovalInfoPack); // Move index back to beginning so we can read from it.

	decl String:query[1000], String:escapedTargetAuth[64], String:escapedType[64], String:escapedAdminName[64], String:escapedAdminAuth[64];
	SQL_EscapeString(db, targetAuth, escapedTargetAuth, sizeof(escapedTargetAuth));
	SQL_EscapeString(db, pmethod[name], escapedType, sizeof(escapedType));
	SQL_EscapeString(db, adminName, escapedAdminName, sizeof(escapedAdminName));
	SQL_EscapeString(db, adminAuth, escapedAdminAuth, sizeof(escapedAdminAuth));
	Format(query, sizeof(query), "SELECT COUNT(*) FROM sourcepunish_punishments WHERE UnPunish = 0 AND (Punish_Server_ID = %i OR Punish_All_Servers = 1) AND ((Punish_Time + (Punish_Length * 60)) > UNIX_TIMESTAMP(NOW()) OR Punish_Length = 0) AND Punish_Type = '%s' AND Punish_Player_ID = '%s';", serverID, escapedType, escapedTargetAuth);
	SQL_TQuery(db, Native_UnpunishClient_ExistenceCheckCompleted, query, punishmentRemovalInfoPack);

	return true;
}

public Native_UnpunishClient_ExistenceCheckCompleted(Handle:owner, Handle:query, const String:error[], any:punishmentRemovalInfoPack) {
	decl String:type[64], pmethod[punishmentType], String:adminName[64], String:adminAuth[64], String:targetName[64], String:targetAuth[64], String:reason[64];
	new targetClient = ReadPackCell(punishmentRemovalInfoPack);
	new timestamp = ReadPackCell(punishmentRemovalInfoPack);
	ReadPackString(punishmentRemovalInfoPack, type, sizeof(type));
	ReadPackString(punishmentRemovalInfoPack, adminName, sizeof(adminName));
	ReadPackString(punishmentRemovalInfoPack, adminAuth, sizeof(adminAuth));
	new adminClient = ReadPackCell(punishmentRemovalInfoPack);
	ReadPackString(punishmentRemovalInfoPack, targetName, sizeof(targetName));
	ReadPackString(punishmentRemovalInfoPack, targetAuth, sizeof(targetAuth));
	ReadPackString(punishmentRemovalInfoPack, reason, sizeof(reason));
	new Handle:plugin = Handle:ReadPackCell(punishmentRemovalInfoPack);
	new Function:resultCallback = Function:ReadPackCell(punishmentRemovalInfoPack);
	ResetPack(punishmentRemovalInfoPack);

	if (query == INVALID_HANDLE) {
		Call_StartFunction(plugin, resultCallback);
		Call_PushCell(targetClient);
		Call_PushCell(SP_ERROR_SQL);
		Call_PushString(adminName);
		Call_PushString(adminAuth);
		Call_PushCell(adminClient);
		Call_Finish();
		ThrowError("Error querying DB: %s", error);
	}

	SQL_FetchRow(query);
	new numberOfPunishmentsByUserWithType = SQL_FetchInt(query, 0);
	if (numberOfPunishmentsByUserWithType == 0) {
		Call_StartFunction(plugin, resultCallback);
		Call_PushCell(targetClient);
		Call_PushCell(SP_ERROR_TARGET_NOT_PUNISHED);
		Call_PushString(adminName);
		Call_PushString(adminAuth);
		Call_PushCell(adminClient);
		Call_Finish();
		return;
	}

	GetTrieArray(punishments, type, pmethod, sizeof(pmethod));

	Call_StartForward(pmethod[removeCallback]);
	Call_PushCell(targetClient);
	Call_Finish();

	decl String:updateQuery[512], String:escapedType[64], String:escapedAdminName[64], String:escapedAdminAuth[64], String:escapedTargetAuth[64];
	SQL_EscapeString(db, type, escapedType, sizeof(escapedType));
	SQL_EscapeString(db, adminName, escapedAdminName, sizeof(escapedAdminName));
	SQL_EscapeString(db, adminAuth, escapedAdminAuth, sizeof(escapedAdminAuth));
	SQL_EscapeString(db, targetAuth, escapedTargetAuth, sizeof(escapedTargetAuth));
	Format(updateQuery, sizeof(updateQuery), "UPDATE sourcepunish_punishments SET UnPunish = 1, UnPunish_Admin_Name = '%s', UnPunish_Admin_ID = '%s', UnPunish_Time = %i, UnPunish_Reason = '%s' WHERE UnPunish = 0 AND (Punish_Server_ID = %i OR Punish_All_Servers = 1) AND Punish_Player_ID = '%s' AND Punish_Type = '%s' AND ((Punish_Time + (Punish_Length * 60)) > UNIX_TIMESTAMP(NOW()) OR Punish_Length = 0);", escapedAdminName, escapedAdminAuth, timestamp, reason, serverID, escapedTargetAuth, escapedType);

	SQL_TQuery(db, UnpunishedUser, updateQuery, punishmentRemovalInfoPack);

	if (punishmentRemovalTimers[targetClient] != INVALID_HANDLE) {
		new Handle:timer = INVALID_HANDLE;
		GetTrieValue(punishmentRemovalTimers[targetClient], pmethod[name], timer);
		KillTimer(timer);
		SetTrieValue(punishmentRemovalTimers[targetClient], pmethod[name], INVALID_HANDLE);
	}
}

public UnpunishedUser(Handle:owner, Handle:query, const String:error[], any:punishmentRemovalInfoPack) {
	decl String:type[64], String:adminName[64], String:adminAuth[64], String:targetName[64], String:reason[64];
	new targetClient = ReadPackCell(punishmentRemovalInfoPack);
	ReadPackCell(punishmentRemovalInfoPack); // Timestamp
	ReadPackString(punishmentRemovalInfoPack, type, sizeof(type));
	ReadPackString(punishmentRemovalInfoPack, adminName, sizeof(adminName));
	ReadPackString(punishmentRemovalInfoPack, adminAuth, sizeof(adminAuth));
	new adminClient = ReadPackCell(punishmentRemovalInfoPack);
	ReadPackString(punishmentRemovalInfoPack, targetName, sizeof(targetName));
	if (targetClient != -1) {
		ReadPackString(punishmentRemovalInfoPack, "", 0); // Target auth
	}
	ReadPackString(punishmentRemovalInfoPack, reason, sizeof(reason));
	new Handle:plugin = Handle:ReadPackCell(punishmentRemovalInfoPack);
	new Function:resultCallback = Function:ReadPackCell(punishmentRemovalInfoPack);

	if (query != INVALID_HANDLE) {
		PrintToServer("[SM] Removed %s punishment from %s with reason: %s", type, targetName, reason);

		if (targetClient > 0 && IsClientInGame(targetClient)) { // Will be 0/false or -1 if the user is not online
			PrintToChat(targetClient, "[SM] Your %s punishment has been removed by %s with reason: %s", type, adminName, reason);
		}
	}

	if (resultCallback != INVALID_FUNCTION) {
		Call_StartFunction(plugin, resultCallback);
		if (targetClient == -1) {
			Call_PushString(targetName);
		} else {
			Call_PushCell(targetClient);
		}
		if (query == INVALID_HANDLE) {
			Call_PushCell(SP_ERROR_SQL);
		} else {
			Call_PushCell(SP_SUCCESS);
		}
		Call_PushString(adminName);
		Call_PushString(adminAuth);
		Call_PushCell(adminClient);
		Call_Finish();
	}

	if (query == INVALID_HANDLE) {
		ThrowError("Error querying DB: %s", error);
	}
}

public Native_UnpunishIdentity(Handle:plugin, numParams) {
	new timestamp = GetTime();

	decl String:type[64], String:identity[64], String:reason[256], String:adminName[64], String:adminAuth[64], pmethod[punishmentType];
	GetNativeString(1, type, sizeof(type));
	GetNativeString(2, identity, sizeof(identity));
	GetNativeString(3, reason, sizeof(reason));
	GetNativeString(4, adminName, sizeof(adminName));
	GetNativeString(5, adminAuth, sizeof(adminAuth));
	new Function:resultCallback = GetNativeCell(6);
	new adminClient = GetNativeCell(7);

	if (!GetTrieArray(punishments, type, pmethod, sizeof(pmethod))) {
		return ThrowNativeError(SP_ERROR_NATIVE, "Punishment type %s not found", type);
	}

	new Handle:punishmentRemovalInfoPack = CreateDataPack();
	WritePackCell(punishmentRemovalInfoPack, -1);
	WritePackCell(punishmentRemovalInfoPack, timestamp);
	WritePackString(punishmentRemovalInfoPack, pmethod[name]);
	WritePackString(punishmentRemovalInfoPack, adminName);
	WritePackString(punishmentRemovalInfoPack, adminAuth);
	WritePackCell(punishmentRemovalInfoPack, adminClient);
	WritePackString(punishmentRemovalInfoPack, identity);
	WritePackString(punishmentRemovalInfoPack, reason);
	WritePackCell(punishmentRemovalInfoPack, _:plugin);
	WritePackCell(punishmentRemovalInfoPack, _:resultCallback);
	ResetPack(punishmentRemovalInfoPack); // Move index back to beginning so we can read from it.

	decl String:query[1000], String:escapedTargetAuth[64], String:escapedType[64], String:escapedAdminName[64], String:escapedAdminAuth[64];
	SQL_EscapeString(db, identity, escapedTargetAuth, sizeof(escapedTargetAuth));
	SQL_EscapeString(db, pmethod[name], escapedType, sizeof(escapedType));
	SQL_EscapeString(db, adminName, escapedAdminName, sizeof(escapedAdminName));
	SQL_EscapeString(db, adminAuth, escapedAdminAuth, sizeof(escapedAdminAuth));
	Format(query, sizeof(query), "SELECT COUNT(*) FROM sourcepunish_punishments WHERE UnPunish = 0 AND (Punish_Server_ID = %i OR Punish_All_Servers = 1) AND ((Punish_Time + (Punish_Length * 60)) > UNIX_TIMESTAMP(NOW()) OR Punish_Length = 0) AND Punish_Type = '%s' AND Punish_Player_ID = '%s';", serverID, escapedType, escapedTargetAuth);
	SQL_TQuery(db, Native_UnpunishIdentity_ExistenceCheckCompleted, query, punishmentRemovalInfoPack);

	return true;
}

public Native_UnpunishIdentity_ExistenceCheckCompleted(Handle:owner, Handle:query, const String:error[], any:punishmentRemovalInfoPack) {
	if (query == INVALID_HANDLE) {
		ThrowError("Error querying DB: %s", error);
	}

	decl String:type[64], pmethod[punishmentType], String:adminName[64], String:adminAuth[64], String:targetAuth[64], String:reason[64];
	ReadPackCell(punishmentRemovalInfoPack); // -1
	new timestamp = ReadPackCell(punishmentRemovalInfoPack);
	ReadPackString(punishmentRemovalInfoPack, type, sizeof(type));
	ReadPackString(punishmentRemovalInfoPack, adminName, sizeof(adminName));
	ReadPackString(punishmentRemovalInfoPack, adminAuth, sizeof(adminAuth));
	new adminClient = ReadPackCell(punishmentRemovalInfoPack);
	ReadPackString(punishmentRemovalInfoPack, targetAuth, sizeof(targetAuth));
	ReadPackString(punishmentRemovalInfoPack, reason, sizeof(reason));
	new Handle:plugin = Handle:ReadPackCell(punishmentRemovalInfoPack);
	new Function:resultCallback = Function:ReadPackCell(punishmentRemovalInfoPack);
	ResetPack(punishmentRemovalInfoPack);

	SQL_FetchRow(query);
	if (SQL_FetchInt(query, 0) == 0) {
		Call_StartFunction(plugin, resultCallback);
		Call_PushString(targetAuth);
		Call_PushCell(SP_ERROR_TARGET_NOT_PUNISHED);
		Call_PushString(adminName);
		Call_PushString(adminAuth);
		Call_PushCell(adminClient);
		Call_Finish();
		return;
	}

	GetTrieArray(punishments, type, pmethod, sizeof(pmethod));

	decl String:updateQuery[512], String:escapedType[64], String:escapedTargetAuth[64], String:escapedAdminName[64], String:escapedAdminAuth[64];
	SQL_EscapeString(db, targetAuth, escapedTargetAuth, sizeof(escapedTargetAuth));
	SQL_EscapeString(db, adminName, escapedAdminName, sizeof(escapedAdminName));
	SQL_EscapeString(db, adminAuth, escapedAdminAuth, sizeof(escapedAdminAuth));
	SQL_EscapeString(db, type, escapedType, sizeof(escapedType));

	Format(updateQuery, sizeof(updateQuery), "UPDATE sourcepunish_punishments SET UnPunish = 1, UnPunish_Admin_Name = '%s', UnPunish_Admin_ID = '%s', UnPunish_Time = %i, UnPunish_Reason = '%s' WHERE UnPunish = 0 AND (Punish_Server_ID = %i OR Punish_All_Servers = 1) AND Punish_Player_ID = '%s' AND Punish_Type = '%s' AND ((Punish_Time + (Punish_Length * 60)) > UNIX_TIMESTAMP(NOW()) OR Punish_Length = 0);", escapedAdminName, escapedAdminAuth, timestamp, reason, serverID, escapedTargetAuth, escapedType);
	SQL_TQuery(db, UnpunishedUser, updateQuery, punishmentRemovalInfoPack);
}

public Action:PunishmentExpire(Handle:timer, Handle:punishmentInfoPack) {
	decl String:type[64];
	ReadPackString(punishmentInfoPack, type, sizeof(type));
	new targetClient = ReadPackCell(punishmentInfoPack);
	decl String:adminName[64];
	ReadPackString(punishmentInfoPack, adminName, sizeof(adminName));
	new setTimestamp = ReadPackCell(punishmentInfoPack);

	RemoveFromTrie(punishmentRemovalTimers[targetClient], type); // This timer is done, no need to try to make it more dead later.

	decl pmethod[punishmentType];
	if (!GetTrieArray(punishments, type, pmethod, sizeof(pmethod))) {
		decl String:targetClientName[64];
		GetClientName(targetClient, targetClientName, sizeof(targetClientName));
		PrintToServer("[SM] Punishment type %s not found when trying to end expired punishment for %s", type, targetClientName);
		return;
	}

	if (IsClientInGame(targetClient)) {
		decl String:setReadableTime[64];
		FormatTime(setReadableTime, sizeof(setReadableTime), "%F at %R (UTC)", setTimestamp); // E.g. "2013-08-03 at 00:12 (UTC)"

		PrintToChat(targetClient, "[SM] Punishment of type %s set by %s on %s expired", type, adminName, setReadableTime);
	}

	Call_StartForward(pmethod[removeCallback]);
	Call_PushCell(targetClient);
	Call_Finish();
}

public Native_GetRegisteredPunishmentTypeStrings(Handle:plugin, numParams) {
	return _:punishmentTypes;
}

public Native_GetPunishmentTypeDisplayName(Handle:plugin, numParams) {
	decl String:type[64], pmethod[punishmentType];
	GetNativeString(1, type, sizeof(type));
	if (!GetTrieArray(punishments, type, pmethod, sizeof(pmethod))) {
		return ThrowNativeError(SP_ERROR_NATIVE, "Punishment type %s not found", type);
	}

	SetNativeString(2, pmethod[displayName], GetNativeCell(3)); // Copy display name into buffer (param 2). maxlen is param 3.
	return true;
}

public Native_GetPunishmentTypeFlags(Handle:plugin, numParams) {
	decl String:type[64], pmethod[punishmentType];
	GetNativeString(1, type, sizeof(type));
	if (!GetTrieArray(punishments, type, pmethod, sizeof(pmethod))) {
		return ThrowNativeError(SP_ERROR_NATIVE, "Punishment type %s not found", type);
	}

	return pmethod[flags];
}

public Native_GetPunishmentTypeAdminFlag(Handle:plugin, numParams) {
	decl String:type[64], pmethod[punishmentType];
	GetNativeString(1, type, sizeof(type));
	if (!GetTrieArray(punishments, type, pmethod, sizeof(pmethod))) {
		return ThrowNativeError(SP_ERROR_NATIVE, "Punishment type %s not found", type);
	}

	return pmethod[adminflag];
}

public Native_RegisterPunishment(Handle:plugin, numParams) {
	decl String:type[64];
	GetNativeString(1, type, sizeof(type));

	decl String:typeDisplayName[64];
	GetNativeString(2, typeDisplayName, sizeof(typeDisplayName));

	decl pmethod[punishmentType];
	strcopy(pmethod[name], sizeof(pmethod[name]), type);
	strcopy(pmethod[displayName], sizeof(pmethod[displayName]), typeDisplayName);

	new Handle:af = CreateForward(ET_Event, Param_Cell, Param_String, Param_String);
	AddToForward(af, plugin, GetNativeCell(3));
	pmethod[addCallback] = af;

	new Handle:rf = CreateForward(ET_Event, Param_Cell);
	AddToForward(rf, plugin, GetNativeCell(4));
	pmethod[removeCallback] = rf;

	pmethod[flags] = GetNativeCell(5);
	pmethod[adminflag] = GetNativeCell(6);
	pmethod[pluginHandle] = plugin;

	SetTrieArray(punishments, type, pmethod, sizeof(pmethod));
	PushArrayString(punishmentTypes, type);

	decl String:mainAddCommand[67] = "sm_",
		 String:mainRemoveCommand[69] = "sm_un",
		 String:addCommand[70] = "sm_add",
		 String:removeCommand[70] = "sm_del",
		 String:addCommandDescription[128],
		 String:removeCommandDescription[128],
		 String:addOfflinePlayerCommandDescription[128],
		 String:removeOfflinePlayerCommandDescription[128];

	StrCat(mainAddCommand, sizeof(mainAddCommand), type);
	if (pmethod[flags] & SP_NOTIME) {
		Format(addCommandDescription, sizeof(addCommandDescription), "%s <#userid|name> [reason] - Punishes a player with a %s", mainAddCommand, typeDisplayName);
	} else {
		Format(addCommandDescription, sizeof(addCommandDescription), "%s <#userid|name> [expiry|0] [reason] - Punishes a player with a %s", mainAddCommand, typeDisplayName);
	}
	RegAdminCmd(mainAddCommand, Command_Punish, pmethod[adminflag], addCommandDescription);

	if (!(pmethod[flags] & SP_NOREMOVE)) {
		StrCat(mainRemoveCommand, sizeof(mainRemoveCommand), type);
		Format(removeCommandDescription, sizeof(removeCommandDescription), "%s <#userid|name> [reason] - Removes punishment from player of type %s", mainRemoveCommand, typeDisplayName);
		RegAdminCmd(mainRemoveCommand, Command_Punish, pmethod[adminflag], removeCommandDescription);
	}

	StrCat(addCommand, sizeof(addCommand), type);
	if (pmethod[flags] & SP_NOTIME) {
		Format(addOfflinePlayerCommandDescription, sizeof(addOfflinePlayerCommandDescription), "%s <steam ID> [reason] - Punishes an offline Steam ID with a %s", addCommand, typeDisplayName);
	} else {
		Format(addOfflinePlayerCommandDescription, sizeof(addOfflinePlayerCommandDescription), "%s <steam ID> [expiry|0] [reason] - Punishes an offline Steam ID with a %s", addCommand, typeDisplayName);
	}
	RegAdminCmd(addCommand, Command_Punish, ADMFLAG_RCON, addOfflinePlayerCommandDescription);

	StrCat(removeCommand, sizeof(removeCommand), type);
	Format(removeOfflinePlayerCommandDescription, sizeof(removeOfflinePlayerCommandDescription), "%s <steam ID> [reason] - Removes punishment from offline Steam ID of type %s", removeCommand, typeDisplayName);
	RegAdminCmd(removeCommand, Command_Punish, ADMFLAG_RCON, removeOfflinePlayerCommandDescription);

	Call_StartForward(punishmentRegisteredForward);
	Call_PushString(type);
	Call_PushString(typeDisplayName);
	Call_PushCell(pmethod[flags]);
	Call_Finish();

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
	Format(query, sizeof(query), "SELECT Punish_Type, Punish_Admin_Name, Punish_Player_ID, Punish_Reason, Punish_Time, Punish_Length FROM sourcepunish_punishments WHERE Punish_Type = '%s' AND UnPunish = 0 AND (Punish_Server_ID = %i OR Punish_All_Servers = 1) AND ((Punish_Time + (Punish_Length * 60)) > UNIX_TIMESTAMP(NOW()) OR Punish_Length = 0);", type, serverID);
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
			Format(query, sizeof(query), "SELECT DISTINCT Punish_Player_ID FROM sourcepunish_punishments WHERE Punish_Type = '%s' AND UnPunish = 0 AND (Punish_Server_ID = %i OR Punish_All_Servers = 1) AND ((Punish_Time + (Punish_Length * 60)) > UNIX_TIMESTAMP(NOW()) OR Punish_Length = 0);", pmethod[name], serverID);
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
	if (!GetMenuItemCount(menu)) {
		PrintToChat(client, "[SP] There are no players with that punishment type");
	} else {
		DisplayMenu(menu, client, MENU_TIME_FOREVER);
	}
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
	adminMenuClientStatusInReasonMenu[client] = false;
	decl pmethod[punishmentType];
	GetTrieArray(punishments, adminMenuClientStatusType[client], pmethod, sizeof(pmethod));

	if (!IsClientConnected(adminMenuClientStatusTarget[client])) {
		PrintToChat(client, "[SM] Target is not connected.");
		return;
	}

	if (!CanUserTarget(client, adminMenuClientStatusTarget[client])) {
		decl String:targetName[64];
		GetClientName(adminMenuClientStatusTarget[client], targetName, sizeof(targetName));
		PrintToChat(client, "[SM] Can't target %s.", targetName);
		return;
	}

	decl String:adminName[64], String:adminAuth[64];
	GetClientName(client, adminName, sizeof(adminName));
	GetClientAuthString(client, adminAuth, sizeof(adminAuth));

	if (adminMenuClientStatusAdding[client]) {
		PunishClient(pmethod[name], adminMenuClientStatusTarget[client], adminMenuClientStatusDuration[client], reason, adminName, adminAuth, Command_Punish_Client_Result, client);
	} else {
		UnpunishClient(pmethod[name], adminMenuClientStatusTarget[client], reason, adminName, adminAuth, Command_Unpunish_Client_Result, client);
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
