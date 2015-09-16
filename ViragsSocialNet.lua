require "ICComm"
require "Apollo"
require "ApolloTimer"

-----------------------------------------------------------------------------------------------
-- ViragsSocial Broadcasting
-----------------------------------------------------------------------------------------------
local ViragsSocial = Apollo.GetAddon("ViragsSocial")
local JSON
local List = {}

ViragsSocial.ICCommLib_PROTOCOL_VERSION = 0.001

ViragsSocial.MSG_CODES = {
    ["REQUEST_INFO"] = 1,
    ["UPDATE_FOR_TARGET"] = 2,
    ["UPDATE_FOR_ALL"] = 3,

}

function ViragsSocial:InitComm()
    if self.tSettings.bDisableNetwork then return end

    self:DEBUG("InitComm()")

    JSON = Apollo.GetPackage("Lib:dkJSON-2.5").tPackage
    local arGuilds = GuildLib.GetGuilds()

    if arGuilds == nil then return end

    self.InfoChannels = {}

    for key, current in pairs(arGuilds) do
        local guildName = current:GetName()
        self:DEBUG("Setting up " .. guildName)
        if guildName and (current:GetType() == GuildLib.GuildType_Guild
                     or   current:GetType() == GuildLib.GuildType_Circle) then
            self:JoinChannel(guildName, current)
        end
    end
end

function ViragsSocial:JoinChannel(channelName, guild, tries)
    tries = tries or 3

    local newChannel = ICCommLib.JoinChannel("ViragsSocial" .. channelName, ICCommLib.CodeEnumICCommChannelType.Guild, guild)
    newChannel:SetJoinResultFunction("OnChannelJoin", self)

    if newChannel:IsReady() then
        newChannel:SetSendMessageResultFunction("OnMessageSent", self)
        newChannel:SetReceivedMessageFunction("OnMessageReceived", self)
        self.InfoChannels[channelName] = newChannel
    elseif tries > 0 then
        self:DEBUG("Retrying " .. tries)
        self:JoinChannel(channelName, guild, tries - 1)
    else
        self:DEBUG("Failed to join " .. channelName)
    end
end

function ViragsSocial:OnMessageSent(iccomm, eResult, idMessage)
    self:DEBUG("Message[" .. idMessage .. "] = " .. self:GetResult(eResult))
end

function ViragsSocial:OnMessageReceived(channel, msg, sSender)
  self:DEBUG("Received message from " .. channel:GetName())
  self:DEBUG("Message: " .. msg)

  local decoded = JSON.decode(msg)

  if self.MSG_CODES["REQUEST_INFO"] == decoded.MSG_CODE then
      self:BroadcastToTarget(channel, decoded.name)
      return
  end

  if not self:isUpToDateVersion(decoded) then return end

  local bNeedUpdateGrid = false

  if self.MSG_CODES["UPDATE_FOR_TARGET"] == decoded.MSG_CODE then
      bNeedUpdateGrid = decoded.target == self.kMyID
  elseif self.MSG_CODES["UPDATE_FOR_ALL"] == decoded.MSG_CODE then
      bNeedUpdateGrid = true
  end

  if bNeedUpdateGrid and self:ValidateBroadcast(decoded) then
      self.ktPlayerInfoDB[decoded.name] = decoded
      self:UpdateGrid(false, false)
  end
end

function ViragsSocial:OnChannelJoin(channel, eResult)
    self:DEBUG("Joined " .. channel:GetName() .. "[" .. self:GetResult(eResult) .. "]")
end

function ViragsSocial:GetResult(eResult)
    local sResult = tostring(eResult)

    for stext, key in next, ICCommLib.CodeEnumICCommMessageResult do
        if eResult == key then
            return stext
        end
    end
    return "Unknown Error"
end

--SEND MSG_CODES["UPDATE_FOR_ALL"]
function ViragsSocial:BroadcastUpdate()
    if self.InfoChannels then
        for key, channel in pairs(self.InfoChannels) do
            self:AddToBroadcastQueue(channel, self.MSG_CODES["UPDATE_FOR_ALL"], nil)
        end
    end
end

--SEND MSG_CODES["REQUEST_INFO"]
function ViragsSocial:BroadcastRequestInfo()

    if self.kbCanRequestFullUpdateBroadcast and self.InfoChannels then
        self.kbCanRequestFullUpdateBroadcast = false

        for key, channel in pairs(self.InfoChannels) do
            self:AddToBroadcastQueue(channel, self.MSG_CODES["REQUEST_INFO"], nil)
        end
    end
end

--SEND MSG_CODES["UPDATE_FOR_TARGET"]
function ViragsSocial:BroadcastToTarget(channel, target)
    if target and channel then
        self:AddToBroadcastQueue(channel, self.MSG_CODES["UPDATE_FOR_TARGET"], target)
    end
