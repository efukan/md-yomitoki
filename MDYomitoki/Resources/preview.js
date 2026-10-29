'use strict';

const content = document.getElementById('content');
const baseElement = document.querySelector('base');
const post = (message) => window.webkit.messageHandlers.bridge.postMessage(message);

const TOP = 16;  // この位置（px）にある要素を「画面上部に見えている要素」とみなす
const MARK_CLASSES = ['chg', 'chg-latest', 'del-before', 'del-after'];
const startLine = (el) => parseInt(el.dataset.sourcepos, 10);
const endLine = (el) => parseInt(el.dataset.sourcepos.split('-')[1], 10);
const withoutPositions = (html) => html.replace(/ data-sourcepos="[^"]*"/g, '');

let blocks = [];        // data-sourcepos を持つ全要素（文書順）
let targets = [];       // 付箋を付けられる要素（文書順）
let liveAnchor = null;  // 画像の読み込みやウィンドウ幅の変化でずれないよう、ユーザーが見ている位置を覚えておく

// MARK: - Swift から呼ばれる関数

// 変わったブロックだけを差し替え、画面上部に見えていた要素の位置を 1px も動かさない。
function render(html, base, marks) {
  if (baseElement.href !== base) baseElement.href = base;
  const anchor = captureAnchor();
  morph(html);
  applyMarks(marks);
  restoreAnchor(anchor);
  liveAnchor = captureAnchor();
}

function setMarks(marks) {
  applyMarks(marks);
}

// 本文の列の最大幅（CSS の値）。高さが変わるので、ResizeObserver が見ていた位置を保つ。
function setContentWidth(width) {
  document.documentElement.style.setProperty('--content-width', width);
}

// line〜last 行の範囲のうち ratio の位置が画面上部に来るようにスクロールする。
// プレビュー自身の位置（要素の開始行〜終了行と要素内の割合）も、エディタの位置（1 行とその行内の割合）も同じ式で扱える。
function scrollToLine(line, ratio = 0, last = line) {
  const el = elementForLine(line);
  if (!el) {
    window.scrollTo(0, 0);
  } else {
    const s = startLine(el), e = Math.max(s, endLine(el));
    const span = Math.max(1, last - line + 1);
    const r = Math.min(1, Math.max(0, (line - s + ratio * span) / (e - s + 1)));
    const rect = el.getBoundingClientRect();
    // 表の本体の行は、画面の上に固定する見出し行に隠れないよう、その高さだけ下に出す
    const head = el.closest('tbody')?.closest('table')?.tHead;
    const covered = head ? head.getBoundingClientRect().height : 0;
    window.scrollTo(0, Math.max(0, window.scrollY + rect.top + rect.height * r - (r > 0 ? TOP : 12) - covered));
  }
  liveAnchor = captureAnchor();
  reportScroll();
}

// ⌘J・付箋・ルーラー：その行を受け持つ要素へスクロールして、一瞬光らせる。
// 空行（どの要素にも含まれない行。削除の位置など）なら次の要素へ（削除の赤線はその要素の上に引かれる）。
function jumpToLine(line) {
  let el = elementForLine(line);
  if (!el || endLine(el) < line) el = blocks.find((b) => startLine(b) >= line) ?? el;
  if (!el) return scrollToLine(line);
  scrollToLine(startLine(el));
  el.classList.remove('jump-flash');
  void el.offsetWidth;  // アニメーションを最初から再生させる
  el.classList.add('jump-flash');
  // 光らせ終わったら外す（角の丸みなどが要素に残らないように）
  el.addEventListener('animationend', () => el.classList.remove('jump-flash'), { once: true });
}

// MARK: - リモート画像の切り替え

// オフのときは http/https の画像の src を data-remote-src に退避して読み込ませない。
// テンプレート内の要素はまだ読み込みを始めないので、文書へ入れる前に退避すれば通信は起きない。
let allowRemoteImages = true;

function gateRemoteImages(root) {
  for (const img of root.querySelectorAll('img')) {
    const src = img.getAttribute('src');
    if (!allowRemoteImages && src && /^\s*https?:/i.test(src)) {
      img.dataset.remoteSrc = src;
      img.removeAttribute('src');
      img.classList.add('remote-blocked');
    } else if (allowRemoteImages && img.dataset.remoteSrc) {
      img.setAttribute('src', img.dataset.remoteSrc);
      delete img.dataset.remoteSrc;
      img.classList.remove('remote-blocked');
    }
  }
}

function setRemoteImages(allow) {
  allowRemoteImages = allow;
  gateRemoteImages(content);
}

// MARK: - DOM の差分更新

