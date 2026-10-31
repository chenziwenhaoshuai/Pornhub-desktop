use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub domain: String,
    pub proxy: ProxySettings,
    pub account_name: String,
    /// Download the whole video into the local cache as soon as playback starts.
    pub prefetch: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ProxySettings {
    pub enabled: bool,
    pub host: String,
    pub port: u16,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            domain: "https://cn.pornhub.com".into(),
            proxy: ProxySettings::default(),
            account_name: String::new(),
            prefetch: true,
        }
    }
}

impl Default for ProxySettings {
    fn default() -> Self {
        Self {
            enabled: true,
            host: "127.0.0.1".into(),
            port: 7897,
        }
    }
}

pub fn normalize(mut s: Settings) -> Settings {
    let mut domain = s.domain.trim().to_string();
    if domain.is_empty() {
        domain = "https://cn.pornhub.com".into();
    }
    if !domain.starts_with("http://") && !domain.starts_with("https://") {
        domain = format!("https://{domain}");
    }
    while domain.ends_with('/') {
        domain.pop();
    }
    s.domain = domain;

    s.proxy.host = s.proxy.host.trim().to_string();
    if s.proxy.host.is_empty() {
        s.proxy.host = "127.0.0.1".into();
    }
    if s.proxy.port == 0 {
        s.proxy.port = 7897;
    }
    s.account_name = s.account_name.trim().to_string();
    s
}

pub fn settings_path(dir: &Path) -> PathBuf {
    dir.join("settings.json")
}

pub fn load(dir: &Path) -> Settings {
    let path = settings_path(dir);
    match std::fs::read_to_string(&path) {
        Ok(text) => serde_json::from_str::<Settings>(&text)
            .map(normalize)
            .unwrap_or_default(),
        Err(_) => Settings::default(),
    }
}

pub fn save(dir: &Path, settings: &Settings) -> Result<(), String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("创建配置目录失败: {e}"))?;
    let text = serde_json::to_string_pretty(settings).map_err(|e| e.to_string())?;
    std::fs::write(settings_path(dir), text).map_err(|e| format!("保存设置失败: {e}"))
}