end

function ViragsSocial:AddToBroadcastQueue(channel, code, target)
    if code == self.MSG_CODES["REQUEST_INFO"]
            or code == self.MSG_CODES["UPDATE_FOR_TARGET"]
            or code == self.MSG_CODES["UPDATE_FOR_ALL"] then
        local queueValue = { tChannel = channel, nCode = code, strTarget = target }

        if self.msgQueue == nil then
            self.msgQueue = List.new()
        end

        List.pushleft(self.msgQueue, queueValue)
        Apollo.StartTimer("BroadcastUpdateTimer")
    end
end

function ViragsSocial:StartBroadcastFromQueue()
    if self.kMyID == nil or self.kbNeedUpdateMyInfo then
        self:UpdateMyInfo()
        if self.kMyID == nil or self.kbNeedUpdateMyInfo then --fail
            Apollo.StartTimer("BroadcastUpdateTimer")
            return
        end
        self:UpdateGrid(false, false)
    end

    local v = List.popright(self.msgQueue)

    if v then self:Broadcast(v.tChannel, self.ktPlayerInfoDB[self.kMyID], v.nCode, v.strTarget) end

    if List.hasmore(self.msgQueue) then Apollo.StartTimer("BroadcastUpdateTimer") end
end

-- SEND
function ViragsSocial:Broadcast(channel, msg, code, target)
    if self:ValidateBroadcast(msg) and channel and code then

        if code == self.MSG_CODES["UPDATE_FOR_ALL"] then
            self.knMyLastUpdate = self:HelperServerTime()
        end

        if self.ktPlayerInfoDB[self.kMyID].onlineTime == nil then
            self.ktPlayerInfoDB[self.kMyID].onlineTime = self:HelperServerTime()
        end

        if self.tSettings.bDisableNetwork then
            local newMsg = {}
            newMsg.version = self.ICCommLib_PROTOCOL_VERSION
            newMsg.addonVersion = self.ADDON_VERSION
            newMsg.name = msg.name
            newMsg.level = msg.level
            newMsg.class = msg.class
            newMsg.path = msg.path
            msg = newMsg
        end

        msg.target = target
        msg.MSG_CODE = code

        channel:SendMessage(JSON.encode(msg))
    end
end

-------OLD CODE-----
--function ViragsSocial:SetICCommCallback()
--    if not self.channel then
--        self.channel = ICCommLib.JoinChannel("ViragSocial", ICCommLib.CodeEnumICCommChannelType.Group)
--    end
--    if self.channel:IsReady() then
--        self.channel:SetSendMessageResultFunction("OnBroadcastSent", self)
--        self.channel:SetReceivedMessageFunction("OnBroadcastReceived", self)
--        self.channelTimer = nil
--    end
--end

function ViragsSocial:HelperServerTime()
    local tTime = GameLib.GetServerTime()
    tTime.year = tTime.nYear
    tTime.month = tTime.nMonth
    tTime.day = tTime.nDay
    tTime.hour = tTime.nhour
    tTime.min = tTime.nMinute
    tTime.sec = tTime.nSecond
    tTime.isdst = false
    return os.time(tTime)
end


--VALIDATE (version check)
function ViragsSocial:isUpToDateVersion(msg)
    --protocol changed, so dont try to do anything
    if msg.version and msg.version > self.ICCommLib_PROTOCOL_VERSION then
        self.bNeedUpdateAddon = true
        self:ShowUpdateAddonInfoWnd()
        return false
    end

    --addon changed, so can still use data, just report that you need to update
    if msg.addonVersion and msg.addonVersion > self.ADDON_VERSION then
        self.bNeedUpdateAddon = true
        self:ShowUpdateAddonInfoWnd()
    end

    return true
end

--VALIDATE
function ViragsSocial:ValidateBroadcast(msg)
    return msg and type(msg) == "table" and msg.name ~= nil -- todo validation
end



-- QUEUE from http://stackoverflow.com/questions/18843610/fast-implementation-of-queues-in-lua or  Programming in Lua
function List.new()
    return { first = 0, last = -1 }
end

function List.hasmore(list)
    return list.first <= list.last
end

function List.pushleft(list, value)
    local first = list.first - 1
    list.first = first
    list[first] = value
end

function List.pushright(list, value)
    local last = list.last + 1
    list.last = last
    list[last] = value
end

function List.popleft(list)
    local first = list.first
    if first > list.last then return nil end -- error("list is empty")
    local value = list[first]
    list[first] = nil -- to allow garbage collection
    list.first = first + 1
    return value
end

function List.popright(list)
    local last = list.last
    if list.first > last then return nil end -- error("list is empty")
    local value = list[last]
    list[last] = nil -- to allow garbage collection
    list.last = last - 1
    return value
end
