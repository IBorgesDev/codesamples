--!strict

local http_service = game:GetService("HttpService")

const LENGTH = 12

return string.sub((string.gsub(http_service:GenerateGUID(false), "-", "")), 1, LENGTH)
