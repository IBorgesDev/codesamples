--!strict

export type Kind = {
    name: string,
    rarity: number,
}

local kinds: { [string]: Kind } = {
    egg_common = { name = "Common Egg", rarity = 1 },
    egg_rare = { name = "Rare Egg", rarity = 2 },
    pet_cat = { name = "Cat", rarity = 2 },
    pet_dragon = { name = "Dragon", rarity = 4 },
    rod_golden = { name = "Golden Rod", rarity = 3 },
}

for _, kind in kinds do
    table.freeze(kind)
end

return table.freeze(kinds)
