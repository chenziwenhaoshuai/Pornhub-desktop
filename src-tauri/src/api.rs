use crate::config::Settings;
use crate::cookies::CookieJar;
use crate::net;
use crate::parse::{self, Categories, Home, Listing, VideoDetail};
use crate::transport;
use scraper::Html;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use url::form_urlencoded;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    pub logged_in: bool,
    pub username: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Challenge {
    pub two_step_type: String,
    pub email: String,
    pub username: String,
    pub phone_number: String,
    pub authy_id: String,
    pub authy_id_hashed: String,
    pub auto_login_parameter: String,
    pub csrf: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "camelCase")]
pub enum LoginOutcome {
    Ok(Account),
    TwoFactor(Challenge),
}

fn clean_message(raw: &str) -> String {
    let fragment = Html::parse_fragment(raw);
    let text = fragment
        .root_element()
        .text()
        .collect::<Vec<_>>()
        .join(" ");
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.is_empty() {
        raw.trim().to_string()
    } else {
        collapsed
    }
}

fn value_str(v: &Value, key: &str) -> String {
    v.get(key)
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .trim()
        .to_string()
}

fn is_success(v: &Value) -> bool {
    match v.get("success") {
        Some(Value::String(s)) => s != "0" && !s.is_empty(),
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0) != 0,
        _ => false,
    }
}

fn username_from_redirect(redirect: &str) -> String {
    let marker = "/users/";
    if let Some(idx) = redirect.find(marker) {
        let rest = &redirect[idx + marker.len()..];
        let name = rest.split(['/', '?', '#']).next().unwrap_or("");
        if !name.is_empty() {
            return name.to_string();
        }
    }
    String::new()
}

fn interpret_response(v: &Value, csrf: &str) -> Result<LoginOutcome, String> {
    if v
        .get("requireCaptcha")
        .and_then(|x| x.as_bool())
        .unwrap_or(false)
    {
        return Err(
            "站点要求人机验证，无法直接登录。可在浏览器登录后使用“粘贴浏览器 Cookie”方式登录。"
                .into(),
        );
    }

    if !is_success(v) {
        let message = value_str(v, "message");
        if message.is_empty() {
            return Err("登录失败，请检查账号和密码".into());
        }
        let cleaned = clean_message(&message);
        if cleaned.to_ascii_lowercase().contains("captcha") {
            return Err(
                "站点要求人机验证，无法直接登录。可在浏览器登录后使用“粘贴浏览器 Cookie”方式登录。"
                    .into(),
            );
        }
        return Err(cleaned);
    }

    let two_step = v
        .get("twoStepVerification")
        .and_then(|x| x.as_bool())
        .unwrap_or(false)
        || !value_str(v, "twoStepVerificationType").is_empty();

    if two_step {
        let mut two_step_type = value_str(v, "twoStepVerificationType");
        if two_step_type.is_empty() {
            two_step_type = "existingLegacy".into();
        }
        return Ok(LoginOutcome::TwoFactor(Challenge {
            two_step_type,
            email: value_str(v, "email"),
            username: value_str(v, "username"),
            phone_number: value_str(v, "phoneNumber"),
            authy_id: value_str(v, "authyId"),
            authy_id_hashed: value_str(v, "authyIdHashed"),
            auto_login_parameter: value_str(v, "autoLoginParameter"),
            csrf: csrf.to_string(),
        }));
    }

    let mut username = value_str(v, "username");
    if username.is_empty() {
        username = value_str(v, "user_name");
    }
    if username.is_empty() {
        username = value_str(v, "nickname");
    }
    if username.is_empty() {
        username = username_from_redirect(&value_str(v, "redirect"));
    }

    Ok(LoginOutcome::Ok(Account {
        logged_in: true,
        username,
    }))
}

fn origin(settings: &Settings) -> String {
    settings.domain.trim_end_matches('/').to_string()
}

async fn post_auth(
    settings: &Settings,
    jar: &CookieJar,
    form: &[(&str, &str)],
    csrf: &str,
) -> Result<LoginOutcome, String> {
    let domain = origin(settings);
    let url = format!("{domain}/front/authenticate");
    let body: String = form_urlencoded::Serializer::new(String::new())
        .extend_pairs(form.iter().copied())
        .finish();

    let mut headers = vec![
        ("Referer".to_string(), format!("{domain}/login")),
        ("Origin".to_string(), domain.clone()),
        (
            "Accept".to_string(),
            "application/json, text/javascript, */*; q=0.01".to_string(),
        ),
        ("X-Requested-With".to_string(), "XMLHttpRequest".to_string()),
        ("Cache-Control".to_string(), "no-cache".to_string()),
    ];
    if let Some(cookie) = jar.cookie_header(&url) {
        headers.push(("Cookie".to_string(), cookie));
    }

    let res = transport::request(settings, "POST", &url, &headers, Some(body.as_bytes())).await?;
    for raw in res.set_cookies() {
        jar.apply_set_cookie(&res.url, &raw);
    }

    if res.status == 429 {
        return Err("请求过于频繁，请稍后再试".into());
    }

    let text = res.text();
    let value: Value = serde_json::from_str(&text).map_err(|_| {
        format!(
            "登录接口返回异常（HTTP {}），可能触发了站点风控",
            res.status
        )
    })?;
    interpret_response(&value, csrf)
}

