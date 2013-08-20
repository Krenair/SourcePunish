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
	new Handle:registeredPunishments = GetRegisteredPunishmentTypeStrings();
	for (new i = 0; i < GetArraySize(registeredPunishments); i++) {
		decl String:type[64], String:displayType[64];
		GetArrayString(registeredPunishments, i, type, sizeof(type));
		GetPunishmentTypeDisplayName(type, displayType, sizeof(displayType));
		PunishmentRegistered(type, displayType, GetPunishmentTypeFlags(type));
	}

	LoadTranslations("common.phrases");
}

public OnPluginEnd() {
	IRC_CleanUp();
}

public PunishmentRegistered(String:type[], String:typeDisplayName[], flags) {
	decl String:mainRemoveCommand[66] = "un",
		 String:addCommand[67] = "add",
		 String:removeCommand[67] = "del",
		 String:addCommandDescription[89] = "Punishes a player with a ",
		 String:removeCommandDescription[103] = "Removes punishment from player of type ",
		 String:addOfflinePlayerCommandDescription[100] = "Punishes an offline Steam ID with a ",
		 String:removeOfflinePlayerCommandDescription[113] = "Removes punishment from offline Steam ID of type ";

	StrCat(addCommandDescription, sizeof(addCommandDescription), typeDisplayName);
	IRC_RegAdminCmd(type, IRCCommand_Punish, ADMFLAG_GENERIC, addCommandDescription);

	if (!(flags & SP_NOREMOVE)) {
		StrCat(mainRemoveCommand, sizeof(mainRemoveCommand), type);
		StrCat(removeCommandDescription, sizeof(removeCommandDescription), typeDisplayName);
		IRC_RegAdminCmd(mainRemoveCommand, IRCCommand_Unpunish, ADMFLAG_GENERIC, removeCommandDescription);
	}

	StrCat(addCommand, sizeof(addCommand), type);
	StrCat(addOfflinePlayerCommandDescription, sizeof(addOfflinePlayerCommandDescription), typeDisplayName);
	IRC_RegAdminCmd(addCommand, IRCCommand_Punish, ADMFLAG_GENERIC, addOfflinePlayerCommandDescription);

	StrCat(removeCommand, sizeof(removeCommand), type);
	StrCat(removeOfflinePlayerCommandDescription, sizeof(removeOfflinePlayerCommandDescription), typeDisplayName);
	IRC_RegAdminCmd(removeCommand, IRCCommand_Unpunish, ADMFLAG_GENERIC, removeCommandDescription);
}

