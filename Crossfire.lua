local SHOW_SECONDS = 4.75
local MAX_STREAK_IMAGE = 5
local IMAGE_DIR = "kill_photo_assets"
local DOWNLOAD_TIMEOUT_MS = 8000

local UI_TAB_INDEX = 2
local UI_SUBTAB_NAME = "##crossfire_Crossfire"
local UI_AUDIO_PANEL_NAME = "##crossfire_Sound"
local UI_AUDIO_ENABLED_NAME = "##crossfire_Enable sound"
local UI_VOLUME_SLIDER_NAME = "##crossfire_Volume"
local UI_VOLUME_SLIDER_POSTFIX = ""

local REMOTE_FILES = {
    ["1.png"] = "https://raw.githubusercontent.com/Spkkkkkk/crossfire_indicator_pcxcs2/main/1.png",
    ["2.png"] = "https://raw.githubusercontent.com/Spkkkkkk/crossfire_indicator_pcxcs2/main/2.png",
    ["3.png"] = "https://raw.githubusercontent.com/Spkkkkkk/crossfire_indicator_pcxcs2/main/3.png",
    ["4.png"] = "https://raw.githubusercontent.com/Spkkkkkk/crossfire_indicator_pcxcs2/main/4.png",
    ["5.png"] = "https://raw.githubusercontent.com/Spkkkkkk/crossfire_indicator_pcxcs2/main/5.png",
    ["headshot.png"] = "https://raw.githubusercontent.com/Spkkkkkk/crossfire_indicator_pcxcs2/main/headshot.png",
    ["1.wav"] = "https://raw.githubusercontent.com/Spkkkkkk/crossfire_indicator_pcxcs2/main/1.wav",
    ["2.wav"] = "https://raw.githubusercontent.com/Spkkkkkk/crossfire_indicator_pcxcs2/main/2.wav",
    ["3.wav"] = "https://raw.githubusercontent.com/Spkkkkkk/crossfire_indicator_pcxcs2/main/3.wav",
    ["4.wav"] = "https://raw.githubusercontent.com/Spkkkkkk/crossfire_indicator_pcxcs2/main/4.wav",
    ["5.wav"] = "https://raw.githubusercontent.com/Spkkkkkk/crossfire_indicator_pcxcs2/main/5.wav",
    ["headshot.wav"] = "https://raw.githubusercontent.com/Spkkkkkk/crossfire_indicator_pcxcs2/main/headshot.wav"
}

local OFFSETS = {
    dwLocalPlayerController = 36651400,
    fallback_m_nKillCount = 0x941
}

local cs2 = nil
local client_base = 0
local kill_count_offset = OFFSETS.fallback_m_nKillCount
local action_tracking_offset = nil
local headshot_count_offset = nil

local images = {}
local headshot_image = 0
local audio_subtab = nil
local audio_panel = nil
local audio_enabled_checkbox = nil
local volume_slider = nil

local last_kill_count = nil
local last_headshot_count = nil
local popup_timer = 0.0
local popup_image_index = 1
local popup_is_headshot = false

local function clamp(value, min_value, max_value)
    if value < min_value then
        return min_value
    end

    if value > max_value then
        return max_value
    end

    return value
end

local function get_rotating_image_index(kill_count)
    if not kill_count or kill_count <= 0 then
        return 1
    end

    return ((kill_count - 1) % MAX_STREAK_IMAGE) + 1
end

local function bytes_from_string(data)
    local bytes = {}

    for i = 1, #data do
        bytes[i] = string.byte(data, i)
    end

    return bytes
end

local function safe_ru64(addr)
    local ok, value = pcall(function()
        return cs2:ru64(addr)
    end)

    if ok then
        return value
    end

    return nil
end

local function safe_ru32(addr)
    local ok, value = pcall(function()
        return cs2:ru32(addr)
    end)

    if ok then
        return value
    end

    return nil
end

local function safe_ru8(addr)
    local ok, value = pcall(function()
        return cs2:ru8(addr)
    end)

    if ok then
        return value
    end

    return nil
end

local function ensure_process()
    if cs2 and cs2:alive() then
        return true
    end

    cs2 = ref_process()
    if not cs2 or not cs2:alive() then
        cs2 = nil
        client_base = 0
        last_kill_count = nil
        return false
    end

    client_base = 0
    last_kill_count = nil
    return true
end

local function resolve_client_base()
    if client_base ~= 0 then
        return client_base ~= nil
    end

    local base = cs2:get_module("client.dll")
    if not base or base == 0 then
        client_base = nil
        return false
    end

    client_base = base
    return true
