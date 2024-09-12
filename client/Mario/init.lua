--!strict
local Mario = {}
Mario.__index = Mario

local SM64 = script.Parent
local Core = SM64.Parent

local FFlags = require(SM64.FFlags)

local Util = require(SM64.Util)
local Enums = require(SM64.Enums)
local Shared = require(Core.Shared)

local Sounds = Shared.Sounds
local Animations = Shared.Animations

local Types = require(SM64.Types)
local Flags = Types.Flags

local Action = Enums.Action
local Buttons = Enums.Buttons
local ActionFlags = Enums.ActionFlags
local ActionGroups = Enums.ActionGroups

local MarioCap = Enums.MarioCap
local MarioEyes = Enums.MarioEyes
local MarioFlags = Enums.MarioFlags
local MarioHands = Enums.MarioHands

local InputFlags = Enums.InputFlags
local ModelFlags = Enums.ModelFlags
local TerrainType = Enums.TerrainType
local SurfaceClass = Enums.SurfaceClass
local ParticleFlags = Enums.ParticleFlags

local AirStep = Enums.AirStep
local HangStep = Enums.HangStep
local GroundStep = Enums.GroundStep

local InteractionStatus = Enums.Interaction.Status

export type BodyState = Types.BodyState
export type Controller = Types.Controller
export type MarioState = Types.MarioState

export type Mario = typeof(setmetatable({} :: MarioState, Mario))
export type MarioAction = (Mario) -> boolean
export type Flags = Types.Flags
export type Class = Mario

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- VARIABLES
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local SHORT_TO_RAD = (2 * math.pi) / 0x10000
local sMovingSandSpeeds = { 12, 8, 4, 0 }
local Vector3XZ = Vector3.new(1, 0, 1)
local RAD90 = (math.pi / 2)

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- HELPERS
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function solveBestWallFromAngle(walls: { RaycastResult }, angle: number): RaycastResult?
	local angleDiffStore = math.huge
	local best: RaycastResult?

	for _, wall in ipairs(walls) do
		local angleDiff = Util.AbsAngleDiff(Util.SignedShort(angle - 0x8000), Util.Atan2s(wall.Normal.Z, wall.Normal.X))

		if angleDiff < angleDiffStore then
			angleDiffStore = angleDiff
			best = wall
		end
	end

	return best
end

local function clipMario(m: Mario, nextPos: Vector3, heightOff: number?): Vector3
	if FFlags.CONTINUOUS_INSTEAD_OF_QSTEP then
		local heightOffset: number = (tonumber(heightOff) or 0)
		local origin = m.Position + (Vector3.yAxis * heightOffset)
		local delta = nextPos - m.Position

		local nextClip: RaycastResult? = delta.Magnitude > 0.01 and Util.RaycastSM64(origin, delta) or nil
		local maybeNextPos = nextPos

		if nextClip then
			local ignoreWall, ignoreFloor, ignoreCeil = Util.GetIgnoredCollisions(nextClip)
			local normalY = nextClip.Normal.Y

			-- Push away from clip position
			-- we make sure we do a safe floor push, otherwise mario'd get propulsed upwards/downwards
			-- in a weird way since the ray origin vector is higher than m.Position
			if not ignoreWall and (math.abs(normalY) < 0.01) then
				maybeNextPos = Util.SetY(nextClip.Position + (nextClip.Normal * 5), nextPos.Y)
			elseif math.abs(normalY) >= 0.01 then
				if (normalY >= 0.01 and not ignoreFloor) or (normalY <= -0.01 and not ignoreCeil) then
					local dir = 16 * math.sign(normalY)
					maybeNextPos = Util.SetY(nextClip.Position, nextPos.Y + dir)
				end
			end
		end

		-- Move maybeNextPos up/down depending on the angle we're looking at from the normal,
		-- so steep floor angles can be detected. This intentionally keeps the de-facto speed
		-- behavior intact.
		local slopeDisplaceApplicable = math.abs(m.Position.Y - m.FloorHeight) < 1.0
		local surfNormal = m.Floor and m.Floor.Normal or Vector3.yAxis
		local surfAngle = m.FloorAngle

		if math.abs(surfNormal.Y) < 0.8 and slopeDisplaceApplicable then
			local angleDiff = ((SHORT_TO_RAD * (surfAngle - m.FaceAngle.Y)) - RAD90) / RAD90
			maybeNextPos += Vector3.yAxis * 16 * math.clamp(angleDiff, -1, 1) * math.sign(m.ForwardVel)
		end

		return maybeNextPos
	end

	return nextPos
end

local function solveContinuousClip(m: Mario, nextPos: Vector3, heightOff: number): Vector3
	if not FFlags.CONTINUOUS_INSTEAD_OF_QSTEP then
		return nextPos
	end

	local maybeNextPos = nextPos
	local delta = nextPos - m.Position

	-- We wish to move as much as possible, so we need to cut the travel
	-- distance if there was no floor found.
	-- This should always be successful first attempt, unless you have
	-- a really high amount of forward velocity.
	for i = 1, 0.25, -0.25 do
		local travelDist = (delta * i)

		-- Ignore short
		if travelDist.Magnitude < 64 and i ~= 1 then
			break
		end

		local clipped = clipMario(m, m.Position + travelDist, heightOff)
		local _, floorHere = Util.FindFloor(clipped)

		if floorHere then
			maybeNextPos = clipped
			break
		end
	end

	return maybeNextPos
end

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- BINDINGS
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local actions: { MarioAction } = {}
Mario.Animations = Animations
Mario.Actions = actions
Mario.Sounds = Sounds
Mario.Enums = Enums
Mario.Types = Types
Mario.Util = Util

function Mario.RegisterAction(actionType: number, action: MarioAction)
	if actions[actionType] then
		warn("Action", Enums.GetName(Action, actionType), "was registered twice!")
	end

	actions[actionType] = action
end

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- ANIMATIONS
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

function Mario.IsAnimAtEnd(m: Mario): boolean
	return m.AnimFrame >= m.AnimFrameCount
end

function Mario.IsAnimPastEnd(m: Mario, sub: number?): boolean
	local sub: number = tonumber(sub) or 2
	return m.AnimFrame >= m.AnimFrameCount - sub
end

function Mario.SetAnimation(m: Mario, anim: Animation): number
	if anim and typeof(anim) == "Instance" and anim:IsA("Animation") then
		if m.AnimCurrent == anim then
			return m.AnimFrame
		end

		m.AnimFrameCount = anim:GetAttribute("NumFrames")
		m.AnimCurrent = anim
	else
		warn("Invalid animation provided in SetAnimation:", anim, debug.traceback())
		m.AnimFrameCount = 0
		m.AnimCurrent = nil
	end

	local startFrame: number = anim and anim:GetAttribute("StartFrame") or 0
	m.AnimAccelAssist = 0
	m.AnimAccel = 0

	m.AnimReset = true
	m.AnimDirty = true
	m.AnimFrame = startFrame

	return startFrame
end

function Mario.SetAnimationWithAccel(m: Mario, anim: Animation, accel: number)
	if m.AnimCurrent ~= anim then
		m:SetAnimation(anim)
		m.AnimAccelAssist = -accel
	end

	m.AnimAccel = accel
	return m.AnimFrame
end

function Mario.SetAnimToFrame(m: Mario, frame: number)
	if m.AnimAccel ~= 0 then
		m.AnimAccelAssist = bit32.lshift(frame, 0x10) + m.AnimAccel
		m.AnimFrame = bit32.rshift(m.AnimAccelAssist, 0x10)
	else
		m.AnimFrame = frame + 1
	end

	m.AnimDirty = true
	m.AnimSetFrame = m.AnimFrame
end

function Mario.IsAnimPastFrame(m: Mario, frame: number): boolean
	local isPastFrame: boolean = false
	local accel = m.AnimAccel

	if accel ~= 0 then
		local assist = m.AnimAccelAssist
		local accelFrame = bit32.lshift(frame, 0x10)
		isPastFrame = (assist > accelFrame and accelFrame >= assist - accel)
	else
		isPastFrame = (m.AnimFrame == (frame + 1))
	end

	return isPastFrame
end

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- AUDIO
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

