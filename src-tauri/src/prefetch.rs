use crate::cache::DiskCache;
use crate::config::Settings;
use crate::cookies::CookieJar;
use crate::transport;
use serde::Serialize;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::sync::{Mutex, RwLock};

const SEGMENT_CONCURRENCY: usize = 4;
/// Hard stop so an unexpected endless playlist cannot fill the disk.
const MAX_CACHE_BYTES: u64 = 6 * 1024 * 1024 * 1024;

#[derive(Debug, Clone, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct PrefetchProgress {
    pub active: bool,
    pub complete: bool,
    pub total: usize,
    pub done: usize,
    pub bytes: u64,
    pub message: String,
}

pub struct Prefetch {
    cache: Arc<DiskCache>,
    settings: Arc<RwLock<Settings>>,
    jar: Arc<CookieJar>,
    generation: Arc<AtomicU64>,
    progress: Mutex<PrefetchProgress>,
}

fn browser_headers(settings: &Settings, jar: &CookieJar, url: &str) -> Vec<(String, String)> {
    let mut headers = vec![
        (
            "Referer".to_string(),
            format!("{}/", settings.domain.trim_end_matches('/')),
        ),
        ("Accept".to_string(), "*/*".to_string()),
    ];
    if let Some(cookie) = jar.cookie_header(url) {
        headers.push(("Cookie".to_string(), cookie));
    }
    headers
}

async fn fetch_bytes(
    settings: &Settings,
    jar: &CookieJar,
    url: &str,
) -> Result<(u16, String, Vec<u8>), String> {
    let headers = browser_headers(settings, jar, url);
    let res = transport::request(settings, "GET", url, &headers, None).await?;
    let content_type = res
        .header("content-type")
        .unwrap_or("application/octet-stream")
        .to_string();
    Ok((res.status, content_type, res.body))
}

fn extract_uri(tag: &str) -> Option<String> {
    let idx = tag.find("URI=\"")?;
    let rest = &tag[idx + 5..];
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
}

impl Prefetch {
    pub fn new(cache: Arc<DiskCache>, settings: Arc<RwLock<Settings>>, jar: Arc<CookieJar>) -> Self {
        Self {
            cache,
            settings,
            jar,
            generation: Arc::new(AtomicU64::new(0)),
            progress: Mutex::new(PrefetchProgress::default()),
        }
    }

    pub fn cache(&self) -> &Arc<DiskCache> {
        &self.cache
    }

    /// Start downloading every segment of the given HLS playlist in the
    /// background. Any previous prefetch is cancelled first.
    pub async fn start(self: &Arc<Self>, url: String) -> Result<(), String> {
        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        {
            let mut progress = self.progress.lock().await;
            *progress = PrefetchProgress {
                active: true,
                message: "正在读取播放列表…".into(),
                ..Default::default()
            };
        }
        let this = self.clone();
        tauri::async_runtime::spawn(async move {
            // Give the player a head start so its first segments are not
            // competing with the background download for bandwidth.
            tokio::time::sleep(std::time::Duration::from_millis(2500)).await;
            if this.generation.load(Ordering::SeqCst) != generation {
                return;
            }
            let result = this.download_all(generation, &url).await;
            if this.generation.load(Ordering::SeqCst) != generation {
                return;
            }
            let mut progress = this.progress.lock().await;
            progress.active = false;
            match result {
                Ok(()) => {
                    progress.complete = progress.total > 0 && progress.done >= progress.total;
                    if progress.complete {
                        progress.message = "已完整缓存".into();
                    }
                }
                Err(err) => {
                    progress.complete = false;
                    progress.message = err;
                }
            }
        });
        Ok(())
    }

    pub async fn stop(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
        let mut progress = self.progress.lock().await;
        progress.active = false;
    }

    /// Stop any running prefetch, wipe the disk cache and report freed bytes.
    pub async fn clear(&self) -> u64 {
        self.stop().await;
        let freed = self.cache.total_bytes();
        self.cache.clear();
        let mut progress = self.progress.lock().await;
        *progress = PrefetchProgress::default();
        freed
    }

    pub async fn status(&self) -> PrefetchProgress {
        self.progress.lock().await.clone()
    }

