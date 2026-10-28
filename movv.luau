-- Connected Discord-GitHub
--!strict
-- MovementKit.client.luau
-- Momentum movement kit for a DeathRun: Leap, Blast, Wall Run and Grapple in one LocalScript
--[[
	Functionality summarized:
	A drop in LocalScript for StarterPlayerScripts that gives the stock R6/R15 character four
	movement abilities built to chain into each other. The movement is simulated here on the
	client on purpose. Roblox gives every client network ownership of its own character, so the
	client is the machine running that character's physics, and a force the server applied would
	be fought by the client's simulation and show up as rubber banding.
	Leap (Q) - launches you along the camera's horizontal direction with a fixed amount of lift
	Blast (E) - recoil along the camera axis, aim down to go up or aim at a wall to push off it
	Wall run (automatic) - jump beside a part in the Walls folder while steering along it, the
	wall turns green and fades back to its colour over the time you have left on it
	Wall jump (jump during a wall run) - kicks you off the wall and keeps your run speed
	Grapple (hold F) - aim near a part tagged "GrapplePoint" and a winched rope reels you in, you
	can swing on it, letting go keeps your momentum and arriving at the point pops you over it.
	Every part in the Points folder bobs up and down, the rope follows the point as it moves
	How it functions and how the parts fit together:
	MovementController - a metatable class that owns two kinds of state and keeps them apart.
		Per player: cooldown timestamps and the grapple highlight. These survive respawns.
		Per character: a Rig table built in bind() holding the physics actuators and the movement
		state. It is thrown away with the body, so a new character never inherits a half finished
		wall run or a rope from the old one.
	State machine - a Rig is always Idle, WallRun or Grapple. setState() is the only way to change
		it, and it switches every actuator off before the next state switches on only the ones it
		owns, so two mechanics can never push the character at the same time.
	Actuators - built once per character and toggled with Enabled instead of created per cast.
		driver: one LinearVelocity shared by launches (for 0.1s) and wall runs (the whole run)
		aligner: an AlignOrientation that turns the body along the wall while AutoRotate is off
		rope: a RopeConstraint whose winch reels you toward the grapple point
	Input - ContextActionService binds each ability to its key, its gamepad button and an on screen
		touch button in one call. The wall jump reads the jump button the Humanoid already tracks.
	Two loops - step() runs on PreSimulation, so a velocity it sets is used by this frame's
		physics. render() runs straight after the default camera script, so the wall tilt and the
		speed FOV go on top of this frame's camera. It also picks the grapple target.
	Every velocity the kit writes goes through clampVelocity, the cap that keeps a character
	from covering more ground between two physics steps than a wall is thick and tunneling.
--]]
-- How to play: Q leap // E blast (aim down to go up) // hold F while a point is highlighted
-- Jump beside a wall and hold a direction along it to wall run, jump again to wall jump off it
-- Services
-- Fetched once here, GetService is a lookup by name and the two loops below run every frame
local CollectionService = game:GetService("CollectionService") -- finds grapple points by tag
local ContextActionService = game:GetService("ContextActionService") -- ability input
local Players = game:GetService("Players") -- LocalPlayer and its character events
local RunService = game:GetService("RunService") -- PreSimulation and BindToRenderStep
local UserInputService = game:GetService("UserInputService") -- focus events and key names
local TweenService = game:GetService("TweenService") -- wall fade and point bobbing
local Workspace = game:GetService("Workspace") -- Raycast, CurrentCamera and Terrain
-- Level folders, WaitForChild because they can replicate after this script starts
local wallsFolder = Workspace:WaitForChild("Walls") -- every part inside is a runnable wall
local pointsFolder = Workspace:WaitForChild("Points") -- every part inside bobs up and down
local usesMouse = UserInputService.MouseEnabled -- PC, the dot replaces the mouse cursor
-- Types
-- String literal unions instead of plain strings, so a typo like "Grappel" is a type error when
-- the script is analysed instead of a nil lookup that silently does nothing at runtime
type Launch = "Leap" | "Blast" -- the abilities that are a single change of velocity
type Ability = Launch | "Grapple" -- everything that has a key and a cooldown
type MoveState = "Idle" | "WallRun" | "Grapple" -- what is steering the character right now
type AbilityConfig = { -- one row of ABILITIES below
	name: Ability, -- also the action name and the key into every per ability table
	cooldown: number, -- seconds
	key: Enum.KeyCode | Enum.UserInputType, -- keyboard binding
	button: Enum.KeyCode, -- gamepad binding
}
type PointGui = { -- the BillboardGui over one grapple point, and the pieces that change
	gui: BillboardGui,
	grapple: TextLabel, -- "Grapple!", shown while the point is highlighted
	count: TextLabel, -- "x1", "x2"... on the point you last held
	bar: Frame, -- the combo timer's background
	fill: Frame, -- the part of the bar that drains
}
type Rig = { -- everything that belongs to one character and dies with it
	humanoid: Humanoid, -- movement state, floor detection, input direction
	root: BasePart, -- HumanoidRootPart, the part every constraint acts on
	attachment: Attachment, -- sits on the root, Attachment0 of all three constraints
	anchor: Attachment, -- the far end of the rope, kept in Terrain so it can sit anywhere
	driver: LinearVelocity, -- launches and wall runs
	aligner: AlignOrientation, -- body facing during a wall run
	rope: RopeConstraint, -- the grapple's physics, pulls on the root and is never drawn
	line: Beam, -- the rope you see, drawn from a hand to the point
	hands: { Attachment }, -- the hand grips the line can start from, one is picked per grapple
	rayParams: RaycastParams, -- skips this character, water and anything with CanCollide off
	died: RBXScriptConnection, -- disconnected in unbind() so an old body cannot fire it later
	jumpHeld: boolean, -- Humanoid.Jump last step, a false to true change is one press
	state: MoveState, -- which state owns the actuators right now
	stateStartedAt: number, -- os.clock() when the current state began
	impulseEndsAt: number, -- os.clock() when a launch hands the body back to the Humanoid
	autoRotate: boolean, -- the Humanoid's AutoRotate from before a wall run switched it off
	runSpeed: number, -- speed along the wall, fixed for the whole run
	wallNormal: Vector3, -- flat, points out of the wall toward the character
	wallTangent: Vector3, -- flat, the direction of the run
	lastWall: BasePart?, -- the wall just left, it cannot be caught again until wallReattachAt
	wallReattachAt: number, -- os.clock() when lastWall can be caught again
	grappleTarget: BasePart?, -- the point the rope is on
	swings: { AnimationTrack }, -- loaded once per character, one plays per grapple
}
-- Abilities
-- The single source of truth for bindings and cooldowns. Input and cooldowns are both built
-- from this one table at startup, so a rebind or a retune can never leave them disagreeing
local ABILITIES: { AbilityConfig } = {
	{ name = "Leap", cooldown = 1, key = Enum.KeyCode.Q, button = Enum.KeyCode.ButtonX },
	{ name = "Blast", cooldown = 1, key = Enum.KeyCode.E, button = Enum.KeyCode.ButtonY },
	{ name = "Grapple", cooldown = 0.025, key = Enum.UserInputType.MouseButton2, button = Enum.KeyCode.ButtonR2 },
}
-- Leap config
local LEAP_SPEED = 160 -- studs/s of horizontal launch from a standstill
local LEAP_CARRY_BONUS = 55 -- studs/s added on top of the speed you arrive with
local LEAP_UP_SPEED = 75 -- studs/s of lift, a constant so the arc keeps its shape every cast
-- Blast config
local BLAST_SPEED = 135 -- studs/s at full strength
local BLAST_MIN_PITCH = 0.25 -- the aim's LookVector.Y has to be at least this far from level
local BLAST_MAX_PITCH = 0.95 -- full strength from this pitch up
local BLAST_MIN_STRENGTH = 0.45 -- the weakest legal blast, as a fraction of BLAST_SPEED
-- Wall run config
local WALL_CHECK_DISTANCE = 3.5 -- studs from the root to look sideways for a wall
local WALL_MAX_NORMAL_Y = 0.2 -- a surface tilted more than this is a floor or a ceiling
local WALL_ENTRY_SPEED = 12 -- horizontal studs/s to catch a wall, a running jump is enough
local WALL_INPUT_DOT = 0.3 -- how far the input has to point along the wall to start a run
local WALL_RUN_MIN_SPEED = 40 -- studs/s, even a slow entry runs at least this fast
local WALL_RUN_LIFT = 16 -- studs/s upward when the run starts
local WALL_RUN_GRAVITY = 20 -- studs/s² bending the run back down
local WALL_RUN_MAX_TIME = 1.6 -- seconds, 2 * LIFT / GRAVITY so the arc ends where it began
-- Linear over the whole run time, so how green the wall still is shows how long you have left
local WALL_FADE = TweenInfo.new(WALL_RUN_MAX_TIME, Enum.EasingStyle.Linear)
local WALL_READY_COLOR = Color3.fromRGB(70, 220, 110) -- green, you are on the wall and can jump
local WALL_HOLD_DISTANCE = 2.2 -- studs from the root to the wall, the arms stay just clear
local WALL_HOLD_GAIN = 8 -- per second, how hard a wrong distance gets corrected
local WALL_JUMP_PUSH = 45 -- studs/s away from the wall
local WALL_JUMP_UP = 55 -- studs/s upward
local WALL_REATTACH_TIME = 0.4 -- seconds before the wall you just left can be caught again
local WALL_TILT = math.rad(12) -- camera roll when the wall is directly to one side
-- Grapple config
local GRAPPLE_TAG = "GrapplePoint" -- CollectionService tag, used by three calls below
local GRAPPLE_RANGE = 120 -- studs from the root
local CROSSHAIR_ASSIST = math.rad(1.5) -- how far past a point's edge still counts as on it
local GRAPPLE_REEL_SPEED = 60 -- studs/s the winch shortens the rope by
local GRAPPLE_ARRIVE_DISTANCE = 6 -- studs past the point's own size where the rope lets go
local GRAPPLE_POP_SPEED = 50 -- minimum upward studs/s when you arrive
local GRAPPLE_MAX_TIME = 3 -- seconds, the safety net for a release that never arrives
local ROPE_THICKNESS = 0.15 -- studs
local GRAPPLE_COLOR = Color3.fromRGB(255, 60, 60) -- red, shared by the rope and the highlight
-- Roblox's own R15 tool swings. Animations only load in games that have permission to them, and
-- Roblox's defaults are the ones every game can use. Swap in your own uploads for a real left
-- and right swing, any number of ids works since one is picked at random
local SWING_ANIMATION_IDS = { "rbxassetid://0", "rbxassetid://0" } -- placeholders, left and right
local POINT_BOB_HEIGHT = 1.5 -- studs each point rises above where it was placed
-- Sine eases in and out so the turn at the top and bottom is smooth. -1 repeats forever and
-- true plays it in reverse on the way back, so one tween covers the whole up and down loop
local POINT_BOB = TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
-- Shared config
local MAX_HORIZONTAL_SPEED = 320 -- studs/s, faster than this a body can skip a thin wall
local MAX_VERTICAL_SPEED = 250 -- studs/s, same reason, Roblox has no terminal velocity of its own
local IMPULSE_DURATION = 0.1 -- seconds a launch holds its velocity before normal physics resumes
local ACTUATOR_MAX_FORCE = 50000 -- one force budget for the driver and the winch
local MIN_DIRECTION_MAGNITUDE = 0.001 -- a vector shorter than this has no usable direction
-- Combo config
-- Each grapple started before the window runs out adds one. The window starts when you let go of
-- the rope, shrinks with every level, and landing or running out of time ends the combo
local COMBO_WINDOW = 2.5 -- seconds to grab the next point after letting go at x1
local COMBO_SHRINK = 0.3 -- seconds taken off the window per level
local COMBO_MIN_WINDOW = 0.8 -- the window never gets shorter than this
local COMBO_COLORS = { -- by level: x1 gray, x2 green, x3 blue, x4 purple, x5 and up gold
	Color3.fromRGB(170, 170, 180), Color3.fromRGB(80, 220, 110), Color3.fromRGB(70, 160, 255),
	Color3.fromRGB(180, 90, 255), Color3.fromRGB(255, 200, 40), -- anything past the last stays gold
}
-- Gui config, sizes in pixels since a BillboardGui keeps its size on screen
local POINT_GUI_SIZE = UDim2.fromOffset(140, 70) -- the grapple point's gui
local POINT_GUI_OFFSET = Vector3.new(0, 4, 0) -- studs above the point
local POINT_TEXT_SIZE = 22 -- pixels
local COMBO_BAR_SIZE = UDim2.fromOffset(100, 6) -- pixels
local COMBO_BAR_BACKGROUND = Color3.fromRGB(30, 30, 36) -- the empty part of the bar
local STROKE_THICKNESS = 2 -- pixels, the outline on the labels, the bars and the crosshair
local WALL_GUI_SIZE = UDim2.fromOffset(250, 80) -- the wall prompt's gui
local WALL_GUI_OFFSET = Vector3.new(0, 3.5, 0) -- studs above the top of the wall
local WALL_GUI_TEXT = Color3.fromRGB(255, 255, 255)
local WALL_GUI_CORNER = UDim.new(0, 8) -- pixels of rounding on each corner
local CROSSHAIR_SIZE = 6 -- pixels across
local CROSSHAIR_COLOR = Color3.fromRGB(255, 255, 255) -- white, the stroke keeps it visible on sky
-- Camera config
local FOV_BOOST = 20 -- degrees added at MAX_HORIZONTAL_SPEED
local FOV_SPEED_START = 40 -- studs/s where the FOV starts to widen
local CAMERA_SMOOTHING = 10 -- per second, how quickly the roll and the FOV chase their targets
local CAMERA_EPSILON = 0.001 -- a roll (radians) or FOV change (degrees) too small to see
-- Cooldown lookup built from ABILITIES once, so startCooldown is a single table read
local cooldowns: { [Ability]: number } = {}
for _, ability in ABILITIES do -- generalized iteration, walks the array in order
	cooldowns[ability.name] = ability.cooldown
