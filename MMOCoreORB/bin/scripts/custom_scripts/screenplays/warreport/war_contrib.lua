--[[
  custom_scripts/screenplays/warreport/war_contrib.lua

  Backlog B14 (game-side half). docs/DESIGN-PARTICIPATION.md S:A.4 verified a
  hard constraint: Core3's Lua has NO database access of any kind -- every
  registerFunction in DirectorManager.cpp was read; none give SQL. So the war
  contribution ledger (warsim/sql/schema.sql:222, war_contribution_ledger)
  cannot be written directly from game Lua.

  This module is the WRITER half of the approved "spool file + host-side
  flusher" design (S:A.4). It appends one line per contribution event to a
  minute-bucketed spool file under log/warcontrib/. The reader half,
  bridge/flush_contributions.lua, runs on the HOST (CORE3_SRC is a real bind
  mount -- deploy/docker-compose.yml:85-87 -- so the host sees the exact same
  files) as the first step of deploy/scripts/war-advance.sh, before every
  tick, and turns closed buckets into war_contribution_ledger rows.

  WHY MINUTE-BUCKETED FILENAMES MAKE THE FLUSHER RACE-FREE
  -----------------------------------------------------------
  Every Core3 thread owns its own Lua VM (DirectorManager.h,
  ThreadLocal<Lua*>), so many threads can call WarContrib.record()
  concurrently. The bucket a writer targets is `floor(os.time()/60)`: for
  the whole 60 seconds that wall-clock minute M is current, EVERY writer on
  EVERY thread computes the same bucket M and appends only to
  pending.<M>.csv -- never to any other file, and never to a file some
  other minute already finished with.

  The flusher, per its own header, only ever touches a bucket once its own
  wall clock has moved to at least bucket (M + 2) -- i.e. once a full closed
  minute has elapsed since M could last have been "the current bucket" for
  any writer. That is a property of the clock and the bucket arithmetic
  alone, and it depends on one deployment-topology fact that is NOT asserted
  anywhere in code: the host running the flusher and the container running
  this writer must share a clock (they do here -- Docker gives the container
  the host kernel's clock, same boot_id, measured zero skew -- but a future
  deployment where that stops being true, e.g. a remote/VM-isolated
  container, would violate this silently). It holds for any number of
  concurrent writer threads, needs no lock, no rename-out-from-under-a-
  writer, and no coordination between the game process and the host script
  BEYOND that shared clock. A writer can never have an fd open on a bucket
  the flusher is willing to touch, because by the time the flusher will
  touch it, no writer could possibly still be computing that bucket number
  from the current time.

  WHY ONE f:write() PER LINE IS ATOMIC
  ---------------------------------------
  The spool file is opened "a" (O_APPEND). On Linux, a single write(2) to an
  O_APPEND fd for a size under PIPE_BUF (4096 bytes; every line here is well
  under that) is atomic -- the kernel serialises concurrent appenders at the
  file-offset level, so each write lands whole or not at all, never
  interleaved with another thread's write. That guarantee applies to
  EXACTLY one write() call carrying the WHOLE line (fields + trailing
  newline). WarContrib.record() therefore builds the complete line as one
  Lua string first and calls fh:write() on it exactly once. Do not add a
  second write() for the newline or for any field -- that would reopen the
  interleaving risk this whole design exists to close.

  SOURCE VOCABULARY -- docs/DESIGN.md S:5.5, PROVISIONAL
  -------------------------------------------------------------------------
  CORRECTION: an earlier version of this comment claimed the list below
  mirrors a warsim/sim/tick.lua COMBAT_CHANNELS allowlist that sums only
  listed sources and silently zeroes anything else. That allowlist does NOT
  exist on main today -- it lives in another lane's unmerged worktree.
  warsim/store/mysql.lua:686-688 currently sums EVERY row for a
  (faction, region_id) pair with no source filter at all, so on main an
  unlisted source is not "silently worth zero" -- it would be summed like
  everything else. Do not repeat that claim; it was wrong.

  The seven values in VALID_SOURCES below are the contribution-source table
  docs/DESIGN.md S:5.5 defines (the table around lines 1037-1043, explicitly
  marked PROVISIONAL: "Stage 1 defines the contract and the units; the point
  values ... cannot be validated until there is a game server writing
  them"). This module enforces that vocabulary as a POLICY CHOICE made here,
  not an enforcement of an existing sim-side filter: reject any source
  outside the documented list now, so that whichever lane lands the actual
  sim-side filter (tracked separately, not part of this file) inherits an
  already-constrained set of values rather than years of free-form strings.
  There is no shared runtime import across the Lua-game / Lua-host
  boundary, so VALID_SOURCES below is a manually-kept copy of the DESIGN.md
  table -- if that table changes, this list must change with it.

  EIGHTH VALUE ADDED: `materiel_donation` -- docs/DESIGN-VICTORY.md's
  recruiter-hand-in channel (distinct from `materiel_delivery`, mission-based
  and still unwired). The writer is
  custom_scripts/screenplays/warreport/war_donate.lua; see that file's
  header for the valuation formula and the two laundering loops it closes.

  This module is deliberately Core3-API-free (no CreatureObject, no
  assumption that `printf` exists) so it can be exercised from plain host
  lua5.3 -- see deploy/tests/assert-contrib-flush.sh, which dofile()s this
  exact file with no engine stubs at all. Call sites that actually observe
  game events (an NPC-kill observer, a crafting-delivery hook, ...) resolve
  the faction/region/points/character themselves and pass plain values to
  WarContrib.record(); wiring those call sites is a separate, later change
  and is NOT part of this file.
]]

WarContrib = WarContrib or {}

-- Relative to the Core3 process's cwd (MMOCoreORB/bin -- the same cwd stock
-- scripts already assume, e.g. ServerEventAutomation.lua's
-- io.open("log/ServerEventAutomation.log", "a+")). A test harness running
-- under plain lua5.3 (a different cwd, and one that must never write into
-- the real spool the live flusher scans) overrides this field before
-- calling WarContrib.record -- see assert-contrib-flush.sh.
WarContrib.SPOOL_DIR = "log/warcontrib"

