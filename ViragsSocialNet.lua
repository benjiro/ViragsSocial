require "ICComm"

local ViragsSocial = Apollo.GetAddon("ViragsSocial")
local JSON
local Queue = {}

ViragsSocial.ICCommLib_PROTOCOL_VERSION = 0.001
ViragsSocial.MSG_CODES = {
    ["REQUEST_INFO"] = 1,
    ["UPDATE_FOR_TARGET"] = 2,
    ["UPDATE_FOR_ALL"] = 3,

}

function ViragsSocial:InitComm()
    self:DEBUG("Initalisating communication module")

    JSON = Apollo.GetPackage("Lib:dkJSON-2.5").tPackage
    local arGuilds = GuildLib.GetGuilds()

    if arGuilds == nil then return end

    self.InfoChannels = {}
    self.msgQueue = Queue:new()

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

    local newChannel = ICCommLib.JoinChannel("ViragsSocial" .. channelName,
        ICCommLib.CodeEnumICCommChannelType.Guild, guild)
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

        self.msgQueue:Push(queueValue)
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

    local v = self.msgQueue:Pop()

    if v then self:Broadcast(v.tChannel, self.ktPlayerInfoDB[self.kMyID], v.nCode, v.strTarget) end

    if self.msgQueue:GetSize() > 0 then Apollo.StartTimer("BroadcastUpdateTimer") end
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

        msg.target = target
        msg.MSG_CODE = code

        channel:SendMessage(JSON.encode(msg))
    end
end

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
    return msg and type(msg) == "table" and msg.name ~= nil
end

function Queue:new()
    local o = { first = 0, last = -1 }
    setmetatable(o, self)
    self.__index = self
    return o
end

function Queue:Push(value)
    local last = self.last + 1
    self.last = last
    self[last] = value
end

function Queue:Pop()
    local first = self.first
    if first > self.last then self:DEBUG("Queue is empty") end
    local value = self[first]
    self[first] = nil
    self.first = first + 1
    return value
end

function Queue:GetSize()
    return self.last - self.first + 1
end
