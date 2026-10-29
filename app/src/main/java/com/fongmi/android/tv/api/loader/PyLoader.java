package com.fongmi.android.tv.api.loader;

import android.text.TextUtils;

import com.fongmi.android.tv.App;
import com.fongmi.chaquo.Loader;
import com.github.catvod.crawler.Spider;
import com.github.catvod.crawler.SpiderNull;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

public class PyLoader {

    private final Map<String, Spider> spiders;
    private final Loader loader;
    private volatile String recent;

    public PyLoader() {
        spiders = new ConcurrentHashMap<>();
        Loader l = null;
        try {
            l = new Loader();
        } catch (Throwable t) {
            // ChaQuoPy's native runtime (libchaquopy_java / libpython) requires
            // API 24+. On Android 6.0 (API 23) loading it throws
            // UnsatisfiedLinkError. Degrade gracefully so BaseLoader
            // initialization never crashes the app (video playback does not
            // depend on Python).
            t.printStackTrace();
        }
        loader = l;
    }

    public boolean isAvailable() {
        return loader != null;
    }

    public void clear() {
        spiders.values().forEach(Spider::destroy);
        spiders.clear();
        recent = null;
    }

    public void setRecent(String recent) {
        this.recent = recent;
    }

    public Spider getSpider(String key, String api, String ext) {
        if (loader == null) return new SpiderNull();
        // ConcurrentHashMap.computeIfAbsent 是 Java 8 / API 24 才有的方法，Android 6.0
        // (API 23) 上会抛 NoSuchMethodError；用 synchronized + get/put 等价实现。
        synchronized (spiders) {
            Spider cached = spiders.get(key);
            if (cached != null) return cached;
            Spider spider = createSpider(key, api, ext);
            spiders.put(key, spider);
            return spider;
        }
    }

    private Spider createSpider(String key, String api, String ext) {
        try {
            Spider spider = loader.spider(api);
            spider.siteKey = key;
            spider.init(App.get(), normalizeExt(ext));
            return spider;
        } catch (Throwable e) {
            e.printStackTrace();
            return new SpiderNull();
        }
    }

    private String normalizeExt(String ext) {
        String value = TextUtils.isEmpty(ext) ? "" : ext.trim();
        // Many live Python spiders treat ext as an option object and call .get().
        // TV-style configs commonly express an empty extension as [], which would
        // otherwise deserialize to a list and crash those spiders during init.
        return "[]".equals(value) ? "{}" : ext;
    }

    public Object[] proxy(Map<String, String> params) throws Exception {
        if (recent == null || loader == null) return null;
        Spider spider = spiders.get(recent);
        return spider != null ? spider.proxy(params) : null;
    }
}
