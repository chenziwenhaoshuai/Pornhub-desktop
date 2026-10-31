use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::RwLock;
use std::time::{SystemTime, UNIX_EPOCH};
use url::Url;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredCookie {
    pub name: String,
    pub value: String,
    pub domain: String,
    pub path: String,
    pub expires: Option<i64>,
}

pub struct CookieJar {
    cookies: RwLock<Vec<StoredCookie>>,
    path: PathBuf,
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn default_path(path: &str) -> String {
    if path.is_empty() {
        return "/".into();
    }
    let idx = path.rfind('/').unwrap_or(0);
    if idx == 0 {
        "/".into()
    } else {
        path[..idx].to_string()
    }
}

impl CookieJar {
    pub fn new(path: PathBuf) -> Self {
        let cookies = std::fs::read_to_string(&path)
            .ok()
            .and_then(|t| serde_json::from_str::<Vec<StoredCookie>>(&t).ok())
            .unwrap_or_default();
        Self {
            cookies: RwLock::new(cookies),
            path,
        }
    }

    fn persist(&self) {
        let guard = self.cookies.read().unwrap_or_else(|e| e.into_inner());
        if let Ok(text) = serde_json::to_string(&*guard) {
            if let Some(dir) = self.path.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            let tmp = self.path.with_extension("json.tmp");
            if std::fs::write(&tmp, text).is_ok() {
                let _ = std::fs::rename(&tmp, &self.path);
            }
        }
    }

    /// Feed one raw `Set-Cookie` header value received from `url`.
    pub fn apply_set_cookie(&self, url: &str, raw: &str) {
        let host = match Url::parse(url) {
            Ok(u) => match u.host_str() {
                Some(h) => h.to_ascii_lowercase(),
                None => return,
            },
            Err(_) => return,
        };
        let (cookie, delete) = match parse_set_cookie(raw, &host) {
            Some(value) => value,
            None => return,
        };
        {
            let mut guard = self.cookies.write().unwrap_or_else(|e| e.into_inner());
            guard.retain(|c| {
                !(c.name == cookie.name && c.domain == cookie.domain && c.path == cookie.path)
            });
            if !delete {
                guard.push(cookie);
            }
        }
        self.persist();
    }

    pub fn clear(&self) {
        self.cookies
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .clear();
        let _ = std::fs::remove_file(&self.path);
    }

    pub fn has_any(&self) -> bool {
        !self
            .cookies
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .is_empty()
    }

    /// Import a raw `Cookie:` header pasted by the user.
    pub fn import_header(&self, domain: &str, header: &str) -> usize {
        let host = domain
            .trim()
            .trim_start_matches("https://")
            .trim_start_matches("http://")
            .split('/')
            .next()
            .unwrap_or("")
            .to_ascii_lowercase();
        if host.is_empty() {
            return 0;
        }
        let mut guard = self.cookies.write().unwrap_or_else(|e| e.into_inner());
        let mut count = 0;
        for part in header.split(';') {
            let part = part.trim();
            if part.is_empty() {
                continue;
            }
            if let Some((name, value)) = part.split_once('=') {
                let name = name.trim();
                if name.is_empty() {
                    continue;
                }
                let value = value.trim().trim_matches('"').to_string();
                guard.retain(|c| !(c.name == name && c.domain == host));
                guard.push(StoredCookie {
                    name: name.to_string(),
                    value,
                    domain: host.clone(),
                    path: "/".into(),
                    expires: None,
                });
                count += 1;
            }
        }
        drop(guard);
        if count > 0 {
            self.persist();
        }
        count
    }

    /// Build the `Cookie:` header for a request URL.
    pub fn cookie_header(&self, url: &str) -> Option<String> {
        let url = Url::parse(url).ok()?;
        let host = url.host_str()?.to_ascii_lowercase();
        let path = if url.path().is_empty() {
            "/"
        } else {
            url.path()
        };
        let now = now();
        let guard = self.cookies.read().unwrap_or_else(|e| e.into_inner());
        let mut matched: Vec<&StoredCookie> = guard
            .iter()
            .filter(|c| {
                c.expires.map(|e| e > now).unwrap_or(true)
                    && (host == c.domain || host.ends_with(&format!(".{}", c.domain)))
                    && path.starts_with(&c.path)
            })
            .collect();
        if matched.is_empty() {
            return None;
        }
        matched.sort_by(|a, b| b.path.len().cmp(&a.path.len()));
        Some(
            matched
                .iter()
                .map(|c| format!("{}={}", c.name, c.value))
                .collect::<Vec<_>>()
                .join("; "),
        )
    }
}

fn parse_set_cookie(raw: &str, host: &str) -> Option<(StoredCookie, bool)> {
    let mut parts = raw.split(';');
    let first = parts.next()?.trim();
    let (name, value) = first.split_once('=')?;
    let name = name.trim();
    if name.is_empty() {
        return None;
    }
    let value = value.trim().trim_matches('"').to_string();
    let mut domain = host.to_string();
    let mut path = default_path("");
    let mut expires: Option<i64> = None;
    let mut delete = false;

    for attr in parts {
        let attr = attr.trim();
        let (key, val) = match attr.split_once('=') {
            Some(kv) => kv,
            None => continue,
        };
        match key.trim().to_ascii_lowercase().as_str() {
            "domain" => {
                let d = val.trim().trim_start_matches('.').to_ascii_lowercase();
                if !d.is_empty() {
                    domain = d;
                }
            }
            "path" => {
                let p = val.trim();
                if p.starts_with('/') {
                    path = p.to_string();
                }
            }
            "max-age" => {
                if let Ok(secs) = val.trim().parse::<i64>() {
                    if secs <= 0 {
                        delete = true;
                    } else {
                        expires = Some(now() + secs);
                    }
                }
            }
            "expires" => {
                if let Ok(t) = httpdate::parse_http_date(val.trim()) {
                    let secs = t
                        .duration_since(UNIX_EPOCH)
                        .map(|d| d.as_secs() as i64)
                        .unwrap_or(0);
                    if secs <= now() {
                        delete = true;
                    } else {
                        expires = Some(secs);
                    }
                }
            }
            _ => {}
        }
    }

    Some((
        StoredCookie {
            name: name.to_string(),
            value,
            domain,
            path,
            expires,
        },
        delete,
    ))
}
