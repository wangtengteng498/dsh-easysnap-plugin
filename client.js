window.__ModuleLoader__.load({
  id: 'dsh-easysnap-plugin',
  factory(require) {
    const React = require('react');
    const h = React.createElement;

    function findComposer() {
      const editables = document.querySelectorAll('[contenteditable="true"]');
      if (editables.length) return editables[editables.length - 1];
      const areas = document.querySelectorAll('textarea');
      return areas.length ? areas[areas.length - 1] : null;
    }

    // 把 PNG 塞进输入框：先合成 paste（DSH 粘贴图片走这条路），失败再补 drop。
    function insertImageFile(file) {
      const target = findComposer() || document;
      const dt = new DataTransfer();
      dt.items.add(file);
      let ok = false;
      try {
        target.dispatchEvent(new ClipboardEvent('paste', {
          clipboardData: dt, bubbles: true, cancelable: true,
        }));
        ok = true;
      } catch (e) { ok = false; }
      if (!ok) {
        try {
          target.dispatchEvent(new DragEvent('drop', {
            dataTransfer: dt, bubbles: true, cancelable: true,
          }));
          ok = true;
        } catch (e) { ok = false; }
      }
      return ok;
    }

    const btnBase = {
      display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
      width: 26, height: 26, padding: 0, margin: '0 2px',
      border: '1px solid transparent', borderRadius: 6,
      background: 'transparent', cursor: 'pointer',
      color: 'var(--dsw-alias-text-secondary, #8a8f98)', lineHeight: 0,
    };
    const btnHover = {
      background: 'var(--dsw-alias-bg-hover, rgba(127,127,127,0.14))',
      color: 'var(--dsw-alias-text-primary, #1f2328)',
    };
    const btnBusy = {
      opacity: 0.55, cursor: 'default',
      color: 'var(--dsw-alias-text-accent, #2f7cf6)',
    };
    const noteStyle = {
      position: 'fixed', left: '50%', bottom: 90, transform: 'translateX(-50%)',
      zIndex: 2147483001, padding: '6px 12px', borderRadius: 8,
      background: 'var(--dsw-alias-bg-elevated, rgba(20,20,20,0.9))',
      color: 'var(--dsw-alias-text-primary, #fff)',
      font: '12px/1.4 system-ui, sans-serif', pointerEvents: 'none', maxWidth: '70vw',
    };

    function SnapButton() {
      const [hover, setHover] = React.useState(false);
      const [busy, setBusy] = React.useState(false);
      const [note, setNote] = React.useState('');
      const pollRef = React.useRef(null);
      const noteTimer = React.useRef(null);

      const flash = (text, ms) => {
        setNote(text);
        if (noteTimer.current) clearTimeout(noteTimer.current);
        if (ms) noteTimer.current = setTimeout(() => setNote(''), ms);
      };

      const stopPoll = () => {
        if (pollRef.current) { clearInterval(pollRef.current); pollRef.current = null; }
      };

      React.useEffect(() => () => {
        stopPoll();
        if (noteTimer.current) clearTimeout(noteTimer.current);
      }, []);

      const openFrame = async () => {
        // 允许在“取景中”再次点击：会重开框并重置轮询，不会卡死
        setBusy(true);
        // 提示只停留几秒，别一直挡视线
        flash('取景框已打开：拖到目标位置，点框上的 Snap', 4500);
        try {
          const r = await fetch('/dsh-easysnap-plugin/frame', { cache: 'no-store' });
          if (!r.ok) throw new Error('HTTP ' + r.status);
        } catch (e) {
          setBusy(false);
          flash('打开取景框失败：' + (e && e.message ? e.message : e), 6000);
          return;
        }

        const started = Date.now();
        let lastTs = 0;
        let count = 0;
        stopPoll();
        pollRef.current = setInterval(async () => {
          // 框一直开着就持续轮询：每点一次 Snap 都追加一张，最多等 10 分钟
          if (Date.now() - started > 600000) {
            stopPoll();
            setBusy(false);
            return;
          }
          try {
            let alive = true;
            let hasShot = false;
            const sr = await fetch('/dsh-easysnap-plugin/state?t=' + Date.now(), { cache: 'no-store' });
            if (sr.ok) {
              const st = await sr.json();
              alive = !!st.alive;
              hasShot = !!st.hasShot;
            }
            if (!hasShot && !alive) {
              stopPoll();
              setBusy(false);
              flash(count > 0 ? ('已插入 ' + count + ' 张，取景框已关闭') : '取景框已关闭', 2200);
              return;
            }
            if (!hasShot) return;
            const rr = await fetch('/dsh-easysnap-plugin/last?since=' + lastTs + '&t=' + Date.now(), { cache: 'no-store' });
            if (rr.status === 204 || !rr.ok) return;
            const ts = Number(rr.headers.get('x-shot-ts') || '0');
            const blob = await rr.blob();
            if (!blob || blob.size < 100) return;
            const stamp = Number.isFinite(ts) && ts > 0 ? Math.floor(ts) : Date.now();
            if (stamp <= lastTs) return;   // 同一张不重复插入
            lastTs = stamp;
            const file = new File([blob], 'snap-' + Date.now() + '.png', { type: 'image/png' });
            const ok = insertImageFile(file);
            count += 1;
            flash(ok ? ('已插入第 ' + count + ' 张') : '已生成图片，但没能插入输入框', 2200);
          } catch (e) { /* 网络抖动，继续轮询 */ }
        }, 600);
      };

      const cameraIcon = h('svg', {
        width: 17, height: 17, viewBox: '0 0 24 24', fill: 'none',
        stroke: 'currentColor', strokeWidth: 1.8, strokeLinecap: 'round',
        strokeLinejoin: 'round', 'aria-hidden': true,
      },
        h('path', { d: 'M3 8.5A2.5 2.5 0 0 1 5.5 6h1.6l1.2-1.7h7.4L16.9 6h1.6A2.5 2.5 0 0 1 21 8.5v9A2.5 2.5 0 0 1 18.5 20h-13A2.5 2.5 0 0 1 3 17.5z' }),
        h('circle', { cx: 12, cy: 13, r: 3.2 }));

      let style = btnBase;
      if (hover && !busy) style = Object.assign({}, btnBase, btnHover);
      if (busy) style = Object.assign({}, btnBase, btnBusy);

      const buttonEl = h('button', {
        type: 'button',
        title: busy ? '取景框中：点框里的 Snap 拍下来（再点这里可重开）' : '打开桌面取景框截图',
        'aria-label': '打开取景框截图',
        style,
        onMouseEnter: () => setHover(true),
        onMouseLeave: () => setHover(false),
        onClick: openFrame,
      }, cameraIcon);

      const noteEl = note ? h('div', { style: noteStyle }, note) : null;

      return h(React.Fragment, null, buttonEl, noteEl);
    }

    return {
      inject: ['slots'],
      apply(ctx) {
        ctx.slots.inject('conversation.input.left', () => ctx.slots.register({
          name: 'conversation.input.left',
          id: 'dsh-easysnap-plugin',
          order: 20,
        }, SnapButton));
      },
    };
  },
});
