package com.fongmi.android.tv.server.process;

import android.text.TextUtils;

import com.fongmi.android.tv.App;
import com.fongmi.android.tv.api.config.VodConfig;
import com.fongmi.android.tv.event.RefreshEvent;
import com.fongmi.android.tv.server.impl.Process;
import com.fongmi.android.tv.setting.DanmakuSetting;
import com.fongmi.android.tv.setting.PlayerSetting;
import com.fongmi.android.tv.setting.ProxySetting;
import com.fongmi.android.tv.setting.Setting;
import com.github.catvod.bean.Doh;
import com.github.catvod.crawler.SpiderDebug;
import com.github.catvod.net.OkHttp;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;

import fi.iki.elonen.NanoHTTPD;
import fi.iki.elonen.NanoHTTPD.IHTTPSession;
import fi.iki.elonen.NanoHTTPD.Response;

/**
 * Exposes the app-level settings over the LAN HTTP server so a phone or PC on the
 * same network can view and edit them, then push the change back to the TV.
 *
 * Routes:
 *   GET  /setting/schema  -> grouped field schema + current values (JSON)
 *   POST /setting/save    -> {"values":{key:value}} apply and reload affected UI (JSON)
 *
 * The static page is served by {@link com.fongmi.android.tv.server.Nano} from
 * assets as "setting.html" for the bare "/setting" URL.
 *
 * All writes go through the same Setting/PlayerSetting/DanmakuSetting setters the
 * in-app settings screens use. Player-kernel and danmaku-appearance changes are
 * persisted immediately but, like the in-app screens, take effect on the next
 * playback / danmaku load; we deliberately do not restart an active player.
 */
public class SettingApi implements Process {

    /** Keys whose only effect is a persisted pref; no UI reload should be fired. */
    private static final Set<String> PERSIST_ONLY = Set.of(
            "player", "render", "mpv_render", "size", "scale", "episode_column",
            "buffer", "back_buffer_option", "buffer_bytes_option", "play_cache_option",
            "auto_change", "auto_play", "bluray_menu", "tunnel", "exo_enhanced",
            "audio_pass_through", "audio_prefer", "video_prefer", "prefer_aac", "caption",
            "subtitle_text_size", "subtitle_position", "default_speed",
            "danmaku_load", "danmaku_auto", "danmaku_spider_first", "danmaku_api_url",
            "danmaku_show", "danmaku_text_scale", "danmaku_transparency", "danmaku_text_bold",
            "danmaku_duration_ms", "danmaku_fixed_duration_ms", "danmaku_time_offset_ms",
            "danmaku_max_on_screen", "danmaku_scroll_area_ratio", "danmaku_max_scroll_lines",
            "danmaku_line_spacing", "danmaku_show_scroll", "danmaku_show_top", "danmaku_show_subtitle",
            "ua", "zhuyin", "csp_warmup_sites", "update_github_proxy", "update_github_proxy_url",
            "update_github_proxy_mode", "update_oci_mirror", "update_oci_mirror_url");

    @Override
    public boolean isRequest(IHTTPSession session, String url) {
        return "/setting/schema".equals(url) || "/setting/save".equals(url);
    }

    @Override
    public Response doResponse(IHTTPSession session, String url, Map<String, String> files) {
        try {
            if ("/setting/schema".equals(url)) return schema();
            if (session.getMethod() != NanoHTTPD.Method.POST) return error(Response.Status.METHOD_NOT_ALLOWED, "POST required");
            return save(files.get("postData"));
        } catch (Throwable e) {
            SpiderDebug.log("setting-api", e);
            return error(Response.Status.INTERNAL_ERROR, e.getMessage());
        }
    }

