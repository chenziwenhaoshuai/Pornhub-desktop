#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use ph_desktop::{api, cache, config, cookies, media, net, prefetch, transport};
use api::{Account, Challenge, LoginOutcome};
use cache::DiskCache;
use config::Settings;
use cookies::CookieJar;
use media::MediaServer;
use prefetch::{Prefetch, PrefetchProgress};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tauri::{Manager, State};
use tokio::sync::{Mutex, RwLock};

struct AppState {
    dir: PathBuf,
    settings: Arc<RwLock<Settings>>,
    jar: Arc<CookieJar>,
    media: MediaServer,
    prefetch: Arc<Prefetch>,
    cache: Mutex<HashMap<String, (Instant, Value)>>,
}

const CACHE_TTL: Duration = Duration::from_secs(3600);

impl AppState {
    async fn settings(&self) -> Settings {
        self.settings.read().await.clone()
    }

    async fn cache_get(&self, key: &str) -> Option<Value> {
        let guard = self.cache.lock().await;
        guard
            .get(key)
            .filter(|(at, _)| at.elapsed() < CACHE_TTL)
            .map(|(_, value)| value.clone())
    }

    async fn cache_put(&self, key: String, value: Value) {
        let mut guard = self.cache.lock().await;
        if guard.len() > 120 {
            guard.clear();
        }
        guard.insert(key, (Instant::now(), value));
    }
}

async fn cached_json<F, Fut>(state: &AppState, key: String, force: bool, build: F) -> Result<Value, String>
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = Result<Value, String>>,
{
    if !force {
        if let Some(value) = state.cache_get(&key).await {
            return Ok(value);
        }
    }
    let value = build().await?;
    state.cache_put(key, value.clone()).await;
    Ok(value)
}

fn to_value<T: serde::Serialize>(value: T) -> Result<Value, String> {
    serde_json::to_value(value).map_err(|e| format!("序列化失败：{e}"))
}

#[tauri::command]
async fn get_settings(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings().await;
    Ok(json!({
        "settings": settings,
        "mediaBase": state.media.base,
    }))
}

#[tauri::command]
async fn save_settings(state: State<'_, AppState>, settings: Settings) -> Result<Value, String> {
    let normalized = config::normalize(settings);
    *state.settings.write().await = normalized.clone();
    config::save(&state.dir, &normalized)?;
    state.cache.lock().await.clear();
    Ok(json!({ "settings": normalized, "mediaBase": state.media.base }))
}

#[tauri::command]
async fn test_connection(state: State<'_, AppState>) -> Result<net::TestResult, String> {
    let settings = state.settings().await;
    Ok(net::test(&settings, &state.jar).await)
}

#[tauri::command]
async fn get_home(
    state: State<'_, AppState>,
    page: Option<u32>,
    force: Option<bool>,
) -> Result<Value, String> {
    let page = page.unwrap_or(1).max(1);
    let settings = state.settings().await;
    let jar = state.jar.clone();
    let key = format!("home:{page}");
    cached_json(&state, key, force.unwrap_or(false), || async {
        let home = api::home(&settings, &jar, page).await?;
        to_value(home)
    })
    .await
}

#[tauri::command]
async fn get_categories(state: State<'_, AppState>, force: Option<bool>) -> Result<Value, String> {
    let settings = state.settings().await;
    let jar = state.jar.clone();
    cached_json(&state, "categories".into(), force.unwrap_or(false), || async {
        let cats = api::categories(&settings, &jar).await?;
        to_value(cats)
    })
    .await
}

#[tauri::command]
async fn get_list(
    state: State<'_, AppState>,
    path: String,
    page: Option<u32>,
    force: Option<bool>,
) -> Result<Value, String> {
    let page = page.unwrap_or(1).max(1);
    let settings = state.settings().await;
    let jar = state.jar.clone();
    let key = format!("list:{path}:{page}");
    cached_json(&state, key, force.unwrap_or(false), || async {
        let listing = api::listing(&settings, &jar, &path, page).await?;
        to_value(listing)
    })
    .await
}

#[tauri::command]
async fn get_video(
    state: State<'_, AppState>,
    vkey: String,
    force: Option<bool>,
) -> Result<Value, String> {
    let settings = state.settings().await;
    let jar = state.jar.clone();
    let key = format!("video:{vkey}");
    cached_json(&state, key, force.unwrap_or(false), || async {
        let detail = api::video(&settings, &jar, &vkey).await?;
        to_value(detail)
    })
    .await
}

#[tauri::command]
async fn get_account(state: State<'_, AppState>) -> Result<Account, String> {
    let settings = state.settings().await;
    Ok(api::fetch_account(&settings, &state.jar).await)
}

#[tauri::command]
async fn login(
    state: State<'_, AppState>,
    email: String,
    password: String,
) -> Result<LoginOutcome, String> {
    let settings = state.settings().await;
    let outcome = api::login(&settings, &state.jar, email.trim(), &password).await?;
    if let LoginOutcome::Ok(account) = &outcome {
        let mut next = settings.clone();
        next.account_name = account.username.clone();
        config::save(&state.dir, &next)?;
        *state.settings.write().await = next;
        state.cache.lock().await.clear();
    }
    Ok(outcome)
}

