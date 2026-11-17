--!strict

local warned: { [string]: boolean } = {}

return function(name: string, interval: number, step: () -> ...any)
    task.spawn(function()
        while true do
            task.wait(interval)
            local ok, problem = pcall(step)
            if not ok and not warned[name] then
                warned[name] = true
                warn(`[{name}] step failed: {problem}`)
            end
        end
    end)
end