end
-- Animation objects built once and shared. Each character's Animator turns them into its own
-- tracks in bind(), so only the tracks are per character
local swingAnimations: { Animation } = {}
for _, id in SWING_ANIMATION_IDS do
	local animation = Instance.new("Animation")
	animation.AnimationId = id
	table.insert(swingAnimations, animation)
end
-- Grapple point registry
-- Keyed by the instance instead of an array. The added signal and the startup GetTagged pass can
-- both report the same part, and in a map that is a harmless overwrite. Removal is one assignment
-- instead of a search. The removed signal also fires when StreamingEnabled streams a part out,
-- so the registry never holds a point that no longer exists on this client
local grapplePoints: { [Instance]: BasePart } = {}
local pointGuis: { [Instance]: PointGui } = {} -- each point's gui, keyed the same way
local function addStroke(parent: GuiObject) -- the text on a TextLabel, the border on a Frame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = STROKE_THICKNESS -- readable against both sky and lava
	stroke.Parent = parent
end
local function roundCorners(frame: GuiObject, radius: UDim?) -- pill or circle unless given one
	local corner = Instance.new("UICorner")
	-- Scale 0.5 rounds each corner by half the frame's smaller side, the most a corner can take
	corner.CornerRadius = radius or UDim.new(0.5, 0)
	corner.Parent = frame
end
local function makeLabel(parent: Instance, order: number): TextLabel -- one outlined text row
	local label = Instance.new("TextLabel")
	label.LayoutOrder = order -- the row's place in the UIListLayout
	label.Size = UDim2.new(1, 0, 0, POINT_TEXT_SIZE) -- full width, one line tall
	label.BackgroundTransparency = 1 -- text only
	label.Font = Enum.Font.BuilderSansBold
	label.TextSize = POINT_TEXT_SIZE
	label.Visible = false -- hidden rows take no space in a UIListLayout
	addStroke(label)
	label.Parent = parent
	return label