// 最上位ブロックを、行番号を除いた HTML で比較する。同じものは既存ノードを使い回すので、
// 画像は再読み込みされず、高さも変わらない。上に行が挿入されても、ずれた行番号だけ書き換える。
function morph(html) {
  const template = document.createElement('template');
  template.innerHTML = html;
  defuse(template.content);

  const reusable = new Map();
  for (const node of content.children) {
    if (!reusable.has(node._key)) reusable.set(node._key, []);
    reusable.get(node._key).push(node);
  }

  let cursor = content.firstElementChild;
  const newDiagrams = [];
  for (const fresh of [...template.content.children]) {
    const key = withoutPositions(fresh.outerHTML);
    const old = reusable.get(key)?.shift();
    let node = fresh;
    if (old) {
      copyPositions(fresh, old);
      node = old;
    } else {
      node._key = key;
      gateRemoteImages(node);
      highlightCode(node);
      enableTaskCheckboxes(node);
      newDiagrams.push(...mermaidBlocks(node));
      // フロントマターを開いていたなら、書き換わっても開いたままにする
      if (frontMatterOpen && node.matches('details.front-matter')) node.open = true;
    }
    if (node === cursor) {
      cursor = cursor.nextElementSibling;
    } else {
      content.insertBefore(node, cursor);
    }
  }
  while (cursor) {
    const next = cursor.nextElementSibling;
    cursor.remove();
    cursor = next;
  }
  blocks = [...content.querySelectorAll('[data-sourcepos]')];
  targets = blocks.filter((el) => !el.matches(NOT_BOOKMARKABLE));
  renderMermaid(newDiagrams);
}

// 文書の生 HTML のうち、外枠の動作を乗っ取れるものを文書へ入れる前に取り除く。
// - meta・base・link：meta refresh による再読み込みや、文書の基準 URL の差し替え
// - form と img の name：document.createElement や form.outerHTML などを要素で上書きして（DOM clobbering）、
//   この JS を例外で止める（プレビューが古い内容のまま更新されなくなる）。form は中身だけ残す。
// - object・embed：CSP で読み込めないが、document の名前付きプロパティになる
function defuse(root) {
  for (const el of root.querySelectorAll('meta, base, link, object, embed')) el.remove();
  for (const form of root.querySelectorAll('form')) form.replaceWith(...form.childNodes);
  for (const img of root.querySelectorAll('img[name]')) img.removeAttribute('name');
}

// 行番号を持つ要素どうしを文書順で対応させる（色付けで入れた span などは数えない）
function copyPositions(from, to) {
  const source = [from, ...from.querySelectorAll('[data-sourcepos]')];
  const target = [to, ...to.querySelectorAll('[data-sourcepos]')];
  source.forEach((el, i) => target[i]?.setAttribute('data-sourcepos', el.getAttribute('data-sourcepos')));
}

// MARK: - スクロール位置の維持

