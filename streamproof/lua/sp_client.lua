--!nocheck
--!nolint UnknownGlobal
--!nolint LocalShadow
-- ===========================================================================
--  STREAMPROOF-BRUECKE  (Client-Seite)                        Version 1.0.0
-- ===========================================================================
--  Was das hier tut, in einem Satz: es macht die eigenen Visuals INNERHALB
--  von Roblox unsichtbar und zeichnet sie stattdessen in einem externen
--  Windows-Fenster, das der Bildschirmaufnahme entzogen ist.
--
--  WARUM ueberhaupt ein zweites Programm?
--  Roblox rendert in seinen eigenen Swapchain. Alles, was dort gezeichnet
--  wird, landet zwangslaeufig in jeder Aufnahme dieses Fensters - es gibt
--  keinen Schalter, keine Eigenschaft und keinen Trick, mit dem eine
--  ScreenGui fuer OBS oder Discord unsichtbar waere. Die einzige Stelle, an
--  der Windows selbst eine Ausnahme kennt, ist ein EIGENES Fenster:
--  SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE). Das Fenster
--  verschwindet dann aus jeder Aufnahme, und - das ist der Punkt, der
--  frueher anders war - der Rest des Bildschirms bleibt ganz normal
--  sichtbar. Kein schwarzes Bild, das Spiel laesst sich weiter streamen.
--
--  WIE die Anzeige identisch bleibt, ohne sie nachzubauen:
--  Dieses Modul baut die GUI nicht nach. Es LIEST den echten GUI-Baum, den
--  das Hauptskript ohnehin erzeugt, und schickt ihn als Liste flacher
--  Zeichenbefehle (Rechteck, Text, Bild, Clip) an das Programm. Damit sieht
--  das Overlay automatisch genauso aus wie das Original - auch bei allem,
--  was spaeter dazukommt, ohne dass hier eine Zeile geaendert werden muss.
--
--  WARUM das Original dabei trotzdem weiterlaufen muss:
--  Nur wenn die GUI weiter existiert und weiter LAYOUTET wird, gibt es
--  ueberhaupt etwas zu spiegeln - und nur dann nimmt sie weiter Klicks
--  entgegen. Beides wurde an diesem Build nachgemessen:
--    * ScreenGui in einer CanvasGroup mit GroupTransparency = 1
--      -> vollstaendig unsichtbar, AbsolutePosition/AbsoluteSize rechnen
--         weiter (Text von "Hello" auf einen laengeren Text geaendert:
--         115x20 -> 274x20, waehrend unsichtbar). Buttons bleiben klickbar.
--    * BillboardGui mit Enabled = false
--      -> unsichtbar, Kinder rechnen ebenfalls weiter (23x16 -> 225x16,
--         deckungsgleich mit TextService:GetTextSize = 225).
--  Du klickst also weiter das echte, unsichtbare Panel an derselben Stelle,
--  an der du das Overlay siehst. Es gibt keine zweite Eingabeebene, die
--  auseinanderlaufen koennte.
--
--  WAS HIER NICHT PASSIERT: es wird nichts in den Roblox-Prozess
--  geschrieben, nichts gehookt und nichts injiziert. Die Bruecke ist eine
--  WebSocket-Verbindung nach 127.0.0.1 - dieselbe Art Verbindung, die der
--  Executor ohnehin anbietet. Das Programm liest nur, was dieses Skript
--  ihm schickt, und zeichnet es in sein eigenes Fenster.
-- ===========================================================================

local HttpService  = game:GetService("HttpService")
local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local GuiService   = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer  = Players.LocalPlayer

--  Eine eventuell noch laufende aeltere Fassung sauber beenden, bevor die
--  neue sich einrichtet - sonst haengen zwei Sende-Schleifen an derselben
--  Verbindung und das Overlay bekommt jeden Frame doppelt.
do
	local g = (getgenv and getgenv()) or _G
	local old = rawget(g, "SP")
	if type(old) == "table" and type(old.shutdown) == "function" then
		pcall(old.shutdown)
	end
end

local SP = {}
do
	local g = (getgenv and getgenv()) or _G
	g.SP = SP
	_G.SP = SP
end

--------------------------------------------------------------------
-- Konfiguration
--------------------------------------------------------------------
SP.VERSION  = "1.0.0"
SP.PORT     = 7373
SP.BASE     = "http://127.0.0.1:7373"
SP.WSURL    = "ws://127.0.0.1:7373/ws"
--  Wo das Programm liegt. Wird in die Zwischenablage gelegt, wenn es nicht
--  gefunden wird - Links lassen sich aus Roblox heraus nicht oeffnen.
SP.DOWNLOAD = "https://github.com/GamerScripting/Script-Bedwars/releases/latest"

--  Die ScreenGuis des Hauptskripts. Beide werden gespiegelt und beide
--  verschwinden beim Aktivieren.
SP.SCREENGUIS = { "KitPanel_MCP", "KitInvHud_MCP" }

--  Zustand. "status" ist das, was die Keybinds-Seite anzeigt:
--    off        aus
--    searching  sucht das Programm
--    missing    Programm laeuft nicht (Download in der Zwischenablage)
--    nohttp     Executor hat keine HTTP-Funktion
--    on         laeuft, Frames gehen raus
--    lost       Verbindung waehrend des Betriebs verloren
SP.active   = false
SP.status   = "off"
SP.note     = ""
SP.fps      = 0
SP.prims    = 0
SP.appVer   = "?"

--------------------------------------------------------------------
-- Takt: wo die Millisekunden wirklich liegen
--------------------------------------------------------------------
--  Die Verbindung ist NICHT der Engpass. Ueber 127.0.0.1 ist ein
--  WebSocket-Paket in deutlich unter einer Millisekunde drueben; es gibt
--  auf dem Weg keinen Puffer, der etwas zurueckhaelt. Teuer ist einzig das
--  ABLESEN des GUI-Baums, und zwar sehr ungleich verteilt:
--
--    Welt-Tags   ~40-300 Befehle. Sie MUESSEN jeden Frame neu, weil sie
--                mit der Kamera wandern - eine Tag-Position, die einen
--                Frame alt ist, klebt sichtbar hinterher. Kostet fast
--                nichts, bleibt also auf voller Bildrate.
--    Panel       1500-4000 Befehle. Es steht zwischen zwei Neuaufbauten
--                vollkommen still (das Hauptskript zeichnet es selbst nur
--                bei geaendertem Fingerabdruck neu). Es jeden Frame
--                abzulesen waere der gesamte Mehraufwand dieses Moduls -
--                fuer null sichtbaren Unterschied.
--
--  NACHGEMESSEN, nicht geschaetzt. Ein Panel mit 1045 GuiObjects (also
--  etwa der Groesse, die eine volle Lobby erzeugt) ergibt 829 Befehle und
--  73 KB Text, und ein Durchlauf kostet 2,69 ms. Daraus folgt unmittelbar:
--
--      bei  60 Hz  ->  161 ms je Sekunde  =  16 % durchgehend
--      bei  30 Hz  ->   81 ms je Sekunde  =   8 %
--      bei  10 Hz  ->   27 ms je Sekunde  =   2,7 %
--
--  Sechzig Mal je Sekunde ein Panel abzulesen, das sich zwischen zwei
--  Klicks kein Pixel bewegt, waere also der teuerste Teil des ganzen
--  Werkzeugs - fuer nichts. Deshalb 30 Hz als Ausgangswert (fluessig genug
--  fuer Scrollen und die Hover-Uebergaenge, das Einzige, was sich ohne
--  Neuaufbau aendert), dazu SP.touch(): jeder echte Neuaufbau schickt das
--  Panel SOFORT, unabhaengig vom Takt. Ein Klick ist damit ohne messbare
--  Verzoegerung drueben.
--
--  Und der Normalfall kostet gar nichts: ist das Panel zu, steigt der
--  Durchlauf sofort aus (die ScreenGui ist dann nicht Enabled) - dann
--  laufen nur die Tags, und die sind zwei Groessenordnungen billiger.
--
--  NACHTRAG - die Zahlen oben stammen aus der ersten Fassung, seither ist
--  ein Durchlauf deutlich billiger. Die beiden teuersten Stellen waren
--  naemlich nicht das Zusammenbauen des Textes, sondern:
--    * tostring(...):gsub(...) auf Enum-Werte, je Textelement und Bild -
--      bei zweihundert Elementen und sechzig Bildern sind das
--      vierundzwanzigtausend Zeichenketten je Sekunde, nur um eine 0 oder
--      eine 1 zu bekommen;
--    * FindFirstChildOfClass fuer Ecke, Rahmen und Polster, dreimal je
--      Element und Bild - jedes Mal ein Durchlauf durch die Kinderliste.
--  Beides wird jetzt nachgeschlagen statt berechnet: Tabellen mit dem Enum
--  selbst als Schluessel, und eine schwache Tabelle fuer die Zusatzobjekte,
--  die sich ohnehin nie aendern. Damit ist die volle Bildrate auch fuers
--  Panel vertretbar - und genau darauf steht es jetzt.
--
--  budgetMs ist die Notbremse fuer ein Panel, das groesser wird als alles
--  bisher Gemessene: dauert ein Durchlauf laenger, faellt die Rate von
--  selbst, bis er wieder hineinpasst. Sie bleibt, denn "schnell genug" ist
--  keine Zusicherung fuer ein Panel, das erst noch wachsen kann.
SP.rate = {
	tags      = 0,    -- Hz; 0 = jeder gerenderte Frame (empfohlen)
	panel     = 240,  -- Obergrenze, wenn sich wirklich etwas tut
	panelIdle = 15,   -- Hz, wenn sich nichts tut
	--  Die Bremse begrenzt die DAUERLAST, nicht die Einzelkosten.
	--
	--  Erst stand hier "ein Durchlauf darf hoechstens 4 ms kosten" - das ist
	--  die falsche Frage. Ein Durchlauf von 3 ms ist harmlos; 3 ms
	--  hundertachtzehn Mal je Sekunde sind es nicht, das sind fuenfunddreissig
	--  Prozent Dauerlast, und genau die waren als Ruckeln beim Kameraschwenk
	--  zu spueren. Also wird gerechnet, was es in der Sekunde kostet, und
	--  die Rate danach gesetzt: bei 3 ms je Durchlauf und zwoelf Prozent
	--  Deckel sind das vierzig Bilder je Sekunde - fuers Auge derselbe
	--  Eindruck, ein Drittel der Last.
	--  ZWEI Deckel statt einem - das ist die "variable Bildfrequenz".
	--
	--  Die beiden Faelle sind voellig verschieden teuer wert:
	--    * Du schiebst das Panel, scrollst oder faehrst mit der Maus
	--      darueber. Dann zaehlt jede Millisekunde Verzoegerung, denn ein
	--      Fenster, das der Maus nachhinkt, fuehlt sich sofort kaputt an.
	--      Hier darf es teuer sein: es dauert ein paar Sekunden.
	--    * Das Panel steht still. Dann ist jeder weitere Durchlauf
	--      vollstaendig umsonst - dasselbe Bild, nur teurer.
	--
	--  Ein einziger Mittelwert muss beide Faelle falsch bedienen: hoch
	--  genug fuers Ziehen heisst dauerhaft zu teuer, sparsam genug fuer
	--  den Ruhezustand heisst zaeh beim Ziehen. Also wird umgeschaltet.
	--  Diese Zahlen sind Anteile EINER SEKUNDE Rechenzeit auf dem
	--  Render-Thread des Spiels, und sie kosten Bildrate genau in diesem
	--  Verhaeltnis. 0.35 stand hier einmal und hat aus 240 Bildern 156
	--  gemacht - nachgerechnet und nachgemessen. Auch "beim Bedienen" ist so
	--  etwas zu teuer: ein Panel, das mit 60 statt 190 Hz nachzieht, sieht
	--  identisch aus, weil der Bildschirm ohnehin nicht mehr zeigt.
	maxLoadBusy = 0.08, -- waehrend du das Panel wirklich bedienst
	maxLoadIdle = 0.01, -- wenn nichts passiert
	busyFor     = 0.4,  -- Sekunden, die eine Eingabe als "busy" gilt
	minPanel    = 8,    -- so weit darf heruntergeregelt werden
}

--  Von aussen setzbar, damit die App die Werte fernsteuern kann.
function SP.setRate(tagsHz, panelHz)
	if tonumber(tagsHz)  then SP.rate.tags  = math.clamp(tonumber(tagsHz), 0, 240) end
	if tonumber(panelHz) then SP.rate.panel = math.clamp(tonumber(panelHz), 1, 240) end
end

--  Die Leistungsstufen, die das Programm hier herueberschickt.
--
--  Der Grund, warum das von aussen einstellbar sein muss und nicht fest
--  verdrahtet: was "flott" kostet, entscheidet der Rechner, nicht dieses
--  Modul. Auf einem 240-Hz-Rechner mit Luft nach oben ist die volle Rate
--  richtig; auf einem Notebook, das im Spiel schon bei 45 Bildern haengt,
--  ist jede Millisekunde, die dieses Modul nimmt, eine, die das Spiel
--  verliert. Darum drei Stufen statt einer Vermutung.
function SP.setProfile(name)
	local r = SP.rate
	if name == "spar" then
		r.tags, r.panel, r.panelIdle       = 60,  40,  4
		r.maxLoadBusy, r.maxLoadIdle       = 0.03, 0.005
		r.busyFor, r.minPanel              = 0.5, 4
	elseif name == "max" then
		r.tags, r.panel, r.panelIdle       = 0,   240, 20
		r.maxLoadBusy, r.maxLoadIdle       = 0.15, 0.03
		r.busyFor, r.minPanel              = 0.35, 10
	else -- "normal"
		--  maxLoadBusy war 0.08 (acht Prozent). Bei einem Panel mit vielen
		--  Zeilen - Team-Liste, Kit-Icons, Schloss- und Rang-Abzeichen je
		--  Zeile - kostet ein Durchlauf mehrere Millisekunden, und acht
		--  Prozent Budget reichten dann nicht, um die eingestellten 120 Hz
		--  wirklich zu erreichen: "erlaubt" blieb weit darunter haengen, das
		--  Panel zog beim Ziehen/Scrollen sichtbar nach. Gemeldet als "die
		--  update rate soll 120 sein, so wie sie ist ruckelt es".
		--
		--  Zwoelf Prozent gelten NUR waehrend SP.busy (siehe busyFor) -
		--  ein paar Zehntelsekunden beim Bedienen, danach sofort wieder das
		--  ungeaenderte, fast kostenlose maxLoadIdle. Das ist etwas mehr als
		--  die 0.35, die frueher 240 Bilder auf 156 gedrueckt haben - aber
		--  nur ein Drittel davon, und nur im kurzen Bedienfenster statt
		--  dauerhaft.
		--
		--  Obergrenze 180 statt 150: bei einem grossen Panel (volles
		--  Team-Raster mit vielen Zeilen) reichte 120 als Ziel oft nicht,
		--  weil "erlaubt" schon vorher an der Kostenrechnung haengen blieb -
		--  die Obergrenze war also selten das eigentliche Limit. Auf
		--  ausdruecklichen Wunsch weiter angehoben (150 -> 180): aendert am
		--  kostenbasierten Regler selbst nichts (der bleibt die eigentliche
		--  Bremse - siehe maxLoadBusy/-Idle direkt darunter), hebt aber die
		--  Decke fuer die Faelle an, in denen ein billiges Panel sie vorher
		--  unnoetig frueh getroffen hat. Welt-Tags (r.tags) stehen bereits
		--  auf 0 - "jeder gerenderte Frame", also schon schneller als jede
		--  feste Zahl es waere; fuer sie gibt es hier nichts anzuheben.
		r.tags, r.panel, r.panelIdle       = 0,   180, 10
		r.maxLoadBusy, r.maxLoadIdle       = 0.12, 0.01
		r.busyFor, r.minPanel              = 0.4, 10
	end
	SP.profile = name or "normal"
	return SP.profile
