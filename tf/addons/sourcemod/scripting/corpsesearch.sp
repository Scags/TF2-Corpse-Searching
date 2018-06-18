#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>

#define MAX_EDICT_BITS 		11
#define MAX_EDICTS 			(1 << MAX_EDICT_BITS)	// https://github.com/ValveSoftware/source-sdk-2013/blob/master/mp/src/public/const.h

methodmap HUD < Handle
{
	public HUD()
	{
		return view_as< HUD >(CreateHudSynchronizer());
	}
	public int Show( int client, const char[] message, any ... )
	{
		char buffer[220];	// Max HUD length
		VFormat(buffer, sizeof(buffer), message, 4);
		return ShowSyncHudText(client, this, buffer);
	}
	public void Clear( int client )
	{
		ClearSyncHud(client, this);
	}
};

HUD
	hSearchHud
;

int
	iPrimary[MAX_EDICTS],	// Primary clip to store in corpses
	iSecondary[MAX_EDICTS],	// Secondary clip to store in corpses
	iSearchTime[MAXPLAYERS+1],
	iRagdoll[MAXPLAYERS+1],
	iTempRag[MAXPLAYERS+1],
	iGatheredPrimary[MAXPLAYERS+1],
	iGatheredSecondary[MAXPLAYERS+1]
;

bool
	bSearching[MAXPLAYERS+1]
;

public void OnPluginStart()
{
	for (int i = MaxClients; i; --i)
		if (IsClientInGame(i))
			OnClientPutInServer(i);

	hSearchHud = new HUD();
	HookEvent("player_death", OnPlayerDied);
}

public void OnMapStart()
{
	PrecacheSound("weapons/default_reload.wav");
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_PreThinkPost, OnThink);
	bSearching[client] = false;
	iSearchTime[client] = 0;
	iRagdoll[client] = 0;
	iTempRag[client] = 0;
	iGatheredPrimary[client] = 0;
	iGatheredSecondary[client] = 0;
}

public void OnEntityCreated(int ent, const char[] classname)
{
	if (!strcmp(classname, "tf_ammo_pack", false))	// Spawned packs on death
		SDKHook(ent, SDKHook_Spawn, OnAmmoSpawn);
}

public Action OnAmmoSpawn(int ent)
{
	AcceptEntityInput(ent, "Kill");
	return Plugin_Handled;
}

public Action OnPlayerDied(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!(0 < client <= MaxClients))
		return Plugin_Continue;

	int wep, prim, sec, offset;

	// Gather ammo for both slots
	wep = GetPlayerWeaponSlot(client, 0);
	if (!IsValidEntity(wep))
		prim = 0;
	else
	{
		offset = GetEntProp(wep, Prop_Send, "m_iPrimaryAmmoType", 1)*4;
		prim = GetEntData(client, FindSendPropInfo("CTFPlayer", "m_iAmmo") + offset, 4);
	}

	wep = GetPlayerWeaponSlot(client, 1);
	if (!IsValidEntity(wep))
		sec = 0;
	else
	{
		offset = GetEntProp(wep, Prop_Send, "m_iPrimaryAmmoType", 1)*4;
		sec = GetEntData(client, FindSendPropInfo("CTFPlayer", "m_iAmmo") + offset, 4);
	}

	// Clamp
	if (prim < 0)
		prim = 0;
	if (sec < 0)
		sec = 0;

	DataPack pack;

	CreateDataTimer(0.1, RagDollTimer, pack);
	pack.WriteCell(client);
	pack.WriteCell(prim);
	pack.WriteCell(sec);

	return Plugin_Continue;
}

public Action RagDollTimer(Handle timer, DataPack pack)
{
	pack.Reset();

	int client = pack.ReadCell();
	if (!IsClientInGame(client))
		return Plugin_Continue;

	int rag = GetEntPropEnt(client, Prop_Send, "m_hRagdoll");
	if (!IsValidEntity(rag) 
	  || GetEntProp(rag, Prop_Send, "m_bFeignDeath")
	  || GetEntProp(rag, Prop_Send, "m_bBecomeAsh")
	  || GetEntProp(rag, Prop_Send, "m_bGib"))
		return Plugin_Continue;

	int prim = pack.ReadCell();
	int sec = pack.ReadCell();

	iPrimary[rag] = prim;
	iSecondary[rag] = sec;

	return Plugin_Continue;
}

