---@type GL
local _, GL = ...;

---@class GDKP
GL.GDKP = {
    _initialized = false,
    broadcastInProgress = false,
    requestingData = false,

    inProgress = false,
    timerId = 0, -- ID of the timer event
    CurrentAuction = {
        initiatorID = nil, -- The player who started the auction
        duration = nil, -- The amount of time players get to bid
        refreshDuration = nil, -- The amount of time the timer resets to
        itemId = nil, -- The ID of the item we're bidding on
        itemName = nil, -- The name of the item we're bidding on
        itemLink = nil, -- The item link of the item we're bidding on
        itemIcon = nil, -- The icon of the item we're bidding on
        minimumBid = nil, -- The minimum amount players need to bid
        minimumIncrement = nil, -- The minimum amount between two player bids
        Bids = {}, -- Player bids
        TopBid = {}, -- Top bid
    },
    listeningForBids = false,
    BidListenerCancelTimerId = nil,
};

local DB = GL.DB; ---@type DB
local Constants = GL.Data.Constants; ---@type Data
local CommActions = Constants.Comm.Actions;
local GDKP = GL.GDKP; ---@type GDKP

--- @return boolean
function GDKP:_init()
    GL:debug("GDKP:_init");

    if (self._initialized) then
        return false;
    end

---@todo: remove
if (GL.User.name == "Omegachrist" or GL.User.name == "Arvadabank") then
    --GL.Interface.GDKP.Overview:draw();
end
    --- Register listener for whisper command
    GL.Events:register({
        {"GDKPChatMsgWhisper", "CHAT_MSG_WHISPER"},
        {"GDKPChatMsgParty", "CHAT_MSG_PARTY"},
        {"GDKPChatMsgPartyLeader", "CHAT_MSG_PARTY_LEADER"},
        {"GDKPChatMsgRaid", "CHAT_MSG_RAID"},
        {"GDKPChatMsgRaidLeader", "CHAT_MSG_RAID_LEADER"},
    }, function (event, message, sender)

    end);

    self._initialized = true;
    return true;
end

--- Return the currently active GDKP session
---
---@return table|boolean
function GDKP:getActiveSession()
    local activeSessionIdentifier = DB.GDKP.activeSession or false;

    if (not activeSessionIdentifier) then
        return false;
    end

    return DB:get("GDKP.Ledger." .. activeSessionIdentifier, false);
end

--- Return whether we have an active GDKP session
---
---@return boolean
function GDKP:hasActiveSession()
    return not GL:empty(DB.GDKP.activeSession) and not GL:empty(DB.GDKP.Ledger[DB.GDKP.activeSession].ID);
end

--- Return whether we the session identifier exists
---
---@return boolean
function GDKP:sessionExists(sessionIdentifier)
    return DB.GDKP.Ledger[sessionIdentifier] and not GL:empty(DB.GDKP.Ledger[sessionIdentifier].ID);
end

--- Restore the given auction
---
---@param sessionIdentifier string
---@param auctionIdentifier string
---
---@return void
function GDKP:restoreAuction(sessionIdentifier, auctionIdentifier)
    GL:debug("GDKP:restoreAuction");

    local Auction = DB:get(string.format("GDKP.Ledger.%s.Auctions.%s", sessionIdentifier, auctionIdentifier));

    -- The auction could not be found or is not deleted
    if (not Auction or Auction.price) then
        return false;
    end

    -- Sort the states on createdAt so that we can get the most recent state
    table.sort(Auction.PreviousStates, function (a, b)
        return a.createdAt > b.createdAt;
    end);

    local mostRecentStateIdentifier;
    local MostRecentState;
    for stateIdentifier, State in pairs(Auction.PreviousStates or {}) do
        mostRecentStateIdentifier = stateIdentifier;
        MostRecentState = State;

        break;
    end

    -- Better safe than lua error
    if (GL:empty(MostRecentState)) then
        return false;
    end

    Auction.Winner = MostRecentState.Winner;
    Auction.price = MostRecentState.price;
    Auction.guild = MostRecentState.guild;

    -- Remove the restored state from the previous states table
    Auction.PreviousStates[mostRecentStateIdentifier] = nil;

    -- We don't point to Auction here, we want a copy not a pointer!
    local Before = DB:get(string.format("GDKP.Ledger.%s.Auctions.%s", sessionIdentifier, auctionIdentifier));
    DB:set(string.format("GDKP.Ledger.%s.Auctions.%s", sessionIdentifier, auctionIdentifier), Auction);

    GL.Events:fire("GL.GDKP_AUCTION_CHANGED", sessionIdentifier, auctionIdentifier, Before, Auction);
    GL.Events:fire("GL.GDKP_AUCTION_RESTORED", sessionIdentifier, auctionIdentifier);

    return true;
