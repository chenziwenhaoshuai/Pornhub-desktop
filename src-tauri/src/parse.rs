use scraper::{ElementRef, Html, Selector};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct VideoItem {
    pub vkey: String,
    pub title: String,
    pub thumb: String,
    pub duration: String,
    pub views: String,
    pub author: String,
    pub href: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Home {
    pub items: Vec<VideoItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Category {
    pub id: String,
    pub name: String,
    pub count: String,
    pub thumb: String,
    pub href: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Categories {
    pub items: Vec<Category>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Listing {
    pub title: String,
    pub items: Vec<VideoItem>,
    pub current: u32,
    pub pages: Vec<u32>,
    pub next_href: Option<String>,
    pub prev_href: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Link {
    pub name: String,
    pub href: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Source {
    pub quality: String,
    pub height: u64,
    pub format: String,
    pub url: String,
    #[serde(rename = "isDefault")]
    pub is_default: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct VideoDetail {
    pub vkey: String,
    pub title: String,
    pub views: String,
    pub publish: String,
    pub duration: u64,
    pub author: String,
    pub author_href: String,
    pub avatar: String,
    pub image: String,
    pub categories: Vec<Link>,
    pub tags: Vec<Link>,
    pub sources: Vec<Source>,
    pub related: Vec<VideoItem>,
    pub unavailable: bool,
    pub url: String,
}

fn sel(s: &str) -> Selector {
    Selector::parse(s).expect("invalid selector")
}

fn collapse(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn text_of(el: &ElementRef) -> String {
    collapse(&el.text().collect::<Vec<_>>().join(" "))
}

fn attr(el: &ElementRef, name: &str) -> String {
    el.value().attr(name).unwrap_or("").trim().to_string()
}

pub fn abs(domain: &str, href: &str) -> String {
    let href = href.trim();
    if href.starts_with("http://") || href.starts_with("https://") {
        return href.to_string();
    }
    if href.starts_with("//") {
        return format!("https:{href}");
    }
    let domain = domain.trim_end_matches('/');
    if href.starts_with('/') {
        format!("{domain}{href}")
    } else {
        format!("{domain}/{href}")
    }
}

fn clean_thumb(raw: &str) -> String {
    let raw = raw.trim();
    if raw.starts_with("data:") || raw.is_empty() {
        String::new()
    } else if raw.starts_with("//") {
        format!("https:{raw}")
    } else {
        raw.to_string()
    }
}

fn parse_items(root: ElementRef, domain: &str) -> Vec<VideoItem> {
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for el in root.select(&sel("li[data-video-vkey]")) {
        let vkey = attr(&el, "data-video-vkey");
        if vkey.is_empty() || !seen.insert(vkey.clone()) {
            continue;
        }
        let anchor = el.select(&sel("a[href*=\"viewkey=\"]")).next();
        let href = anchor.as_ref().map(|a| attr(a, "href")).unwrap_or_default();
        if href.is_empty() {
            continue;
        }
        let title = anchor
            .as_ref()
            .and_then(|a| a.value().attr("title"))
            .map(|s| collapse(s))
            .filter(|s| !s.is_empty())
            .or_else(|| anchor.as_ref().map(text_of))
            .unwrap_or_default();

        let img = el.select(&sel("img")).next();
        let thumb = img
            .as_ref()
            .map(|i| {
                let candidates = ["data-mediumthumb", "data-image", "src"];
                candidates
                    .iter()
                    .map(|k| clean_thumb(&attr(i, k)))
                    .find(|v| !v.is_empty())
                    .unwrap_or_default()
            })
            .unwrap_or_default();

        let duration = el
            .select(&sel(".duration"))
            .next()
            .map(|e| text_of(&e))
            .unwrap_or_default();
        let views = el
            .select(&sel(".views"))
            .next()
            .map(|e| text_of(&e))
            .unwrap_or_default();
        let author = el
            .select(&sel(".videoUploaderBlock a"))
            .next()
            .map(|e| text_of(&e))
            .unwrap_or_default();

        out.push(VideoItem {
            vkey,
            title,
            thumb,
            duration,
            views,
            author,
            href: abs(domain, &href),
        });
    }
    out
}

pub fn parse_home(html: &str, domain: &str) -> Home {
    let doc = Html::parse_document(html);
    let root = doc
        .select(&sel("#singleFeedSection"))
        .next()
        .or_else(|| doc.select(&sel(".frontListingWrapper")).next());
    let items = match root {
        Some(el) => parse_items(el, domain),
        None => parse_items(doc.root_element(), domain),
    };
    Home { items }
}

fn best_container(doc: &Html) -> Option<ElementRef<'_>> {
    if let Some(el) = doc.select(&sel("#singleFeedSection")).next() {
        return Some(el);
    }
    let mut best: Option<(usize, ElementRef)> = None;
    for el in doc.select(&sel("ul.nf-videos")) {
        let count = el.select(&sel("li[data-video-vkey]")).count();
        if count > 0 && best.as_ref().map(|(n, _)| count > *n).unwrap_or(true) {
            best = Some((count, el));
        }
    }
    best.map(|(_, el)| el)
}

pub fn parse_listing(html: &str, domain: &str) -> Listing {
    let doc = Html::parse_document(html);
    let items = best_container(&doc)
        .map(|el| parse_items(el, domain))
        .unwrap_or_default();

    let title = doc
        .select(&sel("h1"))
        .next()
        .map(|e| text_of(&e))
        .unwrap_or_default();

    let current = doc
        .select(&sel(".page_current"))
        .next()
        .map(|e| text_of(&e))
        .and_then(|t| t.parse::<u32>().ok())
        .unwrap_or(1);

    let mut pages: Vec<u32> = doc
        .select(&sel(".page_number a"))
        .filter_map(|e| text_of(&e).parse::<u32>().ok())
        .collect();
    pages.sort_unstable();
    pages.dedup();

    let next_href = doc
        .select(&sel(".page_next a"))
        .next()
        .map(|e| attr(&e, "href"))
        .filter(|h| !h.is_empty());
    let prev_href = doc
        .select(&sel(".page_previous a"))
        .next()
        .filter(|e| {
            e.parent()
                .and_then(ElementRef::wrap)
                .map(|p| !p.attr("class").unwrap_or("").contains("disabled"))
                .unwrap_or(true)
        })
        .map(|e| attr(&e, "href"))
        .filter(|h| !h.is_empty());

    Listing {
        title,
        items,
        current,
        pages,
        next_href,
        prev_href,
    }
}

pub fn parse_categories(html: &str, domain: &str) -> Categories {
    let doc = Html::parse_document(html);
    let mut items = Vec::new();
    for el in doc.select(&sel("li.catPic")) {
        let id = attr(&el, "data-category");
        let anchor = el.select(&sel("a[href*=\"c=\"]")).next();
        let href = anchor.as_ref().map(|a| attr(a, "href")).unwrap_or_default();
        if id.is_empty() || href.is_empty() {
            continue;
        }
        let name = el
            .select(&sel("strong"))
            .next()
            .map(|e| text_of(&e))
            .filter(|s| !s.is_empty())
            .or_else(|| {
                el.select(&sel("img")).next().and_then(|img| {
                    let alt = attr(&img, "alt");
                    let cleaned = alt
                        .replace("色情类别", "")
                        .replace("Porn Category", "")
                        .trim()
                        .to_string();
                    if cleaned.is_empty() {
                        None
                    } else {
                        Some(cleaned)
                    }
                })
            })
            .unwrap_or_default();
        let count = el
            .select(&sel(".videoCount"))
            .next()
            .map(|e| text_of(&e))
            .unwrap_or_default();
        let thumb = el
            .select(&sel("img"))
            .next()
            .map(|i| {
                let p = attr(&i, "data-path");
                if p.is_empty() {
                    clean_thumb(&attr(&i, "src"))
                } else {
                    clean_thumb(&p)
                }
            })
            .unwrap_or_default();

        items.push(Category {
            id,
            name,
            count,
            thumb,
            href: abs(domain, &href),
        });
    }
    Categories { items }
}

fn balanced(html: &str, start: usize, open: u8, close: u8) -> Option<&str> {
    let bytes = html.as_bytes();
    let mut depth = 0i32;
    let mut in_str = false;
    let mut esc = false;
    for i in start..bytes.len() {
        let c = bytes[i];
        if in_str {
            if esc {
                esc = false;
            } else if c == b'\\' {
                esc = true;
            } else if c == b'"' {
                in_str = false;
            }
            continue;
        }
        if c == b'"' {
            in_str = true;
        } else if c == open {
            depth += 1;
        } else if c == close {
            depth -= 1;
            if depth == 0 {
                return html.get(start..=i);
            }
        }
    }
    None
}

fn flashvars(html: &str) -> Option<Value> {
    let marker = "var flashvars_";
    let idx = html.find(marker)?;
    let brace = html[idx..].find('{')? + idx;
    let raw = balanced(html, brace, b'{', b'}')?;
    serde_json::from_str::<Value>(raw).ok()
}

fn media_definitions(html: &str, flash: Option<&Value>) -> Vec<Value> {
    if let Some(defs) = flash
        .and_then(|f| f.get("mediaDefinitions"))
        .and_then(|d| d.as_array())
    {
        return defs.clone();
    }
    let marker = "\"mediaDefinitions\"";
    if let Some(idx) = html.find(marker) {
        if let Some(bracket) = html[idx..].find('[').map(|i| i + idx) {
            if let Some(raw) = balanced(html, bracket, b'[', b']') {
                if let Ok(defs) = serde_json::from_str::<Vec<Value>>(raw) {
                    return defs;
                }
            }
        }
    }
    Vec::new()
}

fn json_str(v: &Value, key: &str) -> String {
    v.get(key)
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .trim()
        .to_string()
}

pub fn parse_video(html: &str, domain: &str, vkey: &str) -> Result<VideoDetail, String> {
    let doc = Html::parse_document(html);
    let flash = flashvars(html);

    let h1 = doc
        .select(&sel("h1.title, h1"))
        .next()
        .map(|e| text_of(&e))
        .unwrap_or_default();

    let mut title = flash
        .as_ref()
        .map(|f| {
            let translated = json_str(f, "videoTitleTranslated");
            if translated.is_empty() {
                json_str(f, "video_title")
            } else {
                translated
            }
        })
        .unwrap_or_default();
    if title.is_empty() {
        title = h1;
    }

    let duration = flash
        .as_ref()
        .and_then(|f| f.get("video_duration"))
        .and_then(|d| d.as_u64())
        .unwrap_or(0);

    let views = doc
        .select(&sel(".views span.count"))
        .next()
        .map(|e| text_of(&e))
        .or_else(|| doc.select(&sel(".views")).next().map(|e| text_of(&e)))
        .unwrap_or_default();

    let publish = doc
        .select(&sel(".videoInfo"))
        .next()
        .map(|e| text_of(&e))
        .unwrap_or_default();

    let author_el = doc.select(&sel(".userInfo .usernameWrap a")).next();
    let author = author_el.as_ref().map(text_of).unwrap_or_default();
    let author_href = author_el
        .as_ref()
        .map(|e| abs(domain, &attr(e, "href")))
        .unwrap_or_default();

    let avatar = doc
        .select(&sel(".userAvatar img"))
        .next()
        .map(|e| clean_thumb(&attr(&e, "src")))
        .unwrap_or_default();

    let image = flash
        .as_ref()
        .map(|f| clean_thumb(&json_str(f, "image_url")))
        .unwrap_or_default();

    let mut categories = Vec::new();
    for el in doc.select(&sel(".categoriesWrapper a")) {
        let name = text_of(&el);
        if !name.is_empty() {
            categories.push(Link {
                name,
                href: abs(domain, &attr(&el, "href")),
            });
        }
    }

    let mut tags = Vec::new();
    for el in doc.select(&sel(".tagsWrapper a")) {
        let name = text_of(&el);
        if !name.is_empty() {
            tags.push(Link {
                name,
                href: abs(domain, &attr(&el, "href")),
            });
        }
    }

    let defs = media_definitions(html, flash.as_ref());
    let mut sources: Vec<Source> = Vec::new();
    for d in defs.iter() {
        let format = json_str(d, "format");
        let url = d.get("videoUrl").and_then(|x| x.as_str()).unwrap_or("");
        if url.is_empty() || !(url.starts_with("http://") || url.starts_with("https://")) {
            continue;
        }
        if url.contains("/video/get_media") {
            continue;
        }
        if !format.is_empty() && format != "hls" && format != "mp4" {
            continue;
        }
        let height = d.get("height").and_then(|x| x.as_u64()).unwrap_or(0);
        let quality = d
            .get("quality")
            .map(|q| match q {
                Value::String(s) => s.clone(),
                Value::Number(n) => n.to_string(),
                _ => String::new(),
            })
            .unwrap_or_default();
        if sources
            .iter()
            .any(|s| s.url == url && s.height == height)
        {
            continue;
        }
        sources.push(Source {
            quality,
            height,
            format,
            url: url.to_string(),
            is_default: d
                .get("defaultQuality")
                .and_then(|x| x.as_bool())
                .unwrap_or(false),
        });
    }
    sources.sort_by(|a, b| b.height.cmp(&a.height));

    let mut related = doc
        .select(&sel("#relatedVideosListing"))
        .next()
        .map(|el| parse_items(el, domain))
        .unwrap_or_default();
    related.retain(|item| item.vkey != vkey);
    related.truncate(30);

    let unavailable_flag = flash
        .as_ref()
        .and_then(|f| f.get("video_unavailable"))
        .map(|v| v.as_i64().unwrap_or(0) != 0 || v.as_bool().unwrap_or(false))
        .unwrap_or(false);

    let unavailable = unavailable_flag || sources.is_empty();

    Ok(VideoDetail {
        vkey: vkey.to_string(),
        title,
        views,
        publish,
        duration,
        author,
        author_href,
        avatar,
        image,
        categories,
        tags,
        sources,
        related,
        unavailable,
        url: format!("{}/view_video.php?viewkey={}", domain.trim_end_matches('/'), vkey),
    })
}

pub fn is_logged_in(html: &str) -> bool {
    let compact = collapse(html);
    if compact.contains("isLoggedInUser = 1") || compact.contains("isLoggedInUser=1") {
        return true;
    }
    if compact.contains("isLoggedInUser = 0") || compact.contains("isLoggedInUser=0") {
        return false;
    }
    let doc = Html::parse_document(html);
    if let Some(body) = doc.select(&sel("body")).next() {
        let cls = body.value().attr("class").unwrap_or("").to_string();
        let has = |name: &str| cls.split_whitespace().any(|c| c == name);
        if has("logged-out") {
            return false;
        }
        if has("logged-in") {
            return true;
        }
    }
    false
}

pub fn parse_username(html: &str) -> String {
    let doc = Html::parse_document(html);
    if let Some(el) = doc
        .select(&sel("[data-user-nickname], #headerUserName, .userName, .headerUserName"))
        .next()
    {
        let nick = attr(&el, "data-user-nickname");
        if !nick.is_empty() {
            return nick;
        }
        let text = text_of(&el);
        if !text.is_empty() {
            return text;
        }
    }
    String::new()
}

pub fn parse_login_form(html: &str, domain: &str) -> Result<(String, String, String), String> {
    let doc = Html::parse_document(html);
    let form = doc
        .select(&sel("form.js-loginForm"))
        .next()
        .ok_or_else(|| "未能解析登录表单，站点结构可能已变化".to_string())?;
    let token = form
        .select(&sel("input[name=\"token\"]"))
        .next()
        .map(|e| attr(&e, "value"))
        .unwrap_or_default();
    if token.is_empty() {
        return Err("登录页缺少安全令牌，请稍后重试".into());
    }
    let redirect = form
        .select(&sel("input[name=\"redirect\"]"))
        .next()
        .map(|e| attr(&e, "value"))
        .unwrap_or_default();
    let from = form
        .select(&sel("input[name=\"from\"]"))
        .next()
        .map(|e| attr(&e, "value"))
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| "pc_login_modal_:login".into());
    let _ = domain;
    Ok((token, redirect, from))
}

pub fn validate_vkey(vkey: &str) -> bool {
    let len = vkey.len();
    (6..=32).contains(&len) && vkey.chars().all(|c| c.is_ascii_alphanumeric())
}
