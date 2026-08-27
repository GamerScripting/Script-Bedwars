# Script-Bedwars
Bedwars luau script

Hinweis: einige Executor (oder Umgebungen) liefern beim direkten Zugriff auf raw.githubusercontent.com 404/403. Um das zu umgehen habe ich die Datei `Script.lua` hinzugefügt und Beispiele für kompatible Loadstring‑Varianten unten eingefügt.

Empfohlene Loadstring-Optionen

1) Schneller, kompatibler CDN-Load (jsDelivr):

```lua
-- funktioniert in game:HttpGet und den meisten Executors
loadstring(game:HttpGet("https://cdn.jsdelivr.net/gh/GamerScripting/Script-Bedwars@main/Script.lua"))()
```

2) Direkter Raw-GitHub mit Header (z.B. Synapse):

```lua
local r = syn.request({
  Url = "https://raw.githubusercontent.com/GamerScripting/Script-Bedwars/main/Script.lua",
  Method = "GET",
  Headers = { ["User-Agent"] = "Mozilla/5.0" }
})
loadstring(r.Body)()
```

3) Fallback: raw.githack / raw.githack CDN

```lua
loadstring(game:HttpGet("https://raw.githack.com/GamerScripting/Script-Bedwars/main/Script.lua"))()
```

Wenn du mir sagst, welchen Executor du verwendest (z. B. Synapse, Krnl, Fluxus), kann ich dir die jeweils passendste Variante bereitstellen.