    private Response schema() {
        JsonArray groups = new JsonArray();
        groups.add(group("network", "网络与接口", "",
                select("doh", "安全 DNS (DoH)", dohOptions(), Setting.getDoh()),
                toggle("shell_proxy", "启用自定义代理", Setting.isShellProxy()),
                text("shell_proxy_url", "代理地址", Setting.getShellProxyUrl()),
                textarea("shell_proxy_rules", "代理规则", Setting.getShellProxyRules())
        ));
        groups.add(group("interface", "界面与显示", "",
                select("language", "语言", intOptions("0:跟随系统", "1:简体中文", "2:繁体中文"), Setting.getLanguage()),
                select("ui_scale", "界面缩放", intOptions("0:跟随系统", "1:标准", "4:轻度紧凑", "2:紧凑", "5:更紧凑", "3:较小"), Setting.getUiScale()),
                select("wall", "壁纸", wallOptions(), Setting.getWall()),
                select("search_column", "搜索结果列数", intOptions("1:1 列", "2:2 列"), Setting.getSearchColumn()),
                number("site_column", "站点列数", Setting.getSiteColumn()),
                toggle("compact_episode_title", "紧凑剧集标题", Setting.isCompactEpisodeTitle()),
                toggle("playback_artwork_wall", "播放页海报壁纸", Setting.isPlaybackArtworkWall()),
                toggle("web_home_fullscreen", "网页首页全屏", Setting.isWebHomeFullscreen()),
                toggle("web_home_extension", "网页首页扩展配置", Setting.isWebHomeExtension())
        ));
        groups.add(group("playback", "播放与筛选", "",
                number("site_mode", "站点模式", Setting.getSiteMode()),
                toggle("site_health_sort", "站点健康排序", Setting.isSiteHealthSort()),
                toggle("site_health_dialog_sort", "站点健康弹窗排序", Setting.isSiteHealthDialogSort()),
                toggle("incognito", "隐身模式", Setting.isIncognito()),
                toggle("adblock", "广告过滤", Setting.isAdblock()),
                toggle("drive_check", "网盘有效性检测", Setting.isDriveCheck()),
                toggle("csp_warmup", "CSP 预热", Setting.isCspWarmup()),
                select("csp_warmup_mode", "CSP 预热模式", intOptions("1:默认", "2:自定义"), Setting.getCspWarmupSelectedMode())
        ));
        groups.add(group("player", "播放器",
                "保存后立即写入。播放内核、渲染、缓冲等参数在下一次播放时生效（与应用内「播放器」设置页一致，不会打断当前播放）。",
                select("player", "播放内核", intOptions("0:EXO", "1:IJK", "2:MPV"), PlayerSetting.getPlayer()),
                select("render", "渲染方式", intOptions("0:Surface(4K/HDR)", "1:Texture(兼容)"), PlayerSetting.getRender()),
                select("mpv_render", "MPV 渲染后端", intOptions("0:OpenGL", "1:Vulkan"), PlayerSetting.getMpvRender()),
                number("size", "画面尺寸", PlayerSetting.getSize()),
                number("scale", "画面缩放", PlayerSetting.getScale()),
                number("episode_column", "剧集列数", PlayerSetting.getEpisodeColumn()),
                number("buffer", "缓冲档位", PlayerSetting.getBuffer()),
                number("back_buffer_option", "回看缓冲档位", PlayerSetting.getBackBufferOption()),
                number("buffer_bytes_option", "缓冲字节档位", PlayerSetting.getBufferBytesOption()),
                number("play_cache_option", "播放缓存档位", PlayerSetting.getPlayCacheOption()),
                toggle("auto_change", "自动换源", PlayerSetting.isAutoChange()),
                toggle("auto_play", "自动连播", PlayerSetting.isAutoPlay()),
                toggle("bluray_menu", "蓝光菜单", PlayerSetting.isBlurayMenu()),
                toggle("tunnel", "Tunnel 直通(4K/HDR)", PlayerSetting.isTunnel()),
                toggle("exo_enhanced", "Exo 4K 增强", PlayerSetting.isExoEnhanced()),
                toggle("audio_pass_through", "音频直通", PlayerSetting.isAudioPassThrough()),
                toggle("audio_prefer", "音频优先", PlayerSetting.isAudioPrefer()),
                toggle("video_prefer", "视频优先", PlayerSetting.isVideoPrefer()),
                toggle("prefer_aac", "优先 AAC", PlayerSetting.isPreferAAC()),
                toggle("caption", "系统字幕", PlayerSetting.isCaption()),
                floatField("subtitle_text_size", "字幕字号", PlayerSetting.getSubtitleTextSize()),
                floatField("subtitle_position", "字幕位置", PlayerSetting.getSubtitlePosition()),
                floatField("default_speed", "默认倍速", PlayerSetting.getDefaultSpeed())
        ));
        groups.add(group("danmaku", "弹幕",
                "保存后立即写入。弹幕外观在下次加载弹幕时生效（与应用内「弹幕」设置面板一致）。",
                toggle("danmaku_load", "加载弹幕", DanmakuSetting.isLoad()),
                toggle("danmaku_auto", "自动加载", DanmakuSetting.isAuto()),
                toggle("danmaku_spider_first", "Spider 弹幕优先", DanmakuSetting.isSpiderFirst()),
                text("danmaku_api_url", "自定义弹幕接口", DanmakuSetting.getApiUrl()),
                toggle("danmaku_show", "显示弹幕", DanmakuSetting.isShow()),
                floatField("danmaku_text_scale", "字号缩放", DanmakuSetting.getTextScale()),
                floatField("danmaku_transparency", "不透明度", DanmakuSetting.getTransparency()),
                toggle("danmaku_text_bold", "弹幕加粗", DanmakuSetting.isTextBold()),
                number("danmaku_duration_ms", "滚动时长(ms)", (int) DanmakuSetting.getDurationMs()),
                number("danmaku_fixed_duration_ms", "固定弹幕时长(ms)", (int) DanmakuSetting.getFixedDurationMs()),
                number("danmaku_time_offset_ms", "时间偏移(ms)", (int) DanmakuSetting.getTimeOffsetMs()),
                number("danmaku_max_on_screen", "同屏上限", DanmakuSetting.getMaxOnScreen()),
                floatField("danmaku_scroll_area_ratio", "滚动区域比例", DanmakuSetting.getScrollAreaRatio()),
                number("danmaku_max_scroll_lines", "滚动行数上限", DanmakuSetting.getMaxScrollLines()),
                floatField("danmaku_line_spacing", "行距", DanmakuSetting.getLineSpacing()),
                toggle("danmaku_show_scroll", "显示滚动弹幕", DanmakuSetting.isShowScroll()),
                toggle("danmaku_show_top", "显示顶部弹幕", DanmakuSetting.isShowTop()),
                toggle("danmaku_show_subtitle", "显示字幕弹幕", DanmakuSetting.isShowSubtitle())
        ));
        groups.add(group("enhance", "增强",
                "与设置页「增强」对应。网盘检测、站点健康排序、CSP 预热、网页首页、调试日志等开关已在上方分组。修改后即时写入，部分项下次进入对应页面生效。",
                text("ua", "自定义 User-Agent", Setting.getUa()),
                toggle("zhuyin", "注音搜索", Setting.isZhuyin()),
                select("wall_type", "壁纸来源", intOptions("0:内置", "1:自定义"), Setting.getWallType()),
                number("theme_color", "主题色 (int, -1=跟随)", Setting.getThemeColor()),
                number("wall_color", "壁纸色 (int)", Setting.getWallColor()),
                textarea("csp_warmup_sites", "CSP 预热站点 (每行一个 key)", joinLines(Setting.getCspWarmupSites())),
                text("update_github_proxy", "GitHub 更新代理", Setting.getUpdateGithubProxy()),
                text("update_github_proxy_url", "GitHub 代理自定义地址", Setting.getUpdateGithubProxyUrl()),
                text("update_github_proxy_mode", "GitHub 代理模式", Setting.getUpdateGithubProxyMode()),
                text("update_oci_mirror", "OCI 镜像", Setting.getUpdateOciMirror()),
                text("update_oci_mirror_url", "OCI 镜像自定义地址", Setting.getUpdateOciMirrorUrl())
        ));
        groups.add(group("advanced", "更新与调试", "",
                toggle("update", "自动检查更新", Setting.getUpdate()),
                select("update_source", "更新源", updateSourceOptions(), Setting.getUpdateSource()),
                toggle("debug_log", "调试日志", Setting.isDebugLog())
        ));
        JsonObject root = new JsonObject();
        root.addProperty("ok", true);
        root.add("groups", groups);
        return json(root);
    }