end

--- Delete the given auction
---
---@param sessionIdentifier string
---@param auctionIdentifier string
---
---@return void
function GDKP:deleteAuction(sessionIdentifier, auctionIdentifier, byPassReason)
    GL:debug("GDKP:deleteAuction");

    byPassReason = GL:toboolean(byPassReason);
    local Auction = DB:get(string.format("GDKP.Ledger.%s.Auctions.%s", sessionIdentifier, auctionIdentifier));

    -- The auction could not be found or is already deleted
    if (not Auction or not Auction.price) then
        return false;
    end

    Auction.PreviousStates = Auction.PreviousStates or {};

    local PreviousState = {
        createdAt = GetServerTime(),
        Winner = Auction.Winner,
        price = Auction.price,
        CreatedBy = {
            class = GL.User.class,
            name = GL.User.name,
            guild = GL:tableGet(GL.User, "Guild.name") or nil,
            uuid = GL.User.id,
        },
    };

    -- Add a state so we can restore later if needed
    tinsert(Auction.PreviousStates, PreviousState);

    Auction.Winner = nil;
    Auction.price = nil;

    -- We don't point to Auction here, we want a copy not a pointer!
    local Before = DB:get(string.format("GDKP.Ledger.%s.Auctions.%s", sessionIdentifier, auctionIdentifier));
    DB:set(string.format("GDKP.Ledger.%s.Auctions.%s", sessionIdentifier, auctionIdentifier), Auction);

    GL.Events:fire("GL.GDKP_AUCTION_CHANGED", sessionIdentifier, auctionIdentifier, Before, Auction);
    GL.Events:fire("GL.GDKP_AUCTION_DELETED", sessionIdentifier, auctionIdentifier);

    return true;
end

--- Delete the given auction
---
---@param Details table
---
---@return boolean
function GDKP:createAuction(itemID, price, winner, sessionIdentifier)
    GL:debug("GDKP:deleteAuction");

    if ((not sessionIdentifier
            or (sessionIdentifier and not self:sessionExists(sessionIdentifier))
        )
        and not self:hasActiveSession()
    ) then
        return false;
    end

    sessionIdentifier = sessionIdentifier or DB.GDKP.activeSession;

    local Auction = {
        price = price,
        itemID = itemID,
        createdAt = GetServerTime(),
        CreatedBy = {
            class = GL.User.class,
            guild = GL.User.Guild.name,
            name = GL.User.name,
            race = GL.User.race,
            realm = GL.User.realm,
            uuid = GL.User.id,
        },
    };

    local Winner = GL.Player:fromName(winner) or {};
    Winner.Guild = Winner.Guild or {};

    Auction.Winner = {
        class = Winner.class,
        guild = Winner.Guild.name,
        name = Winner.name or winner,
        race = Winner.race,
        realm = Winner.realm or GL.User.realm,
        uuid = Winner.id,
    };

    local checksum = Auction.createdAt .. GL:stringHash(Auction);
    Auction.ID = checksum;

    DB.GDKP.Ledger[sessionIdentifier].Auctions[checksum] = Auction;

    GL.Events:fire("GL.GDKP_AUCTION_CHANGED", sessionIdentifier, checksum, {}, Auction);
    GL.Events:fire("GL.GDKP_AUCTION_CREATED", sessionIdentifier, checksum);

    return true;
end

--- Check whether the current user is allowed to broadcast SoftRes data
---
---@return boolean
function GDKP:userIsAllowedToBroadcast()
    GL:debug("GDKP:userIsAllowedToBroadcast");

    return GL.User.isInGroup and (GL.User.isMasterLooter or GL.User.hasAssist);
end

