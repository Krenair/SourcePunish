#define SP_NOREMOVE 1
#define SP_NOTIME 1 << 1

functag SPACB public(client, String:reason[]); // SourcePunish Add CallBack
functag SPRCB public(client); // SourcePunish Remove CallBack
native bool:RegisterPunishment(String:type[], String:typeDisplayName[], SPACB:addCallback, SPRCB:removeCallback, flags = 0);

functag PunishmentRegisteredForward public(String:type[]);
native bool:AddToPunishmentRegisteredForward(PunishmentRegisteredForward:func);

native Handle:GetRegisteredPunishments();
