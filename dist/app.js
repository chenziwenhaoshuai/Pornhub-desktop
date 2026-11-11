/* Pornhub Desktop — custom client UI */
(() => {
  'use strict';

  const invoke = window.__TAURI__.core.invoke;
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

  const view = $('#view');
  const homePane = $('#homePane');
  const subPane = $('#subPane');
  const S = {
    settings: null,
    mediaBase: '',
    account: null,
    route: null,
    stack: [],
    index: -1,
    seq: 0,
    homeRendered: false,
    homeScrollTop: 0,
    homePage: 1,
    homeLoading: false,
    homeHasMore: true,
    seenHomeVkeys: new Set(),
  };

  const HISTORY_KEY = 'ph.history.v1';
  const POS_KEY = 'ph.pos.';
  const memoryCache = new Map();

  /* ------------------------------- utils ------------------------------- */

  const esc = (value) =>
    String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');

  function b64url(text) {
    const bytes = new TextEncoder().encode(text);
    let binary = '';
    const step = 0x8000;
    for (let i = 0; i < bytes.length; i += step) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + step));
    }
    return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }

  const mediaUrl = (url) => (url ? `${S.mediaBase}/m?u=${b64url(url)}` : '');
  const imgUrl = (url) => (url ? `${S.mediaBase}/i?u=${b64url(url)}` : '');

  function toRelativePath(raw) {
    if (!raw) return '/video';
    const text = String(raw).trim();
    if (text.startsWith('http://') || text.startsWith('https://')) {
      try {
        const u = new URL(text);
        return u.pathname + u.search;
      } catch {
        return text;
      }
    }
    return text.startsWith('/') ? text : '/' + text;
  }

  function fmtTime(seconds) {
    if (!isFinite(seconds) || seconds < 0) seconds = 0;
    seconds = Math.floor(seconds);
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = seconds % 60;
    return h
      ? `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
      : `${m}:${String(s).padStart(2, '0')}`;
  }

  function fmtBytes(bytes) {
    const value = Number(bytes) || 0;
    if (value < 1024) return `${value} B`;
    if (value < 1024 * 1024) return `${(value / 1024).toFixed(0)} KB`;
    if (value < 1024 * 1024 * 1024) return `${(value / 1024 / 1024).toFixed(0)} MB`;
    return `${(value / 1024 / 1024 / 1024).toFixed(2)} GB`;
  }

  function withParam(path, key, value) {
    const [base, qs = ''] = String(path).split('?');
    const params = new URLSearchParams(qs);
    if (value === null || value === undefined || value === '') params.delete(key);
    else params.set(key, value);
    const query = params.toString();
    return query ? `${base}?${query}` : base;
  }

  const param = (path, key) => new URLSearchParams(String(path).split('?')[1] || '').get(key);

  let toastTimer = 0;
  function toast(message, kind = '') {
    const box = document.createElement('div');
    box.className = `toast ${kind}`;
    box.textContent = message;
    $('#toasts').appendChild(box);
    clearTimeout(toastTimer);
    setTimeout(() => {
      box.style.transition = 'opacity .25s, transform .25s';
      box.style.opacity = '0';
      box.style.transform = 'translateY(6px)';
      setTimeout(() => box.remove(), 260);
    }, 4200);
  }

  function icons(name) {
    const paths = {
      play: '<path d="M8 5v14l11-7z"/>',
      pause: '<path d="M7 5h4v14H7zm6 0h4v14h-4z"/>',
      volume: '<path d="M4 9v6h4l5 4V5L8 9H4zm12.5 3a4.5 4.5 0 0 0-2.5-4v8a4.5 4.5 0 0 0 2.5-4z"/>',
      mute: '<path d="M4 9v6h4l5 4V5L8 9H4zm13.6 3 2.4 2.4-1.1 1.1L16.5 13l-2.4 2.5-1.1-1.1L15.4 12 13 9.6l1.1-1.1 2.4 2.4 2.4-2.4 1.1 1.1L17.6 12z"/>',
      settings: '<path d="M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8Z"/>',
      pip: '<path d="M3 5h18v14H3V5zm2 2v10h14V7H5zm7 4h6v5h-6v-5z"/>',
      full: '<path d="M4 4h6v2H6v4H4V4zm10 0h6v6h-2V6h-4V4zM4 14h2v4h4v2H4v-6zm14 0h2v6h-6v-2h4v-4z"/>',
      exitfull: '<path d="M8 4h2v6H4V8h4V4zm6 0h2v4h4v2h-6V4zM4 14h6v6H8v-4H4v-2zm10 0h6v2h-4v4h-2v-6z"/>',
      clock: '<path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm1 5v5.6l4.3 2.5-1 1.7-5.3-3.1V7h2z"/>',
      refresh: '<path d="M12 5V2L7 6l5 4V7a5 5 0 1 1-5 5H5a7 7 0 1 0 7-7z"/>',
      external: '<path d="M14 3h7v7h-2V6.4l-8.3 8.3-1.4-1.4L17.6 5H14V3zM5 5h5v2H7v10h10v-3h2v5H5V5z"/>',
      trash: '<path d="M9 3h6l1 2h4v2H4V5h4l1-2zM6 8h12l-1 13H7L6 8z"/>',
      star: '<path d="m12 3 2.7 5.7 6.3.9-4.6 4.4 1.1 6.2L12 17.3 6.5 20.2l1.1-6.2L3 9.6l6.3-.9L12 3z"/>',
      arrowLeft: '<path d="M20 11H7.8l5.6-5.6L12 4l-8 8 8 8 1.4-1.4L7.8 13H20v-2z"/>',
      arrowRight: '<path d="M4 13h12.2l-5.6 5.6L12 20l8-8-8-8-1.4 1.4 5.6 5.6H4v2z"/>',
    };
    return `<svg viewBox="0 0 24 24">${paths[name] || ''}</svg>`;
  }

  /* ------------------------------ data layer ------------------------------ */

  const CACHE_TTL = 30 * 60 * 1000;

  async function cached(command, args, key, force) {
    const now = Date.now();
    if (!force) {
      const hit = memoryCache.get(key);
      const isHomeKey = key === 'home' || String(key).startsWith('home:');
      const ttl = isHomeKey ? Infinity : CACHE_TTL;
      if (hit && (ttl === Infinity || now - hit.at < ttl)) return hit.value;
    }
    const value = await invoke(command, args);
    memoryCache.set(key, { at: now, value });
    return value;
  }

  function clearClientCache() {
    memoryCache.clear();
    S.homeRendered = false;
    S.homePage = 1;
    S.homeHasMore = true;
    S.seenHomeVkeys = new Set();
  }

  /* ------------------------------- history ------------------------------- */

  function getHistory() {
    try {
      const value = JSON.parse(localStorage.getItem(HISTORY_KEY) || '[]');
      return Array.isArray(value) ? value : [];
    } catch {
      return [];
    }
  }

  function saveHistory(list) {
    try {
      localStorage.setItem(HISTORY_KEY, JSON.stringify(list.slice(0, 120)));
    } catch {
      /* ignore quota */
    }
  }

  function pushHistory(item) {
    if (!item || !item.vkey) return;
    const list = getHistory().filter((x) => x.vkey !== item.vkey);
    list.unshift({ ...item, at: Date.now() });
    saveHistory(list);
  }

  function updateHistoryProgress(vkey, position, duration) {
    if (!vkey) return;
    try {
      localStorage.setItem(
        POS_KEY + vkey,
        JSON.stringify({ t: position, d: duration, at: Date.now() })
      );
    } catch {
      /* ignore */
    }
    const list = getHistory();
    const entry = list.find((x) => x.vkey === vkey);
    if (entry) {
      entry.position = position;
      entry.durationSec = duration;
      entry.at = Date.now();
      saveHistory(list);
    }
  }

  function getProgress(vkey) {
    try {
      const value = JSON.parse(localStorage.getItem(POS_KEY + vkey) || 'null');
      if (value && typeof value.t === 'number' && value.t > 5) return value;
    } catch {
      /* ignore */
    }
    return null;
  }

  function clearHistory() {
    getHistory().forEach((item) => {
      try {
        localStorage.removeItem(POS_KEY + item.vkey);
      } catch {
        /* ignore */
      }
    });
    saveHistory([]);
  }

  /* ------------------------------- router ------------------------------- */

  const RENDERERS = {
    home: renderHome,
    categories: renderCategories,
    list: renderList,
    video: renderVideo,
    history: renderHistory,
    settings: renderSettings,
  };

  function go(route, options = {}) {
    const { replace = false, force = false } = options;
    if (replace && S.index >= 0) {
      S.stack[S.index] = route;
    } else {
      S.stack = S.stack.slice(0, S.index + 1);
      S.stack.push(route);
      S.index = S.stack.length - 1;
    }
    render({ force });
  }

  function refresh() {
    render({ force: true });
  }

  function back() {
    if (S.index > 0) {
      S.index -= 1;
      render({});
    }
  }

  function forward() {
    if (S.index < S.stack.length - 1) {
      S.index += 1;
      render({});
    }
  }

  function restoreScroll(top) {
    const prev = view.style.scrollBehavior;
    view.style.scrollBehavior = 'auto';
    view.scrollTop = top;
    requestAnimationFrame(() => {
      view.scrollTop = top;
      view.style.scrollBehavior = prev;
    });
  }

  function updateHomeContinueWatching() {
    const box = $('#homeContinueSection', homePane);
    if (!box) return;
    const history = getHistory()
      .filter((x) => x.position > 10)
      .slice(0, 8);
    box.innerHTML = history.length
      ? `<div class="section-title">继续观看<span class="rule"></span><button class="btn small ghost" data-act="history">全部历史</button></div>
         <div class="grid">${history
           .map((h) => card(h, { progress: h.position }))
           .join('')}</div>`
      : '';
  }

  async function render({ force = false } = {}) {
    const seq = ++S.seq;
    const route = S.stack[S.index];
    if (!route) return;
    const previous = S.route;
    S.route = route;

    if (previous && previous.name === 'home') {
      S.homeScrollTop = view.scrollTop;
    }

    destroyPlayer();
    if (previous && previous.name === 'video') {
      // Leaving a video: stop the background download and drop its cache so the
      // next video always starts from a clean slate.
      try {
        await invoke('stop_prefetch');
      } catch {
        /* ignore */
      }
      try {
        await invoke('clear_media_cache');
      } catch {
        /* ignore */
      }
    }
    updateChrome();

    if (route.name === 'home') {
      if (S.homeRendered && !force) {
        subPane.style.display = 'none';
        subPane.innerHTML = '';
        homePane.style.display = '';
        updateHomeContinueWatching();
        restoreScroll(S.homeScrollTop || 0);
        return;
      }

      subPane.style.display = 'none';
      subPane.innerHTML = '';
      homePane.style.display = '';
      S.homeScrollTop = 0;
      restoreScroll(0);
      try {
        await renderHome(route.params || {}, seq, force);
        if (seq === S.seq) S.homeRendered = true;
      } catch (err) {
        if (seq === S.seq) stateError(String(err && err.message ? err.message : err));
      }
      return;
    }

    homePane.style.display = 'none';
    subPane.style.display = '';
    restoreScroll(0);
    const fn = RENDERERS[route.name];
    if (!fn) return;
    try {
      await fn(route.params || {}, seq, force);
    } catch (err) {
      if (seq === S.seq) stateError(String(err && err.message ? err.message : err));
    }
  }

  function updateChrome() {
    const route = S.route || {};
    const navMap = { home: 'home', categories: 'categories', history: 'history', settings: 'settings' };
    let active = navMap[route.name] || '';
    if (route.name === 'list') {
      if (route.params && route.params.nav) active = route.params.nav;
    }
    $$('#sideNav .navitem').forEach((btn) => {
      btn.classList.toggle('active', btn.dataset.nav === active);
    });
    $('#navBack').disabled = S.index <= 0;
    $('#navForward').disabled = S.index >= S.stack.length - 1;
    $('#accountBtn').classList.toggle('on', !!(S.account && S.account.loggedIn));
    updateSideAccount();
    updateConnState();
  }

  /* ------------------------------- chrome ------------------------------- */

  function updateSideAccount() {
    const box = $('#sideAccountBody');
    const button = $('#accountBtn');
    const name = $('#accountName');
    const avatar = $('#accountAvatar');
    if (S.account && S.account.loggedIn) {
      const label = S.account.username || '已登录';
      button.classList.add('on');
      name.textContent = label;
      avatar.textContent = label.slice(0, 1);
      box.innerHTML = `已登录 <b>${esc(label)}</b><br><span class="mini-link" data-act="account">管理账号</span>`;
    } else {
      button.classList.remove('on');
      name.textContent = '登录';
      avatar.textContent = '?';
      box.innerHTML = `未登录<br><span class="mini-link" data-act="login">登录账号，同步偏好</span>`;
    }
    $$('#sideAccountBody [data-act]').forEach((el) => {
      el.addEventListener('click', () => {
        if (el.dataset.act === 'login') openLogin();
        else openAccount();
      });
    });
  }

  function updateConnState() {
    const el = $('#connState');
    if (!S.settings) {
      el.textContent = '正在读取设置…';
      return;
    }
    const p = S.settings.proxy || {};
    el.classList.remove('bad');
    el.textContent = p.enabled
      ? `代理 ${p.host}:${p.port} · ${S.connected === false ? '连接异常' : '已启用'}`
      : '直连模式 · 未使用代理';
    if (S.connected === false) el.classList.add('bad');
  }

  /* ------------------------------ templates ------------------------------ */

  function skeletonGrid(count = 12) {
    return `<div class="grid">${Array.from({ length: count })
      .map(
        () => `<div class="card"><div class="sk thumb-sk"></div><div class="sk line"></div><div class="sk line short"></div></div>`
      )
      .join('')}</div>`;
  }

  function card(item, opts = {}) {
    const progress =
      opts.progress && item.durationSec ? Math.min(100, (opts.progress / item.durationSec) * 100) : 0;
    return `<div class="card" data-vkey="${esc(item.vkey)}" data-title="${esc(item.title)}">
      <div class="thumb">
        <img loading="lazy" src="${esc(imgUrl(item.thumb))}" alt="" />
        ${item.duration ? `<span class="dur">${esc(item.duration)}</span>` : ''}
        ${progress > 1 ? `<div class="progress-line"><i style="width:${progress.toFixed(1)}%"></i></div>` : ''}
      </div>
      <div class="card-title">${esc(item.title || '未命名视频')}</div>
      <div class="card-sub">${item.author ? `<span>${esc(item.author)}</span>` : ''}${
        item.views ? `<span>${esc(item.views)}</span>` : ''
      }</div>
    </div>`;
  }

  function stateBox(message, hint = '', actions = '') {
    return `<div class="state">
      <svg viewBox="0 0 24 24"><path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20Zm1 15h-2v-2h2v2Zm0-4h-2V7h2v6Z"/></svg>
      <div class="big">${esc(message)}</div>
      ${hint ? `<div class="hint">${esc(hint)}</div>` : ''}
      ${actions ? `<div class="btnrow">${actions}</div>` : ''}
    </div>`;
  }

  function stateError(message) {
    const pane = S.route && S.route.name === 'home' ? homePane : subPane;
    pane.innerHTML = `<div class="view-inner">${stateBox(
      '加载失败',
      message || '请稍后重试',
      `<button class="btn" data-act="retry">重试</button>
       <button class="btn ghost" data-act="settings">检查代理设置</button>`
    )}</div>`;
  }

  function stateEmpty(message, hint = '') {
    const pane = S.route && S.route.name === 'home' ? homePane : subPane;
    pane.innerHTML = `<div class="view-inner">${stateBox(message, hint, `<button class="btn" data-act="home">回到首页</button>`)}</div>`;
  }

  function pageButtons(current, pages) {
    if (!pages || !pages.length) return '';
    const set = new Set([1, pages[pages.length - 1], current - 1, current, current + 1, current + 2]);
    const list = Array.from(set)
      .filter((p) => p >= 1 && p <= pages[pages.length - 1])
      .sort((a, b) => a - b);
    let html = `<button class="pagebtn" data-page="${current - 1}" ${current <= 1 ? 'disabled' : ''}>‹</button>`;
    let prev = 0;
    for (const p of list) {
      if (prev && p - prev > 1) html += `<span class="pagegap">…</span>`;
      html += `<button class="pagebtn ${p === current ? 'active' : ''}" data-page="${p}">${p}</button>`;
      prev = p;
    }
    html += `<button class="pagebtn" data-page="${current + 1}" ${
      current >= pages[pages.length - 1] ? 'disabled' : ''
    }>›</button>`;
    return `<div class="pagination">${html}</div>`;
  }

  /* ------------------------------- pages ------------------------------- */

  async function renderHome(params, seq, force) {
    homePane.innerHTML = `<div class="view-inner">${skeletonGrid(14)}</div>`;
    S.homePage = 1;
    S.homeLoading = false;
    S.homeHasMore = true;
    S.seenHomeVkeys = new Set();

    let data;
    try {
      data = await cached('get_home', { page: 1, force: !!force }, 'home:1', force);
    } catch (err) {
      if (seq === S.seq) stateError(String(err));
      return;
    }
    if (seq !== S.seq) return;
    S.connected = true;
    updateConnState();

    const items = (data && data.items) || [];
    if (!items.length) {
      stateEmpty('首页暂时没有内容', '可能是代理未生效或站点结构发生变化，试试刷新。');
      return;
    }
    const hero = items[0];
    const rest = items.slice(1);
    if (hero && hero.vkey) S.seenHomeVkeys.add(hero.vkey);
    rest.forEach((x) => x.vkey && S.seenHomeVkeys.add(x.vkey));

    const history = getHistory()
      .filter((x) => x.position > 10)
      .slice(0, 8);

    homePane.innerHTML = `<div class="view-inner">
      <div class="hero" data-vkey="${esc(hero.vkey)}" data-title="${esc(hero.title)}">
        <div class="hero-img" style="background-image:url('${esc(imgUrl(hero.thumb))}')"></div>
        <div class="hero-body">
          <div class="hero-badge">${icons('star')} 今日推荐</div>
          <h1 class="hero-title">${esc(hero.title)}</h1>
          <div class="hero-meta">
            ${hero.duration ? `<span>${esc(hero.duration)}</span>` : ''}
            ${hero.views ? `<span class="dot">${esc(hero.views)}</span>` : ''}
            ${hero.author ? `<span class="dot">${esc(hero.author)}</span>` : ''}
          </div>
          <div class="hero-actions">
            <button class="btn primary" data-vkey="${esc(hero.vkey)}" data-title="${esc(hero.title)}">${icons('play')} 立即播放</button>
            <button class="btn ghost" data-act="refresh-home">${icons('refresh')} 刷新推荐</button>
          </div>
        </div>
      </div>
      <div id="homeContinueSection">
      ${
        history.length
          ? `<div class="section-title">继续观看<span class="rule"></span><button class="btn small ghost" data-act="history">全部历史</button></div>
             <div class="grid">${history
               .map((h) => card(h, { progress: h.position }))
               .join('')}</div>`
          : ''
      }
      </div>
      <div class="section-title">为你推荐<span class="rule"></span></div>
      <div class="grid" id="homeFeedGrid">${rest.map((item) => card(item)).join('')}</div>
      <div id="homeLoadingMore" class="loading-more" style="display:none;"><span class="spinner"></span> 正在加载更多推荐…</div>
      <div id="homeNoMore" class="loading-more" style="display:none; color:var(--muted); font-size:13px;">已加载全部推荐</div>
    </div>`;
  }

  async function loadMoreHome() {
    if (S.homeLoading || !S.homeHasMore) return;
    if (!S.route || S.route.name !== 'home') return;
    const feedGrid = $('#homeFeedGrid', homePane);
    if (!feedGrid) return;

    S.homeLoading = true;
    const loadingEl = $('#homeLoadingMore', homePane);
    const noMoreEl = $('#homeNoMore', homePane);
    if (loadingEl) loadingEl.style.display = 'flex';
    if (noMoreEl) noMoreEl.style.display = 'none';

    const nextPage = S.homePage + 1;
    try {
      const data = await cached('get_home', { page: nextPage }, `home:${nextPage}`, false);
      const items = (data && data.items) || [];
      if (!items.length) {
        S.homeHasMore = false;
        if (loadingEl) loadingEl.style.display = 'none';
        if (noMoreEl) noMoreEl.style.display = 'flex';
        return;
      }
      const unique = items.filter((it) => it.vkey && !S.seenHomeVkeys.has(it.vkey));
      unique.forEach((it) => S.seenHomeVkeys.add(it.vkey));

      if (unique.length > 0) {
        const cardsHtml = unique.map((it) => card(it)).join('');
        feedGrid.insertAdjacentHTML('beforeend', cardsHtml);
      }
      S.homePage = nextPage;
      if (items.length < 10) {
        S.homeHasMore = false;
        if (noMoreEl) noMoreEl.style.display = 'flex';
      }
    } catch (err) {
      console.warn('加载更多推荐失败:', err);
    } finally {
      S.homeLoading = false;
      if (loadingEl) loadingEl.style.display = 'none';
    }
  }

  async function renderCategories(params, seq, force) {
    subPane.innerHTML = `<div class="view-inner">
      <div class="page-head"><div><h1 class="page-title">全部分类</h1><div class="page-sub">按类别浏览视频</div></div></div>
      ${skeletonGrid(18)}
    </div>`;
    let data;
    try {
      data = await cached('get_categories', { force: !!force }, 'categories', force);
    } catch (err) {
      if (seq === S.seq) stateError(String(err));
      return;
    }
    if (seq !== S.seq) return;
    const items = (data && data.items) || [];
    if (!items.length) {
      stateEmpty('没有读取到分类', '站点可能临时限制了访问，稍后再试。');
      return;
    }
    subPane.innerHTML = `<div class="view-inner">
      <div class="page-head"><div><h1 class="page-title">全部分类</h1><div class="page-sub">共 ${items.length} 个分类</div></div>
        <button class="btn small ghost" data-act="refresh-cats">${icons('refresh')} 刷新</button>
      </div>
      <div class="cat-grid">${items
        .map(
          (c) => `<div class="cat" data-cat="${esc(c.href)}" data-catname="${esc(c.name)}">
            <img loading="lazy" src="${esc(imgUrl(c.thumb))}" alt="" />
            <div class="cat-body">
              <div class="cat-name">${esc(c.name)}</div>
              <div class="cat-count">${esc(c.count || '')}</div>
            </div>
          </div>`
        )
        .join('')}</div>
    </div>`;
  }

  const SORTS = [
    { key: 'ht', label: '最热' },
    { key: 'mv', label: '最多观看' },
    { key: 'tr', label: '评分最高' },
    { key: 'cm', label: '最新' },
  ];

  async function renderList(params, seq, force) {
    const rawPath = params.path || '/video';
    const path = toRelativePath(rawPath);
    const page = params.page || 1;
    const navKey = params.nav || '';
    const heading = params.title || '';
    subPane.innerHTML = `<div class="view-inner">
      <div class="page-head"><div><h1 class="page-title">${esc(heading || '视频列表')}</h1><div class="page-sub">加载中…</div></div></div>
      ${skeletonGrid(16)}
    </div>`;
    let data;
    try {
      data = await cached('get_list', { path, page, force: !!force }, `list:${path}:${page}`, force);
    } catch (err) {
      if (seq === S.seq) stateError(String(err));
      return;
    }
    if (seq !== S.seq) return;

    const items = (data && data.items) || [];
    const title = heading || data.title || '视频列表';
    const current = data.current || page;
    const pages = data.pages || [];
    const sort = param(path, 'o');
    const isSearch = path.includes('search');
    const sorts = SORTS.filter((s) => s.key !== 'ht' || !/[?&]c=/.test(path));

    subPane.innerHTML = `<div class="view-inner">
      <div class="page-head">
        <div>
          <h1 class="page-title">${esc(title)}</h1>
          <div class="page-sub">第 ${current} 页 · ${items.length} 个结果${isSearch ? ` · 搜索“${esc(param(path, 'search') || '')}”` : ''}</div>
        </div>
        <div class="head-actions">
          ${
            isSearch
              ? ''
              : sorts.map(
                  (s) =>
                    `<button class="chip ${sort === s.key ? 'active' : ''}" data-sort="${s.key}">${s.label}</button>`
                ).join('')
          }
        </div>
      </div>
      ${
        items.length
          ? `<div class="grid">${items.map((item) => card(item)).join('')}</div>${pageButtons(current, pages)}`
          : stateBox('没有找到视频', '换个关键词或分类试试。', `<button class="btn" data-act="categories">浏览分类</button>`)
      }
    </div>`;
  }

  function destroyPlayer() {
    if (window.__player && typeof window.__player.destroy === 'function') {
      try {
        window.__player.destroy();
      } catch {
        /* ignore */
      }
    }
    window.__player = null;
  }

  async function renderVideo(params, seq, force) {
    const vkey = params.vkey;
    if (!vkey) {
      stateEmpty('视频编号缺失');
      return;
    }
    subPane.innerHTML = `<div class="view-inner">
      <div class="video-layout">
        <div>
          <div class="player-wrap"><div class="center-load"><span class="spinner"></span> 正在解析视频地址…</div></div>
        </div>
      </div>
    </div>`;
    let data;
    try {
      data = await cached('get_video', { vkey, force: !!force }, `video:${vkey}`, force);
    } catch (err) {
      if (seq === S.seq) stateError(String(err));
      return;
    }
    if (seq !== S.seq) return;

    const related = data.related || [];
    const progress = getProgress(vkey);
    const categories = (data.categories || [])
      .map((c) => `<button class="chip tag" data-cat="${esc(c.href)}" data-catname="${esc(c.name)}">${esc(c.name)}</button>`)
      .join('');
    const tags = (data.tags || [])
      .slice(0, 24)
      .map((t) => `<button class="chip tag" data-cat="${esc(t.href)}" data-catname="${esc(t.name)}">${esc(t.name)}</button>`)
      .join('');

    subPane.innerHTML = `<div class="view-inner">
      <div class="video-layout">
        <div class="video-main">
          <div class="player-wrap" id="playerMount"></div>
          <div class="player-note hidden" id="prefetchNote"></div>
          <div class="video-head">
            <h1 class="video-title">${esc(data.title || '未命名视频')}</h1>
            <div class="video-meta">
              ${data.views ? `<span>${esc(data.views)} 次观看</span>` : ''}
              ${data.publish ? `<span class="dot">${esc(data.publish)}</span>` : ''}
              ${data.duration ? `<span class="dot">${esc(fmtTime(data.duration))}</span>` : ''}
            </div>
            <div class="video-actions">
              <button class="btn small" data-act="refresh-video">${icons('refresh')} 刷新播放地址</button>
              <button class="btn small ghost" data-act="open-browser">${icons('external')} 在浏览器打开</button>
              ${
                progress
                  ? `<button class="btn small ghost" data-act="restart">${icons('clock')} 从头播放</button>`
                  : ''
              }
            </div>
            ${
              data.author
                ? `<div class="video-author">
                    <img src="${esc(imgUrl(data.avatar))}" alt="" />
                    <div><div class="name">${esc(data.author)}</div><div class="role">上传者</div></div>
                  </div>`
                : ''
            }
          </div>
        </div>
        <aside class="video-side">
          <div class="side-panel">
            <h3>相关推荐</h3>
            <div class="side-rel">
              ${
                related.length
                  ? related
                      .map(
                        (item) => `<div class="rel-item" data-vkey="${esc(item.vkey)}" data-title="${esc(item.title)}">
                          <div class="rel-thumb">
                            <img loading="lazy" src="${esc(imgUrl(item.thumb))}" alt="" />
                            ${item.duration ? `<span class="dur">${esc(item.duration)}</span>` : ''}
                          </div>
                          <div class="rel-body">
                            <div class="rel-title">${esc(item.title)}</div>
                            <div class="rel-sub">${esc(item.author || '')}${item.views ? ` · ${esc(item.views)}` : ''}</div>
                          </div>
                        </div>`
                      )
                      .join('')
                  : '<div class="side-card-body">暂无相关推荐</div>'
              }
            </div>
          </div>
          ${
            categories || tags
              ? `<div class="side-panel"><h3>分类</h3><div class="chips">${categories}</div>
                 ${tags ? `<h3 style="margin-top:14px">标签</h3><div class="chips">${tags}</div>` : ''}</div>`
              : ''
          }
        </aside>
      </div>
    </div>`;

    const mount = $('#playerMount');
    if (!data.sources || !data.sources.length) {
      mount.innerHTML = `<div class="player-error">
        <div>
          <div>该视频当前不可播放${data.unavailable ? '（可能已删除、需要登录或受地区限制）' : ''}</div>
          <button class="btn primary" data-act="open-browser">在浏览器中打开</button>
        </div>
      </div>`;
      return;
    }

    window.__player = new Player(mount, {
      sources: data.sources,
      poster: data.image || (related[0] && related[0].thumb) || '',
      vkey,
      title: data.title,
      duration: data.duration,
      resume: progress ? progress.t : 0,
    });
  }

  function renderHistory() {
    const list = getHistory();
    if (!list.length) {
      stateEmpty('还没有观看记录', '看过的视频会自动出现在这里，方便继续观看。');
      return;
    }
    subPane.innerHTML = `<div class="view-inner">
      <div class="page-head">
        <div><h1 class="page-title">观看历史</h1><div class="page-sub">最近 ${list.length} 条记录 · 仅保存在本机</div></div>
        <div class="head-actions">
          <button class="btn small ghost" data-act="clear-history">${icons('trash')} 清空历史</button>
        </div>
      </div>
      <div class="grid">${list
        .map((item) => card(item, { progress: item.position }))
        .join('')}</div>
    </div>`;
  }

  async function renderSettings(params, seq) {
    const settings = S.settings || { domain: 'https://cn.pornhub.com', proxy: { enabled: true, host: '127.0.0.1', port: 7897 } };
    const proxy = settings.proxy || {};
    const account = S.account;
    subPane.innerHTML = `<div class="view-inner" style="max-width:860px">
      <div class="page-head">
        <div><h1 class="page-title">设置</h1><div class="page-sub">网络代理、账号与本地数据</div></div>
        <button class="btn small ghost" data-act="open-site">${icons('external')} 打开官网</button>
      </div>

      <div class="side-panel" style="margin-bottom:14px">
        <h3>网络与代理</h3>
        <div class="field">
          <label for="stDomain">站点域名</label>
          <input id="stDomain" type="text" value="${esc(settings.domain)}" spellcheck="false" />
          <div class="hint">默认 https://cn.pornhub.com，也可以换成其他镜像域名。</div>
        </div>
        <div class="field">
          <label>连接方式</label>
          <select id="stProxy">
            <option value="1" ${proxy.enabled ? 'selected' : ''}>使用本机代理（VPN / Clash 等）</option>
            <option value="0" ${!proxy.enabled ? 'selected' : ''}>直连（不使用代理）</option>
          </select>
        </div>
        <div class="row2">
          <div class="field">
            <label for="stHost">代理地址</label>
            <input id="stHost" type="text" value="${esc(proxy.host || '127.0.0.1')}" spellcheck="false" />
          </div>
          <div class="field">
            <label for="stPort">端口</label>
            <input id="stPort" type="number" min="1" max="65535" value="${esc(proxy.port || 7897)}" />
          </div>
        </div>
        <div class="modal-actions" style="justify-content:flex-start">
          <button class="btn primary" data-act="save-settings">保存并应用</button>
          <button class="btn" data-act="test">测试连接</button>
          <span class="page-sub" id="testResult" style="margin-left:6px"></span>
        </div>
      </div>

      <div class="side-panel" style="margin-bottom:14px">
        <h3>播放与缓存</h3>
        <div class="field">
          <label for="stPrefetch">预缓冲模式</label>
          <select id="stPrefetch">
            <option value="1" ${settings.prefetch !== false ? 'selected' : ''}>点开视频就下载整部视频（推荐）</option>
            <option value="0" ${settings.prefetch === false ? 'selected' : ''}>按需缓冲（只缓冲即将播放的部分）</option>
          </select>
          <div class="hint">开启后，视频一打开就会在后台尽可能把整部视频缓存到本机，之后拖动进度条几乎无需等待。缓存只保留在本次观看期间：退出视频或下次启动应用时会自动清理。</div>
        </div>
      </div>

      <div class="side-panel" style="margin-bottom:14px">
        <h3>账号</h3>
        ${
          account && account.loggedIn
            ? `<div class="account-card" style="margin-bottom:10px">
                 <div class="bigavatar">${esc((account.username || 'U').slice(0, 1))}</div>
                 <div><div class="who">${esc(account.username || '已登录')}</div>
                 <div class="state-line"><span class="dot-online"></span> 已登录，将使用站点个性化推荐</div></div>
               </div>
               <div class="modal-actions" style="justify-content:flex-start">
                 <button class="btn" data-act="account">管理账号</button>
                 <button class="btn ghost danger" data-act="logout">退出登录</button>
               </div>`
            : `<p>登录后可同步收藏、订阅与个性化首页推荐。密码只用于向站点发起登录，不会保存在本机。</p>
               <div class="modal-actions" style="justify-content:flex-start">
                 <button class="btn primary" data-act="login">登录账号</button>
               </div>`
        }
      </div>

      <div class="side-panel" style="margin-bottom:14px">
        <h3>本地数据</h3>
        <div class="kv"><span>页面缓存</span><span>自动缓存 2 分钟，可手动清除</span></div>
        <div class="kv"><span>观看历史</span><span>${getHistory().length} 条，仅保存在本机</span></div>
        <div class="modal-actions" style="justify-content:flex-start">
          <button class="btn small" data-act="clear-cache">清除页面缓存</button>
          <button class="btn small ghost danger" data-act="clear-history">清空观看历史</button>
        </div>
      </div>

      <div class="side-panel">
        <h3>关于</h3>
        <div class="kv"><span>应用</span><span>Pornhub Desktop 1.0.0</span></div>
        <div class="kv"><span>架构</span><span>Tauri + Rust（自解析页面与播放地址）</span></div>
        <div class="kv"><span>媒体代理</span><span>本机 127.0.0.1 随机端口 · 仅本机可访问</span></div>
        <p class="notice">本应用不是简单套壳网页：页面内容与视频地址均由本地服务解析，视频流经本地代理转发。所有数据仅保存在你的电脑上。请遵守所在地区法律法规，仅用于个人学习与娱乐。</p>
      </div>
    </div>`;
  }

  /* ------------------------------- view events ------------------------------- */

  view.addEventListener('click', async (event) => {
    const cardEl = event.target.closest('[data-vkey]');
    const catEl = event.target.closest('[data-cat]');
    const pageEl = event.target.closest('[data-page]');
    const sortEl = event.target.closest('[data-sort]');
    const actionEl = event.target.closest('[data-act]');

    if (cardEl && !actionEl) {
      const vkey = cardEl.dataset.vkey;
      if (vkey) go({ name: 'video', params: { vkey } });
      return;
    }
    if (catEl) {
      const path = toRelativePath(catEl.dataset.cat);
      go({ name: 'list', params: { path, title: catEl.dataset.catname } });
      return;
    }
    if (pageEl) {
      event.preventDefault();
      const page = Number(pageEl.dataset.page);
      const route = S.route;
      if (route && route.name === 'list' && page >= 1) {
        go({ name: 'list', params: { ...route.params, page } });
      }
      return;
    }
    if (sortEl) {
      const route = S.route;
      if (route && route.name === 'list') {
        const cleanP = toRelativePath(route.params.path);
        const path = withParam(cleanP, 'o', sortEl.dataset.sort);
        go({ name: 'list', params: { ...route.params, path, page: 1 } });
      }
      return;
    }
    if (!actionEl) return;

    const act = actionEl.dataset.act;
    switch (act) {
      case 'retry':
        refresh();
        break;
      case 'home':
        go({ name: 'home' });
        break;
      case 'settings':
        go({ name: 'settings' });
        break;
      case 'categories':
        go({ name: 'categories' });
        break;
      case 'history':
        go({ name: 'history' });
        break;
      case 'login':
        openLogin();
        break;
      case 'account':
        openAccount();
        break;
      case 'logout':
        await doLogout();
        break;
      case 'refresh-home':
        for (const k of Array.from(memoryCache.keys())) {
          if (k === 'home' || k.startsWith('home:')) memoryCache.delete(k);
        }
        S.homeRendered = false;
        refresh();
        break;
      case 'refresh-cats':
        memoryCache.delete('categories');
        refresh();
        break;
      case 'refresh-video':
        refresh();
        break;
      case 'open-browser': {
        const route = S.route;
        if (route && route.name === 'video') {
          const base = (S.settings && S.settings.domain) || 'https://cn.pornhub.com';
          invoke('open_external', { url: `${base}/view_video.php?viewkey=${route.params.vkey}` }).catch((e) =>
            toast(String(e), 'bad')
          );
        } else {
          invoke('open_external', { url: (S.settings && S.settings.domain) || 'https://cn.pornhub.com' }).catch((e) =>
            toast(String(e), 'bad')
          );
        }
        break;
      }
      case 'open-site':
        invoke('open_external', { url: (S.settings && S.settings.domain) || 'https://cn.pornhub.com' }).catch((e) =>
          toast(String(e), 'bad')
        );
        break;
      case 'clear-cache':
        clearClientCache();
        try {
          await invoke('clear_cache');
          toast('页面缓存已清除', 'good');
        } catch (e) {
          toast(String(e), 'bad');
        }
        break;
      case 'clear-history':
        clearHistory();
        toast('观看历史已清空', 'good');
        if (S.route && S.route.name === 'history') refresh();
        else if (S.route && S.route.name === 'settings') refresh();
        break;
      case 'restart': {
        const route = S.route;
        if (route && route.name === 'video') {
          try {
            localStorage.removeItem(POS_KEY + route.params.vkey);
          } catch {
            /* ignore */
          }
          memoryCache.delete(`video:${route.params.vkey}`);
          refresh();
        }
        break;
      }
      case 'save-settings':
        await saveSettings();
        break;
      case 'test':
        await testConnection();
        break;
      default:
        break;
    }
  });

  /* ------------------------------- settings ------------------------------- */

  async function saveSettings() {
    const domain = $('#stDomain').value.trim();
    const enabled = $('#stProxy').value === '1';
    const host = $('#stHost').value.trim() || '127.0.0.1';
    const port = Number($('#stPort').value) || 7897;
    const prefetchEl = $('#stPrefetch');
    const prefetch = prefetchEl ? prefetchEl.value === '1' : true;
    if (!domain) {
      toast('请填写站点域名', 'bad');
      return;
    }
    const next = {
      domain,
      proxy: { enabled, host, port },
      accountName: (S.settings && S.settings.accountName) || '',
      prefetch,
    };
    try {
      const info = await invoke('save_settings', { settings: next });
      S.settings = info.settings;
      S.mediaBase = info.mediaBase || S.mediaBase;
      clearClientCache();
      toast('设置已保存并生效', 'good');
      updateConnState();
      renderSettings({}, S.seq);
    } catch (e) {
      toast(String(e), 'bad');
    }
  }

  async function testConnection() {
    const out = $('#testResult');
    if (out) out.textContent = '测试中…';
    try {
      const res = await invoke('test_connection');
      S.connected = !!res.ok;
      const text = `${res.ok ? '连接正常' : '连接失败'} · ${res.ms}ms · ${res.message}`;
      if (out) out.textContent = text;
      toast(text, res.ok ? 'good' : 'bad');
      updateConnState();
      if (res.loggedIn && (!S.account || !S.account.loggedIn)) refreshAccount();
    } catch (e) {
      S.connected = false;
      if (out) out.textContent = String(e);
      toast(String(e), 'bad');
      updateConnState();
    }
  }

  /* ------------------------------- account ------------------------------- */

  let accountBusy = false;

  async function refreshAccount() {
    if (accountBusy) return;
    accountBusy = true;
    try {
      const account = await invoke('get_account');
      S.account = account;
      updateSideAccount();
      updateChrome();
      if (S.route && S.route.name === 'settings') refresh();
    } catch {
      /* offline: keep previous state */
    } finally {
      accountBusy = false;
    }
  }

  async function doLogout() {
    try {
      await invoke('logout');
      S.account = { loggedIn: false, username: '' };
      if (S.settings) S.settings.accountName = '';
      updateChrome();
      toast('已退出登录，本地 Cookie 已清除', 'good');
      clearClientCache();
      if (S.route && (S.route.name === 'home' || S.route.name === 'settings')) refresh();
    } catch (e) {
      toast(String(e), 'bad');
    }
  }

  function openModal(inner, opts = {}) {
    const mask = document.createElement('div');
    mask.className = 'modal-mask';
    mask.innerHTML = `<div class="modal${opts.wide ? ' wide' : ''}">${inner}</div>`;
    document.body.appendChild(mask);
    const close = () => {
      mask.remove();
      document.removeEventListener('keydown', onKey);
    };
    const onKey = (e) => {
      if (e.key === 'Escape') close();
    };
    document.addEventListener('keydown', onKey);
    mask.addEventListener('mousedown', (e) => {
      if (e.target === mask) close();
    });
    $$('[data-close]', mask).forEach((el) => el.addEventListener('click', close));
    return { close, root: mask.querySelector('.modal') };
  }

  function openAccount() {
    const logged = S.account && S.account.loggedIn;
    const name = (S.account && S.account.username) || '用户';
    const { close } = openModal(
      `<div class="modal-head"><h2>账号</h2><button class="modal-x" data-close>&times;</button></div>
       <div class="modal-body">
         ${
           logged
             ? `<div class="account-card">
                  <div class="bigavatar">${esc(name.slice(0, 1))}</div>
                  <div><div class="who">${esc(name)}</div>
                  <div class="state-line"><span class="dot-online"></span> 已登录 · Cookie 已保存在本机</div></div>
                </div>
                <div class="notice">登录状态用于获取个性化首页推荐、订阅与收藏。若站点登录过期，可重新登录或使用“浏览器 Cookie”方式。</div>
                <div class="modal-actions" style="margin-top:14px">
                  <button class="btn ghost" data-close>关闭</button>
                  <button class="btn" id="accRefresh">刷新状态</button>
                  <button class="btn danger" id="accLogout">退出登录</button>
                </div>`
             : `<p>尚未登录。登录后应用会记住站点 Cookie，为你加载个性化推荐。</p>
                <div class="modal-actions"><button class="btn primary" id="accLogin">去登录</button></div>`
         }
       </div>`
    );
    const refreshBtn = $('#accRefresh');
    if (refreshBtn) {
      refreshBtn.addEventListener('click', async () => {
        refreshBtn.disabled = true;
        refreshBtn.textContent = '检查中…';
        await refreshAccount();
        close();
        if (S.account && S.account.loggedIn) toast('登录状态正常', 'good');
        else toast('登录状态已过期，请重新登录', 'bad');
      });
    }
    const logoutBtn = $('#accLogout');
    if (logoutBtn) {
      logoutBtn.addEventListener('click', async () => {
        close();
        await doLogout();
      });
    }
    const loginBtn = $('#accLogin');
    if (loginBtn) {
      loginBtn.addEventListener('click', () => {
        close();
        openLogin();
      });
    }
  }

  function openLogin() {
    const { root, close } = openModal(
      `<div class="modal-head"><h2>登录账号</h2><button class="modal-x" data-close>&times;</button></div>
       <div class="modal-body">
         <div class="tabs">
           <button data-tab="cred" class="active">账号密码</button>
           <button data-tab="cookie">浏览器 Cookie</button>
         </div>
         <div id="loginPane"></div>
       </div>`
    );

    const pane = $('#loginPane', root);
    const tabCred = $('[data-tab="cred"]', root);
    const tabCookie = $('[data-tab="cookie"]', root);

    function showCred() {
      tabCred.classList.add('active');
      tabCookie.classList.remove('active');
      pane.innerHTML = `
        <form id="loginForm" autocomplete="off">
          <div class="form-error" id="loginError"></div>
          <div class="field">
            <label for="lgEmail">邮箱 / 用户名</label>
            <input id="lgEmail" type="text" spellcheck="false" autocomplete="username" />
          </div>
          <div class="field">
            <label for="lgPass">密码</label>
            <input id="lgPass" type="password" autocomplete="current-password" />
          </div>
          <div class="modal-actions">
            <button type="button" class="btn ghost" data-close>取消</button>
            <button type="submit" class="btn primary" id="lgSubmit">登录</button>
          </div>
        </form>
        <div class="notice">密码仅用于向站点提交登录请求，不会保存在本机；登录成功后只保存站点 Cookie。</div>`;
      const form = $('#loginForm', pane);
      const error = $('#loginError', pane);
      const submit = $('#lgSubmit', pane);
      form.addEventListener('submit', async (e) => {
        e.preventDefault();
        const email = $('#lgEmail', pane).value.trim();
        const password = $('#lgPass', pane).value;
        error.classList.remove('show');
        if (!email || !password) {
          error.textContent = '请输入邮箱和密码';
          error.classList.add('show');
          return;
        }
        submit.disabled = true;
        submit.innerHTML = '<span class="spinner"></span> 登录中…';
        try {
          const res = await invoke('login', { email, password });
          handleLoginResult(res);
        } catch (err) {
          const message = String(err);
          error.textContent = message;
          error.classList.add('show');
          if (message.includes('Cookie')) {
            tabCookie.click();
            toast('请改用“浏览器 Cookie”方式登录', 'bad');
          }
        } finally {
          submit.disabled = false;
          submit.textContent = '登录';
        }
      });
      setTimeout(() => $('#lgEmail', pane).focus(), 60);
    }

    function showCookie() {
      tabCookie.classList.add('active');
      tabCred.classList.remove('active');
      pane.innerHTML = `
        <div class="form-error" id="cookieError"></div>
        <div class="field">
          <label for="lgCookie">Cookie 请求头</label>
          <textarea id="lgCookie" placeholder="粘贴浏览器里的整行 Cookie，例如：cookieA=...; cookieB=..."></textarea>
          <div class="hint">在浏览器登录 cn.pornhub.com 后，按 F12 → 网络(Network) → 任选一个请求 → 请求标头(Request Headers) → 复制 Cookie 一整行。</div>
        </div>
        <div class="modal-actions">
          <button class="btn ghost" data-close>取消</button>
          <button class="btn primary" id="lgCookieSubmit">导入并登录</button>
        </div>
        <div class="notice">适用于站点要求人机验证或 Google/第三方登录的情况。Cookie 只保存在本机应用数据目录中。</div>`;
      const error = $('#cookieError', pane);
      const submit = $('#lgCookieSubmit', pane);
      submit.addEventListener('click', async () => {
        const header = $('#lgCookie', pane).value.trim();
        error.classList.remove('show');
        if (!header) {
          error.textContent = '请先粘贴 Cookie';
          error.classList.add('show');
          return;
        }
        submit.disabled = true;
        submit.innerHTML = '<span class="spinner"></span> 验证中…';
        try {
          const account = await invoke('import_cookies', { header });
          S.account = account;
          if (S.settings) S.settings.accountName = account.username;
          updateChrome();
          close();
          toast(`已登录：${account.username || '账号'}`, 'good');
          clearClientCache();
          refresh();
        } catch (err) {
          error.textContent = String(err);
          error.classList.add('show');
        } finally {
          submit.disabled = false;
          submit.textContent = '导入并登录';
        }
      });
    }

    function showTwoFactor(challenge) {
      const type = challenge.twoStepType || 'existingLegacy';
      const google = /google|authy|totp/i.test(type);
      const email = challenge.email || challenge.username || '';
      pane.innerHTML = `
        <div class="form-error" id="twofaError"></div>
        <p style="margin-top:0">${
          google
            ? '该账号启用了两步验证，请输入验证器 App 中的 6 位验证码。'
            : `该账号启用了两步验证，验证码已发送${email ? `到 ${esc(email)}` : '到你的邮箱/手机'}。`
        }</p>
        <div class="field">
          <label for="lgCode">验证码</label>
          <input id="lgCode" type="text" inputmode="numeric" maxlength="8" autocomplete="one-time-code" />
        </div>
        <div class="modal-actions">
          <button class="btn ghost" id="twofaBack">返回</button>
          <button class="btn primary" id="twofaSubmit">验证</button>
        </div>`;
      setTimeout(() => $('#lgCode', pane).focus(), 60);
      $('#twofaBack', pane).addEventListener('click', showCred);
      const submit = $('#twofaSubmit', pane);
      const error = $('#twofaError', pane);
      const send = async () => {
        const code = $('#lgCode', pane).value.trim();
        error.classList.remove('show');
        if (!code) {
          error.textContent = '请输入验证码';
          error.classList.add('show');
          return;
        }
        submit.disabled = true;
        submit.innerHTML = '<span class="spinner"></span> 验证中…';
        try {
          const res = await invoke('login_2fa', { challenge, code });
          handleLoginResult(res);
        } catch (err) {
          error.textContent = String(err);
          error.classList.add('show');
        } finally {
          submit.disabled = false;
          submit.textContent = '验证';
        }
      };
      submit.addEventListener('click', send);
      $('#lgCode', pane).addEventListener('keydown', (e) => {
        if (e.key === 'Enter') send();
      });
    }

    function handleLoginResult(res) {
      if (res && res.status === 'twoFactor') {
        showTwoFactor(res);
        return;
      }
      if (res && res.status === 'ok') {
        S.account = { loggedIn: true, username: res.username || '' };
        if (S.settings) S.settings.accountName = res.username || '';
        updateChrome();
        close();
        toast(`欢迎回来${res.username ? '，' + res.username : ''}`, 'good');
        clearClientCache();
        refresh();
      }
    }

    tabCred.addEventListener('click', showCred);
    tabCookie.addEventListener('click', showCookie);
    showCred();
  }

  /* ------------------------------- player ------------------------------- */

  class Player {
    constructor(mount, options) {
      this.mount = mount;
      this.options = options;
      this.sources = (options.sources || []).slice();
      this.vkey = options.vkey;
      this.title = options.title || '';
      this.poster = options.poster || '';
      this.hls = null;
      this.menuKind = '';
      this.idleTimer = 0;
      this.lastSave = 0;
      this.started = false;
      this.resumeAt = options.resume || 0;
      this.restored = false;
      this.destroyed = false;
      this.prefetchTimer = 0;

      mount.innerHTML = this.template();
      this.video = $('video', mount);
      this.wrap = mount;
      this.bigplay = $('.p-bigplay', mount);
      this.controls = $('.p-controls', mount);
      this.seek = $('.p-seek', mount);
      this.played = $('.p-seek .played', mount);
      this.buffered = $('.p-seek .buffered', mount);
      this.knob = $('.p-seek .knob', mount);
      this.cur = $('.p-time .cur', mount);
      this.tot = $('.p-time .tot', mount);
      this.menu = $('.p-menu', mount);
      this.errorBox = $('.player-error', mount);
      this.pToast = $('.p-toast', mount);

      this.bind();
      this.startSource();
      this.scheduleIdle();
    }

    template() {
      return `<video playsinline preload="metadata" ${this.poster ? `poster="${esc(imgUrl(this.poster))}"` : ''}></video>
        <div class="p-bigplay"><button aria-label="播放">${icons('play')}</button></div>
        <div class="p-controls">
          <div class="p-seekrow">
            <div class="p-seek">
              <div class="track"><div class="buffered"></div><div class="played"></div></div>
              <div class="knob"></div>
            </div>
            <div class="p-time"><span class="cur">0:00</span><span> / </span><span class="tot">--:--</span></div>
          </div>
          <div class="p-btns">
            <button class="pbtn" data-p="toggle" title="播放/暂停">${icons('play')}</button>
            <div class="p-vol">
              <button class="pbtn small" data-p="mute" title="静音">${icons('volume')}</button>
              <input type="range" min="0" max="1" step="0.02" value="1" aria-label="音量" />
            </div>
            <div class="p-spacer"></div>
            <button class="pbtn small" data-p="rate" title="播放速度">1×</button>
            <button class="pbtn small" data-p="quality" title="画质">自动</button>
            <button class="pbtn small" data-p="pip" title="画中画">${icons('pip')}</button>
            <button class="pbtn small" data-p="full" title="全屏">${icons('full')}</button>
          </div>
        </div>
        <div class="p-menu"></div>
        <div class="p-toast"></div>
        <div class="player-error hidden"></div>`;
    }

    bind() {
      const video = this.video;
      this.togglePlay = () => {
        if (video.paused) video.play().catch(() => {});
        else video.pause();
      };

      $('.p-bigplay button', this.wrap).addEventListener('click', (e) => {
        e.stopPropagation();
        this.togglePlay();
      });
      video.addEventListener('click', () => this.togglePlay());
      video.addEventListener('dblclick', () => this.toggleFullscreen());

      this.wrap.addEventListener('mousemove', () => this.wake());
      this.wrap.addEventListener('mouseleave', () => this.scheduleIdle());

      $('[data-p="toggle"]', this.wrap).addEventListener('click', () => this.togglePlay());
      $('[data-p="mute"]', this.wrap).addEventListener('click', () => {
        video.muted = !video.muted;
        this.syncVolume();
      });
      const vol = $('.p-vol input', this.wrap);
      vol.addEventListener('input', () => {
        video.volume = Number(vol.value);
        video.muted = video.volume === 0;
        this.syncVolume();
      });
      $('[data-p="rate"]', this.wrap).addEventListener('click', (e) => {
        e.stopPropagation();
        this.openMenu('rate');
      });
      $('[data-p="quality"]', this.wrap).addEventListener('click', (e) => {
        e.stopPropagation();
        this.openMenu('quality');
      });
      $('[data-p="pip"]', this.wrap).addEventListener('click', () => {
        if (!document.pictureInPictureEnabled) {
          this.flash('当前环境不支持画中画');
          return;
        }
        if (document.pictureInPictureElement) document.exitPictureInPicture().catch(() => {});
        else video.requestPictureInPicture().catch(() => this.flash('无法进入画中画'));
      });
      $('[data-p="full"]', this.wrap).addEventListener('click', () => this.toggleFullscreen());

      document.addEventListener('fullscreenchange', this.onFullscreen = () => {
        const active = document.fullscreenElement === this.wrap;
        $('[data-p="full"]', this.wrap).innerHTML = icons(active ? 'exitfull' : 'full');
      });

      video.addEventListener('play', () => {
        $('.p-bigplay', this.wrap).classList.add('hidden');
        $('[data-p="toggle"]', this.wrap).innerHTML = icons('pause');
        this.scheduleIdle();
        if (!this.started) {
          this.started = true;
          pushHistory({
            vkey: this.vkey,
            title: this.title,
            thumb: this.poster,
            duration: fmtTime(this.options.duration || 0),
            author: '',
            position: 0,
            durationSec: this.options.duration || 0,
          });
        }
      });
      video.addEventListener('pause', () => {
        $('.p-bigplay', this.wrap).classList.remove('hidden');
        $('[data-p="toggle"]', this.wrap).innerHTML = icons('play');
        this.wake();
        this.saveProgress(true);
      });
      video.addEventListener('ended', () => {
        $('.p-bigplay', this.wrap).classList.remove('hidden');
        this.saveProgress(true);
      });

      video.addEventListener('loadedmetadata', () => {
        this.tot.textContent = fmtTime(video.duration);
        this.applyResume();
      });
      video.addEventListener('timeupdate', () => {
        this.renderProgress();
        this.saveProgress(false);
      });
      video.addEventListener('progress', () => this.renderBuffered());
      video.addEventListener('volumechange', () => this.syncVolume());
      video.addEventListener('waiting', () => this.flash('缓冲中…'));
      video.addEventListener('error', () => {
        if (!this.hls) this.fail('视频加载失败，可能是地址已过期。');
      });

      this.seek.addEventListener('pointerdown', (e) => {
        e.preventDefault();
        this.seeking = true;
        this.seek.setPointerCapture(e.pointerId);
        this.seekTo(e);
      });
      this.seek.addEventListener('pointermove', (e) => {
        if (this.seeking) this.seekTo(e, false);
      });
      this.seek.addEventListener('pointerup', (e) => {
        if (this.seeking) {
          this.seekTo(e, true);
          this.seeking = false;
        }
      });

      this.onKey = (e) => {
        if ($('.modal-mask')) return;
        if (e.target && /INPUT|TEXTAREA|SELECT/.test(e.target.tagName)) return;
        if (e.ctrlKey || e.altKey || e.metaKey) return;
        switch (e.key) {
          case ' ':
          case 'k':
            e.preventDefault();
            this.togglePlay();
            break;
          case 'ArrowRight':
            e.preventDefault();
            this.nudge(5);
            break;
          case 'ArrowLeft':
            e.preventDefault();
            this.nudge(-5);
            break;
          case 'ArrowUp':
            e.preventDefault();
            video.volume = Math.min(1, video.volume + 0.05);
            break;
          case 'ArrowDown':
            e.preventDefault();
            video.volume = Math.max(0, video.volume - 0.05);
            break;
          case 'm':
            video.muted = !video.muted;
            break;
          case 'f':
            this.toggleFullscreen();
            break;
          default:
            return;
        }
        this.wake();
      };
      document.addEventListener('keydown', this.onKey);

      this.onDocClick = (e) => {
        if (!this.menu.contains(e.target)) this.closeMenu();
      };
      document.addEventListener('click', this.onDocClick);
    }

    async autoRefreshStream() {
      if (this.refreshing || this.destroyed || !this.vkey) return false;
      this.refreshing = true;
      this.flash('播放地址已失效，正在自动刷新…');
      try {
        const savedTime = this.video.currentTime || this.resumeAt || 0;
        const data = await invoke('get_video', { vkey: this.vkey, force: true });
        if (this.destroyed) return false;
        const sources = (data && data.sources) || [];
        const validSources = sources.filter((s) => s && s.url);
        if (!validSources.length) throw new Error('未获取到有效播放地址');
        this.sources = validSources;
        this.resumeAt = savedTime;
        this.restored = false;
        const preferred =
          validSources.find((s) => s.isDefault) ||
          validSources.slice().sort((a, b) => (b.height || 0) - (a.height || 0))[0];
        this.load(preferred);
        this.flash('已自动恢复播放');
        return true;
      } catch (err) {
        this.fail('视频流加载失败，请手动刷新播放地址。');
        return false;
      } finally {
        this.refreshing = false;
      }
    }

    startSource() {
      const sources = this.sources.filter((s) => s && s.url);
      if (!sources.length) {
        this.fail('没有可用的播放地址');
        return;
      }
      const preferred =
        sources.find((s) => s.isDefault) ||
        sources.slice().sort((a, b) => (b.height || 0) - (a.height || 0))[0];
      this.load(preferred);
    }

    load(source) {
      if (!source) return;
      this.current = source;
      this.errorBox.classList.add('hidden');
      this.destroyHls();
      const url = mediaUrl(source.url);
      const isHls = (source.format || '').toLowerCase() === 'hls' || /\.m3u8(\?|$)/i.test(source.url);

      if (isHls && window.Hls && window.Hls.isSupported()) {
        const hls = new window.Hls({
          enableWorker: true,
          // Keep a long buffer: combined with the disk prefetch below this lets
          // the player hold far more than the default window.
          backBufferLength: 600,
          maxBufferLength: 300,
          maxMaxBufferLength: 600,
          maxBufferSize: 512 * 1024 * 1024,
          startFragPrefetch: true,
          manifestLoadingTimeOut: 20000,
          fragLoadingTimeOut: 30000,
        });
        this.hls = hls;
        hls.on(window.Hls.Events.MANIFEST_PARSED, () => {
          this.buildQualityLevels();
          this.play();
        });
        hls.on(window.Hls.Events.LEVEL_SWITCHED, () => this.updateQualityLabel());
        hls.on(window.Hls.Events.ERROR, async (_evt, data) => {
          if (!data || !data.fatal) return;
          const status = data.response && data.response.code;
          if (status === 403 || status === 410) {
            await this.autoRefreshStream();
            return;
          }
          if (data.type === window.Hls.ErrorTypes.NETWORK_ERROR) {
            this.flash('网络错误，正在重试…');
            try {
              hls.startLoad();
            } catch {
              const recovered = await this.autoRefreshStream();
              if (!recovered) this.fail('视频流加载失败，请刷新播放地址。');
            }
          } else if (data.type === window.Hls.ErrorTypes.MEDIA_ERROR) {
            try {
              hls.recoverMediaError();
            } catch {
              this.fail('视频解码失败，请刷新播放地址。');
            }
          } else {
            const recovered = await this.autoRefreshStream();
            if (!recovered) this.fail('视频流加载失败，请刷新播放地址。');
          }
        });
        hls.loadSource(url);
        hls.attachMedia(this.video);
        this.updateQualityLabel();
      } else if (isHls && this.video.canPlayType('application/vnd.apple.mpegurl')) {
        this.video.src = url;
        this.play();
      } else if (isHls) {
        this.fail('当前环境不支持 HLS 播放');
      } else {
        this.video.src = url;
        this.play();
      }

      this.startPrefetch(source);
    }

    /* ---- full-video background buffering ---- */

    startPrefetch(source) {
      clearInterval(this.prefetchTimer);
      this.prefetchTimer = 0;
      const enabled = !S.settings || S.settings.prefetch !== false;
      const isHls =
        source && ((source.format || '').toLowerCase() === 'hls' || /\.m3u8(\?|$)/i.test(source.url));
      if (!enabled || !source || !source.url || !isHls) {
        this.setNote('');
        return;
      }
      this.setNote('正在准备预缓冲…');
      invoke('prefetch_video', { url: source.url }).catch(() => {});
      this.prefetchTimer = setInterval(() => this.pollPrefetch(), 1500);
      this.pollPrefetch();
    }

    async pollPrefetch() {
      if (this.destroyed) return;
      try {
        const status = await invoke('prefetch_status');
        if (this.destroyed || !status) return;
        if (status.active) {
          if (!status.total) {
            this.setNote('正在读取播放列表…');
          } else {
            const pct = Math.floor((status.done / status.total) * 100);
            this.setNote(
              `正在预缓冲 ${pct}% · ${status.done}/${status.total} 段 · 已缓存 ${fmtBytes(status.bytes)}`
            );
          }
        } else if (status.complete) {
          this.setNote(`已完整缓存 ${fmtBytes(status.bytes)}，拖动进度条无需等待`);
          clearInterval(this.prefetchTimer);
          this.prefetchTimer = 0;
        } else if (status.message) {
          this.setNote(status.message);
        } else {
          this.setNote('');
        }
      } catch {
        /* backend not ready */
      }
    }

    setNote(text) {
      const el = document.getElementById('prefetchNote');
      if (!el) return;
      el.textContent = text || '';
      el.classList.toggle('hidden', !text);
    }

    play() {
      this.video.play().catch(() => {
        $('.p-bigplay', this.wrap).classList.remove('hidden');
      });
    }

    applyResume() {
      if (this.restored || !this.resumeAt) return;
      this.restored = true;
      const duration = this.video.duration || 0;
      if (this.resumeAt > 10 && (!duration || this.resumeAt < duration - 15)) {
        try {
          this.video.currentTime = this.resumeAt;
          this.flash(`已从 ${fmtTime(this.resumeAt)} 继续播放`);
        } catch {
          /* ignore */
        }
      }
    }

    seekTo(event, commit = true) {
      const rect = this.seek.getBoundingClientRect();
      const ratio = Math.min(1, Math.max(0, (event.clientX - rect.left) / rect.width));
      const duration = this.video.duration;
      if (!isFinite(duration) || duration <= 0) return;
      this.played.style.width = `${(ratio * 100).toFixed(2)}%`;
      this.knob.style.left = `${(ratio * 100).toFixed(2)}%`;
      this.cur.textContent = fmtTime(duration * ratio);
      if (commit) {
        try {
          this.video.currentTime = duration * ratio;
        } catch {
          /* ignore */
        }
      }
    }

    nudge(delta) {
      const duration = this.video.duration;
      if (!isFinite(duration)) return;
      this.video.currentTime = Math.min(duration, Math.max(0, this.video.currentTime + delta));
    }

    renderProgress() {
      const duration = this.video.duration;
      if (!isFinite(duration) || duration <= 0) return;
      const ratio = this.video.currentTime / duration;
      this.played.style.width = `${(ratio * 100).toFixed(2)}%`;
      this.knob.style.left = `${(ratio * 100).toFixed(2)}%`;
      this.cur.textContent = fmtTime(this.video.currentTime);
      this.tot.textContent = fmtTime(duration);
    }

    renderBuffered() {
      const duration = this.video.duration;
      if (!isFinite(duration) || duration <= 0) return;
      const ranges = this.video.buffered;
      if (!ranges.length) return;
      let end = 0;
      for (let i = 0; i < ranges.length; i += 1) {
        if (ranges.start(i) <= this.video.currentTime + 0.5) end = Math.max(end, ranges.end(i));
      }
      this.buffered.style.width = `${Math.min(100, (end / duration) * 100).toFixed(2)}%`;
    }

    saveProgress(force) {
      const now = Date.now();
      if (!force && now - this.lastSave < 4000) return;
      this.lastSave = now;
      const duration = this.video.duration;
      if (!isFinite(duration) || duration <= 0) return;
      updateHistoryProgress(this.vkey, this.video.currentTime, duration);
    }

    syncVolume() {
      const input = $('.p-vol input', this.wrap);
      input.value = String(this.video.muted ? 0 : this.video.volume);
      $('[data-p="mute"]', this.wrap).innerHTML = icons(this.video.muted || this.video.volume === 0 ? 'mute' : 'volume');
    }

    toggleFullscreen() {
      if (document.fullscreenElement === this.wrap) document.exitFullscreen().catch(() => {});
      else this.wrap.requestFullscreen().catch(() => {});
    }

    openMenu(kind) {
      if (this.menuKind === kind && this.menu.classList.contains('open')) {
        this.closeMenu();
        return;
      }
      this.menuKind = kind;
      if (kind === 'rate') {
        const rates = [0.5, 0.75, 1, 1.25, 1.5, 2];
        this.menu.innerHTML =
          `<div class="p-menu-title">播放速度</div>` +
          rates
            .map(
              (r) =>
                `<button data-rate="${r}" class="${Math.abs(this.video.playbackRate - r) < 0.01 ? 'active' : ''}">
                  <span>${r === 1 ? '正常' : r + '×'}</span>${Math.abs(this.video.playbackRate - r) < 0.01 ? '<span class="tick">✓</span>' : ''}
                </button>`
            )
            .join('');
        $$('[data-rate]', this.menu).forEach((btn) => {
          btn.addEventListener('click', () => {
            this.video.playbackRate = Number(btn.dataset.rate);
            $('[data-p="rate"]', this.wrap).textContent = btn.dataset.rate === '1' ? '1×' : btn.dataset.rate + '×';
            this.closeMenu();
          });
        });
      } else if (kind === 'quality') {
        let html = '<div class="p-menu-title">画质</div>';
        if (this.hls && this.hls.levels && this.hls.levels.length) {
          const levels = this.hls.levels
            .map((lvl, idx) => ({ idx, height: lvl.height, bitrate: lvl.bitrate }))
            .sort((a, b) => b.height - a.height);
          const currentLevel = this.hls.autoLevelEnabled ? -1 : this.hls.currentLevel;
          html += `<button data-level="-1" class="${currentLevel === -1 ? 'active' : ''}"><span>自动</span>${currentLevel === -1 ? '<span class="tick">✓</span>' : ''}</button>`;
          levels.forEach((lvl) => {
            const label = lvl.height ? `${lvl.height}p` : `${Math.round(lvl.bitrate / 1000)}k`;
            html += `<button data-level="${lvl.idx}" class="${currentLevel === lvl.idx ? 'active' : ''}"><span>${label}</span>${
              currentLevel === lvl.idx ? '<span class="tick">✓</span>' : ''
            }</button>`;
          });
        } else if (this.sources.length) {
          html += this.sources
            .map(
              (s, idx) =>
                `<button data-source="${idx}" class="${this.current === s ? 'active' : ''}"><span>${esc(
                  s.quality || (s.height ? s.height + 'p' : '默认')
                )}</span>${this.current === s ? '<span class="tick">✓</span>' : ''}</button>`
            )
            .join('');
        } else {
          html += '<button disabled><span>单一画质</span></button>';
        }
        this.menu.innerHTML = html;
        $$('[data-level]', this.menu).forEach((btn) => {
          btn.addEventListener('click', () => {
            const level = Number(btn.dataset.level);
            this.hls.currentLevel = level;
            this.updateQualityLabel();
            this.closeMenu();
            this.flash(level === -1 ? '画质：自动' : `画质：${btn.textContent.trim().replace('✓', '')}`);
          });
        });
        $$('[data-source]', this.menu).forEach((btn) => {
          btn.addEventListener('click', () => {
            const src = this.sources[Number(btn.dataset.source)];
            if (src) this.load(src);
            this.closeMenu();
          });
        });
      }
      this.menu.classList.add('open');
    }

    closeMenu() {
      this.menu.classList.remove('open');
      this.menuKind = '';
    }

    buildQualityLevels() {
      if (!this.hls) return;
      this.updateQualityLabel();
    }

    updateQualityLabel() {
      const label = $('[data-p="quality"]', this.wrap);
      if (!this.hls || !this.hls.levels || !this.hls.levels.length) {
        const quality = this.current && (this.current.quality || (this.current.height ? this.current.height + 'p' : ''));
        if (label) label.textContent = quality || '画质';
        return;
      }
      if (this.hls.autoLevelEnabled) {
        const lvl = this.hls.levels[this.hls.currentLevel];
        label.textContent = lvl && lvl.height ? `自动 ${lvl.height}p` : '自动';
      } else {
        const lvl = this.hls.levels[this.hls.currentLevel];
        label.textContent = lvl && lvl.height ? `${lvl.height}p` : '画质';
      }
    }

    wake() {
      this.wrap.classList.remove('idle');
      this.scheduleIdle();
    }

    scheduleIdle() {
      clearTimeout(this.idleTimer);
      if (this.video && this.video.paused) return;
      this.idleTimer = setTimeout(() => {
        if (!this.video.paused) this.wrap.classList.add('idle');
      }, 2800);
    }

    flash(message) {
      this.pToast.textContent = message;
      this.pToast.classList.add('show');
      clearTimeout(this.flashTimer);
      this.flashTimer = setTimeout(() => this.pToast.classList.remove('show'), 1800);
    }

    fail(message) {
      this.errorBox.classList.remove('hidden');
      this.errorBox.innerHTML = `<div>
        <div>${esc(message)}</div>
        <button class="btn primary" id="pRetry">重新加载</button>
      </div>`;
      const retry = $('#pRetry', this.errorBox);
      if (retry) {
        retry.addEventListener('click', () => {
          this.errorBox.classList.add('hidden');
          this.destroyHls();
          if (this.current) this.load(this.current);
        });
      }
    }

    destroyHls() {
      if (this.hls) {
        try {
          this.hls.destroy();
        } catch {
          /* ignore */
        }
        this.hls = null;
      }
    }

    destroy() {
      this.destroyed = true;
      clearTimeout(this.idleTimer);
      clearTimeout(this.flashTimer);
      clearInterval(this.prefetchTimer);
      this.prefetchTimer = 0;
      this.saveProgress(true);
      this.destroyHls();
      document.removeEventListener('keydown', this.onKey);
      document.removeEventListener('click', this.onDocClick);
      document.removeEventListener('fullscreenchange', this.onFullscreen);
      try {
        this.video.pause();
        this.video.removeAttribute('src');
        this.video.load();
      } catch {
        /* ignore */
      }
      if (document.fullscreenElement === this.wrap) document.exitFullscreen().catch(() => {});
    }
  }

  /* ------------------------------- boot ------------------------------- */

  $('#navBack').addEventListener('click', back);
  $('#navForward').addEventListener('click', forward);
  $('#navReload').addEventListener('click', refresh);
  $('#accountBtn').addEventListener('click', () => {
    if (S.account && S.account.loggedIn) openAccount();
    else openLogin();
  });

  $$('#sideNav .navitem').forEach((btn) => {
    btn.addEventListener('click', () => {
      const nav = btn.dataset.nav;
      if (nav === 'home') {
        if (S.route && S.route.name === 'home') {
          restoreScroll(0);
          S.homeScrollTop = 0;
          return;
        }
        go({ name: 'home' });
      }
      else if (nav === 'categories') go({ name: 'categories' });
      else if (nav === 'history') go({ name: 'history' });
      else if (nav === 'settings') go({ name: 'settings' });
      else if (nav === 'trending') go({ name: 'list', params: { path: '/video?o=ht', title: '热门视频', nav: 'trending' } });
      else if (nav === 'newest') go({ name: 'list', params: { path: '/video?o=cm', title: '最新视频', nav: 'newest' } });
    });
  });

  $$('[data-win]').forEach((btn) => {
    btn.addEventListener('click', () => {
      invoke('window_action', { action: btn.dataset.win }).catch(() => {});
    });
  });

  // 标题栏的双击最大化由 Tauri 的 data-tauri-drag-region="deep" 原生处理，
  // 这里不再额外监听 dblclick，避免一次双击触发两次切换。

  $('#searchInput').addEventListener('keydown', (e) => {
    if (e.key !== 'Enter') return;
    const q = e.target.value.trim();
    if (!q) return;
    e.target.blur();
    go({ name: 'list', params: { path: `/video/search?search=${encodeURIComponent(q)}`, title: `搜索：${q}` } });
  });

  document.addEventListener(
    'load',
    (e) => {
      if (e.target && e.target.tagName === 'IMG') e.target.classList.add('loaded');
    },
    true
  );
  document.addEventListener(
    'error',
    (e) => {
      const el = e.target;
      if (el && el.tagName === 'IMG' && !el.dataset.failed) {
        el.dataset.failed = '1';
        el.classList.add('loaded');
        el.style.opacity = '0';
      }
    },
    true
  );

  view.addEventListener('scroll', () => {
    if (!S.route || S.route.name !== 'home') return;
    if (S.homeLoading || !S.homeHasMore) return;
    const threshold = 500;
    if (view.scrollTop + view.clientHeight >= view.scrollHeight - threshold) {
      loadMoreHome();
    }
  });

  async function boot() {
    homePane.innerHTML = `<div class="view-inner"><div class="center-load"><span class="spinner"></span> 正在初始化…</div></div>`;
    subPane.style.display = 'none';
    try {
      const info = await invoke('get_settings');
      S.settings = info.settings;
      S.mediaBase = info.mediaBase;
    } catch (err) {
      homePane.innerHTML = `<div class="view-inner">${stateBox(
        '应用初始化失败',
        String(err),
        `<button class="btn" data-act="retry">重试</button>`
      )}</div>`;
      return;
    }
    updateConnState();
    go({ name: 'home' }, { replace: true });
    refreshAccount();
  }

  boot();
})();