// 画面上部の要素（文書順で最後の、top が TOP 以下の要素）。要素の top は文書順に単調なので二分探索する。
function topElement() {
  let lo = 0, hi = blocks.length - 1, found = null;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (blocks[mid].getBoundingClientRect().top <= TOP) {
      found = blocks[mid];
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return found;
}

// 上部の要素と、それが差し替えで消えた場合に備えて周辺の最上位ブロックの位置を控える。
function captureAnchor() {
  const el = topElement();
  if (!el) return null;
  let block = el;
  while (block.parentElement !== content) block = block.parentElement;
  const candidates = [el, block];
  for (let n = block.previousElementSibling, i = 0; n && i < 8; n = n.previousElementSibling, i++) candidates.push(n);
  for (let n = block.nextElementSibling, i = 0; n && i < 8; n = n.nextElementSibling, i++) candidates.push(n);
  return candidates.map((node) => ({ node, top: node.getBoundingClientRect().top }));
}

function restoreAnchor(anchor) {
  const hit = anchor?.find((a) => a.node.isConnected);
  if (!hit) return;
  const delta = hit.node.getBoundingClientRect().top - hit.top;
  if (delta !== 0) window.scrollBy(0, delta);
}

// その行を受け持つ要素（開始行が line 以下で一番後ろのもの。同じなら文書順で後の＝内側の要素）。
// 脚注は HTML の末尾にまとめて出るので、文書順でも行番号が戻る。順に見て途中で打ち切ると、
// 脚注より後の行（末尾への追記など）が脚注の定義の行（文書の前の方）に取られるので、全部見る。
function elementForLine(line) {
  let target = null;
  for (const el of blocks) {
    const start = startLine(el);
    if (start <= line && (!target || start >= startLine(target))) target = el;
  }
  return target;
}

// スクロール中も 80ms ごとに通知する（止まるまで待つと、見出し一覧の追従が遅れて見える）。
let reportPending = false;
function scheduleReport() {
  if (reportPending) return;
  reportPending = true;
  setTimeout(() => {
    reportPending = false;
    reportScroll();
  }, 80);
}

function reportScroll() {
  const el = topElement();
  if (!el) return post({ type: 'scroll', line: 1, endLine: 1, ratio: 0 });
  const rect = el.getBoundingClientRect();
  const ratio = rect.height > 0 ? Math.min(1, Math.max(0, (TOP - rect.top) / rect.height)) : 0;
  post({ type: 'scroll', line: startLine(el), endLine: endLine(el), ratio });
}

window.addEventListener('scroll', () => {
  liveAnchor = captureAnchor();
  scheduleReport();
  scheduleHover();
  scheduleStickyHead();
}, { passive: true });

// 画像の読み込み完了やウィンドウ幅の変化で高さが変わっても、見ている位置を保つ。余白の印とルーラーも置き直す。
new ResizeObserver(() => {
  restoreAnchor(liveAnchor);
  placeOverlays();
}).observe(content);
// 文字の大きさ（ページの拡大率）を変えると本文の幅が変わらなくても高さが変わるので、ここでも位置を保つ
window.addEventListener('resize', () => {
  restoreAnchor(liveAnchor);
  placeOverlays();
});

// 本文の外に重ねている印（付箋・変更の線）と右端のルーラー
function placeOverlays() {
  placeBookmarks();
  placeChangeMarks();
  scheduleRuler();
  stickyTable = null;  // 列の幅が変わっているかもしれないので作り直す
  scheduleStickyHead();
}

// MARK: - 変更ハイライト

// 変更行と重なる要素のうち、その行を子要素が受け持っていない「最も深い要素」に印を付ける。
function applyMarks(marks) {
  for (const el of content.querySelectorAll(MARK_CLASSES.map((c) => '.' + c).join(','))) {
    el.classList.remove(...MARK_CLASSES);
  }
  bookmarkLines = marks?.bookmarks ?? [];
  removedEntries = [];
  if (marks) {
    for (const el of blocks) {
      if (ownsAny(el, marks.changed)) el.classList.add('chg');
      if (ownsAny(el, marks.latest)) el.classList.add('chg-latest');
    }
    const leaves = blocks.filter((el) => !el.querySelector('[data-sourcepos]'));
    const deletions = new Map();  // 削除の位置 → 削除の印を付けた要素と、印が上端か下端か
    for (const line of marks.deleted) {
      const leaf = leaves.find((l) => startLine(l) >= line);
      const target = leaf ?? leaves.at(-1);
      if (!target) continue;
      // 表のセルなら行に付ける
      const el = target.matches('td, th') ? target.parentElement : target;
      el.classList.add(leaf ? 'del-before' : 'del-after');
      deletions.set(line, { el, before: !!leaf });
    }
    removedEntries = marks.removed.map(([line, count, text]) => ({ line, count, text, deletion: deletions.get(line) }));
  }
  placeOverlays();
}

function ownsAny(el, ranges) {
  const s = startLine(el), e = endLine(el);
  const children = [...el.querySelectorAll('[data-sourcepos]')];
  if (children.length === 0) return ranges.some(([a, b]) => a <= e && s <= b);
  for (const [a, b] of ranges) {
    for (let line = Math.max(a, s); line <= Math.min(b, e); line++) {
      if (!children.some((child) => startLine(child) <= line && line <= endLine(child))) return true;
    }
  }
  return false;
}

// MARK: - 付箋

// 入れ物（リスト・引用・表全体）と表のセルには付けない。表は行（tr）ごとに付ける。
const NOT_BOOKMARKABLE = 'ul, ol, blockquote, table, thead, tbody, td, th, section, details';
const MARK_SIZE = 21;  // 印の当たり判定の大きさ（px）。形は CSS の ::after で描く。
const MARK_OFFSET = 32; // 当たり判定の左端から本文の列の左端までの距離

// 印は本文の左の余白に重ねた層に置く。本文の要素には一切手を加えないので、レイアウトも差分更新も変わらない。
const gutter = document.createElement('div');
gutter.id = 'gutter';
document.body.appendChild(gutter);
const hoverMark = document.createElement('div');
hoverMark.className = 'bm bm-hover';
hoverMark.title = '付箋を付ける（⌘D）';
hoverMark.hidden = true;
gutter.appendChild(hoverMark);

let bookmarkLines = [];
let pinnedTargets = new Set();

// line を受け持つ要素（開始行が line 以下で、文書順で最後のもの）。開始行は文書順に単調なので二分探索する。
function targetForLine(line) {
  let lo = 0, hi = targets.length - 1, found = null;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (startLine(targets[mid]) <= line) {
      found = targets[mid];
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return found;
}

// 本文の列の左端（画面の座標）
function columnLeft() {
  return content.getBoundingClientRect().left + parseFloat(getComputedStyle(content).paddingLeft);
}

// 本文の列の右端（画面の座標）
function columnRight() {
  return content.getBoundingClientRect().right - parseFloat(getComputedStyle(content).paddingRight);
}

// 要素の1行目の高さの中央（画面の座標）
function firstLineMiddle(el) {
  const rect = el.getBoundingClientRect();
  const style = getComputedStyle(el.matches('tr') ? el.firstElementChild ?? el : el);
  const lineHeight = Math.min(parseFloat(style.lineHeight) || rect.height, rect.height);
  return rect.top + (parseFloat(style.paddingTop) || 0) + lineHeight / 2;
}

// 本文の列の左の余白に、要素の1行目の高さの中央で印を置く（文書の座標）。
function placeMark(mark, el) {
  mark.style.left = `${columnLeft() + window.scrollX - MARK_OFFSET}px`;
  mark.style.top = `${window.scrollY + firstLineMiddle(el) - MARK_SIZE / 2}px`;
  mark._target = el;
}

function placeBookmarks() {
  for (const mark of gutter.querySelectorAll('.bm-pin')) mark.remove();
  pinnedTargets = new Set();
  for (const line of bookmarkLines) {
    const el = targetForLine(line);
    if (!el || pinnedTargets.has(el)) continue;
    pinnedTargets.add(el);
    const mark = document.createElement('div');
    mark.className = 'bm bm-pin';
    mark.title = '付箋を外す（⌘D）';
    placeMark(mark, el);
    gutter.appendChild(mark);
  }
  updateHover();
}

// マウスの高さにある要素。入れ子のリストでは内側の項目を、段落の間の余白ではすぐ上の要素を選ぶ。
// 本文を読んでいる間は出さない（目障りなので）。本文の列の左の余白にマウスがあるときだけ。
// 本文のすぐ左は変更の線の当たり判定なので空けておく。
function targetAt(x, y) {
  const column = columnLeft();
  if (x < column - MARK_OFFSET - 8 || x >= column - CHANGE_ZONE) return null;
  let lo = 0, hi = targets.length - 1, found = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (targets[mid].getBoundingClientRect().top <= y) {
      found = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  if (found < 0) return null;
  for (let i = found; i >= 0 && i > found - 30; i--) {
    if (targets[i].getBoundingClientRect().bottom > y) return targets[i];
  }
  return targets[found];
}

let mouse = null;
let hoverFrame = 0;
function scheduleHover() {
  if (!hoverFrame) hoverFrame = requestAnimationFrame(updateHover);
}

function updateHover() {
  hoverFrame = 0;
  const el = mouse && targetAt(mouse.x, mouse.y);
  if (!el || pinnedTargets.has(el)) {
    hoverMark.hidden = true;
    hoverMark._target = null;
    return;
  }
  if (hoverMark._target !== el || hoverMark.hidden) placeMark(hoverMark, el);
  hoverMark.hidden = false;
}

document.addEventListener('mousemove', (event) => {
  mouse = { x: event.clientX, y: event.clientY };
  scheduleHover();
  reportHorizontalScroll();
});

// トラックパッドの横スワイプは「戻る／進む」になる。横にスクロールできる表・コードの上では、端まで行っていても
// 戻る／進むにしない（表を横に送っているつもりで前の位置へ飛ぶ事故を防ぐ）ので、マウスの下にあるかを Swift に知らせる（変わった時だけ）。
let overHorizontalScroll = false;
function reportHorizontalScroll() {
  const el = mouse && document.elementFromPoint(mouse.x, mouse.y)?.closest('.table-wrap, pre');
  const over = !!el && el.scrollWidth > el.clientWidth + 1;
  if (over === overHorizontalScroll) return;
  overHorizontalScroll = over;
  post({ type: 'horizontalScroll', over });
}
window.addEventListener('resize', reportHorizontalScroll);
// マウスがプレビューの外（サイドバーや別のウィンドウ）へ出たら、ホバーの印を消す。
// WebKit はビューの外へ出ても mouseleave を送らないことがあるので、Swift の mouseExited からも呼ぶ。
function hideBookmarkHover() {
  mouse = null;
  scheduleHover();
  reportHorizontalScroll();
  hideRemovedSoon();
  codeTools.hidden = true;
  hoveredPre = null;
}
document.documentElement.addEventListener('mouseleave', hideBookmarkHover);
window.addEventListener('blur', hideBookmarkHover);

// 要素に付いている付箋をすべて外す。無ければ要素の開始行に付ける。
gutter.addEventListener('mousedown', (event) => event.preventDefault());  // 文字の選択を始めない
gutter.addEventListener('click', (event) => {
  const el = event.target._target;
  if (!el) return;
  const lines = bookmarkLines.filter((line) => targetForLine(line) === el);
  post({ type: 'toggleBookmark', lines: lines.length > 0 ? lines : [startLine(el)] });
});

// MARK: - 変更の印（本文の列の左の余白の細い線と、削除の三角）

// 列の左の余白に細い線を引く（未確認の変更は淡く、最新の更新は濃く。本文の淡い塗りは最新の更新だけ CSS で）。
// 削除の位置には、本文の幅の赤線と、その左に赤い三角、右端に「−行数」の丸い印を置く。
// 線か三角にマウスを載せると、変更前の内容（削除なら消えた行）を吹き出しで見せる。付箋と同じく #gutter 層に置く。
const CHANGE_GAP = 6;    // 本文の列の左端から線までの距離
const CHANGE_WIDTH = 3;  // 線の太さ
const CHANGE_HIT = 5;    // 線の左右に広げる当たり判定
const CHANGE_ZONE = CHANGE_GAP + CHANGE_WIDTH + CHANGE_HIT;  // 本文の左端からの当たり判定の幅
let removedEntries = [];  // [{ line, count, text, deletion: { el, before } | undefined }]
const removedPopover = document.createElement('div');
removedPopover.id = 'removed-pop';
removedPopover.hidden = true;
document.body.appendChild(removedPopover);
let popoverTimer = 0;

function placeChangeMarks() {
  for (const mark of gutter.querySelectorAll('.cb, .cd, .cdl, .cdline')) mark.remove();
  removedPopover.hidden = true;
  const x = columnLeft() + window.scrollX - CHANGE_GAP - CHANGE_WIDTH;
  const y = window.scrollY;
  // 縦に重なる・接する要素は1本の線にまとめる。最新の更新は未確認の変更の上に重ねる。
  for (const kind of ['chg', 'chg-latest']) {
    const spans = [...content.querySelectorAll('.' + kind)].map((el) => {
      const rect = (el.matches('td, th') ? el.parentElement : el).getBoundingClientRect();
      return { top: rect.top + y, bottom: rect.bottom + y, first: startLine(el), last: endLine(el) };
    }).sort((a, b) => a.top - b.top);
    const bars = [];
    for (const span of spans) {
      const bar = bars.at(-1);
      if (bar && span.top <= bar.bottom + 1) {
        bar.bottom = Math.max(bar.bottom, span.bottom);
        bar.first = Math.min(bar.first, span.first);
        bar.last = Math.max(bar.last, span.last);
      } else {
        bars.push(span);
      }
    }
    for (const bar of bars) {
      const mark = document.createElement('div');
      mark.className = kind === 'chg' ? 'cb' : 'cb cb-latest';
      mark.style.left = `${x - CHANGE_HIT}px`;
      mark.style.top = `${bar.top}px`;
      mark.style.height = `${bar.bottom - bar.top}px`;
      mark._entries = removedEntries.filter((e) => !e.deletion && bar.first <= e.line && e.line <= bar.last);
      gutter.appendChild(mark);
    }
  }
  // 削除の三角と行数。同じ高さに重なるもの（表の行の上下など）はまとめる。
  const deletions = new Map();
  for (const entry of removedEntries) {
    if (!entry.deletion) continue;
    const rect = entry.deletion.el.getBoundingClientRect();
    const edge = Math.round((entry.deletion.before ? rect.top : rect.bottom) + y);
    if (deletions.has(edge)) {
      deletions.get(edge).entries.push(entry);
    } else {
      deletions.set(edge, { entries: [entry], below: !entry.deletion.before });
    }
  }
  const right = columnRight();
  for (const [edge, { entries, below }] of deletions) {
    // 赤線（2px）は要素の上端のすぐ上か、下端のすぐ下に引く。三角と行数の印はその中心にそろえる。
    // 要素の影や枠で描くと、要素の角の丸み（移動した時に光らせる枠など）に沿って端が曲がるので、重ねた層に引く。
    const middle = below ? edge + 1 : edge - 1;
    const line = document.createElement('div');
    line.className = 'cdline';
    line.style.left = `${columnLeft() + window.scrollX}px`;
    line.style.width = `${right - columnLeft()}px`;
    line.style.top = `${middle - 1}px`;
    gutter.appendChild(line);
    // 三角の左端は変更の線の左端にそろえる（先が赤線の始まりに近づく）。三角は当たり判定の中で (4, 2) から 6×8。
    const triangle = document.createElement('div');
    triangle.className = 'cd';
    triangle.style.left = `${x - 4}px`;
    triangle.style.top = `${middle - 6}px`;
    const badge = document.createElement('div');
    badge.className = 'cdl';
    badge.textContent = entries.reduce((sum, e) => sum + e.count, 0);  // 「−」は CSS で描く
    for (const mark of [triangle, badge]) {
      mark._entries = entries;
      mark._deleted = true;
      gutter.appendChild(mark);
    }
    const left = Math.min(right + CHANGE_GAP, window.innerWidth - 12 - badge.offsetWidth);
    badge.style.left = `${window.scrollX + left}px`;
    badge.style.top = `${middle - badge.offsetHeight / 2}px`;
  }
}

// 本文の列の左端にそろえ、マウスの少し下に出す。下に収まらなければ上に出す。
function showRemoved(mark, mouseY) {
  clearTimeout(popoverTimer);
  const count = mark._entries.reduce((sum, e) => sum + e.count, 0);
  const title = document.createElement('div');
  title.className = 'rp-title';
  const children = [title];
  if (mark._deleted) {
    title.textContent = `削除された ${count}行`;
  } else if (count === 0) {
    title.textContent = '追加された行（変更前の内容はありません）';
  } else {
    title.textContent = `変更前の内容（${count}行）`;
  }
  if (count > 0) {
    const text = document.createElement('pre');
    text.textContent = mark._entries.map((e) => e.text).join('\n⋯\n');
    children.push(text);
  }
  removedPopover.replaceChildren(...children);
  removedPopover.classList.toggle('rp-del', !!mark._deleted);
  removedPopover.hidden = false;
  const width = removedPopover.offsetWidth, height = removedPopover.offsetHeight;
  const left = Math.max(8, Math.min(columnLeft(), window.innerWidth - 8 - width));
  const below = mouseY + 14;
  const top = below + height <= window.innerHeight - 8 ? below : Math.max(8, mouseY - 14 - height);
  removedPopover.style.left = `${window.scrollX + left}px`;
  removedPopover.style.top = `${window.scrollY + top}px`;
}

// 吹き出しの中の文字を選べるよう、印から吹き出しへマウスを移す間は消さない
function hideRemovedSoon() {
  clearTimeout(popoverTimer);
  popoverTimer = setTimeout(() => { removedPopover.hidden = true; }, 200);
}

gutter.addEventListener('mouseover', (event) => {
  const mark = event.target.closest('.cb, .cd, .cdl');
  if (mark) showRemoved(mark, event.clientY);
});
gutter.addEventListener('mouseout', (event) => {
  if (event.target.closest('.cb, .cd, .cdl')) hideRemovedSoon();
});
removedPopover.addEventListener('mouseenter', () => clearTimeout(popoverTimer));
removedPopover.addEventListener('mouseleave', hideRemovedSoon);

// MARK: - ルーラー（右端に変更の位置を並べる）

// 文書全体を画面の高さに縮めて印を並べるので、スクロールバーのつまみの位置と対応する。
// 普段は変更と削除だけ。検索中は一致の位置を上に重ねる。印の近くをクリックするとその位置へ移動する。
const ruler = document.createElement('div');
ruler.id = 'ruler';
ruler.title = '変更の位置（クリックで移動）';
document.body.appendChild(ruler);
let rulerFrame = 0;

function scheduleRuler() {
  if (!rulerFrame) rulerFrame = requestAnimationFrame(drawRuler);
}

function drawRuler() {
  rulerFrame = 0;
  const scale = window.innerHeight / Math.max(1, document.documentElement.scrollHeight);
  // 種類 → [[上端, 下端, 行]]（文書の座標）。後の種類ほど上に重なる（今の一致は他の一致より上）。
  const spans = new Map(['chg', 'chg-latest', 'del', 'search', 'current'].map((kind) => [kind, []]));
  const add = (kind, top, bottom, line) => spans.get(kind).push([top, bottom, line]);
  const y = window.scrollY;
  for (const kind of ['chg', 'chg-latest']) {
    for (const el of content.querySelectorAll('.' + kind)) {
      const rect = el.getBoundingClientRect();
      add(kind, rect.top + y, rect.bottom + y, startLine(el));
    }
  }
  for (const el of content.querySelectorAll('.del-before, .del-after')) {
    const rect = el.getBoundingClientRect();
    const edge = (el.classList.contains('del-before') ? rect.top : rect.bottom) + y;
    add('del', edge, edge, startLine(el));
  }
  highlighted.ranges.forEach((range, i) => {
    if (!range.startContainer.isConnected) return;
    const rect = range.getBoundingClientRect();
    add(i === highlighted.current ? 'current' : 'search', rect.top + y, rect.bottom + y, null);
  });

  const marks = [];
  for (const [kind, list] of spans) {
    list.sort((a, b) => a[0] - b[0]);
    let last = null;
    for (const [top, bottom, line] of list) {
      const t = top * scale, b = Math.max(bottom * scale, t + 2);
      if (last && t <= last.bottom + 1) {
        last.bottom = Math.max(last.bottom, b);
        continue;
      }
      last = { kind, top: t, bottom: b, line, y: top };
      marks.push(last);
    }
  }
  ruler.replaceChildren(...marks.map((m) => {
    const mark = document.createElement('div');
    mark.className = `rk rk-${m.kind}`;
    mark.style.top = `${m.top}px`;
    mark.style.height = `${m.bottom - m.top}px`;
    mark._line = m.line;
    mark._y = m.y;
    return mark;
  }));
}

// 印は細いので、クリックした高さから一番近い印（6px 以内）を選ぶ
ruler.addEventListener('click', (event) => {
  let best = null, bestDistance = 6;
  for (const mark of ruler.children) {
    const rect = mark.getBoundingClientRect();
    const distance = Math.max(rect.top - event.clientY, event.clientY - rect.bottom, 0);
    if (distance < bestDistance) {
      best = mark;
      bestDistance = distance;
    }
  }
  if (!best) return;
  post({ type: 'willJump' });
  if (best._line) {
    jumpToLine(best._line);
  } else {
    window.scrollTo(0, Math.max(0, best._y - window.innerHeight / 3));
  }
});

// MARK: - タスクリストのチェックボックス

// cmark は disabled で出力するので、クリックできるようにする。クリックしたら Swift が元の行の [ ] と [x] を入れ替えて
// 保存し、描画し直す（ここでは見た目を変えない。元のファイルと食い違わないように）。
// 項目が空行で区切られたリストでは、チェックボックスが段落の中に入る
const TASK_CHECKBOX = 'li > input[type="checkbox"], li > p:first-child > input[type="checkbox"]';

function enableTaskCheckboxes(root) {
  for (const box of root.querySelectorAll(TASK_CHECKBOX)) {
    box.removeAttribute('disabled');
    box.title = 'クリックで完了／未完了を切り替え（ファイルに保存）';
  }
}

content.addEventListener('click', (event) => {
  const box = event.target.closest?.(TASK_CHECKBOX);
  if (!box || !content.contains(box)) return;
  event.preventDefault();
  post({ type: 'toggleTask', line: startLine(box.closest('li')) });
});

// MARK: - コードブロック

// 言語が書かれたコードブロック（```swift など）だけを highlight.js で色付けする（言語の推測はしない）。
// 新しく入ったブロックだけに行う。使い回すブロックは色付けしたまま残る（比較は色付け前の HTML で行う）。
function highlightCode(root) {
  if (!window.hljs) return;
  for (const code of root.querySelectorAll('pre > code[class*="language-"]')) {
    const language = languageOf(code);
    if (!hljs.getLanguage(language)) continue;
    try {
      code.innerHTML = hljs.highlight(code.textContent, { language, ignoreIllegals: true }).value;
      code.classList.add('hljs');
    } catch {
      // 色付けできなくても、そのまま表示する
    }
  }
}

function languageOf(code) {
  return [...code.classList].find((c) => c.startsWith('language-'))?.slice('language-'.length) ?? '';
}

// コードブロックにマウスを載せたら、右上に言語名とコピーのボタンを出す。本文には手を加えない（重ねた層に置く）。
const codeTools = document.createElement('div');
codeTools.id = 'code-tools';
codeTools.hidden = true;
const codeLanguage = document.createElement('span');
const copyButton = document.createElement('button');
copyButton.textContent = 'コピー';
codeTools.append(codeLanguage, copyButton);
document.body.appendChild(codeTools);
let hoveredPre = null;
let copiedTimer = 0;

function showCodeTools(pre) {
  hoveredPre = pre;
  const code = pre.querySelector('code');
  codeLanguage.textContent = pre._mermaid ? 'mermaid' : code ? languageOf(code) : '';
  copyButton.textContent = 'コピー';
  codeTools.hidden = false;
  const rect = pre.getBoundingClientRect();
  codeTools.style.top = `${window.scrollY + rect.top + 6}px`;
  codeTools.style.left = `${window.scrollX + rect.right - 6 - codeTools.offsetWidth}px`;
}

document.addEventListener('mouseover', (event) => {
  if (codeTools.contains(event.target)) return;
  const pre = event.target.closest?.('pre');
  if (pre && content.contains(pre)) {
    if (pre !== hoveredPre || codeTools.hidden) showCodeTools(pre);
  } else {
    codeTools.hidden = true;
    hoveredPre = null;
  }
});

copyButton.addEventListener('click', () => {
  if (!hoveredPre) return;
  // 最後の改行は除く（cmark はコードの末尾に改行を付ける）
  post({ type: 'copy', text: (hoveredPre._mermaid?.source ?? hoveredPre.textContent).replace(/\n$/, '') });
  copyButton.textContent = 'コピーしました';
  clearTimeout(copiedTimer);
  copiedTimer = setTimeout(() => { copyButton.textContent = 'コピー'; }, 1500);
});

// MARK: - Mermaid の図

// ```mermaid のコードブロックを図にする。mermaid.min.js（約 5.5MB）は図のある文書を開いた時に初めて読み込む。
// pre 要素は残して中身を図（SVG）に置き換える（差分更新は色付け前の HTML で比べて pre を使い回すので、変わらない図は描き直さない）。
// 書き方の誤りで描けなければ、元のコードと理由を出す。描くのは1つずつ順番に（テーマの切り替えと重ならないように）。
let mermaidLoading = null;
let mermaidQueue = Promise.resolve();
let mermaidCount = 0;

function mermaidBlocks(root) {
  return [...(root.matches('pre') ? [root] : []), ...root.querySelectorAll('pre')]
    .filter((pre) => pre.querySelector(':scope > code.language-mermaid'));
}

function loadMermaid() {
  mermaidLoading ??= new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = 'yomitoki://app/mermaid.min.js';
    script.onload = () => resolve(window.mermaid);
    script.onerror = reject;
    document.head.appendChild(script);
  });
  return mermaidLoading;
}

function renderMermaid(pres) {
  if (pres.length === 0) return mermaidQueue;
  mermaidQueue = mermaidQueue.then(() => drawMermaid(pres)).catch(() => {});
  return mermaidQueue;
}

// 見た目（ライト／ダーク）が変わった時と、印刷の前（Swift がライトにしてから呼ぶ）に描き直す
function refreshMermaid() {
  return renderMermaid([...content.querySelectorAll('pre.mermaid-block')]);
}
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', refreshMermaid);

async function drawMermaid(pres) {
  const mermaid = await loadMermaid();
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: 'strict',
    theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default',
    fontFamily: getComputedStyle(document.body).fontFamily,
  });
  for (const pre of pres) {
    if (!pre.isConnected) continue;
    pre._mermaid ??= { source: pre.querySelector('code')?.textContent ?? pre.textContent };
    pre.classList.add('mermaid-block');
    const id = `mermaid-${++mermaidCount}`;
    try {
      const { svg } = await mermaid.render(id, pre._mermaid.source);
      pre.innerHTML = svg;
      pre.classList.remove('mermaid-error');
    } catch (error) {
      // 描けなかった時に mermaid が本文の外に残す要素を片付ける
      document.getElementById(id)?.remove();
      document.getElementById('d' + id)?.remove();
      const message = document.createElement('div');
      message.className = 'mermaid-message';
      message.textContent = `図にできませんでした：${error?.message ?? error}`;
      const code = document.createElement('code');
      code.textContent = pre._mermaid.source;
      pre.replaceChildren(message, code);
      pre.classList.add('mermaid-error');
    }
  }
}

