-- Moar Challenges Please - challenges 21-50 (if counting from Vanilla).

local function m(id) return G.GAME and G.GAME.modifiers and G.GAME.modifiers[id] end

--============================================================
-- Shop / economy hooks
--============================================================

local mcp_set_cost_value = Card.set_cost_value
function Card:set_cost_value()
    mcp_set_cost_value(self)
    if m('mcp_black_market') then self.cost = self.cost * 2 end
    if m('mcp_thrift_store') and (self.ability.set == 'Joker' or self.ability.set == 'Booster') then
        self.cost = math.max(1, math.floor(self.cost * 0.5))
    end
end

local mcp_set_sell_value = Card.set_sell_value
function Card:set_sell_value()
    mcp_set_sell_value(self)
    if m('mcp_no_refunds') then self.sell_cost = 0 end
end

local mcp_can_reroll = G.FUNCS.can_reroll
G.FUNCS.can_reroll = function(e)
    mcp_can_reroll(e)
    if m('mcp_no_reroll') then
        e.config.colour = G.C.UI.BACKGROUND_INACTIVE
        e.config.button = nil
    end
end

local mcp_impulse_armed = false

local function joker_draft_sweep() -- Jokers are sold entering the shop rather than at Boss Blind end.
    if not (m('mcp_joker_draft') and G.jokers and G.GAME.round_resets) then return end
    local ante = MCP.plain(G.GAME.round_resets.ante) or 0
    if G.GAME.mcp_draft_ante == ante then return end
    G.GAME.mcp_draft_ante = ante
    for i = #G.jokers.cards, 1, -1 do
        local c = G.jokers.cards[i]
        if c and not c.ability.eternal then
            ease_dollars(MCP.plain(c.cost) or 0)
            c:start_dissolve()
        end
    end
end

local mcp_update_shop = Game.update_shop
function Game:update_shop(dt)
    mcp_update_shop(self, dt)
    joker_draft_sweep()
    if not (m('mcp_impulse_buyer') and mcp_impulse_armed) then return end
    local card = G.shop_jokers and G.shop_jokers.cards and G.shop_jokers.cards[1]
    if not card then return end
    mcp_impulse_armed = false

    local price = MCP.plain(card.cost) or 0
    local dollars = MCP.plain(G.GAME.dollars) or 0
    if price > dollars then return end
    pcall(G.FUNCS.buy_from_shop, { config = { ref_table = card } })
end