end
local function buildPointGui(point: BasePart): PointGui
	local gui = Instance.new("BillboardGui") -- 2D ui that floats at a 3D part and faces the camera
	gui.Size = POINT_GUI_SIZE
	gui.StudsOffset = POINT_GUI_OFFSET
	gui.AlwaysOnTop = true -- never hidden behind the point or the level
	gui.LightInfluence = 0 -- full brightness whatever the lighting
	gui.Enabled = false -- nothing to show yet
	gui.Parent = point -- with no Adornee a BillboardGui sits on its parent, and dies with it
	local layout = Instance.new("UIListLayout") -- stacks Grapple!, the count and the bar
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom -- rows grow upward from the point
	layout.Padding = UDim.new(0, 4) -- pixels between rows
	layout.Parent = gui
	local grapple = makeLabel(gui, 1)
	grapple.Text = "Grapple!"
	grapple.TextColor3 = GRAPPLE_COLOR -- the same red as the highlight it appears with
	local count = makeLabel(gui, 2) -- text and colour are set when a combo lands here
	local bar = Instance.new("Frame")
	bar.LayoutOrder = 3 -- under the count
	bar.Size = COMBO_BAR_SIZE
	bar.BackgroundColor3 = COMBO_BAR_BACKGROUND
	bar.BorderSizePixel = 0
	bar.Visible = false
	bar.Parent = gui
	roundCorners(bar)
	addStroke(bar) -- on a Frame the stroke outlines its border
	local fill = Instance.new("Frame") -- its X scale is the time left, 1 full and 0 empty
	fill.Size = UDim2.fromScale(1, 1)
	fill.BorderSizePixel = 0
	fill.Parent = bar
	-- Its own corners too, a parent's UICorner does not clip what is inside it
	roundCorners(fill)
	return { gui = gui, grapple = grapple, count = count, bar = bar, fill = fill }
end
local function buildCrosshair(): (ScreenGui, Frame) -- the dot, and the gui holding it
	local gui = Instance.new("ScreenGui")
	gui.Name = "Crosshair"
	gui.ResetOnSpawn = false -- this script runs once, so its gui has to outlive respawns
	-- IgnoreGuiInset stretches the gui over the top bar, so its pixels line up with the screen
	-- pixels GetMouseLocation and ViewportPointToRay use
	gui.IgnoreGuiInset = true
	local dot = Instance.new("Frame")
	dot.AnchorPoint = Vector2.new(0.5, 0.5) -- centred on its position instead of hanging off it
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.Size = UDim2.fromOffset(CROSSHAIR_SIZE, CROSSHAIR_SIZE)
	dot.BackgroundColor3 = CROSSHAIR_COLOR
	dot.BorderSizePixel = 0
	dot.Parent = gui
	roundCorners(dot) -- a square with every corner rounded by half is a circle
	addStroke(dot) -- dark ring so white still shows against the sky
	return gui, dot
end
local function trackGrapplePoint(instance: Instance) -- runs for every part that gains the tag
	-- IsA narrows the type. The second check matters now that a gui is built, the added signal
	-- and the GetTagged pass can both report the same part and it must only get one
	if not instance:IsA("BasePart") or grapplePoints[instance] then return end
	grapplePoints[instance] = instance -- the value keeps the narrowed BasePart type
	pointGuis[instance] = buildPointGui(instance)
end
local function untrackGrapplePoint(instance: Instance) -- untagged, destroyed or streamed out
	local pointGui = pointGuis[instance]
	if pointGui then pointGui.gui:Destroy() end -- already gone if the part was, safe twice
	grapplePoints[instance] = nil -- one assignment each, no search
	pointGuis[instance] = nil
end
-- Shows or hides one point's rows, Grapple! or the combo count and its bar. The gui itself
-- shows when any of its rows does, so the rows are the only thing callers change
local function showPointGui(point: Instance?, visible: boolean, combo: boolean)
	local pointGui = if point then pointGuis[point] else nil -- nil point or untracked, no gui
	if not pointGui then return end
	if combo then
		pointGui.count.Visible = visible
		pointGui.bar.Visible = visible
	else
		pointGui.grapple.Visible = visible
	end
	pointGui.gui.Enabled = pointGui.grapple.Visible or pointGui.count.Visible
end
-- Vector helpers
-- Plain Vector3 maths shared by every ability. Nothing in here touches an Instance
local function horizontal(vector: Vector3): Vector3 -- the same vector with the vertical dropped
	return Vector3.new(vector.X, 0, vector.Z) -- Vector3 is immutable, so this is a new value
end
local function flatten(vector: Vector3): Vector3? -- horizontal direction, nil if there is none
	local flat = horizontal(vector) -- drop the vertical before measuring
	-- Looking straight up or down leaves nothing, and .Unit on a zero vector divides by zero and
	-- the NaN spreads into everything. Unit divides by Magnitude, so the length is exactly 1
	return if flat.Magnitude < MIN_DIRECTION_MAGNITUDE then nil else flat.Unit
end
local function clampVelocity(velocity: Vector3): Vector3 -- caps both axes separately
	local flat = horizontal(velocity) -- the horizontal gets a length cap, not a per axis one
	if flat.Magnitude > MAX_HORIZONTAL_SPEED then -- Magnitude is the length, so the speed
		flat = flat.Unit * MAX_HORIZONTAL_SPEED -- same direction, capped length
	end
	local vertical = math.clamp(velocity.Y, -MAX_VERTICAL_SPEED, MAX_VERTICAL_SPEED) -- both ways
	return flat + Vector3.yAxis * vertical -- flat has Y = 0, so this just puts the vertical back
end
-- Physics helpers
local function liftOff(humanoid: Humanoid) -- makes the Humanoid treat itself as airborne
	if humanoid.FloorMaterial ~= Enum.Material.Air then -- Air means nothing is under the feet
		-- A Running Humanoid pulls itself back onto the floor and applies ground friction, which
		-- eats a launch on its first physics step. Freefall instead of Jumping because Jumping
		-- plays the jump sound and does nothing if a game disabled it with SetStateEnabled
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
	end
end
local function applyImpulse(rig: Rig, velocity: Vector3) -- a launch, held for IMPULSE_DURATION
	liftOff(rig.humanoid) -- the constraint alone would lose its first step to ground friction
	-- A LinearVelocity HOLDS the target for a short window, where writing AssemblyLinearVelocity is
	-- one instant that the Humanoid's own controller can overwrite on the very next step
	rig.driver.VectorVelocity = clampVelocity(velocity) -- set before enabling, never a stale target
	rig.driver.Enabled = true -- step() switches it off again once impulseEndsAt passes
	rig.impulseEndsAt = os.clock() + IMPULSE_DURATION -- a timestamp, so nothing is left waiting
end
local function isStatic(part: BasePart): boolean -- world geometry that will not move under you
	-- Loose props and other players are never anchored. Terrain is matched by identity, so this
	-- never relies on the Anchored flag it only has because it inherits from BasePart
	return part.Anchored or part == Workspace.Terrain
end
local function castWall(rig: Rig, direction: Vector3): RaycastResult? -- a runnable wall or nil
	local origin = rig.root.Position -- rays start from the middle of the body
	-- Raycast takes an origin and a direction whose length is the range, and returns nil on a miss
	local result = Workspace:Raycast(origin, direction * WALL_CHECK_DISTANCE, rig.rayParams)
	-- Normal.Y near 0 rejects the top of a wall part, IsDescendantOf makes the folder the whole
	-- rule, so any part dropped into Walls is runnable and nothing outside it ever is
	if result and math.abs(result.Normal.Y) <= WALL_MAX_NORMAL_Y then
		return if result.Instance:IsDescendantOf(wallsFolder) then result else nil
	end
	return nil
end
local function canSee(rig: Rig, target: BasePart): boolean -- nothing solid between root and target
	local origin = rig.root.Position -- where the rope starts
	local result = Workspace:Raycast(origin, target.Position - origin, rig.rayParams) -- whole gap
	-- A RopeConstraint is a distance limit and not a real rope, it passes straight through walls,
	-- so this ray is what makes it behave like one. The ray is exactly as long as the gap, so a hit
	-- is the target itself, something loose that should not snap the rope, or real geometry
	return result == nil or result.Instance == target or not isStatic(result.Instance)
