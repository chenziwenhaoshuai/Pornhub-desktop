use axum::{
    body::Body,
    extract::{Path, Query, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use serde::Deserialize;
use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use tokio::sync::{Mutex, RwLock};

use crate::cache::{CachedEntry, DiskCache};
use crate::config::Settings;
use crate::cookies::CookieJar;
use crate::transport;

#[derive(Clone)]
struct MediaState {
    settings: Arc<RwLock<Settings>>,
    jar: Arc<CookieJar>,
    cache: Arc<DiskCache>,
    token: String,
    prefix: String,
    images: Arc<Mutex<ImageCache>>,
}

pub struct MediaServer {
    pub base: String,
}

#[derive(Deserialize)]
struct ProxyQuery {
    u: String,
}

pub async fn start(
    settings: Arc<RwLock<Settings>>,
    jar: Arc<CookieJar>,
    cache: Arc<DiskCache>,
) -> Result<MediaServer, String> {
    let token = uuid::Uuid::new_v4().simple().to_string();
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0u16))
        .await
        .map_err(|e| format!("本地播放服务启动失败：{e}"))?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("本地播放服务启动失败：{e}"))?
        .port();
    let prefix = format!("http://127.0.0.1:{port}/{token}");
    let state = MediaState {
        settings,
        jar,
        cache,
        token: token.clone(),
        prefix: prefix.clone(),
        images: Arc::new(Mutex::new(ImageCache::new(64 * 1024 * 1024))),
    };

    let app = Router::new()
        .route("/{token}/m", get(media_handler).options(preflight))
        .route("/{token}/i", get(image_handler).options(preflight))
        .with_state(state);

    tauri::async_runtime::spawn(async move {
        if let Err(err) = axum::serve(listener, app).await {
            eprintln!("[media] server stopped: {err}");
        }
    });

    Ok(MediaServer { base: prefix })
}

async fn preflight() -> Response {
    (
        [
            (header::ACCESS_CONTROL_ALLOW_ORIGIN, "*"),
            (header::ACCESS_CONTROL_ALLOW_HEADERS, "*"),
            (header::ACCESS_CONTROL_ALLOW_METHODS, "GET, HEAD, OPTIONS"),
            (header::ACCESS_CONTROL_MAX_AGE, "86400"),
        ],
        StatusCode::NO_CONTENT,
    )
        .into_response()
}

fn error(status: StatusCode, message: &str) -> Response {
    let mut res = (status, message.to_string()).into_response();
    res.headers_mut().insert(
        header::ACCESS_CONTROL_ALLOW_ORIGIN,
        HeaderValue::from_static("*"),
    );
    res
}

fn coded_error(message: &str) -> Response {
    error(StatusCode::BAD_GATEWAY, message)
}

fn decode_target(raw: &str) -> Result<url::Url, String> {
    let encoded = raw.trim();
    let bytes = URL_SAFE_NO_PAD
        .decode(encoded.trim_end_matches('='))
        .map_err(|_| "无效的媒体地址".to_string())?;
    let text = String::from_utf8(bytes).map_err(|_| "无效的媒体地址".to_string())?;
    let url = url::Url::parse(&text).map_err(|_| "无效的媒体地址".to_string())?;
    if url.scheme() != "http" && url.scheme() != "https" {
        return Err("不支持的协议".into());
    }
    Ok(url)
}

fn is_playlist_url(url: &str, content_type: &str) -> bool {
    content_type.to_ascii_lowercase().contains("mpegurl")
        || url.to_ascii_lowercase().contains(".m3u8")
}

fn playlist_response(text: &str, base: &url::Url, prefix: &str) -> Response {
    let rewritten = rewrite_playlist(text, base, prefix);
    Response::builder()
        .status(StatusCode::OK)
        .header(
            header::CONTENT_TYPE,
            "application/vnd.apple.mpegurl; charset=utf-8",
        )
        .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
        .header(header::CACHE_CONTROL, "no-store")
        .body(Body::from(rewritten))
        .unwrap_or_else(|_| coded_error("构建响应失败"))
}

fn parse_range(raw: &str, len: usize) -> Option<(usize, usize)> {
    let spec = raw.trim().strip_prefix("bytes=")?;
    let (start_s, end_s) = spec.split_once('-')?;
    let start = start_s.trim().parse::<usize>().ok()?;
    let end = if end_s.trim().is_empty() {
        len.saturating_sub(1)
    } else {
        end_s.trim().parse::<usize>().ok()?.min(len.saturating_sub(1))
    };
    if start > end || start >= len {
        return None;
    }
    Some((start, end))
}

