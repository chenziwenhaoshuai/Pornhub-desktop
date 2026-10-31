use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use ph_desktop::{api, cache, config, cookies, media, net, transport};
use std::sync::Arc;
use tokio::sync::RwLock;

fn enc(url: &str) -> String {
    URL_SAFE_NO_PAD.encode(url)
}

#[tokio::main]
async fn main() {
    let dir = std::env::temp_dir().join("ph-selftest");
    let _ = std::fs::create_dir_all(&dir);
    let settings = config::Settings::default();
    let jar = Arc::new(cookies::CookieJar::new(dir.join("cookies.json")));

    let test = net::test(&settings, &jar).await;
    println!("net.test ok={} ms={} msg={}", test.ok, test.ms, test.message);

    let home = api::home(&settings, &jar).await;
    match &home {
        Ok(h) => {
            println!("home items={}", h.items.len());
            for item in h.items.iter().take(3) {
                println!(
                    "  - {} | {} | dur={} | thumb={}",
                    item.vkey,
                    item.title.chars().take(36).collect::<String>(),
                    item.duration,
                    !item.thumb.is_empty()
                );
            }
        }
        Err(e) => println!("home FAIL: {e}"),
    }

    match api::categories(&settings, &jar).await {
        Ok(c) => println!("categories={} first={}", c.items.len(), c.items.first().map(|x| x.name.clone()).unwrap_or_default()),
        Err(e) => println!("categories FAIL: {e}"),
    }

    for path in ["/video?c=98", "/video?c=98&o=mv", "/video?o=ht"] {
        match api::listing(&settings, &jar, path, 2).await {
            Ok(l) => println!(
                "listing {path} title={} items={} current={} pages_first={:?}",
                l.title,
                l.items.len(),
                l.current,
                l.pages.first()
            ),
            Err(e) => println!("listing {path} FAIL: {e}"),
        }
    }

    let vkey = home
        .as_ref()
        .ok()
        .and_then(|h| h.items.first())
        .map(|i| i.vkey.clone());
    if let Some(vkey) = vkey {
        match api::video(&settings, &jar, &vkey).await {
            Ok(v) => {
                println!(
                    "video {} sources={} related={} unavailable={}",
                    v.vkey,
                    v.sources.len(),
                    v.related.len(),
                    v.unavailable
                );
                for s in &v.sources {
                    println!("  src {}p {} {}", s.height, s.format, s.quality);
                }
                if let Some(src) = v.sources.first() {
                    let media_settings = Arc::new(RwLock::new(settings.clone()));
                    let disk_cache = Arc::new(cache::DiskCache::new(
                        std::env::temp_dir().join("ph-selftest-media"),
                    ));
                    match media::start(media_settings, jar.clone(), disk_cache).await {
                        Ok(server) => {
                            let master = format!("{}/m?u={}", server.base, enc(&src.url));
                            match transport::request(&settings, "GET", &master, &[], None).await {
                                Ok(r) => {
                                    let text = r.text();
                                    let variant = text
                                        .lines()
                                        .map(|l| l.trim())
                                        .find(|l| !l.is_empty() && !l.starts_with('#'))
                                        .unwrap_or("")
                                        .to_string();
                                    println!(
                                        "media master status={} lines={} variant={}",
                                        r.status,
                                        text.lines().count(),
                                        variant.chars().take(90).collect::<String>()
                                    );
                                    if !variant.is_empty() {
                                        match transport::request(&settings, "GET", &variant, &[], None)
                                            .await
                                        {
                                            Ok(vr) => {
                                                let ct = vr.header("content-type").unwrap_or("").to_string();
                                                let body = vr.text();
                                                let seg = body
                                                    .lines()
                                                    .map(|l| l.trim())
                                                    .find(|l| !l.is_empty() && !l.starts_with('#'))
                                                    .unwrap_or("")
                                                    .to_string();
                                                println!(
                                                    "media variant status={} type={} lines={} seg={}",
                                                    vr.status,
                                                    ct,
                                                    body.lines().count(),
                                                    !seg.is_empty()
                                                );
                                                if !seg.is_empty() {
                                                    match transport::request(
                                                        &settings,
                                                        "GET",
                                                        &seg,
                                                        &[("Range".into(), "bytes=0-1023".into())],
                                                        None,
                                                    )
                                                    .await
                                                    {
                                                        Ok(sr) => println!(
                                                            "media segment status={} range={:?} bytes={}",
                                                            sr.status,
                                                            sr.header("content-range"),
                                                            sr.body.len()
                                                        ),
                                                        Err(e) => println!("segment FAIL: {e}"),
                                                    }
                                                }
                                            }
                                            Err(e) => println!("variant FAIL: {e}"),
                                        }
                                    }
                                }
                                Err(e) => println!("master FAIL: {e}"),
                            }
                        }
                        Err(e) => println!("media server FAIL: {e}"),
                    }
                }
            }
            Err(e) => println!("video FAIL: {e}"),
        }
    }

    let login_url = format!("{}/login", settings.domain);
    match net::fetch_text(&settings, &jar, &login_url).await {
        Ok((_, html)) => match ph_desktop::parse::parse_login_form(&html, &settings.domain) {
            Ok((token, redirect, from)) => println!(
                "login form token_len={} redirect_len={} from={}",
                token.len(),
                redirect.len(),
                from
            ),
            Err(e) => println!("login form FAIL: {e}"),
        },
        Err(e) => println!("login page FAIL: {e}"),
    }

    println!("selftest done");
}
