#include <sourcemod>
#include <sourceirc>
#include <sdktools>
#include <sourcepunish>
#include <regex>

public Plugin:myinfo = {
	name = "SourceIRC -> SourcePunish",
	author = "Alex",
	description = "SourcePunish integration plugin for SourceIRC",
	version = "0.1",
	url = "https://github.com/Krenair/SourcePunish"
};

public OnPluginStart() {
	LoadTranslations("common.phrases");
	if (LibraryExists("sourcepunish")) {
		ProcessRegisteredPunishments();
	}
}

public OnLibraryAdded(const String:libraryName[]) {
	if (StrEqual(libraryName, "sourcepunish")) {
		ProcessRegisteredPunishments();
	}
}

public OnLibraryRemoved(const String:libraryName[]) {
	if (StrEqual(libraryName, "sourcepunish")) {
		IRC_CleanUp();
	}
}

public OnPluginEnd() {
	IRC_CleanUp();
}

public ProcessRegisteredPunishments() {
	new Handle:registeredPunishments = GetRegisteredPunishmentTypeStrings();
	for (new i = 0; i < GetArraySize(registeredPunishments); i++) {
		decl String:type[64], String:displayType[64];
		GetArrayString(registeredPunishments, i, type, sizeof(type));
		GetPunishmentTypeDisplayName(type, displayType, sizeof(displayType));
		PunishmentRegistered(type, displayType, GetPunishmentTypeFlags(type));
	}
}

public PunishmentRegistered(String:type[], String:typeDisplayName[], flags) {
	decl String:mainRemoveCommand[66] = "un",
		 String:addCommand[67] = "add",
		 String:removeCommand[67] = "del",
		 String:addCommandDescription[128],
		 String:removeCommandDescription[128],
		 String:addOfflinePlayerCommandDescription[128],
		 String:removeOfflinePlayerCommandDescription[128];

	if (flags & SP_NOTIME) {
		Format(addCommandDescription, sizeof(addCommandDescription), "%s <#userid|name> [reason] - Punishes a player with a %s", type, typeDisplayName);
	} else {
		Format(addCommandDescription, sizeof(addCommandDescription), "%s <#userid|name> [expiry|0] [reason] - Punishes a player with a %s", type, typeDisplayName);
	}
	IRC_RegAdminCmd(type, IRCCommand_Punish, GetPunishmentTypeAdminFlag(type), addCommandDescription);

	if (!(flags & SP_NOREMOVE)) {
		StrCat(mainRemoveCommand, sizeof(mainRemoveCommand), type);
		Format(removeCommandDescription, sizeof(removeCommandDescription), "%s <#userid|name> [reason] - Removes punishment from player of type %s", mainRemoveCommand, typeDisplayName);
		IRC_RegAdminCmd(mainRemoveCommand, IRCCommand_Punish, GetPunishmentTypeAdminFlag(type), removeCommandDescription);
	}

	StrCat(addCommand, sizeof(addCommand), type);
	if (flags & SP_NOTIME) {
		Format(addOfflinePlayerCommandDescription, sizeof(addOfflinePlayerCommandDescription), "%s <steam ID> [reason] - Punishes an offline Steam ID with a %s", addCommand, typeDisplayName);
	} else {
		Format(addOfflinePlayerCommandDescription, sizeof(addOfflinePlayerCommandDescription), "%s <steam ID> [expiry|0] [reason] - Punishes an offline Steam ID with a %s", addCommand, typeDisplayName);
	}
	IRC_RegAdminCmd(addCommand, IRCCommand_Punish, ADMFLAG_RCON, addOfflinePlayerCommandDescription);

	StrCat(removeCommand, sizeof(removeCommand), type);
	Format(removeOfflinePlayerCommandDescription, sizeof(removeOfflinePlayerCommandDescription), "%s <steam ID> [reason] - Removes punishment from offline Steam ID of type %s", removeCommand, typeDisplayName);
	IRC_RegAdminCmd(removeCommand, IRCCommand_Punish, ADMFLAG_RCON, removeOfflinePlayerCommandDescription);
}

public PunishmentPluginUnloaded() {
	IRC_CleanUp();
	ProcessRegisteredPunishments();
}

