package com.fongmi.android.tv.server.process;

import android.text.TextUtils;

import com.fongmi.android.tv.App;
import com.fongmi.android.tv.api.config.VodConfig;
import com.fongmi.android.tv.event.RefreshEvent;
import com.fongmi.android.tv.server.impl.Process;
import com.fongmi.android.tv.setting.ProxySetting;
import com.fongmi.android.tv.setting.Setting;
import com.github.catvod.crawler.SpiderDebug;
import com.github.catvod.net.OkHttp;
import com.github.catvod.bean.Doh;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;

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
 *   POST /setting/save    -> {"values":{key:value}} apply and hot-reload (JSON)
 *
 * The static page is served by {@link com.fongmi.android.tv.server.Nano} from
 * assets as "setting.html" for the bare "/setting" URL.
 */
public class SettingApi implements Process {

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
        groups.add(group("network", "网络与接口",
                select("doh", "安全 DNS (DoH)", dohOptions(), Setting.getDoh()),
                toggle("shell_proxy", "启用自定义代理", Setting.isShellProxy()),
                text("shell_proxy_url", "代理地址", Setting.getShellProxyUrl()),
                textarea("shell_proxy_rules", "代理规则", Setting.getShellProxyRules())
        ));
        groups.add(group("interface", "界面与显示",
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
        groups.add(group("playback", "播放与筛选",
                number("site_mode", "站点模式", Setting.getSiteMode()),
                toggle("site_health_sort", "站点健康排序", Setting.isSiteHealthSort()),
                toggle("site_health_dialog_sort", "站点健康弹窗排序", Setting.isSiteHealthDialogSort()),
                toggle("incognito", "隐身模式", Setting.isIncognito()),
                toggle("adblock", "广告过滤", Setting.isAdblock()),
                toggle("drive_check", "网盘有效性检测", Setting.isDriveCheck()),
                toggle("csp_warmup", "CSP 预热", Setting.isCspWarmup()),
                select("csp_warmup_mode", "CSP 预热模式", intOptions("1:默认", "2:自定义"), Setting.getCspWarmupSelectedMode())
        ));
        groups.add(group("advanced", "更新与调试",
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
            switch (key) {
                case "wall", "wall_color", "theme_color" -> theme = true;
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
                case "doh" -> { String v = value.getAsString(); Setting.putDoh(v); try { OkHttp.dns().setDoh(Doh.objectFrom(v)); } catch (Throwable ignored) {} }
                case "shell_proxy" -> Setting.putShellProxy(value.getAsBoolean());
                case "shell_proxy_url" -> Setting.putShellProxyUrl(value.getAsString());
                case "shell_proxy_rules" -> Setting.putShellProxyRules(value.getAsString());
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
                case "site_mode" -> Setting.putSiteMode(value.getAsInt());
                case "site_health_sort" -> Setting.putSiteHealthSort(value.getAsBoolean());
                case "site_health_dialog_sort" -> Setting.putSiteHealthDialogSort(value.getAsBoolean());
                case "incognito" -> Setting.putIncognito(value.getAsBoolean());
                case "adblock" -> Setting.putAdblock(value.getAsBoolean());
                case "drive_check" -> Setting.putDriveCheck(value.getAsBoolean());
                case "csp_warmup" -> Setting.putCspWarmup(value.getAsBoolean());
                case "csp_warmup_mode" -> Setting.putCspWarmupMode(value.getAsInt());
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
                "csp_warmup_mode", "update", "update_source", "debug_log");
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

    private JsonObject group(String id, String title, JsonObject... fields) {
        JsonObject object = new JsonObject();
        object.addProperty("id", id);
        object.addProperty("title", title);
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