end
-- Each wall's own colour, saved the first time it is tinted. Reading wall.Color on every run
-- instead would save a half faded green whenever a new run starts before the last fade ends
local wallColors: { [BasePart]: Color3 } = {}
local function flashWall(wall: BasePart) -- green now, back to its own colour as time runs out
	local original = wallColors[wall] or wall.Color
	wallColors[wall] = original
	wall.Color = WALL_READY_COLOR
	-- A new tween on the same property cancels the old one, so re-catching a wall restarts it
	TweenService:Create(wall, WALL_FADE, { Color = original }):Play()
end
local wallGuis: { [Instance]: BillboardGui } = {} -- each wall's prompt, keyed by the wall
local function addWallGui(instance: Instance) -- runs for every part placed in the Walls folder
	-- IsA narrows the type, and the second check keeps it to one gui per wall
	if not instance:IsA("BasePart") or wallGuis[instance] then return end
	local gui = Instance.new("BillboardGui") -- 2D ui at a 3D part that always faces the camera
	gui.Size = WALL_GUI_SIZE
	-- Extents offsets are measured in the part's own size, so (0, 1, 0) is the top of its
	-- bounding box. A short wall and a tall one both get the prompt right on top
	gui.ExtentsOffsetWorldSpace = Vector3.yAxis
	gui.StudsOffset = WALL_GUI_OFFSET -- then a little higher than that
	gui.LightInfluence = 0 -- full brightness whatever the lighting
	gui.Parent = instance -- with no Adornee a BillboardGui sits on its parent, and dies with it
	local label = makeLabel(gui, 1) -- the same outlined text as the grapple prompt
	label.Size = UDim2.fromScale(1, 1) -- the whole gui, text centres itself
	label.TextColor3 = WALL_GUI_TEXT -- white
	label.Text = "Jump on the wall!"
	label.Visible = true -- always on, the gui itself is what gets hidden
	roundCorners(label, WALL_GUI_CORNER)
	wallGuis[instance] = gui
end
local function showWallGui(wall: Instance?, visible: boolean) -- nil wall or no gui does nothing
	local gui = if wall then wallGuis[wall] else nil
	if gui then gui.Enabled = visible end
end
local function bobPoint(instance: Instance) -- starts one point's endless up and down tween
	if not instance:IsA("BasePart") then return end -- IsA also narrows the type to BasePart
	local top = instance.CFrame + Vector3.yAxis * POINT_BOB_HEIGHT -- CFrame + Vector3 moves it
	TweenService:Create(instance, POINT_BOB, { CFrame = top }):Play()
end
local function arrivalRadius(point: BasePart): number -- how close counts as reaching a point
	-- Distances are measured to the point's centre, so half its diagonal is added. Otherwise a big
	-- collidable point would stop you at its surface before you ever got close enough to arrive
	return GRAPPLE_ARRIVE_DISTANCE + point.Size.Magnitude / 2
end
-- Ability maths
-- These only work out a velocity and return it. Applying it is the controller's job, which keeps
-- every rule about state and cooldowns in one place instead of repeated inside each ability
local function leapVelocity(rig: Rig, look: Vector3): Vector3? -- nil means the Leap refused
	-- Looking straight down leaves no horizontal aim, so fall back to where the body faces
	-- instead of refusing, which would read to the player as the game dropping their input
	local direction = flatten(look) or flatten(rig.root.CFrame.LookVector)
	if not direction then return nil end -- only possible if the body itself is tipped over
	local current = rig.root.AssemblyLinearVelocity -- velocity of the whole welded rig
	-- max(base, incoming + bonus): a plain assignment would slow down anyone already faster than
	-- LEAP_SPEED, and adding the full LEAP_SPEED would stack 160 a cast. Chaining still climbs by
	-- the bonus each time, which is the reward for carrying speed, until clampVelocity caps it
	local speed = math.max(LEAP_SPEED, horizontal(current).Magnitude + LEAP_CARRY_BONUS)
	-- Keeping a bigger existing rise stops the leap from cutting your ascent short
	return direction * speed + Vector3.yAxis * math.max(LEAP_UP_SPEED, current.Y)
end
local function blastVelocity(rig: Rig, look: Vector3): Vector3? -- nil means the Blast refused
	local pitch = math.abs(look.Y) -- LookVector is unit length, so Y is the sine of the pitch
	local grounded = rig.humanoid.FloorMaterial ~= Enum.Material.Air -- grounded check, no raycast
	-- Too level and it would just be a Leap on a shorter cooldown. Aiming up while grounded
	-- would drive you into the floor, which can do nothing, so neither costs a cooldown
	if pitch < BLAST_MIN_PITCH or (look.Y > 0 and grounded) then return nil end
	-- How far through the legal pitch range the aim is, clamped to 0..1 so a steeper aim caps out
	local band = math.clamp((pitch - BLAST_MIN_PITCH) / (BLAST_MAX_PITCH - BLAST_MIN_PITCH), 0, 1)
	local strength = BLAST_MIN_STRENGTH + band * (1 - BLAST_MIN_STRENGTH) -- remap 0..1 onto MIN..1
	local impulse = -look * BLAST_SPEED * strength -- unary minus flips the aim, that is the recoil
	local current = rig.root.AssemblyLinearVelocity -- the velocity the body has right now
	-- The blast is a floor your own vertical motion can add to but never cancel. With a plain sum,
	-- falling at 100 and blasting up at 135 would leave only 35, the opposite of what you pressed
	local summedY = current.Y + impulse.Y
	local vertical = if impulse.Y >= 0 -- if expression, one value from two branches
		then math.max(summedY, impulse.Y) -- blasting up: the better of the sum or the blast alone
		else math.min(summedY, impulse.Y) -- blasting down: the same idea with the sign flipped
	-- The horizontal is a plain sum on purpose, blasting against your own motion is how you brake
	return Vector3.new(current.X + impulse.X, vertical, current.Z + impulse.Z)
end
-- skip is the point the combo is on. Leaving it out means the only way to keep a combo going
-- is to swing to a different point, so grabbing the same one again can never add to it
local function findGrappleTarget(rig: Rig, aim: Ray, skip: BasePart?): BasePart?
	local origin = rig.root.Position -- property reads cross into the engine, so read them once
	local eye = aim.Origin -- where the camera is
	local look = aim.Direction -- through the dot, already unit length
	local best: BasePart? = nil -- nothing found yet
	local bestAngle = math.huge -- any point the crosshair is on beats this
	for _, point in grapplePoints do -- every point currently tagged and streamed in
		local position = point.Position -- read once, used twice
		local distance = (position - origin).Magnitude -- the rope's length if this one wins
		local toPoint = position - eye
		-- Dot of two unit vectors is the cosine of the angle between them, acos turns it back into
		-- the angle. Clamped first, float error can push a dot a hair past 1 and acos would be NaN
		local angle = math.acos(math.clamp(look:Dot(toPoint.Unit), -1, 1))
		-- How big the point looks from the camera: its radius over its distance, as an angle. The
		-- crosshair is on the point when the angle to its centre is inside that, so far points are
		-- small targets and near ones big, exactly as they look on screen
		local radius = math.min(point.Size.X, point.Size.Y, point.Size.Z) / 2
		local onPoint = angle <= math.atan(radius / toPoint.Magnitude) + CROSSHAIR_ASSIST
		-- Cheapest tests first. The raycast is the only real cost and 'and' short circuits, so a
		-- ray is only cast for a point in range, under the crosshair and nearer its centre
		if
			point ~= skip -- not the point you just swung on
			and distance <= GRAPPLE_RANGE -- close enough to reach
			and onPoint -- the crosshair is over it
			and angle < bestAngle -- and closer to the crosshair than the best so far
			and distance > arrivalRadius(point) -- not one you have already reached
			and canSee(rig, point) -- the raycast, last so it runs as rarely as possible
		then
			best = point -- the new favourite
			bestAngle = angle -- raises the bar, later points now have to beat this one
		end
	end
	return best