// MARK: - 表の見出し行の固定

// 表は横スクロールのために .table-wrap（overflow-x: auto）で包んでいるので、CSS の position: sticky は
// 画面に対しては効かない。見出し行が画面の上に隠れた表があれば、その見出し行の複製を画面の上端に重ねる。
// 列の幅は元の表から写し、表の横スクロールにも合わせる。表の終わりが来たら一緒に押し上げる。
const stickyHead = document.createElement('div');
stickyHead.id = 'sticky-head';
stickyHead.hidden = true;
document.body.appendChild(stickyHead);
let stickyTable = null;
let stickyFrame = 0;

function scheduleStickyHead() {
  if (!stickyFrame) stickyFrame = requestAnimationFrame(updateStickyHead);
}

function updateStickyHead() {
  stickyFrame = 0;
  let table = null;
  for (const candidate of content.querySelectorAll('table')) {
    const head = candidate.tHead;
    if (!head) continue;
    const rect = candidate.getBoundingClientRect();
    if (rect.top >= 0) break;  // ここから下の表はまだ見出し行が見えている
    if (rect.bottom > head.getBoundingClientRect().height * 2) table = candidate;
  }
  if (!table) {
    stickyHead.hidden = true;
    stickyTable = null;
    return;
  }
  const wrap = table.closest('.table-wrap') ?? table.parentElement;
  if (table !== stickyTable) {
    stickyTable = table;
    const clone = document.createElement('table');
    clone.appendChild(table.tHead.cloneNode(true));
    for (const el of clone.querySelectorAll('*')) {
      el.removeAttribute('data-sourcepos');
      el.classList.remove(...MARK_CLASSES);
    }
    const cells = [...table.tHead.rows[0]?.cells ?? []];
    [...clone.tHead.rows[0]?.cells ?? []].forEach((cell, i) => {
      const width = `${cells[i].getBoundingClientRect().width}px`;
      cell.style.width = cell.style.minWidth = cell.style.maxWidth = width;
    });
    clone.style.width = `${table.getBoundingClientRect().width}px`;
    stickyHead.replaceChildren(clone);
  }
  const wrapRect = wrap.getBoundingClientRect();
  const tableRect = table.getBoundingClientRect();
  stickyHead.hidden = false;
  stickyHead.style.left = `${wrapRect.left}px`;
  stickyHead.style.width = `${wrap.clientWidth}px`;
  // 表の終わりが近づいたら、見出し行も一緒に押し上げる
  stickyHead.style.top = `${Math.min(0, tableRect.bottom - stickyHead.offsetHeight * 2)}px`;
  stickyHead.firstElementChild.style.transform = `translateX(${tableRect.left - wrapRect.left}px)`;
}

