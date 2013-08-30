public SharedPlugin:__pl_sourcepunish = {
	name = "sourcepunish",
	file = "sourcepunish.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};
native PunishmentPluginUnload();

#define SP_NOREMOVE 1
#define SP_NOTIME 1 << 1

functag SPACB public(client, String:reason[]); // SourcePunish Add CallBack
functag SPRCB public(client); // SourcePunish Remove CallBack
native bool:RegisterPunishment(String:type[], String:typeDisplayName[], SPACB:addCallback, SPRCB:removeCallback, flags = 0);

forward PunishmentRegistered(String:type[], String:displayType[], flags);
forward PunishmentPluginUnloaded(String:type[]);

native Handle:GetRegisteredPunishmentTypeStrings();
native GetPunishmentTypeDisplayName(String:type[], String:buffer[], maxlen);
native GetPunishmentTypeFlags(String:type[]);

#define SP_SUCCESS 1
#define SP_ERROR_TARGET_ALREADY_PUNISHED 2
#define SP_ERROR_TARGET_NOT_PUNISHED 3
#define SP_ERROR_SQL 4
functag SPPRCBC public(targetClient, result, String:adminName[], String:adminAuth[], adminClient); // SourcePunish (Un)Punish Result CallBack (identified by client)
functag SPPRCBA public(String:identity[], result, String:adminName[], String:adminAuth[], adminClient); // SourcePunish (Un)Punish Result CallBack (identified by auth)
native PunishClient(String:type[], targetClient, durationMinutes, String:reason[], String:adminName[], String:adminAuth[], SPPRCBC:resultCallback, adminClientId = 0);
native PunishIdentity(String:type[], String:identity[], durationMinutes, String:reason[], String:adminName[], String:adminAuth[], SPPRCBA:resultCallback, adminClientId = 0);
native UnpunishClient(String:type[], targetClient, String:reason[], String:adminName[], String:adminAuth[], SPPRCBC:resultCallback, adminClient = 0);
native UnpunishIdentity(String:type[], String:identity[], String:reason[], String:adminName[], String:adminAuth[], SPPRCBA:resultCallback, adminClient = 0);