public Action:IRCCommand_Punish(String:nick[], args) {
	if (args < 1) {
		IRC_ReplyToCommand(nick, "Usage: [add]<type> <target> [time|0] [reason]");
		return Plugin_Handled;
	}

	decl String:command[70], String:prefix[4];
	IRC_GetCmdArg(0, command, sizeof(command));
	strcopy(prefix, sizeof(prefix), command); // Get the first 3 characters (sizeof(prefix) - 1 = 3 (1 char is for \0)).
	new typeIndexInCommand = 0; // If the first 3 characters are not "add", the type is the full command name.
	if (StrEqual(prefix, "add", false)) {
		typeIndexInCommand = 3; // Otherwise, the type is after "add", which is 3 characters long.
	}

	decl String:type[64];
	strcopy(type, sizeof(type), command[typeIndexInCommand]);

	decl String:target[64], String:time[64], String:fullArgString[64];
	IRC_GetCmdArgString(fullArgString, sizeof(fullArgString));
	new pos = BreakString(fullArgString, target, sizeof(target));

	decl String:reason[64];
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
		} else {
			reason[0] = '\0';
		}
	} else {
		strcopy(time, sizeof(time), "0");
		reason[0] = '\0'; // Make it safe per http://wiki.alliedmods.net/Introduction_to_SourcePawn#Caveats
	}

	decl String:setByAuth[64];
	IRC_GetHostMask(setByAuth, sizeof(setByAuth));

	new String:target_name[MAX_TARGET_LENGTH]; // Stores the noun identifying the target(s)
	new target_list[MAXPLAYERS], target_count = 0; // Array to store the clients, and also a variable to store the number of clients
	new bool:tn_is_ml; // Stores whether the noun must be translated

	if (typeIndexInCommand == 3) {
		// sm_add commands are for offline players
		if (MatchRegex(CompileRegex("^STEAM_[0-7]:[01]:\\d+$"), target) >= 0) {
			if (ProcessTargetString(target, 0, target_list, sizeof(target_list), 0, target_name, sizeof(target_name), tn_is_ml)) {
				IRC_ReplyToCommand(nick, "[SM] Target is online as %s", target_name);
				return Plugin_Handled;
			}
		} else {
			IRC_ReplyToCommand(nick, "[SM] Target should be a Steam ID!");
			return Plugin_Handled;
		}
	} else if (typeIndexInCommand == 0 && (target_count = ProcessTargetString(
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

	if (typeIndexInCommand == 0) {
		for (new i = 0; i < target_count; i++) {
			PunishClient(type, target_list[i], StringToInt(time), reason, nick, setByAuth, IRCCommand_Punish_Client_Result);
		}
	} else {
		PunishIdentity(type, target, StringToInt(time), reason, nick, setByAuth, IRCCommand_Punish_Identity_Result);
	}
	return Plugin_Handled;
}

public IRCCommand_Punish_Client_Result(targetClient, result, String:adminName[], String:adminAuth[]) {
	decl String:targetName[64];
	GetClientName(targetClient, targetName, sizeof(targetName));
	IRCCommand_Punish_Identity_Result(targetName, result, adminName, adminAuth);
}

public IRCCommand_Punish_Identity_Result(String:identity[], result, String:adminName[], String:adminAuth[]) {
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

public Action:IRCCommand_Unpunish(String:nick[], args) {
	if (args < 1) {
		IRC_ReplyToCommand(nick, "Usage: <un|del><type> <target> [reason]");
		return Plugin_Handled;
	}

	decl String:command[70], String:prefix[4];
	IRC_GetCmdArg(0, command, sizeof(command));
	strcopy(prefix, sizeof(prefix), command); // Get the first 3 characters (sizeof(prefix) - 1 = 3 (1 char is for \0)).
	new typeIndexInCommand = 2; // If the first 3 characters are not "del", the type is after "un", which is 2 characters long.
	if (StrEqual(prefix, "del", false)) {
		typeIndexInCommand = 3; // Otherwise, the type is after "del", which is 3 characters long.
	}

	decl String:type[64];
	strcopy(type, sizeof(type), command[typeIndexInCommand]);

	decl String:target[64], String:fullArgString[64];
	IRC_GetCmdArgString(fullArgString, sizeof(fullArgString));
	new pos = BreakString(fullArgString, target, sizeof(target));

	decl String:reason[64];

	if (pos != -1) {
		strcopy(reason, sizeof(reason), fullArgString[pos]);
	} else {
		reason[0] = '\0'; // Make it safe per http://wiki.alliedmods.net/Introduction_to_SourcePawn#Caveats
	}

	decl String:setByAuth[64];
	IRC_GetHostMask(setByAuth, sizeof(setByAuth));

	new String:target_name[MAX_TARGET_LENGTH]; // Stores the noun identifying the target(s)
	new target_list[MAXPLAYERS], target_count = 0; // Array to store the clients, and also a variable to store the number of clients
	new bool:tn_is_ml; // Stores whether the noun must be translated

	if (typeIndexInCommand == 3) {
		if (MatchRegex(CompileRegex("^STEAM_[0-7]:[01]:\\d+$"), target) == -1) {
			IRC_ReplyToCommand(nick, "[SM] Target should be a Steam ID!");
			return Plugin_Handled;
		} else {
			new String:tn[MAX_TARGET_LENGTH], tl[MAXPLAYERS], bool:tnml;
			if (ProcessTargetString(target, 0, tl, sizeof(tl), 0, tn, sizeof(tn), tnml)) {
				IRC_ReplyToCommand(nick, "[SM] Target is online as %s", tn);
				return Plugin_Handled;
			}
		}
	} else if (typeIndexInCommand == 2 && (target_count = ProcessTargetString(
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

	if (typeIndexInCommand == 2) {
		for (new i = 0; i < target_count; i++) {
			UnpunishClient(type, target_list[i], reason, nick, setByAuth, IRCCommand_Unpunish_Client_Result);
		}
	} else {
		UnpunishIdentity(type, target, reason, nick, setByAuth, IRCCommand_Unpunish_Identity_Result);
	}
	return Plugin_Handled;
}

public IRCCommand_Unpunish_Client_Result(targetClient, result, String:adminName[], String:adminAuth[]) {
	decl String:targetName[64];
	GetClientName(targetClient, targetName, sizeof(targetName));
	IRCCommand_Unpunish_Identity_Result(targetName, result, adminName, adminAuth);
}

public IRCCommand_Unpunish_Identity_Result(String:identity[], result, String:adminName[], String:adminAuth[]) {
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
