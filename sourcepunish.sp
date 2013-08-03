//TODO: Record stuff to DB

#include <sourcemod>
#include <sdktools>
#include <sourcepunish>

public Plugin:myinfo = {
    name = "SourcePunish",
    author = "Alex",
    description = "Punishment management system",
    version = "0.02",
    url = ""
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

public OnPluginStart() {
	punishments = CreateTrie();
	LoadTranslations("common.phrases");
	RegAdminCmd("sm_punish", Command_Punish, ADMFLAG_GENERIC, "Punishes a player");
}

public Action:Command_Punish(client, args) {
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

	decl String:setBy[64];
	GetClientName(client, setBy, sizeof(setBy));

	for (new i = 0; i < target_count; i++) {
		Call_StartForward(pmethod[addCallback]);
		Call_PushCell(target_list[i]);
		Call_PushString(reason);
		decl result;
		Call_Finish(result);

		if (!(pmethod[flags] & SP_NOREMOVE) && !(pmethod[flags] & SP_NOTIME) && !StrEqual(time, "0")) {
			new Handle:punishmentInfoPack = CreateDataPack();
			WritePackString(punishmentInfoPack, type);
			WritePackCell(punishmentInfoPack, target_list[i]);
			WritePackString(punishmentInfoPack, setBy);
			WritePackCell(punishmentInfoPack, GetTime());
			ResetPack(punishmentInfoPack); // Move index back to beginning so we can read from it.
			punishmentRemovalTimers[target_list[i]] = CreateTimer(StringToFloat(time) * 60, PunishmentExpire, punishmentInfoPack);
		}
	}

	ReplyToCommand(client, "[SM] Punish %s with %s for %s minutes because %s", target, type, time, reason);
	return Plugin_Handled;
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