public Action:IRCCommand_Punish(String:nick[], args) {
	decl String:command[70], String:twoChars[3], String:threeChars[4];
	IRC_GetCmdArg(0, command, sizeof(command));

	strcopy(twoChars, sizeof(twoChars), command); // Get the first 2 characters (sizeof(twoChars) - 1 = 3 (1 char is for \0)).
	strcopy(threeChars, sizeof(threeChars), command); // Get the first 3 characters (sizeof(threeChars) - 1 = 3 (1 char is for \0)).

	new commandType = 0; // Values are 0 = normal punish, 1 = normal unpunish, 2 = offline punish, 3 = offline unpunish
	decl String:type[64];
	if (StrEqual(twoChars, "un", false)) {
		commandType = 1;
		strcopy(type, sizeof(type), command[2]);
	} else if (StrEqual(threeChars, "add", false)) {
		commandType = 2;
		strcopy(type, sizeof(type), command[3]);
	} else if (StrEqual(threeChars, "del", false)) {
		commandType = 3;
		strcopy(type, sizeof(type), command[3]);
	} else {
		strcopy(type, sizeof(type), command);
	}

	if (!FindStringInArray(GetRegisteredPunishmentTypeStrings(), type)) {
		IRC_ReplyToCommand(nick, "[SM] Plugin providing punishment type %s has been unloaded.", type);
		return Plugin_Handled;
	}

	if (args < 1) {
		switch (commandType) {
			case 0: {
				if (GetPunishmentTypeFlags(type) & SP_NOTIME) {
					IRC_ReplyToCommand(nick, "Usage: %s <#userid|name> [reason]", type);
				} else {
					IRC_ReplyToCommand(nick, "Usage: %s <#userid|name> [time|0] [reason]", type);
				}
			}
			case 1: {
				IRC_ReplyToCommand(nick, "Usage: un%s <#userid|name> [reason]", type);
			}
			case 2: {
				IRC_ReplyToCommand(nick, "Usage: add%s <steam ID> [reason]", type);
			}
			case 3: {
				IRC_ReplyToCommand(nick, "Usage: del%s <steam ID> [reason]", type);
			}
		}
		return Plugin_Handled;
	}

	decl String:target[64], String:time[64], String:fullArgString[64];
	IRC_GetCmdArgString(fullArgString, sizeof(fullArgString));
	new pos = BreakString(fullArgString, target, sizeof(target));

	decl String:reason[64];
	if (commandType == 0 || commandType == 2) {
		new reasonArgumentNum = 2;
		if (!(GetPunishmentTypeFlags(type) & SP_NOTIME)) {
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
			} else if (GetPunishmentTypeFlags(type) & SP_NOTIME) {
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

	decl String:adminAuth[64];
	IRC_GetHostMask(adminAuth, sizeof(adminAuth));

	new String:target_name[MAX_TARGET_LENGTH]; // Stores the noun identifying the target(s)
	new target_list[MAXPLAYERS], target_count = 0; // Array to store the clients, and also a variable to store the number of clients
	new bool:tn_is_ml; // Stores whether the noun must be translated

	if (commandType > 1) {
		// sm_add/sm_del commands are for offline players
		if (MatchRegex(CompileRegex("^STEAM_[0-7]:[01]:\\d+$"), target) >= 0) {
			if (ProcessTargetString(target, 0, target_list, sizeof(target_list), 0, target_name, sizeof(target_name), tn_is_ml)) {
				IRC_ReplyToCommand(nick, "[SM] Target is online as %s", target_name);
				return Plugin_Handled;
			}
		} else {
			IRC_ReplyToCommand(nick, "[SM] Target should be a Steam ID!");
			return Plugin_Handled;
		}
	} else if ((target_count = ProcessTargetString(
		target,
		0,
		target_list,
		MAXPLAYERS,
		COMMAND_FILTER_CONNECTED, // We want to allow targetting even players who are not fully in-game but connected
		target_name,
		sizeof(target_name),
		tn_is_ml
	)) <= 0) {
		// Reply to the admin with a failure message
		IRC_ReplyToTargetError(nick, target_count);
		return Plugin_Handled;
	}

	if (commandType == 0) {
		for (new i = 0; i < target_count; i++) {
			PunishClient(type, target_list[i], StringToInt(time), reason, nick, adminAuth, IRCCommand_Punish_Client_Result);
		}
	} else if (commandType == 1) {
		for (new i = 0; i < target_count; i++) {
			UnpunishClient(type, target_list[i], reason, nick, adminAuth, IRCCommand_Unpunish_Client_Result);
		}
	} else if (commandType == 2) {
		PunishIdentity(type, target, StringToInt(time), reason, nick, adminAuth, IRCCommand_Punish_Identity_Result);
	} else if (commandType == 3) {
		UnpunishIdentity(type, target, reason, nick, adminAuth, IRCCommand_Unpunish_Identity_Result);
	}
	return Plugin_Handled;
}

public IRCCommand_Punish_Client_Result(targetClient, result, String:adminName[], String:adminAuth[], adminClient) {
	decl String:targetName[64];
	GetClientName(targetClient, targetName, sizeof(targetName));
	IRCCommand_Punish_Identity_Result(targetName, result, adminName, adminAuth, adminClient);
}

public IRCCommand_Punish_Identity_Result(String:identity[], result, String:adminName[], String:adminAuth[], adminClient) {
	switch (result) {
		case SP_SUCCESS: {
			IRC_ReplyToCommand(adminName, "Successfully punished %s", identity);
		}
		case SP_ERROR_TARGET_ALREADY_PUNISHED: {
			IRC_ReplyToCommand(adminName, "%s has already been punished with that", identity);
		}
		case SP_ERROR_SQL: {
			IRC_ReplyToCommand(adminName, "An SQL error occured while punishing %s", identity);
		}
	}
}

public IRCCommand_Unpunish_Client_Result(targetClient, result, String:adminName[], String:adminAuth[], adminClient) {
	decl String:targetName[64];
	GetClientName(targetClient, targetName, sizeof(targetName));
	IRCCommand_Unpunish_Identity_Result(targetName, result, adminName, adminAuth, adminClient);
}

public IRCCommand_Unpunish_Identity_Result(String:identity[], result, String:adminName[], String:adminAuth[], adminClient) {
	switch (result) {
		case SP_SUCCESS: {
			IRC_ReplyToCommand(adminName, "Successfully unpunished %s", identity);
		}
		case SP_ERROR_TARGET_NOT_PUNISHED: {
			IRC_ReplyToCommand(adminName, "%s has not been punished with that", identity);
		}
		case SP_ERROR_SQL: {
			IRC_ReplyToCommand(adminName, "An SQL error occured while unpunishing %s", identity);
		}
	}
}
