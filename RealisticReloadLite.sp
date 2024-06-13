//========================================================================================
// INCLUDES
//========================================================================================

#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <sdkhooks>

//========================================================================================
// HANDLES & VARIABLES
//========================================================================================

new const String:PLUGIN_VERSION[4] = "1.4";

enum guntype                                             // 不同武器类别，对应不同换弹情形
{    
    GUNTYPE_NONE = 0,                                    // guntype默认值，即武器分类上不属于枪（炸弹、匕首、投掷物）
    GUNTYPE_SHOTGUN,                                     // 霰弹枪单独拿出来作为一类，没有+1功能
    GUNTYPE_CLOSEDBOLT,                                  // 闭膛待击，大部分枪以及盾牌插件属于这一类，允许+1功能
    GUNTYPE_CLOSEDBOLT_DUAL,                             // 闭膛待击且双枪，仅双枪，允许+1/+2功能
    GUNTYPE_OPENBOLT                                     // 开膛待击，没有+1功能，少数武器属于这一类，例如原版的m249/mac10
}

enum gunstatus                                           // PostThinkHook会高频率执行，需要根据这些“状态”便于进行分支跳转
{
    GUNSTATUS_NONE = 0,                                  // 不换弹时，都保持这个状态
    GUNSTATUS_RELOAD,                                    // 打空了，换弹的时候弹膛里没有子弹，直接原版换弹结束，不需要后处理过程
    GUNSTATUS_RELOADWITHCHAMBERBULLET,                   // 换弹的时候，弹膛里有1发子弹，需要后处理过程
    GUNSTATUS_RELOADWITHCHAMBERBULLET2                   // 换弹的时候，弹膛里有2发子弹，需要后处理过程
}

new bool:g_bfreezetime = false;                          // 回合刚开始的冷却时间阶段不允许换弹，用一个bool值表示是否处于该阶段

new latestammo[2048];                                    // 倒数第二次执行PostThinkHook函数后，紧接的是原版换弹，这会改变ammo值，因此需要latestammo记住原版换弹前弹膛内有几发子弹
new WeaponsMaxClip[2048] = {0};                          // 用来记录弹匣容量（获取maxclip新方法，不用SDKCall）
new Float:lastPrintTime[MAXPLAYERS+1] = {0.0};           // 记录上一次满弹PrintToChat的时间，用于避免满弹提示在聊天区刷屏
new guntype:g_guntype[2048];
new gunstatus:g_gunstatus[2048];

new bool:isEnabled;
new bool:isEnabledAdjustment;
new bool:isEnabledMessage;
new whichEliteGuntype;
static char WeaponToClosedbolt[2048];
static char WeaponToOpenbolt[2048];
static char WeaponToUntreat[2048];

new Handle:cvarEnable;
new Handle:cvarEnableAdjustment;
new Handle:cvarEnableMessage;
new Handle:cvarEliteGuntype;
new Handle:cvarToClosedbolt;
new Handle:cvarToOpenbolt;
new Handle:cvarToUntreat;

//========================================================================================
//========================================================================================

public Plugin:myinfo = 
{
    name = "RealisticReloadLite(RrL)",                                           // RealisticReload -> RealisticReloadLite(RrL)
    author = "Ducheese,javalia",                                                 // javalia(original/hardcore version) -> Ducheese(lite/friendly/semi-realistic version)
    description = "Lite version for Realistic Reload, aka one in the chamber",   // original descriptions: remove remaining bullets on magazine when reload for realistic reload
    version = PLUGIN_VERSION, 
    url = "https://space.bilibili.com/1889622121"
}

