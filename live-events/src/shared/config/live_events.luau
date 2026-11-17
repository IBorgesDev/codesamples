--!strict

export type Definition = {
    id: string,
    kind: "counter" | "vote",
    shards: number,
    title: string,
    options: { string },
    labels: { [string]: string },
    goal: { option: string, target: number }?,
    reward_coins: number?,
    ends_at: number?,
}

local definitions: { Definition } = {
    {
        id = "world_fishing",
        kind = "counter",
        shards = 1,
        title = "World Fishing Event",
        options = { "fish" },
        labels = { fish = "Fish caught worldwide" },
        goal = { option = "fish", target = 1_000_000 },
        reward_coins = 100,
        ends_at = nil,
    },
    {
        id = "boss_vote",
        kind = "vote",
        shards = 1,
        title = "Choose the next boss",
        options = { "kraken", "megalodon", "leviathan" },
        labels = { kraken = "Kraken", megalodon = "Megalodon", leviathan = "Leviathan" },
        goal = nil,
        reward_coins = nil,
        ends_at = nil,
    },
}

for _, definition in definitions do
    table.freeze(definition)
end

return table.freeze(definitions)