end

local function resolve_kill_count_offset()
    if not ensure_process() or not resolve_client_base() then
        return
    end

    local entries = cs2:cs2_get_schema_dump()
    if not entries or #entries == 0 then
        log(string.format(
            "[kill-photo] Schema dump vacio, usando fallback m_nKillCount = 0x%X",
            OFFSETS.fallback_m_nKillCount
        ))
        return
    end

    for i = 1, #entries do
        local entry = entries[i]
        if entry and entry.name == "CCSPlayerController::m_nKillCount" then
            kill_count_offset = entry.offset
        elseif entry and entry.name == "CCSPlayerController::m_pActionTrackingServices" then
            action_tracking_offset = entry.offset
        elseif entry and entry.name == "CCSPlayerController_ActionTrackingServices::m_iNumRoundKillsHeadshots" then
            headshot_count_offset = entry.offset
        elseif entry and entry.name == "CCSPlayerController_ActionTrackingServices::m_iHeadShotKills" and not headshot_count_offset then
            headshot_count_offset = entry.offset
        end
    end
end

local function ensure_asset_dir()
    if not does_file_exist(IMAGE_DIR) then
        create_directory(IMAGE_DIR)
    end
end

local function asset_path(file_name)
    return IMAGE_DIR .. "/" .. file_name
end

local function write_binary_file(path, body)
    if write_file_binary then
        return write_file_binary(path, bytes_from_string(body))
    end

    return create_file(path, body)
end

local function download_asset(file_name)
    local url = REMOTE_FILES[file_name]
    if not url or url == "" then
        return false
    end

    local ok, status_code, body = net_http_get(url, DOWNLOAD_TIMEOUT_MS)
    if not ok or status_code ~= 200 or not body or #body == 0 then
        log(string.format("[kill-photo] No pude descargar %s (http=%s)", file_name, tostring(status_code)))
        return false
    end

    local saved = write_binary_file(asset_path(file_name), body)
    if not saved then
        log("[kill-photo] No pude guardar " .. file_name)
        return false
    end

    log("[kill-photo] Descargado " .. file_name)
    return true
end

local function ensure_asset(file_name)
    local path = asset_path(file_name)
    if does_file_exist(path) then
        return true
    end

    return download_asset(file_name)
end

local function load_bitmap_from_file(path)
    if not does_file_exist(path) then
        return 0
    end

    local ok, data = read_file(path)
    if not ok or not data or #data == 0 then
        log("[kill-photo] No pude leer " .. path)
        return 0
    end

    local bmp = create_bitmap(bytes_from_string(data))
    if bmp == 0 then
        log("[kill-photo] create_bitmap fallo con " .. path)
    end

    return bmp
end

local function reload_bitmaps()
    ensure_asset_dir()
    images = {}

    for i = 1, MAX_STREAK_IMAGE do
        local file_name = string.format("%d.png", i)
        ensure_asset(file_name)
        images[i] = load_bitmap_from_file(asset_path(file_name))
    end

    ensure_asset("headshot.png")
    headshot_image = load_bitmap_from_file(asset_path("headshot.png"))
end

local function preload_audio_assets()
    ensure_asset_dir()

    for i = 1, MAX_STREAK_IMAGE do
        ensure_asset(string.format("%d.wav", i))
    end

    ensure_asset("headshot.wav")
end

local function play_kill_sound()
    if audio_enabled_checkbox and not audio_enabled_checkbox:get() then
        return
    end

    local volume = 0.10
    if volume_slider then
        volume = volume_slider:get()
    end

    local file_name = string.format("%d.wav", popup_image_index)
    if popup_is_headshot then
        file_name = "headshot.wav"
    end

    ensure_asset(file_name)
    local sound_path = asset_path(file_name)
    if does_file_exist(sound_path) then
        local snd = load_sound(sound_path)
        if snd then
            local ok = play_sound(snd, volume)
        else
            log("[kill-photo] load_sound fallo: " .. sound_path)
        end
    else
        log("[kill-photo] No existe el audio: " .. sound_path)
    end
end

local function get_local_controller()
    if not ensure_process() or not resolve_client_base() then
        return nil
    end

    local controller = safe_ru64(client_base + OFFSETS.dwLocalPlayerController)
    if not controller or controller == 0 then
        return nil
    end

    return controller
end

local function read_local_kill_count(controller)
    controller = controller or get_local_controller()
    if not controller then
        return nil
    end

    return safe_ru8(controller + kill_count_offset)
end