local function log(msg)
	if _G.printf ~= nil then
		printf(msg)
	else
		io.stderr:write(msg)
	end
end
WarContrib._log = log

-- Combat-channel vocabulary. Keep in sync with docs/DESIGN.md S:5.5's
-- contribution-source table (PROVISIONAL) -- see the header comment above.
-- This is a POLICY fence this module chooses to enforce, NOT a mirror of
-- an existing sim-side filter (none exists on main -- see header).
local VALID_SOURCES = {
	npc_kill_faction        = true,
	npc_kill_elite          = true,
	installation_destroyed  = true,
	mission_completed       = true,
	presence_hour           = true,
	pvp_kill                = true,
	base_delivery           = true,
	materiel_donation       = true,
	materiel_support        = true,
}
WarContrib.VALID_SOURCES = VALID_SOURCES

local VALID_FACTIONS = { IMPERIAL = true, REBEL = true }

-- Every region_id in custom_scripts/war/war_state.lua / region_map.lua
-- (e.g. "cor_bela_vistal", "tat_mos_eisley") is lowercase ascii, digits and
-- underscore only. Reject anything else outright -- there is no legitimate
-- region_id this excludes, so there is nothing to "escape", only to refuse.
local REGION_PATTERN = "^[a-z][a-z0-9_]*$"

local function normalizeFaction(faction)
	if type(faction) ~= "string" then
		return nil
	end
	local upper = string.upper(faction)
	if VALID_FACTIONS[upper] then
		return upper
	end
	return nil
end

local function validRegionId(s)
	return type(s) == "string" and #s >= 1 and #s <= 32 and string.match(s, REGION_PATTERN) ~= nil
end

local function validPoints(p)
	local n = tonumber(p)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return nil -- not a number, or NaN/inf
	end
	-- war_contribution_ledger.points is DECIMAL(9,4); reject non-positive
	-- and absurd magnitudes rather than let a malformed caller write
	-- garbage into the ledger.
	if n <= 0 or n > 99999 then
		return nil
	end
	return n
end

-- Returns the CSV field to emit ("" for NULL), or nil if characterId was
-- given but is not a valid non-negative integer.
local function characterIdField(c)
	if c == nil then
		return ""
	end
	local n = tonumber(c)
	if n == nil or n < 0 or math.floor(n) ~= n then
		return nil
	end
	return tostring(math.floor(n))
end