    private Response save(String body) {
        if (TextUtils.isEmpty(body)) return error(Response.Status.BAD_REQUEST, "请求体不能为空");
        JsonObject payload;
        try {
            payload = App.gson().fromJson(body, JsonObject.class);
        } catch (Throwable e) {
            return error(Response.Status.BAD_REQUEST, "无效的 JSON");
        }
        if (payload == null || !payload.has("values") || !payload.get("values").isJsonObject()) return error(Response.Status.BAD_REQUEST, "缺少 values 字段");
        JsonObject values = payload.getAsJsonObject("values");
        Set<String> allowed = allowedKeys();
        int applied = 0;
        boolean theme = false, size = false, home = false, language = false;
        for (Map.Entry<String, JsonElement> entry : values.entrySet()) {
            String key = entry.getKey();
            if (!allowed.contains(key)) continue;
            if (!apply(key, entry.getValue())) continue;
            applied++;
            if (PERSIST_ONLY.contains(key)) continue;
            switch (key) {
                case "wall", "wall_color", "theme_color", "wall_type" -> theme = true;
                case "ui_scale", "search_column", "site_column", "compact_episode_title" -> size = true;
                case "language" -> language = true;
                default -> home = true;
            }
        }
        if (language) RefreshEvent.language();
        if (theme) RefreshEvent.theme();
        if (size) RefreshEvent.size();
        if (home) RefreshEvent.home();
        JsonObject result = new JsonObject();
        result.addProperty("ok", true);
        result.addProperty("applied", applied);
        return json(result);
    }