    async fn fetch(
        &self,
        settings: &Settings,
        url: &str,
    ) -> Result<(u16, String, Vec<u8>), String> {
        if let Some(entry) = self.cache.get(url) {
            return Ok((entry.status, entry.content_type, entry.bytes));
        }
        let (status, content_type, body) = fetch_bytes(settings, &self.jar, url).await?;
        if (200..300).contains(&status) {
            self.cache.put(url, status, &content_type, &body);
        }
        Ok((status, content_type, body))
    }

    async fn download_all(&self, generation: u64, url: &str) -> Result<(), String> {
        let settings = self.settings.read().await.clone();

        let (status, content_type, body) = self.fetch(&settings, url).await?;
        if !(200..300).contains(&status) {
            return Err(format!("播放列表返回 HTTP {status}"));
        }
        let _ = content_type;
        let base = url::Url::parse(url).map_err(|_| "播放列表地址无效".to_string())?;
        let mut playlist_url = url.to_string();
        let mut playlist_text = String::from_utf8_lossy(&body).to_string();

        if playlist_text.contains("#EXT-X-STREAM-INF") {
            let variant = playlist_text
                .lines()
                .map(str::trim)
                .find(|line| !line.is_empty() && !line.starts_with('#'))
                .ok_or_else(|| "主播放列表中没有可用清晰度".to_string())?;
            let abs = base
                .join(variant)
                .map_err(|_| "无法解析视频分片列表".to_string())?;
            playlist_url = abs.to_string();
            let (st, ctv, bv) = self.fetch(&settings, &playlist_url).await?;
            if !(200..300).contains(&st) {
                return Err(format!("视频分片列表返回 HTTP {st}"));
            }
            self.cache.put(&playlist_url, st, &ctv, &bv);
            playlist_text = String::from_utf8_lossy(&bv).to_string();
        }

        let base = url::Url::parse(&playlist_url)
            .map_err(|_| "视频分片列表地址无效".to_string())?;
        let mut targets: Vec<String> = Vec::new();
        for line in playlist_text.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            if line.starts_with('#') {
                if line.starts_with("#EXT-X-MAP") || line.starts_with("#EXT-X-KEY") {
                    if let Some(uri) = extract_uri(line) {
                        if let Ok(abs) = base.join(&uri) {
                            targets.push(abs.to_string());
                        }
                    }
                }
                continue;
            }
            if let Ok(abs) = base.join(line) {
                targets.push(abs.to_string());
            }
        }
        targets.sort();
        targets.dedup();

        if targets.is_empty() {
            return Err("未找到可缓冲的视频分片".into());
        }

        {
            let mut progress = self.progress.lock().await;
            progress.total = targets.len();
            progress.message = "正在预缓冲…".into();
        }

        for chunk in targets.chunks(SEGMENT_CONCURRENCY) {
            if self.generation.load(Ordering::SeqCst) != generation {
                return Ok(());
            }
            if self.cache.total_bytes() > MAX_CACHE_BYTES {
                let mut progress = self.progress.lock().await;
                progress.message = "已达到本地缓存上限（6 GB）".into();
                return Ok(());
            }

            let mut set = tokio::task::JoinSet::new();
            for target in chunk {
                let settings = settings.clone();
                let jar = self.jar.clone();
                let cache = self.cache.clone();
                let generation_flag = self.generation.clone();
                let target = target.clone();
                set.spawn(async move {
                    if generation_flag.load(Ordering::SeqCst) != generation {
                        return 0;
                    }
                    if cache.has(&target) {
                        return 0u64;
                    }
                    match fetch_bytes(&settings, &jar, &target).await {
                        Ok((status, content_type, body)) if (200..300).contains(&status) => {
                            // Do not write into the cache if the session was
                            // cancelled (user left the video) while downloading.
                            if generation_flag.load(Ordering::SeqCst) != generation {
                                return 0;
                            }
                            let len = body.len() as u64;
                            cache.put(&target, status, &content_type, &body);
                            len
                        }
                        _ => 0,
                    }
                });
            }

            while let Some(joined) = set.join_next().await {
                if self.generation.load(Ordering::SeqCst) != generation {
                    set.shutdown().await;
                    return Ok(());
                }
                if let Ok(len) = joined {
                    let mut progress = self.progress.lock().await;
                    progress.done += 1;
                    progress.bytes += len;
                    progress.message = "正在预缓冲…".into();
                }
            }
        }

        Ok(())
    }
}