fn cached_media_response(
    entry: CachedEntry,
    upstream: &url::Url,
    prefix: &str,
    range: Option<&str>,
) -> Response {
    if is_playlist_url(upstream.as_str(), &entry.content_type) {
        return playlist_response(&String::from_utf8_lossy(&entry.bytes), upstream, prefix);
    }
    let total = entry.bytes.len();
    let content_type = if entry.content_type.is_empty() {
        "application/octet-stream".to_string()
    } else {
        entry.content_type
    };
    if let Some((start, end)) = range.and_then(|value| parse_range(value, total)) {
        let slice = entry.bytes[start..=end].to_vec();
        return Response::builder()
            .status(StatusCode::PARTIAL_CONTENT)
            .header(header::CONTENT_TYPE, content_type)
            .header(header::ACCEPT_RANGES, "bytes")
            .header(
                header::CONTENT_RANGE,
                format!("bytes {start}-{end}/{total}"),
            )
            .header(header::CONTENT_LENGTH, (end - start + 1).to_string())
            .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
            .header(header::CACHE_CONTROL, "public, max-age=86400")
            .body(Body::from(slice))
            .unwrap_or_else(|_| coded_error("构建响应失败"));
    }
    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, content_type)
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CONTENT_LENGTH, total.to_string())
        .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
        .header(header::CACHE_CONTROL, "public, max-age=86400")
        .body(Body::from(entry.bytes))
        .unwrap_or_else(|_| coded_error("构建响应失败"))
}

async fn media_handler(
    Path(token): Path<String>,
    Query(query): Query<ProxyQuery>,
    State(state): State<MediaState>,
    headers: HeaderMap,
) -> Response {
    if token != state.token {
        return error(StatusCode::FORBIDDEN, "forbidden");
    }
    let upstream = match decode_target(&query.u) {
        Ok(url) => url,
        Err(err) => return error(StatusCode::BAD_REQUEST, &err),
    };
    let range = headers
        .get(header::RANGE)
        .and_then(|v| v.to_str().ok())
        .map(|v| v.to_string());

    if let Some(entry) = state.cache.get(upstream.as_str()) {
        return cached_media_response(entry, &upstream, &state.prefix, range.as_deref());
    }

    let settings = state.settings.read().await.clone();
    let referer = format!("{}/", settings.domain.trim_end_matches('/'));

    let mut request_headers = vec![
        ("Referer".to_string(), referer),
        ("Accept".to_string(), "*/*".to_string()),
        ("Origin".to_string(), settings.domain.trim_end_matches('/').to_string()),
    ];
    if let Some(range) = &range {
        request_headers.push(("Range".to_string(), range.clone()));
    }
    if let Some(cookie) = state.jar.cookie_header(upstream.as_str()) {
        request_headers.push(("Cookie".to_string(), cookie));
    }

    let response = match transport::request(
        &settings,
        "GET",
        upstream.as_str(),
        &request_headers,
        None,
    )
    .await
    {
        Ok(res) => res,
        Err(err) => return coded_error(&format!("上游请求失败：{err}")),
    };

    let status = StatusCode::from_u16(response.status).unwrap_or(StatusCode::BAD_GATEWAY);
    let content_type = response
        .header(header::CONTENT_TYPE.as_str())
        .unwrap_or("")
        .to_string();

    if is_playlist_url(upstream.as_str(), &content_type)
        || response.url.to_ascii_lowercase().contains(".m3u8")
    {
        let base = url::Url::parse(&response.url).unwrap_or_else(|_| upstream.clone());
        let text = response.text();
        if (200..300).contains(&status.as_u16()) {
            state.cache.put(
                upstream.as_str(),
                status.as_u16(),
                "application/vnd.apple.mpegurl",
                text.as_bytes(),
            );
        }
        return playlist_response(&text, &base, &state.prefix);
    }

    if status == StatusCode::OK && !response.body.is_empty() {
        state
            .cache
            .put(upstream.as_str(), 200, &content_type, &response.body);
    }

    let mut builder = Response::builder()
        .status(status)
        .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
        .header(
            header::ACCESS_CONTROL_EXPOSE_HEADERS,
            "Content-Length, Content-Range, Accept-Ranges, Content-Type",
        )
        .header(header::CACHE_CONTROL, "public, max-age=86400");

    for name in [
        header::CONTENT_TYPE,
        header::CONTENT_LENGTH,
        header::CONTENT_RANGE,
        header::ACCEPT_RANGES,
        header::ETAG,
        header::LAST_MODIFIED,
    ] {
        if let Some(value) = response.header(name.as_str()) {
            if let Ok(hv) = HeaderValue::from_str(value) {
                builder = builder.header(name, hv);
            }
        }
    }

    builder
        .body(Body::from(response.body))
        .unwrap_or_else(|_| coded_error("构建响应失败"))
}