--- Anounce to everyone in the raid that a roll off is starting
---
---@param itemLink string
---@param time number
---@param note string|nil
---@return void
function GDKP:announceStart(itemLink, minimumBid, minimumIncrement)
    GL:debug("GDKP:announceStart");

    local duration = GL.Settings:get("GDKP.auctionDuration", 20);

    if (type(itemLink) ~= "string"
        or GL:empty(itemLink)
        or not GL:higherThanZero(duration)
    ) then
        GL:warning("Invalid data provided for GDKP auction start!");
        return false;
    end

    self:listenForBids();

    GL.CommMessage.new(
        CommActions.startGDKPAuction,
        {
            item = itemLink,
            duration = duration,
            minimumBid = minimumBid,
            minimumIncrement = minimumIncrement,
        },
        "GROUP"
    ):send();

    -- The user doesn't want to announce anything in chat
    if (not GL.Settings:get("GDKP.announceAuctionStart")) then
        return true;
    end

    local announceMessage = "You have %TIME seconds to bid on %ITEM. Minimum bid is %MINIMUMBID and the minimum increment is %MINIMUMINCREMENT";
    announceMessage = announceMessage:gsub("%S+", {
        ["%TIME"] = duration,
        ["%ITEM"] = itemLink,
        ["%MINIMUMBID"] = minimumBid,
        ["%MINIMUMINCREMENT"] = minimumIncrement
    });

    if (GL.User.isInRaid) then
        GL:sendChatMessage(
            announceMessage,
            "RAID_WARNING"
        );
    else
        GL:sendChatMessage(
            announceMessage,
            "PARTY"
        );
    end

    return true;
end

--- Anounce to everyone in the raid that the auction has ended
---
---@return void
function GDKP:announceStop()
    GL:debug("GDKP:announceStop");

    GL.CommMessage.new(
        CommActions.stopGDKPAuction,
        nil,
        "GROUP"
    ):send();

    self:stopListeningForBids();
end

--- Start an auction
--- This is done via a CommMessage even for the masterlooter to make
--- sure that the auction starts simultaneously for everyone
---
---@param CommMessage CommMessage
function GDKP:start(CommMessage)
    GL:debug("GDKP:start");

    local content = CommMessage.content;

    --[[
        MAKE SURE THE PAYLOAD IS VALID
        PROVIDE VERY SPECIFIC ERROR MESSAGE IF IT'S NOT
    ]]
    if (not content) then
        return GL:error("Missing content in GDKP:start");
    end

    if (type(content) ~= "table") then
        return GL:error("Content is not a table in GDKP:start");
    end

    if (not content.duration
        or type(content.duration) ~= "number"
    ) then
        return GL:error("No duration provided in GDKP:start");
    end

    if (not content.item) then
        return GL:error("No item provided in GDKP:start");
    end

    --- We have to wait with starting the actual auction until
    --- the item that's up for bidding has been successfully loaded by the Item API
    ---
    ---@vararg Item
    ---@return void
    GL:onItemLoadDo(content.item, function (Items)
        local Entry = Items[1];

        if (GL:empty(Entry)) then
            return;
        end

        local duration = math.floor(tonumber(content.duration));
        local SupportedBids = content.SupportedBids or {};
        local minimumBid = content.minimumBid or 0;
        local minimumIncrement = content.minimumIncrement or 1;

        -- This is a new auction so clean everything
        if (Entry.link ~= self.CurrentAuction.itemLink
            or CommMessage.Sender.id ~= self.CurrentAuction.initiatorID
        ) then
            -- This is a new item so make sure to
            -- override all previously set properties
            self.CurrentAuction = {
                initiatorID = CommMessage.Sender.id,
                initiatorName = CommMessage.Sender.name,
                duration = duration,
                itemId = Entry.id,
                itemName = Entry.name,
                itemLink = Entry.link,
                itemIcon = Entry.icon,
                minimumBid = minimumBid,
                minimumIncrement = minimumIncrement,
                Bids = {},
                TopBid = {},
            };
        else
            -- If we roll the same item again we do need to make
            -- sure that we update the roll timer
            self.CurrentAuction.time = duration;
        end

        self.inProgress = true;

        -- Don't show the bid UI if the user disabled it
        -- and the current user is not the one who initiated the auction
        if (GL.Settings:get("GDKP.showBidWindow")
            or self:startedByMe()
        ) then
            GL.Interface.GDKP.Bidder:show(duration, Entry.link, Entry.icon, content.note, SupportedBids);

            if (CommMessage.Sender.id == GL.User.id) then
                GL.Interface.GDKP.Auctioneer:drawReopenAuctioneerButton();
            end
        end

        -- Make sure the rolloff stops when time is up
        self.timerId = GL.Ace:ScheduleTimer(function ()
            self:stop();
        end, duration);

        -- Send a countdown in chat when enabled
        local numberOfSecondsToCountdown = GL.Settings:get("MasterLooting.numberOfSecondsToCountdown", 5);
        if (self:startedByMe() -- Only post a countdown if this user initiated the auction
            and duration > numberOfSecondsToCountdown -- No point in counting down if there's hardly enough time anyways
            and GL.Settings:get("MasterLooting.doCountdown", false)
        ) then
            local SecondsAnnounced = {};
            self.countDownTimer = GL.Ace:ScheduleRepeatingTimer(function ()
                local secondsLeft = math.ceil(GL.Ace:TimeLeft(self.timerId));
                if (secondsLeft <= numberOfSecondsToCountdown
                        and secondsLeft > 0
                        and not SecondsAnnounced[secondsLeft]
                ) then
                    SecondsAnnounced[secondsLeft] = true;

                    GL:sendChatMessage(
                            string.format("%s seconds to roll", secondsLeft),
                            "GROUP"
                    );
                end
            end, 1);
        end

        -- Play raid warning sound
        GL:playSound(8959, "Master");

        -- Items should only contain 1 item but lets add a return just in case
        return;
    end);
