--!strict

local replicated_storage = game:GetService("ReplicatedStorage")

local tuning = require(replicated_storage.Shared.config.tuning)

const SECONDS_PER_MINUTE = 60
const UPDATE_RU = 2
const SET_RU = 1
const GET_RU = 1
const PRESENCE_BYTES = 48
const SESSION_BYTES = 2 * 1024
const COORDINATION_WRITES = 3
const PARTIES = 2

export type Scenario = {
    name: string,
    ccu: number,
    players_per_server: number,
}

export type Load = {
    session_minutes: number,
    cross_trades_per_player_minute: number,
    trade_minutes: number,
    changes_per_trade: number,
    hints_per_trade: number,
    spammer_share: number?,
}

export type Plan = {
    trades_per_minute: number,
    ru_presence: number,
    ru_trades: number,
    ru_spam: number,
    ru_quota: number,
    ru_share: number,
    hottest_session_read: number,
    busiest_map_ru: number,
    memory_bytes: number,
    memory_quota: number,
    deliveries_per_game: number,
    delivery_limit_game: number,
}

local capacity = {}

local function per_minute(interval: number): number
    return SECONDS_PER_MINUTE / interval
end

function capacity.plan(scenario: Scenario, load: Load): Plan
    local config = tuning.trade
    local store = tuning.platform.memory_store
    local messaging = tuning.platform.messaging
    local servers = math.ceil(scenario.ccu / scenario.players_per_server)
    local joins = scenario.ccu / load.session_minutes
    local refreshes = scenario.ccu * per_minute(config.presence_refresh)
    local ru_presence = joins * (SET_RU + UPDATE_RU) + refreshes * SET_RU

    local trades = scenario.ccu * load.cross_trades_per_player_minute
    local polls_per_minute = PARTIES * per_minute(config.remote_poll_interval)
    local ru_per_trade = SET_RU
        + (load.changes_per_trade + COORDINATION_WRITES) * UPDATE_RU
        + polls_per_minute * load.trade_minutes * GET_RU
    local ru_trades = trades * ru_per_trade
    local quota = store.ru_base + store.ru_per_ccu * scenario.ccu
    local session_minutes = load.trade_minutes + config.closed_ttl / SECONDS_PER_MINUTE

    local spammers = scenario.ccu * (load.spammer_share or 0)
    local spam_changes = config.cross_pace.rate * SECONDS_PER_MINUTE
    local spam_sessions = per_minute(config.cross_answer_cooldown)
    local spam_alive = math.ceil(config.closed_ttl / config.cross_answer_cooldown) + 1
    local ru_spam = spammers
        * (spam_sessions * SET_RU + spam_changes * (UPDATE_RU + GET_RU) + polls_per_minute * GET_RU)
    local ru_total = ru_presence + ru_trades + ru_spam

    return {
        trades_per_minute = trades,
        ru_presence = ru_presence,
        ru_trades = ru_trades,
        ru_spam = ru_spam,
        ru_quota = quota,
        ru_share = ru_total / quota,
        hottest_session_read = polls_per_minute * GET_RU
            + math.max(load.changes_per_trade / load.trade_minutes, spam_changes) * UPDATE_RU,
        busiest_map_ru = ru_total / config.coordinator_maps,
        memory_bytes = scenario.ccu * PRESENCE_BYTES
            + trades * session_minutes * SESSION_BYTES
            + spammers * spam_alive * SESSION_BYTES,
        memory_quota = store.memory_base + store.memory_per_ccu * scenario.ccu,
        deliveries_per_game = trades * load.hints_per_trade + spammers * (spam_changes + 2 * spam_sessions),
        delivery_limit_game = messaging.per_game_base + messaging.per_game_per_server * servers,
    }
end

function capacity.check(plan: Plan): { string }
    local limits = tuning.platform
    local store = limits.memory_store
    local problems = {}

    local function require_that(ok: boolean, message: string)
        if not ok then
            table.insert(problems, message)
        end
    end

    require_that(plan.ru_share <= limits.trade_ru_share, `RU share {plan.ru_share}`)
    require_that(plan.hottest_session_read <= store.read_per_key * limits.safety, "session key reads")
    require_that(
        plan.busiest_map_ru <= store.partitions_per_map * store.per_partition * limits.safety,
        `busiest coordinator map {plan.busiest_map_ru} RU/min`
    )
    require_that(plan.memory_bytes <= plan.memory_quota * limits.trade_ru_share, `memory {plan.memory_bytes}`)
    require_that(
        plan.deliveries_per_game <= plan.delivery_limit_game * limits.safety,
        `MessagingService deliveries {plan.deliveries_per_game}/min`
    )

    return problems
end

return capacity
