--- This module supports dynamic mask generation.

--
-- Permission is hereby granted, free of charge, to any person obtaining
-- a copy of this software and associated documentation files (the
-- "Software"), to deal in the Software without restriction, including
-- without limitation the rights to use, copy, modify, merge, publish,
-- distribute, sublicense, and/or sell copies of the Software, and to
-- permit persons to whom the Software is furnished to do so, subject to
-- the following conditions:
--
-- The above copyright notice and this permission notice shall be
-- included in all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
-- EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
-- MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
-- IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
-- CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
-- TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
-- SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
--
-- [ MIT license: http://www.opensource.org/licenses/mit-license.php ]
--

-- Standard library imports --
local assert = assert
local format = string.format
local floor = math.floor
local max = math.max
local remove = os.remove
local tostring = tostring
local type = type
local unpack = unpack

-- Modules --
local file = require("corona_utils.file")
local strings = require("tektite_core.var.strings")
local var_preds = require("tektite_core.var.predicates")
local timers = require("corona_utils.timers")

-- Corona globals --
local display = display
local graphics = graphics
local system = system

-- Corona modules --
local json = require("json")
local sqlite3 = require("sqlite3")

-- Cached module references --
local _GetPixInt_

-- Exports --
local M = {}

-- Add 3 pixels to each side, then add (4 - 1) to round up to next multiple of 4 --
local Rounding = 3 * 2 + 3

-- Helper to get extra padding and report odd counts
local function Extra (n)
	local padding = Rounding - (n + Rounding) % 4
	local odd = padding % 2

	return (padding - odd) / 2, odd
end

--
local function UpperLeftAlign (object, x, y)
	object.anchorX, object.x = 0, x or 0
	object.anchorY, object.y = 0, y or 0
end

--
local function NewRect (group, stash, x, y, w, h, color)
	local n, rect = stash and stash.numChildren or 0

	if n > 0 then
		rect = stash[n]

		rect.width, rect.height = w, h

		group:insert(rect)
	else
		rect = display.newRect(group, 0, 0, w, h)
	end

	UpperLeftAlign(rect, x, y)

	if color then
		rect:setFillColor(color)
	end

	return rect
end

-- Helper for black regions of mask texture
local function BlackRect (group, stash, x, y, w, h)
	return NewRect(group, stash, x, y, w, h, 0)
end

-- --
local SaveParams = { isFullResolution = true }

--
local function Save (group, name, base_dir)
	-- Generate a new name, if none is provided. As a sanity check, verify no such file exists.
	if not name then
		repeat
			name = strings.AddExtension(strings.NewName(), "png")
		until not file.Exists(name, base_dir)
	end

	-- Save the group as a PNG. Return the filename, since it may have been auto-generated.
	SaveParams.filename, SaveParams.baseDir = name, base_dir

	display.save(group, SaveParams)

	return name
end

--- Generates a rectangular mask, for use with `graphics.setMask`.
-- @uint w Mask width...
-- @uint h ...and height.
-- @param[opt] name File name to assign to mask; if absent, one will be auto-generated.
-- @param[opt=`system.CachesDirectory`] base_dir Directory where mask is stored.
-- @treturn string Mask file name.
-- @treturn number xscale Scale to apply to mask to fit _w_...
-- @treturn number yscale ...and to fit _h_.
function M.NewMask (w, h, name, base_dir)
	name, base_dir = name and format(name, w, h), base_dir or system.CachesDirectory

	-- If the mask exists, reuse it; otherwise, build it.
	if not file.Exists(name, base_dir) then
		local group = display.newGroup()
		local xpad, ew = Extra(w)
		local ypad, eh = Extra(h)

		BlackRect(group, nil, 0, 0, w + ew + xpad * 2, h + eh + ypad * 2)
		NewRect(group, nil, xpad, ypad, w + ew, h + eh)
		Save(group, name, base_dir)

		group:removeSelf()
	end

	return name
end

-- --
local CW, CH = display.contentWidth - 6, display.contentHeight - 6

--
local function InBounds (bounds, gbounds)
	return gbounds.xMin >= 0 and gbounds.yMin >= 0 and gbounds.xMax <= bounds.xMax and gbounds.yMax <= bounds.yMax
end

-- --
local SheetFrame = {}

-- --
local Sheet = { frames = { SheetFrame } }

-- --
local TrashPile, TrashTimer = {}

--
local function CaptureBounds (group, bounds, hidden, yfunc)
	-- Contents are visible: just capture the bounds directly.
	if not hidden then
		return display.captureBounds(bounds)
	else
		local gbounds = group.contentBounds

		-- Obscured, but within bounds: just capture the group.
		if InBounds(bounds, gbounds) then
			return display.capture(group)

		-- Out-of-bounds: make an intermediate image and capture that.
		else
			-- Move the group fully on screen, detecting too-large cases.
			local movex, movey = max(0, -gbounds.xMin), max(0, -gbounds.yMin)

			assert(gbounds.xMax + movex <= CW, "Frame too wide to capture!")
			assert(gbounds.yMax + movey <= CH, "Frame too tall to capture!")
			-- ^^ Okay?

			-- Save the group to an image.
			group.x, group.y = group.x + movex, group.y + movey

			local name = Save(group, nil, system.TemporaryDirectory)

			--
			yfunc()

			-- Create a one-frame image sheet, where the frame is positioned over the bounded part of
			-- the content. Reload it as a sprite (in the group's parent), then capture and return it.
			-- Since the image is a temporary resource, queue it up for subsequent removal.
			SheetFrame.x, SheetFrame.width = movex, bounds.xMax - bounds.xMin
			SheetFrame.y, SheetFrame.height = movey, bounds.yMax - bounds.yMin

			local sheet = graphics.newImageSheet(name, system.TemporaryDirectory, Sheet)
			local image = display.newImage(group.parent, sheet, 1)

			file.PutInTrash_Guard(name, image, system.TemporaryDirectory)

			return image
		end
	end
end

--
local function DefYieldFunc () end

-- read sources: table (parent, key); database (table, key, is_open); embedded (chunk type, key)
-- write methods: to table / JSON; to database; to same file
-- remove: if missing read source
-- tEXt:
-- Keyword:        1-79 bytes (character string)
--   Null separator: 1 byte
--   Text:           n bytes (character string)

--
local function IsPosInt (var)
	return var_preds.IsInteger(var) and var > 0
end

-- Rounds up to next multiple of 4 (mask dimensions requirement)
local function NextMult4 (x)
	local over = x % 4

	return x + (over > 0 and 4 - over or 0)
end

-- Converts an ordered collection of positions into an easier-to-use map
local function ToFrameMap (arr)
	local frames = {}

	for i = 1, #arr, 3 do
		frames[arr[i]] = { arr[i + 1], arr[i + 2] }
	end

	return frames
end

--
local function WithDatabase (method, source, filename, func, data)
	local db, tname = source

	if type(source) == "table" then
		db, tname = unpack(source)
	else
		db = source
	end

	if method == "database_file" then
		db = sqlite3.open(db)
	end

	tname = tname or "corona_mask_data"

	local res = func(db, tname, filename, data)

	if method == "database_file" then
		db:close()
	end

	return res
end

-- Helper to read data out of a database table, if it exists
local function AuxRead (db, tname, filename)
	local data

	for _ in db:urows([[SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ']] .. tname .. [[';]]) do
		for ii, v in db:urows([[SELECT * FROM ]] .. tname .. [[ WHERE m_KEY = ']] .. filename .. [[';]]) do
			data = v
		end
	end

	return data
end

-- Helper to check dimension validity
local function CheckDim (fdim, idim)
	return IsPosInt(fdim) and IsPosInt(idim) and idim > fdim
end

-- Tries to read file-related data from some source
local function ReadData (opts, filename, fdimx, fdimy)
	local method, source, data = opts.method, opts.data

	-- Read a string out of a database (which may be opened) --
	-- arg: { name / db, table, key }
	if method == "database_file" or method == "database_handle" then
		source = WithDatabase(method, source, filename, AuxRead)

	-- Read from PNG --
	elseif method == "image_metadata" then
		-- FindText(keyword) = "CoronaMaskData"...
		-- arg = ...
	end

	if type(source) == "string" then
		data = json.decode(source)
	else
		data = source
	end

	return type(data) == "table" -- Is it a table...
		and type(data.frames) == "table" and IsPosInt(#data.frames) -- ...does it have per-frame data...
		and CheckDim(fdimx, data.xdim) and CheckDim(fdimy, data.ydim) -- ...and valid frame / image dimensions?
		and data, source -- All good: return the data
end

--
local function AuxWrite (db, tname, filename, data)
	db:exec([[
		CREATE TABLE IF NOT EXISTS ]] .. tname .. [[ (m_KEY UNIQUE, m_DATA);
		INSERT OR REPLACE INTO ]] .. tname .. [[ VALUES(']] .. filename .. [[', ']] .. data .. [[');
	]])
end

--
local function WriteData (method, source, frames, fdimx, fdimy, xdim, ydim, filename)
	-- Correct the mask coordinates to refer to frame centers, relative to the mask center.
	local xcorr = floor((xdim - fdimx + 1) / 2)
	local ycorr = floor((ydim - fdimy + 1) / 2)

	for i = 2, #frames, 3 do
		frames[i], frames[i + 1] = xcorr - frames[i], ycorr - frames[i + 1]
	end

	--
	local data = { frames = frames, xdim = xdim, ydim = ydim }
	local vals = json.encode(data)

	-- Write a string into a database (which may be opened) --
	-- arg: { name / db, table name (def = "corona_mask_data") } / arg: name / db
	if method == "database_file" or method == "database_handle" then
		WithDatabase(method, source, filename, AuxWrite, vals)

	-- Write to PNG --
	-- arg: { filename, keyword (def = "CoronaMaskData") }
	elseif method == "image_metadata" then
		-- FindText(keyword) = "CoronaMaskData"...
		-- ^^ Add (or update)

	-- Raw string --
	else
		return data, vals
	end

	return data, source
end

--- DOCME
-- @ptable opts
-- @string spec_name
-- @string common_name
-- @string[opt] message
function M.GetPixInt (opts, spec_name, common_name, message)
	assert(opts, "Missing options")

	local int = opts[spec_name] or opts[common_name]

	if not IsPosInt(int) then
		if message then
			assert(false, "Missing pixel " .. message)
		else
			assert(false, "Missing field: <" .. spec_name .. "> or <" .. common_name .. ">")
		end
	end

	return int
end

--
local function GetDim (opts, fdim, dim_name, npix_name, message1, message2)
	if fdim then
		return fdim, ("%i"):format(fdim)
	else
		local pix_dim = _GetPixInt_(opts, dim_name, "pix_dim", message1)
		local npix = _GetPixInt_(opts, npix_name, "npix", message2)

		return pix_dim * npix, ("%ip%i"):format(pix_dim, npix)
	end
end

--
local function AuxNewSheet (opts)
	assert(opts, "Missing options")

	local fdimx, xstr = GetDim(opts, opts.dimx or opts.dim, "pixw", "npix_cols", "width", "column count")
	local fdimy, ystr = GetDim(opts, fdimx or opts.fdimy, "pixh", "npix_rows", "height", "row count")
	local name, id = assert(opts.name, "Missing filename"), opts.id and ("_id_" .. tostring(opts.id)) or ""

	return fdimx, fdimy, ("__%s_%sx%s%s__.png"):format(name, xstr, ystr, id), opts.method, opts.data
end

--
local function BindPatterns (MS, clear, full)
	MS.m_clear, MS.m_full = clear, full
end

--
local function GetCounts (fdimx, fdimy)
	local dx, dy = fdimx + 3, fdimy + 3

	return floor((CW + 3) / dx), floor((CH + 3) / dy), dx, dy
end

--
local function GetDims (x, y, endx, ncols, dy)
	return NextMult4(endx or x), NextMult4(y + (ncols > 0 and dy or 0))
end

--
local function GetScales (fdimx, fdimy, w, h)
	-- (fdimx - 6) / (w - 6)??
end

--- DOCME
-- @ptable opts
-- @treturn MaskSheet MS
function M.NewSheet (opts)
	local fdimx, fdimy, filename, method, data = AuxNewSheet(opts)
	local base_dir = opts.dir or system.CachesDirectory
	local exists, ms_data, source = file.Exists(filename, base_dir)
	local MaskSheet, frames, mask, xscale, yscale = {}, {}

	--
	if exists and not opts.recreate then
		ms_data, source = ReadData(opts, filename, fdimx, fdimy)
	end

--	local XDIM = opts.frame_w or opts.dim or fdimx
--	local YDIM = opts.frame_h or opts.dim or fdimy

	--
	if ms_data then
		mask, frames = graphics.newMask(filename, base_dir), ToFrameMap(ms_data.frames)
		xscale, yscale = GetScales(fdimx, fdimy, ms_data.xdim, ms_data.ydim)

		-- Add dummy methods.
		local function Fail ()
			assert(false, "Mask already created")
		end

		MaskSheet.AddFrame, MaskSheet.Commit, MaskSheet.GetRect, MaskSheet.StashRect = Fail, Fail, Fail, Fail
		MaskSheet.BindPatterns = BindPatterns

	--
	else
		-- If a mask file with the same name exists, remove it.
		if exists then
			assert(base_dir ~= system.ResourceDirectory, "Mask sheet is missing data")

			remove(system.pathForFile(filename, base_dir))
		end

		-- Compute the offset as the 3 pixels of black border plus any padding needed to satisfy
		-- the height requirement. Bounded captures will be used to grab each frame, since using
		-- several containers and capturing all in one go seems to be flaky on the simulator.
		local back, into = BlackRect(display.getCurrentStage(), nil, 0, 0, fdimx, fdimy), opts.into
		local mgroup, stash = display.newGroup(), display.newGroup()

		stash.isVisible = false

		if into then
			into:insert(back)
			into:insert(mgroup)
			into:insert(stash)
		end

		local bounds, yfunc, hidden = back.contentBounds, opts.yfunc or DefYieldFunc, not not opts.hidden
		local cols_done, rows_done, x, y, endx = 0, 0, 3, 3
		local ncols, nrows, dx, dy = GetCounts(fdimx, fdimy)

		--- DOCME
		-- @callable func
		-- @param index
		-- @bool is_white
		-- @callable[opt] after
		function MaskSheet:AddFrame (func, index, is_white, after)
			assert(not mask, "Mask already created")
			assert(rows_done < nrows, "No space for new frames")

			--
			local cgroup, bg = display.newGroup(), is_white and 1 or 0

			if into then
				into:insert(cgroup)
			end

			-- Add the background color, i.e. the component of the frame not defined by the shapes.
			back:setFillColor(bg)

			-- Save the frame's left-hand coordinate.
			frames[#frames + 1] = index
			frames[#frames + 1] = x
			frames[#frames + 1] = y

			--
			func(cgroup, 1 - bg, fdimx, fdimy, index)

			-- Capture the frame and incorporate it into the built-up mask.
			local capture = CaptureBounds(cgroup, bounds, hidden, yfunc)

			mgroup:insert(capture)

			yfunc()

			--
			if after then
				after(cgroup, index)
			end

			cgroup:removeSelf()

			UpperLeftAlign(capture, x, y)

			-- Advance past the frame.
			if cols_done == ncols then
				cols_done, endx = 0, endx or x + dx
				rows_done, x, y = rows_done + 1, 3, y + dy
			else
				cols_done, x = cols_done + 1, x + dx
			end
		end

		--- DOCME
		-- @function MaskSheet:BindPatterns
		-- @uint[opt] clear
		-- @uint[opt] full
		MaskSheet.BindPatterns = BindPatterns

		--- DOCME
		function MaskSheet:Commit ()
			assert(not mask, "Mask already created")

			--
			local xdim, ydim = GetDims(x, y, endx, ncols, dy)
			local background = BlackRect(mgroup, stash, 0, 0, xdim, ydim)

			background:toBack()

			-- Save the image and mask data.
			Save(mgroup, filename, base_dir)

			ms_data, source = WriteData(method, data, frames, fdimx, fdimy, xdim, ydim, filename)

			-- Clean up temporary resources.
			back:removeSelf()
			mgroup:removeSelf()
			stash:removeSelf()

			back, bounds, into, mgroup, stash, yfunc = nil

			-- Create a mask with final frames.
			mask, frames = graphics.newMask(filename, base_dir), ToFrameMap(frames)
			xscale, yscale = GetScales(fdimx, fdimy, xdim, ydim)
		end

		--- DOCME
		-- @pgroup group
		-- @number x
		-- @number y
		-- @number w
		-- @number h
		-- @number[opt] fill
		-- @treturn DisplayObject X
		function MaskSheet:GetRect (group, x, y, w, h, fill)
			assert(not mask, "Mask already created")

			return NewRect(group, stash, x, y, w, h, fill)
		end

		--- DOCME
		-- @pobject rect X
		function MaskSheet:StashRect (rect)
			if stash then
				stash:insert(rect)
			else
				rect:removeSelf()
			end
		end
	end

	--- Getter.
	-- @return X
	function MaskSheet:GetData ()
		return ms_data
	end

	--- Getter.
	-- @return X
	function MaskSheet:GetSource ()
		return source
	end

	--- Predicate.
	-- @treturn boolean S###
	function MaskSheet:IsLoaded ()
		return mask ~= nil
	end

	--- DOCME
	-- @pobject object
	-- @param index
	function MaskSheet:Set (object, index)
		assert(mask, "Mask not ready")

		local not_clear = index ~= self.m_clear

		object.isVisible = not_clear

		if not_clear then -- non-visible cells are fine as is
			-- If a cell is full, there is nothing to mask.
			if index == self.m_full then
				object:setMask(nil)

			-- Otherwise, apply the mask at the given frame.
			else
				object:setMask(mask)

				local x, y = unpack(frames[index])

				object.maskX, object.maskScaleX = x * xscale, xscale
				object.maskY, object.maskScaleY = y * yscale, yscale
				-- ^^ ceil()?
			end
		end
	end

	return MaskSheet
end

--- DOCME
-- @ptable opts
-- @treturn MaskSheet MS
function M.NewSheet_Data (opts)
	local fdimx, fdimy, filename, method, data = AuxNewSheet(opts)
	local MaskSheet, frames, source = {}, {}

	--
	local cols_done, rows_done, x, y, endx = 0, 0, 3, 3
	local ncols, nrows, dx, dy = GetCounts(fdimx, fdimy)

	--- DOCME
	-- @param index
	function MaskSheet:AddFrame (index)
		assert(frames, "Data already created")
		assert(rows_done < nrows, "No space for new frames")

		-- Save the frame's left-hand coordinate.
		frames[#frames + 1] = index
		frames[#frames + 1] = x
		frames[#frames + 1] = y

		--
		if cols_done == ncols then
			cols_done, endx = 0, endx or x + dx
			rows_done, x, y = rows_done + 1, 3, y + dy
		else
			cols_done, x = cols_done + 1, x + dx
		end
	end

	--- DOCME
	function MaskSheet:Commit ()
		assert(frames, "Data already created")

		local xdim, ydim = GetDims(x, y, endx, ncols, dy)

		data, source = WriteData(method, data, frames, fdimx, fdimy, xdim, ydim, filename)

		frames = nil
	end

	--- DOCME
	-- @return ARG
	function MaskSheet:GetData ()
		return data
	end

	--- DOCME
	-- @return ARG
	function MaskSheet:GetSource ()
		return source
	end

	--- Predicate.
	-- @treturn boolean S###
	function MaskSheet:IsLoaded ()
		return frames == nil
	end

	return MaskSheet
end

--- DOCME
-- @pobject object X
-- @number[opt=object.width] w
-- @number[opt=object.height] h
-- See: https://github.com/Lerg/dynamic-masks/blob/master/main.lua
function M.SetDynamicMask (object, w, h)
	--
	display.setDefault("magTextureFilter", "nearest")

	object:setMask(graphics.newMask("corona_utils/assets/mask.png"))

	display.setDefault("magTextureFilter", "linear")

	--
	w, h = w or object.width, h or object.height

	object.maskScaleX = .5 * w
	object.maskScaleY = .5 * h

	if object._type == "GroupObject" then
		object.maskX = object.x + object.maskScaleX
		object.maskY = object.y + object.maskScaleY
	else
		object.maskX = object.x
		object.maskY = object.y
	end
end

-- Cache module members.
_GetPixInt_ = M.GetPixInt

-- Export the module.
return M