end

--- Check whether the current rolloff was started by me (the user)
---
---@return boolean
function GDKP:startedByMe()
    return self.CurrentAuction.initiatorID == GL.User.id;
end

--- Stop a roll off. This method can be invoked internally when the roll
--- off time is over or when announced by the initiation of the roll off.
---
---@param CommMessage string|nil
---@return boolean
function GDKP:stop(CommMessage)
    GL:debug("GDKP:stop");

    if (not self.inProgress) then
        return GL:warning("Can't stop auction, no auction in progress");
    end

    if (CommMessage
        and self.CurrentAuction.initiatorID ~= GL.User.id
        and CommMessage.Sender.id ~= self.CurrentAuction.initiatorID
    ) then
        if (self.CurrentAuction.initiatorID) then
            GL:warning(CommMessage.Sender.name .. " is not allowed to stop auction");
        else
            GL:warning(CommMessage.Sender.name .. " is not allowed to stop current auction: auction is invalid");
        end

        return false;
    end

    -- If this user started the roll then we need to cancel some timers and post a message
    if (self:startedByMe()) then
        -- Announce that the roll has ended
        if (GL.Settings:get("MasterLooting.announceRollEnd", true)) then
            GL:sendChatMessage(
                string.format("Stop your bids!"),
                "RAID_WARNING"
            );
        end
    end

    if (self.countDownTimer) then
        GL.Ace:CancelTimer(self.countDownTimer);
        self.countDownTimer = nil;
    end

    -- Play raid warning sound
    GL:playSound(8959);

    self.inProgress = false;
    GL.Ace:CancelTimer(self.timerId);

    GL.RollerUI:hide();

    -- If we're the initiatorID then we need to update our initiatorID UI
    if (self:startedByMe()) then
        GL.Interface.GDKP.Auctioneer:updateWidgets();
    end

    return true;
end

function GDKP:resetAuction()
    -- Reset the last auction. This happens when the master looter
    -- awards an item or when he clicks the "clear" button in the auctioneer window
    GL:debug("GDKP:resetAuction");

    -- All we need to do is reset the itemLink and let self:start() take care of the rest
    self.CurrentAuction.itemLink = "";
end

--- Start listening for rolls
---
---@return void
function GDKP:listenForBids()
    GL:debug("GDKP:listenForBids");

    -- Make sure the timer to cancel listening for rolls is cancelled
    if (self.bidListenerCancelTimerId) then
        GL.Ace:CancelTimer(self.bidListenerCancelTimerId);
    end

    if (self.listeningForBids) then
        return;
    end

    self.listeningForBids = true;

    GL.Events:register({
        {"GDKPChatMsgWhisper", "CHAT_MSG_WHISPER"},
        {"GDKPChatMsgParty", "CHAT_MSG_PARTY"},
        {"GDKPChatMsgPartyLeader", "CHAT_MSG_PARTY_LEADER"},
        {"GDKPChatMsgRaid", "CHAT_MSG_RAID"},
        {"GDKPChatMsgRaidLeader", "CHAT_MSG_RAID_LEADER"},
    }, function (event, message, sender)
        self:processBid(event, message, sender);
    end);
end