public OnPluginStart()
{
    CreateConVar("sm_rrl_lite_version", PLUGIN_VERSION, "插件版本", FCVAR_PROTECTED);
    cvarEnable = CreateConVar("sm_rrl_enable", "1", "是否启用插件（1：启用；0：禁用）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    cvarEnableAdjustment = CreateConVar("sm_rrl_enable_adjustment", "0", "在满弹匣弹膛的情况下，按R键后的动作调整（1：强制v模保持静置状态，即idle动作；0：可能出现不符预期的动作）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    cvarEnableMessage = CreateConVar("sm_rrl_enable_message", "1", "是否启用聊天区满弹匣弹膛提示（1：启用；0：禁用）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    cvarEliteGuntype = CreateConVar("sm_rrl_elite_guntype", "2", "双枪的归类在此处决定，修改将在新购买的武器上生效（2：有两把枪且闭膛待击，允许+2；1：使用了盾牌插件，只有一把枪且闭膛待击，允许+1；0：开膛待击，弹膛里不会留子弹）", FCVAR_NOTIFY, true, 0.0, true, 2.0);
    cvarToClosedbolt = CreateConVar("sm_rrl_to_closedbolt", "", "需要特别转换成闭膛待击（close-bolt）的武器名单，该名单优先有效，支持加枪插件添加的新武器名，输入上限为2048个字符，修改将在新购买的武器上生效（输入例子：weapon_mac10;weapon_m249）", FCVAR_NOTIFY);
    cvarToOpenbolt = CreateConVar("sm_rrl_to_openbolt", "", "需要特别转换成开膛待击（open-bolt）的武器名单，支持加枪插件添加的新武器名，输入上限为2048个字符，修改将在新购买的武器上生效（输入例子：weapon_deagle;weapon_tmp）", FCVAR_NOTIFY);
    cvarToUntreat = CreateConVar("sm_rrl_to_untreat", "", "不经插件处理、保持原版换弹的武器名单，以霰弹枪为父类的加枪插件武器应该填在此处，输入上限为2048个字符，修改将在新购买的武器上生效（输入例子：weapon_mk2）", FCVAR_NOTIFY);
    
    AutoExecConfig(true, "plugin.realistic_reload_lite");         // 配置文件.cfg里写着的才是进游戏时的初始参数设置，控制台修改的结果并不会保存

    HookConVarChange(cvarEnable, CvarChange);
    HookConVarChange(cvarEnableAdjustment, CvarChange);
    HookConVarChange(cvarEnableMessage, CvarChange);
    HookConVarChange(cvarEliteGuntype, CvarChange);
    HookConVarChange(cvarToClosedbolt, CvarChange);
    HookConVarChange(cvarToOpenbolt, CvarChange);
    HookConVarChange(cvarToUntreat, CvarChange);

    HookEvent("round_end", EventRoundEnd);
    HookEvent("round_freeze_end", EventRoundFreezeEnd);
}

public OnConfigsExecuted()
{
    isEnabled = GetConVarBool(cvarEnable);
    isEnabledAdjustment = GetConVarBool(cvarEnableAdjustment);
    isEnabledMessage = GetConVarBool(cvarEnableMessage);
    whichEliteGuntype = GetConVarInt(cvarEliteGuntype);
    GetConVarString(cvarToClosedbolt, WeaponToClosedbolt, sizeof(WeaponToClosedbolt));
    GetConVarString(cvarToOpenbolt, WeaponToOpenbolt, sizeof(WeaponToOpenbolt));
    GetConVarString(cvarToUntreat, WeaponToUntreat, sizeof(WeaponToUntreat));
}

public CvarChange(Handle:convar, const String:oldValue[], const String:newValue[])
{
    if(convar == cvarEnable)
    {
        if(StringToInt(newValue) == 1)
        {
            isEnabled = true;
            PrintToChatAll("\x04[RrL] \x03插件功能已开启");
        }
        else if(StringToInt(newValue) == 0)
        {
            isEnabled = false;
            PrintToChatAll("\x04[RrL] \x03插件功能已关闭");
        }
    }
    else if(convar == cvarEnableAdjustment)
    {
        if(StringToInt(newValue) == 1)
        {
            isEnabledAdjustment = true;
            PrintToChatAll("\x04[RrL] \x03功能已开启, 当在满弹匣弹膛的情况下按R键时, 将强制v模保持静置状态");
        }
        else if(StringToInt(newValue) == 0)
        {
            isEnabledAdjustment = false;
            PrintToChatAll("\x04[RrL] \x03功能已关闭, 当在满弹匣弹膛的情况下按R键时, 可能出现不符预期的动作");
        }
    }
    else if(convar == cvarEnableMessage)
    {
        if(StringToInt(newValue) == 1)
        {
            isEnabledMessage = true;
            PrintToChatAll("\x04[RrL] \x03满弹匣弹膛提示已开启");
        }
        else if(StringToInt(newValue) == 0)
        {
            isEnabledMessage = false;
            PrintToChatAll("\x04[RrL] \x03满弹匣弹膛提示已关闭");
        }
    }
    else if(convar == cvarEliteGuntype)
    {
        if(StringToInt(newValue) == 2)
        {
            whichEliteGuntype = 2;
            PrintToChatAll("\x04[RrL] \x03双枪已归类为+2闭膛待击武器, 修改将在新购买的武器上生效");
        }
        else if(StringToInt(newValue) == 1)
        {
            whichEliteGuntype = 1;
            PrintToChatAll("\x04[RrL] \x03双枪已归类为+1闭膛待击武器, 修改将在新购买的武器上生效");
        }
        else if(StringToInt(newValue) == 0)
        {
            whichEliteGuntype = 0;
            PrintToChatAll("\x04[RrL] \x03双枪已归类为开膛待击武器, 修改将在新购买的武器上生效");
        }
    }
    else if(convar == cvarToClosedbolt)
    {
        if(StrContains(newValue, "weapon_", false) != -1)
        {
            strcopy(WeaponToClosedbolt, strlen(newValue) + 1, newValue);
            PrintToChatAll("\x04[RrL] \x03转闭膛待击武器名单已更新为: %s, 修改将在新购买的武器上生效", WeaponToClosedbolt);
        }
        else if(StrEqual("", newValue) || StrContains(newValue, "weapon_", false) == -1)
        {
            strcopy(WeaponToClosedbolt, strlen(newValue) + 1, newValue);
            PrintToChatAll("\x04[RrL] \x03转闭膛待击武器名单已清空, 修改将在新购买的武器上生效");
        }
    }
    else if(convar == cvarToOpenbolt)
    {
        if(StrContains(newValue, "weapon_", false) != -1)
        {
            strcopy(WeaponToOpenbolt, strlen(newValue) + 1, newValue);
            PrintToChatAll("\x04[RrL] \x03转开膛待击武器名单已更新为: %s, 修改将在新购买的武器上生效", WeaponToOpenbolt);        
        }
        else if(StrEqual("", newValue) || StrContains(newValue, "weapon_", false) == -1)
        {
            strcopy(WeaponToOpenbolt, strlen(newValue) + 1, newValue);
            PrintToChatAll("\x04[RrL] \x03转开膛待击武器名单已清空, 修改将在新购买的武器上生效");
        }
    }
    else if(convar == cvarToUntreat)
    {
        if(StrContains(newValue, "weapon_", false) != -1)
        {
            strcopy(WeaponToUntreat, strlen(newValue) + 1, newValue);
            PrintToChatAll("\x04[RrL] \x03保持原版换弹的武器名单已更新为: %s, 修改将在新购买的武器上生效", WeaponToUntreat);        
        }
        else if(StrEqual("", newValue) || StrContains(newValue, "weapon_", false) == -1)
        {
            strcopy(WeaponToUntreat, strlen(newValue) + 1, newValue);
            PrintToChatAll("\x04[RrL] \x03保持原版换弹的武器名单已清空, 修改将在新购买的武器上生效");
        }
    }
}

public OnEntityCreated(int entity, const String:classname[])
{
    if(entity >= 0 && entity <= 2047)
    {
        g_gunstatus[entity] = GUNSTATUS_NONE;
        latestammo[entity] = 0;
        /*
            获取武器的弹匣容量maxclip。需要延时执行，实体刚创建的时候，很多属性没有创建。
            现在确认guntype也要延时执行了，加枪插件改classname有点慢。
        */
        if(StrContains(classname, "weapon_", false) != -1)     // 过滤出武器实体
            CreateTimer(0.5, Timer_GetMaxClip, entity);
    }
}

public OnMapStart()
{
    for(int client = 1; client <= MaxClients; client++)
    {
        lastPrintTime[client] = 0.0;                             // 换地图时并不会自动初始化这个数组，手动重置一下（不需要每回合重置）
    }
}


//========================================================================================
// HOOK
//========================================================================================

public Action:EventRoundEnd(Handle:Event_End, const String:Name[], bool:Broadcast)
{
    for(int client = 1; client <= MaxClients; client++)
    {
        if(IsClientInGame(client))
        {
            for(int i = 0; i < 48; i++)                          // 不知道为什么是48，可能MyWeapons的参数范围是0~47
            {
                new weapon = GetEntPropEnt(client, Prop_Data, "m_hMyWeapons", i);
                
                if(weapon != -1)
                    g_gunstatus[weapon] = GUNSTATUS_NONE;        // 新的回合，所有client的MyWeapons武器实体的status都初始化
            }
        }
    }
    g_bfreezetime = true;                                        // 冷却时间阶段，g_bfreezetime的值都保持true，在此期间插件不工作
}

public Action:EventRoundFreezeEnd(Handle:Event_Freeze, const String:Name[], bool:Broadcast)
{
    g_bfreezetime = false;
}

public OnClientPutInServer(int client)
{
    /* 
        具体流程是这样的：
        按R换弹 -> 一次prethink进行前处理（玩家看到弹匣变成1，剩余弹药加进备弹量中）-> 当前弹匣小于30，满足触发原版换弹的条件
        -> 循环多次postthink后处理（无数次post直到原版换弹结束，得到原版换弹计算出的弹匣和备弹量 -> 最后一次post根据弹膛内情况重新计算弹匣和备弹量）
    */
    if(!IsFakeClient(client))
    {
        /*
            对bot和玩家做出了区分，bot是没有PreThink过程的。作者原话如下：
            Bots doesn't need any handling about this. If we try to handle this, bots will do unexpected reload on freezetime.
            如果PreThinkHook开放给bots，开局冷却时间阶段，bots会做预料之外的换弹。

            想要触发换弹动作，那么必须先让当前子弹量就小于弹匣容量，所以需要PreThink前处理。
            比如原版30发按R无效，因此PreThink先把30发变成了1发，然后才能触发原版换弹。
            然而原版将31发也视为按R键有效的状态，需要特别阻止其换弹动作的发生。
        */
        SDKHook(client, SDKHook_PreThink, PreThinkHook);
    }
    SDKHook(client, SDKHook_PostThink, PostThinkHook);
}

public PreThinkHook(int client)
{                                                             
    new buttons = GetEntProp(client, Prop_Data, "m_nButtons");

    if(IsPlayerAlive(client))
    {
        if(buttons & IN_RELOAD && ~buttons & IN_ATTACK && !g_bfreezetime && isEnabled)
        {    
            new weapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");

            if(weapon != -1 && g_gunstatus[weapon] == GUNSTATUS_NONE
            && GetEntPropFloat(weapon, Prop_Data, "m_flNextPrimaryAttack") <= GetGameTime()    // 这两行的意思我不懂
            && GetEntPropFloat(client, Prop_Data, "m_flNextAttack") <= GetGameTime()
            && !GetEntProp(weapon, Prop_Data, "m_bInReload"))
            {
                new ammotype = GetEntProp(weapon, Prop_Data, "m_iPrimaryAmmoType");    // 获取ActiveWeapon的子弹类别的索引，-1估计就是没有子弹，不是枪，那也没有后续处理了
                
                if(ammotype != -1)
                {
                    new reservedammo = GetEntProp(client, Prop_Data, "m_iAmmo", 4, ammotype);    // 输入某种子弹的索引，获取该子弹的剩余子弹量（"m_iAmmo"是指备弹量，不包括当前弹匣）
                    new ammo = GetEntProp(weapon, Prop_Data, "m_iClip1");                        // 当前弹匣子弹数量

                    if(reservedammo >= 1)
                    {
                        if(g_guntype[weapon] == GUNTYPE_CLOSEDBOLT)
                        {
                            if(ammo > 1)                                              // 为了实现1，就需要在这里加上一个判断条件：弹匣满时（30+1）无效，为此需要有变量记住一个满弹匣的容量
                            {    
                                SetEntProp(client, Prop_Data, "m_iAmmo", reservedammo + ammo - 1, 4, ammotype);
                                SetEntProp(weapon, Prop_Data, "m_iClip1", 1);         // 让枪的当前弹匣量变成1，这个操作直接导致子弹丢失。为留住这部分，需要修改m_iAmmo
                                latestammo[weapon] = 1; 
                            }  
                        }
                        else if(g_guntype[weapon] == GUNTYPE_CLOSEDBOLT_DUAL)
                        {
                            if(ammo > 2)
                            {
                                SetEntProp(client, Prop_Data, "m_iAmmo", reservedammo + ammo - 2, 4, ammotype);
                                SetEntProp(weapon, Prop_Data, "m_iClip1", 2);
                                latestammo[weapon] = 2;
                            }
                        }
                        else if(g_guntype[weapon] == GUNTYPE_OPENBOLT)
                        {
                            SetEntProp(client, Prop_Data, "m_iAmmo", reservedammo + ammo - 0, 4, ammotype);
                            SetEntProp(weapon, Prop_Data, "m_iClip1", 0);
                        }
                    }
                }
            }
        }
    }
}

public PostThinkHook(int client)
{
    if(IsPlayerAlive(client))
    {
        new weapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon"); 

        if(weapon != -1)
        {
            new ammo = GetEntProp(weapon, Prop_Data, "m_iClip1");                    // 是经过PreThinkHook的SetEntProp后的ammo，要么ammo=0，要么ammo=1或2

            /*
                "m_bInReload"这个变量，在换弹过程中一直是1，换弹动作结束了才会变成0，脱离这个if分支。
                这个分支的作用，可能是对PreThinkHook所做的变化进行延续，并且更新g_gunstatus数组（还有一点，是给bots用的）。
                跳出这个分支的时候，原版换弹也就完成了，进入剩下三个分支是最后一次后处理过程。
            */
            if(GetEntProp(weapon, Prop_Data, "m_bInReload") && !g_bfreezetime && isEnabled)
            {
                new ammotype = GetEntProp(weapon, Prop_Data, "m_iPrimaryAmmoType");
                new reservedammo = GetEntProp(client, Prop_Data, "m_iAmmo", 4, ammotype);
                
                if(g_guntype[weapon] == GUNTYPE_CLOSEDBOLT)
                {
                    if(ammo >= 1)      // 弹膛里有1发子弹的情况
                    {
                        SetEntProp(client, Prop_Data, "m_iAmmo", reservedammo + ammo - 1, 4, ammotype);
                        SetEntProp(weapon, Prop_Data, "m_iClip1", 1);
                        latestammo[weapon] = 1;
                        g_gunstatus[weapon] = GUNSTATUS_RELOADWITHCHAMBERBULLET;
                    }
                    else
                    {              
                        g_gunstatus[weapon] = GUNSTATUS_RELOAD;    // 打空了，原版换弹结束即可，不需要后处理
                    }
                }
                else if(g_guntype[weapon] == GUNTYPE_CLOSEDBOLT_DUAL)
                {
                    if(ammo >= 2)
                    {
                        SetEntProp(client, Prop_Data, "m_iAmmo", reservedammo + ammo - 2, 4, ammotype);
                        SetEntProp(weapon, Prop_Data, "m_iClip1", 2);
                        latestammo[weapon] = 2;
                        g_gunstatus[weapon] = GUNSTATUS_RELOADWITHCHAMBERBULLET2;
                    }
                    else if(ammo == 1)
                    {
                        latestammo[weapon] = 1;
                        g_gunstatus[weapon] = GUNSTATUS_RELOADWITHCHAMBERBULLET;
                    }
                    else
                    {
                        g_gunstatus[weapon] = GUNSTATUS_RELOAD;
                    }
                }
                else if(g_guntype[weapon] == GUNTYPE_OPENBOLT)
                {
                    SetEntProp(client, Prop_Data, "m_iAmmo", reservedammo + ammo - 0, 4, ammotype);
                    SetEntProp(weapon, Prop_Data, "m_iClip1", 0);
                    g_gunstatus[weapon] = GUNSTATUS_RELOAD;
                }
            }
            else if(g_gunstatus[weapon] == GUNSTATUS_RELOADWITHCHAMBERBULLET)      // 弹膛里有1发子弹的情况的后处理
            {
                if(ammo > latestammo[weapon])                                      // 此处的ammo是原版换弹之后的ammo
                {
                    new ammotype = GetEntProp(weapon, Prop_Data, "m_iPrimaryAmmoType");
                    new reservedammo = GetEntProp(client, Prop_Data, "m_iAmmo", 4, ammotype);
                    
                    if(reservedammo >= 1)
                    {
                        SetEntProp(weapon, Prop_Data, "m_iClip1", GetEntProp(weapon, Prop_Data, "m_iClip1") + 1);
                        SetEntProp(client, Prop_Data, "m_iAmmo", reservedammo - 1, 4, ammotype);
                    }
                    
                    g_gunstatus[weapon] = GUNSTATUS_NONE;
                }
            }
            else if(g_gunstatus[weapon] == GUNSTATUS_RELOADWITHCHAMBERBULLET2)
            {
                if(ammo > latestammo[weapon])
                {
                    new ammotype = GetEntProp(weapon, Prop_Data, "m_iPrimaryAmmoType");
                    new reservedammo = GetEntProp(client, Prop_Data, "m_iAmmo", 4, ammotype);
                    
                    if(reservedammo >= 2)
                    {
                        SetEntProp(weapon, Prop_Data, "m_iClip1", GetEntProp(weapon, Prop_Data, "m_iClip1") + 2);
                        SetEntProp(client, Prop_Data, "m_iAmmo", reservedammo - 2, 4, ammotype);
                    }
                    else if(reservedammo == 1)
                    {
                        SetEntProp(weapon, Prop_Data, "m_iClip1", GetEntProp(weapon, Prop_Data, "m_iClip1") + 1);
                        SetEntProp(client, Prop_Data, "m_iAmmo", reservedammo - 1, 4, ammotype);
                    }
                    
                    g_gunstatus[weapon] = GUNSTATUS_NONE;
                }
            }
            else if(g_gunstatus[weapon] == GUNSTATUS_RELOAD)
            {
                g_gunstatus[weapon] = GUNSTATUS_NONE;
            }
        } 
    }
}

public Action:OnPlayerRunCmd(int client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
    if(IsPlayerAlive(client))
    {
        if(buttons & IN_RELOAD && isEnabled)
        {
            new iActiveWeapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");

            if(iActiveWeapon != -1)
            {
                new ammotype = GetEntProp(iActiveWeapon, Prop_Data, "m_iPrimaryAmmoType");

                if(ammotype != -1)
                {
                    new ammo = GetEntProp(iActiveWeapon, Prop_Data, "m_iClip1");
                    // new maxclip = GetMaxClip1(iActiveWeapon);                                 // 如果获取不到maxclip，控制台的报错会刷屏，游戏会严重掉帧（因此不用SDKCall函数来获取武器的弹匣容量）

                    new maxclip = WeaponsMaxClip[iActiveWeapon];

                    if(g_guntype[iActiveWeapon] == GUNTYPE_CLOSEDBOLT)
                    {
                        if(ammo == (maxclip+1))
                        {
                            buttons &= ~IN_RELOAD;                                              // 强制修改R键为没有输入的状态，即阻止换弹（可能还是有换弹动作）
                            WaitTimeSwitchIdle(client, iActiveWeapon);                           // 强制回到idle动作
                        }
                    }
                    else if(g_guntype[iActiveWeapon] == GUNTYPE_CLOSEDBOLT_DUAL)
                    {
                        if(ammo == (maxclip+2))
                        {
                            buttons &= ~IN_RELOAD;
                            WaitTimeSwitchIdle(client, iActiveWeapon);
                        }
                    }
                    else if(g_guntype[iActiveWeapon] == GUNTYPE_OPENBOLT)
                    {
                        if(ammo == maxclip)
                        {
                            buttons &= ~IN_RELOAD;
                            WaitTimeSwitchIdle(client, iActiveWeapon);
                        }
                    }
                }
            }
        }
    }

    return Plugin_Continue;
} 

//========================================================================================
// TIMER
//========================================================================================

public Action:Timer_GetMaxClip(Handle timer, int entity)
{
    if(!IsValidEntity(entity)) return Plugin_Continue;      // 0.5后变成了无效实体是有可能的

    decl String:classname[64];
    GetEntityClassname(entity, classname, sizeof(classname));
    /*
        两类名单的处理，可支持加枪插件添加的新武器名。
    */
    if(StrContains(WeaponToClosedbolt, classname, false) != -1)         // 必须要有 != -1，否则分支判断结果完全不符合预期
    {
        g_guntype[entity] = GUNTYPE_CLOSEDBOLT;
    }
    else if(StrContains(WeaponToOpenbolt, classname, false) != -1)
    {
        g_guntype[entity] = GUNTYPE_OPENBOLT;
    }
    else if(StrContains(WeaponToUntreat, classname, false) != -1)
    {
        g_guntype[entity] = GUNTYPE_SHOTGUN;
    }
    else if(StrEqual(classname, "weapon_m3", false) || StrEqual(classname, "weapon_xm1014", false))
    {
        g_guntype[entity] = GUNTYPE_SHOTGUN; 
    }
    else if(StrEqual(classname, "weapon_m249", false) || StrEqual(classname, "weapon_mac10", false))
    {
        g_guntype[entity] = GUNTYPE_OPENBOLT;
    }
    else if(StrEqual(classname, "weapon_elite", false))
    {
        if(whichEliteGuntype == 2)
        {
            g_guntype[entity] = GUNTYPE_CLOSEDBOLT_DUAL;
        }
        else if(whichEliteGuntype == 1)
        {
            g_guntype[entity] = GUNTYPE_CLOSEDBOLT;    // 盾牌插件
        }
        else
        {
            g_guntype[entity] = GUNTYPE_OPENBOLT;      // 例如双枪左轮
        }
    }
    else if(StrContains(classname, "weapon_", false) != -1)
    {
        /*
            这里没有对非枪械武器做出处理，但是RR插件作者写了一段注释：
            This can be looks weird because it sets entity to closed bolt guns, even in case the entity is not even weapon.
            But it will not make problem.
        */
        g_guntype[entity] = GUNTYPE_CLOSEDBOLT;
    }

    if(StrContains(classname, "weapon_", false) != -1 && !StrEqual(classname, "weapon_knife", false))    // 0.5秒的时间差，有一些莫名其妙的实体避开了OnEntityCreated的if过滤导致报错
    {
        new ammotype = GetEntProp(entity, Prop_Data, "m_iPrimaryAmmoType");     // 武器里除了匕首外都有ammotype，高爆雷的ammotype号是11

        if(ammotype != -1)
        {
            new ammo = GetEntProp(entity, Prop_Data, "m_iClip1");
            WeaponsMaxClip[entity] = ammo;
        }
    }

    return Plugin_Continue;
}

public Action:Timer_SetIdle(Handle timer, int weapon)
{
    SetEntPropFloat(weapon, Prop_Send, "m_flTimeWeaponIdle", 0.0);          // 意思可能是将距离下一次idle的时间设为0，也就是强制idle了
}

//========================================================================================
// FUCTIONS
//========================================================================================

void WaitTimeSwitchIdle(int client, int weapon)
{
    float currentTime = GetGameTime();
    float lastPrint = lastPrintTime[client];                                // 必须要先new一个变量来接收，否则减出来的总是0.0

    if ((currentTime-lastPrint)>3.0 && isEnabledMessage)                    // 避免PrintToChat刷屏，最小间隔3s才会出现下一条
    {
        PrintToChat(client, "\x04[RrL] \x03弹匣弹膛已满");
        lastPrintTime[client] = currentTime;
    }

    if(isEnabledAdjustment)
        CreateTimer(0.0, Timer_SetIdle, weapon);
}

/* int GetMaxClip1(weapon)
{
    new Handle:hCall= EndPrepSDKCall();
    new value = SDKCall(hCall, weapon);
    // PrintToChatAll("weapon index %i SDKCall GetMaxClip1 return value %i", weapon, value);    // 返回值正确
    CloseHandle(hCall);

    return value;
} */