local mcp_reroll = G.FUNCS.reroll_shop
G.FUNCS.reroll_shop = function(e)
    if m('mcp_gambler') then
        G.GAME.mcp_gambler_rerolls = (G.GAME.mcp_gambler_rerolls or 0) + 1
        if G.jokers and #G.jokers.cards > 0 and pseudorandom('mcp_gambler') < 1 / 6 then
            local c = G.jokers.cards[pseudorandom('mcp_gambler_pick', 1, #G.jokers.cards)]
            if c and not c.ability.eternal then
                play_sound('glass' .. math.random(1, 6), math.random() * 0.2 + 0.9, 0.5)
                c:start_dissolve()
            end
        end
    end
    return mcp_reroll(e)
end

local mcp_calc_reroll = calculate_reroll_cost
function calculate_reroll_cost(skip_increment)
    mcp_calc_reroll(skip_increment)
    if not (G.GAME and G.GAME.current_round) then return end
    if m('mcp_gambler') then
        local done = G.GAME.mcp_gambler_rerolls or 0
        G.GAME.current_round.reroll_cost = math.max(0, done + 1 - 10)
    end
    if m('mcp_impulse_buyer') then
        mcp_impulse_armed = true
    end
end

--============================================================
-- Card pools
--============================================================

local SUITS = { 'S', 'H', 'D', 'C' }
local RANKS = { '2', '3', '4', '5', '6', '7', '8', '9', 'T', 'J', 'Q', 'K', 'A' }
local FACES = { 'J', 'Q', 'K' }

-- Read by the run-start ban sweep below, so it has to be declared above it.
local BABY_SAFE = { m_bonus = true, m_mult = true, m_stone = true,
                    e_base = true, e_foil = true, e_holo = true }

--============================================================
-- Hand legality (28 / 36 / 38)
--============================================================

local SUIT_NAME = { S = 'Spades', H = 'Hearts', D = 'Diamonds', C = 'Clubs' }

local function is_wild(c)
    if SMODS and SMODS.has_enhancement then return SMODS.has_enhancement(c, 'm_wild') end
    return c.config and c.config.center_key == 'm_wild'
end

local function suits_in(cards) -- Distinct suits present, with each Wild card counting as one missing suit.
    local seen, wilds = {}, 0
    for _, c in ipairs(cards) do
        if not c.debuff then
            if is_wild(c) then
                wilds = wilds + 1
            else
                for _, s in ipairs(SUITS) do
                    local suit = SUIT_NAME[s]
                    if c:is_suit(suit) and not seen[suit] then
                        seen[suit] = true
                        break
                    end
                end
            end
        end
    end
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    return math.min(4, n + wilds)
end


local function hand_order(name) -- Lower order = stronger hand: SMODS numbers PokerHands from Flush Five (1) down.
    local ph = SMODS.PokerHands and SMODS.PokerHands[name]
    return ph and ph.order or 99
end


local function top_rank(cards) -- Highest scoring rank in a hand, so to rank a high Pair above a low one.
    local best = 0
    for _, c in ipairs(cards or {}) do
        local id = c.get_id and c:get_id() or 0
        if id > best then best = id end
    end
    return best
end

local mcp_debuff_hand = Blind.debuff_hand
function Blind:debuff_hand(cards, hand, handname, check)
    if mcp_debuff_hand(self, cards, hand, handname, check) then return true end

    if m('mcp_suit_up') and suits_in(cards) < 4 then return true end

    if m('mcp_poker_purist') and handname then
        local ord, rank = hand_order(handname), top_rank(cards)
        local prev, prev_rank = G.GAME.mcp_last_hand_order, G.GAME.mcp_last_hand_rank or 0
        if prev then
            if ord > prev then return true end
            if ord == prev and rank <= prev_rank then return true end
        end
        if not check then
            G.GAME.mcp_last_hand_order = ord
            G.GAME.mcp_last_hand_rank = rank
        end
    end

    if m('mcp_balanstro') and handname and G.GAME.hands then
        local this = G.GAME.hands[handname]
        if this then
            local pool, seen = {}, {}
            for _, c in ipairs(cards or {}) do
                if not seen[c] then seen[c] = true; pool[#pool + 1] = c end
            end
            for _, c in ipairs((G.hand and G.hand.cards) or {}) do
                if not seen[c] then seen[c] = true; pool[#pool + 1] = c end
            end

            local ok, parts = pcall(evaluate_poker_hand, pool)
            if ok and parts then
                local mine = MCP.plain(this.played) or 0
                if not check then mine = mine - 1 end
                local min
                for name, matches in pairs(parts) do
                    if next(matches) and G.GAME.hands[name] then
                        local p = MCP.plain(G.GAME.hands[name].played) or 0
                        if not min or p < min then min = p end
                    end
                end
                if min and mine > min then return true end
            end
        end
    end
    return false
end

--============================================================
-- Round / play hooks
--============================================================
local mcp_eval_round = G.FUNCS.evaluate_round
G.FUNCS.evaluate_round = function(...)
    if m('mcp_trial') and G.GAME.round_resets
        and G.GAME.blind_on_deck and G.GAME.blind_on_deck ~= 'Boss' then
        local bs = G.GAME.round_resets.blind_states
        if bs then
            bs[G.GAME.blind_on_deck] = 'Defeated'
            if bs.Boss == 'Defeated' then bs.Boss = 'Upcoming' end
        end
    end
    G.GAME.mcp_last_hand_order = nil
    G.GAME.mcp_last_hand_rank = nil
    return mcp_eval_round(...)
end

--============================================================
-- Post-scoring card fates (41 / 42 / 43)
--============================================================
local ENH_POOL = { 'm_bonus', 'm_mult', 'm_wild', 'm_glass', 'm_steel', 'm_stone', 'm_gold', 'm_lucky' }

local function mark_destroyed(card, cards_destroyed)
    if card.getting_sliced then return end
    card.getting_sliced = true
    if SMODS.shatters and SMODS.shatters(card) then
        card.shattered = true
    else
        card.destroyed = true
    end
    cards_destroyed[#cards_destroyed + 1] = card
end

local mcp_destroying = SMODS.calculate_destroying_cards
function SMODS.calculate_destroying_cards(context, cards_destroyed, scoring_hand)
    mcp_destroying(context, cards_destroyed, scoring_hand)
    if not scoring_hand then return end

    if m('mcp_glass_house') and context.scoring_name ~= 'Full House' then
        for _, c in ipairs(context.full_hand or {}) do
            mark_destroyed(c, cards_destroyed)
        end
    end

    if m('mcp_recursion') then
        local replaced = 0
        for _, c in ipairs(scoring_hand) do
            if not c.getting_sliced then replaced = replaced + 1 end
            mark_destroyed(c, cards_destroyed)
        end
        for _ = 1, replaced do
            local proto = {
                s = SUITS[pseudorandom('mcp_rec_s', 1, #SUITS)],
                r = RANKS[pseudorandom('mcp_rec_r', 1, #RANKS)],
                e = ENH_POOL[pseudorandom('mcp_rec_e', 1, #ENH_POOL)],
            }
            G.E_MANAGER:add_event(Event({ func = function()
                card_from_control(proto); return true
            end }))
        end
    end
end

local mcp_draw_discard = G.FUNCS.draw_from_play_to_discard
G.FUNCS.draw_from_play_to_discard = function(e)
    if m('mcp_rusty_deck') and G.play then
        for _, c in ipairs(G.play.cards) do
            if SMODS.has_enhancement and SMODS.has_enhancement(c, 'm_steel') and not c.mcp_rusted then
                c.mcp_rusted = true
                c:set_debuff(true)
                c:juice_up(0.3, 0.3)
                play_sound('card1', 1)
            end
        end
    end
    return mcp_draw_discard(e)
end

--============================================================
-- Joker lifecycle hooks
--============================================================

local mcp_cloning = false

local mcp_add_to_deck = Card.add_to_deck
function Card:add_to_deck(from_debuff)
    mcp_add_to_deck(self, from_debuff)
    if not (self.ability and self.ability.set == 'Joker') then return end

    if m('mcp_all_perishable') and not self.ability.perishable
        and not (self.config and self.config.center and self.config.center.perishable_compat == false) then
        self.ability.perishable = true
        self.ability.perish_tally = G.GAME.perishable_rounds or 5
    end


    if m('mcp_one_trick') and not mcp_cloning then -- fill the remaining slots with copies. mcp_cloning stops the copies cloning too.
        local src = self
        G.E_MANAGER:add_event(Event({ func = function()
            if G.jokers and not mcp_cloning then
                mcp_cloning = true
                local want = (G.jokers.config.card_limit or 0) - #G.jokers.cards
                for _ = 1, math.min(want, 20) do
                    local c = copy_card(src, nil)
                    c:add_to_deck()
                    G.jokers:emplace(c)
                end
                mcp_cloning = false
            end
            return true
        end }))
    end
end

local mcp_sell = G.FUNCS.sell_card
G.FUNCS.sell_card = function(e)
    local card = e and e.config and e.config.ref_table
    local key = m('mcp_one_trick') and card and card.config and card.config.center_key
    local res = mcp_sell(e)
    if key and G.jokers then
        for i = #G.jokers.cards, 1, -1 do
            local c = G.jokers.cards[i]
            if c ~= card and c.config and c.config.center_key == key then
                c:start_dissolve()
            end
        end
    end
    return res
end

local mcp_create_card = create_card
function create_card(_type, area, legendary, _rarity, skip_materialize, soulable, forced_key, key_append)
    local c = mcp_create_card(_type, area, legendary, _rarity, skip_materialize, soulable, forced_key, key_append)
    if c and c.ability then
        if c.ability.set == 'Joker' then
            if m('mcp_all_perishable') and not c.ability.perishable
                and not (c.config and c.config.center and c.config.center.perishable_compat == false) then
                c.ability.perishable = true
                c.ability.perish_tally = G.GAME.perishable_rounds or 5
            end
            if m('mcp_tenant') and not c.ability.rental then
                c.ability.rental = true
                if c.set_cost then c:set_cost() end   -- rentals price at $1; recompute
            end
        elseif c.ability.set == 'Default' or c.ability.set == 'Enhanced' then
            if m('mcp_wild_west') then c:set_debuff(false) end
        end
    end
    return c
end

local mcp_calc_retriggers = SMODS.calculate_retriggers
function SMODS.calculate_retriggers(card, context, _ret)
    local ret = mcp_calc_retriggers(card, context, _ret)
    if m('mcp_double_down') and card and card.ability and card.ability.set == 'Joker'
        and SMODS.insert_repetitions then
        SMODS.insert_repetitions(ret, { repetitions = 1, message = localize('k_again_ex') },
            card, 'joker_retrigger')
    end
    return ret
end

local DD_EVENT_CONTEXTS = {
    'setting_blind', 'first_hand_drawn', 'hand_drawn', 'pre_discard', 'discard',
    'end_of_round', 'buying_card', 'open_booster', 'skip_blind', 'reroll_shop',
    'using_consumeable', 'skipping_booster', 'ending_shop', 'card_added',
}

local mcp_calc_joker = Card.calculate_joker
function Card:calculate_joker(context, ...)
    local eff, post = mcp_calc_joker(self, context, ...)
    if m('mcp_double_down') and context and self.ability and self.ability.set == 'Joker'
        and not context.blueprint_card and not context.retrigger_joker
        and not context.retrigger_joker_check and not self.mcp_dd_running then
        for _, key in ipairs(DD_EVENT_CONTEXTS) do
            if context[key] then
                self.mcp_dd_running = true          -- the rerun must not re-enter here
                pcall(mcp_calc_joker, self, context, ...)
                self.mcp_dd_running = nil
                break
            end
        end
    end
    return eff, post
end

--============================================================
-- Run-shape hooks
--============================================================
local mcp_start_run = Game.start_run
function Game:start_run(args)
    mcp_start_run(self, args)
    if not (G.GAME and G.GAME.modifiers) then return end
    if m('mcp_half_a_hand') then
        if G.hand then G.hand.config.highlighted_limit = 3 end
        if G.GAME.starting_params then G.GAME.starting_params.play_limit = 3 end
    end
    if m('mcp_long_game') then G.GAME.win_ante = 16 end
    if m('mcp_baby') then
        G.GAME.banned_keys = G.GAME.banned_keys or {}
        for _, pool in ipairs({ 'Enhanced', 'Edition', 'Seal' }) do
            for _, v in ipairs(G.P_CENTER_POOLS[pool] or {}) do
                if v.key and not BABY_SAFE[v.key] then G.GAME.banned_keys[v.key] = true end
            end
        end
    end
end

local mcp_ease_ante = ease_ante
function ease_ante(mod)
    mcp_ease_ante(mod)
    if m('mcp_final_form') and G.jokers and MCP.plain(mod) and MCP.plain(mod) > 0 then
        G.jokers.config.card_limit = G.jokers.config.card_limit + 1
    end
    if m('mcp_legendary_twist') and G.jokers and not G.GAME.mcp_chicot_destroyed     -- Chicot is destroyed on reaching Ante 8 and bypasses Eternal.
        and G.GAME.round_resets and (MCP.plain(G.GAME.round_resets.ante) or 0) >= 8 then
        G.GAME.mcp_chicot_destroyed = true
        for i = #G.jokers.cards, 1, -1 do
            local c = G.jokers.cards[i]
            local ck = c.config and (c.config.center_key or (c.config.center and c.config.center.key))
            if ck == 'j_chicot' then c:start_dissolve() end
        end
    end
end

local mcp_get_blind_amount = get_blind_amount
function get_blind_amount(ante)
    local base = mcp_get_blind_amount(ante)
    if m('mcp_double_down') and ante and ante > 1 then
        return (to_big and to_big(base) or base) * 2
    end
    return base
end

local mcp_set_blind_ch = Blind.set_blind
function Blind:set_blind(blind, reset, silent)
    mcp_set_blind_ch(self, blind, reset, silent)
    if reset then return end
    if m('mcp_tenant') then
        self.dollars = (MCP.plain(blind and blind.dollars) or 0) * 2
        G.GAME.current_round.dollars_to_be_earned = self.dollars > 0
            and string.rep(localize('$'), self.dollars) or ''
    end
end

--============================================================
-- Bosses in the Small/Big slots (50)
--============================================================

local function bosses_everywhere()
    if not m('mcp_trial') then return false end
    return (G.GAME.round_resets and G.GAME.round_resets.ante or 1) >= 2
end

local mcp_next_vouchers = SMODS.get_next_vouchers
function SMODS.get_next_vouchers(existing)
    if not existing
        and m('mcp_trial')
        and G.STATE == G.STATES.ROUND_EVAL
        and G.GAME and G.GAME.blind_on_deck and G.GAME.blind_on_deck ~= 'Boss'
        and G.GAME.current_round and G.GAME.current_round.voucher then
        return G.GAME.current_round.voucher
    end
    return mcp_next_vouchers(existing)
end

local mcp_reset_blinds = reset_blinds
function reset_blinds()
    local bs = G.GAME and G.GAME.round_resets and G.GAME.round_resets.blind_states
    local new_ante = bs and bs.Boss == 'Defeated'
    mcp_reset_blinds()
    local rr = G.GAME and G.GAME.round_resets
    if not (rr and rr.blind_choices) then return end
    if bosses_everywhere() then
        for _, slot in ipairs({ 'Small', 'Big' }) do
            local cur = G.P_BLINDS[rr.blind_choices[slot]]
            if new_ante or not (cur and cur.boss) then
                rr.blind_choices[slot] = get_new_boss()
            end
        end
    end
end

--============================================================
-- Baby's First Balatro rules (51)
--============================================================
-- The Wall and Violet Vessel are the only vanilla bosses with no ability at all,
-- so every Boss round is one of those two and differs only in score requirement.

local BABY_BOSS, BABY_FINAL = 'bl_wall', 'bl_final_vessel'

local function baby_boss_mult(ante)
    if ante >= 8 then return 6 end   -- Very Large Blind
    if ante == 7 then return 4 end   -- Extra Large Blind
    return 2                         -- same size as a normal Boss
end

-- About a quarter of White Stake. Ante 0 and 1 are pinned to the numbers a first run
-- should open on; from Ante 2 up it is a flat quarter of vanilla, endless included.
local BABY_AMOUNTS = { [0] = 25, [1] = 100 }

local mcp_get_blind_amount = get_blind_amount
function get_blind_amount(ante)
    if not m('mcp_baby') then return mcp_get_blind_amount(ante) end
    local plain = MCP.plain(ante)
    if plain and BABY_AMOUNTS[plain] then return BABY_AMOUNTS[plain] end
    return mcp_get_blind_amount(ante) * 0.25
end

local mcp_get_new_boss = get_new_boss
function get_new_boss()
    if not m('mcp_baby') then return mcp_get_new_boss() end
    local rr = G.GAME.round_resets
    local ante = MCP.plain(rr and rr.ante) or 1
    local win = MCP.plain(G.GAME.win_ante) or 8
    local key = (ante >= 2 and ante % win == 0) and BABY_FINAL or BABY_BOSS
    G.GAME.bosses_used[key] = (G.GAME.bosses_used[key] or 0) + 1
    return key
end

local mcp_set_blind_baby = Blind.set_blind
function Blind:set_blind(blind, reset, silent)
    mcp_set_blind_baby(self, blind, reset, silent)
    if reset or not (m('mcp_baby') and blind and blind.boss) then return end
    local rr = G.GAME.round_resets
    local ante = MCP.plain(rr and rr.ante) or 1
    self.mult = baby_boss_mult(ante)
    self.chips = get_blind_amount(rr.ante) * self.mult * G.GAME.starting_params.ante_scaling
end

local mcp_skip_blind = G.FUNCS.skip_blind
G.FUNCS.skip_blind = function(e)
    if m('mcp_baby') then return end
    return mcp_skip_blind(e)
end

-- Editions, seals and stickers are polled rather than drawn from a pool, so
-- banned_keys does not reach them.
local mcp_poll_edition = poll_edition
function poll_edition(...)
    local ed = mcp_poll_edition(...)
    if m('mcp_baby') and type(ed) == 'table' and (ed.polychrome or ed.negative) then return nil end
    return ed
end

if SMODS.poll_seal then
    local mcp_poll_seal = SMODS.poll_seal
    function SMODS.poll_seal(...)
        if m('mcp_baby') then return nil end
        return mcp_poll_seal(...)
    end
end

if SMODS.Sticker and SMODS.Sticker.should_apply then
    local mcp_should_apply = SMODS.Sticker.should_apply
    function SMODS.Sticker:should_apply(card, center, area, rate)
        if m('mcp_baby') then return false end
        return mcp_should_apply(self, card, center, area, rate)
    end
end

local mcp_get_type = Blind.get_type
function Blind:get_type()
    if not (G.GAME and G.GAME.mcp_true_blind_type)
        and bosses_everywhere() and G.GAME.blind_on_deck and G.GAME.blind_on_deck ~= 'Boss' then
        return G.GAME.blind_on_deck
    end
    return mcp_get_type(self)
end

local mcp_sell_card = Card.sell_card
function Card:sell_card()
    local luchador = self.ability and self.ability.name == 'Luchador'
    local saved = G.GAME and G.GAME.mcp_true_blind_type
    if luchador and G.GAME then G.GAME.mcp_true_blind_type = true end
    local ret = mcp_sell_card(self)
    if luchador and G.GAME then G.GAME.mcp_true_blind_type = saved end
    return ret
end

local mcp_ability_table = Card.generate_UIBox_ability_table
function Card:generate_UIBox_ability_table(vars_only)
    local luchador = self.ability and self.ability.name == 'Luchador'
    local saved = G.GAME and G.GAME.mcp_true_blind_type
    if luchador and G.GAME then G.GAME.mcp_true_blind_type = true end
    local ret = mcp_ability_table(self, vars_only)
    if luchador and G.GAME then G.GAME.mcp_true_blind_type = saved end
    return ret
end

--============================================================
-- Debuffs (37 / 43)
--============================================================

local mcp_card_set_debuff = Card.set_debuff
function Card:set_debuff(should_debuff)
    local playing = self.ability and (self.ability.set == 'Default' or self.ability.set == 'Enhanced')
    if playing and m('mcp_wild_west') and not is_wild(self) then should_debuff = true end
    if self.mcp_rusted then should_debuff = true end
    return mcp_card_set_debuff(self, should_debuff)
end

--============================================================
-- Board note (28)
--============================================================

local mcp_note

local function sync_board_note()
    local want = G.STAGE == G.STAGES.RUN and G.STATE == G.STATES.SELECTING_HAND
        and m('mcp_suit_up') and G.play and G.play.T
    if want and not mcp_note then
        mcp_note = UIBox{
            definition = {
                n = G.UIT.ROOT, config = { align = 'cm', colour = G.C.CLEAR },
                nodes = {{
                    n = G.UIT.C,
                    config = { align = 'cm', padding = 0.08, r = 0.1, emboss = 0.05,
                               colour = adjust_alpha(G.C.PURPLE, 0.8) },
                    nodes = {{
                        n = G.UIT.T, config = { text = localize('k_mcp_suit_up'),
                                                scale = 0.35, shadow = true, colour = G.C.WHITE } },
                    },
                }},
            },
            config = { align = 'cm', offset = { x = 0, y = -2.6 }, major = G.play, bond = 'Weak' },
        }
    elseif mcp_note and not want then
        mcp_note:remove()
        mcp_note = nil
    end
end

local mcp_game_update_ch = Game.update
function Game:update(dt)
    mcp_game_update_ch(self, dt)
    sync_board_note()
end

--============================================================
-- Ban list helpers
--============================================================

local function pool_ids(pool_key, filter)
    return function()
        local out = {}
        for _, v in ipairs(G.P_CENTER_POOLS[pool_key] or {}) do
            if v.key and (not filter or filter(v)) then out[#out + 1] = { id = v.key } end
        end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end
end

local function merge_pools(...)
    local parts = { ... }
    return function()
        local out, seen = {}, {}
        for _, part in ipairs(parts) do
            for _, e in ipairs(type(part) == 'function' and part() or part) do
                if not seen[e.id] then seen[e.id] = true; out[#out + 1] = e end
            end
        end
        return out
    end
end

local ban_planets   = pool_ids('Planet')
local ban_tarots    = pool_ids('Tarot')
local ban_spectrals = pool_ids('Spectral')

local ban_nonbuffoon_boosters = pool_ids('Booster', function(v)
    return not (v.kind == 'Buffoon' or (v.key or ''):find('buffoon'))
end)

local ban_planet_packs = pool_ids('Booster', function(v)
    return v.kind == 'Celestial' or (v.key or ''):find('celestial')
end)

local ban_tarot_packs = pool_ids('Booster', function(v)
    return v.kind == 'Arcana' or (v.key or ''):find('arcana')
end)

local ban_commons   = pool_ids('Joker', function(v) return v.rarity == 1 or v.rarity == 'Common' end)

--============================================================
-- Baby's First Balatro whitelists (51)
--============================================================
-- Whitelists, so anything unlisted - including every modded object - is banned.

local function pool_whitelist(pool_key, allowed)
    return pool_ids(pool_key, function(v) return not allowed[v.key] end)
end

local BABY_JOKERS = {}
for _, k in ipairs({
    -- flat Chips or Mult on a poker hand, which is the point of the challenge
    'j_joker', 'j_jolly', 'j_zany', 'j_mad', 'j_crazy', 'j_droll',
    'j_sly', 'j_wily', 'j_clever', 'j_devious', 'j_crafty', 'j_half',
    -- flat Chips or Mult per scored suit or face card
    'j_greedy_joker', 'j_lusty_joker', 'j_wrathful_joker', 'j_gluttenous_joker',
    'j_scary_face', 'j_smiley', 'j_arrowhead', 'j_onyx_agate',
    -- Chips or Mult read off something visible on the board
    'j_banner', 'j_mystic_summit', 'j_abstract', 'j_blue_joker', 'j_bull',
    'j_bootstraps', 'j_swashbuckler',
    -- additive scaling that only ever goes up
    'j_supernova', 'j_square', 'j_runner', 'j_trousers', 'j_flash', 'j_fortune_teller',
    'j_hiker',
    -- economy
    'j_egg', 'j_delayed_grat', 'j_golden', 'j_cloud_9', 'j_rocket', 'j_to_the_moon',
    'j_satellite', 'j_gift', 'j_rough_gem',
    -- quality of life
    'j_juggler', 'j_drunkard', 'j_chaos', 'j_splash', 'j_astronomer', 'j_burnt',
    -- scaling that can shrink or spend itself; the text still says exactly what it does
    'j_ice_cream', 'j_popcorn', 'j_green_joker', 'j_ride_the_bus',
    'j_mr_bones', 'j_luchador',
    -- rank-reading Jokers; a fixed rank is still a thing a child can point at
    'j_scholar', 'j_walkie_talkie', 'j_wee', 'j_shoot_the_moon',
    'j_even_steven', 'j_odd_todd', 'j_fibonacci', 'j_stuntman',
}) do BABY_JOKERS[k] = true end

local BABY_TAROTS = {}
for _, k in ipairs({
    'c_empress',        -- Mult cards
    'c_heirophant',     -- Bonus cards; vanilla spells the key this way
    'c_hermit',         -- double money
    'c_temperance',     -- money from Jokers
    'c_high_priestess', -- creates Planets
    'c_emperor',        -- creates Tarots from this same pool
    'c_tower',          -- Stone cards
}) do BABY_TAROTS[k] = true end

local BABY_VOUCHERS = {}
for _, k in ipairs({
    'v_grabber', 'v_nacho_tong', 'v_wasteful', 'v_recyclomancy',
    'v_overstock_norm', 'v_overstock_plus', 'v_clearance_sale', 'v_liquidation',
    'v_seed_money', 'v_money_tree', 'v_crystal_ball', 'v_paint_brush', 'v_palette',
    'v_telescope', 'v_observatory', 'v_planet_merchant', 'v_planet_tycoon',
    'v_tarot_merchant', 'v_tarot_tycoon', 'v_reroll_surplus', 'v_reroll_glut',
    'v_blank', 'v_antimatter',
}) do BABY_VOUCHERS[k] = true end

local ban_nonbaby_jokers  = pool_whitelist('Joker', BABY_JOKERS)
local ban_nonbaby_tarots  = pool_whitelist('Tarot', BABY_TAROTS)
local ban_nonbaby_vouchers = pool_whitelist('Voucher', BABY_VOUCHERS)
-- Enhancements, Editions and Seals are banned into G.GAME.banned_keys at run start
-- instead of through restrictions.banned_cards: the challenge screen cannot render them.

local ban_spectral_packs = pool_ids('Booster', function(v)
    return v.kind == 'Spectral' or (v.key or ''):find('spectral')
end)

-- Skipping is prevented rather than removed, so the button still draws. These two are
-- worth collecting if a Blind is skipped anyway.
local BABY_TAGS = { tag_investment = true, tag_coupon = true }
local ban_nonbaby_tags = pool_whitelist('Tag', BABY_TAGS)


local ban_unlockable_jokers = pool_ids('Joker', function(v)
    if v.rarity == 4 or v.rarity == 'Legendary' then return false end
    return v.unlock_condition ~= nil or v.unlocked == false
end)

--============================================================
-- Deck builders
--============================================================

local function full_deck(enh)
    local t = {}
    for _, s in ipairs(SUITS) do
        for _, r in ipairs(RANKS) do t[#t + 1] = { s = s, r = r, e = enh } end
    end
    return t
end

local function face_deck()
    local t = {}
    for _ = 1, 3 do
        for _, s in ipairs(SUITS) do
            for _, r in ipairs(FACES) do t[#t + 1] = { s = s, r = r } end
        end
    end
    return t
end

local function challenge(key, name, opts)
    opts = opts or {}
    SMODS.Challenge{
        key = key,
        loc_txt = { name = name },
        rules = { custom = opts.custom or {}, modifiers = opts.modifiers or {} },
        jokers = opts.jokers or {},
        consumeables = opts.consumeables or {},
        vouchers = opts.vouchers or {},
        deck = opts.deck or { type = 'Challenge Deck' },
        restrictions = {
            banned_cards = opts.banned_cards or {},
            banned_tags  = opts.banned_tags or {},
            banned_other = opts.banned_other or {},
        },
    }
end

--============================================================
-- Challenges 21-50
--============================================================
challenge('no_refunds', 'No Refunds', { custom = { { id = 'mcp_no_refunds' } } })
challenge('black_market', 'Black Market', { custom = { { id = 'mcp_black_market' } } })
challenge('thrift_store', 'Thrift Store', {
    custom = { { id = 'mcp_thrift_store' }, { id = 'mcp_no_reroll' } },
    vouchers = { { id = 'v_overstock_norm' }, { id = 'v_overstock_plus' } },
})
challenge('impulse_buyer', 'Impulse Buyer', { custom = { { id = 'mcp_impulse_buyer' } } })
challenge('homeless', 'Homeless', {
    custom = { { id = 'mcp_homeless' } },
    modifiers = { { id = 'dollars', value = -20 } },
    jokers = { { id = 'j_vagabond', eternal = true } },
})
local ban_consumable_vouchers = {
    { id = 'v_tarot_merchant' }, { id = 'v_tarot_tycoon' },
    { id = 'v_planet_merchant' }, { id = 'v_planet_tycoon' },
    { id = 'v_observatory' }, { id = 'v_omen_globe' },
}
challenge('ivory_tower', 'Ivory Tower', {
    custom = { { id = 'mcp_ivory_tower' } },
    modifiers = { { id = 'dollars', value = 20 } },
    banned_cards = merge_pools(ban_tarots, ban_planets, ban_spectrals, ban_nonbuffoon_boosters,
                               ban_consumable_vouchers),
    banned_tags = { { id = 'tag_charm' }, { id = 'tag_meteor' }, { id = 'tag_ethereal' } },
})
challenge('new_beginnings', 'New Beginnings', {
    custom = { { id = 'mcp_new_beginnings' } },
    banned_cards = ban_unlockable_jokers,
})
challenge('suit_up', 'Suit Up', {
    custom = { { id = 'mcp_suit_up' } },
    consumeables = { { id = 'c_lovers' }, { id = 'c_fool' } },
    jokers = { { id = 'j_flower_pot', eternal = true } },
    banned_other = {
        { id = 'bl_goad', type = 'blind' }, { id = 'bl_head', type = 'blind' },
        { id = 'bl_club', type = 'blind' }, { id = 'bl_window', type = 'blind' },
    },
})
challenge('one_trick', 'The One Trick', { custom = { { id = 'mcp_one_trick' } } })
challenge('no_common_sense', 'No Common Sense', {
    custom = { { id = 'mcp_no_commons' } },
    banned_cards = ban_commons,
})
challenge('everything_price', 'Everything For a Price', { custom = { { id = 'mcp_all_perishable' } } })
challenge('joker_draft', 'Joker Draft', { custom = { { id = 'mcp_joker_draft' } } })
challenge('legendary_run', 'Legendary Run, but..', {
    custom = { { id = 'mcp_legendary_twist' } },
    modifiers = { { id = 'joker_slots', value = 0 } },
    jokers = {
        { id = 'j_caino',     eternal = true },
        { id = 'j_triboulet', eternal = true },
        { id = 'j_yorick',    eternal = true },
        { id = 'j_chicot',    eternal = true },
        { id = 'j_perkeo',    eternal = true },
    },
    banned_cards = { { id = 'j_luchador' }, { id = 'c_soul' } },
    banned_other = {
        { id = 'bl_final_acorn',  type = 'blind' },
        { id = 'bl_final_vessel', type = 'blind' },
        { id = 'bl_final_heart',  type = 'blind' },
        { id = 'bl_final_bell',   type = 'blind' },
    },
})
challenge('half_a_hand', 'Half a Hand', {
    custom = { { id = 'mcp_half_a_hand' } },
    jokers = { { id = 'j_half', edition = 'negative', eternal = true } },
})
challenge('slow_hands', 'Slow Hands', {
    custom = { { id = 'mcp_slow_hands' } },
    modifiers = { { id = 'hand_size', value = 13 }, { id = 'hands', value = 2 }, { id = 'discards', value = 1 } },
})
challenge('poker_purist', 'Poker Purist', {
    custom = { { id = 'mcp_poker_purist' } },
    jokers = { { id = 'j_space', edition = 'negative' } },
})
challenge('wild_west', 'Wild West', {
    custom = { { id = 'mcp_wild_west' } },
    deck = { type = 'Challenge Deck', cards = full_deck('m_wild') },
})
challenge('balanstro', 'Balanstro', {
    custom = { { id = 'mcp_balanstro' } },
    jokers = { { id = 'j_obelisk', edition = 'negative', eternal = true } },
})
challenge('double_down', 'Double Down', { custom = { { id = 'mcp_double_down' } } })
challenge('final_form', 'Final Form', {
    custom = { { id = 'mcp_final_form' } },
    modifiers = { { id = 'joker_slots', value = 0 } },
})
challenge('recursion', 'Recursion', { custom = { { id = 'mcp_recursion' } } })
challenge('glass_house', 'Glass House', {
    custom = { { id = 'mcp_glass_house' } },
    deck = { type = 'Challenge Deck', cards = full_deck('m_glass') },
})
challenge('rusty_deck', 'Rusty Deck', {
    custom = { { id = 'mcp_rusty_deck' } },
    deck = { type = 'Challenge Deck', cards = full_deck('m_steel') },
})
challenge('ancient_technology', 'Ancient Technology', {
    custom = { { id = 'mcp_ancient_tech' } },
    banned_cards = merge_pools(ban_planets, ban_planet_packs),
    banned_tags = { { id = 'tag_meteor' } },
})
challenge('stargazer', 'Stargazer', {
    custom = { { id = 'mcp_stargazer' } },
    banned_cards = merge_pools(ban_tarots, ban_tarot_packs),
    banned_tags = { { id = 'tag_charm' } },
})
challenge('recovered', 'The Recovered', {
    custom = { { id = 'mcp_recovered' } },
    modifiers = { { id = 'hand_size', value = 5 } },
    deck = { type = 'Challenge Deck', cards = face_deck() },
})
challenge('tenant', 'The Tenant', {
    custom = {
        { id = 'mcp_tenant' },
        { id = 'money_per_hand', value = 2, no_ui = true },
    },
    banned_cards = { { id = 'j_credit_card' } },
    banned_other = { { id = 'bl_ox', type = 'blind' } },
})
challenge('gambler', 'The Gambler', {
    custom = { { id = 'mcp_gambler' }, { id = 'mcp_gambler_risk' } },
    banned_cards = { { id = 'v_reroll_surplus' }, { id = 'v_reroll_glut' } },
})
challenge('long_game', 'The Long Game', { custom = { { id = 'mcp_long_game' } } })
challenge('trial', 'The Trial', {
    custom = { { id = 'mcp_trial' } },
    jokers = { { id = 'j_luchador' } },
    banned_cards = { { id = 'j_chicot' }, { id = 'v_directors_cut' }, { id = 'v_retcon' } },
    banned_tags = { { id = 'tag_boss' } },
})
challenge('baby', "Baby's First Balatro", {
    custom = {
        { id = 'mcp_baby' },
        { id = 'mcp_baby_jokers' },
        { id = 'mcp_baby_bosses' },
        { id = 'mcp_baby_scaling' },
    },
    modifiers = {
        { id = 'hands',       value = 5 },   -- vanilla 4
        { id = 'discards',    value = 4 },   -- vanilla 3
        { id = 'dollars',     value = 10 },  -- vanilla 4
        { id = 'joker_slots', value = 5 },
    },
    banned_cards = merge_pools(ban_nonbaby_jokers, ban_nonbaby_tarots, ban_nonbaby_vouchers,
                               ban_spectrals, ban_spectral_packs),
    banned_tags = ban_nonbaby_tags,
})