end

--  Das Hauptskript kann nach einem Neuaufbau SP.touch() rufen; dann geht
--  das Panel sofort raus statt auf sein naechstes Zeitfenster zu warten.
--  Ohne diesen Ruf funktioniert alles genauso, nur um bis zu 50 ms traeger.
function SP.touch()
	SP.dirty = true
	--  Ein Neuaufbau tauscht die Elemente aus; die gemerkten Scrollflaechen
	--  zeigen dann auf Zerstoertes, und die gemerkten Zusatzobjekte
	--  (UICorner/UIStroke/UIPadding) gehoeren zu Elementen, die es nicht
	--  mehr gibt.
	SP.dropScrollCache = true
	SP.dropDeco = true
end

--  Registry aller BillboardGuis, die das Hauptskript erzeugt hat. Gefuellt
--  vom Haken in dessen new()-Funktion (siehe INTEGRATION.md), damit ein
--  frisch gebautes Tag gar nicht erst einen Frame lang sichtbar ist.
--  KEINE schwache Tabelle. Das war ein Fehler, und ein schwer zu findender.
--
--  Ein __mode = "k" haelt seine Schluessel nicht am Leben - was bei Instanzen
--  genau das Falsche ist: Roblox kann die LUA-HUELLE einer Instanz einsammeln,
--  obwohl die Instanz selbst weiter im Baum haengt. Beim naechsten Zugriff
--  ueber den Baum entsteht eine neue Huelle, aber der Eintrag in dieser
--  Tabelle ist weg.
--
--  Nachgemessen: zwanzig eigens angelegte Testschilder waren nach wenigen
--  Sekunden aus SP.tags verschwunden, waehrend ihr Ordner im Baum noch stand.
--
--  Die Folge war schlimmer als ein Leck. Ein Schild, das aus dieser Tabelle
--  faellt, ist in Roblox weiter abgeschaltet (das hat die Bruecke ja getan)
--  und wird vom Overlay nicht mehr gezeichnet - es ist also UEBERALL
--  unsichtbar. Die Spieler-Nametags kamen jedes Mal zurueck, weil updateTag
--  sie alle halbe Sekunde neu anmeldet; Drop-, Kit- und Bienen-ESP melden
--  sich nur bei der Erzeugung an und blieben weg. Genau das Muster
--  "manche ESP sind mal da und mal nicht".
--
--  Also stark, und dafuer aktiv aufgeraeumt: der Sicherheitsdurchlauf
--  (enforceTags, viermal je Sekunde) wirft alles heraus, dessen Parent nil
--  ist. Zerstoert das Hauptskript ein Schild, ist es damit spaetestens eine
--  Viertelsekunde spaeter auch hier weg.
SP.tags = {}

--  ...und daneben, WAS DAS HAUPTSKRIPT WILL.
--
--  Das hier ist die Stelle, an der die Generator-Schilder verschwunden sind,
--  und der Fehler war grundsaetzlicher Art: beide Seiten haben dieselbe
--  Eigenschaft benutzt, um zwei verschiedene Dinge zu sagen.
--
--    Das Hauptskript setzt gui.Enabled, um "dieses Schild soll man sehen"
--    zu sagen (Filter an/aus, eigenes Team ausgeschlossen, Tags-Taste).
--    Diese Bruecke setzt gui.Enabled = false, um es in Roblox stumm zu
--    stellen, weil es ja im Overlay gezeichnet wird.
--
--  Sobald beide gleichzeitig schrieben, war der Wert nur noch der des
--  letzten Schreibers. Der erste Anlauf war, im Hauptskript
--  "... and not SP.active" anzuhaengen - damit schrieb es immer false, und
--  die Bruecke konnte nicht mehr unterscheiden, ob ein Schild aus ist, weil
--  SIE es abgeschaltet hat, oder weil der Filter es nicht will. Sie hat dann
--  entweder alle gezeigt (auch die ausgefilterten) oder gar keine.
--
--  Jetzt sind es zwei getrennte Werte: SP.want ist der Wunsch des Skripts,
--  gui.Enabled gehoert allein dieser Bruecke. Gezeichnet wird, was gewuenscht
--  ist; sichtbar in Roblox ist es nur, wenn die Bruecke aus ist.
SP.want = {}

--  Gehaltene Bildschirmstelle je Schild, gegen Mikrobewegungen (siehe
--  halte()). Hier oben deklariert und nicht erst dort: enforceTags raeumt
--  die Tabelle mit auf, und enforceTags steht weiter oben - genau dieser
--  Ordnungsfehler hat schon einmal sofort einen Laufzeitfehler geworfen.
--  Eine stabile Kennung je Schild.
--
--  Sie ist der Schluessel zu der einzigen Aenderung, die das Zucken wirklich
--  wegnimmt. Bisher wurde jede Bewegung eines Schildes als "der Inhalt dieser
--  Kachel hat sich geaendert" behandelt - also musste die ganze Kachel neu
--  gezeichnet und neu ueber die CPU geschoben werden. Bei zwanzig Schildern
--  sind das zwanzig Schiebevorgaenge je Bild, und darin liegt die Grenze von
--  etwa hundertzwanzig Bildern je Sekunde.
--
--  Mit einer Kennung kann das Programm jedem Schild ein eigenes kleines
--  Fenster geben: bewegt sich das Schild, wird nur das FENSTER verschoben,
--  und die Pixel bleiben, wo sie sind. Genau so macht es Roblox selbst mit
--  einem BillboardGui - dieselben Pixel, neue Stelle. Neu gezeichnet wird nur
--  noch, wenn sich Text oder Farbe wirklich aendern.
local tagIds = {}
local tagIdNext = 0

local function idOf(gui)
	local id = tagIds[gui]
	if not id then
		tagIdNext += 1
		id = tagIdNext
		tagIds[gui] = id
	end
	return id
end

local HALTE = 0.6
local held = {}


function SP.note_tag(inst)
	if typeof(inst) == "Instance" and inst:IsA("BillboardGui") then
		SP.tags[inst] = true
		if SP.want[inst] == nil then SP.want[inst] = inst.Enabled and true or false end
		--  SOFORT stumm stellen, noch bevor ein Bild damit gezeichnet wird.
		--  Ein Schild, das erst im naechsten Takt verschwindet, ist genau
		--  der eine Frame, den eine Aufnahme mitnimmt.
		if SP.active then SP.hideTag(inst) end
	end
end

--  "Soll man dieses Schild gerade sehen?" - die Frage, die das Hauptskript
--  an mehreren Stellen stellt und bisher mit gui.Enabled beantwortet hat.
--
--  Solange die Bruecke laeuft, ist gui.Enabled aber IMMER false, denn so
--  wird das Schild in Roblox stumm gestellt. Ein Takt, der darauf abfragt,
--  haelt jedes Schild fuer abgeschaltet und hoert auf, es zu fuellen. Genau
--  das ist passiert: updateTagVitals stieg bei "not gui.Enabled" aus, HP
--  und Entfernung wurden nie geschrieben, und im Overlay stand in jeder
--  Zeile "Label" - der Standardtext einer leeren TextLabel. Es sah aus, als
--  kaemen die Daten nicht an; geschrieben wurden sie nie.
function SP.tag_live(gui)
	if typeof(gui) ~= "Instance" then return false end
	if not SP.active then return gui.Enabled end
	return SP.want[gui] ~= false
end

--  Der Weg, den das Hauptskript benutzt, statt gui.Enabled selbst zu setzen.
--
--  Enabled gehoert waehrend des Betriebs der Bruecke (sie setzt es auf
--  false, um das Schild in Roblox stumm zu stellen). Der WUNSCH des
--  Hauptskripts landet daneben in SP.want. Beides getrennt zu fuehren ist
--  der ganze Punkt: nur so laesst sich "der Filter will das nicht zeigen"
--  von "die Bruecke hat es versteckt" unterscheiden - und genau diese
--  Unterscheidung fehlte, als die Generator-Schilder erst ueberall und dann
--  nirgends zu sehen waren.
function SP.tag_state(gui, want)
	if typeof(gui) ~= "Instance" then return end
	want = want and true or false
	SP.tags[gui] = true
	SP.want[gui] = want
	if SP.active then
		SP.hideTag(gui)
	elseif gui.Enabled ~= want then
		gui.Enabled = want
	end
end

--------------------------------------------------------------------
-- Transport
--------------------------------------------------------------------
local function httpFn()
	return (syn and syn.request) or (http and http.request) or http_request or request
end

--  Laeuft das Programm? Kurze Anfrage an den eigenen Rechner. Absichtlich
--  synchron: der Aufrufer will genau jetzt wissen, ob er umschalten kann
--  oder den Download melden muss.
--
--  DREI VERSUCHE, NICHT EINER. Gemeldet: frisch heruntergeladen, App
--  geoeffnet, sofort K gedrueckt - "Programm nicht gefunden", obwohl es
--  lief. Ursache: ein einziger Versuch mit 0.5s Timeout, direkt nach dem
--  Start der App. In den ersten Sekunden laufen dort im Hintergrund
--  Guard.Scan() (alle Prozesse durchgehen) und die Update-Suche gleichzeitig
--  gegen den ThreadPool - die eine HTTP-Anfrage, die genau in dieses
--  Fenster faellt, kann knapp ueber 0.5s brauchen, obwohl die App laengst
--  laeuft. Jetzt: bis zu drei Versuche mit steigendem Timeout, kurze Pause
--  dazwischen - kostet im guten Fall (App laengst warm) weiterhin nur die
--  ersten Millisekunden, im schlechten Fall (kalter Start) bis zu 3s statt
--  eines sofortigen Fehlschlags.
function SP.probe()
	local req = httpFn()
	if type(req) ~= "function" then
		SP.status, SP.note = "nohttp", "executor has no HTTP function"
		return false
	end

	for attempt, timeout in ipairs({ 0.5, 1, 1.5 }) do
		local ok, res = pcall(req, { Url = SP.BASE .. "/ping", Method = "GET", Timeout = timeout })
		local body = ok and type(res) == "table" and (res.Body or res.body) or nil
		if type(body) == "string" and body:find("streamproof", 1, true) then
			local okJ, t = pcall(function() return HttpService:JSONDecode(body) end)
			SP.appVer = (okJ and type(t) == "table" and tostring(t.version)) or "?"
			SP.status, SP.note = "searching", ""
			return true
		end
		if attempt < 3 then task.wait(0.3) end
	end

	SP.status, SP.note = "missing", "companion app not running"
	return false
end

local function wsConnect()
	local mk = (WebSocket and WebSocket.connect)
		or (syn and syn.websocket and syn.websocket.connect)
	if type(mk) ~= "function" then return nil end
	local ok, sock = pcall(mk, SP.WSURL)
	if not ok or type(sock) ~= "userdata" and type(sock) ~= "table" then return nil end
	return sock
end

--------------------------------------------------------------------
-- Sichtbarkeit: das Original verstecken, ohne es anzuhalten
--------------------------------------------------------------------
--  ScreenGui -> alle Kinder wandern in eine CanvasGroup, deren
--  GroupTransparency auf 1 steht. Nachgemessen: das Layout laeuft weiter,
--  die Klickflaechen bleiben. Enabled = false waere der naive Weg und
--  wuerde beides kaputt machen.
--
--  Die Gruppe heisst "SPGroup" und traegt keine eigene Optik (kein
--  Hintergrund, volle Flaeche, Position 0,0) - fuer die Kinder aendert
--  sich dadurch kein einziger Absolutwert.
local function groupOf(gui, make)
	local grp = gui:FindFirstChild("SPGroup")
	if grp or not make then return grp end
	grp = Instance.new("CanvasGroup")
	grp.Name                   = "SPGroup"
	grp.BackgroundTransparency = 1
	grp.BorderSizePixel        = 0
	grp.Position               = UDim2.fromScale(0, 0)
	grp.Size                   = UDim2.fromScale(1, 1)
	grp.ZIndex                 = 0
	grp.GroupTransparency      = 1
	grp.Parent                 = gui

	--  Was das Hauptskript spaeter noch an die ScreenGui haengt (der
	--  Tooltip zum Beispiel), muss ebenfalls in die Gruppe - sonst waere
	--  ausgerechnet das eine Element sichtbar, das ueber allem liegt.
	--  Die Verbindung wird je GUI gemerkt und beim Aufloesen getrennt;
	--  ohne das sammelt jedes Ein- und Ausschalten eine weitere an.
	SP.conns = SP.conns or {}
	if SP.conns[gui] then pcall(function() SP.conns[gui]:Disconnect() end) end
	SP.conns[gui] = gui.ChildAdded:Connect(function(ch)
		if not SP.active then return end
		if ch == grp or not ch:IsA("GuiObject") then return end
		task.defer(function()
			if SP.active and ch.Parent == gui and grp.Parent then ch.Parent = grp end
		end)
	end)
	return grp
end

local function hideScreenGui(gui)
	local grp = groupOf(gui, true)
	for _, ch in ipairs(gui:GetChildren()) do
		if ch ~= grp and ch:IsA("GuiObject") then ch.Parent = grp end
	end
	grp.GroupTransparency = 1
end

local function showScreenGui(gui)
	--  Erst die Verbindung trennen, DANN zurueckraeumen: sonst sieht der
	--  ChildAdded-Haken die zurueckwandernden Kinder und schiebt sie in die
	--  Gruppe, die gerade aufgeloest wird.
	if SP.conns and SP.conns[gui] then
		pcall(function() SP.conns[gui]:Disconnect() end)
		SP.conns[gui] = nil
	end
	local grp = groupOf(gui, false)
	if not grp then return end
	for _, ch in ipairs(grp:GetChildren()) do
		if ch:IsA("GuiObject") then ch.Parent = gui end
	end
	grp:Destroy()
end

