--!strict

local Move = {
	RETURN_TO_MIDDLE = 0x0001,
	ZOOMED_OUT = 0x0002,
	ROTATE_RIGHT = 0x0004,
	ROTATE_LEFT = 0x0008,
	ENTERED_ROTATE_SURFACE = 0x0010,
	METAL_BELOW_WATER = 0x0020,
	FIX_IN_PLACE = 0x0040,
	UNKNOWN_8 = 0x0080,
	CAM_MOVING_INTO_MODE = 0x0100,
	STARTED_EXITING_C_UP = 0x0200,
	UNKNOWN_11 = 0x0400,
	INIT_CAMERA = 0x0800,
	ALREADY_ZOOMED_OUT = 0x1000,
	C_UP_MODE = 0x2000,
	SUBMERGED = 0x4000,
	PAUSE_SCREEN = 0x8000,
}

Move.ROTATE = bit32.bor(Move.ROTATE_RIGHT, Move.ROTATE_LEFT, Move.RETURN_TO_MIDDLE)
Move.RESTRICT = bit32.bor(Move.ENTERED_ROTATE_SURFACE, Move.METAL_BELOW_WATER, Move.FIX_IN_PLACE)
return Move