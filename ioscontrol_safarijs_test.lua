log("===== IOSCONTROL -> SAFARIJS TEST =====")

local BIN = "/var/jb/usr/local/bin/safarijs"
local SCRIPTS = "/var/mobile/Library/IOSControl/Scripts/"

-- Open a real Safari page first.
openURL("https://example.com")
sleep(6)

-- 1. Probe local Web Inspector transport.
execute(
    BIN .. " probe > " ..
    SCRIPTS .. "safarijs_probe.json 2>&1"
)

sleep(1)

local probe = readFile("safarijs_probe.json")

log("")
log("=== PROBE ===")
log(tostring(probe))

-- 2. List Safari / WebKit targets.
execute(
    BIN .. " list > " ..
    SCRIPTS .. "safarijs_list.json 2>&1"
)

sleep(1)

local listing = readFile("safarijs_list.json")

log("")
log("=== LIST ===")
log(tostring(listing))

-- 3. Use a file for JavaScript so shell quoting cannot corrupt the code.
writeFile(
    "safarijs_input.js",
    "document.title"
)

execute(
    BIN .. " eval-file " ..
    SCRIPTS .. "safarijs_input.js > " ..
    SCRIPTS .. "safarijs_result.json 2>&1"
)

sleep(1)

local result = readFile("safarijs_result.json")

log("")
log("=== EVAL document.title ===")
log(tostring(result))

log("")
log("===== END SAFARIJS TEST =====")
