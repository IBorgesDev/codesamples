--!nocheck

local server_storage = game:GetService("ServerStorage")

const SPEC_SUFFIX = "%.spec$"

return function()
    local dev_packages = server_storage:FindFirstChild("DevPackages")
    local tests = server_storage:FindFirstChild("Tests")

    if not (dev_packages and tests and dev_packages:FindFirstChild("TestEZ")) then
        warn("[tests] TestEZ or ServerStorage.Tests missing, skipped")
        return
    end

    local test_ez = require(dev_packages.TestEZ)
    local silent = { report = function() end }
    local specs = {}
    for _, child in tests:GetDescendants() do
        if child:IsA("ModuleScript") and string.match(child.Name, SPEC_SUFFIX) then
            table.insert(specs, child)
        end
    end

    table.sort(specs, function(a, b)
        return a.Name < b.Name
    end)

    local passed, failed, skipped = 0, 0, 0
    local errors = {}
    for _, spec in specs do
        local results = test_ez.TestBootstrap:run({ spec }, silent)
        passed += results.successCount
        failed += results.failureCount
        skipped += results.skippedCount
        for _, message in results.errors do
            table.insert(errors, `{spec.Name}: {message}`)
        end

        task.wait()
    end

    if failed > 0 then
        warn(`[tests] {failed} FAILED, {passed} passed`)
        for _, message in errors do
            warn("[tests] " .. tostring(message))
        end
    else
        print(`[tests] all {passed} passed ({skipped} skipped) in {#specs} spec files`)
    end
end