// 表の横スクロール（scroll は伝わらないので捕捉で受ける）
content.addEventListener('scroll', scheduleStickyHead, true);

// MARK: - 検索（照合は Swift 側。ここでは本文テキストの提供とハイライトだけを行う）

let searchNodes = [];  // [{ node, start }] 本文のテキストノードと、つなげた文字列での開始位置（UTF-16）
let highlighted = { ranges: [], current: -1 };  // ハイライト中の一致（ルーラーに出す）

function collectText() {
  searchNodes = [];
  let text = '';
  const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    searchNodes.push({ node, start: text.length });
    text += node.data;
  }
  return text;
}

// つなげた文字列での位置を（テキストノード, ノード内の位置）に変換する。終端はノードの末尾側に寄せる。
function locate(offset, isEnd) {
  let lo = 0, hi = searchNodes.length - 1, found = 0;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const start = searchNodes[mid].start;
    if (isEnd ? start < offset : start <= offset) {
      found = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  const entry = searchNodes[found];
  return [entry.node, Math.min(offset - entry.start, entry.node.data.length)];
}

function highlightSearch(ranges, current) {
  clearSearch();
  if (!window.CSS?.highlights || searchNodes.length === 0 || ranges.length === 0) return 0;
  const domRanges = [];
  for (const [location, length] of ranges) {
    const range = document.createRange();
    const [startNode, startOffset] = locate(location, false);
    const [endNode, endOffset] = locate(location + length, true);
    if (!startNode.isConnected || !endNode.isConnected) continue;
    range.setStart(startNode, startOffset);
    range.setEnd(endNode, endOffset);
    domRanges.push(range);
  }
  if (domRanges.length === 0) return 0;
  if (current < 0) {
    // 画面に見えている位置以降で最初の一致
    current = domRanges.findIndex((r) => r.getBoundingClientRect().bottom >= 0);
    if (current < 0) current = 0;
  }
  current = Math.min(current, domRanges.length - 1);
  highlighted = { ranges: domRanges, current };
  scheduleRuler();
  CSS.highlights.set('search', new Highlight(...domRanges));
  CSS.highlights.set('search-current', new Highlight(domRanges[current]));
  const rect = domRanges[current].getBoundingClientRect();
  if (rect.top < TOP || rect.bottom > window.innerHeight - 40) {
    window.scrollBy(0, rect.top - window.innerHeight / 3);
  }
  return current;
}

function clearSearch() {
  CSS.highlights?.delete('search');
  CSS.highlights?.delete('search-current');
  highlighted = { ranges: [], current: -1 };
  scheduleRuler();
}

// MARK: - その他

let frontMatterOpen = false;
content.addEventListener('toggle', (event) => {
  if (event.target.matches('details.front-matter')) frontMatterOpen = event.target.open;
}, true);

// <base> が文書のフォルダを指しているので、#fragment のリンクは自前でページ内スクロールする。
// 見出しの id は GitHub と同じく user-content- 付き。生 HTML の id・name と脚注は書かれたまま探す（本文の中だけ）。
document.addEventListener('click', (event) => {
  const link = event.target.closest('a[href^="#"]');
  if (!link) return;
  event.preventDefault();
  const id = decodeURIComponent(link.getAttribute('href').slice(1));
  const found = [document.getElementById('user-content-' + id), document.getElementById(id), ...document.getElementsByName(id)]
    .find((el) => el && content.contains(el));
  if (!found) return;
  post({ type: 'willJump' });
  if (found.dataset.sourcepos) {
    jumpToLine(startLine(found));
  } else {
    found.scrollIntoView({ block: 'start' });
  }
});

let selectionTimer;
document.addEventListener('selectionchange', () => {
  clearTimeout(selectionTimer);
  selectionTimer = setTimeout(() => post({ type: 'selection', text: String(window.getSelection() || '') }), 80);
});

document.addEventListener('error', (event) => {
  if (event.target.tagName === 'IMG') event.target.classList.add('broken');
}, true);

post({ type: 'ready' });