-- Attempts to create SPOOL_DIR once, if it doesn't exist yet. log/ itself
-- is gitignored (MMOCoreORB/.gitignore:31 ignores it wholesale) and nothing
-- in deploy/ creates log/warcontrib/ on a fresh checkout or after
-- `git clean`, so without this, EVERY record() call would fail with
-- open_failed until a human ran mkdir by hand. `mkdir -p` is instant,
-- local, and non-blocking -- this is nothing like the rejected
-- io.popen("mysql ...") alternative in S:A.4 (an unbounded per-event stall
-- waiting on MariaDB); it runs at most once per Lua VM incarnation, only
-- when the directory is actually missing.
local dirEnsured = false
local function ensureSpoolDir()
	if dirEnsured then
		return
	end
	os.execute("mkdir -p '" .. WarContrib.SPOOL_DIR:gsub("'", "'\\''") .. "'")
	dirEnsured = true
end

--- Append one contribution event to the current minute's spool file.
--
--   faction     "imperial"/"IMPERIAL"/"rebel"/"REBEL" (case-insensitive)
--   regionId    e.g. "tat_mos_eisley" -- must match REGION_PATTERN
--   source      one of VALID_SOURCES (docs/DESIGN.md S:5.5's PROVISIONAL
--               contribution-source vocabulary -- see header comment)
--   points      positive number (raw contribution points for this event)
--   characterId optional integer (SWG object id) -- "for attribution /
--               digests only" per schema.sql; nil is fine
--
-- Returns true on success, or false plus a short machine-readable reason on
-- rejection ("bad_faction", "bad_region_id", "bad_source", "bad_points",
-- "bad_character_id", "open_failed"). NEVER throws: a malformed call site
-- should lose one contribution event, not raise into a game thread.
function WarContrib.record(faction, regionId, source, points, characterId)
	local fac = normalizeFaction(faction)
	if fac == nil then
		log("WarContrib.record: rejected, bad faction " .. tostring(faction) .. "\n")
		return false, "bad_faction"
	end

	if not validRegionId(regionId) then
		log("WarContrib.record: rejected, bad region_id " .. tostring(regionId) .. "\n")
		return false, "bad_region_id"
	end

	if type(source) ~= "string" or not VALID_SOURCES[source] then
		-- Loud and specific on purpose: this is a policy fence, not
		-- enforcement of an existing sim-side filter (none exists on
		-- main -- see header comment). Reject any source outside
		-- docs/DESIGN.md S:5.5's PROVISIONAL vocabulary now, rather than
		-- let an unreviewed channel name reach the ledger. Never fall
		-- back to a default "source" value here.
		log("WarContrib.record: rejected, source '" .. tostring(source)
			.. "' is not on docs/DESIGN.md S:5.5's contribution-source vocabulary\n")
		return false, "bad_source"
	end

	local pts = validPoints(points)
	if pts == nil then
		log("WarContrib.record: rejected, bad points " .. tostring(points) .. "\n")
		return false, "bad_points"
	end

	local charField = characterIdField(characterId)
	if charField == nil then
		log("WarContrib.record: rejected, bad character_id " .. tostring(characterId) .. "\n")
		return false, "bad_character_id"
	end

	local now = os.time()
	local bucket = math.floor(now / 60)

	-- Every field above is already validated against a fixed, comma-free
	-- character set (or is a formatted number), so there is nothing left
	-- that could corrupt the CSV format -- rejection above IS the
	-- escaping. One string, one write() call:
	local line = string.format("%d,%s,%s,%s,%s,%s\n",
		now, fac, regionId, source, string.format("%.4f", pts), charField)

	local path = WarContrib.SPOOL_DIR .. "/pending." .. tostring(bucket) .. ".csv"
	local fh = io.open(path, "a")
	if fh == nil then
		-- log/warcontrib/ is gitignored and not created by anything else
		-- (see ensureSpoolDir's comment) -- try once to create it, then
		-- retry the open exactly once before giving up.
		ensureSpoolDir()
		fh = io.open(path, "a")
	end
	if fh == nil then
		log("WarContrib.record: could not open " .. path .. " for append even after mkdir -p "
			.. WarContrib.SPOOL_DIR .. "\n")
		return false, "open_failed"
	end

	fh:write(line)
	fh:close()

	return true
end
