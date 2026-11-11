use crate::config::Settings;
use crate::cookies::CookieJar;
use crate::transport;
use std::time::{Duration, Instant};

pub const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36";

pub fn referer(settings: &Settings) -> String {
    format!("{}/", settings.domain.trim_end_matches('/'))
}

pub fn url_for(settings: &Settings, path: &str, page: u32) -> Result<String, String> {
    let path = path.trim();
    let base = format!("{}/", settings.domain.trim_end_matches('/'));
    let mut base_url = url::Url::parse(&base).map_err(|e| format!("站点地址无效：{e}"))?;

    let mut url = if path.starts_with("http://") || path.starts_with("https://") {
        let parsed = url::Url::parse(path).map_err(|e| format!("页面地址无效：{e}"))?;
        let base_host = base_url.host_str().unwrap_or("").to_ascii_lowercase();
        let target_host = parsed.host_str().unwrap_or("").to_ascii_lowercase();
        if !target_host.ends_with("pornhub.com") && target_host != base_host {
            return Err("非法的页面地址".into());
        }
        base_url.set_path(parsed.path());
        base_url.set_query(parsed.query());
        base_url
    } else {
        let clean_path = if path.starts_with('/') {
            path
        } else {
            &format!("/{path}")
        };
        if clean_path.starts_with("//") {
            return Err("非法的页面路径".into());
        }
        base_url
            .join(clean_path)
            .map_err(|e| format!("页面地址无效：{e}"))?
    };

    if page > 1 {
        url.query_pairs_mut().append_pair("page", &page.to_string());
    }
    Ok(url.to_string())
}

fn browser_headers(settings: &Settings, jar: &CookieJar, url: &str) -> Vec<(String, String)> {
    let mut headers = vec![
        ("Referer".to_string(), referer(settings)),
        (
            "Accept".to_string(),
            "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"
                .to_string(),
        ),
        (
            "Accept-Language".to_string(),
            "zh-CN,zh;q=0.9,en;q=0.8".to_string(),
        ),
    ];
    if let Some(cookie) = jar.cookie_header(url) {
        headers.push(("Cookie".to_string(), cookie));
    }
    headers
}

fn absorb_cookies(jar: &CookieJar, response: &transport::Response) {
    for raw in response.set_cookies() {
        jar.apply_set_cookie(&response.url, &raw);
    }
}

fn status_error(status: u16) -> String {
    match status {
        403 => "站点返回 403（访问被拒绝）。请检查代理节点是否可用，或稍后重试".into(),
        404 => "页面不存在（404），链接可能已失效".into(),
        429 => "请求过于频繁，请稍后再试".into(),
        451 => "该内容在当前地区不可用".into(),
        500..=599 => format!("站点服务器错误（HTTP {status}），请稍后重试"),
        _ => format!("站点返回 HTTP {status}"),
    }
}

pub async fn fetch_text(
    settings: &Settings,
    jar: &CookieJar,
    url: &str,
) -> Result<(String, String), String> {
    let mut last_err = String::new();
    for attempt in 0..2 {
        let headers = browser_headers(settings, jar, url);
        match transport::request(settings, "GET", url, &headers, None).await {
            Ok(res) => {
                absorb_cookies(jar, &res);
                if (200..300).contains(&res.status) {
                    let final_url = res.url.clone();
                    return Ok((final_url, res.text()));
                }
                last_err = status_error(res.status);
                if res.status < 500 {
                    return Err(last_err);
                }
            }
            Err(err) => last_err = err,
        }
        if attempt == 0 {
            tokio::time::sleep(Duration::from_millis(400)).await;
        }
    }
    Err(last_err)
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TestResult {
    pub ok: bool,
    pub ms: u64,
    pub message: String,
    pub logged_in: bool,
}

pub async fn test(settings: &Settings, jar: &CookieJar) -> TestResult {
    let started = Instant::now();
    let url = format!("{}/", settings.domain.trim_end_matches('/'));
    match fetch_text(settings, jar, &url).await {
        Ok((_, html)) => {
            let logged_in = crate::parse::is_logged_in(&html);
            TestResult {
                ok: true,
                ms: started.elapsed().as_millis() as u64,
                message: if logged_in {
                    "连接正常，账号已登录".into()
                } else {
                    "连接正常".into()
                },
                logged_in,
            }
        }
        Err(message) => TestResult {
            ok: false,
            ms: started.elapsed().as_millis() as u64,
            message,
            logged_in: false,
        },
    }
}
