# Script-Bedwars

Loader für meine Roblox-Skripte. In diesem Repo liegt **nur der Loader** —
das eigentliche Skript wird nach erfolgreicher Key-Prüfung vom Server geladen
und steht nirgends in diesen Dateien.

## Loadstrings

**BedWars**

```lua
loadstring(game:HttpGet("https://cdn.jsdelivr.net/gh/GamerScripting/Script-Bedwars@main/loader/bedwars.lua"))()
```

**RUNAWAYS** — läuft nur in einer laufenden Runde, nicht in der Lobby.

```lua
loadstring(game:HttpGet("https://cdn.jsdelivr.net/gh/GamerScripting/Script-Bedwars@main/loader/runaways.lua"))()
```

Beim ersten Start fragt der Loader nach deinem Key. Danach merkt er ihn sich —
neu eingeben musst du ihn nur nach einem Update.

Jedes Skript hat **eigene Keys**: ein BedWars-Key funktioniert nicht bei
RUNAWAYS und umgekehrt.

## Falls jsDelivr klemmt

Manche Executor bekommen bei `raw.githubusercontent.com` ein 404/403. Dafür
gibt es zwei Ausweichwege:

```lua
-- raw.githack
loadstring(game:HttpGet("https://raw.githack.com/GamerScripting/Script-Bedwars/main/loader/runaways.lua"))()
```

```lua
-- raw.githubusercontent mit User-Agent (Synapse u. ä.)
local r = request({
  Url = "https://raw.githubusercontent.com/GamerScripting/Script-Bedwars/main/loader/runaways.lua",
  Method = "GET",
  Headers = { ["User-Agent"] = "Mozilla/5.0" }
})
loadstring(r.Body)()
```

`Script` und `Script.lua` im Wurzelverzeichnis sind der BedWars-Loader unter
den alten Pfaden — sie bleiben liegen, damit bereits verteilte Loadstrings
weiter funktionieren.