local function eachScreenGui(fn)
	local hui = nil
	pcall(function() hui = gethui() end)
	for _, root in ipairs({ hui, game:GetService("CoreGui") }) do
		if root then
			for _, name in ipairs(SP.SCREENGUIS) do
				local gui = root:FindFirstChild(name)
				if gui and gui:IsA("ScreenGui") then fn(gui) end
			end
		end
	end
end

--  Einmaliger Nachzug beim Aktivieren: Tags, die schon standen, bevor der
--  Haken in new() sie mitbekommen konnte (etwa nach einer Neu-Injektion).
--  Ein voller Workspace-Durchlauf ist teuer, darum genau einmal.
local function collectExistingTags()
	local ok, list = pcall(function() return workspace:GetDescendants() end)
	if not ok then return end
	for _, d in ipairs(list) do
		if d:IsA("BillboardGui") and d.Name:find("_MCP", 1, true) then
			SP.tags[d] = true
		end
	end
end

--  WELT-TAGS UNSICHTBAR MACHEN - der Weg dorthin war ein Umweg, und beide
--  Irrtuemer sind es wert, hier zu stehen.
--
--  Ausgangspunkt: gui.Enabled = false. Sicher unsichtbar, kostet Roblox
--  nichts (nicht gezeichnet heisst nicht gerechnet) - aber im Overlay
--  standen manche Schilder an der falschen Stelle und zeigten Zeilen mit
--  "Label" statt Text.
--
--  Erster Erklaerungsversuch: "ein abgeschaltetes BillboardGui rechnet sein
--  Layout nicht weiter". Nachgemessen an einem Schild, das im Bild war:
--
--      1 normal           bb=230x100  pill=64x34@82,66  name=90
--      2 Pill unsichtbar  bb=230x100  pill=64x34@82,66  name=226
--      3 Enabled=false    bb=230x100  pill=64x34@82,66  name=340
--
--  Das Layout laeuft also auch abgeschaltet weiter. Die Erklaerung war
--  falsch.
--
--  Der echte Grund, sichtbar an einem Schild, das gerade NICHT im Bild war:
--  dort steht bb=0x0 - und dann loesen alle Kinder, die ihre Position in
--  Scale angeben, gegen eine Box der Groesse null auf. Aus "mittig in 230"
--  wird "bei minus der halben eigenen Breite":
--
--      im Bild        pill@ 82,66
--      nicht im Bild  pill@-26,-34
--
--  Ein Schild, das ERZEUGT wird, waehrend die Bruecke laeuft, wird nie ein
--  einziges Mal gezeichnet - es bleibt also dauerhaft auf 0x0 stehen und
--  korrigiert sich nie. Genau das waren die Generator-Schilder und die
--  Namensschilder neuer Spieler.
--
--  Der zweite Irrtum war der Versuch, das mit einer CanvasGroup zu loesen
--  (wie bei den ScreenGuis, wo es nachweislich traegt): Kinder in eine
--  CanvasGroup mit GroupTransparency = 1, Schild bleibt AN. Zwei Probleme,
--  beide gemeldet: die Gruppe mit Size = fromScale(1,1) wird selbst 0x0,
--  wenn das Schild 0x0 ist - das Problem blieb also -, und in einem
--  BillboardGui versteckt GroupTransparency nicht. Das Ergebnis war ein
--  doppeltes Bild: einmal im Spiel, einmal im Overlay darueber.
--
--  Was traegt, ist die Verbindung aus beiden Erkenntnissen:
--    * Enabled = false zum Verstecken. Es versteckt wirklich, und es ist
--      der billigste Weg - fuer schwache Rechner der einzige richtige.
--    * Ein Rahmen mit Groesse in PIXELN um die Kinder. Weil seine Groesse
--      nicht am Schild haengt, loesen Scale-Positionen auch dann richtig
--      auf, wenn das Schild noch nie gezeichnet wurde. Nachgemessen: mit
--      Size = fromOffset(230,100) steht der Rahmen auf 230x100 und die
--      Pille wieder auf 82,66.
--  DAS SCHILD BLEIBT, WIE ES IST. Kein Rahmen, keine Gruppe, nichts
--  umgehaengt - und das ist der dritte und letzte Anlauf.
--
--  Anlauf zwei war ein Rahmen "SPBox" mit Groesse in Pixeln, in den die
--  Kinder wanderten. Er hat die Positionen tatsaechlich repariert und
--  prompt etwas Schlimmeres kaputt gemacht: das Hauptskript sucht seine
--  Pille mit gui:FindFirstChild("Pill"), also nur eine Ebene tief. Lag sie
--  im Rahmen, fand updateTag sie nicht mehr, brach ab - und fuellte die
--  Zeilen nie. Im Overlay stand dann in jedem Namensschild "Label", der
--  Roblox-Standardtext einer leeren TextLabel. Gemeldet als "er fetched die
--  Infos nicht richtig". Genau umgekehrt: die Infos kamen richtig an, sie
--  wurden nie geschrieben.
--
--  Merksatz daraus: an einem fremden GUI-Baum darf man die STRUKTUR nicht
--  anfassen. Sichtbarkeit ja, Reihenfolge ja - aber nicht, wo etwas haengt.
--
--  Versteckt wird also schlicht mit Enabled = false. Das versteckt wirklich
--  (die CanvasGroup tat es in einem BillboardGui nicht, siehe unten), und
--  es ist der billigste Weg fuer Roblox: nicht gezeichnet heisst nicht
--  gerechnet, was auf schwachen Rechnern genau der Punkt ist.
--
--  Das Positionsproblem bleibt damit bestehen - ein nie gezeichnetes Schild
--  hat AbsoluteSize 0x0, und Kinder mit Position in Scale loesen dann gegen
--  null auf. Das wird jetzt dort geloest, wo es entsteht: beim Serialisieren
--  wird der Scale-Anteil selbst nachgerechnet (siehe serializeTags).
function SP.hideTag(gui)
	--  Aufraeumen nach Anlauf zwei: falls noch ein SPBox im Baum haengt,
	--  wandern die Kinder zurueck. Ohne das bliebe eine einmal umgebaute
	--  Sitzung fuer immer kaputt.
	local stale = gui:FindFirstChild("SPBox")
	if stale then
		for _, ch in ipairs(stale:GetChildren()) do
			if ch:IsA("GuiObject") then ch.Parent = gui end
		end
		stale:Destroy()
	end
	if gui.Enabled then gui.Enabled = false end
end

local function showTag(gui)
	local stale = gui:FindFirstChild("SPBox")
	if stale then
		for _, ch in ipairs(stale:GetChildren()) do
			if ch:IsA("GuiObject") then ch.Parent = gui end
		end
		stale:Destroy()
	end
	--  Zurueck auf den Wunsch des Hauptskripts, nicht pauschal auf AN.
	--  Sonst standen nach dem Abschalten auch die ausgefilterten
	--  Generatoren wieder da.
	local w = SP.want[gui]
	if w == nil then w = true end
	if gui.Enabled ~= w then gui.Enabled = w end
end

--  Das Netz unter dem Haken in new(): Schilder, die auf einem anderen Weg
--  entstanden sind, und Kinder, die nachtraeglich an ein Schild gehaengt
--  wurden. Laeuft im langsamen Takt (viermal je Sekunde), NICHT je Bild -
--  je Bild waere es ein GetChildren() mal Anzahl Schilder, also ein paar
--  tausend Wegwerf-Tabellen je Sekunde fuer einen Fall, der selten eintritt.
--  "Gehoert dieses Schild noch zum Spiel?"
--
--  Parent == nil allein reicht dafuer NICHT, und das ist der Unterschied
--  zwischen einer Tabelle, die sich selbst aufraeumt, und einer, die
--  vollaeuft: wird ein Charakter zerstoert, hat das Namensschild darin
--  weiterhin seinen Kopf als Parent - nur haengt dieser Kopf an nichts mehr.
--  Nachgemessen: bei zwanzig Spielern standen achtzig Eintraege in SP.tags,
--  und jeder davon kostet in jedem Bild eine Runde durch die Schleife.
local function lebt(gui)
	if typeof(gui) ~= "Instance" then return false end
	if gui.Parent == nil then return false end
	local ok, inGame = pcall(function() return gui:IsDescendantOf(game) end)
	return ok and inGame
end

local function enforceTags(on)
	for gui in pairs(SP.tags) do
		if not lebt(gui) then
			SP.tags[gui] = nil
			SP.want[gui] = nil
			held[gui] = nil
			tagIds[gui] = nil
		elseif on then
			SP.hideTag(gui)
		end
	end
end

--------------------------------------------------------------------
-- Serialisierung: GUI-Baum -> flache Zeichenbefehle
--------------------------------------------------------------------
--  Das Format ist bewusst mager gehalten, weil es bis zu sechzig Mal je
--  Sekunde ueber die Leitung geht. Ein Befehl ist ein JSON-Objekt mit
--  einem Buchstaben als Art:
--     r  Rechteck   (Farbe, Transparenz, Eckenradius, Rahmen)
--     t  Text       (Groesse, Gewicht, Ausrichtung, RichText, Kontur)
--     i  Bild       (Roblox-Asset-URL, Fuellart, Eckenradius)
--     c  Clip auf   (ab hier wird auf dieses Rechteck beschnitten)
--     e  Clip zu
--  Die Transparenz wird unveraendert uebernommen (0 = deckend), damit auf
--  beiden Seiten dieselben Zahlen stehen wie in den Roblox-Eigenschaften.

--  EIN Puffer, und nur EIN Schreiber zur Zeit.
--
--  Der Puffer ist bewusst modulweit und nicht je Aufruf neu: er wird
--  dreissig Mal je Sekunde gefuellt, eine frische Tabelle je Durchlauf
--  waere reine Arbeit fuer den Garbage Collector. Der Preis dafuer ist,
--  dass zwei gleichzeitige Durchlaeufe sich gegenseitig den Inhalt
--  zerschiessen wuerden - genau das ist beim Einrichten passiert, als die
--  Diagnose aus einem zweiten Thread mitten in die Sende-Schleife lief.
--  Der Waechter laesst den zweiten Aufruf leer zurueckkommen, statt ein
--  halbes Bild zu liefern.
local buf, bn, busy = {}, 0, false
local function put(s) bn += 1; buf[bn] = s end

local function hex(c)
	return ("%02X%02X%02X"):format(
		math.floor(c.R * 255 + 0.5),
		math.floor(c.G * 255 + 0.5),
		math.floor(c.B * 255 + 0.5))
end

