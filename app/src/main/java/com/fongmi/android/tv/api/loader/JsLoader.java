package com.fongmi.android.tv.api.loader;

import com.fongmi.android.tv.App;
import com.fongmi.quickjs.crawler.Loader;
import com.fongmi.quickjs.utils.Module;
import com.github.catvod.crawler.Spider;
import com.github.catvod.crawler.SpiderDebug;
import com.github.catvod.crawler.SpiderNull;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

public class JsLoader {

    private final Map<String, Spider> spiders;
    private final Loader loader;
    private volatile String recent;

    public JsLoader() {
        spiders = new ConcurrentHashMap<>();
        Loader l = null;
        try {
            l = new Loader();
        } catch (Throwable t) {
            // QuickJS native runtime may fail to load on some API levels.
            // Degrade gracefully so BaseLoader initialization never crashes.
            t.printStackTrace();
        }
        loader = l;
    }

    public boolean isAvailable() {
        return loader != null;
    }

    public void clear() {
        spiders.values().forEach(Spider::destroy);
        Module.get().clear();
        spiders.clear();
        recent = null;
    }

    public void setRecent(String recent) {
        this.recent = recent;
    }

    public Spider getSpider(String key, String api, String ext, String jar) {
        if (loader == null) return new SpiderNull();
        // ConcurrentHashMap.computeIfAbsent 是 Java 8 / API 24 才有的方法，Android 6.0
        // (API 23) 上会抛 NoSuchMethodError；用 synchronized + get/put 等价实现，
        // 保留“同一 key 只创建一次”的原子语义。
        synchronized (spiders) {
            Spider cached = spiders.get(key);
            if (cached != null) return cached;
            Spider spider = createSpider(key, api, ext, jar);
            spiders.put(key, spider);
            return spider;
        }
    }

    private Spider createSpider(String key, String api, String ext, String jar) {
        try {
            Spider spider = loader.spider(api, BaseLoader.get().dex(jar));
            spider.siteKey = key;
            spider.init(App.get(), ext);
            return spider;
        } catch (Throwable e) {
            SpiderDebug.log("JsLoader", "JS spider init failed: key=%s api=%s", key, api);
            SpiderDebug.log("JsLoader", e);
            e.printStackTrace();
            return new SpiderNull();
        }
    }

    public Object[] proxy(Map<String, String> params) throws Exception {
        if (recent == null || loader == null) return null;
        Spider spider = spiders.get(recent);
        return spider != null ? spider.proxy(params) : null;
    }
}
