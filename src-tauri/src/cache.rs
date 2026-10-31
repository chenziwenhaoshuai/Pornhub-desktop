use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

/// A simple on-disk cache for media playlists and segments.
///
/// Files live in a single directory and are named after a hash of the upstream
/// URL, so a playlist or segment is fetched from the network only once even if
/// the player requests it again later (seeking, quality switch, retry...).
pub struct DiskCache {
    dir: PathBuf,
    bytes: AtomicU64,
}

#[derive(Clone)]
pub struct CachedEntry {
    pub status: u16,
    pub content_type: String,
    pub bytes: Vec<u8>,
}

fn hash_key(url: &str) -> String {
    // Two independent 64-bit FNV-1a passes -> 128-bit hex name.
    let mut h1: u64 = 0xcbf2_9ce4_8422_2325;
    let mut h2: u64 = 0x8422_2325_cbf2_9ce4;
    for (i, b) in url.as_bytes().iter().enumerate() {
        h1 ^= u64::from(*b);
        h1 = h1.wrapping_mul(0x0000_0100_0000_01b3);
        h2 ^= u64::from(*b).wrapping_add(i as u64);
        h2 = h2.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{h1:016x}{h2:016x}")
}

impl DiskCache {
    pub fn new(dir: PathBuf) -> Self {
        let _ = std::fs::create_dir_all(&dir);
        let bytes = dir_size(&dir);
        Self {
            dir,
            bytes: AtomicU64::new(bytes),
        }
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn total_bytes(&self) -> u64 {
        self.bytes.load(Ordering::Relaxed)
    }

    fn paths(&self, url: &str) -> (PathBuf, PathBuf) {
        let key = hash_key(url);
        (self.dir.join(format!("{key}.bin")), self.dir.join(format!("{key}.meta")))
    }

    pub fn has(&self, url: &str) -> bool {
        let (bin, _) = self.paths(url);
        bin.is_file()
    }

    pub fn get(&self, url: &str) -> Option<CachedEntry> {
        let (bin, meta) = self.paths(url);
        let bytes = std::fs::read(&bin).ok()?;
        let meta_text = std::fs::read_to_string(&meta).unwrap_or_default();
        let mut lines = meta_text.lines();
        let status = lines
            .next()
            .and_then(|s| s.trim().parse::<u16>().ok())
            .unwrap_or(200);
        let content_type = lines.next().unwrap_or("").trim().to_string();
        Some(CachedEntry {
            status,
            content_type,
            bytes,
        })
    }

    pub fn put(&self, url: &str, status: u16, content_type: &str, data: &[u8]) {
        let (bin, meta) = self.paths(url);
        let bin_tmp = bin.with_extension("bin.tmp");
        if std::fs::write(&bin_tmp, data).is_err() {
            return;
        }
        if std::fs::rename(&bin_tmp, &bin).is_err() {
            let _ = std::fs::remove_file(&bin_tmp);
            return;
        }
        let meta_text = format!("{status}\n{content_type}\n");
        let _ = std::fs::write(&meta, meta_text);
        self.bytes.fetch_add(data.len() as u64, Ordering::Relaxed);
    }

    /// Remove every cached file and reset the byte counter.
    pub fn clear(&self) {
        let Ok(entries) = std::fs::read_dir(&self.dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file() {
                let _ = std::fs::remove_file(path);
            }
        }
        self.bytes.store(0, Ordering::Relaxed);
    }
}

fn dir_size(dir: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return 0;
    };
    let mut total = 0u64;
    for entry in entries.flatten() {
        if let Ok(meta) = entry.metadata() {
            if meta.is_file() {
                total += meta.len();
            }
        }
    }
    total
}