local function read_local_headshot_count(controller)
    controller = controller or get_local_controller()
    if not controller or not action_tracking_offset or not headshot_count_offset then
        return nil
    end

    local action_tracking = safe_ru64(controller + action_tracking_offset)
    if not action_tracking or action_tracking == 0 then
        return nil
    end

    return safe_ru32(action_tracking + headshot_count_offset)
end

local function draw_kill_popup()
    if popup_timer <= 0.0 then
        return
    end

    local vw, vh = get_view()
    local scale = get_view_scale()
    local fps = get_fps()

    local progress = 1.0 - (popup_timer / SHOW_SECONDS)
    local fade_in = clamp(progress / 0.14, 0.0, 1.0)
    local fade_out = clamp(popup_timer / 0.22, 0.0, 1.0)
    local visibility = math.min(fade_in, fade_out)

    local alpha = math.floor(255 * visibility)
    local grow = 0.92 + (0.08 * visibility)
    local image_bmp = images[popup_image_index] or 0

    if popup_is_headshot and headshot_image ~= 0 then
        image_bmp = headshot_image
    end

    if image_bmp == 0 then
        local dt = 1.0 / math.max(fps, 1.0)
        popup_timer = math.max(0.0, popup_timer - dt)
        return
    end

    local w = math.min(vw * 0.26, 420.0 * scale) * grow
    local h = w * 0.72
    local x = (vw - w) * 0.5
    local y = (vh - h) - (vh * 0.16) - ((1.0 - visibility) * 24.0 * scale)

    draw_bitmap(image_bmp, x, y, w, h, 255, 255, 255, alpha, false)

    local dt = 1.0 / math.max(fps, 1.0)
    popup_timer = math.max(0.0, popup_timer - dt)
end

function main()
    if not ensure_process() then
        log("[kill-photo] No pude obtener el proceso de CS2 todavia.")
        return 1
    end

    if not resolve_client_base() then
        log("[kill-photo] No pude encontrar client.dll.")
        return 1
    end

    resolve_kill_count_offset()
    reload_bitmaps()
    preload_audio_assets()

    if ui and ui.create_subtab then
        audio_subtab = ui.create_subtab(UI_TAB_INDEX, UI_SUBTAB_NAME)
        if audio_subtab then
            audio_panel = audio_subtab:add_panel(UI_AUDIO_PANEL_NAME, false)
            audio_enabled_checkbox = audio_panel:add_checkbox(UI_AUDIO_ENABLED_NAME, true)
            volume_slider = audio_panel:add_slider_double(UI_VOLUME_SLIDER_NAME, UI_VOLUME_SLIDER_POSTFIX, 0.10, 0.00, 1.00, 0.01)
        end
    end

    if (not audio_enabled_checkbox or audio_enabled_checkbox:get()) and does_file_exist(asset_path("1.wav")) then
        local snd = load_sound(asset_path("1.wav"))
        if snd then
            local initial_volume = volume_slider and volume_slider:get() or 0.10
            local ok = play_sound(snd, initial_volume)
        else
            log("[kill-photo] Test audio inicial load_sound fallo.")
        end
    else
        log("[kill-photo] Test audio inicial no disponible.")
    end

    local controller = get_local_controller()
    last_kill_count = read_local_kill_count(controller) or 0
    last_headshot_count = read_local_headshot_count(controller) or 0
    log("[kill-photo] Version con audio y slider cargada.")
    return 1
end

function on_frame()
    local controller = get_local_controller()
    local kill_count = read_local_kill_count(controller)
    local headshot_count = read_local_headshot_count(controller)

    if kill_count ~= nil then
        if last_kill_count == nil then
            last_kill_count = kill_count
        elseif kill_count > last_kill_count then
            popup_image_index = get_rotating_image_index(kill_count)
            popup_is_headshot = headshot_count ~= nil and last_headshot_count ~= nil and headshot_count > last_headshot_count
            popup_timer = SHOW_SECONDS
            play_kill_sound()
            last_kill_count = kill_count
        elseif kill_count < last_kill_count then
            last_kill_count = kill_count
            popup_is_headshot = false
        end
    end

    if headshot_count ~= nil then
        if last_headshot_count == nil or headshot_count < last_headshot_count then
            last_headshot_count = headshot_count
        elseif headshot_count > last_headshot_count then
            last_headshot_count = headshot_count
        end
    end

    draw_kill_popup()
end

function on_unload()
    if cs2 then
        deref_process(cs2)
        cs2 = nil
    end

    log("[kill-photo] Version con audio y slider descargada.")
end