--  JSON-Textliteral. gsub mit einer Tabelle statt fuenf Einzelaufrufen -
--  das hier laeuft ueber jedes Label in jedem Frame.
local JESC = {
	['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r",
	["\t"] = "\\t", ["\b"] = "\\b", ["\f"] = "\\f",
}
local function jstr(s)
	s = tostring(s):gsub('[%c"\\]', function(ch)
		return JESC[ch] or ("\\u%04x"):format(ch:byte())
	end)
	return '"' .. s .. '"'
end

local function num(v)
	--  Ganze Zahlen ohne Nachkommastellen: spart je Wert ein paar Bytes,
	--  und Pixel sind ohnehin ganzzahlig.
	if v == math.floor(v) then return ("%d"):format(v) end
	return ("%.2f"):format(v)
end

--  Enum.Font -> Schriftgewicht. Die App kennt keine Roblox-Schriften, sie
--  braucht Familie plus Gewicht. Der Name traegt das Gewicht selbst, also
--  wird er gelesen statt eine Tabelle mit sechzig Eintraegen zu pflegen.
--  Schluessel ist das Enum selbst, nicht sein Name: so faellt das tostring
--  nach dem ersten Mal je Schriftart weg.
local WEIGHT = {}
local function weightOf(font)
	local w = WEIGHT[font]
	if w then return w end
	local n = tostring(font):lower()
	w = 400
	if     n:find("black")    then w = 900
	elseif n:find("semibold") then w = 600
	elseif n:find("bold")     then w = 700
	elseif n:find("medium")   then w = 500
	elseif n:find("light")    then w = 300 end
	WEIGHT[font] = w
	return w
end

--  Die Enum-Werte DIREKT als Schluessel, nicht ihre Namen.
--
--  Vorher stand hier tostring(inst.TextXAlignment):gsub("^Enum...", "") - das
--  sind zwei String-Operationen je Textelement und Durchlauf, bei
--  zweihundert Elementen und sechzig Bildern je Sekunde also
--  vierundzwanzigtausend Zeichenketten in der Sekunde, nur um eine Null oder
--  eine Eins zu bekommen. Eine Tabelle mit dem Enum selbst als Schluessel
--  kostet nichts.
local ALIGN_X = {
	[Enum.TextXAlignment.Left] = 0, [Enum.TextXAlignment.Center] = 1,
	[Enum.TextXAlignment.Right] = 2,
}
local ALIGN_Y = {
	[Enum.TextYAlignment.Top] = 0, [Enum.TextYAlignment.Center] = 1,
	[Enum.TextYAlignment.Bottom] = 2,
}
local SCALE_M = {
	[Enum.ScaleType.Stretch] = 0, [Enum.ScaleType.Fit] = 1,
	[Enum.ScaleType.Crop] = 2, [Enum.ScaleType.Slice] = 0,
	[Enum.ScaleType.Tile] = 0,
}
local TRUNC_END = Enum.TextTruncate.AtEnd

--  Ecke, Rahmen und Polster eines Elements - EINMAL nachgesehen, dann
--  gemerkt.
--
--  FindFirstChildOfClass geht die Kinderliste durch. Dreimal je Element und
--  Durchlauf ist bei zweihundert Elementen sechshundert Durchlaeufe durch
--  Kinderlisten, und das bei jedem Bild. Die Zusatzobjekte einer GUI
--  aendern sich praktisch nie - sie werden beim Bauen angelegt und bleiben.
--  Und NICHT schwach, obwohl das hier ein reiner Zwischenspeicher ist.
--
--  Der Grund ist derselbe, der SP.tags getroffen hat (siehe dort): Roblox
--  sammelt die Lua-Huelle einer Instanz ein, obwohl die Instanz weiter im
--  Baum haengt. Eine schwache Tabelle verliert ihre Eintraege deshalb
--  staendig - der Zwischenspeicher trifft dann fast nie, und genau die
--  sechshundert Durchlaeufe durch Kinderlisten je Bild, die er sparen
--  sollte, fallen wieder an. Ein Zwischenspeicher, der nicht trifft, ist
--  reine Verwaltung.
--
--  Aufgeraeumt wird darum von Hand, und zwar an der Stelle, an der es
--  wirklich noetig ist: SP.touch() meldet jeden Neuaufbau des Panels, und
--  ein Neuaufbau ist genau der Moment, in dem alte Elemente zerstoert
--  werden. Dazu eine Obergrenze als Notbremse.
local deco = {}
local decoN = 0

local function decoClear()
	deco = {}
	decoN = 0
end

local function decoOf(inst)
	local d = deco[inst]
	if d then return d end
	d = {
		corner  = inst:FindFirstChildOfClass("UICorner"),
		stroke  = inst:FindFirstChildOfClass("UIStroke"),
		padding = inst:FindFirstChildOfClass("UIPadding"),
	}
	--  Eine volle Lobby erzeugt ein Panel mit gut tausend Elementen; das
	--  Vielfache davon braucht niemand zu behalten.
	if decoN > 8000 then decoClear() end
	deco[inst] = d
	decoN += 1
	return d
end

local function padOf(d)
	local p = d.padding
	if not p or p.Parent == nil then return 0, 0, 0, 0 end
	return p.PaddingLeft.Offset, p.PaddingRight.Offset,
	       p.PaddingTop.Offset, p.PaddingBottom.Offset
end

local function cornerOf(d, w, h)
	local c = d.corner
	if not c or c.Parent == nil then return 0 end
	local r = c.CornerRadius
	return r.Offset + r.Scale * math.min(w, h)
end

--  Verblassen statt verschwinden (siehe SP.occlusionFade weiter unten):
--  fade laeuft von 0 (unveraendert) bis knapp unter 1 (fast unsichtbar).
--  Schiebt jede Transparenz naeher an 1 heran, nie darueber hinaus - ein
--  bereits unsichtbares Element (t=1) bleibt unsichtbar, eines mit t=0
--  landet bei genau fade.
local function fadeT(t, fade)
	if not fade or fade <= 0 then return t end
	return t + (1 - t) * fade
end

--  Ein einzelner GuiObject. ox/oy verschieben den ganzen Baum: bei einer
--  ScreenGui ist das der GUI-Inset (AbsolutePosition zaehlt ab UNTERHALB
--  der Topbar, das Fenster des Overlays faengt aber oben an), bei einem
--  Billboard die projizierte Bildschirmstelle. fade: siehe fadeT oben -
--  wie stark dieses (Welt-Tag-)Schild gerade verdeckt ist, 0 fuer alles
--  ausserhalb der Welt-Tags (Panel kennt keine Ueberdeckung durch andere
--  Panel-Elemente in diesem Sinne).
local function emit(inst, ox, oy, fade)
	if not inst:IsA("GuiObject") or not inst.Visible then return end

	local ap, as = inst.AbsolutePosition, inst.AbsoluteSize
	local x, y, w, h = ap.X + ox, ap.Y + oy, as.X, as.Y
	if w <= 0 or h <= 0 then
		--  Kein Platz, aber Kinder koennen trotzdem herausragen (bei
		--  AutomaticSize passiert das staendig) - also nicht abbrechen.
		w, h = math.max(w, 0), math.max(h, 0)
	end

	local d   = decoOf(inst)
	local rad = cornerOf(d, w, h)

	--  Hintergrund
	--
	--  ACHTUNG, hier lag ein Fehler, der teuer war: die Teile eines
	--  Befehls duerfen NICHT in mehreren put() landen. Am Ende werden alle
	--  Eintraege mit KOMMA verbunden (table.concat(buf, ",")), aus
	--  '{"k":"r"...' + ',"sc"...' + '}' wurde also
	--  '{"k":"r"..., ,"sc"..., }' - ungueltiges JSON, und die App hat
	--  daraufhin jedes Bild verworfen. Aufgefallen ist es erst am echten
	--  Panel, weil nur Elemente MIT Rahmen betroffen waren; die Testbilder
	--  hatten keinen. Ein Befehl, ein put().
	if inst.BackgroundTransparency < 1 and w > 0 and h > 0 then
		local s = d.stroke
		local t = ('{"k":"r","x":%s,"y":%s,"w":%s,"h":%s,"c":"%s","a":%s,"r":%s')
			:format(num(x), num(y), num(w), num(h),
				hex(inst.BackgroundColor3), num(fadeT(inst.BackgroundTransparency, fade)), num(rad))
		if s and s.Transparency < 1 and s.Thickness > 0 then
			t = t .. (',"sc":"%s","st":%s,"sa":%s')
				:format(hex(s.Color), num(s.Thickness), num(fadeT(s.Transparency, fade)))
		end
		put(t .. "}")
	elseif w > 0 and h > 0
		and not (inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox")) then
		--  Rahmen ohne Fuellung gibt es auch (Chips mit transparentem Grund).
		--  NICHT fuer Text: ein UIStroke im Contextual-Modus auf einem
		--  TextLabel (genESP/dropESP, siehe deren stroke()-Aufrufe) soll die
		--  GLYPHEN umranden, keine Box um den ganzen Text ziehen - das war
		--  genau diese Box, faelschlich auch fuer Text gezogen (gemeldet als
		--  "Rahmen um die Schrift"). Der Text-Block unten greift fuer diesen
		--  Fall stattdessen selbst auf d.stroke zurueck.
		local s = d.stroke
		if s and s.Transparency < 1 and s.Thickness > 0 then
			put(('{"k":"r","x":%s,"y":%s,"w":%s,"h":%s,"a":1,"r":%s,"sc":"%s","st":%s,"sa":%s}')
				:format(num(x), num(y), num(w), num(h), num(rad),
					hex(s.Color), num(s.Thickness), num(fadeT(s.Transparency, fade))))
		end
	end

	--  Bild
	if (inst:IsA("ImageLabel") or inst:IsA("ImageButton"))
		and inst.Image ~= "" and inst.ImageTransparency < 1 then
		put(('{"k":"i","x":%s,"y":%s,"w":%s,"h":%s,"u":%s,"a":%s,"r":%s,"sm":%d,"c":"%s"}')
			:format(num(x), num(y), num(w), num(h), jstr(inst.Image),
				num(fadeT(inst.ImageTransparency, fade)), num(rad),
				SCALE_M[inst.ScaleType] or 0,
				hex(inst.ImageColor3)))
	end

	--  Text
	if (inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox")) then
		local txt = inst.Text
		if inst:IsA("TextBox") and txt == "" then
			txt = inst.PlaceholderText
		end
		if txt ~= "" and inst.TextTransparency < 1 then
			local pl, pr, pt, pb = padOf(d)
			local so, sk = inst.TextStrokeTransparency, inst.TextStrokeColor3
			--  Manche Tags (genESP/dropESP) nutzen statt der eingebauten
			--  TextStroke-Eigenschaften ein echtes UIStroke im
			--  Contextual-Modus (kraeftiger, an die Glyphen gebunden statt an
			--  die Box) - siehe deren stroke()-Aufrufe. Die eingebauten
			--  Eigenschaften bleiben dabei auf Standard (unsichtbar), sonst
			--  faellt der Kontur-Text hier faelschlich auf "keine Kontur"
			--  zurueck.
			if so >= 1 and d.stroke and d.stroke.Transparency < 1 and d.stroke.Thickness > 0 then
				so, sk = d.stroke.Transparency, d.stroke.Color
			end
			so = fadeT(so, fade)
			--  Wieder: EIN Befehl, EIN put() - siehe die Begruendung oben.
			local t = ('{"k":"t","x":%s,"y":%s,"w":%s,"h":%s,"s":%s,"f":%d,"c":"%s","a":%s,"ax":%d,"ay":%d,"tr":%d,"rt":%d,"wr":%d,"tx":%s')
				:format(num(x + pl), num(y + pt), num(math.max(0, w - pl - pr)),
					num(math.max(0, h - pt - pb)),
					num(inst.TextSize), weightOf(inst.Font),
					hex(inst.TextColor3), num(fadeT(inst.TextTransparency, fade)),
					ALIGN_X[inst.TextXAlignment] or 0,
					ALIGN_Y[inst.TextYAlignment] or 1,
					(inst.TextTruncate == TRUNC_END) and 1 or 0,
					inst.RichText and 1 or 0,
					inst.TextWrapped and 1 or 0,
					jstr(txt))
			if so < 1 then
				t = t .. (',"so":%s,"sk":"%s"'):format(num(so), hex(sk))
			end
			put(t .. "}")
		end
	end

	--  ViewportFrame kann nicht gespiegelt werden - darin steckt ein
	--  3D-Modell, und das rendert Roblox selbst. Statt es zu faelschen
	--  bekommt die Stelle einen Platzhalter; betroffen ist allein das
	--  Mech-Renderbild der Stufe 1, alles andere sind echte 2D-Bilder.
	if inst:IsA("ViewportFrame") and w > 0 and h > 0 then
		put(('{"k":"r","x":%s,"y":%s,"w":%s,"h":%s,"c":"3C4252","a":%s,"r":%s}')
			:format(num(x), num(y), num(w), num(h), num(fadeT(0.35, fade)), num(rad)))
	end

	--  Kinder. ZIndexBehavior ist im Hauptskript "Sibling": Geschwister
	--  werden nach ZIndex sortiert, der Baum bleibt sonst die Reihenfolge.
	local kids = {}
	for _, ch in ipairs(inst:GetChildren()) do
		if ch:IsA("GuiObject") and ch.Visible then kids[#kids + 1] = ch end
	end
	if #kids == 0 then return end
	if #kids > 1 then
		--  Stabil sortieren: bei gleichem ZIndex bleibt die Baumreihenfolge,
		--  sonst springen gleichrangige Elemente von Frame zu Frame.
		local idx = {}
		for i, ch in ipairs(kids) do idx[ch] = i end
		table.sort(kids, function(a, b)
			if a.ZIndex ~= b.ZIndex then return a.ZIndex < b.ZIndex end
			return idx[a] < idx[b]
		end)
	end

	local clip = inst.ClipsDescendants and w > 0 and h > 0
	if clip then
		put(('{"k":"c","x":%s,"y":%s,"w":%s,"h":%s}'):format(num(x), num(y), num(w), num(h)))
	end
	for _, ch in ipairs(kids) do emit(ch, ox, oy, fade) end
	if clip then put('{"k":"e"}') end

	--  Scrollbalken. Roblox zeichnet ihn selbst und er taucht im Baum nicht
	--  auf - ohne ihn saehe eine lange Liste im Overlay so aus, als gaebe
	--  es nichts mehr zu scrollen.
	if inst:IsA("ScrollingFrame") and inst.ScrollBarThickness > 0 then
		local cs, ws = inst.AbsoluteCanvasSize, inst.AbsoluteWindowSize
		local th = inst.ScrollBarThickness
		if cs.Y > ws.Y + 1 and ws.Y > 0 then
			local f = ws.Y / cs.Y
			local len = math.max(20, ws.Y * f)
			local pos = (inst.CanvasPosition.Y / math.max(1, cs.Y - ws.Y)) * (ws.Y - len)
			put(('{"k":"r","x":%s,"y":%s,"w":%s,"h":%s,"c":"%s","a":%s,"r":%s}')
				:format(num(x + w - th), num(y + pos), num(th), num(len),
					hex(inst.ScrollBarImageColor3), num(inst.ScrollBarImageTransparency), num(th / 2)))
		end
		if cs.X > ws.X + 1 and ws.X > 0 then
			local f = ws.X / cs.X
			local len = math.max(20, ws.X * f)
			local pos = (inst.CanvasPosition.X / math.max(1, cs.X - ws.X)) * (ws.X - len)
			put(('{"k":"r","x":%s,"y":%s,"w":%s,"h":%s,"c":"%s","a":%s,"r":%s}')
				:format(num(x + pos), num(y + h - th), num(len), num(th),
					hex(inst.ScrollBarImageColor3), num(inst.ScrollBarImageTransparency), num(th / 2)))
		end
	end
end

--  Alle Panel-ScreenGuis in einen JSON-Array-Text. Der GUI-Inset kommt
--  dazu: AbsolutePosition zaehlt ab der Unterkante der Topbar, das
--  Overlay-Fenster deckt aber die ganze Client-Flaeche ab. An diesem Build
--  gemessen sind das 58 Pixel - der Wert wird trotzdem jeden Frame
--  gelesen, weil er sich mit ein-/ausgeblendeter Topbar aendert.
local function serializeScreen()
	if busy then return "[]", 0 end
	if SP.dropDeco then SP.dropDeco = false; decoClear() end
	busy = true
	buf, bn = {}, 0
	local inset = GuiService:GetGuiInset()
	local ok, err = pcall(function()
		eachScreenGui(function(gui)
			if not gui.Enabled then return end
			local grp = groupOf(gui, false)
			for _, ch in ipairs((grp or gui):GetChildren()) do
				if ch:IsA("GuiObject") then emit(ch, inset.X, inset.Y) end
			end
		end)
	end)
	busy = false
	if not ok then
		--  Ein einzelnes kaputtes Element darf nicht die ganze Bruecke
		--  abschalten - es faellt nur dieses Bild aus.
		SP.lastError = tostring(err)
		return "[]", 0
	end
	return "[" .. table.concat(buf, ",") .. "]", bn
end

--  Die Welt-Tags. Jedes BillboardGui wird an seiner Adornee-Position auf
--  den Bildschirm projiziert; die Kinder tragen ihre Position relativ zur
--  Billboard-Box, die um den projizierten Punkt zentriert ist.
--
--  WorldToViewportPoint rechnet ohne GUI-Inset, deckt sich also direkt mit
--  dem Fenster des Overlays - hier darf NICHTS dazuaddiert werden.
--  WIEVIEL DARF SICH UEBERDECKEN?
--
--  In einer vollen Lobby oder einem Nahkampf stehen zwanzig Schilder
--  uebereinander. Alle voll zu zeichnen kostet nicht nur Rechenzeit - man
--  liest auch keines davon mehr richtig.
--
--  ZWEI ANLAEUFE, GANZ WEGLASSEN, BEIDE ZURUECKGENOMMEN.
--
--  Erster Anlauf: Hysterese (zwei Schwellen statt einer). Live getestet,
--  wieder zurueckgenommen - "alles kaputt", Schilder weg, die eigentlich
--  da sein sollten, abhaengig davon, wie die Kamera stand.
--
--  Zweiter Anlauf: der eigentliche Fehler war gefunden und behoben - die
--  Pruefschleife lief in derselben Reihenfolge wie die Sortierung
--  (WEITESTE zuerst, siehe oben) und testete jedes Schild damit
--  ausschliesslich gegen noch WEITER ENTFERNTE, statt gegen naehere -
--  ein Schild kann aber nur von etwas verdeckt werden, das NAEHER an der
--  Kamera steht. Mit der Pruefung umgekehrt (naechstes zuerst, siehe
--  drop() unten) traf die Berechnung selbst wieder zu. Trotzdem: live
--  angesehen "klappt nur so halb" - hartes Weglassen bleibt ein Sprung
--  (da, dann weg), und genau dieser Sprung ist das Eigentliche, was
--  stoert, nicht die Berechnung dahinter.
--
--  SP.declutter bleibt deshalb aus (0 = kein hartes Weglassen mehr). Die
--  Berechnung von eben (drop(), naechstes-zuerst) bleibt stehen - falls
--  hartes Weglassen doch nochmal gebraucht wird, ist sie richtig, nur
--  gerade nicht angeschlossen.
SP.declutter = 0

--  STATTDESSEN: VERBLASSEN STATT VERSCHWINDEN.
--
--  Kein Sprung mehr, keine Gefahr eines falsch verschwundenen Schildes -
--  ein staerker verdecktes Schild wird nur zunehmend durchsichtiger,
--  bleibt aber IMMER da, nur schwaecher. Das vordere, unverdeckte Schild
--  wirkt dadurch von selbst kraeftiger, rein durch den Kontrast - ohne
--  dass seine eigenen Farben angefasst werden muessten.
--
--  0 schaltet ab. 0.85 (der Vorschlag unten) heisst: ein zu 100 % von
--  naeheren Schildern bedecktes Schild verliert bis zu 85 % seiner
--  Deckkraft - nie ganz auf 0, ein Rest bleibt immer lesbar, falls die
--  Ueberdeckung nur kurz und nicht wirklich vollstaendig ist.
--
--  STANDARDMAESSIG AUS - eigener Schalter (KEYBINDS -> DECLUTTER), nicht
--  von selbst an. Live noch nicht ausreichend gegengeprueft (siehe die
--  Historie oben); bis das ausgiebiger getestet ist, soll es niemanden
--  ungefragt treffen. Dieselbe An/Aus-ueber-Basiswert-Form wie
--  SP.lookahead/SP.setLookahead weiter unten.
SP.occlusionFade = 0
SP.occlusionFadeBase = 0.85
function SP.setOcclusionFade(on)
	SP.occlusionFade = on and SP.occlusionFadeBase or 0
end

--  DIE KAMERA VORHERSAGEN - UND JEDES SCHILD DAMIT NEU PROJIZIEREN.
--
--  Das ist der dritte und richtige Anlauf. Die beiden Irrwege gehoeren
--  dokumentiert, weil sie beide plausibel aussahen:
--
--  1. Nichts tun und hoffen, dass es schnell genug ist. Zwischen "Roblox
--     rechnet die Bildschirmstelle aus" und "das Overlay-Fenster liegt auf
--     dem Schirm" liegen gemessen 13 bis 18 Millisekunden. Bei 240 Bildern
--     ist Roblox dann drei Bilder weiter. Das Schild zieht beim Schwenk
--     sichtbar mit und schnappt danach zurueck.
--
--  2. Je Schild die Bildschirm-Geschwindigkeit messen und damit
--     vorausrechnen. Im Grundsatz richtig, in der Praxis zu unruhig: eine
--     Geschwindigkeit aus Differenzen ist verrauscht, und zwanzig Schilder
--     haben zwanzig verschiedene Rauschsignale. Sie zappeln dann jedes fuer
--     sich, statt sich gemeinsam zu bewegen. Gemeldet als "es gibt trotzdem
--     leichte Bewegungen statt komplett still zu stehen".
--
--  Der richtige Weg geht nicht ueber die Schilder, sondern ueber die
--  URSACHE ihrer Bewegung: die Kamera. Sie ist EIN Signal, laesst sich
--  darum sauber glaetten, und wenn man sie vorausrechnet und alle Schilder
--  damit projiziert, bewegen sie sich starr gemeinsam - genau wie die Welt.
--  Das ist die Anforderung: "es soll sich gegen die Kamera bewegen, um auf
--  demselben Feld zu bleiben."
--
--  Die Projektion ist gegen Robloxs eigene WorldToViewportPoint geprueft:
--  groesster Fehler ueber zwoelf Proben 0,225 Pixel.
SP.lookahead = 0.014   -- Sekunden Vorlauf; 0 schaltet die Vorhersage ab
SP.lookaheadBase = SP.lookahead   -- der "an"-Wert, fuer SP.setLookahead

--  AN/AUS VON AUSSEN. Die Vorhersage gleicht die eigene Pipeline-
--  Verzoegerung aus, aber sie ist eine SCHAETZUNG - auf einem Rechner mit
--  anderer Kamerasteuerung (starke Beschleunigung, sehr hohe Sensitivitaet)
--  kann sie mehr Bewegung hinzudichten als tatsaechlich fehlt, sichtbar als
--  leichtes Nachziehen beim Stoppen der Drehung. Ohne einen Schalter waere
--  das nur durch Skript-Aenderung abstellbar - jetzt reicht SP.lookahead = 0
--  ueber SP.setLookahead(false), von der Keybinds-Seite aus erreichbar.
function SP.setLookahead(on)
	SP.lookahead = on and SP.lookaheadBase or 0
end

--  Mindestabstand in Bildschirm-Pixeln zwischen einem Welt-Tag und dem
--  Kopf seines Adornee - siehe serializeTags() fuer die ausfuehrliche
--  Begruendung ("am Anfang ganz unten, je naeher man kommt weiter oben").
SP.tagMinHeadGap = 20

local function project(cf, fovDeg, vpx, vpy, world)
	local rel = cf:PointToObjectSpace(world)
	local depth = -rel.Z
	if depth <= 0 then return nil end
	local tanHalf = math.tan(math.rad(fovDeg) * 0.5)
	local nx = (rel.X / (depth * tanHalf * (vpx / vpy))) * 0.5 + 0.5
	local ny = 0.5 - (rel.Y / (depth * tanHalf)) * 0.5
	return nx * vpx, ny * vpy, depth
end

local camT, camYaw, camPitch, camPos
local rateYaw, ratePitch = 0, 0
local ratePos = Vector3.new()

local function wrapPi(a)
	while a > math.pi do a -= math.pi * 2 end
	while a < -math.pi do a += math.pi * 2 end
	return a
end

--  BEIM BESCHLEUNIGEN VORSICHTIG, BEIM ABBREMSEN SCHNELL.
--
--  Die alte, einheitliche Glaettung (rate*0.7 + neu*0.3, in beide
--  Richtungen gleich) lag genau dann daneben, wenn die Drehung PLOETZLICH
--  aufhoert (Maus losgelassen): die Rate faellt dann nicht sofort auf 0,
--  sondern zerfaellt ueber mehrere Bilder - und die Vorhersage rechnet in
--  der Zwischenzeit weiter mit einer Drehung, die es nicht mehr gibt.
--  Sichtbar als kurzes Nachziehen/Zurueckschnappen ENTGEGEN der gerade
--  beendeten Drehrichtung, genau in dem Moment, in dem man aufhoert zu
--  drehen - gemeldet als "das Overlay zieht sich mit, wenn ich die Kamera
--  bewege, und das muss man stoppen koennen".
--
--  Ein asymmetrischer Faktor loest genau das: wird die neue Messung
--  KLEINER als die bisherige Rate (die Drehung wird langsamer oder
--  stoppt), zaehlt die neue Messung staerker - die Rate faellt schnell.
--  Wird sie GROESSER (die Drehung beschleunigt gerade erst), bleibt die
--  alte, vorsichtige Glaettung - genau die, die frueher das Gezappel bei
--  zwanzig gleichzeitig gemessenen Schildern verhindert hat (siehe unten).
local function blendRate(old, new)
	local w = (math.abs(new) < math.abs(old)) and 0.4 or 0.7
	return old * w + new * (1 - w)
end

local function blendVec(old, new)
	local w = (new.Magnitude < old.Magnitude) and 0.4 or 0.7
	return old * w + new * (1 - w)
end

--  Gemessen wird ueber ein FENSTER von 20 ms, nicht von Bild zu Bild: bei
--  240 Bildern sind zwei aufeinanderfolgende Bilder 4 ms auseinander, und
--  ein Zittern von einer Millisekunde darin waere schon ein Viertel
--  Fehler in der Geschwindigkeit.
local function predictCam(cam, now)
	local cf = cam.CFrame
	local pitch, yaw, roll = cf:ToEulerAnglesYXZ()
	local pos = cf.Position

	if not camT then
		camT, camYaw, camPitch, camPos = now, yaw, pitch, pos
		return cf
	end

	local dt = now - camT
	if dt >= 0.02 then
		local dy = wrapPi(yaw - camYaw) / dt
		local dp = wrapPi(pitch - camPitch) / dt
		local dv = (pos - camPos) / dt
		--  Kameraschnitt, Respawn, Teleport: nicht in die Glaettung lassen.
		if math.abs(dy) > 40 then dy = 0 end
		if math.abs(dp) > 40 then dp = 0 end
		if dv.Magnitude > 3000 then dv = Vector3.new() end
		rateYaw   = blendRate(rateYaw, dy)
		ratePitch = blendRate(ratePitch, dp)
		ratePos   = blendVec(ratePos, dv)
		camT, camYaw, camPitch, camPos = now, yaw, pitch, pos
	end

	local L = SP.lookahead
	if L <= 0 then return cf end

	--  TOTZONE. Steht die Kamera, wird NICHTS vorhergesagt - dann ist die
	--  Stelle von Bild zu Bild bitgleich, und das Schild steht wirklich
	--  still. Ohne das haette die Vorhersage selbst dafuer gesorgt, dass es
	--  nie Ruhe gibt.
	if math.abs(rateYaw) < 0.02 and math.abs(ratePitch) < 0.02
	   and ratePos.Magnitude < 0.5 then
		return cf
	end

	SP.camRate = math.floor(math.deg(math.abs(rateYaw)) + 0.5)
	return CFrame.new(pos + ratePos * L)
		* CFrame.fromEulerAnglesYXZ(pitch + ratePitch * L, yaw + rateYaw * L, roll)
end

--  IST DAS PANEL OFFEN?
--
--  Gebraucht, weil bei offenem Panel ALLE Welt-ESPs ausgehen sollen - das
--  Panel verdeckt ohnehin das halbe Bild, und Schilder, die darunter
--  hindurchscheinen, machen es nur unleserlich. Ausgenommen ist das
--  Inventar-HUD: es ist eine ScreenGui und gehoert zur Bedienung, nicht zur
--  Welt, und wird darum weiter gespiegelt.
--
--  Im Hauptskript gilt diese Regel bisher nur fuer die Spieler-Namensschilder
--  (die Bedingung "not panelOpen" in updateTag); Generator-, Drop-, Kit- und
--  Bienen-ESP kannten sie nicht. Hier laufen alle Welt-Tags durch eine
--  einzige Stelle - also steht sie hier, und damit fuer alle.
--
--  Die Referenz wird gemerkt und nur einmal je Sekunde neu gesucht. Ein
--  FindFirstChild ueber zwei Wurzeln je Bild waere fuer eine Abfrage, deren
--  Antwort sich beim Tastendruck aendert, unnoetig teuer.
local panelRef = nil
local panelRefAt = 0

--  MIKROBEWEGUNGEN WEGHALTEN.
--
--  Auch mit vorhergesagter Kamera bleibt ein Rest Unruhe: die Drehrate wird
--  geglaettet, hinkt also beim Anlaufen und Auslaufen minimal nach, und
--  darunter liegt noch das Zittern der Kamera selbst. Das sind Bruchteile
--  eines Pixels - aber genau die sieht man, weil Text bei jeder
--  Bruchteil-Verschiebung neu gerastert wird und dabei flimmert.
--
--  Deshalb eine Haltezone in der POSITION, zusaetzlich zur Totzone in der
--  Drehrate: bewegt sich ein Schild um weniger als 0,6 Pixel, behaelt es
--  seine alte Stelle. Dann steht es wirklich bitgleich - und weil das
--  Overlay nur zeichnet, was sich geaendert hat, zeichnet es dafuer auch
--  nichts.
--
--  Bewegt sich das Schild wirklich, greift die Zone nicht - aber ein
--  harter Sprung direkt auf den neuen Rohwert war bei SCHNELLEN
--  Kamerabewegungen selbst noch unruhig ("zittert"): genau das
--  Restrauschen, das die geglaettete Drehrate oben nicht restlos
--  wegbekommt, nur zu gross fuer die 0,6-Pixel-Haltezone. Deshalb kein
--  Sprung mehr, sondern ein kurzer, straffer Zug in Richtung des neuen
--  Werts (SCHRITT) statt eines vollen Schritts - bei stetiger Bewegung in
--  wenigen Bildern (Millisekunden bei ueblicher Bildrate) eingeholt, bei
--  einzelnen Ausreissern gedaempft. "Fuer kurze Zeit stabil bleiben,
--  statt zu zittern" - genau dieser kurze Nachlauf.
local SCHRITT = 0.55
local function halte(gui, x, y)
	local h = held[gui]
	if not h then
		h = { x = x, y = y }
		held[gui] = h
		return x, y
	end
	if math.abs(x - h.x) < HALTE and math.abs(y - h.y) < HALTE then
		return h.x, h.y
	end
	h.x = h.x + (x - h.x) * SCHRITT
	h.y = h.y + (y - h.y) * SCHRITT
	return h.x, h.y
end

local function panelOffen()
	if panelRef == nil or panelRef.Parent == nil then
		local now = os.clock()
		if now - panelRefAt > 1 then
			panelRefAt = now
			panelRef = nil
			local hui = nil
			pcall(function() hui = gethui() end)
			for _, root in ipairs({ hui, game:GetService("CoreGui") }) do
				if root then
					local g = root:FindFirstChild(SP.SCREENGUIS[1])
					if g and g:IsA("ScreenGui") then panelRef = g end
				end
			end
		end
	end
	return panelRef ~= nil and panelRef.Enabled
end

--  WEITER ENTFERNT = IMMER WEITER HINTEN - ABER GEGEN EINE BERUHIGTE
--  MESSUNG, NICHT GEGEN DEN ROHEN WERT.
--
--  Reines "a.z > b.z" (die fruehere Fassung) sortierte JEDES Bild neu aus
--  dem rohen, staendig ein kleines Stueck schwankenden Abstand - gemeldet
--  an genau der Stelle, an der es am meisten auffaellt: zwei dicht
--  beieinanderstehende Schilder (zwei Emerald-Generatoren, 208 vs. 207
--  Studs entfernt) tauschten bei praktisch jedem Bild die Reihenfolge,
--  weil 1 Stud Unterschied auf 207 reines Messrauschen ist, keine echte
--  Anordnung.
--
--  WICHTIG: die Regel selbst ("weiter weg -> immer dahinter") bleibt eine
--  einfache, strikte Zahlenordnung - kein Sonderfall, der sich je nach
--  Nachbarpaar anders verhaelt (das waere nicht mehr garantiert
--  transitiv, und Lua's table.sort verlangt eine konsistente
--  Vergleichsfunktion). Stattdessen wird pro Schild NUR DIE MESSUNG
--  selbst beruhigt: SP._zSort haelt je Schild die zuletzt GENUTZTE Tiefe
--  fest und uebernimmt den neuen rohen Wert erst, wenn er sich klar davon
--  entfernt hat (> 8 % bzw. mind. 1 Stud) - kleines Rauschen faellt raus,
--  eine echte Annaeherung oder Entfernung schlaegt weiterhin voll durch,
--  und "weiter weg" bedeutet ab da wieder ausnahmslos "weiter hinten".
local function sortDepthOf(zSort, c)
	local id = idOf(c.gui)
	local prev = zSort[id]
	if not prev or math.abs(c.z - prev) > math.max(1, prev * 0.08) then
		zSort[id] = c.z
		return c.z
	end
	return prev
end

local function serializeTags()
	if busy then return "[]", 0 end
	local cam = workspace.CurrentCamera
	if not cam then return "[]", 0 end

	--  Panel offen: keine Welt-Schilder. Siehe panelOffen() darueber.
	if panelOffen() then
		local st = SP.stat
		if not st then st = {}; SP.stat = st end
		st.kandidaten, st.gezeigt, st.panelOffen = 0, 0, true
		SP.tagsShown, SP.tagsHidden = 0, 0
		return "[]", 0
	end

	busy = true
	buf, bn = {}, 0
	local eye = cam.CFrame.Position

	--  EINMAL je Bild die Kamera vorausrechnen, danach ALLE Schilder damit
	--  projizieren. Genau daran haengt, dass sie sich gemeinsam und starr
	--  gegen die Kamera bewegen statt jedes fuer sich zu zappeln.
	local camPred = predictCam(cam, os.clock())
	local fov     = cam.FieldOfView
	local vpx, vpy = cam.ViewportSize.X, cam.ViewportSize.Y

	--  Erst sammeln, dann entscheiden, dann zeichnen. Das Sammeln ist
	--  billig (eine Projektion je Schild); teuer ist erst das Ablesen des
	--  Baums, und das passiert nur noch fuer die Schilder, die uebrig
	--  bleiben.
	--  Die Eintraege selbst werden wiederverwendet (kein Muell je Bild),
	--  sortiert wird aber eine frische Liste - table.sort wuerde sonst die
	--  alten Eintraege jenseits von cn mitsortieren und Schilder vom letzten
	--  Bild wieder hereinholen.
	local pool = SP._cand
	if not pool then pool = {}; SP._cand = pool end
	local cand = SP._candList
	if not cand then cand = {}; SP._candList = cand end
	local cn = 0

	--  Zaehler, um die Frage "warum ist das Schild nicht da?" mit Zahlen zu
	--  beantworten statt mit einer Vermutung. Genau diese Frage stand offen:
	--  "es kommt auf meine Kamera an, ob etwas angezeigt wird oder nicht."
	local nWant, nKeinOrt, nHinten, nZuWeit, nAusserhalb = 0, 0, 0, 0, 0

	for gui in pairs(SP.tags) do
		if typeof(gui) ~= "Instance" or gui.Parent == nil then
			SP.tags[gui] = nil
			SP.want[gui] = nil
		elseif SP.want[gui] == false then
			nWant += 1
			--  Ausgefiltert: das Schild steht noch da, das Hauptskript will
			--  es aber gerade nicht zeigen (Filter, eigenes Team
			--  ausgeschlossen, Tags-Taste aus).
			--
			--  Gefragt wird SP.want und NICHT gui.Enabled: Enabled steht
			--  waehrend des Betriebs immer auf false, das setzt diese
			--  Bruecke selbst. Es zu lesen hiess, gar keine Schilder mehr zu
			--  zeichnen - so sind die Generator-ESPs einmal vollstaendig
			--  verschwunden.
		else
			local ad = gui.Adornee or gui.Parent
			local pos
			if typeof(ad) == "Instance" then
				if ad:IsA("BasePart") then pos = ad.Position
				elseif ad:IsA("Attachment") then pos = ad.WorldPosition
				elseif ad:IsA("Model") then
					local ok, cf = pcall(function() return ad:GetPivot().Position end)
					pos = ok and cf or nil
				end
			end
			if not pos then nKeinOrt += 1 end
			if pos then
				local world = pos + gui.StudsOffsetWorldSpace
				local dist  = (world - eye).Magnitude
				local maxd  = gui.MaxDistance
				if maxd <= 0 then maxd = math.huge end
				if dist > maxd then nZuWeit += 1 end
				if dist <= maxd then
					local px, py, depth = project(camPred, fov, vpx, vpy, world)
					if not px then nHinten += 1 end
					if px then
						--  GROESSE UEBER AbsoluteSize, NICHT UEBER Size.Offset.
						--
						--  Size.Offset ist nur die HALBE Wahrheit: ein
						--  BillboardGui, dessen Size in SCALE angegeben ist
						--  (bei diesem Spiel gemessen: {6, 0}, {1.25, 0} -
						--  Scale 6/1.25, Offset 0/0), liefert ueber .Offset
						--  IMMER null, unabhaengig von der tatsaechlichen
						--  Groesse auf dem Bildschirm. bw/bh waren damit
						--  staendig 0x0 - eine Box ohne Ausdehnung.
						--
						--  Zwei Folgen davon, beide gemeldet:
						--    1. Die Box-Halbierung weiter unten (px - bw*0.5,
						--       py - bh*0.5) faellt weg, wenn bw/bh null
						--       sind - das Schild sitzt dann am Mittelpunkt
						--       statt an seiner oberen linken Ecke zentriert,
						--       gemeldet als "Namensschilder sitzen viel zu
						--       weit unten". Der Fehler in Pixeln bleibt
						--       etwa gleich gross, faellt aber bei einem aus
						--       der Ferne ohnehin kleinen Charakter viel
						--       staerker auf - "das passiert bei groesserer
						--       Distanz" beschreibt also nicht einen groesser
						--       werdenden Fehler, sondern einen gleich
						--       grossen Fehler neben einem kleiner werdenden
						--       Massstab.
						--    2. Eine nullgrosse Box faellt beim
						--       Bildschirmrand-Test (weiter unten) viel
						--       leichter komplett heraus, obwohl das echte,
						--       richtig grosse Schild noch zur Haelfte im
						--       Bild waere - ein Teil von "es kommt auf die
						--       Kamera an, ob alles angezeigt wird".
						--
						--  AbsoluteSize ist die von Roblox bereits fertig
						--  aufgeloeste Pixelgroesse - richtig fuer Scale,
						--  Offset oder eine Mischung aus beidem. Nur bei
						--  einem noch nie gezeichneten Schild (0x0, siehe
						--  "kollabierte Box" weiter unten im Code) faellt sie
						--  selbst auf 0 zurueck; genau dann greift Offset
						--  als Ersatzwert.
						local size = gui.Size
						local absSize = gui.AbsoluteSize
						local bw = absSize.X > 0 and absSize.X or size.X.Offset
						local bh = absSize.Y > 0 and absSize.Y or size.Y.Offset

						--  NICHT MEHR AUF DEM WELT-VERSATZ ZENTRIEREN - AUF EINEM
						--  MINDESTABSTAND ZUM KOPF SELBST.
						--
						--  StudsOffsetWorldSpace haengt den Anker ein paar Studs
						--  ueber den Kopf - aber das ist ein WELT-Abstand, und der
						--  schrumpft mit der Kamera-Distanz genau wie jeder andere
						--  Weltabstand auch (perspektivische Verkuerzung). Live
						--  gemessen (eigener Kopf, 3.4 Studs Versatz): 313px
						--  Abstand bei 5 Studs, aber nur noch 23px bei 60 Studs
						--  und 3.5px bei 400 Studs - waehrend die halbe Boxhoehe
						--  (bh*0.5, hier 50px) IMMER gleich bleibt. Ab ungefaehr
						--  der Distanz, an der der Weltabstand unter die halbe
						--  Boxhoehe faellt, zentrierte sich die Box nicht mehr
						--  ueber, sondern zunehmend UNTER dem Kopf - das Schild
						--  "sank" mit wachsender Distanz Richtung und unter den
						--  Charakter. Gemeldet als "am Anfang [aus der Ferne] ganz
						--  unten, je naeher man kommt, weiter oben".
						--
						--  Der Kopf selbst (ohne Versatz) projiziert unabhaengig
						--  von diesem Effekt - er ist ja der Bezugspunkt, nicht
						--  irgendein Punkt darueber. Ein FESTER Bildschirm-Mindest-
						--  abstand ueber dem Kopf loest das: aus der Naehe bleibt
						--  alles wie bisher (der Weltabstand ist dort ohnehin
						--  groesser als der Mindestabstand, ueberschreibt ihn
						--  also nicht), aber ab der kritischen Distanz greift der
						--  Mindestabstand und haelt das Schild dauerhaft ueber dem
						--  Kopf, statt in ihn hinein- und darunter zu rutschen.
						local _, hpy = project(camPred, fov, vpx, vpy, pos)
						local headY = hpy or py
						local naturalGap = hpy and (headY - py) or 0
						local gap = math.max(naturalGap, SP.tagMinHeadGap)
						local ox, oy = halte(gui, px - bw * 0.5, headY - gap - bh)
						--  RANDPUFFER statt "on".
						--
						--  "on" ist schon dann false, wenn der projizierte
						--  PUNKT einen Pixel aus dem Bild rutscht - das
						--  Schild selbst waere aber noch zur Haelfte zu
						--  sehen. Roblox zeichnet es in dem Fall weiter,
						--  das Overlay hat es abrupt weggelassen. Gemeldet
						--  als "wenn ich nicht hingucke, gibt es die auch
						--  nicht". Also wird die ganze Box geprueft, nicht
						--  der Punkt.
						if not (ox + bw >= 0 and ox <= vpx and oy + bh >= 0 and oy <= vpy) then
							nAusserhalb += 1
						end
						if ox + bw >= 0 and ox <= vpx and oy + bh >= 0 and oy <= vpy then
							cn += 1
							local c = pool[cn]
							if not c then c = {}; pool[cn] = c end
							c.gui, c.ox, c.oy, c.bw, c.bh, c.z, c.drop, c.fade = gui, ox, oy, bw, bh, depth, false, 0

							--  FUER DIE VERDECKUNGSPRUEFUNG: DIE TATSAECHLICH
							--  SICHTBARE FLAECHE, NICHT DIE SCHILD-BOX.
							--
							--  gui.AbsoluteSize (oben, bw/bh) ist die FEST
							--  DEKLARIERTE Groesse des BillboardGui selbst (bei
							--  genESP z.B. immer 180x130*scale) - nicht die des
							--  "Pill"-Frames darin, das per AutomaticSize auf
							--  seinen wirklichen Inhalt waechst (laengerer Text,
							--  mehr Zeilen). Zwei Schilder, deren PILLS sich
							--  sichtbar ueberlappen, deren viel groesserer, groesstenteils
							--  leerer BillboardGui-Rahmen sich aber zufaellig
							--  nicht ueberschneidet, zaehlten bislang als "nicht
							--  ueberdeckt" - gemeldet als sichtbar
							--  ueberlappender Text, der trotzdem nicht
							--  verblasst. Deshalb hier, wo vorhanden, die
							--  tatsaechliche Pill-Flaeche: relativ zum
							--  BillboardGui gemessen (Roblox' eigene
							--  AbsolutePosition/-Size, fuer beide dieselbe
							--  Basis), dann auf dieselbe Stelle wie ox/oy
							--  umgerechnet (die eigene Projektion, nicht Robloxs).
							c.fx, c.fy, c.fw, c.fh = ox, oy, bw, bh
							local pill = gui:FindFirstChild("Pill")
							if pill and pill:IsA("GuiObject") then
								local pas = pill.AbsoluteSize
								if pas.X > 0 and pas.Y > 0 then
									local gap = gui.AbsolutePosition
									c.fw, c.fh = pas.X, pas.Y
									c.fx = ox + (pill.AbsolutePosition.X - gap.X)
									c.fy = oy + (pill.AbsolutePosition.Y - gap.Y)
								end
							end

							cand[cn] = c
						end
					end
				end
			end
		end
	end

	--  Reste des letzten Bildes abschneiden: table.sort wuerde sie sonst
	--  mitsortieren und Schilder von vorhin wieder hereinholen.
	for i = #cand, cn + 1, -1 do cand[i] = nil end

	--  IMMER NACH TIEFE SORTIEREN - UNABHAENGIG VON SP.declutter.
	--
	--  Das hier ist reine ZEICHENREIHENFOLGE, keine Ausblendung: jedes
	--  Schild wird weiterhin gezeigt, nur die Reihenfolge, in der die
	--  Gruppen im JSON stehen, aendert sich. Die Culling-Logik von
	--  declutter (Schilder ganz weglassen, wenn sie stark ueberdeckt
	--  sind) bleibt komplett abgeschaltet, siehe SP.declutter = 0 oben.
	--
	--  Ohne diese Sortierung war die Reihenfolge an Lua's pairs()-
	--  Iteration ueber SP.tags gekoppelt - und die kann sich bei jedem
	--  Hinzufuegen oder Entfernen eines Schildes (Generator-Countdown neu
	--  erzeugt, Spieler kommt/geht, ein ESP baut seine Tags neu) ohne
	--  erkennbaren Grund umsortieren. Auf der C#-Seite entscheidet genau
	--  diese Reihenfolge, welches Fenster beim gemeinsamen
	--  HWND_TOPMOST-Stapeln zuletzt (und damit vorne) landet - zwei
	--  ueberlappende Schilder haben darum bei manchem Bild das eine und
	--  beim naechsten das andere vorne gezeigt. Gemeldet als "wenn sich
	--  zwei ESPs overlappen, shiften sie dauerhaft vor und zurueck".
	--
	--  Nach Tiefe sortiert (weiteste zuerst, naechste zuletzt -> naechste
	--  landet zuletzt im Stapel und damit vorn) bleibt die Reihenfolge
	--  stabil, solange sich die Distanzen nicht wirklich kreuzen - und wo
	--  sie es tun, wechselt die Reihenfolge genau dann, wenn es inhaltlich
	--  auch richtig ist: das naeher gerueckte Schild uebernimmt.
	if cn > 1 then
		local zSort = SP._zSort
		if not zSort then zSort = {}; SP._zSort = zSort end
		for i = 1, cn do cand[i].zs = sortDepthOf(zSort, cand[i]) end
		table.sort(cand, function(a, b) return a.zs > b.zs end)

		--  Alle paar hundert Bilder aufraeumen statt jedes Mal: eine
		--  ganz normale, ueber Zahlen-Ids indizierte Tabelle wird von Lua
		--  nicht von selbst leerer, wenn ein Schild verschwindet. Ueber
		--  eine lange Runde sammeln sich sonst Karteileichen fuer jeden
		--  inzwischen zerstoerten Generator-Countdown und jedes gegangene
		--  ESP-Tag an.
		SP._zSortTick = (SP._zSortTick or 0) + 1
		if SP._zSortTick >= 512 then
			SP._zSortTick = 0
			local fresh = {}
			for i = 1, cn do
				local id = idOf(cand[i].gui)
				fresh[id] = zSort[id]
			end
			SP._zSort = fresh
		end
	end

	--  Wiederverwenden statt je Bild neu anlegen. Bei 240 Bildern waren das
	--  fuenf Wegwerf-Tabellen je Bild, also tausendzweihundert je Sekunde,
	--  nur um dieselben Zahlen nochmal hineinzuschreiben.
	local keep = SP._keep
	if not keep then
		keep = { x = {}, y = {}, w = {}, h = {} }
		SP._keep = keep
	end
	local keptX, keptY, keptW, keptH, kept = keep.x, keep.y, keep.w, keep.h, 0
	local schwelle = SP.declutter
	local fadeMax = SP.occlusionFade

	--  VERDECKUNG PRUEFEN - GEGENLAEUFIG ZUR SORTIERUNG.
	--
	--  cand steht weiteste-zuerst (siehe die Sortierung oben, fuer den
	--  Fenster-Stapel gebraucht). Verdecken kann ein Schild aber nur etwas,
	--  das NAEHER an der Kamera steht - darum hier rueckwaerts durch cand
	--  (naechstes zuerst): das naechste Schild ist immer sichtbar, jedes
	--  weitere wird nur gegen die schon bestaetigt sichtbaren, damit
	--  garantiert NAEHEREN Schilder geprueft. Siehe der lange Kommentar bei
	--  SP.declutter/SP.occlusionFade oben - das war lange schlicht
	--  andersherum.
	--
	--  Liefert zwei unabhaengige Werte aus derselben Ueberdeckungsflaeche:
	--  drop (hartes Weglassen, SP.declutter - standardmaessig aus) und fade
	--  (weiches Verblassen, SP.occlusionFade - standardmaessig an).
	if schwelle > 0 or fadeMax > 0 then
		for i = cn, 1, -1 do
			local c = cand[i]
			local drop, fade = false, 0
			if kept > 0 then
				--  Wieviel dieser Box ist schon belegt? Naeherung ueber die
				--  Summe der Einzelschnitte; sie ueberschaetzt bei mehreren
				--  Verdeckern, und das ist die richtige Richtung - wo sich drei
				--  Schilder stapeln, soll eher etwas verblassen/wegfallen.
				--  c.fx/fy/fw/fh statt c.ox/oy/bw/bh: die tatsaechliche
				--  Pill-Flaeche, siehe deren Berechnung oben.
				local area = c.fw * c.fh
				if area > 1 then
					local ueber = 0
					for j = 1, kept do
						local ix = math.min(c.fx + c.fw, keptX[j] + keptW[j]) - math.max(c.fx, keptX[j])
						if ix > 0 then
							local iy = math.min(c.fy + c.fh, keptY[j] + keptH[j]) - math.max(c.fy, keptY[j])
							if iy > 0 then ueber += ix * iy end
						end
					end
					local frac = ueber / area
					if schwelle > 0 and frac > schwelle then drop = true end
					if fadeMax > 0 then fade = math.min(fadeMax, frac) end
				end
			end
			c.drop, c.fade = drop, fade
			--  Auch ein verblasstes Schild zaehlt weiter als "davor" fuer
			--  alles, was noch dahinter kommt - es steht ja weiterhin an
			--  dieser Bildschirmstelle, nur schwaecher gezeichnet.
			if not drop then
				kept += 1
				keptX[kept], keptY[kept], keptW[kept], keptH[kept] = c.fx, c.fy, c.fw, c.fh
			end
		end
		kept = 0   -- fuer die Emission unten neu gezaehlt
	end

	--  EMISSION - WEITESTE ZUERST, WIE GEHABT (Fenster-Stapel-Reihenfolge).
	for i = 1, cn do
		local c = cand[i]

		if not c.drop then
			kept += 1

			local gui, ox, oy, bw, bh = c.gui, c.ox, c.oy, c.bw, c.bh

			--  GRUPPENKOPF: Kennung und Stelle des Schildes.
			--
			--  Danach folgen seine Kinder mit Koordinaten RELATIV zur
			--  Schild-Box. Damit ist der Inhalt von der Stelle getrennt: das
			--  Programm kann das Schild verschieben, ohne es neu zu zeichnen.
			put(('{"k":"g","i":%d,"x":%s,"y":%s,"w":%s,"h":%s}')
				:format(idOf(gui), num(ox), num(oy), num(bw), num(bh)))
			--  KOLLABIERTE BOX NACHRECHNEN.
			--
			--  Ein BillboardGui, das Roblox noch nie gezeichnet hat, hat
			--  AbsoluteSize 0x0 - dann loesen alle Kinder, die ihre Position
			--  in Scale angeben, gegen null auf. Nachgemessen an einem
			--  Namensschild: im Bild Pille @ 82,66, nie gezeichnet @ -26,-34.
			--  Das trifft die Schilder, die ENTSTEHEN, waehrend die Bruecke
			--  laeuft - sie werden sofort abgeschaltet, also nie gezeichnet,
			--  und korrigieren sich nie von selbst. Der fehlende Betrag ist
			--  genau der Scale-Anteil an der Box.
			--  ox/oy gehen NICHT mehr mit: die Kinder werden relativ zur
			--  Schild-Box geschickt, die Stelle steht im Gruppenkopf.
			local flach = gui.AbsoluteSize.X < 1
			for _, ch in ipairs(gui:GetChildren()) do
				if ch:IsA("GuiObject") then
					if flach then
						local pp = ch.Position
						emit(ch, bw * pp.X.Scale, bh * pp.Y.Scale, c.fade)
					else
						emit(ch, 0, 0, c.fade)
					end
				end
			end
		end
	end

	SP.tagsShown, SP.tagsHidden = kept, cn - kept
	local st = SP.stat
	if not st then st = {}; SP.stat = st end
	st.kandidaten, st.gezeigt = cn, kept
	st.ausgefiltert, st.keinOrt = nWant, nKeinOrt
	st.hinterKamera, st.zuWeit, st.ausserhalbBild = nHinten, nZuWeit, nAusserhalb
	st.panelOffen = false
	--  Keine Instanz im Vorrat halten, den wir naechstes Bild wiederverwenden.
	for i = 1, cn do pool[i].gui = nil end

	busy = false
	return "[" .. table.concat(buf, ",") .. "]", bn
end

--------------------------------------------------------------------
-- Hat sich ueberhaupt etwas getan?
--------------------------------------------------------------------
--  Das Panel jedes Bild abzulesen, nur um festzustellen, dass es gleich
--  geblieben ist, ist die teuerste Art nichts zu tun: gemessen 3,3 ms je
--  Durchlauf, bei 240 Bildern also achtzig Prozent Dauerlast - und genau
--  das war als Ruckeln beim Kameraschwenk zu spueren.
--
--  Zwischen zwei Neuaufbauten kann sich am Panel nur dreierlei aendern:
--    * es wurde neu gezeichnet   -> das meldet SP.touch() von selbst
--    * es wurde gescrollt        -> CanvasPosition, billig abzufragen
--    * die Maus ist gewandert    -> Hover-Uebergaenge
--  Alles andere steht still. Also wird genau das geprueft, und zwar an
--  einer Handvoll Werten statt an zweihundert Elementen.
--
--  Die Liste der Scrollflaechen wird gemerkt und nur bei einem echten
--  Neuaufbau verworfen - sie ueber GetDescendants zu suchen waere selbst
--  wieder so teuer wie das, was hier gespart werden soll.
local scrollCache = nil
local hotRects = nil

--  Was kann sich am Panel aendern, ohne dass es neu gebaut wird?
--
--    * es wurde neu gezeichnet   -> das meldet SP.touch() von selbst
--    * es wurde gescrollt        -> CanvasPosition, billig abzufragen
--    * die Maus ist darueber     -> Hover-Uebergaenge
--
--  Der dritte Punkt war ein teurer Denkfehler. Erst stand hier schlicht die
--  Mausposition: bewegt sie sich, gilt das Panel als "in Benutzung", und
--  dann darf das Ablesen viel Rechenzeit nehmen. Beim SPIELEN bewegt sich
--  die Maus aber dauernd - das ist die Kamera. Also galt das Panel praktisch
--  immer als in Benutzung, und das Budget von fuenfunddreissig Prozent einer
--  Sekunde wurde tatsaechlich ausgegeben.
--
--  Und das ist genau der gemeldete Verlust: bei 240 Bildern je Sekunde sind
--  4,16 ms je Bild; nimmt sich etwas davon 35 Prozent, bleiben 6,4 ms, also
--  156 Bilder. Gemeldet waren "160 statt 220 bis 240". Das war keine
--  Messungenauigkeit, das war diese Zeile.
--
--  Die Maus zaehlt jetzt nur noch, wenn sie WIRKLICH UEBER dem Panel steht.
--  Bewegt sie sich irgendwo sonst, kann sich am Panel nichts geaendert
--  haben - dann gibt es auch nichts abzulesen.
local function panelPulse()
	if SP.dropScrollCache then
		SP.dropScrollCache = false
		scrollCache, hotRects = nil, nil
	end
	if not scrollCache then
		scrollCache, hotRects = {}, {}
		eachScreenGui(function(gui)
			if not gui.Enabled then return end
			local grp = groupOf(gui, false) or gui
			for _, d in ipairs(grp:GetDescendants()) do
				if d:IsA("ScrollingFrame") then
					scrollCache[#scrollCache + 1] = d
				end
			end
			--  Die obersten Flaechen des Panels - daran wird gemessen, ob die
			--  Maus ueberhaupt darueber ist.
			for _, d in ipairs(grp:GetChildren()) do
				if d:IsA("GuiObject") then hotRects[#hotRects + 1] = d end
			end
		end)
	end

	local n = 0
	for i = #scrollCache, 1, -1 do
		local sf = scrollCache[i]
		if sf.Parent == nil then
			table.remove(scrollCache, i)
		else
			local cp = sf.CanvasPosition
			n += cp.X + cp.Y * 7919
		end
	end

	--  Maus nur beachten, wenn sie ueber dem Panel steht.
	if #hotRects > 0 then
		local ok, m = pcall(function() return UserInputService:GetMouseLocation() end)
		if ok and m then
			local drueber = false
			for i = #hotRects, 1, -1 do
				local r = hotRects[i]
				if r.Parent == nil then
					table.remove(hotRects, i)
				elseif not drueber and r.Visible then
					local p2, s2 = r.AbsolutePosition, r.AbsoluteSize
					if m.X >= p2.X and m.X <= p2.X + s2.X
					   and m.Y >= p2.Y and m.Y <= p2.Y + s2.Y then
						drueber = true
					end
				end
			end
			SP.overPanel = drueber
			if drueber then n += m.X * 31 + m.Y * 37 end
		end
	else
		SP.overPanel = false
	end
	return n
end

--------------------------------------------------------------------
-- Sende-Schleife
--------------------------------------------------------------------
--  Das Panel wird nur geschickt, wenn sich wirklich etwas geaendert hat.
--  Es besteht aus mehreren tausend Befehlen und steht zwischen zwei
--  Neuaufbauten still - jeden Frame dasselbe zu schicken waere ein
--  Vielfaches an Last fuer null Unterschied. Die Tags dagegen wandern mit
--  der Kamera und gehen jeden Frame raus; sie sind klein.
local function frameText(screen, tags, sameScreen)
	local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
		or Vector2.new(1920, 1080)
	local head = ('{"v":1,"t":%s,"vw":%s,"vh":%s')
		:format(num(os.clock() * 1000), num(vp.X), num(vp.Y))
	if sameScreen or screen == nil then
		head = head .. ',"sk":1'
	else
		head = head .. ',"s":' .. screen
	end
	return head .. ',"w":' .. (tags or "[]") .. "}"
end

local function startLoop()
	task.spawn(function()
		local sock, useWs = nil, false
		local lastScreen  = nil
		local panelAt, httpAt = 0, 0
		local tagAt = 0
		local lastPulse = nil
		local busyUntil = 0
		local frames, fpsAt = 0, os.clock()
		local sentCount = 0
		local fails = 0
		local panelHz = SP.rate.panel

		--  Verbindung aufbauen - und zwar so, dass sie sich auch wieder
		--  aufbaut.
		--
		--  DAS HIER WAR DER GRUND FUERS WACKELN. Bricht der WebSocket ab
		--  (weil das Programm neu gestartet wurde, zum Beispiel), fiel die
		--  Schleife auf HTTP zurueck - und blieb dort. HTTP ist auf zwanzig
		--  Bilder je Sekunde gedrosselt, weil eine request()-Runde beim
		--  Executor blockiert. Zwanzig Aktualisierungen je Sekunde bei einem
		--  Spiel, das mit zweihundertvierzig zeichnet, heisst: jedes Welt-Tag
		--  haengt bis zu fuenfzig Millisekunden hinterher. Beim Kameraschwenk
		--  sieht man das als Zittern und als Versatz - und es sah aus wie ein
		--  Rechenfehler in der Projektion, war aber schlicht ein zu alter Wert.
		local lastWsTry = 0

		local function openWs()
			local s = wsConnect()
			if not s then return false end
			sock, useWs, SP.sock = s, true, s
			pcall(function()
				s.OnClose:Connect(function()
					if sock ~= s then return end
					useWs, sock, SP.sock = false, nil, nil

					--  SOFORT ABSCHALTEN, NICHT AUF HTTP AUSWEICHEN.
					--
					--  Vorher hing hier nur das Aufraeumen der drei Variablen,
					--  und die Hauptschleife lief weiter - ueber den HTTP-
					--  Rueckfall, der synchron blockiert (siehe httpFn). Stirbt
					--  das Programm (Absturz oder Neustart), landet dieser Weg
					--  bei jedem Versuch auf einer toten Gegenstelle, und je
					--  nach Executor braucht ein scheiternder Verbindungsaufbau
					--  dort Sekunden statt Millisekunden - auf dem Thread, der
					--  RenderStepped antreibt. Genau das war "massive FPS-Drops
					--  und Haenger, wenn die App weg ist".
					--
					--  Ein geschlossener WebSocket, der eben noch offen war, ist
					--  das zuverlaessigste und schnellste Zeichen ueberhaupt,
					--  dass die Gegenseite weg ist - zuverlaessiger als drei
					--  Fehlschlaege abzuwarten. Also sofort zurueck auf die
					--  eigene Anzeige, ohne einen einzigen weiteren Versuch.
					task.spawn(function()
						SP.setActive(false, "Verbindung getrennt (Programm beendet)")
					end)
				end)
			end)

			--  Gegenrichtung: das Programm darf hierher sprechen.
			--
			--  Der Grund ist kein Komfort, sondern ein Notausgang. Solange
			--  die Bruecke laeuft, ist das Panel in Roblox unsichtbar - wenn
			--  dann am Overlay etwas klemmt, sieht man gar nichts mehr und
			--  findet den Schalter nicht, mit dem man zurueckkaeme. Die Taste
			--  gibt es zwar weiterhin, aber sich darauf zu verlassen, dass
			--  jemand sie im richtigen Moment weiss, waere schlechtes Design.
			--  Ein Knopf im Programm kommt immer durch.
			pcall(function()
				s.OnMessage:Connect(function(msg)
					local okJ, cmd = pcall(function()
						return HttpService:JSONDecode(msg)
					end)
					if not okJ or type(cmd) ~= "table" then return end

					if cmd.cmd == "off" then
						warn("[Streamproof] AUS auf Zuruf des Programms")
						task.spawn(function()
							SP.setActive(false, "Knopf im Programm")
						end)
					elseif cmd.cmd == "rate" then
						SP.setRate(cmd.tags, cmd.panel)
					elseif cmd.cmd == "profile" then
						SP.setProfile(tostring(cmd.name))
						print("[Streamproof] Leistungsstufe: " .. tostring(SP.profile))
					elseif cmd.cmd == "ping" then
						pcall(function()
							s:Send('{"v":1,"pong":1}')
						end)
					end
				end)
			end)
			return true
		end

		openWs()
		SP.status = "on"
		SP.ws = useWs

		while SP.active do
			local okAll = pcall(function()
				local now = os.clock()

				--  Ist die schnelle Leitung weg, alle zwei Sekunden einen
				--  neuen Anlauf. Der HTTP-Weg traegt derweil weiter, aber er
				--  ist nur der Notnagel - dauerhaft dort zu bleiben war der
				--  Fehler.
				if not useWs and (now - lastWsTry) > 2 then
					lastWsTry = now
					openWs()
				end

				--  Hier stand ein Durchlauf ueber ALLE Welt-Tags, in jedem
				--  Bild, der Enabled stur auf false nachzog - weil das
				--  Hauptskript es staendig wieder einschaltete. Der Streit
				--  ist beigelegt (das Skript meldet seinen Wunsch jetzt ueber
				--  SP.tag_state statt Enabled selbst zu setzen), also bleibt
				--  nur der langsame Sicherheitsdurchlauf viermal je Sekunde.
				--  Ein GetChildren() mal Anzahl Schilder je Bild waren bei
				--  240 Bildern ein paar tausend Wegwerf-Tabellen je Sekunde.

				--  Tags: voller Takt. Eine Drosselung ist moeglich, aber
				--  nicht empfohlen - das ist der Teil, der sich bei jeder
				--  Mausbewegung aendert.
				local tags, n2 = "[]", 0
				local tagStep = (SP.rate.tags > 0) and (1 / SP.rate.tags) or 0
				if now - tagAt >= tagStep then
					tagAt = now
					tags, n2 = serializeTags()
				end

				--  Panel: nur wenn sich wirklich etwas getan haben KANN.
				--  panelHz ist die Obergrenze fuer den Fall, dass etwas
				--  passiert; passiert nichts, laeuft es auf panelIdle.
				local screen, n1, sendScreen = nil, 0, false
				local pulse   = panelPulse()
				local changed = (pulse ~= lastPulse)
				lastPulse = pulse

				--  BEDIENST DU GERADE ETWAS?
				--
				--  Alles, was das Panel zwischen zwei Neuaufbauten aendern
				--  kann, geht ueber eine Eingabe: Maus bewegt, Maus gedrueckt,
				--  gescrollt. Genau daran wird "busy" erkannt - und ein paar
				--  Zehntel nachgehalten, damit die Rate nicht bei jeder
				--  Pause zwischen zwei Mausbewegungen einbricht.
				if changed or SP.dirty then busyUntil = now + SP.rate.busyFor end
				local busy = now < busyUntil
				SP.busy = busy

				local since   = now - panelAt
				local due     = SP.dirty or changed
					or since >= (1 / math.max(1, SP.rate.panelIdle))

				if due and since >= (1 / panelHz) then
					local t0 = os.clock()
					screen, n1 = serializeScreen()
					local cost = (os.clock() - t0) * 1000
					panelAt, SP.dirty = now, false
					SP.panelMs = cost

					--  Wieviele Durchlaeufe je Sekunde passen in das
					--  Lastbudget? Gleitend nachgezogen, damit ein einzelner
					--  Ausreisser die Rate nicht springen laesst.
					--
					--  Das Budget selbst haengt daran, ob du gerade etwas
					--  bedienst (siehe SP.rate.maxLoadBusy/Idle). Beim Ziehen
					--  darf das Panel also das Siebenfache kosten - und
					--  genau dann ist es das auch wert.
					local budget = busy and SP.rate.maxLoadBusy or SP.rate.maxLoadIdle
					local erlaubt = SP.rate.panel
					if cost > 0.05 then
						erlaubt = math.clamp(
							(budget * 1000) / cost,
							SP.rate.minPanel, SP.rate.panel)
					end
					--  Hoch schnell, runter langsam: wenn du anfaengst zu
					--  ziehen, soll das Panel sofort mitkommen; laesst du los,
					--  darf es sich Zeit nehmen. Mit einem einzigen
					--  Glaettungsfaktor waere der erste Zug immer zaeh.
					local k = (erlaubt > panelHz) and 0.6 or 0.15
					panelHz = panelHz + (erlaubt - panelHz) * k

					if screen ~= lastScreen then
						lastScreen, sendScreen = screen, true
					end
					--  Getrennt merken: das Panel wird nur alle paar Bilder
					--  abgelesen, die Tags bei jedem. Beides in eine Zahl zu
					--  schreiben hiess, dass in der Statuszeile fast immer
					--  "0 prims" stand - naemlich in jedem Bild, in dem das
					--  Panel gerade nicht dran war.
					SP.panelPrims = n1
				end
				SP.prims = (SP.panelPrims or 0) + n2
				SP.hzNow  = math.floor(panelHz + 0.5)

				--  Nichts Neues? Dann geht auch nichts raus. Ein Paket, das
				--  denselben Inhalt traegt wie das letzte, kostet auf beiden
				--  Seiten Arbeit und aendert kein Pixel.
				if n2 == 0 and not sendScreen then return end

				local payload = frameText(sendScreen and screen or nil, tags, not sendScreen)

				if useWs and sock then
					--  Direkt raus, ohne Sammelpuffer: das ist die Stelle,
					--  an der die Echtzeit entsteht oder verloren geht.
					sock:Send(payload)
					sentCount += 1
				else
					--  Rueckfall ohne WebSocket. Eine request()-Runde kostet
					--  je nach Executor mehrere Millisekunden und blockiert
					--  dabei - das gehoert nicht in jeden Frame. Dieser Weg
					--  ist spuerbar traeger, deshalb steht er auch nur hier.
					if now - httpAt > 0.05 then
						httpAt = now
						local req = httpFn()
						if req then
							--  Timeout: OHNE Angabe wartet mancher Executor auf
							--  seinen eigenen, viel groesseren Standardwert -
							--  und das auf dem Thread, der das Bild antreibt.
							--  Kommt gar nichts zurueck (Programm weg, Port
							--  tot), soll das hier scheitern, nicht haengen.
							local ok2 = pcall(req, {
								Url = SP.BASE .. "/frame", Method = "POST",
								Headers = { ["Content-Type"] = "application/json" },
								Body = payload,
								Timeout = 0.5,
							})
							if not ok2 then error("http send failed") end
							sentCount += 1
						end
					end
				end
			end)

			if okAll then
				fails = 0
				frames += 1
				if os.clock() - fpsAt >= 1 then
					--  ZWEI Zahlen, und der Unterschied ist wichtig: wie oft
					--  die Schleife lief, und wie viele Bilder wirklich
					--  rausgingen. Vorher stand nur die erste da - sie zeigte
					--  240, waehrend ueber den HTTP-Notnagel zwanzig ankamen.
					--  Ein Problem, das die eigene Anzeige nicht zeigt, sucht
					--  man an der falschen Stelle.
					SP.fps, SP.sent = frames, sentCount
					frames, sentCount, fpsAt = 0, 0, os.clock()
				end
			else
				fails += 1
				--  Drei Fehlschlaege hintereinander heissen: das Programm
				--  ist weg. Dann wird zurueckgeschaltet, statt blind
				--  weiterzusenden - sonst saesse man ohne jede Anzeige da
				--  und wuesste nicht, warum.
				if fails >= 3 then
					SP.status, SP.note = "lost", "connection lost - visuals restored"
					warn("[Streamproof] Verbindung verloren - Visuals wieder in Roblox")
					SP.setActive(false, "Verbindung verloren")
					return
				end
			end

			--  RenderStepped und nicht Heartbeat: dieser Takt laeuft
			--  unmittelbar VOR dem Zeichnen des Frames, die abgelesenen
			--  Positionen sind also so frisch wie ueberhaupt moeglich.
			RunService.RenderStepped:Wait()
		end

		if sock then pcall(function() sock:Close() end) end
		if SP.sock == sock then SP.sock = nil end
	end)
end

--------------------------------------------------------------------
-- Oeffentliche Schalter
--------------------------------------------------------------------
--  reason ist nur fuer die Konsole - aber dafuer wichtig: beim Einrichten
--  stand die Bruecke ploetzlich auf AUS, und es war nicht zu sehen, ob sie
--  sich selbst abgeschaltet hatte, ob ein Tastendruck sie getroffen hatte
--  oder ob das Hauptskript sie beendet hat. Drei sehr verschiedene Fehler,
--  die ohne diesen Zusatz gleich aussehen.
function SP.setActive(on, reason)
	on = on and true or false
	if on == SP.active then return SP.active end
	SP.lastReason = reason or "unbekannt"

	if on then
		SP.status = "searching"
		if not SP.probe() then
			--  Kein Link zum Anklicken in Roblox - also in die
			--  Zwischenablage, dann ist er mit einem Einfuegen im Browser da.
			pcall(function()
				local cb = setclipboard or toclipboard or writeclipboard
				if cb then cb(SP.DOWNLOAD) end
			end)
			warn(("[Streamproof] Programm nicht gefunden (%s). Download-Link liegt in der Zwischenablage:\n  %s")
				:format(SP.note, SP.DOWNLOAD))
			return false
		end

		SP.active = true
		collectExistingTags()
		eachScreenGui(hideScreenGui)
		enforceTags(true)
		startLoop()


		--  Das Netz unter dem Haken in new(): ein Tag, das auf einem
		--  anderen Weg entstanden ist, wird spaetestens hier stumm.
		task.spawn(function()
			while SP.active do
				pcall(enforceTags, true)
				pcall(function() eachScreenGui(hideScreenGui) end)
				task.wait(0.25)
			end
		end)

		print(("[Streamproof] AN - App %s, Overlay uebernimmt die Anzeige."):format(SP.appVer))
		return true
	end

	SP.active = false
	SP.status = (SP.status == "lost") and "lost" or "off"
	SP.fps, SP.prims, SP.panelPrims = 0, 0, 0

	--  Die Verbindung SOFORT kappen, nicht erst wenn die Schleife das
	--  naechste Mal drankommt. Solange sie steht, zeigt das Overlay das
	--  zuletzt geschickte Bild - und ein Panel, das nach dem Ausschalten
	--  noch eine Sekunde in der Luft haengt, sieht aus wie ein Fehler.
	--  Erst ein leeres Bild schicken (falls das Schliessen beim Executor
	--  traege ist), dann schliessen: beides sorgt in der App fuer eine
	--  leere Flaeche, das eine ueber den Inhalt, das andere ueber das
	--  Verbindungsende.
	local s = SP.sock
	SP.sock = nil
	if s then
		pcall(function() s:Send('{"v":1,"s":[],"w":[]}') end)
		pcall(function() s:Close() end)
	end

	pcall(function() eachScreenGui(showScreenGui) end)
	--  Die Tags nicht selbst wieder anschalten: updateTag und die
	--  ESP-Ticks des Hauptskripts setzen Enabled ohnehin jede halbe
	--  Sekunde neu, und die kennen den gewollten Zustand (Taste an/aus,
	--  Panel offen) besser als dieses Modul.
	for gui in pairs(SP.tags) do
		if typeof(gui) == "Instance" and gui.Parent then
			--  Nur die Gruppe aufloesen. Enabled wird NICHT angefasst: es
			--  steht ohnehin schon auf dem, was das Hauptskript will.
			--  Frueher wurde hier pauschal alles eingeschaltet, und dann
			--  standen nach dem Abschalten auch die ausgefilterten
			--  Generatoren wieder da.
			pcall(showTag, gui)
		end
	end
	print(("[Streamproof] AUS (%s) - Anzeige wieder in Roblox.")
		:format(SP.lastReason or "?"))
	return false
end

function SP.toggle(reason) return SP.setActive(not SP.active, reason or "toggle") end

--  Kurzfassung fuer die Keybinds-Seite.
function SP.label()
	if SP.active then
		return ("ON  ·  %d/%d sent  ·  %d prims  ·  panel %d Hz%s / %.1f ms  ·  %s")
			:format(SP.sent or 0, SP.fps or 0, SP.prims,
				SP.hzNow or 0, SP.busy and " (aktiv)" or "",
				SP.panelMs or 0,
				(SP.sock ~= nil) and "ws" or "HTTP (langsam!)")
	end
	if SP.status == "missing" then return "APP NOT FOUND  ·  link copied" end
	if SP.status == "nohttp"  then return "NO HTTP FUNCTION" end
	if SP.status == "lost"    then return "CONNECTION LOST" end
	return "OFF"
end

--  Diagnose ohne Netz und ohne etwas zu verstecken: baut EIN Bild und sagt,
--  was es gekostet haette. Dafuer gedacht, die Frage "laggt das?" mit Zahlen
--  statt mit einem Gefuehl zu beantworten - und zwar an dem Panel, das
--  gerade wirklich offen ist.
function SP.debugFrame()
	--  Laeuft die Bruecke, wird NICHT ein zweites Mal serialisiert - die
	--  Zahlen der laufenden Schleife sind ohnehin die echten, und ein
	--  zweiter Durchlauf aus diesem Thread wuerde ihr nur in den Puffer
	--  greifen (siehe Waechter oben).
	if SP.active then
		return {
			live       = true,
			prims      = SP.prims,
			panelMs    = SP.panelMs,
			panelHz    = SP.hzNow,
			sendFps    = SP.fps,
			transport  = SP.ws and "websocket" or "http",
			lastError  = SP.lastError or "-",
		}
	end

	local t0 = os.clock()
	local screen, n1 = serializeScreen()
	local t1 = os.clock()
	local tags, n2 = serializeTags()
	local t2 = os.clock()
	return {
		panelPrims = n1,
		tagPrims   = n2,
		panelKB    = math.floor(#screen / 102.4 + 0.5) / 10,
		tagKB      = math.floor(#tags / 102.4 + 0.5) / 10,
		panelMs    = math.floor((t1 - t0) * 10000 + 0.5) / 10,
		tagMs      = math.floor((t2 - t1) * 10000 + 0.5) / 10,
		tagsTracked = (function()
			local c = 0
			for _ in pairs(SP.tags) do c += 1 end
			return c
		end)(),
	}
end

function SP.shutdown()
	if SP.active then pcall(SP.setActive, false, "shutdown (Skript entladen)") end
	SP.active = false
	SP.status = "off"
end

print(("[Streamproof] Bruecke bereit (v%s). SP.toggle() oder die Taste im KEYBINDS-Tab.")
	:format(SP.VERSION))

return SP