--- Unregister the CHAT_MSG_SYSTEM to stop listening for rolls
---
---@return void
function GDKP:stopListeningForBids()
    GL:debug("GDKP:stopListeningForBids");

    if (self.bidListenerCancelTimerId) then
        GL.Ace:CancelTimer(self.bidListenerCancelTimerId);
    end

    self.listeningForBids = false;
    GL.Events:unregister({
        "GDKPChatMsgWhisper",
        "GDKPChatMsgParty",
        "GDKPChatMsgPartyLeader",
        "GDKPChatMsgRaid",
        "GDKPChatMsgRaidLeader",
    });
end

function GDKP:bid(message)
    GL:dump(message);

    -- There's no auction in progress
    if (not self.inProgress) then
        return false;
    end

    message = message:gsub("%,", ".");

    local bid = self:messageToBid(message);

    if (not GL:higherThanZero(bid)) then
        return false;
    end

    -- The given bid is invalid or not higher than the highest known bid
    if (not GL:higherThanZero(bid)
        or bid < self:lowestValidBid()
    ) then
        return false;
    end

    if (GL.User.isInGroup) then
        GL:sendChatMessage(bid, "GROUP", nil, nil, false);
    else
        GL:sendChatMessage(bid, "WHISPER", nil, self.CurrentAuction.initiatorName, false);
    end
end

--- Return the lowest possible valid bid based on the current bid or the minimum price
---
---@return number
function GDKP:lowestValidBid()
    return math.max(
        GL:tableGet(self.CurrentAuction, "TopBid.price", 0) + (self.CurrentAuction.minimumIncrement or 0),
        self.CurrentAuction.minimumBid
    );
end

function GDKP:processBid(event, message, bidder)
    GL:debug("GDKP:processBid");

    -- We only track rolls when a rollof is actually in progress
    if (not GDKP.inProgress) then
        return;
    end

    message = string.lower(message);

    -- This is most likely a message generated by gargul
    if (GL:strStartsWith(message, "{rt3} gargul :")) then
        return;
    end

    ---@todo set to false
    --local acceptClosedBids = false;
    local acceptClosedBids = true;

    -- We only accept bids in /w when we're accepting closed bids or when we're not in a group (e.g. testing)
    if (event == "CHAT_MSG_WHISPER"
        and not acceptClosedBids
        and GL.User.isInGroup)
    then
        local response = "I'm not accepting closed bids, use the /ra channel instead!";

        if (not GL.User.isInRaid) then
            response = "I'm not accepting closed bids, use the /gr channel instead!";
        end

        --GL:sendChatMessage(response, "WHISPER", nil, sender);

        return;
    end

    local bid = self:messageToBid(message);

    if (not GL:higherThanZero(bid)) then
        return;
    end

    --- Make sure the person who bid is in our group
    local BidEntry = false;
    for _, Member in pairs(GL.User:groupMembers(true)) do
        if (GL:stripRealm(bidder) == GL:stripRealm(Member.name)) then
            local Player = GL.Player:fromName(Member.name);
            local playerName, realm = GL:stripRealm(bidder);

            BidEntry = {
                Bidder = {
                    class = Player.class,
                    guild = Player.Guild.name,
                    name = playerName,
                    race = Player.race,
                    realm = realm,
                    uuid = Player.id,
                },
                bid = bid,
                createdAt = GetServerTime(),
            };

            break;
        end
    end

    if (not BidEntry) then
        return;
    end

    -- The bid is not high enough for us to accept
    ---@todo: add some form of feedback / reporting
    if (BidEntry.bid < math.max(
        self.CurrentAuction.minimumBid,
        GL:tableGet(self.CurrentAuction, "TopBid.bid", 0) + self.CurrentAuction.minimumIncrement
    ))
    then
        return;
    end

    tinsert(self.CurrentAuction.Bids, BidEntry);
    GL.Interface.GDKP.Auctioneer:refreshRollsTable();

    self.CurrentAuction.TopBid = BidEntry;

    GL.Events:fire("GL.GDKP_BID_ACCEPTED", BidEntry);
end

--- Transform a given message to a bid if possible
---
---@param message string
---@return number
function GDKP:messageToBid(message)
    message = message:gsub("%,", ".");

    local onlyAcceptRoundNumbers = true;
    local match = message:match("(%d*%.?%d+)");

    if (GL:empty(match)) then
        return 0;
    end

    local bid = tonumber(match);
    local kModifier = message:find("%d+k");

    local distance = GL:levenshtein(match, message);

    if (distance > 7) then
        return 0;
    end

    if (kModifier) then
        bid = bid * 1000;
    end

    if (onlyAcceptRoundNumbers) then
        bid = GL:round(bid);
    end

    return bid;
end

GL:debug("GDKP.lua");