pub async fn login(
    settings: &Settings,
    jar: &CookieJar,
    email: &str,
    password: &str,
) -> Result<LoginOutcome, String> {
    let domain = origin(settings);
    let (_, html) = net::fetch_text(settings, jar, &format!("{domain}/login")).await?;
    let (token, redirect, from) = parse::parse_login_form(&html, &domain)?;

    let form = [
        ("redirect", redirect.as_str()),
        ("user_id", ""),
        ("intended_action", ""),
        ("token", token.as_str()),
        ("from", from.as_str()),
        ("email", email),
        ("password", password),
    ];
    post_auth(settings, jar, &form, &token).await
}

pub async fn login_2fa(
    settings: &Settings,
    jar: &CookieJar,
    challenge: &Challenge,
    code: &str,
) -> Result<LoginOutcome, String> {
    let email = if !challenge.email.is_empty() {
        challenge.email.clone()
    } else {
        challenge.username.clone()
    };
    let form = [
        ("verification_modal", "1"),
        ("email", email.as_str()),
        ("username", challenge.username.as_str()),
        ("token2", challenge.auto_login_parameter.as_str()),
        ("authyId", challenge.authy_id.as_str()),
        ("authyIdHashed", challenge.authy_id_hashed.as_str()),
        ("token", challenge.csrf.as_str()),
        ("verification_code", code),
    ];
    post_auth(settings, jar, &form, &challenge.csrf).await
}

pub async fn fetch_account(settings: &Settings, jar: &CookieJar) -> Account {
    let domain = origin(settings);
    match net::fetch_text(settings, jar, &format!("{domain}/")).await {
        Ok((_, html)) => {
            let logged_in = parse::is_logged_in(&html);
            let mut username = if logged_in {
                parse::parse_username(&html)
            } else {
                String::new()
            };
            if logged_in && username.is_empty() {
                username = settings.account_name.clone();
            }
            Account {
                logged_in,
                username,
            }
        }
        Err(_) => Account {
            logged_in: !settings.account_name.is_empty(),
            username: settings.account_name.clone(),
        },
    }
}

pub async fn home(settings: &Settings, jar: &CookieJar) -> Result<Home, String> {
    let domain = origin(settings);
    let (_, html) = net::fetch_text(settings, jar, &format!("{domain}/")).await?;
    Ok(parse::parse_home(&html, &domain))
}

pub async fn categories(settings: &Settings, jar: &CookieJar) -> Result<Categories, String> {
    let domain = origin(settings);
    let (_, html) = net::fetch_text(settings, jar, &format!("{domain}/categories")).await?;
    Ok(parse::parse_categories(&html, &domain))
}

pub async fn listing(
    settings: &Settings,
    jar: &CookieJar,
    path: &str,
    page: u32,
) -> Result<Listing, String> {
    let url = net::url_for(settings, path, page)?;
    let (_, html) = net::fetch_text(settings, jar, &url).await?;
    Ok(parse::parse_listing(&html, &settings.domain))
}

pub async fn video(
    settings: &Settings,
    jar: &CookieJar,
    vkey: &str,
) -> Result<VideoDetail, String> {
    if !parse::validate_vkey(vkey) {
        return Err("视频编号无效".into());
    }
    let domain = origin(settings);
    let url = format!("{domain}/view_video.php?viewkey={vkey}");
    let (_, html) = net::fetch_text(settings, jar, &url).await?;
    parse::parse_video(&html, &domain, vkey)
}

pub async fn import_cookies(
    settings: &Settings,
    jar: &CookieJar,
    header: &str,
) -> Result<Account, String> {
    let count = jar.import_header(&settings.domain, header);
    if count == 0 {
        return Err("未能识别 Cookie，请确认复制的是完整的 Cookie 请求头".into());
    }
    let account = fetch_account(settings, jar).await;
    if !account.logged_in {
        return Err("Cookie 无效或已过期，请重新从浏览器复制".into());
    }
    Ok(account)
}