function Mario.PlaySound(_, sound: Instance?)
	if not sound then
		return
	end

	assert(sound)

	if sound:IsA("Sound") then
		sound:SetAttribute("Play", true)
	else
		local rollTable = {}
		local chances = sound:GetAttributes()

		for name, chance in pairs(chances) do
			for _ = 1, chance do
				table.insert(rollTable, name)
			end
		end

		if #rollTable > 0 then
			local pick = rollTable[math.random(1, #rollTable)]
			sound = Sounds[pick]

			if sound then
				sound:SetAttribute("Play", true)
			end
		end
	end
end

function Mario.PlaySoundIfNoFlag(m: Mario, sound: Instance?, flags: number)
	if not m.Flags:Has(flags) and sound then
		m:PlaySound(sound)
		m.Flags:Add(flags)
	end
end

function Mario.PlayJumpSound(m: Mario)
	if m.Flags:Has(MarioFlags.MARIO_SOUND_PLAYED) then
		return
	end

	if m.Action() == Action.TRIPLE_JUMP then
		m:PlaySound(Sounds.MARIO_YAHOO_WAHA_YIPPEE)
	elseif m.Action() == Action.JUMP_KICK then
		m:PlaySound(Sounds.MARIO_PUNCH_HOO)
	else
		m:PlaySound(Sounds.MARIO_YAH_WAH_HOO)
	end

	m.Flags:Add(MarioFlags.MARIO_SOUND_PLAYED)
end

function Mario.AdjustSoundForSpeed(m: Mario)
	local _absForwardVel = math.abs(m.ForwardVel)
	-- TODO: Adjust Moving Speed Pitch
end

function Mario.PlaySoundAndSpawnParticles(m: Mario, sound: Instance?, wave: number?)
	local particles: number?

	if m.TerrainType == TerrainType.WATER then
		if wave ~= 0 then
			particles = ParticleFlags.SHALLOW_WATER_SPLASH
		else
			particles = ParticleFlags.SHALLOW_WATER_WAVE
		end
	else
		if m.TerrainType == TerrainType.SAND then
			particles = ParticleFlags.DIRT
		elseif m.TerrainType == TerrainType.SNOW then
			particles = ParticleFlags.SNOW
		end
	end

	if particles then
		m.ParticleFlags:Add(particles)
	end

	if sound then
		local terrainType = Enums.GetName(TerrainType, m.TerrainType)
		local stepSound = Sounds[sound.Name .. "_" .. terrainType]

		if stepSound then
			m:PlaySound(stepSound)
		else
			m:PlaySound(sound)
		end
	end
end

function Mario.PlayActionSound(m: Mario, sound: Instance?, wave: number?)
	if not m.Flags:Has(MarioFlags.ACTION_SOUND_PLAYED) then
		m:PlaySoundAndSpawnParticles(sound, wave)
		m.Flags:Add(MarioFlags.ACTION_SOUND_PLAYED)
	end
end

function Mario.PlayLandingSound(m: Mario, maybeSound: Instance?)
	local sound = maybeSound or Sounds.ACTION_TERRAIN_LANDING

	-- stylua: ignore
	local landSound = if m.Flags:Has(MarioFlags.METAL_CAP)
		then Sounds.ACTION_METAL_LANDING
		else sound

	m:PlaySoundAndSpawnParticles(landSound, 1)
end

function Mario.PlayLandingSoundOnce(m: Mario, sound: Instance?)
	-- stylua: ignore
	local landSound = if m.Flags:Has(MarioFlags.METAL_CAP)
		then Sounds.ACTION_METAL_LANDING
		else sound

	m:PlayActionSound(landSound, 1)
end

function Mario.PlayHeavyLandingSound(m: Mario, sound: Instance?)
	-- stylua: ignore
	local landSound = if m.Flags:Has(MarioFlags.METAL_CAP)
		then Sounds.ACTION_METAL_HEAVY_LANDING
		else sound

	m:PlaySoundAndSpawnParticles(landSound, 1)
end

function Mario.PlayHeavyLandingSoundOnce(m: Mario, sound: Instance?)
	-- stylua: ignore
	local landSound = if m.Flags:Has(MarioFlags.METAL_CAP)
		then Sounds.ACTION_METAL_HEAVY_LANDING
		else sound

	m:PlayActionSound(landSound, 1)
end

function Mario.PlayMarioSound(m: Mario, actionSound: Instance, marioSound: Instance?)
	if marioSound == nil then
		marioSound = Sounds.MARIO_JUMP
	end

	if actionSound == Sounds.ACTION_TERRAIN_JUMP then
		-- stylua: ignore
		local sound = if m.Flags:Has(MarioFlags.METAL_CAP)
			then Sounds.ACTION_METAL_JUMP
			else actionSound

		m:PlayActionSound(sound)
	else
		m:PlaySoundIfNoFlag(actionSound, MarioFlags.ACTION_SOUND_PLAYED)
	end

	if marioSound == Sounds.MARIO_JUMP or marioSound == nil then
		m:PlayJumpSound()
	elseif marioSound then
		m:PlaySoundIfNoFlag(marioSound, MarioFlags.MARIO_SOUND_PLAYED)
	end
end

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- ACTION STATE
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

function Mario.SetForwardVel(m: Mario, forwardVel: number)
	m.ForwardVel = forwardVel

	m.SlideVelX = Util.Sins(m.FaceAngle.Y) * forwardVel
	m.SlideVelZ = Util.Coss(m.FaceAngle.Y) * forwardVel

	m.Velocity = Vector3.new(m.SlideVelX, m.Velocity.Y, m.SlideVelZ)
end

function Mario.GetFloorClass(m: Mario): number
	local floor = m.Floor
	local hit = floor and floor.Instance

	if hit then
		if FFlags.FLOOR_NEVER_SLIPPERY then
			return SurfaceClass.NOT_SLIPPERY
		end

		if hit and hit:IsA("BasePart") then
			local surfaceIsHard = hit:HasTag("HardSurface")
			local physics = hit.CurrentPhysicalProperties
			local friction = physics.Friction

			local hard = surfaceIsHard and "HARD_" or ""
			if friction <= 0.025 then
				return SurfaceClass[`{hard}VERY_SLIPPERY`]
			elseif friction <= 0.5 then
				return SurfaceClass[`{hard}SLIPPERY`]
			elseif friction >= 0.9 then
				return SurfaceClass[`{hard}NOT_SLIPPERY`]
			end

			return surfaceIsHard and SurfaceClass.HARD or SurfaceClass.DEFAULT
		end
	end

	return SurfaceClass.DEFAULT
end

function Mario.GetTerrainType(m: Mario): number
	local floor = m.Floor
	-- local hit = floor and floor.Instance

	if floor then
		local material = floor.Material
		local value = TerrainType.FROM_MATERIAL[material]

		if value then
			return value
		end
	end

	return TerrainType.DEFAULT
end

function Mario.GetFloorType(m: Mario, other: RaycastResult?): number
	return Util.GetFloorType(other or m.Floor)
end

function Mario.GetWallType(m: Mario, other: RaycastResult?): number
	return Util.GetWallType(other or m.Wall)
end

function Mario.GetCeilType(m: Mario, other: RaycastResult?): number
	return Util.GetCeilType(other or m.Ceil)
end

function Mario.FacingDownhill(m: Mario, turnYaw: boolean?): boolean
	local faceAngleYaw = m.FaceAngle.Y

	if turnYaw and m.ForwardVel < 0 then
		faceAngleYaw += 0x8000
	end

	faceAngleYaw = Util.SignedShort(m.FloorAngle - faceAngleYaw)
	return math.abs(faceAngleYaw) < 0x4000
end

function Mario.FloorIsSlippery(m: Mario)
	local floor = m.Floor

	if floor then
		local floorClass = m:GetFloorClass()
		local normY = 0.7880108

		if floorClass == SurfaceClass.VERY_SLIPPERY then
			normY = 0.9848077 -- ~cos(10 deg)
		elseif floorClass == SurfaceClass.SLIPPERY then
			normY = 0.9396926 -- ~cos(20 deg)
		elseif floorClass == SurfaceClass.NOT_SLIPPERY then
			return false
		end

		return floor.Normal.Y <= normY
	end

	return false
end

function Mario.FloorIsSlope(m: Mario)
	local floor = m.Floor

	if floor then
		local floorClass = m:GetFloorClass()
		local deg = 15

		if floorClass == SurfaceClass.VERY_SLIPPERY then
			deg = 5
		elseif floorClass == SurfaceClass.SLIPPERY then
			deg = 10
		elseif floorClass == SurfaceClass.NOT_SLIPPERY then
			deg = 20
		end

		local rad = math.rad(deg)
		return floor.Normal.Y <= math.cos(rad)
	end

	return false
end

function Mario.FloorIsSteep(m: Mario)
	local floor = m.Floor

	if floor and not m:FacingDownhill() then
		local floorClass = m:GetFloorClass()
		local deg = 30

		if floorClass == SurfaceClass.VERY_SLIPPERY then
			deg = 15
		elseif floorClass == SurfaceClass.SLIPPERY then
			deg = 20
		elseif floorClass == SurfaceClass.NOT_SLIPPERY then
			deg = 30
		end

		local rad = math.rad(deg)
		return floor.Normal.Y <= math.cos(rad)
	end

	return false
end

function Mario.FindFloorHeightRelativePolar(
	m: Mario,
	angleFromMario: number,
	distFromMario: number
): (number, RaycastResult?)
	local y = Util.Sins(m.FaceAngle.Y + angleFromMario) * distFromMario
	local x = Util.Coss(m.FaceAngle.Y + angleFromMario) * distFromMario

	local marioPos = m.Position
	local testPos = marioPos + Vector3.new(y, 100, x)

	return Util.FindFloor(testPos)
end

function Mario.FindFloorSlope(m: Mario, yawOffset: number)
	local x = Util.Sins(m.FaceAngle.Y + yawOffset) * 5
	local z = Util.Coss(m.FaceAngle.Y + yawOffset) * 5

	local forwardFloorY = Util.FindFloor(m.Position + Vector3.new(x, 100, z))
	local backwardFloorY = Util.FindFloor(m.Position + Vector3.new(-x, 100, -z))
	local result = 0

	if forwardFloorY and backwardFloorY then
		local forwardYDelta = forwardFloorY - m.Position.Y
		local backwardYDelta = m.Position.Y - backwardFloorY

		if forwardYDelta ^ 2 < backwardYDelta ^ 2 then
			result = Util.Atan2s(5, forwardYDelta)
		else
			result = Util.Atan2s(5, backwardYDelta)
		end
	end

	return result
end

function Mario.SetSteepJumpAction(m: Mario)
	m.SteepJumpYaw = m.FaceAngle.Y

	if m.ForwardVel > 0 then
		--! ((s16)0x8000) has undefined behavior. Therefore, this downcast has
		-- undefined behavior if m->floorAngle >= 0.
		local angleTemp = Util.SignedShort(m.FloorAngle + 0x8000)
		local faceAngleTemp = Util.SignedShort(m.FaceAngle.Y - angleTemp)

		local y = Util.Sins(faceAngleTemp) * m.ForwardVel
		local x = Util.Coss(faceAngleTemp) * m.ForwardVel * 0.75

		m.ForwardVel = math.sqrt(y * y + x * x)
		m.FaceAngle = Util.SetY(m.FaceAngle, Util.Atan2s(x, y) + angleTemp)
	end

	m:DropAndSetAction(Action.STEEP_JUMP, 0)
end

function Mario.SetYVelBasedOnFSpeed(m: Mario, initialVelY: number, multiplier: number)
	m.Velocity = Util.SetY(m.Velocity, initialVelY + m.ForwardVel * multiplier)

	if m.SquishTimer ~= 0 or m.QuicksandDepth > 1 then
		m.Velocity *= Vector3.new(1, 0.5, 1)
	end
end

function Mario.SetActionAirborne(m: Mario, action: number, actionArg: number)
	if m.SquishTimer ~= 0 or m.QuicksandDepth > 1 then
		if action == Action.DOUBLE_JUMP or action == Action.TWIRLING then
			action = Action.JUMP
		end
	end

	if action == Action.DOUBLE_JUMP then
		m:SetYVelBasedOnFSpeed(52, 0.25)
		m.ForwardVel *= 0.8
	elseif action == Action.BACKFLIP then
		m.AnimReset = true
		m.ForwardVel = -16
		m:SetYVelBasedOnFSpeed(62, 0)
	elseif action == Action.TRIPLE_JUMP then
		m:SetYVelBasedOnFSpeed(69, 0)
		m.ForwardVel *= 0.8
	elseif action == Action.FLYING_TRIPLE_JUMP then
		m:SetYVelBasedOnFSpeed(82, 0)
	elseif action == Action.WATER_JUMP or action == Action.HOLD_WATER_JUMP then
		if actionArg == 0 then
			m:SetYVelBasedOnFSpeed(42, 0)
		end
	elseif action == Action.BURNING_JUMP then
		m.Velocity = Util.SetY(m.Velocity, 31.5)
		m.ForwardVel = 8
	elseif action == Action.RIDING_SHELL_JUMP then
		m:SetYVelBasedOnFSpeed(42, 0.25)
	elseif action == Action.JUMP or action == Action.HOLD_JUMP then
		m.AnimReset = true
		m:SetYVelBasedOnFSpeed(42, 0.25)
		m.ForwardVel *= 0.8
	elseif action == Action.WALL_KICK_AIR or action == Action.TOP_OF_POLE_JUMP then
		m:SetYVelBasedOnFSpeed(62, 0)

		if m.ForwardVel < 24 then
			m.ForwardVel = 24
		end

		m.WallKickTimer = 0
	elseif action == Action.SIDE_FLIP then
		m:SetYVelBasedOnFSpeed(62, 0)
		m.ForwardVel = 8
		m.FaceAngle = Util.SetY(m.FaceAngle, m.IntendedYaw)
	elseif action == Action.STEEP_JUMP then
		m.AnimReset = true
		m:SetYVelBasedOnFSpeed(42, 0.25)
		m.FaceAngle = Util.SetX(m.FaceAngle, -0x2000)
	elseif action == Action.LAVA_BOOST then
		m.Velocity = Util.SetY(m.Velocity, 84)

		if actionArg == 0 then
			m.ForwardVel = 0
		end
	elseif action == Action.DIVE then
		local forwardVel = m.ForwardVel + 15

		if forwardVel > 48 then
			forwardVel = 48
		end

		m:SetForwardVel(forwardVel)
	elseif action == Action.LONG_JUMP then
		m.AnimReset = true
		m:SetYVelBasedOnFSpeed(30, 0)

		m.LongJumpIsSlow = if m.ForwardVel > 16 then false else true

		--! (BLJ's) This properly handles long jumps from getting forward speed with
		--  too much velocity, but misses backwards longs allowing high negative speeds.
		m.ForwardVel *= 1.5

		if m.ForwardVel > 48 then
			m.ForwardVel = 48
		end
	elseif action == Action.SLIDE_KICK then
		m.Velocity = Util.SetY(m.Velocity, 12)

		if m.ForwardVel < 32 then
			m.ForwardVel = 32
		end
	elseif action == Action.JUMP_KICK then
		m.Velocity = Util.SetY(m.Velocity, 20)
	end

	m.PeakHeight = m.Position.Y
	m.Flags:Add(MarioFlags.MOVING_UP_IN_AIR)

	return action
end

function Mario.SetActionMoving(m: Mario, action: number, actionArg: number?): number
	local forwardVel = m.ForwardVel
	local floorClass = m:GetFloorClass()
	local mag = math.min(m.IntendedMag, 8)
	actionArg = actionArg or 0

	if action == Action.WALKING then
		if floorClass ~= SurfaceClass.VERY_SLIPPERY then
			if 0.0 <= forwardVel and forwardVel < mag then
				m.ForwardVel = mag
			end
		end

		m.WalkingPitch = 0
	elseif action == Action.HOLD_WALKING then
		if 0.0 <= forwardVel and forwardVel < mag / 2 then
			m.ForwardVel = mag / 2
		end
	elseif action == Action.BEGIN_SLIDING then
		if m:FacingDownhill(false) then
			action = Action.BUTT_SLIDE
		else
			action = Action.STOMACH_SLIDE
		end
	elseif action == Action.HOLD_BEGIN_SLIDING then
		if m:FacingDownhill() then
			action = Action.HOLD_BUTT_SLIDE
		else
			action = Action.HOLD_STOMACH_SLIDE
		end
	end

	return action
end

function Mario.SetActionSubmerged(m: Mario, action: number, actionArg: number): number
	actionArg = actionArg or 0
	if action == Action.METAL_WATER_JUMP or action == Action.HOLD_METAL_WATER_JUMP then
		m.Velocity = Util.SetY(m.Velocity, 32)
	end

	return action
end

function Mario.SetActionCutscene(m: Mario, action: number, actionArg: number): number
	actionArg = actionArg or 0
	if action == Action.EMERGE_FROM_PIPE then
		m.Velocity = Util.SetY(m.Velocity, 52)
	elseif action == Action.FALL_AFTER_STAR_GRAB then
		m:SetForwardVel(0)
	elseif action == Action.SPAWN_SPIN_AIRBORNE then
		m:SetForwardVel(2)
	elseif action == Action.SPECIAL_EXIT_AIRBORNE or action == Action.SPECIAL_DEATH_EXIT then
		m.Velocity = Util.SetY(m.Velocity, 64)
	end

	return action
end

function Mario.SetAction(m: Mario, action: number, maybeActionArg: number?): boolean
	local group = bit32.band(action, ActionGroups.GROUP_MASK)
	local actionArg = maybeActionArg or 0

	if group == ActionGroups.MOVING then
		action = m:SetActionMoving(action, actionArg)
	elseif group == ActionGroups.AIRBORNE then
		action = m:SetActionAirborne(action, actionArg)
	elseif group == ActionGroups.SUBMERGED then
		action = m:SetActionSubmerged(action, actionArg)
	elseif group == ActionGroups.CUTSCENE then
		action = m:SetActionCutscene(action, actionArg)
	end

	m.Flags:Remove(MarioFlags.ACTION_SOUND_PLAYED, MarioFlags.MARIO_SOUND_PLAYED)

	if not m.Action:Has(ActionFlags.AIR) then
		m.Flags:Remove(MarioFlags.FALLING_FAR)
	end

	m.PrevAction:Copy(m.Action)
	m.Action:Set(action)

	m.ActionArg = actionArg
	m.ActionState = 0
	m.ActionTimer = 0

	return true
end

function Mario.DropAndSetAction(m: Mario, action: number, actionArg: number?): boolean
	-- Placeholder until replaced
	return m:SetAction(action, actionArg)
end

function Mario.DropHeldObject(m: Mario)
	-- Placeholder until replaced
end

function Mario.GetCollidedObject(m: Mario)
	-- Placeholder until replaced
end

function Mario.ThrowHeldObject(m: Mario)
	-- Placeholder until replaced
end

function Mario.GrabUsedObject(m: Mario)
	-- Placeholder until replaced
end

function Mario.CheckObjectGrab(m: Mario): boolean
	-- Placeholder until replaced
	return false
end

function Mario.SetJumpFromLanding(m: Mario)
	if m.QuicksandDepth >= 11.0 then
		return m:SetAction(Action.QUICKSAND_JUMP_LAND, 0)
	end

	if m:FloorIsSteep() then
		m:SetSteepJumpAction()
	elseif m.DoubleJumpTimer == 0 or m.SquishTimer ~= 0 then
		m:SetAction(Action.JUMP, 0)
	else
		local prev = m.PrevAction()

		if prev == Action.JUMP_LAND or prev == Action.FREEFALL_LAND or prev == Action.SIDE_FLIP_LAND_STOP then
			m:SetAction(Action.DOUBLE_JUMP)
		elseif prev == Action.DOUBLE_JUMP_LAND then
			if m.Flags:Has(MarioFlags.WING_CAP) then
				m:SetAction(Action.FLYING_TRIPLE_JUMP)
			elseif m.ForwardVel > 20 then
				m:SetAction(Action.TRIPLE_JUMP)
			else
				m:SetAction(Action.JUMP)
			end
		else
			m:SetAction(Action.JUMP)
		end
	end

	m.DoubleJumpTimer = 0
	return true
end

function Mario.SetJumpingAction(m: Mario, action: number, actionArg: number?)
	if m.QuicksandDepth >= 11.0 then
		return m:SetAction(Action.QUICKSAND_JUMP_LAND, 0)
	end

	if m:FloorIsSteep() then
		m:SetSteepJumpAction()
	else
		m:SetAction(action, actionArg)
	end

	return true
end

function Mario.HurtAndSetAction(m: Mario, action: number, actionArg: number, hurtCounter: number)
	m.HurtCounter = hurtCounter
	m:SetAction(action, actionArg)
end

function Mario.CheckCommonActionExits(m: Mario)
	if m.Input:Has(InputFlags.A_PRESSED) then
		return m:SetAction(Action.JUMP)
	end

	if m.Input:Has(InputFlags.OFF_FLOOR) then
		return m:SetAction(Action.FREEFALL)
	end

	if m.Input:Has(InputFlags.NONZERO_ANALOG) then
		return m:SetAction(Action.WALKING)
	end

	if m.Input:Has(InputFlags.ABOVE_SLIDE) then
		return m:SetAction(Action.BEGIN_SLIDING)
	end

	return false
end

function Mario.CheckCommonHoldActionExits(m: Mario)
	if m.Input:Has(InputFlags.A_PRESSED) then
		return m:SetAction(Action.HOLD_JUMP)
	end

	if m.Input:Has(InputFlags.OFF_FLOOR) then
		return m:SetAction(Action.HOLD_FREEFALL)
	end

	if m.Input:Has(InputFlags.NONZERO_ANALOG) then
		return m:SetAction(Action.HOLD_WALKING)
	end

	if m.Input:Has(InputFlags.ABOVE_SLIDE) then
		return m:SetAction(Action.HOLD_BEGIN_SLIDING)
	end

	return false
end

function Mario.UpdatePunchSequence(m: Mario)
	local endAction, crouchEndAction
	local animFrame

	if m.Action:Has(ActionFlags.MOVING) then
		endAction = Action.WALKING
		crouchEndAction = Action.CROUCH_SLIDE
	else
		endAction = Action.IDLE
		crouchEndAction = Action.CROUCHING
	end

	local actionArg = m.ActionArg

	if actionArg == 0 or actionArg == 1 then
		if actionArg == 0 then
			m:PlaySound(Sounds.MARIO_PUNCH_YAH)
		end

		m:SetAnimation(Animations.FIRST_PUNCH)
		m.ActionArg = m:IsAnimPastEnd(0) and 2 or 1

		if m.AnimFrame >= 2 then
			if m:CheckObjectGrab() then
				return true
			end

			m.Flags:Add(MarioFlags.PUNCHING)
		end
	elseif actionArg == 2 then
		m:SetAnimation(Animations.FIRST_PUNCH_FAST)

		if m.AnimFrame <= 0 then
			m.Flags:Add(MarioFlags.PUNCHING)
		end

		if m.Input:Has(InputFlags.B_PRESSED) then
			m.ActionArg = 3
		end

		if m:IsAnimAtEnd() then
			m:SetAction(endAction)
		end
	elseif actionArg == 3 or actionArg == 4 then
		if actionArg == 3 then
			m:PlaySound(Sounds.MARIO_PUNCH_WAH)
		end

		m:SetAnimation(Animations.SECOND_PUNCH)
		m.ActionArg = m:IsAnimPastEnd(0) and 5 or 4

		if m.AnimFrame > 0 then
			m.Flags:Add(MarioFlags.PUNCHING)
		end

		if m.ActionArg == 5 then
			m.BodyState.PunchType = 1
			m.BodyState.PunchTimer = 4
		end
	elseif actionArg == 5 then
		m:SetAnimation(Animations.SECOND_PUNCH_FAST)

		if m.AnimFrame <= 0 then
			m.Flags:Add(MarioFlags.PUNCHING)
		end

		if m.Input:Has(InputFlags.B_PRESSED) then
			m.ActionArg = 6
		end

		if m:IsAnimAtEnd() then
			m:SetAction(endAction)
		end
	elseif actionArg == 6 then
		m:PlayActionSound(Sounds.MARIO_PUNCH_HOO, 1)
		animFrame = m:SetAnimation(Animations.GROUND_KICK)

		if animFrame == 0 then
			m.BodyState.PunchType = 2
			m.BodyState.PunchTimer = 6
		end

		if animFrame >= 0 and animFrame < 8 then
			m.Flags:Add(MarioFlags.KICKING)
		end

		if m:IsAnimAtEnd() then
			m:SetAction(endAction)
		end
	elseif actionArg == 9 then
		m:PlayActionSound(Sounds.MARIO_PUNCH_HOO, 1)
		m:SetAnimation(Animations.BREAKDANCE)
		animFrame = m.AnimFrame

		if animFrame >= 2 and animFrame < 8 then
			m.Flags:Add(MarioFlags.TRIPPING)
		end

		if m:IsAnimAtEnd() then
			m:SetAction(crouchEndAction)
		end
	end

	return false
end

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- PHYSICS STEP
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

function Mario.BonkReflection(m: Mario, negateSpeed: boolean?)
	local wall = m.Wall

	if wall ~= nil then
		local wallAngle = Util.Atan2s(wall.Normal.Z, wall.Normal.X)
		m.FaceAngle = Util.SetY(m.FaceAngle, wallAngle - (m.FaceAngle.Y - wallAngle))
		m:PlaySound(if m.Flags:Has(MarioFlags.METAL_CAP) then Sounds.ACTION_METAL_BONK else Sounds.ACTION_BONK)
	else
		m:PlaySound(Sounds.ACTION_HIT)
	end

	if negateSpeed then
		m:SetForwardVel(-m.ForwardVel)
	else
		m.FaceAngle += Vector3int16.new(0, 0x8000, 0)
	end

	m.Inertia = Vector3.zero
end

function Mario.PushOffSteepFloor(m: Mario, action: number, actionArg: number?)
	local floorDYaw = m.FloorAngle - m.FaceAngle.Y

	if floorDYaw > -0x4000 and floorDYaw < 0x4000 then
		m.ForwardVel = 16
		m.FaceAngle = Util.SetY(m.FaceAngle, m.FloorAngle)
	else
		m.ForwardVel = -16
		m.FaceAngle = Util.SetY(m.FaceAngle, m.FloorAngle + 0x8000)
	end

	m:SetAction(action, actionArg)
end

function Mario.UpdateMovingSand(m: Mario): boolean
	local floor = m.Floor
	local floorType = m:GetFloorType()

	if
		floor
		and (
			floorType == SurfaceClass.DEEP_MOVING_QUICKSAND
			or floorType == SurfaceClass.SHALLOW_MOVING_QUICKSAND
			or floorType == SurfaceClass.MOVING_QUICKSAND
			or floorType == SurfaceClass.INSTANT_MOVING_QUICKSAND
		)
	then
		local force = tonumber(floor.Instance:GetAttribute("Force")) or 0
		local pushAngle = Util.SignedShort(bit32.lshift(force, 8))
		local pushSpeed = sMovingSandSpeeds[bit32.rshift(force, 8) + 1]

		m.Velocity += Vector3.new(pushSpeed * Util.Sins(pushAngle), 0, pushSpeed * Util.Coss(pushAngle))

		return true
	end

	return false
end

function Mario.UpdateWindyGround(m: Mario): boolean
	local floor = m.Floor
	local floorType = m:GetFloorType()

	if floor and floorType == SurfaceClass.HORIZONTAL_WIND then
		local force = tonumber(floor.Instance:GetAttribute("Force")) or 0

		local pushSpeed = 0
		local pushAngle = bit32.lshift(force, 8)

		if m.Action:Has(ActionFlags.MOVING) then
			local pushDYaw = Util.SignedShort(m.FaceAngle.Y - pushAngle)

			pushSpeed = m.ForwardVel > 0 and -m.ForwardVel * 0.5 or -8.0

			if pushDYaw > -0x4000 and pushDYaw < 0x4000 then
				pushSpeed *= -1.0
			end

			pushSpeed *= Util.Coss(pushDYaw)
		else
			pushSpeed = 3.2 + (Util.GlobalTimer % 4)
		end

		m.Velocity += Vector3.new(pushSpeed * Util.Sins(pushAngle), 0, pushSpeed * Util.Coss(pushAngle))
		return true
	end

	return false
end

function Mario.StopAndSetHeightToFloor(m: Mario)
	m:SetForwardVel(0)
	m.Inertia = Vector3.zero
	m.Velocity *= Vector3XZ
	m.Position = Util.SetY(m.Position, m.FloorHeight)
	m.GfxAngle = Vector3int16.new(0, m.FaceAngle.Y, 0)
end

function Mario.StationaryGroundStep(m: Mario): number
	local takeStep = 0
	local stepResult = GroundStep.NONE

	m:SetForwardVel(0)

	takeStep = m:UpdateMovingSand() and 1 or 0
	takeStep = bit32.bor(takeStep, m:UpdateWindyGround() and 1 or 0)
	if takeStep == 1 or FFlags.SGS_ALWAYS_PERFORMS_STEPS then
		stepResult = m:PerformGroundStep()
	else
		--! This is responsible for several stationary downwarps.
		m.Position = Util.SetY(m.Position, m.FloorHeight)

		m.GfxPos = Vector3.zero
		m.GfxAngle = Vector3int16.new(0, m.FaceAngle.Y, 0)
	end

	return stepResult
end

function Mario.PerformGroundQuarterStep(m: Mario, nextPos: Vector3): number
	nextPos = solveContinuousClip(m, nextPos, 60)
	local lowerPos = Util.FindWallCollisions(nextPos, 30, 24)
	nextPos = lowerPos

	local upperPos, upperWall, allWalls = Util.FindWallCollisions(nextPos, 60, 50)
	nextPos = upperPos

	if FFlags.FIX_WALLCUCKING then
		upperWall = solveBestWallFromAngle(allWalls, m.FaceAngle.Y)
	end

	local floorHeight, floor = Util.FindFloor(nextPos)
	local ceilHeight = Util.FindCeil(nextPos, floorHeight)

	m.Wall = upperWall

	if floor == nil then
		return GroundStep.HIT_WALL_STOP_QSTEPS
	end

	if m.Action:Has(ActionFlags.RIDING_SHELL) and m.FloorHeight <= m.WaterLevel and m.WaterSurfacePseudoFloor then
		floorHeight = m.WaterLevel
		floor = m.WaterSurfacePseudoFloor
	end

	if nextPos.Y > floorHeight + 100 then
		if nextPos.Y + 160 >= ceilHeight then
			return GroundStep.HIT_WALL_STOP_QSTEPS
		end

		m.Position = nextPos
		m.Floor = floor
		m.FloorHeight = floorHeight

		return GroundStep.LEFT_GROUND
	end

	if floorHeight + 160 >= ceilHeight then
		return GroundStep.HIT_WALL_STOP_QSTEPS
	end

	m.Floor = floor
	m.FloorHeight = floorHeight
	m.Position = Vector3.new(nextPos.X, floorHeight, nextPos.Z)

	if upperWall then
		local wallDYaw = Util.SignedShort(Util.Atan2s(upperWall.Normal.Z, upperWall.Normal.X) - m.FaceAngle.Y)

		if math.abs(wallDYaw) >= 0x2AAA and math.abs(wallDYaw) <= 0x5555 then
			return GroundStep.NONE
		end

		return GroundStep.HIT_WALL_CONTINUE_QSTEPS
	end

	return GroundStep.NONE
end

function Mario.PerformGroundStep(m: Mario): number
	local floor = m.Floor

	if not floor then
		return GroundStep.NONE
	end

	local stepResult: number
	assert(floor)

	local steps = FFlags.CONTINUOUS_INSTEAD_OF_QSTEP and 1 or 4
	for _ = 1, steps do
		local intendedVel = m.Velocity
		local intendedX = m.Position.X + floor.Normal.Y * (intendedVel.X / steps)
		local intendedZ = m.Position.Z + floor.Normal.Y * (intendedVel.Z / steps)
		local intendedY = m.Position.Y

		local intendedPos = Vector3.new(intendedX, intendedY, intendedZ)
		stepResult = m:PerformGroundQuarterStep(intendedPos)

		if stepResult == GroundStep.LEFT_GROUND or stepResult == GroundStep.HIT_WALL_STOP_QSTEPS then
			break
		end
	end

	m.TerrainType = m:GetTerrainType()
	m.GfxAngle = Vector3int16.new(0, m.FaceAngle.Y, 0)

	if stepResult == GroundStep.HIT_WALL_CONTINUE_QSTEPS then
		stepResult = GroundStep.HIT_WALL
	end

	return stepResult
end

function Mario.CheckLedgeGrab(m: Mario, wall: RaycastResult, intendedPos: Vector3, nextPos: Vector3): boolean
	if m.Velocity.Y > 0 then
		return false
	end

	local dispX = nextPos.X - intendedPos.X
	local dispZ = nextPos.Z - intendedPos.Z

	if dispX * m.Velocity.X + dispZ * m.Velocity.Z > 0 then
		return false
	end

	local ledgeX = nextPos.X - (wall.Normal.X * 60)
	local ledgeZ = nextPos.Z - (wall.Normal.Z * 60)

	local ledgePos = Vector3.new(ledgeX, nextPos.Y + 160, ledgeZ)
	local ledgeY, ledgeFloor = Util.FindFloor(ledgePos)

	if ledgeY - nextPos.Y < 100 then
		return false
	end

	if ledgeFloor then
		ledgePos = ledgeFloor.Position
		m.Position = ledgePos

		m.Floor = ledgeFloor
		m.FloorHeight = ledgeY
		m.FloorAngle = Util.Atan2s(ledgeFloor.Normal.Z, ledgeFloor.Normal.X)

		m.FaceAngle *= Vector3int16.new(0, 1, 1)
		m.FaceAngle = Util.SetY(m.FaceAngle, Util.Atan2s(wall.Normal.Z, wall.Normal.X) + 0x8000)
	end

	return ledgeFloor ~= nil
end

function Mario.PerformAirQuarterStep(m: Mario, intendedPos: Vector3, stepArg: number)
	local nextPos = solveContinuousClip(m, intendedPos, 75)
	local upperPos, upperWall, allWalls = Util.FindWallCollisions(nextPos, 150, 50)
	nextPos = upperPos

	local lowerPos, lowerWall = Util.FindWallCollisions(nextPos, 30, 50)
	nextPos = lowerPos

	if FFlags.FIX_WALLCUCKING then
		upperWall = solveBestWallFromAngle(allWalls, m.FaceAngle.Y)
	end

	local floorHeight, floor = Util.FindFloor(nextPos)
	local ceilHeight = Util.FindCeil(nextPos, floorHeight)

	m.Wall = nil

	if floor == nil then
		if nextPos.Y <= m.FloorHeight then
			m.Position = Util.SetY(m.Position, m.FloorHeight)
			return AirStep.LANDED
		end

		m.Position = Util.SetY(m.Position, nextPos.Y)
		return AirStep.HIT_WALL
	end

	if m.Action:Has(ActionFlags.RIDING_SHELL) and m.FloorHeight <= m.WaterLevel and m.WaterSurfacePseudoFloor then
		floorHeight = m.WaterLevel
		floor = m.WaterSurfacePseudoFloor
	end

	if nextPos.Y <= floorHeight then
		if ceilHeight - floorHeight > 160 then
			m.Floor = floor
			m.FloorHeight = floorHeight
			m.Position = Vector3.new(nextPos.X, m.Position.Y, nextPos.Z)
		end

		--! When ceilHeight - floorHeight <= 160, the step result says that
		-- Mario landed, but his movement is cancelled and his referenced floor
		-- isn't updated (pedro spots)
		m.Position = Util.SetY(m.Position, floorHeight)
		return AirStep.LANDED
	end

	if nextPos.Y + 160 > ceilHeight then
		if m.Velocity.Y > 0 then
			m.Velocity = Util.SetY(m.Velocity, 0)

			--! Uses referenced ceiling instead of ceil (ceiling hang upwarp)
			if
				bit32.band(stepArg, AirStep.CHECK_HANG) > 0
				and m.Ceil ~= nil
				and m:GetCeilType() == SurfaceClass.HANGABLE
			then
				return AirStep.GRABBED_CEILING
			end

			return AirStep.NONE
		end

		--! Potential subframe downwarp->upwarp?
		if nextPos.Y <= m.FloorHeight then
			m.Position = Util.SetY(m.Position, floorHeight)
			return AirStep.LANDED
		end

		m.Position = Util.SetY(m.Position, nextPos.Y)
		return AirStep.HIT_WALL
	end

	--! When the wall is not completely vertical or there is a slight wall
	-- misalignment, you can activate these conditions in unexpected situations
	if bit32.btest(stepArg, AirStep.CHECK_LEDGE_GRAB) and upperWall == nil and lowerWall ~= nil then
		if m:CheckLedgeGrab(lowerWall, intendedPos, nextPos) then
			return AirStep.GRABBED_LEDGE
		end

		m.Floor = floor
		m.Position = nextPos
		m.FloorHeight = floorHeight

		return AirStep.NONE
	end

	m.Floor = floor
	m.Position = nextPos
	m.FloorHeight = floorHeight

	if upperWall or lowerWall then
		local wall = assert(upperWall or lowerWall)
		local wallDYaw = Util.SignedShort(Util.Atan2s(wall.Normal.Z, wall.Normal.X) - m.FaceAngle.Y)
		m.Wall = wall

		if m:GetWallType() == SurfaceClass.BURNING then
			return AirStep.HIT_LAVA_WALL
		end

		if math.abs(wallDYaw) > 0x6000 then
			return AirStep.HIT_WALL
		end
	end

	-- [on continuous step] ur getting nerfed kid
	-- hopefully this doesn't affect elevator BLJs
	-- (Shouldn't be done on ground step)
	if m.ForwardVel < -256 and upperWall and FFlags.CONTINUOUS_INSTEAD_OF_QSTEP then
		m:SetForwardVel(0)
		return GroundStep.HIT_WALL_STOP_QSTEPS
	end

	return AirStep.NONE
end

function Mario.ApplyTwirlGravity(m: Mario)
	local heaviness = 1

	if m.AngleVel.Y > 1024 then
		heaviness = 1024 / m.AngleVel.Y
	end

	local terminalVelocity = -75 * heaviness
	m.Velocity -= Vector3.new(0, 4 * heaviness, 0)

	if m.Velocity.Y < terminalVelocity then
		m.Velocity = Util.SetY(m.Velocity, terminalVelocity)
	end
end

function Mario.ShouldStrengthenGravityForJumpAscent(m: Mario): boolean
	if not m.Flags:Has(MarioFlags.MOVING_UP_IN_AIR) then
		return false
	end

	if m.Action:Has(ActionFlags.INTANGIBLE, ActionFlags.INVULNERABLE) then
		return false
	end

	if not m.Input:Has(InputFlags.A_DOWN) and m.Velocity.Y > 20 then
		return m.Action:Has(ActionFlags.CONTROL_JUMP_HEIGHT)
	end

	return false
end

function Mario.ApplyGravity(m: Mario)
	local action = m.Action()

	if action == Action.TWIRLING and m.Velocity.Y < 0 then
		m:ApplyTwirlGravity()
	elseif action == Action.SHOT_FROM_CANNON then
		m.Velocity -= Vector3.yAxis

		if m.Velocity.Y < -75 then
			m.Velocity = Util.SetY(m.Velocity, -75)
		end
	elseif action == Action.LONG_JUMP or action == Action.SLIDE_KICK or action == Action.BBH_ENTER_SPIN then
		m.Velocity -= (Vector3.yAxis * 2)

		if m.Velocity.Y < -75 then
			m.Velocity = Util.SetY(m.Velocity, -75)
		end
	elseif action == Action.LAVA_BOOST or action == Action.FALL_AFTER_STAR_GRAB then
		m.Velocity -= (Vector3.yAxis * 3.2)

		if m.Velocity.Y < -65 then
			m.Velocity = Util.SetY(m.Velocity, -65)
		end
	elseif m:ShouldStrengthenGravityForJumpAscent() then
		m.Velocity *= Vector3.new(1, 0.25, 1)
	elseif m.Action:Has(ActionFlags.METAL_WATER) then
		m.Velocity -= (Vector3.yAxis * 1.6)

		if m.Velocity.Y < -16 then
			m.Velocity = Util.SetY(m.Velocity, -16)
		end
	elseif m.Flags:Has(MarioFlags.WING_CAP) and m.Velocity.Y < 0 and m.Input:Has(InputFlags.A_DOWN) then
		m.BodyState.WingFlutter = true
		m.Velocity -= (Vector3.yAxis * 2)

		if m.Velocity.Y < -37.5 then
			m.Velocity += (Vector3.yAxis * 4)

			if m.Velocity.Y > -37.5 then
				m.Velocity = Util.SetY(m.Velocity, -37.5)
			end
		end
	elseif action == Action.WALL_SLIDE then
		m.Velocity -= (Vector3.yAxis * 1)
		-- The function for Action.WALL_SLIDE already caps
	else
		m.Velocity -= (Vector3.yAxis * 4)

		if m.Velocity.Y < -75 then
			m.Velocity = Util.SetY(m.Velocity, -75)
		end
	end
end

function Mario.ApplyVerticalWind(m: Mario)
	local maxVelY, offsetY = 0, 0

	if m.Action() ~= Action.GROUND_POUND then
		offsetY = m.Position.Y - -1500.0

		if m:GetFloorType() == SurfaceClass.VERTICAL_WIND and -3000.0 < offsetY and offsetY < 2000.0 then
			if offsetY >= 0.0 then
				maxVelY = 10000.0 / (offsetY + 200.0)
			else
				maxVelY = 50.0
			end

			if m.Velocity.Y < maxVelY then
				m.Velocity += Vector3.yAxis * (maxVelY / 8.0)
				if m.Velocity.Y > maxVelY then
					m.Velocity = Util.SetY(m.Velocity, maxVelY)
				end
			end
		end
	end
end

function Mario.PerformAirStep(m: Mario, maybeStepArg: number?)
	local stepArg = maybeStepArg or 0
	local stepResult = AirStep.NONE
	m.Wall = nil

	local steps = FFlags.CONTINUOUS_INSTEAD_OF_QSTEP and 1 or 4
	for _ = 1, steps do
		local intendedVel = m.Velocity + m.Inertia
		local intendedPos = m.Position + (intendedVel / steps)
		local result = m:PerformAirQuarterStep(intendedPos, stepArg)

		if result ~= AirStep.NONE then
			stepResult = result
		end

		if
			result == AirStep.LANDED
			or result == AirStep.GRABBED_LEDGE
			or result == AirStep.GRABBED_CEILING
			or result == AirStep.HIT_LAVA_WALL
		then
			break
		end
	end

	if m.Velocity.Y >= 0 then
		m.PeakHeight = m.Position.Y
	end

	m.TerrainType = m:GetTerrainType()

	if m.Action() ~= Action.FLYING then
		m:ApplyGravity()
	end
	m:ApplyVerticalWind()

	m.GfxPos = Vector3.zero
	m.GfxAngle = Vector3int16.new(0, m.FaceAngle.Y, 0)

	return stepResult
end

function Mario.PerformHangingStep(m: Mario, nextPos: Vector3)
	local ceil, floor, wall
	local ceilHeight, floorHeight
	local ceilOffset

	nextPos = solveContinuousClip(m, nextPos, 50)
	nextPos, wall = Util.FindWallCollisions(nextPos, 50, 50)

	m.Wall = wall
	floorHeight, floor = Util.FindFloor(nextPos)
	ceilHeight, ceil = Util.FindCeil(nextPos, floorHeight)

	if floor == nil then
		return HangStep.HIT_CEIL_OR_OOB
	end

	if ceil == nil then
		return HangStep.LEFT_CEIL
	end

	if ceilHeight - floorHeight <= 160 then
		return HangStep.HIT_CEIL_OR_OOB
	end

	if m:GetCeilType() ~= SurfaceClass.HANGABLE then
		return HangStep.LEFT_CEIL
	end

	ceilOffset = ceilHeight - (nextPos.Y + 160.0)
	if ceilOffset < -30.0 then
		return HangStep.HIT_CEIL_OR_OOB
	elseif ceilOffset > 30.0 then
		return HangStep.LEFT_CEIL
	end

	nextPos = Util.SetY(nextPos, m.CeilHeight - 160)
	m.Position = nextPos

	m.Floor = floor
	m.FloorHeight = floorHeight
	m.Ceil = ceil
	m.CeilHeight = ceilHeight

	return HangStep.NONE
end

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- UPDATE ROUTINES
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

function Mario.UpdateButtonInputs(m: Mario)
	if m.Controller.ButtonPressed:Has(Buttons.A_BUTTON) then
		m.Input:Add(InputFlags.A_PRESSED)
	end

	if m.Controller.ButtonDown:Has(Buttons.A_BUTTON) then
		m.Input:Add(InputFlags.A_DOWN)
	end

	if m.SquishTimer == 0 then
		if m.Controller.ButtonPressed:Has(Buttons.B_BUTTON) then
			m.Input:Add(InputFlags.B_PRESSED)
		end

		if m.Controller.ButtonDown:Has(Buttons.Z_TRIG) then
			m.Input:Add(InputFlags.Z_DOWN)
		end

		if m.Controller.ButtonPressed:Has(Buttons.Z_TRIG) then
			m.Input:Add(InputFlags.Z_PRESSED)
		end
	end

	if m.Input:Has(InputFlags.A_PRESSED) then
		m.FramesSinceA = 0
	elseif m.FramesSinceA < 255 then
		m.FramesSinceA += 1
	end

	if m.Input:Has(InputFlags.B_PRESSED) then
		m.FramesSinceB = 0
	elseif m.FramesSinceB < 255 then
		m.FramesSinceB += 1
	end
end

function Mario.UpdateJoystickInputs(m: Mario)
	local controller = m.Controller
	local mag = ((controller.StickMag / 64) * (controller.StickMag / 64)) * 64

	if m.SquishTimer == 0 then
		m.IntendedMag = mag / 2
	else
		m.IntendedMag = mag / 8
	end

	if m.IntendedMag > 0 then
		local cameraYaw = 0

		-- For bots
		if not controller.NotRelative then
			local camera = workspace.CurrentCamera
			local lookVector = camera.CFrame.LookVector
			cameraYaw = Util.Atan2s(-lookVector.Z, -lookVector.X)
		end

		m.IntendedYaw = Util.SignedShort(Util.Atan2s(-controller.StickY, controller.StickX) + cameraYaw)
		m.Input:Add(InputFlags.NONZERO_ANALOG)
	else
		m.IntendedYaw = m.FaceAngle.Y
	end
end

function Mario.UpdateGeometryInputs(m: Mario)
	local floorHeight, floor = Util.FindFloor(m.Position)
	local ceilHeight, ceil = Util.FindCeil(m.Position, m.FloorHeight)
	local ceilHeightSquish, ceilByFloorHeight = Util.FindCeil(m.Position, m.FloorHeight - 80.05)

	m.FloorHeight = floorHeight
	m.CeilHeight = ceilHeight
	m.Floor = floor
	m.Ceil = ceil

	if floor then
		local gasLevel = Util.FindTaggedPlane(m.Position, "PoisonGasCloud")
		local waterLevel, waterPseudoFloor = Util.GetWaterLevel(m.Position)
		m.GasLevel = gasLevel
		m.WaterLevel = waterLevel
		m.WaterSurfacePseudoFloor = waterPseudoFloor

		m.FloorAngle = Util.Atan2s(floor.Normal.Z, floor.Normal.X)
		m.TerrainType = m:GetTerrainType()

		if m:FloorIsSlippery() then
			m.Input:Add(InputFlags.ABOVE_SLIDE)
		end

		-- I guess we could just shove in a use of a tag
		-- or if its Unanchored?
		if ceilByFloorHeight then
			local ceilSquishPart = ceilByFloorHeight.Instance :: BasePart
			local squishable = ((not ceilSquishPart.Anchored) or (ceilSquishPart:HasTag("SquishMario")))

			if squishable then
				local ceilToFloorDist = ceilHeightSquish - floor.Position.Y

				if 0 < ceilToFloorDist and ceilToFloorDist < 150 then
					m.Input:Add(InputFlags.SQUISHED)
				end

				if not ceil then
					ceil = ceilByFloorHeight
					ceilHeight = ceilHeightSquish
					m.Ceil = ceilByFloorHeight
					m.CeilHeight = ceilHeightSquish
				end
			else
				ceilHeightSquish = math.huge
				ceilByFloorHeight = nil
			end
			m.CeilHeightSquish = ceilHeightSquish
		end

		if m.Position.Y > m.FloorHeight + 100 then
			m.Input:Add(InputFlags.OFF_FLOOR)
		end

		if m.Position.Y < m.WaterLevel - 10 then
			m.Input:Add(InputFlags.IN_WATER)
		end

		if m.Position.Y < m.GasLevel - 100 then
			m.Input:Add(InputFlags.IN_POISON_GAS)
		end
	else
		-- Mario gets "killed" here when no floor has been found
		-- LevelTriggerWarp(m, WarpOp.DEATH);
		-- Let's just set Mario's health for now.
		m.Health = 0xFF
	end
end

function Mario.UpdateInputs(m: Mario)
	m.ParticleFlags:Clear()
	m.Flags:Band(0xFFFFFF)
	m.Input:Clear()

	m:UpdateButtonInputs()
	m:UpdateJoystickInputs()
	m:UpdateGeometryInputs()

	-- This code is an example on how to let FIRST_PERSON happen.
	-- Do something else if you want it to, this is not ideal...
	--[[
	local camera = workspace.CurrentCamera
	if camera and (camera.Focus.Position - camera.CFrame.Position).Magnitude < 1 then
		if m.Action:Has(ActionFlags.ALLOW_FIRST_PERSON) then
			m.Input:Add(InputFlags.FIRST_PERSON)
		end
	end
	]]

	if not m.Input:Has(InputFlags.NONZERO_ANALOG, InputFlags.A_PRESSED) then
		m.Input:Add(InputFlags.NO_MOVEMENT)
	end

	if m.WallKickTimer > 0 then
		m.WallKickTimer -= 1
	end

	if m.DoubleJumpTimer > 0 then
		m.DoubleJumpTimer -= 1
	end
end

function Mario.ResetBodyState(m: Mario)
	local bodyState = m.BodyState
	bodyState.CapState:Set(MarioCap.DEFAULT_CAP_OFF)
	bodyState.EyeState = MarioEyes.BLINK
	bodyState.HandState:Set(MarioHands.FISTS)
	bodyState.ModelState:Clear()
	bodyState.WingFlutter = false

	m:SwitchHandGrabPos("RENDER")
	m.Flags:Remove(MarioFlags.METAL_SHOCK)
end

-- what?
function Mario.SwitchHandGrabPos(m: Mario, callContext: string)
	local bodyState = m.BodyState
	local translation = Vector3.zero

	if callContext == "RENDER" then
		if (m :: any).HeldObj ~= nil then
			local grabPos = bodyState.GrabPos

			if grabPos == 0x01 then
				if m.Action:Has(ActionFlags.THROWING) then
					translation = Vector3.new(50, 0, 0)
				else
					translation = Vector3.new(50, 0, 110)
				end
			end
		end
	elseif callContext == "HELD_OBJ" then
		-- ! The HOLP is set here, which is why it only updates when the held object is drawn.
		-- This is why it won't update during a pause buffered hitstun or when the camera is very far
		-- away.
	end

	bodyState.HeldObjLastPos = m.Position + (Vector3.new(Util.Sins(m.FaceAngle.Y), 0, Util.Coss(m.FaceAngle.Y)) * 50)

	return nil
end

function Mario.SinkInQuicksand(m: Mario)
	m.GfxPos = Util.SetY(m.GfxPos, m.GfxPos.Y - m.QuicksandDepth)
end

--[[
 * Is a binary representation of the frames to flicker Mario's cap when the timer
 * is running out.
 *
 * Equals [1000]^5 . [100]^8 . [10]^9 . [1] in binary, which is
 * 100010001000100010001001001001001001001001001010101010101010101.
]]

-- This gets truncated...
-- local capFlickerFrames = 0x4444449249255555

function Mario.UpdateCaps(m: Mario): Flags
	local flags = m.Flags
	local action = m.Action()

	if m.CapTimer > 0 then
		if
			(m.CapTimer <= 60)
			or (
				action ~= Action.READING_AUTOMATIC_DIALOG
				and action ~= Action.READING_NPC_DIALOG
				and action ~= Action.READING_SIGN
				and action ~= Action.IN_CANNON
			)
		then
			m.CapTimer -= 1
		end

		if m.CapTimer == 0 then
			m.Flags:Remove(MarioFlags.SPECIAL_CAPS)

			if not m.Flags:Has(MarioFlags.CAPS) then
				m.Flags:Remove(MarioFlags.CAP_ON_HEAD)
			end
		end

		-- This code flickers the cap through a long binary string, increasing in how
		-- common it flickers near the end.
		--[[if m.CapTimer < 64 and bit32.band(bit32.lshift(1, m.CapTimer), capFlickerFrames) ~= 0 then
			flags:Remove(MarioFlags.SPECIAL_CAPS)
			if not flags:Has(MarioFlags.CAPS) then
				flags:Remove(MarioFlags.CAP_ON_HEAD)
			end
		end]]
	end

	return flags
end

function Mario.UpdateModel(m: Mario)
	local modelState = m.BodyState.ModelState
	local bodyState = m.BodyState
	local flags = m:UpdateCaps()

	if flags:Has(MarioFlags.VANISH_CAP) then
		modelState:Add(ModelFlags.NOISE_ALPHA)
	end

	if flags:Has(MarioFlags.METAL_CAP, MarioFlags.METAL_SHOCK) then
		modelState:Add(ModelFlags.METAL)
	end

	if m.InvincTimer >= 3 and bit32.band(Util.GlobalTimer, 1) > 0 then
		modelState:Add(ModelFlags.INVISIBLE)
	end

	if flags:Has(MarioFlags.CAP_IN_HAND) then
		if flags:Has(MarioFlags.WING_CAP) then
			bodyState.HandState:Set(MarioHands.HOLDING_WING_CAP)
		else
			bodyState.HandState:Set(MarioHands.HOLDING_CAP)
		end
	end

	if flags:Has(MarioFlags.CAP_ON_HEAD) then
		if flags:Has(MarioFlags.WING_CAP) then
			bodyState.CapState:Set(MarioCap.WING_CAP_ON)
		else
			bodyState.CapState:Set(MarioCap.DEFAULT_CAP_ON)
		end
	end

	if m.Action:Has(ActionFlags.SHORT_HITBOX) then
		m.HitboxHeight = 100
	else
		m.HitboxHeight = 160
	end
end

--[[
 * These are the scaling values for the x and z axis for Mario
 * when he is close to unsquishing.
]]
-- stylua: ignore
local squishScaleOverTime = {
	0x46, 0x32, 0x32, 0x3C,
	0x46, 0x50, 0x50, 0x3C,
	0x28, 0x14, 0x14, 0x1E,
	0x32, 0x3C, 0x3C, 0x28
}

--[[
 * Applies the squish to Mario's model via scaling.
 * Must be done manually
]]
function Mario.SquishModel(m: Mario)
	if m.SquishTimer ~= 0xFF then
		-- If no longer squished, scale back to default.
		if m.SquishTimer == 0 then
			m.GfxScale = Vector3.one
		-- If timer is less than 16, rubber-band Mario's size scale up and down.
		elseif m.SquishTimer <= 16 then
			m.SquishTimer -= 1

			m.GfxScale = Vector3.new(
				((squishScaleOverTime[(15 - m.SquishTimer) + 1] * 0.4) / 100.0) + 1.0,
				1.0 - ((squishScaleOverTime[(15 - m.SquishTimer) + 1] * 0.6) / 100.0),
				m.GfxScale.Z
			)
		else
			m.SquishTimer -= 1
			m.GfxScale = Vector3.new(1.4, 0.4, 1.4)
		end
	end
end

function Mario.CheckKickOrPunchWall(m: Mario)
	if m.Flags:Has(MarioFlags.PUNCHING, MarioFlags.KICKING, MarioFlags.TRIPPING) then
		-- stylua: ignore
		local range = Vector3.new(
			Util.Sins(m.FaceAngle.Y),
			0,
			Util.Coss(m.FaceAngle.Y)
		)

		local detector = m.Position + (range * 49.5)
		local _, wall = Util.FindWallCollisions(detector, 80, 5)

		if wall then
			if m.Action() ~= Action.MOVE_PUNCHING or m.ForwardVel >= 0 then
				if m.Action() == Action.PUNCHING then
					m.Action:Set(Action.MOVE_PUNCHING)
				end

				m:SetForwardVel(-48)
				m:PlaySound(Sounds.ACTION_HIT)
				m.ParticleFlags:Add(ParticleFlags.TRIANGLE)
			elseif m.Action:Has(ActionFlags.AIR) then
				m:SetForwardVel(-16)
				m:PlaySound(Sounds.ACTION_HIT)
				m.ParticleFlags:Add(ParticleFlags.TRIANGLE)
			end
		end
	end
end

function Mario.ProcessInteractions(m: Mario)
	if m.InvincTimer > 0 then
		m.InvincTimer -= 1
	end

	--! If the kick/punch flags are set and an object collision changes Mario's
	--  action, he will get the kick/punch wall speed anyway.
	m:CheckKickOrPunchWall()
	m.Flags:Remove(MarioFlags.PUNCHING, MarioFlags.KICKING, MarioFlags.TRIPPING)
end

-- You have to reset/respawn Mario manually on your own.
local function checkDeathBarrier(m: Mario)
	if m.Position.Y < m.FloorHeight + 2048.0 then
		if --[[LevelTriggerWarp(m, WarpOp.WARP_FLOOR) == 20 and]]
			not m.Flags:Has(MarioFlags.FALLING_FAR)
		then
			m:PlaySoundIfNoFlag(Sounds.MARIO_WAAAOOOW, MarioFlags.FALLING_FAR)

			-- Let's just set Mario's health for now
			m.Health = 0xFF
		end
	end
end

local function checkLavaBoost(m: Mario)
	if not m.Action:Has(ActionFlags.RIDING_SHELL) and m.Position.Y < m.FloorHeight + 10 then
		if not m.Flags:Has(MarioFlags.METAL_CAP) then
			m.HurtCounter += m.Flags:Has(MarioFlags.CAP_ON_HEAD) and 12 or 18
		end

		m:DropAndSetAction(Action.LAVA_BOOST)
	end
end

function Mario.HandleSpecialFloors(m: Mario)
	if bit32.band(m.Action(), ActionGroups.GROUP_MASK) == ActionGroups.CUTSCENE then
		return
	end

	if m.Floor then
		local floorType = m:GetFloorType()

		if floorType == SurfaceClass.DEATH_PLANE or floorType == SurfaceClass.VERTICAL_WIND then
			checkDeathBarrier(m)
		end

		if not m.Action:Has(ActionFlags.AIR, ActionFlags.SWIMMING) then
			if floorType == SurfaceClass.BURNING then
				checkLavaBoost(m)
			end
		end
	end
end

function Mario.SetWaterPlungeAction(m: Mario)
	m.ForwardVel /= 4
	m.Velocity *= Vector3.new(1, 0.5, 1)

	-- This behavior sucks, feel free to enable if you want.
	-- m.Position = Util.SetY(m.Position, m.WaterLevel - 100)

	m.FaceAngle *= Vector3int16.new(1, 1, 0)
	m.AngleVel *= 0

	if not m.Action:Has(ActionFlags.DIVING) then
		m.FaceAngle *= Vector3int16.new(0, 1, 1)
	end

	if m.Health < 0x100 and not m.Action:Has(ActionFlags.INTANGIBLE, ActionFlags.INVULNERABLE) then
		return m:SetAction(Action.DROWNING)
	end

	return m:SetAction(Action.WATER_PLUNGE)
end

function Mario.PlayFarFallSound(m: Mario)
	if m.Flags:Has(MarioFlags.FALLING_FAR) then
		return
	end

	local action = m.Action

	if action() == Action.TWIRLING then
		return
	elseif action() == Action.FLYING then
		return
	elseif action() == Action.WALL_SLIDE then
		return
	end

	if action:Has(ActionFlags.INVULNERABLE) then
		return
	end

	if m.PeakHeight - m.Position.Y > 1150 then
		m:PlaySound(Sounds.MARIO_WAAAOOOW)
		m.Flags:Add(MarioFlags.FALLING_FAR)
	end
end

--[[
 * Both increments and decrements Mario's HP.
]]
function Mario.UpdateHealth(m: Mario)
	local terrainIsSnow = false

	if m.Health > 0x100 then
		-- When already healing or hurting Mario, Mario's HP is not changed any more here.
		if not bit32.btest(m.HealCounter, m.HurtCounter) then
			if m.Input:Has(InputFlags.IN_POISON_GAS) and not m.Action:Has(ActionFlags.INTANGIBLE) then
				if not m.Flags:Has(MarioFlags.METAL_CAP) then
					m.Health -= 4
				end
			else
				if m.Action:Has(ActionFlags.SWIMMING) and not m.Action:Has(ActionFlags.INTANGIBLE) then
					-- When Mario is near the water surface, recover health (unless in snow),
					-- when in snow terrains lose 3 health.
					-- If using the debug level select, do not lose any HP to water.
					if (m.Position.Y >= (m.WaterLevel - 140)) and not terrainIsSnow then
						m.Health += 0x1A
					else
						m.Health -= (terrainIsSnow and 3 or 1)
					end
				end
			end
		end

		if m.HealCounter > 0 then
			m.Health += 0x40
			m.HealCounter -= 1
		end

		if m.HurtCounter > 0 then
			m.Health -= 0x40
			m.HurtCounter -= 1
		end

		if (m.Health > 0x880) or FFlags.DEGREELESSNESS_MODE then
			m.Health = 0x880
		end

		if m.Health <= 0x100 then
			m.Health = 0xFF
		end
	end
end

function Mario.UpdateQuicksand(m: Mario, SinkingSpeed)
	if m.Action:Has(ActionFlags.RIDING_SHELL) then
		m.QuicksandDepth = 0
	else
		if m.QuicksandDepth < 1.1 then
			m.QuicksandDepth = 1.1
		end

		local FloorType = m:GetFloorType()
		if FloorType == SurfaceClass.SHALLOW_QUICKSAND then
			m.QuicksandDepth += SinkingSpeed
			if m.QuicksandDepth >= 10 then
				m.QuicksandDepth = 10
			end
		elseif FloorType == SurfaceClass.SHALLOW_MOVING_QUICKSAND then
			m.QuicksandDepth += SinkingSpeed
			if m.QuicksandDepth >= 25 then
				m.QuicksandDepth = 25
			end
		elseif FloorType == SurfaceClass.MOVING_QUICKSAND or FloorType == SurfaceClass.QUICKSAND then
			m.QuicksandDepth += SinkingSpeed
			if m.QuicksandDepth >= 60 then
				m.QuicksandDepth = 60
			end
		elseif FloorType == SurfaceClass.DEEP_MOVING_QUICKSAND or FloorType == SurfaceClass.DEEP_QUICKSAND then
			m.QuicksandDepth += SinkingSpeed
			if m.QuicksandDepth >= 160 then
				return m:DropAndSetAction(Action.QUICKSAND_DEATH, 0)
			end
		elseif FloorType == SurfaceClass.INSTANT_QUICKSAND or FloorType == SurfaceClass.INSTANT_MOVING_QUICKSAND then
			return m:DropAndSetAction(Action.QUICKSAND_DEATH, 0)
		else
			m.QuicksandDepth = 0
		end
	end

	return false
end

--[[
	* Copy position, velocity, and angle variables from MarioState to the Mario
	* object.
]]
function Mario.CopyMarioStateToObject(m: Mario, o: Types.ObjectState)
	o.Velocity = m.Velocity
	o.Position = m.Position

	o.MoveAnglePitch = m.GfxAngle.X
	o.MoveAngleYaw = m.FaceAngle.Y
	o.MoveAngleRoll = m.GfxAngle.Z

	o.FaceAnglePitch = m.GfxAngle.X
	o.FaceAngleYaw = m.FaceAngle.Y
	o.FaceAngleRoll = m.GfxAngle.Z

	o.AngleVelPitch = m.AngleVel.X
	o.AngleVelYaw = m.AngleVel.Y
	o.AngleVelRoll = m.AngleVel.Z

	o.HitboxHeight = m.HitboxHeight
	o.HitboxRadius = m.HitboxRadius
end

function Mario.ExecuteAction(m: Mario): number
	if m.Action() == 0 then
		return 0
	end

	m.AnimFrame += 1
	m.AnimFrame %= (m.AnimFrameCount + 1)

	if m.AnimAccel > 0 then
		m.AnimAccelAssist += m.AnimAccel
		m.AnimAccelAssist %= bit32.lshift(m.AnimFrameCount + 1, 0x10)
	end

	m.GfxAngle *= 0
	m.AnimDirty = true
	m.ThrowMatrix = nil
	m.AnimSkipInterp = math.max(0, m.AnimSkipInterp - 1)

	m:ResetBodyState()
	m:UpdateInputs()

	m:HandleSpecialFloors()
	m:ProcessInteractions()

	if m.Floor == nil then
		m.GfxAngle = Vector3int16.new(0, m.FaceAngle.Y, 0)
		return 0
	end

	while m.Action() > 0 do
		local id = m.Action()
		local action = actions[id]

		if action then
			local group = bit32.band(id, ActionGroups.GROUP_MASK)
			local cancel: boolean?

			if group ~= ActionGroups.SUBMERGED and m.Position.Y < m.WaterLevel - 100 then
				cancel = m:SetWaterPlungeAction()
			else
				if group == ActionGroups.AIRBORNE then
					m:PlayFarFallSound()

					local function commonAirborneCancels(): boolean?
						if m.Input:Has(InputFlags.SQUISHED) then
							return m:DropAndSetAction(Action.SQUISHED, 0)
						end

						if
							m:GetFloorType() == SurfaceClass.VERTICAL_WIND
							and m.Action:Has(ActionFlags.ALLOW_VERTICAL_WIND_ACTION)
						then
							return m:DropAndSetAction(Action.VERTICAL_WIND, 0)
						end

						m.QuicksandDepth = 0.0
						return nil
					end

					cancel = commonAirborneCancels()
					if not cancel then
						m:PlayFarFallSound()
					end
				elseif group == ActionGroups.SUBMERGED then
					if m.Position.Y > m.WaterLevel - 80 then
						if m.WaterLevel - 80 > m.FloorHeight then
							m.Position = Util.SetY(m.Position, m.WaterLevel - 80)
						else
							--! If you press B to throw the shell, there is a ~5 frame window
							--  where your held object is the shell, but you are not in the
							--  water shell swimming action. This allows you to hold the water
							--  shell on land (used for cloning in DDD).
							if m.Action() == Action.WATER_SHELL_SWIMMING and (m :: any).HeldObj ~= nil then
								(m :: any).HeldObj.InteractStatus:Set(InteractionStatus.STOP_RIDING);
								(m :: any).HeldObj = nil
							end

							m.AngleVel *= 0
							if (m :: any).HeldObj == nil then
								cancel = m:SetAction(Action.WALKING)
							else
								cancel = m:SetAction(Action.HOLD_WALKING)
							end
						end
					end

					if m.Health < 0x100 and not m.Action:Has(ActionFlags.INTANGIBLE, ActionFlags.INVULNERABLE) then
						cancel = m:SetAction(Action.DROWNING, 0)
					end

					if not cancel then
						m.QuicksandDepth = 0
						m.BodyState.HeadAngle *= Vector3int16.new(1, 0, 0)
					end
				elseif group == ActionGroups.MOVING then
					local function commonMovingCancels(): boolean?
						if m.Input:Has(InputFlags.SQUISHED) then
							return m:DropAndSetAction(Action.SQUISHED, 0)
						end

						if not m.Action:Has(ActionFlags.INVULNERABLE) then
							if m.Health < 0x100 then
								return m:SetAction(Action.STANDING_DEATH, 0)
							end
						end

						if m:UpdateQuicksand(0.5) then
							return true
						end

						return nil
					end

					cancel = commonMovingCancels()
				elseif group == ActionGroups.STATIONARY then
					local function commonStationaryCancels(): boolean?
						if m.Input:Has(InputFlags.SQUISHED) then
							return m:DropAndSetAction(Action.SQUISHED, 0)
						end

						if m.Action() ~= Action.UNKNOWN_0002020E then
							if m.Health < 0x100 then
								return m:DropAndSetAction(Action.STANDING_DEATH, 0)
							end
						end

						if m:UpdateQuicksand(0.5) then
							return true
						end

						return nil
					end

					cancel = commonStationaryCancels()
				elseif group == ActionGroups.CUTSCENE then
					local function checkForInstantQuicksand(): any
						local floorType = m:GetFloorType()
						if
							(
								floorType == SurfaceClass.INSTANT_QUICKSAND
								or floorType == SurfaceClass.INSTANT_MOVING_QUICKSAND
							)
							and m.Action:Has(ActionFlags.INVULNERABLE)
							and m.Action() ~= Action.QUICKSAND_DEATH
						then
							return m:DropAndSetAction(Action.QUICKSAND_DEATH, 0)
						end

						return false
					end

					if checkForInstantQuicksand() then
						cancel = true
					end
				elseif group == ActionGroups.OBJECT then
					local function checkCommonObjectCancels(): any
						if m.Input:Has(InputFlags.SQUISHED) then
							return m:DropAndSetAction(Action.SQUISHED, 0)
						end

						if m.Health < 0x100 then
							return m:DropAndSetAction(Action.STANDING_DEATH, 0)
						end

						if m:UpdateQuicksand(0.5) then
							return true
						end

						return nil
					end

					cancel = checkCommonObjectCancels()
				end

				if cancel == nil then
					cancel = action(m)
				end
			end

			if not cancel then
				if m.Input:Has(InputFlags.IN_WATER) then
					if group == ActionGroups.MOVING then
						m.ParticleFlags:Add(ParticleFlags.WAVE_TRAIL)
						m.ParticleFlags:Remove(ParticleFlags.DUST)
					elseif group == ActionGroups.STATIONARY then
						m.ParticleFlags:Add(ParticleFlags.IDLE_WATER_WAVE)
					end
				end

				break
			end
		else
			local name = Enums.GetName(Action, id)

			if name then
				warn("Unhandled Action:", name)
			else
				warn("UNKNOWN ACTION:", id)
			end

			m.Action:Set(Action.IDLE)
			break
		end
	end

	m:SinkInQuicksand()
	m:SquishModel()
	m:UpdateHealth()
	m:UpdateModel()

	local marioObj = (m :: any).MarioObj
	if marioObj then
		marioObj.InteractStatus:Clear()
	end

	return m.ParticleFlags()
end

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- INITIALIZATION
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

function Mario.new(): Mario
	local bodyState: BodyState = {
		Action = 0,
		CapState = Flags.new(),
		EyeState = 0,
		HandState = Flags.new(),
		WingFlutter = false,
		ModelState = Flags.new(),
		GrabPos = 0,
		PunchType = 0,
		PunchTimer = 0,
		HeadAngle = Vector3int16.new(),
		TorsoAngle = Vector3int16.new(),
		HeldObjLastPos = Vector3.zero,
	}

	local controller: Controller = {
		RawStickX = 0,
		RawStickY = 0,

		StickX = 0,
		StickY = 0,
		StickMag = 0,

		ButtonDown = Flags.new(),
		ButtonPressed = Flags.new(),
	}

	local state: MarioState = {
		Input = Flags.new(),

		Flags = Flags.new(MarioFlags.NORMAL_CAP, MarioFlags.CAP_ON_HEAD),
		Action = Flags.new(Action.SPAWN_SPIN_AIRBORNE),

		PrevAction = Flags.new(),
		ParticleFlags = Flags.new(),
		HitboxHeight = 100,
		HitboxRadius = 37,
		TerrainType = 0,

		ActionState = 0,
		ActionTimer = 0,
		ActionArg = 0,

		IntendedMag = 0,
		IntendedYaw = 0,
		InvincTimer = 0,

		FramesSinceA = 255,
		FramesSinceB = 255,

		WallKickTimer = 0,
		DoubleJumpTimer = 0,

		FaceAngle = Vector3int16.new(),
		AngleVel = Vector3int16.new(),
		ThrowMatrix = CFrame.identity,

		GfxAngle = Vector3int16.new(),
		GfxScale = Vector3.one,
		GfxPos = Vector3.zero,

		SlideYaw = 0,
		TwirlYaw = 0,

		Position = Vector3.yAxis * 500,
		Velocity = Vector3.zero,

		Inertia = Vector3.zero,
		ForwardVel = 0,
		SlideVelX = 0,
		SlideVelZ = 0,

		CeilHeight = 0,
		FloorHeight = 0,
		FloorAngle = 0,
		WaterLevel = -11000,
		GasLevel = -11000,

		Health = 0x880,
		HurtCounter = 0,
		HealCounter = 0,
		SquishTimer = 0,

		NumCoins = 0,

		CapTimer = 0,
		BurnTimer = 0,
		PeakHeight = 0,
		SteepJumpYaw = 0,
		WalkingPitch = 0,
		QuicksandDepth = 0,
		LongJumpIsSlow = false,

		BodyState = bodyState,
		Controller = controller,

		AnimAccel = 0,
		AnimFrame = -1,
		AnimSetFrame = -1,
		AnimDirty = false,
		AnimReset = false,
		AnimFrameCount = 0,
		AnimAccelAssist = 0,
		AnimSkipInterp = 0,

		-- Hacky solutions...
		PoleObj = nil,
		PoleYawVel = 0,
		PolePos = 0,
	}

	return setmetatable(state, Mario)
end

return Mario
