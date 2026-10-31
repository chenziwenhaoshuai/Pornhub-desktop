use crate::config::Settings;
use std::path::PathBuf;
use std::sync::OnceLock;
use tokio::process::Command;
use tokio::sync::Semaphore;

pub struct Response {
    pub status: u16,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Response {
    pub fn header(&self, name: &str) -> Option<&str> {
        let name = name.to_ascii_lowercase();
        self.headers
            .iter()
            .find(|(k, _)| *k == name)
            .map(|(_, v)| v.as_str())
    }

    pub fn set_cookies(&self) -> Vec<String> {
        self.headers
            .iter()
            .filter(|(k, _)| k == "set-cookie")
            .map(|(_, v)| v.clone())
            .collect()
    }

    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }
}

fn gate() -> &'static Semaphore {
    static GATE: OnceLock<Semaphore> = OnceLock::new();
    GATE.get_or_init(|| Semaphore::new(10))
}

fn temp_dir() -> PathBuf {
    let dir = std::env::temp_dir().join("ph-desktop-http");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

fn curl_path() -> String {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let local = dir.join("curl.exe");
            if local.is_file() {
                return local.to_string_lossy().into_owned();
            }
        }
    }
    #[cfg(windows)]
    {
        if let Ok(sysroot) = std::env::var("SystemRoot") {
            let path = PathBuf::from(sysroot).join("System32").join("curl.exe");
            if path.is_file() {
                return path.to_string_lossy().into_owned();
            }
        }
        let fallback = PathBuf::from(r"C:\Windows\System32\curl.exe");
        if fallback.is_file() {
            return fallback.to_string_lossy().into_owned();
        }
    }
    "curl.exe".to_string()
}

fn friendly_failure(stderr: &str, code: Option<i32>) -> String {
    let text = stderr.trim();
    match code {
        Some(28) => "请求超时：请检查本机代理是否正常运行".into(),
        Some(7) | Some(6) | Some(5) => {
            "连接失败：无法连接到站点，请确认代理软件正在运行且端口正确".into()
        }
        Some(35) | Some(60) => "HTTPS 连接失败：可能是代理证书或网络环境问题".into(),
        _ => {
            if text.is_empty() {
                "网络请求失败，请稍后重试".into()
            } else {
                format!("网络请求失败：{text}")
            }
        }
    }
}

/// Perform an HTTP request through the system `curl` binary.
///
/// The bundled Windows `curl` (Schannel) is used instead of a pure-Rust TLS
/// stack because the site rejects other TLS/HTTP fingerprints with 403/410.
pub async fn request(
    settings: &Settings,
    method: &str,
    url: &str,
    headers: &[(String, String)],
    body: Option<&[u8]>,
) -> Result<Response, String> {
    let _permit = gate()
        .acquire()
        .await
        .map_err(|_| "请求队列已关闭".to_string())?;

    let id = uuid::Uuid::new_v4().simple().to_string();
    let dir = temp_dir();
    let head_path = dir.join(format!("{id}.hdr"));
    let body_path = dir.join(format!("{id}.body"));
    let data_path = dir.join(format!("{id}.data"));

    let mut cmd = Command::new(curl_path());
    cmd.arg("-sS")
        .arg("-L")
        .arg("--max-redirs")
        .arg("6")
        .arg("--http1.1")
        .arg("--connect-timeout")
        .arg("12")
        .arg("--max-time")
        .arg("45")
        .arg("-A")
        .arg(crate::net::UA)
        .arg("--compressed")
        .arg("-D")
        .arg(&head_path)
        .arg("-o")
        .arg(&body_path)
        .arg("-w")
        .arg("%{http_code}\\n%{url_effective}")
        .arg("--url")
        .arg(url);

    let is_local = url::Url::parse(url)
        .ok()
        .and_then(|u| u.host_str().map(|h| h.to_string()))
        .map(|h| h == "127.0.0.1" || h == "localhost" || h == "[::1]" || h == "::1")
        .unwrap_or(false);

    if is_local {
        cmd.arg("--noproxy").arg("*");
    } else if settings.proxy.enabled {
        cmd.arg("--proxy")
            .arg(format!("http://{}:{}", settings.proxy.host, settings.proxy.port));
    } else {
        cmd.arg("--noproxy").arg("*");
    }

    for (name, value) in headers {
        cmd.arg("-H").arg(format!("{name}: {value}"));
    }

    if method != "GET" {
        cmd.arg("-X").arg(method);
    }

    if let Some(data) = body {
        if std::fs::write(&data_path, data).is_err() {
            return Err("写入请求数据失败".into());
        }
        cmd.arg("-H")
            .arg("Content-Type: application/x-www-form-urlencoded")
            .arg("--data-binary")
            .arg(format!("@{}", data_path.display()));
    }

    #[cfg(windows)]
    {
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }

    let output = match cmd.output().await {
        Ok(out) => out,
        Err(err) => {
            cleanup(&[head_path, body_path, data_path]);
            return Err(format!(
                "无法启动 curl（Windows 10 及以上自带）：{err}\n请确认系统目录中存在 curl.exe"
            ));
        }
    };

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        cleanup(&[head_path, body_path, data_path]);
        return Err(friendly_failure(&stderr, output.status.code()));
    }

    let meta = String::from_utf8_lossy(&output.stdout).to_string();
    let mut lines = meta.lines();
    let status = lines
        .next()
        .and_then(|s| s.trim().parse::<u16>().ok())
        .unwrap_or(0);
    let final_url = lines.next().unwrap_or("").trim().to_string();

    if status == 0 {
        cleanup(&[head_path, body_path, data_path]);
        return Err("未收到站点响应，请检查代理设置".into());
    }

    let raw_headers = std::fs::read_to_string(&head_path).unwrap_or_default();
    let headers_out = parse_headers(&raw_headers);
    let body = std::fs::read(&body_path).unwrap_or_default();
    cleanup(&[head_path, body_path, data_path]);

    Ok(Response {
        status,
        url: if final_url.is_empty() {
            url.to_string()
        } else {
            final_url
        },
        headers: headers_out,
        body,
    })
}

fn cleanup(paths: &[PathBuf]) {
    for path in paths {
        let _ = std::fs::remove_file(path);
    }
}

fn parse_headers(raw: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for line in raw.lines() {
        let line = line.trim_end_matches('\r');
        if line.is_empty() || line.starts_with("HTTP/") {
            continue;
        }
        if let Some((name, value)) = line.split_once(':') {
            out.push((name.trim().to_ascii_lowercase(), value.trim().to_string()));
        }
    }
    out
}