    private boolean apply(String key, JsonElement value) {
        try {
            switch (key) {
                // 网络与接口
                case "doh" -> { String v = value.getAsString(); Setting.putDoh(v); try { OkHttp.dns().setDoh(Doh.objectFrom(v)); } catch (Throwable ignored) {} }
                case "shell_proxy" -> Setting.putShellProxy(value.getAsBoolean());
                case "shell_proxy_url" -> Setting.putShellProxyUrl(value.getAsString());
                case "shell_proxy_rules" -> Setting.putShellProxyRules(value.getAsString());
                // 界面与显示
                case "language" -> Setting.putLanguage(value.getAsInt());
                case "ui_scale" -> Setting.putUiScale(value.getAsInt());
                case "wall" -> Setting.putWall(value.getAsInt());
                case "wall_type" -> Setting.putWallType(value.getAsInt());
                case "theme_color" -> Setting.putThemeColor(value.getAsInt());
                case "wall_color" -> Setting.putWallColor(value.getAsInt());
                case "search_column" -> Setting.putSearchColumn(value.getAsInt());
                case "site_column" -> Setting.putSiteColumn(value.getAsInt());
                case "compact_episode_title" -> Setting.putCompactEpisodeTitle(value.getAsBoolean());
                case "playback_artwork_wall" -> Setting.putPlaybackArtworkWall(value.getAsBoolean());
                case "web_home_fullscreen" -> Setting.putWebHomeFullscreen(value.getAsBoolean());
                case "web_home_extension" -> Setting.putWebHomeExtension(value.getAsBoolean());
                // 播放与筛选
                case "site_mode" -> Setting.putSiteMode(value.getAsInt());
                case "site_health_sort" -> Setting.putSiteHealthSort(value.getAsBoolean());
                case "site_health_dialog_sort" -> Setting.putSiteHealthDialogSort(value.getAsBoolean());
                case "incognito" -> Setting.putIncognito(value.getAsBoolean());
                case "adblock" -> Setting.putAdblock(value.getAsBoolean());
                case "drive_check" -> Setting.putDriveCheck(value.getAsBoolean());
                case "csp_warmup" -> Setting.putCspWarmup(value.getAsBoolean());
                case "csp_warmup_mode" -> Setting.putCspWarmupMode(value.getAsInt());
                // 播放器
                case "player" -> PlayerSetting.putPlayer(value.getAsInt());
                case "render" -> PlayerSetting.putRender(value.getAsInt());
                case "mpv_render" -> PlayerSetting.putMpvRender(value.getAsInt());
                case "size" -> PlayerSetting.putSize(value.getAsInt());
                case "scale" -> PlayerSetting.putScale(value.getAsInt());
                case "episode_column" -> PlayerSetting.putEpisodeColumn(value.getAsInt());
                case "buffer" -> PlayerSetting.putBuffer(value.getAsInt());
                case "back_buffer_option" -> PlayerSetting.putBackBufferOption(value.getAsInt());
                case "buffer_bytes_option" -> PlayerSetting.putBufferBytesOption(value.getAsInt());
                case "play_cache_option" -> PlayerSetting.putPlayCacheOption(value.getAsInt());
                case "auto_change" -> PlayerSetting.putAutoChange(value.getAsBoolean());
                case "auto_play" -> PlayerSetting.putAutoPlay(value.getAsBoolean());
                case "bluray_menu" -> PlayerSetting.putBlurayMenu(value.getAsBoolean());
                case "tunnel" -> PlayerSetting.putTunnel(value.getAsBoolean());
                case "exo_enhanced" -> PlayerSetting.putExoEnhanced(value.getAsBoolean());
                case "audio_pass_through" -> PlayerSetting.putAudioPassThrough(value.getAsBoolean());
                case "audio_prefer" -> PlayerSetting.putAudioPrefer(value.getAsBoolean());
                case "video_prefer" -> PlayerSetting.putVideoPrefer(value.getAsBoolean());
                case "prefer_aac" -> PlayerSetting.putPreferAAC(value.getAsBoolean());
                case "caption" -> PlayerSetting.putCaption(value.getAsBoolean());
                case "subtitle_text_size" -> PlayerSetting.putSubtitleTextSize(value.getAsFloat());
                case "subtitle_position" -> PlayerSetting.putSubtitlePosition(value.getAsFloat());
                case "default_speed" -> PlayerSetting.putDefaultSpeed(value.getAsFloat());
                // 弹幕
                case "danmaku_load" -> DanmakuSetting.putLoad(value.getAsBoolean());
                case "danmaku_auto" -> DanmakuSetting.putAuto(value.getAsBoolean());
                case "danmaku_spider_first" -> DanmakuSetting.putSpiderFirst(value.getAsBoolean());
                case "danmaku_api_url" -> DanmakuSetting.putApiUrl(value.getAsString());
                case "danmaku_show" -> DanmakuSetting.putShow(value.getAsBoolean());
                case "danmaku_text_scale" -> DanmakuSetting.putTextScale(value.getAsFloat());
                case "danmaku_transparency" -> DanmakuSetting.putTransparency(value.getAsFloat());
                case "danmaku_text_bold" -> DanmakuSetting.putTextBold(value.getAsBoolean());
                case "danmaku_duration_ms" -> DanmakuSetting.putDurationMs(value.getAsLong());
                case "danmaku_fixed_duration_ms" -> DanmakuSetting.putFixedDurationMs(value.getAsLong());
                case "danmaku_time_offset_ms" -> DanmakuSetting.putTimeOffsetMs(value.getAsLong());
                case "danmaku_max_on_screen" -> DanmakuSetting.putMaxOnScreen(value.getAsInt());
                case "danmaku_scroll_area_ratio" -> DanmakuSetting.putScrollAreaRatio(value.getAsFloat());
                case "danmaku_max_scroll_lines" -> DanmakuSetting.putMaxScrollLines(value.getAsInt());
                case "danmaku_line_spacing" -> DanmakuSetting.putLineSpacing(value.getAsFloat());
                case "danmaku_show_scroll" -> DanmakuSetting.putShowScroll(value.getAsBoolean());
                case "danmaku_show_top" -> DanmakuSetting.putShowTop(value.getAsBoolean());
                case "danmaku_show_subtitle" -> DanmakuSetting.putShowSubtitle(value.getAsBoolean());
                // 增强
                case "ua" -> Setting.putUa(value.getAsString());
                case "zhuyin" -> Setting.putZhuyin(value.getAsBoolean());
                case "csp_warmup_sites" -> Setting.putCspWarmupSites(splitLines(value.getAsString()));
                case "update_github_proxy" -> Setting.putUpdateGithubProxy(value.getAsString());
                case "update_github_proxy_url" -> Setting.putUpdateGithubProxyUrl(value.getAsString());
                case "update_github_proxy_mode" -> Setting.putUpdateGithubProxyMode(value.getAsString());
                case "update_oci_mirror" -> Setting.putUpdateOciMirror(value.getAsString());
                case "update_oci_mirror_url" -> Setting.putUpdateOciMirrorUrl(value.getAsString());
                // 更新与调试
                case "update" -> Setting.putUpdate(value.getAsBoolean());
                case "update_source" -> Setting.putUpdateSource(value.getAsString());
                case "debug_log" -> Setting.putDebugLog(value.getAsBoolean());
                default -> { return false; }
            }
            return true;
        } catch (Throwable e) {
            SpiderDebug.log("setting-api", "apply failed key=%s error=%s", key, e.getMessage());
            return false;
        }
    }