public void OnThink(int client)
{
	if (!IsPlayerAlive(client))
		return;

	if ((GetClientButtons(client) & IN_RELOAD) && !bSearching[client])
	{
		float vecPos[3]; GetClientEyePosition(client, vecPos);
		float vecEyes[3]; GetClientEyeAngles(client, vecEyes);
		float vecRag[3];

		int ent = -1;
		while ((ent = FindEntityByClassname(ent, "tf_ragdoll")) != -1)
		{
			if (GetEntProp(ent, Prop_Send, "m_bFeignDeath")
			 || GetEntProp(ent, Prop_Send, "m_bBecomeAsh")
			 || GetEntProp(ent, Prop_Send, "m_bGib"))
				continue;

			GetEntPropVector(ent, Prop_Send, "m_vecRagdollOrigin", vecRag);
			if (GetVectorDistance(vecRag, vecPos) > 200.0)
				continue;

			iTempRag[client] = ent;	// Disgusting...

			TR_TraceRayFilter(vecPos, vecEyes, MASK_SHOT, RayType_Infinite, Filter1, client);
			if (!TR_DidHit())
				continue;

			bSearching[client] = true;
			iRagdoll[client] = ent;
			iTempRag[client] = 0;
			SetHudTextParams(-1.0, 0.52, 0.2, 100, 100, 100, 255, 0, 0.0, 0.0, 0.0);
			hSearchHud.Show(client, "|");
			iSearchTime[client]++;
			CreateTimer(0.1, UpdateSearchHud, GetClientUserId(client), TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
			break;	// No point in continuing through the loop
		}
	}
}

public bool Filter1(int ent, int mask, any data)
{
	if (ent != iTempRag[data])
		return false;

	return ent != data;
}

public Action UpdateSearchHud(Handle timer, any id)
{
	int client = GetClientOfUserId(id);

	if (!IsClientInGame(client) || !IsPlayerAlive(client) || !IsValidEntity(iRagdoll[client]))
	{
		ClearTimerStuff(client);
		return Plugin_Stop;
	}

	if (!(GetClientButtons(client) & IN_RELOAD))
	{
		ClearTimerStuff(client);
		hSearchHud.Clear(client);
		return Plugin_Stop;
	}

	float vecPos[3]; GetClientEyePosition(client, vecPos);
	float vecRag[3]; GetEntPropVector(iRagdoll[client], Prop_Send, "m_vecRagdollOrigin", vecRag);
	if (GetVectorDistance(vecRag, vecPos) > 200.0)
	{
		ClearTimerStuff(client);
		hSearchHud.Clear(client);
		return Plugin_Stop;
	}

	float vecEyes[3]; GetClientEyeAngles(client, vecEyes);

	TR_TraceRayFilter(vecPos, vecEyes, MASK_SHOT, RayType_Infinite, Filter2, client);
	if (!TR_DidHit())
	{
		ClearTimerStuff(client);
		hSearchHud.Clear(client);
		return Plugin_Stop;
	}

	char strProgressBar[128];
	iSearchTime[client]++;
	for (int i = 0; i <= iSearchTime[client]; ++i)
		strProgressBar[i] = '|';

	if (iSearchTime[client] == 10)
	{
		if (iPrimary[iRagdoll[client]] > 0)
		{
			int wep = GetPlayerWeaponSlot(client, 0);
			if (IsValidEntity(wep))
			{
				int prim = iPrimary[iRagdoll[client]];
				int offset = GetEntProp(wep, Prop_Send, "m_iPrimaryAmmoType", 1)*4;
				int ammotable = FindSendPropInfo("CTFPlayer", "m_iAmmo");
				int prim2 = GetEntData(client, FindSendPropInfo("CTFPlayer", "m_iAmmo") + offset, 4);

				if (prim2 != -1)
				{
					prim2 += prim;
					int max = GetEntData(client, FindDataMapInfo(client, "m_iAmmo")+4);
					if (prim2 > max)
						prim2 = max;

					SetEntData(client, ammotable+offset, prim2, 4, true);

					iGatheredPrimary[client] = prim;
				}
			}
			iPrimary[iRagdoll[client]] = 0;
		}
		EmitSoundToClient(client, "weapons/default_reload.wav");
	}
	else if (iSearchTime[client] == 20)
	{
		if (iSecondary[iRagdoll[client]] > 0)
		{
			int wep = GetPlayerWeaponSlot(client, 0);
			if (IsValidEntity(wep))
			{
				int sec = iSecondary[iRagdoll[client]];
				int offset = GetEntProp(wep, Prop_Send, "m_iPrimaryAmmoType", 1)*4;
				int ammotable = FindSendPropInfo("CTFPlayer", "m_iAmmo");
				int sec2 = GetEntData(client, ammotable + offset, 4);

				if (sec2 != -1)
				{
					sec2 += sec;
					int max = GetEntData(client, FindDataMapInfo(client, "m_iAmmo")+8);
					if (sec2 > max)
						sec2 = max;

					SetEntData(client, ammotable+offset, sec2, 4, true);

					iGatheredSecondary[client] = sec;
				}
			}
			iSecondary[iRagdoll[client]] = 0;
		}
		EmitSoundToClient(client, "weapons/default_reload.wav");
	}

	SetHudTextParams(-1.0, 0.52, 0.2, 100, 100, 100, 255, 0, 0.0, 0.0, 0.0);

	if (iGatheredPrimary[client])
		Format(strProgressBar, sizeof(strProgressBar), "%s\n+%d Primary", strProgressBar, iGatheredPrimary[client]);
	if (iGatheredSecondary[client])
		Format(strProgressBar, sizeof(strProgressBar), "%s\n+%d Secondary", strProgressBar, iGatheredSecondary[client]);

	hSearchHud.Show(client, strProgressBar);
	Action action = Plugin_Continue;
	if (iSearchTime[client] > 20)
	{
		action = Plugin_Stop;
		bSearching[client] = false;
	}

	return action;
}

public bool Filter2(int ent, int mask, any data)
{
	if (ent != iRagdoll[data])
		return false;

	return ent != data;
}

stock void ClearTimerStuff(const int client)
{
	bSearching[client] = false;
	iRagdoll[client] = 0;
	iSearchTime[client] = 0;
	iGatheredPrimary[client] = 0;
	iGatheredSecondary[client] = 0;
}