async fn image_handler(
    Path(token): Path<String>,
    Query(query): Query<ProxyQuery>,
    State(state): State<MediaState>,
) -> Response {
    if token != state.token {
        return error(StatusCode::FORBIDDEN, "forbidden");
    }
    let upstream = match decode_target(&query.u) {
        Ok(url) => url,
        Err(err) => return error(StatusCode::BAD_REQUEST, &err),
    };
    let key = upstream.to_string();

    if let Some((bytes, content_type)) = state.images.lock().await.get(&key) {
        return image_response(bytes, &content_type);
    }

    let settings = state.settings.read().await.clone();
    let mut request_headers = vec![
        (
            "Referer".to_string(),
            format!("{}/", settings.domain.trim_end_matches('/')),
        ),
        (
            "Accept".to_string(),
            "image/avif,image/webp,image/apng,image/*,*/*;q=0.8".to_string(),
        ),
    ];
    if let Some(cookie) = state.jar.cookie_header(upstream.as_str()) {
        request_headers.push(("Cookie".to_string(), cookie));
    }

    let response = match transport::request_with_kind(
        &settings,
        "GET",
        upstream.as_str(),
        &request_headers,
        None,
        transport::RequestKind::Image,
    )
    .await
    {
        Ok(res) => res,
        Err(err) => return coded_error(&format!("图片请求失败：{err}")),
    };

    if !(200..300).contains(&response.status) {
        return coded_error(&format!("图片返回 HTTP {}", response.status));
    }

    let content_type = response
        .header(header::CONTENT_TYPE.as_str())
        .unwrap_or("image/jpeg")
        .to_string();
    let bytes = response.body;

    if bytes.len() <= 4 * 1024 * 1024 {
        state
            .images
            .lock()
            .await
            .put(key, bytes.clone(), content_type.clone());
    }

    image_response(bytes, &content_type)
}

fn image_response(bytes: Vec<u8>, content_type: &str) -> Response {
    let mut builder = Response::builder()
        .status(StatusCode::OK)
        .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
        .header(header::CACHE_CONTROL, "public, max-age=21600");
    if let Ok(hv) = HeaderValue::from_str(content_type) {
        builder = builder.header(header::CONTENT_TYPE, hv);
    }
    builder
        .body(Body::from(bytes))
        .unwrap_or_else(|_| coded_error("构建响应失败"))
}

fn rewrite_playlist(text: &str, base: &url::Url, prefix: &str) -> String {
    let mut out = String::with_capacity(text.len() + text.len() / 4);
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            out.push('\n');
        } else if trimmed.starts_with('#') {
            out.push_str(&rewrite_uri_attributes(line, base, prefix));
            out.push('\n');
        } else {
            out.push_str(&proxify(trimmed, base, prefix));
            out.push('\n');
        }
    }
    out
}

fn proxify(uri: &str, base: &url::Url, prefix: &str) -> String {
    match base.join(uri) {
        Ok(abs) => format!("{}/m?u={}", prefix, URL_SAFE_NO_PAD.encode(abs.as_str())),
        Err(_) => uri.to_string(),
    }
}

fn rewrite_uri_attributes(line: &str, base: &url::Url, prefix: &str) -> String {
    let mut out = String::with_capacity(line.len() + 128);
    let mut rest = line;
    while let Some(pos) = rest.find("URI=\"") {
        out.push_str(&rest[..pos + 5]);
        let after = &rest[pos + 5..];
        match after.find('"') {
            Some(end) => {
                out.push_str(&proxify(&after[..end], base, prefix));
                out.push('"');
                rest = &after[end + 1..];
            }
            None => {
                rest = after;
                break;
            }
        }
    }
    out.push_str(rest);
    out
}

struct ImageCache {
    map: HashMap<String, (Vec<u8>, String)>,
    order: VecDeque<String>,
    size: usize,
    limit: usize,
}

impl ImageCache {
    fn new(limit: usize) -> Self {
        Self {
            map: HashMap::new(),
            order: VecDeque::new(),
            size: 0,
            limit,
        }
    }

    fn get(&self, key: &str) -> Option<(Vec<u8>, String)> {
        self.map.get(key).cloned()
    }

    fn put(&mut self, key: String, bytes: Vec<u8>, content_type: String) {
        if let Some((old, _)) = self.map.remove(&key) {
            self.size = self.size.saturating_sub(old.len());
            self.order.retain(|k| k != &key);
        }
        while self.size + bytes.len() > self.limit {
            match self.order.pop_front() {
                Some(old) => {
                    if let Some((data, _)) = self.map.remove(&old) {
                        self.size = self.size.saturating_sub(data.len());
                    }
                }
                None => break,
            }
        }
        self.size += bytes.len();
        self.order.push_back(key.clone());
        self.map.insert(key, (bytes, content_type));
    }
}