#[tauri::command]
async fn login_2fa(
    state: State<'_, AppState>,
    challenge: Challenge,
    code: String,
) -> Result<LoginOutcome, String> {
    let settings = state.settings().await;
    let outcome = api::login_2fa(&settings, &state.jar, &challenge, code.trim()).await?;
    if let LoginOutcome::Ok(account) = &outcome {
        let mut next = settings.clone();
        next.account_name = account.username.clone();
        config::save(&state.dir, &next)?;
        *state.settings.write().await = next;
        state.cache.lock().await.clear();
    }
    Ok(outcome)
}

#[tauri::command]
async fn logout(state: State<'_, AppState>) -> Result<Value, String> {
    state.jar.clear();
    let mut settings = state.settings().await;
    settings.account_name.clear();
    config::save(&state.dir, &settings)?;
    *state.settings.write().await = settings;
    state.cache.lock().await.clear();
    Ok(json!({ "ok": true }))
}

#[tauri::command]
async fn import_cookies(state: State<'_, AppState>, header: String) -> Result<Account, String> {
    let settings = state.settings().await;
    let account = api::import_cookies(&settings, &state.jar, &header).await?;
    let mut next = settings.clone();
    next.account_name = account.username.clone();
    config::save(&state.dir, &next)?;
    *state.settings.write().await = next;
    state.cache.lock().await.clear();
    Ok(account)
}

#[tauri::command]
async fn get_media_base(state: State<'_, AppState>) -> Result<String, String> {
    Ok(state.media.base.clone())
}

#[tauri::command]
async fn prefetch_video(state: State<'_, AppState>, url: String) -> Result<Value, String> {
    state.prefetch.start(url).await?;
    Ok(json!({ "ok": true }))
}

#[tauri::command]
async fn stop_prefetch(state: State<'_, AppState>) -> Result<Value, String> {
    state.prefetch.stop().await;
    Ok(json!({ "ok": true }))
}

#[tauri::command]
async fn prefetch_status(state: State<'_, AppState>) -> Result<PrefetchProgress, String> {
    Ok(state.prefetch.status().await)
}

#[tauri::command]
async fn clear_media_cache(state: State<'_, AppState>) -> Result<Value, String> {
    let freed = state.prefetch.clear().await;
    Ok(json!({ "ok": true, "freed": freed }))
}

#[tauri::command]
async fn clear_cache(state: State<'_, AppState>) -> Result<Value, String> {
    state.cache.lock().await.clear();
    Ok(json!({ "ok": true }))
}

#[tauri::command]
fn open_external(url: String) -> Result<(), String> {
    let url = url.trim();
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return Err("仅支持打开网页链接".into());
    }
    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("cmd")
            .args(["/C", "start", "", url])
            .spawn()
            .map_err(|e| format!("无法打开浏览器：{e}"))?;
    }
    #[cfg(not(target_os = "windows"))]
    {
        std::process::Command::new("xdg-open")
            .arg(url)
            .spawn()
            .map_err(|e| format!("无法打开浏览器：{e}"))?;
    }
    Ok(())
}

#[tauri::command]
fn window_action(window: tauri::Window, action: String) -> Result<(), String> {
    match action.as_str() {
        "minimize" => window.minimize(),
        "maximize" => {
            if window.is_maximized().unwrap_or(false) {
                window.unmaximize()
            } else {
                window.maximize()
            }
        }
        "close" => window.close(),
        _ => return Err("未知的窗口操作".into()),
    }
    .map_err(|e| e.to_string())
}

fn main() {
    tauri::Builder::default()
        .setup(|app| {
            let dir = app
                .path()
                .app_data_dir()
                .unwrap_or_else(|_| PathBuf::from("."));
            let _ = std::fs::create_dir_all(&dir);

            let settings = config::load(&dir);
            let jar = Arc::new(CookieJar::new(dir.join("cookies.json")));
            let settings = Arc::new(RwLock::new(settings));

            // The media cache is meant for a single viewing session: purge any
            // leftovers from the previous run before the window opens.
            let disk_cache = Arc::new(DiskCache::new(dir.join("media-cache")));
            disk_cache.clear();
            transport::clean_temp_dir();

            let prefetch = Arc::new(Prefetch::new(
                disk_cache.clone(),
                settings.clone(),
                jar.clone(),
            ));

            let media = tauri::async_runtime::block_on(media::start(
                settings.clone(),
                jar.clone(),
                disk_cache,
            ))?;

            app.manage(AppState {
                dir,
                settings,
                jar,
                media,
                prefetch,
                cache: Mutex::new(HashMap::new()),
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_settings,
            save_settings,
            test_connection,
            get_home,
            get_categories,
            get_list,
            get_video,
            get_account,
            login,
            login_2fa,
            logout,
            import_cookies,
            get_media_base,
            prefetch_video,
            stop_prefetch,
            prefetch_status,
            clear_media_cache,
            clear_cache,
            open_external,
            window_action
        ])
        .run(tauri::generate_context!())
        .expect("failed to run app");
}