    private Set<String> allowedKeys() {
        return Set.of("doh", "shell_proxy", "shell_proxy_url", "shell_proxy_rules",
                "language", "ui_scale", "wall", "wall_type", "theme_color", "wall_color",
                "search_column", "site_column", "compact_episode_title", "playback_artwork_wall",
                "web_home_fullscreen", "web_home_extension", "site_mode", "site_health_sort",
                "site_health_dialog_sort", "incognito", "adblock", "drive_check", "csp_warmup",
                "csp_warmup_mode", "update", "update_source", "debug_log",
                "player", "render", "mpv_render", "size", "scale", "episode_column",
                "buffer", "back_buffer_option", "buffer_bytes_option", "play_cache_option",
                "auto_change", "auto_play", "bluray_menu", "tunnel", "exo_enhanced",
                "audio_pass_through", "audio_prefer", "video_prefer", "prefer_aac", "caption",
                "subtitle_text_size", "subtitle_position", "default_speed",
                "danmaku_load", "danmaku_auto", "danmaku_spider_first", "danmaku_api_url",
                "danmaku_show", "danmaku_text_scale", "danmaku_transparency", "danmaku_text_bold",
                "danmaku_duration_ms", "danmaku_fixed_duration_ms", "danmaku_time_offset_ms",
                "danmaku_max_on_screen", "danmaku_scroll_area_ratio", "danmaku_max_scroll_lines",
                "danmaku_line_spacing", "danmaku_show_scroll", "danmaku_show_top", "danmaku_show_subtitle",
                "ua", "zhuyin", "csp_warmup_sites", "update_github_proxy", "update_github_proxy_url",
                "update_github_proxy_mode", "update_oci_mirror", "update_oci_mirror_url");
    }