end
-- MovementController
local MovementController = {} -- class table, every method below lives on it
MovementController.__index = MovementController -- instances fall back to the class for methods
type ControllerData = {
	player: Player, -- whose Character bind() checks against
	readyAt: { [Ability]: number }, -- os.clock() time each ability comes off cooldown
	rig: Rig?, -- nil while there is no living character to move
	aimTarget: BasePart?, -- the point F would grab right now
	roll: number, -- current camera roll in radians, smoothed toward its target
	baseFov: number, -- the FOV without the speed boost
	fovBoost: number, -- degrees this kit has currently added on top of baseFov
	writtenFov: number, -- the FOV as it read back after this kit last wrote it
	highlight: Highlight,
	crosshair: Frame, -- the dot, moved to the mouse every frame on PC
	hiddenWall: BasePart?, -- the wall whose prompt is hidden because you are running on it
	combo: number, -- 0 means no combo
	comboEndsAt: number, -- os.clock() when it runs out, math.huge while a rope is held
	comboWindow: number, -- the full length of the current window, for the bar's fraction
	comboPoint: BasePart?, -- the point you last held, where the count and bar are drawn
}
-- typeof(setmetatable(...)) builds the instance type out of the data type and the class table,
-- so every method is typed from its own definition instead of being listed out a second time
type Controller = typeof(setmetatable({} :: ControllerData, MovementController))
function MovementController.new(player: Player): Controller -- constructor, one per player
	-- One Highlight re-pointed with Adornee instead of one per point, the engine only renders a
	-- limited number of highlights at once and swapping Adornee costs nothing
	local highlight = Instance.new("Highlight")
	highlight.FillColor = GRAPPLE_COLOR -- same red as the rope, so the two read as linked
	highlight.FillTransparency = 0.6 -- a tint, not a solid block
	highlight.OutlineColor = GRAPPLE_COLOR -- the outline is what stays readable at a distance
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop -- shows through what is in front
	-- Starts disabled. With no Adornee a Highlight falls back to its parent, and an FPS view model
	-- kept under the camera would light up
	highlight.Enabled = false
	highlight.Parent = Workspace.CurrentCamera -- inside Workspace and only on this client
	local crosshairGui, crosshair = buildCrosshair()
	crosshairGui.Parent = player:WaitForChild("PlayerGui") -- PlayerGui can lag behind
	local fov = Workspace.CurrentCamera.FieldOfView -- read once, used for two fields
	local self: ControllerData = { -- the data half, the methods come from the metatable
		player = player, -- the owner
		readyAt = {}, -- empty means nothing has been cast
		rig = nil, -- bind() fills this once a character exists
		aimTarget = nil, -- render() fills this in every frame
		roll = 0, -- the camera starts level
		baseFov = fov, -- whatever the game set, the boost goes on top of it
		fovBoost = 0, -- nothing added yet
		writtenFov = fov, -- counts as ours, so the first frame does not re-base
		highlight = highlight, crosshair = crosshair, hiddenWall = nil,
		combo = 0, comboEndsAt = 0, comboWindow = COMBO_WINDOW, comboPoint = nil,
	}
	return setmetatable(self, MovementController) -- attach the methods through __index
end
-- Cooldowns
-- Timestamps instead of a boolean that task.delay flips back. Nothing keeps running after the
-- player leaves, and they survive a respawn, so dying does not refresh everything
function MovementController.isOnCooldown(self: Controller, ability: Ability): boolean
	-- Never cast reads as 0 through 'or 0', which is always in the past. os.clock is monotonic
	-- with sub-millisecond resolution, os.time only counts whole seconds
	return os.clock() < (self.readyAt[ability] or 0)
end
function MovementController.startCooldown(self: Controller, ability: Ability) -- charge it
	self.readyAt[ability] = os.clock() + cooldowns[ability] -- stamp when it is ready again
end
-- Character lifecycle
function MovementController.bind(self: Controller, character: Model) -- builds the Rig
	self:unbind() -- a new body replaces whatever the old one was doing
	local humanoid = character:WaitForChild("Humanoid") -- yields until the child exists
	local root = character:WaitForChild("HumanoidRootPart") -- the part the physics moves
	local animator = humanoid:WaitForChild("Animator") -- plays animations, replicated to everyone
	-- WaitForChild yields, so by now this character may already have been replaced. Binding it
	-- anyway would steal the rig from the newer character that is binding at the same time. The
	-- IsA checks narrow all three types
	if self.player.Character ~= character or not humanoid:IsA("Humanoid") then return end
	if not root:IsA("BasePart") or not animator:IsA("Animator") then return end
	local attachment = Instance.new("Attachment") -- the point every constraint grabs the root by
	attachment.Name = "MovementKit" -- easy to spot in the Explorer while testing
	attachment.Parent = root -- at the root's centre, so a push goes through the middle of the body
	local anchor = Instance.new("Attachment") -- the rope's far end
	anchor.Name = "MovementKitAnchor" -- findable under Terrain while testing
	-- Terrain always exists and never moves, so an attachment inside it is a free point in world
	-- space. Inside the target part it would be destroyed with that part and break the next grapple
	anchor.Parent = Workspace.Terrain
	local driver = Instance.new("LinearVelocity") -- a constraint that drives toward a velocity
	driver.Attachment0 = attachment -- the force is applied here
	driver.RelativeTo = Enum.ActuatorRelativeTo.World -- targets are worked out in world space
	driver.ForceLimitMode = Enum.ForceLimitMode.Magnitude -- one cap on the total, not per axis
	-- Finite, not math.huge. An unlimited constraint pushed into static geometry has no solution
	-- and the solver resolves it by flinging the character, a finite one just loses gracefully
	driver.MaxForce = ACTUATOR_MAX_FORCE
	driver.Enabled = false -- off until a launch or a wall run claims it
	driver.Parent = attachment -- parented means live, it still does nothing until Enabled
	local aligner = Instance.new("AlignOrientation") -- a constraint that drives toward a rotation
	aligner.Mode = Enum.OrientationAlignmentMode.OneAttachment -- aims at its own CFrame property
	aligner.Attachment0 = attachment -- the root's rotation is what gets aligned
	aligner.RigidityEnabled = true -- as much torque as it takes, the run direction snaps
	aligner.Enabled = false -- only a wall run turns this on
	aligner.Parent = attachment -- same pattern as the driver
	local rope = Instance.new("RopeConstraint") -- holds two attachments at most Length apart
	rope.Attachment0 = attachment -- this end is the character
	rope.Attachment1 = anchor -- this end is the grapple point
	-- The winch shortens the rope toward WinchTarget at WinchSpeed without pulling harder than
	-- WinchForce. Target 0 reels all the way in, stepGrapple lets go long before that
	rope.WinchEnabled = true
	rope.WinchTarget = 0 -- target length in studs
	rope.WinchSpeed = GRAPPLE_REEL_SPEED -- studs of rope taken in per second
	rope.WinchForce = ACTUATOR_MAX_FORCE -- the most it may pull with
	rope.Enabled = false -- only a grapple turns this on
	rope.Visible = false -- never drawn, the Beam below is what the player sees
	rope.Parent = attachment -- all three constraints are children, one Destroy removes them all
	-- The pull stays on the root so it goes through the body's centre and cannot spin it. Only
	-- the drawing moves to a hand, a Beam between a grip and the anchor, which costs no physics
	local line = Instance.new("Beam")
	line.Attachment1 = anchor -- the far end, on the point
	line.Color = ColorSequence.new(GRAPPLE_COLOR) -- one colour along the whole length
	line.Width0 = ROPE_THICKNESS -- studs at the hand
	line.Width1 = ROPE_THICKNESS -- and at the point
	line.FaceCamera = true -- turns to face the camera so it never looks paper thin
	line.Segments = 1 -- straight, a taut rope has no curve to draw
	line.Enabled = false -- only a grapple turns this on
	line.Parent = attachment
	-- R15 and R6 both keep a RightGripAttachment and a LeftGripAttachment in the hands, where tools
	-- are held. The recursive FindFirstChild finds them on either rig without naming body parts,
	-- IsA narrows each to an Attachment, and a custom rig with no grips draws from the root instead
	local hands: { Attachment } = {}
	for _, name in { "RightGripAttachment", "LeftGripAttachment" } do
		local grip = character:FindFirstChild(name, true)
		if grip and grip:IsA("Attachment") then table.insert(hands, grip) end
	end
	if #hands == 0 then table.insert(hands, attachment) end
	local rayParams = RaycastParams.new() -- built once per character and reused by every cast
	rayParams.FilterType = Enum.RaycastFilterType.Exclude -- the list below is what to skip
	rayParams.FilterDescendantsInstances = { character } -- never hit your own limbs
	rayParams.RespectCanCollide = true -- decoration and the grapple markers are not walls
	rayParams.IgnoreWater = true -- terrain water is not a wall and should not snap a rope
	local swings: { AnimationTrack } = {}
	for _, animation in swingAnimations do
		local track = animator:LoadAnimation(animation) -- loaded now, so pressing F never waits
		track.Priority = Enum.AnimationPriority.Action -- above the freefall pose it plays over
		table.insert(swings, track)
	end
	-- Once disconnects itself after firing, and unbind() disconnects it for a body that leaves
	-- without dying, so a late signal from an old body can never unbind a newer one
	local died = humanoid.Died:Once(function()
		self:unbind() -- a dead body could otherwise still be launched or grappled
	end)
	self.rig = { -- the Rig annotation on the field makes the checker verify every entry
		humanoid = humanoid, root = root, attachment = attachment, anchor = anchor,
		driver = driver, aligner = aligner, rope = rope, line = line, hands = hands,
		rayParams = rayParams, died = died, swings = swings, runSpeed = 0, wallReattachAt = 0,
		jumpHeld = humanoid.Jump, -- a jump held through a respawn is not a new press
		state = "Idle", -- a fresh body is never in the middle of an ability
		stateStartedAt = os.clock(), -- the Idle clock starts now
		impulseEndsAt = 0, -- 0 is always in the past, so no launch is running
		autoRotate = humanoid.AutoRotate, -- refreshed at the start of every wall run anyway
		wallNormal = Vector3.zero, -- only read during a wall run, which writes it first
		wallTangent = Vector3.zero, lastWall = nil, grappleTarget = nil,
	}
