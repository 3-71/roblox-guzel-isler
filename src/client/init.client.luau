--!strict
-- Grow a Keyboard — client bootstrap.

local controllers = {
	require(script.Controllers.UIController),
	require(script.Controllers.SoundController),
	require(script.Controllers.EffectsController),
	require(script.Controllers.EventController),
	require(script.Controllers.RaceController),
}

for _, controller in controllers do
	local ok, err = pcall(controller.Start)
	if not ok then
		warn("[GrowAKeyboard] controller failed to start:", err)
	end
end