    private JsonArray dohOptions() {
        JsonArray options = new JsonArray();
        options.add(option("", "关闭"));
        try {
            for (Doh doh : VodConfig.get().getDoh()) options.add(option(doh.toString(), doh.getName()));
        } catch (Throwable ignored) {
        }
        return options;
    }

    private JsonArray wallOptions() {
        JsonArray options = new JsonArray();
        for (int wall : Setting.getDefaultWalls()) options.add(option(String.valueOf(wall), Setting.getBuiltInWallName(wall)));
        return options;
    }

    private JsonArray updateSourceOptions() {
        return intOptions("oci:OCI 镜像", "github:GitHub");
    }

    private JsonArray intOptions(String... pairs) {
        JsonArray options = new JsonArray();
        for (String pair : pairs) {
            int cut = pair.indexOf(':');
            options.add(option(pair.substring(0, cut), pair.substring(cut + 1)));
        }
        return options;
    }

    private JsonObject option(String value, String label) {
        JsonObject object = new JsonObject();
        object.addProperty("value", value);
        object.addProperty("label", label);
        return object;
    }

    private JsonObject group(String id, String title, String note, JsonObject... fields) {
        JsonObject object = new JsonObject();
        object.addProperty("id", id);
        object.addProperty("title", title);
        if (!TextUtils.isEmpty(note)) object.addProperty("note", note);
        JsonArray array = new JsonArray();
        for (JsonObject field : fields) array.add(field);
        object.add("fields", array);
        return object;
    }