end
function MovementController.unbind(self: Controller) -- tears the Rig down again
	local rig = self.rig -- a local, because Luau narrows locals after a nil check but not fields
	if not rig then return end -- already unbound, Died and CharacterRemoving can both land here
	self:setState(rig, "Idle") -- runs the exit logic: AutoRotate back, grapple cooldown started
	rig.died:Disconnect() -- harmless if Once already disconnected it
	rig.attachment:Destroy() -- takes the driver, the aligner and the rope with it
	rig.anchor:Destroy() -- lives in Terrain, so removing the character would never reach it
	self.rig = nil -- step() and render() skip everything from now on
	self.aimTarget = nil -- nothing to aim from until the next character
end
-- State machine
function MovementController.setState(self: Controller, rig: Rig, state: MoveState)
	if rig.state == "WallRun" then -- leaving a wall
		rig.humanoid.AutoRotate = rig.autoRotate -- give turning back to the Humanoid
		rig.wallReattachAt = os.clock() + WALL_REATTACH_TIME -- and do not re-catch the same wall
	elseif rig.state == "Grapple" then -- letting go of a rope
		-- The grapple cooldown starts when the rope comes off, not when it goes on, so hanging on
		-- for longer can never shorten the wait before the next one
		self:startCooldown("Grapple")
		-- The combo clock starts here too, so the time you spend on the rope never counts
		self.comboWindow = math.max(COMBO_MIN_WINDOW, COMBO_WINDOW - COMBO_SHRINK * (self.combo - 1))
		self.comboEndsAt = os.clock() + self.comboWindow
	end
	-- Everything off, then the new state turns on only what it owns. This is what makes it
	-- impossible for a wall run and a rope to fight over the character
	rig.driver.Enabled = false
	rig.aligner.Enabled = false
	rig.rope.Enabled = false
	rig.line.Enabled = false -- the drawn rope goes with the real one
	rig.state = state -- the new owner
	rig.stateStartedAt = os.clock() -- every state measures its own duration from here
end
-- Actions, called from input
function MovementController.tryLaunch(self: Controller, ability: Launch) -- Leap and Blast
	local rig = self.rig -- local, so the nil check below narrows it
	-- No Health check needed, Died unbinds the rig, so a rig existing means the character is alive
	if not rig or self:isOnCooldown(ability) then return end
	local look = Workspace.CurrentCamera.CFrame.LookVector -- both launches aim with the camera
	-- An if expression picks which pure function runs, both of them return a Vector3?
	local velocity = if ability == "Leap" then leapVelocity(rig, look) else blastVelocity(rig, look)
	if not velocity then return end -- the ability refused, so no cooldown is charged
	self:setState(rig, "Idle") -- a launch cancels a wall run or a grapple before taking over
	applyImpulse(rig, velocity) -- the driver holds it for IMPULSE_DURATION
	self:startCooldown(ability) -- only after it actually fired
