# Deterministic game SIM in GDScript — the same doctrine as the JS core: a pure function of
# (seed, inputs), seeded RNG, no rendering, no node tree. Headless-testable via test_headless.gd.
# The render/scene layer sits on top and calls Sim.run / step; it never owns game state.
class_name Sim

const W := 16
const H := 12
const WALL_CHANCE := 0.28
const COINS := 6

static func generate_dungeon(seed: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var grid := []
	for y in range(H):
		var row := []
		for x in range(W):
			var border := x == 0 or y == 0 or x == W - 1 or y == H - 1
			row.append(1 if border else (1 if rng.randf() < WALL_CHANCE else 0))
		grid.append(row)
	grid[1][1] = 0
	return grid

static func run(seed: int, inputs: Array) -> String:
	var grid := generate_dungeon(seed)
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = seed ^ 0x9e3779b9
	var coins := {}
	var placed := 0
	while placed < COINS:
		var cx := 1 + int(rng2.randf() * (W - 2))
		var cy := 1 + int(rng2.randf() * (H - 2))
		var key := "%d,%d" % [cx, cy]
		if grid[cy][cx] == 0 and not (cx == 1 and cy == 1) and not coins.has(key):
			coins[key] = true
			placed += 1
	var px := 1
	var py := 1
	var score := 0
	var tick := 0
	var dirs := {
		"up": Vector2i(0, -1), "down": Vector2i(0, 1),
		"left": Vector2i(-1, 0), "right": Vector2i(1, 0), "wait": Vector2i(0, 0)
	}
	for inp in inputs:
		var d: Vector2i = dirs.get(inp, Vector2i(0, 0))
		var nx := px + d.x
		var ny := py + d.y
		if grid[ny][nx] == 0:
			px = nx
			py = ny
		var k := "%d,%d" % [px, py]
		if coins.has(k):
			coins.erase(k)
			score += 1
		tick += 1
	var done := "true" if coins.size() == 0 else "false"
	return "%d|%d|%d|%d|%d,%d|%s" % [seed, tick, score, coins.size(), px, py, done]
