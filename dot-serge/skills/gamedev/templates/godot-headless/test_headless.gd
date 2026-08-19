# Headless regression test — no window, no GPU. The Godot analogue of game.test.mjs.
#   godot --headless --path <this dir> -s res://test_headless.gd
# Exits 0 on pass, 1 on failure (CI-friendly). Determinism + frozen known-answer.
extends SceneTree

# preload (not the class_name global): the global class cache isn't built when a bare script
# is run with `-s` on a fresh project, so preload is the portable way to reference sim.gd.
const SimScript := preload("res://sim.gd")

const SCRIPT := ["right", "right", "down", "down", "left", "up", "right", "down", "down",
	"right", "right", "up", "left", "wait", "down", "right", "right", "down", "left", "up"]
const FROZEN := "42|20|1|5|2,1|false"  # frozen known-answer (Godot RNG stream)

func _initialize() -> void:
	var sig: String = SimScript.run(42, SCRIPT)
	var sig2: String = SimScript.run(42, SCRIPT)
	var ok := true
	print("SIGNATURE: ", sig)
	if sig != sig2:
		push_error("determinism FAIL: %s != %s" % [sig, sig2])
		ok = false
	if FROZEN != "PLACEHOLDER" and sig != FROZEN:
		push_error("known-answer FAIL: got %s want %s" % [sig, FROZEN])
		ok = false
	if ok:
		print("RESULT: PASS")
	else:
		print("RESULT: FAIL")
	quit(0 if ok else 1)
