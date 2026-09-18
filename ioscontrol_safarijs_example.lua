-- Example: execute arbitrary JavaScript in the current inspectable Safari page.

local BIN = "/var/jb/usr/local/bin/safarijs"
local DIR = "/var/mobile/Library/IOSControl/Scripts/"

local js = [[
(() => {
    return {
        title: document.title,
        url: location.href,
        inputs: document.querySelectorAll('input').length
    };
})()
]]

writeFile("run_safari.js", js)

execute(
    BIN .. " eval-file " ..
    DIR .. "run_safari.js > " ..
    DIR .. "run_safari_result.json 2>&1"
)

sleep(1)

local result = readFile("run_safari_result.json")

log("SafariJS result:")
log(tostring(result))