end
function MovementController.startGrapple(self: Controller) -- F pressed
	local rig = self.rig -- local, so the nil check below narrows it
	local target = self.aimTarget -- chosen in render(), so you always grab what is highlighted
	if not rig or not target or self:isOnCooldown("Grapple") then return end -- nothing to grab
	self:setState(rig, "Grapple") -- ends a wall run or a launch first
	rig.grappleTarget = target -- stepGrapple keeps checking this one
	rig.anchor.WorldPosition = target.Position -- move the rope's far end onto the point
	-- Start the rope at the current distance so it is taut straight away instead of slack
	rig.rope.Length = (target.Position - rig.root.Position).Magnitude
	rig.rope.Enabled = true -- the winch starts reeling on this physics step
	rig.line.Attachment0 = rig.hands[math.random(#rig.hands)] -- left or right hand at random
	rig.line.Enabled = true
	liftOff(rig.humanoid) -- otherwise ground friction fights the first pull
	rig.swings[math.random(#rig.swings)]:Play() -- one swing at random, only on a real grapple
	self:addCombo(target)
end
function MovementController.addCombo(self: Controller, point: BasePart) -- a grapple landed
	-- Still inside the window adds a level, otherwise this grapple starts a fresh x1
	self.combo = if os.clock() < self.comboEndsAt then self.combo + 1 else 1
	self.comboEndsAt = math.huge -- frozen while you hold the rope, setState starts it on release
	showPointGui(self.comboPoint, false, true) -- the count moves from the last point to this one
	self.comboPoint = point
	local pointGui = pointGuis[point]
	if pointGui then
		local color = COMBO_COLORS[math.min(self.combo, #COMBO_COLORS)] -- gold caps the list
		pointGui.count.Text = `x{self.combo}` -- string interpolation
		pointGui.count.TextColor3 = color
		pointGui.fill.BackgroundColor3 = color -- the bar matches the level too
		pointGui.fill.Size = UDim2.fromScale(1, 1) -- full while the rope is held
	end
	showPointGui(point, true, true)
end
function MovementController.endCombo(self: Controller) -- ran out of time or landed
	showPointGui(self.comboPoint, false, true)
	self.combo = 0
	self.comboEndsAt = 0 -- in the past, so the next grapple starts at x1
	self.comboPoint = nil
end
function MovementController.releaseGrapple(self: Controller) -- F released
	local rig = self.rig
	if rig and rig.state == "Grapple" then -- releasing F with no rope on does nothing
		-- Nothing is added on release. Turning the rope off leaves the body with whatever velocity
		-- the swing gave it, which is how momentum carries out of a grapple
		self:setState(rig, "Idle")
	end
end
function MovementController.wallJump(self: Controller, rig: Rig) -- a new jump press on a wall
	-- Keep the run speed along the wall and add a push out of it plus lift
	local push = rig.wallNormal * WALL_JUMP_PUSH + Vector3.yAxis * WALL_JUMP_UP
	local velocity = rig.wallTangent * rig.runSpeed + push -- run speed kept along the wall
	self:setState(rig, "Idle") -- also starts the re-catch lockout on this wall
	applyImpulse(rig, velocity) -- held and clamped like any other launch
end
-- Physics step (PreSimulation)
-- One frame of a wall run: re-find the wall, then steer along it
function MovementController.stepWallRun(self: Controller, rig: Rig, now: number)
	local hit = castWall(rig, -rig.wallNormal) -- straight at the wall we are running on
	local elapsed = now - rig.stateStartedAt -- seconds into this run
	-- Any one of these ends the run: the wall ran out, time is up (the arc is back at its
	-- starting height), you landed, or you stopped steering along it, which is how you drop off
	-- a wall without jumping
	local landed = rig.humanoid.FloorMaterial ~= Enum.Material.Air
	local drifting = rig.humanoid.MoveDirection:Dot(rig.wallTangent) <= 0
	if not hit or elapsed >= WALL_RUN_MAX_TIME or landed or drifting then
		self:setState(rig, "Idle") -- the driver turns off and the body keeps its velocity
		return
	end
	-- Rebuilding the normal and the tangent from this frame's hit is what lets a run follow a
	-- curved wall. The sign test keeps the tangent pointing the same way as last frame
	local normal = horizontal(hit.Normal).Unit
	local tangent = normal:Cross(Vector3.yAxis) -- perpendicular to both the normal and up
	tangent = if tangent:Dot(rig.wallTangent) < 0 then -tangent else tangent -- flipped back
	-- Hold is a proportional controller on the distance to the wall. Pushing into the wall
	-- instead would press the body against it and the friction would drag at the run
	local hold = (hit.Distance - WALL_HOLD_DISTANCE) * WALL_HOLD_GAIN
	-- Vertical speed falls off linearly with time, so the height follows a parabola, an arc
	local lift = WALL_RUN_LIFT - WALL_RUN_GRAVITY * elapsed
	local velocity = tangent * rig.runSpeed - normal * hold + Vector3.yAxis * lift -- run, hold, arc
	rig.driver.VectorVelocity = clampVelocity(velocity) -- the cap covers every write
	-- lookAt from the origin builds a pure rotation facing down the wall, OneAttachment mode
	-- only reads the rotation of this CFrame
	rig.aligner.CFrame = CFrame.lookAt(Vector3.zero, tangent)
	rig.wallNormal = normal -- remembered so next frame's ray aims straight at the wall again
	rig.wallTangent = tangent -- and keeps the direction consistent
	rig.lastWall = hit.Instance -- a long wall can be several parts, lock out the one you leave
end
-- Idle and airborne: look for a wall worth running on
function MovementController.tryWallRun(self: Controller, rig: Rig, now: number)
	local velocity = horizontal(rig.root.AssemblyLinearVelocity) -- only horizontal motion runs
	-- Grounded or too slow ends it here, found out without spending a raycast
	if rig.humanoid.FloorMaterial ~= Enum.Material.Air or velocity.Magnitude < WALL_ENTRY_SPEED then
		return
	end
	-- Cross of the travel direction with world up is the direction to your right, so the two rays
	-- look either side of where you are going rather than where the body happens to face
	local side = velocity.Unit:Cross(Vector3.yAxis)
	local hit = castWall(rig, side) or castWall(rig, -side) -- the left ray only if the right missed
	-- No wall, or the one you just left
	if not hit or (hit.Instance == rig.lastWall and now < rig.wallReattachAt) then return end
	-- castWall only accepts near vertical surfaces, so the flattened normal can never be zero here
	local normal = horizontal(hit.Normal).Unit
	local tangent = normal:Cross(Vector3.yAxis) -- along the wall, but maybe the wrong way
	tangent = if tangent:Dot(velocity) < 0 then -tangent else tangent -- turned to match travel
	-- MoveDirection is the player's input in world space, so this asks whether they are steering
	-- along the wall and stops a launch that only flies past one from being hijacked
	if rig.humanoid.MoveDirection:Dot(tangent) < WALL_INPUT_DOT then return end
	self:setState(rig, "WallRun") -- Idle to WallRun
	flashWall(hit.Instance) -- the green tells the player a wall jump is available
	rig.wallNormal = normal -- stepWallRun aims its ray with this
	rig.wallTangent = tangent -- and keeps the run pointing this way
	-- Only the part of your speed that runs along the wall carries into the run
	rig.runSpeed = math.clamp(velocity:Dot(tangent), WALL_RUN_MIN_SPEED, MAX_HORIZONTAL_SPEED)
	rig.autoRotate = rig.humanoid.AutoRotate -- remember it, the game may have turned it off itself
	rig.humanoid.AutoRotate = false -- the aligner turns the body now, two controllers would fight
	rig.driver.Enabled = true -- the run owns the driver
	rig.aligner.Enabled = true -- and the facing
	-- Run the first step now, still inside this PreSimulation, so physics never sees the targets
	-- the previous run left behind. If it finds a reason to end the run, setState switches both off
	self:stepWallRun(rig, now)
end
-- One frame on the rope: check it is still valid, then check for arrival
function MovementController.stepGrapple(self: Controller, rig: Rig, now: number)
	local target = rig.grappleTarget -- local, so the checks below narrow it
	-- Let go if the point was untagged, destroyed or streamed out (all three leave the registry),
	-- if time ran out, or if something solid came between you and it. The nil check is only for
	-- the type checker, startGrapple always sets it
	local expired = now - rig.stateStartedAt >= GRAPPLE_MAX_TIME -- held for too long
	if not target or not grapplePoints[target] or expired or not canSee(rig, target) then
		self:setState(rig, "Idle") -- rope off, grapple cooldown starts
		return
	end
	rig.anchor.WorldPosition = target.Position -- follow the point, so a moving one still works
	-- Arrived. Keep the horizontal you swung in with and make sure there is enough upward speed
	-- to clear the point, otherwise you would stall under it and drop straight down
	if (target.Position - rig.root.Position).Magnitude <= arrivalRadius(target) then
		local velocity = rig.root.AssemblyLinearVelocity -- read before the rope lets go
		local pop = Vector3.new(velocity.X, math.max(velocity.Y, GRAPPLE_POP_SPEED), velocity.Z)
		self:setState(rig, "Idle")
		applyImpulse(rig, pop) -- a launch like any other, so it is clamped and held
	end
end
function MovementController.step(self: Controller) -- every frame, just before physics
	local rig = self.rig
	if not rig then return end -- dead or respawning, nothing to simulate
	local now = os.clock() -- read once, every check this step uses the same time
	-- The default control script writes the held jump button into Humanoid.Jump every frame, so a
	-- change from false to true is exactly one press however long it is held. JumpRequest is not
	-- used because it fires several times per press and keeps firing while jump is held, so the
	-- jump that carried you onto a wall would also throw you straight back off it
	local jumpHeld = rig.humanoid.Jump
	local jumpPressed = jumpHeld and not rig.jumpHeld
	rig.jumpHeld = jumpHeld
	if rig.state == "WallRun" and jumpPressed then -- each state runs its own step
		self:wallJump(rig) -- leaves the wall, so no run step this frame
	elseif rig.state == "WallRun" then
		self:stepWallRun(rig, now)
	elseif rig.state == "Grapple" then
		self:stepGrapple(rig, now)
	elseif rig.driver.Enabled then -- Idle with a launch in progress
		-- Once its time is up this hands the body back to normal physics, until then it stays on
		rig.driver.Enabled = now < rig.impulseEndsAt
	else
		-- Idle and free. Skipping wall checks during a launch means a leap along a wall only
		-- becomes a wall run after the launch has actually taken effect
		self:tryWallRun(rig, now)
	end
end
-- Render step (after the camera)
function MovementController.render(self: Controller, deltaTime: number) -- after the camera
	local camera = Workspace.CurrentCamera -- the Camera this client renders through
	local view = camera.CFrame -- this frame's camera, already placed by the camera script
	-- On PC the dot sits on the mouse, anywhere else it stays at the centre of the screen
	local point = if usesMouse then UserInputService:GetMouseLocation() else camera.ViewportSize / 2
	self.crosshair.Position = UDim2.fromOffset(point.X, point.Y)
	local rig = self.rig
	-- Moving a fixed fraction per frame would settle faster at higher frame rates.
	-- 1 - e^(-k * dt) makes how fast it settles depend only on real time
	local alpha = 1 - math.exp(-CAMERA_SMOOTHING * deltaTime)
	local targetRoll = 0 -- level, unless a wall run says otherwise
	local speed = 0 -- no body, no speed
	if rig then
		speed = horizontal(rig.root.AssemblyLinearVelocity).Magnitude -- drives the FOV boost
		if rig.state == "WallRun" then
			-- Dot of the camera's right with the direction to the wall is 1 with the wall on your
			-- right, -1 on your left and 0 facing along it, so the tilt fades as you look around
			targetRoll = WALL_TILT * view.RightVector:Dot(-rig.wallNormal)
		end
		if rig.state ~= "Grapple" then -- while a rope is on, the target is already chosen
			-- The ray from the camera through the dot's pixel, so the grapple aims where the dot is
			local aim = camera:ViewportPointToRay(point.X, point.Y)
			self.aimTarget = findGrappleTarget(rig, aim, self.comboPoint)
		end
	end
	self.roll += (targetRoll - self.roll) * alpha -- compound assignment, eases toward the target
	if math.abs(self.roll) > CAMERA_EPSILON then -- skip writes nobody could see
		-- Rebuild the camera level from its own position and LookVector before rolling it. When the
		-- camera script rewrote it this frame that changes nothing, and when it did not (a cutscene
		-- or a death cam) it removes last frame's roll, so the tilt can never pile up. A roll about
		-- the camera's own Z axis leaves LookVector alone, and LookVector is what the camera reads
		local level = CFrame.lookAt(view.Position, view.Position + view.LookVector)
		camera.CFrame = level * CFrame.Angles(0, 0, self.roll)
	end
	-- The kit owns only a boost on top of the FOV. If something else set the FOV since this last
	-- wrote it (an FPS zoom, a settings slider), that value becomes the new base instead of being
	-- fought, so the boost lands on top of their zoom rather than undoing it
	local fov = camera.FieldOfView
	if fov ~= self.writtenFov then self.baseFov = fov end
	local widen = (speed - FOV_SPEED_START) / (MAX_HORIZONTAL_SPEED - FOV_SPEED_START) -- 0 to 1
	local boost = self.fovBoost + (FOV_BOOST * math.clamp(widen, 0, 1) - self.fovBoost) * alpha
	if math.abs(boost - self.fovBoost) > CAMERA_EPSILON then -- settled, so stop writing
		self.fovBoost = boost
		camera.FieldOfView = self.baseFov + boost
		self.writtenFov = camera.FieldOfView -- read back, because the engine clamps FOV to 1..120
	end
	-- The wall you are running on hides its prompt and the one you leave gets it back. lastWall is
	-- the part under you this frame, so a wall made of several parts swaps the prompt as you go
	local onWall = if rig and rig.state == "WallRun" then rig.lastWall else nil
	if onWall ~= self.hiddenWall then -- only write when the wall actually changes
		showWallGui(self.hiddenWall, true)
		showWallGui(onWall, false)
		self.hiddenWall = onWall
	end
	-- While grappling show the point you are on, otherwise the one F would grab
	local grappled = if rig and rig.state == "Grapple" then rig.grappleTarget else nil
	local shown = grappled or self.aimTarget
	if shown ~= self.highlight.Adornee then -- only write when the target actually changes
		showPointGui(self.highlight.Adornee, false, false) -- Grapple! follows the highlight exactly
		showPointGui(shown, true, false)
		self.highlight.Adornee = shown
		self.highlight.Enabled = shown ~= nil -- off rather than falling back to its parent
	end
	if self.combo > 0 then
		local remaining = self.comboEndsAt - os.clock() -- math.huge while a rope is held
		-- Touching the floor ends it, but not on a rope, since a grapple can start on the ground
		local landed = rig ~= nil and rig.state ~= "Grapple"
			and rig.humanoid.FloorMaterial ~= Enum.Material.Air
		if remaining <= 0 or landed then
			self:endCombo()
		else
			local pointGui = if self.comboPoint then pointGuis[self.comboPoint] else nil
			if pointGui then
				-- The window shrinks per level, so a higher combo drains the bar faster
				local fraction = math.min(remaining / self.comboWindow, 1) -- huge clamps to 1
				pointGui.fill.Size = UDim2.fromScale(fraction, 1)
			end
		end
	end
end
-- Wiring
local localPlayer = Players.LocalPlayer -- only exists on the client, the player running this
local controller = MovementController.new(localPlayer) -- the one controller on this client
UserInputService.MouseIconEnabled = not usesMouse -- hide the PC cursor, the dot replaces it
local function onAbilityInput(ability: Ability, state: Enum.UserInputState)
	if state == Enum.UserInputState.Begin then -- pressed
		if ability == "Leap" or ability == "Blast" then -- the comparison narrows it to Launch
			controller:tryLaunch(ability)
		else -- the only other ability is the grapple
			controller:startGrapple() -- grabs the highlighted point
		end
	elseif ability == "Grapple" and state ~= Enum.UserInputState.Change then -- End or Cancel
		-- Cancel counts as a release too. It arrives when another action takes the key mid hold or
		-- a finger slides off the touch button, and without it the rope would stay on
		controller:releaseGrapple()
	end
end
-- ContextActionService instead of reading keys through UserInputService. One BindAction covers the
-- keyboard key, the gamepad button and, through the true argument, an on screen touch button, so
-- mobile players get the kit too. It also stays silent while the player is typing in a TextBox
for _, ability in ABILITIES do
	local name: Ability = ability.name -- annotated, or the old solver widens it to string
	local action = `MovementKit{name}` -- action names are shared by every script, so prefix them
	ContextActionService:BindAction(action, function(_, state: Enum.UserInputState)
		onAbilityInput(name, state)
		return Enum.ContextActionResult.Pass -- the key belongs to the kit, nothing below sees it
	end, true, ability.key, ability.button)
	ContextActionService:SetTitle(action, name) -- the label on the touch button
end
-- Client side tweens, so the bobbing costs the server nothing. Points added or streamed in later
-- are caught by ChildAdded, and walls by DescendantAdded so ones grouped into models still get a
-- prompt. Each signal is connected first so nothing slips in between, and a removed wall only
-- leaves its entry behind since the gui is the wall's child and goes with it
wallsFolder.DescendantAdded:Connect(addWallGui)
wallsFolder.DescendantRemoving:Connect(function(instance: Instance) wallGuis[instance] = nil end)
for _, instance in wallsFolder:GetDescendants() do addWallGui(instance) end
pointsFolder.ChildAdded:Connect(bobPoint)
for _, point in pointsFolder:GetChildren() do bobPoint(point) end
-- Connected before the GetTagged pass over the points that already exist, so a point added in
-- between is caught by the signal. Untagged, destroyed and streamed out parts all fire removed
CollectionService:GetInstanceAddedSignal(GRAPPLE_TAG):Connect(trackGrapplePoint)
CollectionService:GetInstanceRemovedSignal(GRAPPLE_TAG):Connect(untrackGrapplePoint)
for _, instance in CollectionService:GetTagged(GRAPPLE_TAG) do trackGrapplePoint(instance) end
-- A key release never reaches ContextActionService while a TextBox has focus, and alt tabbing
-- away swallows it too. Either would leave the rope on with F no longer held, so both let go
UserInputService.TextBoxFocused:Connect(function() controller:releaseGrapple() end)
UserInputService.WindowFocusReleased:Connect(function() controller:releaseGrapple() end)
-- Every spawn and respawn binds a fresh Rig for the new body, and a respawn without a death
-- (like LoadCharacter) unbinds so the old Rig goes with the old body
localPlayer.CharacterAdded:Connect(function(character: Model) controller:bind(character) end)
localPlayer.CharacterRemoving:Connect(function() controller:unbind() end)
-- Fires every frame just before physics runs, the state machine's physics half
RunService.PreSimulation:Connect(function() controller:step() end)
-- The default camera script updates at RenderPriority.Camera, so one after it means the tilt and
-- FOV are applied on top of this frame's camera instead of being overwritten by it
RunService:BindToRenderStep("MovementKit", Enum.RenderPriority.Camera.Value + 1, function(dt)
	controller:render(dt) -- dt feeds the frame rate independent smoothing
end)
-- There is no teardown block on purpose. This LocalScript lives in PlayerScripts for the whole
-- session, and under deferred signals a script never receives its own Destroying event anyway.
-- What does need cleaning up is per character, and unbind() handles it on every death and respawn
-- Last, because bind yields. The character can exist before this script runs, and then
-- CharacterAdded has already fired and will not fire again for it, so bind it here
if localPlayer.Character then controller:bind(localPlayer.Character) end