    private JsonObject base(String key, String type, String label) {
        JsonObject object = new JsonObject();
        object.addProperty("key", key);
        object.addProperty("type", type);
        object.addProperty("label", label);
        return object;
    }

    private JsonObject text(String key, String label, String value) {
        JsonObject object = base(key, "text", label);
        object.addProperty("value", value == null ? "" : value);
        return object;
    }

    private JsonObject textarea(String key, String label, String value) {
        JsonObject object = base(key, "textarea", label);
        object.addProperty("value", value == null ? "" : value);
        return object;
    }

    private JsonObject number(String key, String label, int value) {
        JsonObject object = base(key, "number", label);
        object.addProperty("value", value);
        return object;
    }

    private JsonObject floatField(String key, String label, float value) {
        JsonObject object = base(key, "float", label);
        object.addProperty("value", value);
        return object;
    }

    private JsonObject toggle(String key, String label, boolean value) {
        JsonObject object = base(key, "toggle", label);
        object.addProperty("value", value);
        return object;
    }

    private JsonObject select(String key, String label, JsonArray options, String value) {
        JsonObject object = base(key, "select", label);
        object.add("options", options);
        object.addProperty("value", value == null ? "" : value);
        return object;
    }

    private JsonObject select(String key, String label, JsonArray options, int value) {
        JsonObject object = base(key, "select", label);
        object.add("options", options);
        object.addProperty("value", value);
        return object;
    }

    private String joinLines(List<String> values) {
        return String.join("\n", values);
    }

    private List<String> splitLines(String value) {
        List<String> result = new ArrayList<>();
        if (value == null) return result;
        for (String part : value.split("[\\r\\n,;]+")) {
            String trimmed = part.trim();
            if (!trimmed.isEmpty() && !result.contains(trimmed)) result.add(trimmed);
        }
        return result;
    }

    private Response error(Response.Status status, String message) {
        JsonObject object = new JsonObject();
        object.addProperty("ok", false);
        object.addProperty("message", message == null ? "" : message);
        return NanoHTTPD.newFixedLengthResponse(status, "application/json; charset=utf-8", object.toString());
    }

    private Response json(JsonObject object) {
        return NanoHTTPD.newFixedLengthResponse(Response.Status.OK, "application/json; charset=utf-8", object.toString());
    }
}
