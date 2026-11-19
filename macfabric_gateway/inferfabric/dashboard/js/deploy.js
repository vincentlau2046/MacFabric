/* InferFabric Console — Deploy tab (v2, Task 7)
 * 部署表单（name + engine 类型）+ 拉取表单（name + framework）+ 长任务进度态。
 *
 * 数据源：
 *   - POST /deploy {name, type}     — 生成 YAML 并切换（admin header）
 *   - POST /pull  {name, framework} — 下载权重（admin header）
 *
 * 设计纪律（R12 + R14）：
 *   - 部署表单仅含 name + engine 类型选择（vllm / llama_cpp——auto_deploy 仅支持
 *     此两者，model_discovery.py:141；sglang/ninfer/ollama 服务需 models.d/ 手动 YAML）。
 *     旧 model_dir / port / gpu_mem slider 字段已删除——后端 auto_deploy
 *     自动生成 YAML，不读这些字段（handler.py:1055 _handle_deploy 仅取 name+type）。
 *   - 拉取表单仅含 name + framework。
 *   - 事件委托（无 inline onclick）；数字等宽 tabular-nums；零 emoji（SVG 图标）。
 *   - 破坏性/重型操作 UI.confirm：deploy 启动模型=GPU 资源承诺；
 *     pull 网络磁盘密集。
 *   - /pull 同步无流式：in-flight 期间显示不定进度指示器，响应后替换为结果文本。
 *
 * 暴露：
 *   - window.tabRenderers['tab-deploy'] = renderDeploy
 *   - window.doDeploy() / window.doPull()
 */
(function () {
  'use strict';

  var UI = window.UI;
  var store = window.store;
  if (!UI || !store) {
    console.warn('[deploy] UI/store not ready — deferring');
    return;
  }

  var $ = function (id) { return document.getElementById(id); };

  var ENGINE_LABEL = {
    vllm: 'vLLM', llama_cpp: 'llama.cpp',
  };

  function engineLabel(type) {
    return ENGINE_LABEL[type] || (type ? type.charAt(0).toUpperCase() + type.slice(1) : '—');
  }

  /* ── 进度态 helpers ──
   *   showProgress(msg)   — in-flight：不定 spinner + 消息
   *   showResult(title, detail) — 完成/失败：替换 spinner 为结果文本（保留可见） */
  function showProgress(msg) {
    var card = $('depProgressCard');
    var box = $('deployProgress');
    if (card) card.style.display = '';
    if (!box) return;
    box.innerHTML =
      '<div class="dep-progress-row">' +
        '<span class="dep-spinner"></span>' +
        '<span class="dep-progress-msg"></span>' +
      '</div>';
    var msgEl = box.querySelector('.dep-progress-msg');
    if (msgEl) msgEl.textContent = msg;
  }

  function showResult(title, detail) {
    var card = $('depProgressCard');
    var box = $('deployProgress');
    if (card) card.style.display = '';
    if (!box) return;
    box.innerHTML = '<div class="dep-progress-result"></div>';
    var el = box.querySelector('.dep-progress-result');
    if (el) el.textContent = title + (detail ? ' · ' + detail : '');
  }

  function setBtnBusy(action, busy) {
    var btn = document.querySelector('[data-action="' + action + '"]');
    if (btn) btn.disabled = busy;
  }

  /* ── 部署：POST /deploy {name, type} ──
   *   后端 auto_deploy 生成 YAML → switch。already_configured 时后端亦自动 switch
   *   （handler.py:1063），故统一视为成功路径。成功后跳转推理 TAB 查看新模型。 */
  window.doDeploy = async function () {
    var nameEl = $('depName');
    var typeEl = $('depType');
    var name = nameEl ? nameEl.value.trim() : '';
    var type = typeEl ? typeEl.value : 'vllm';
    if (!name) { UI.toast('请输入模型名称', 'error'); return; }

    var run = async function () {
      setBtnBusy('deploy', true);
      showProgress('正在部署 ' + name + '…');
      try {
        var res = await fetch('/deploy', {
          method: 'POST',
          headers: UI.adminHeaders(),
          body: JSON.stringify({ name: name, type: type }),
        });
        var j = null;
        try { j = await res.json(); } catch (_) {}
        if (!res.ok) {
          var msg = (j && (j.error || j.message)) || ('HTTP ' + res.status);
          throw new Error(msg);
        }
        // 后端对逻辑失败也返回 HTTP 200（_handle_deploy 用 _send_json 默认 200），
        // 必须查 j.status：成功仅 {switched, already_active}（model_lifecycle.py:333）；
        // 其余（"Unsupported type for auto-deploy" / "Unknown model" / "Invalid transition"）为失败。
        var st = j && j.status ? j.status : '';
        if (st !== 'switched' && st !== 'already_active') {
          throw new Error((j && j.message) || ('未知状态: ' + (st || '(空)')));
        }
        showResult(name + ' 部署完成', engineLabel(type));
        UI.toast(name + ' 部署完成', 'ok');
        store.forceRefresh();
        store.switchTab('tab-inference');
      } catch (e) {
        showResult(name + ' 部署失败', (e && e.message ? e.message : String(e)));
        UI.toast('部署失败: ' + (e && e.message ? e.message : e), 'error');
      } finally {
        setBtnBusy('deploy', false);
      }
    };

    UI.confirm({
      title: '部署模型',
      body: '将部署 ' + name + '（' + engineLabel(type) + '）。后端自动生成 YAML 并切换，'
            + '将占用 GPU 资源，可能耗时数十秒加载权重。确定？',
      onOk: run,
    });
  };

  /* ── 拉取：POST /pull {name, framework} ──
   *   /pull 同步无流式（ollama pull 子进程最长 1800s）。in-flight 期间显示不定
   *   spinner，响应后替换为结果文本。仅 ollama 框架实际支持拉取。 */
  window.doPull = async function () {
    var nameEl = $('pullName');
    var fwEl = $('pullFw');
    var name = nameEl ? nameEl.value.trim() : '';
    var fw = fwEl ? fwEl.value : '';
    if (!name) { UI.toast('请输入模型名称', 'error'); return; }

    var run = async function () {
      setBtnBusy('pull', true);
      showProgress('正在拉取 ' + name + '…');
      try {
        var res = await fetch('/pull', {
          method: 'POST',
          headers: UI.adminHeaders(),
          body: JSON.stringify({ name: name, framework: fw }),
        });
        var j = null;
        try { j = await res.json(); } catch (_) {}
        if (!res.ok) {
          var msg = (j && (j.error || j.message)) || ('HTTP ' + res.status);
          throw new Error(msg);
        }
        var st = j && j.status ? j.status : '';
        if (st === 'pulled') {
          showResult(name + ' 拉取完成', (j && j.message) || '');
          UI.toast(name + ' 拉取完成', 'ok');
          store.forceRefresh();
        } else {
          // 后端返回 error 状态（如 vllm/llama_cpp 不支持拉取）
          var emsg = (j && j.message) || '未知结果';
          showResult(name + ' 拉取未完成', emsg);
          UI.toast('拉取未完成: ' + emsg, 'error');
        }
      } catch (e) {
        showResult(name + ' 拉取失败', (e && e.message ? e.message : String(e)));
        UI.toast('拉取失败: ' + (e && e.message ? e.message : e), 'error');
      } finally {
        setBtnBusy('pull', false);
      }
    };

    UI.confirm({
      title: '拉取模型',
      body: '将拉取 ' + name + '（' + fw + '）。网络与磁盘密集，可能耗时数分钟。确定？',
      onOk: run,
    });
  };

  /* ── 自启动开关（M2-T3）──
   * 数据源：snapshot models[].{name,autostart}；POST /admin/models/set-autostart。
   * 时序契约（Review Focus 3）：
   *   - 每模型单写在途（_inflight），连点不重复 POST；
   *   - POST 失败回滚显示快照值并报错；
   *   - 写成功先按响应值显示，随即无条件发起写后快照（forceRefresh）；
   *   - 确认读（不早于写后请求的已应用 HTTP 200 快照）到达前显示
   *     「待回读确认」，轮询不得覆盖（store 序号守卫 + _pending 覆盖显示）；
   *   - 304 不推进序号、不作确认（store.js）；
   *   - 受信新快照与写值不同 → 按服务端值显示并提示不一致。 */
  var _inflight = {};   // model → true
  var _pending = {};    // model → { value, minSeq }（写后待确认读）

  function escHtml(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function renderAutostart() {
    var el = $('depAutostart');
    if (!el) return;
    var models = store.get('models') || [];
    if (!models.length) {
      el.innerHTML = '<p class="if-field-hint">暂无模型。</p>';
      return;
    }
    var rows = models.map(function (m) {
      var name = m.name || '';
      var pend = _pending[name];
      var snapOn = !!m.autostart;
      var on = pend ? pend.value : snapOn;
      var badge = pend
        ? '<span class="badge warn">待回读确认</span>'
        : (on ? '<span class="badge ok">开</span>' : '<span class="badge">关</span>');
      var busy = _inflight[name] ? ' disabled' : '';
      var btn = '<button type="button" class="btn btn-sec btn-sm" data-action="autostart-toggle"' +
        ' data-model="' + escHtml(name) + '" data-cur="' + (on ? '1' : '0') + '"' + busy + '>' +
        (on ? '关闭自启动' : '开启自启动') + '</button>' +
        ' <button type="button" class="btn btn-danger btn-sm" data-action="model-remove"' +
        ' data-model="' + escHtml(name) + '"' + busy + '>移除</button>';
      return '<tr><td class="mono">' + escHtml(name) + '</td><td>' + badge + '</td><td>' + btn + '</td></tr>';
    }).join('');
    el.innerHTML = '<table class="if-table"><thead><tr><th>模型</th><th>自启动</th><th>操作</th></tr></thead>' +
      '<tbody>' + rows + '</tbody></table>';
  }

  function renderAutostartHint() {
    var hint = $('depAutostartHint');
    if (hint) {
      var names = Object.keys(_pending);
      hint.textContent = names.length
        ? '待回读确认：' + names.join('、') + ' — 已下发，等待服务端快照确认（确认前轮询不会覆盖显示）。'
        : '';
    }
  }

  function doAutostartToggle(name, cur) {
    if (_inflight[name]) return;   // 每模型单写在途
    var target = !cur;
    _inflight[name] = true;
    renderAutostart();
    fetch('/admin/models/set-autostart', {
      method: 'POST',
      headers: UI.adminHeaders(),
      body: JSON.stringify({ name: name, enabled: target }),
    }).then(function (res) {
      return res.json().then(function (j) {
        delete _inflight[name];
        if (!res.ok || !j || j.status !== 'ok') {
          var msg = (j && (j.error || j.message)) || ('HTTP ' + res.status);
          UI.toast('自启动保存失败：' + msg, 'error');   // 回滚 = 显示快照值
          renderAutostart();
          return;
        }
        // 写成功：按响应值显示 + 记待确认，再无条件确认读。
        // 确认读门槛 = 确认读请求自身的发出序号（终审 Important-2）：
        // 写前在途轮询的序号可能恰为 appliedSeq()+1，若以其为确认读，
        // 旧值快照会先应用并误报「不一致」— onSeq 在请求发出前同步回调，
        // 早于任何响应应用。
        var pend = { value: !!j.autostart, minSeq: Infinity };
        _pending[name] = pend;
        renderAutostart();
        renderAutostartHint();
        UI.toast(name + ' 自启动已保存（下次网关启动生效）', 'ok');
        store.forceRefreshEx(true, function (seq) { pend.minSeq = seq; });
      }, function () {
        delete _inflight[name];
        UI.toast('自启动保存失败：HTTP ' + res.status + '（非 JSON 响应）', 'error');
        renderAutostart();
      });
    }, function (e) {
      delete _inflight[name];
      UI.toast('自启动保存失败：网络错误 ' + (e && e.message ? e.message : ''), 'error');
      renderAutostart();
    });
  }

  /* 确认读解析：任何已应用快照序号 ≥ minSeq 时结算该模型的待确认 */
  store.on('snapshot_seq', function (seq) {
    var models = store.get('models') || [];
    var byName = {};
    models.forEach(function (m) { byName[m.name] = m; });
    Object.keys(_pending).forEach(function (name) {
      var p = _pending[name];
      if (seq < p.minSeq) return;   // 写后确认读未到（含 304 — 序号不推进）
      var snapOn = !!(byName[name] && byName[name].autostart);
      delete _pending[name];
      if (snapOn !== p.value) {
        UI.toast(name + ' 服务端回读与写值不一致，已按服务端显示', 'error');
      }
    });
    renderAutostart();
    renderAutostartHint();
  });

  /* ── 模型移除（iff remove 入口，上游 issue #8 item 1）──
   * 三段式确认：预览（无 confirmed，零副作用）→ 报告展示（blocked 时给
   * purge 选项，勾选后必须「重新预览」二次预览）→ confirmed:true 执行。
   * 预览与执行各调一次 POST（服务端重算，不缓存预览报告）；
   * 执行 409（预览后池引用变化）→ 用响应报告回预览重走，不自动重试。 */
  var _remove = null;   // { name, report, purge, busy }

  function _fetchAdmin(url, opts, cb) {
    opts = opts || {};
    opts.headers = UI.adminHeaders();
    if (opts.body && typeof opts.body !== 'string') opts.body = JSON.stringify(opts.body);
    fetch(url, opts).then(function (res) {
      var unauthorized = res.status === 401;
      res.json().then(function (j) {
        if (unauthorized) {
          UI.toast('401：需要 admin token — 请在右上角输入后重试', 'error');
          cb({ unauthorized: true, message: (j && j.error) || 'unauthorized' }, j, res.status);
        } else {
          cb(null, j, res.status);
        }
      }, function () {
        cb({ message: 'HTTP ' + res.status + '（非 JSON 响应）' }, null, res.status);
      });
    }, function (e) {
      cb({ message: '网络错误：' + e.message });
    });
  }

  var REMOVE_URL = '/admin/models/remove';

  function openRemoveModal(name) {
    if (_remove && _remove.busy) return;
    _fetchAdmin(REMOVE_URL, { method: 'POST', body: { name: name } }, function (err, j) {
      if (err) {
        if (!err.unauthorized) UI.toast('移除预览失败：' + err.message, 'error');
        return;   // 401 已由 _fetchAdmin 统一提示
      }
      _remove = { name: name, report: j || {}, purge: false, busy: false, error: null };
      renderRemoveModal();
    });
  }

  function closeRemoveModal() {
    if (!_remove) return;
    document.removeEventListener('keydown', _remove.onKey);
    var holder = document.getElementById('depRemoveModal');
    if (holder) { holder.style.display = 'none'; holder.innerHTML = ''; }
    _remove = null;
  }

  /* running 三值：预览报告的 would-stop.running（true/false/"unknown"）；
   * 无停止动作且显式 skipped → 未运行；其余缺省 → 状态未知。 */
  function removeRunningState(report) {
    var actions = report.actions || [];
    for (var i = 0; i < actions.length; i++) {
      var a = actions[i];
      if (a.action === 'would-stop') {
        if (a.running === true) return { badge: '运行中', hint: '执行时将先停止服务' };
        if (a.running === false) return { badge: '未运行', hint: '' };
        return { badge: '状态未知', hint: '执行时将尝试停止' };
      }
      if (a.action === 'stop' && a.status === 'skipped') {
        return { badge: '未运行', hint: '' };
      }
    }
    return { badge: '状态未知', hint: '执行时将尝试停止' };
  }

  function removeListBlock(title, items) {
    if (!items || !items.length) return '';
    return '<p class="if-field-label">' + title + '</p><ul class="if-field-hint">' +
      items.map(function (p) { return '<li class="mono">' + escHtml(p) + '</li>'; }).join('') +
      '</ul>';
  }

  function renderRemoveModal() {
    if (!_remove) return;
    var st = _remove;              // body 构建即引用（error 态），须先于 innerHTML
    var r = _remove.report || {};
    var name = _remove.name;
    var holder = document.getElementById('depRemoveModal');
    if (!holder) {
      holder = document.createElement('div');
      holder.id = 'depRemoveModal';
      document.body.appendChild(holder);
    }
    var running = removeRunningState(r);
    var poolRefs = r.pool_refs || [];
    var blocked = r.status === 'blocked';
    var scenario = r.scenario_refs || [];
    var scenarioFiles = scenario.map(function (s) {
      return (s.file || s.path || '?') + (s.preset ? ' · ' + s.preset : '');
    });
    var body = '';
    if (r.status === 'error') {
      body = '<p class="if-field-hint" style="color:var(--crit)">' + escHtml(r.message || '预览失败') + '</p>';
    } else {
      body =
        '<p>服务状态：<span class="badge ' + (running.badge === '运行中' ? 'warn' : '') + '">' +
          escHtml(running.badge) + '</span>' +
        (running.hint ? ' <span class="if-field-hint">' + escHtml(running.hint) + '</span>' : '') + '</p>' +
        (blocked
          ? '<p style="color:var(--crit)">该模型被模型池候选引用，默认阻止移除：</p>' +
            removeListBlock('引用该模型的池候选', poolRefs.map(function (p) {
              return (p.pool || '?') + ' ← ' + (p.model_name || p.id || '?');
            }))
          : '') +
        (_remove.purge && (r.actions || []).some(function (a) {
          return a.action === 'would-purge-pool-candidates';
        }) ? '<p class="if-field-hint">二次预览：将同时清除以上池候选引用（执行时以服务端重新计算为准）。</p>' : '') +
        removeListBlock('以下权重文件不会被删除（工具永不删权重）：', r.weights_kept) +
        (scenario.length
          ? removeListBlock('移除后遗留的场景侧车条目（加载时被忽略）：', scenarioFiles)
          : '') +
        (blocked
          ? '<label class="cpm-cap"><input type="checkbox" id="depRemovePurge"' +
            (_remove.purge ? ' checked' : '') + '> 同时清除以上池候选引用（purge_pools）</label>' +
            '<p class="if-field-hint">勾选后需「重新预览」确认副作用，才能执行移除。</p>'
          : '') +
        '<p class="if-field-hint">最终引用与状态以服务端执行时重新计算为准。</p>' +
        (st.error
          ? '<p class="if-field-hint" id="depRemoveErr" style="color:var(--crit)">' +
            escHtml(st.error) + '</p>'
          : '<p class="if-field-hint" id="depRemoveErr" style="display:none"></p>');
    }
    var canConfirm = r.status === 'would-remove';
    holder.innerHTML =
      '<div class="if-modal-backdrop">' +
        '<div class="if-modal" role="dialog" aria-modal="true" aria-label="移除模型">' +
          '<div class="if-modal-title" style="color:var(--crit)">移除模型 — ' + escHtml(name) + '</div>' +
          '<div class="if-modal-body">' + body + '</div>' +
          '<div class="if-modal-actions">' +
            '<button type="button" class="btn btn-sec" data-act="remove-cancel">取消</button>' +
            (blocked
              ? '<button type="button" class="btn btn-sec" data-act="remove-repreview"' +
                (_remove.purge ? '' : ' disabled') + '>重新预览</button>'
              : '') +
            '<button type="button" class="btn btn-danger" data-act="remove-confirm"' +
              (_remove.busy || !canConfirm ? ' disabled' : '') + '>确认移除</button>' +
          '</div>' +
        '</div>' +
      '</div>';
    holder.style.display = '';
    if (st.onKey) document.removeEventListener('keydown', st.onKey);   // 重渲染不累积
    st.onKey = function (e) { if (e.key === 'Escape') closeRemoveModal(); };
    document.addEventListener('keydown', st.onKey);
    var backdrop = holder.querySelector('.if-modal-backdrop');
    backdrop.addEventListener('click', function (ev) {
      var act = ev.target.getAttribute && ev.target.getAttribute('data-act');
      if (act === 'remove-cancel' || ev.target === backdrop) { closeRemoveModal(); return; }
      if (act === 'remove-repreview') {
        // 二次预览：单独一次 POST（服务端重算），不缓存第一次的报告
        st.busy = true; st.error = null; renderRemoveModal();
        _fetchAdmin(REMOVE_URL, { method: 'POST', body: { name: st.name, purge_pools: !!st.purge } },
          function (err, j) {
            st.busy = false;
            if (err) {
              if (!err.unauthorized) UI.toast('移除预览失败：' + err.message, 'error');
              renderRemoveModal();
              return;
            }
            st.report = j || {};
            renderRemoveModal();
          });
        return;
      }
      if (act === 'remove-confirm') {
        st.busy = true; st.error = null; renderRemoveModal();
        var bodyReq = { name: st.name, confirmed: true };
        if (st.purge) bodyReq.purge_pools = true;
        _fetchAdmin(REMOVE_URL, { method: 'POST', body: bodyReq }, function (err, j, code) {
          st.busy = false;
          if (err) {
            if (!err.unauthorized) UI.toast('移除失败：' + err.message, 'error');
            renderRemoveModal();
            return;
          }
          if (code === 409 && j && j.status === 'blocked') {
            // 预览后池引用变化的竞态：回预览重走，不自动重试
            st.report = j;
            UI.toast('执行时发现新的池候选引用，已回到预览 — 请重新确认', 'error');
            renderRemoveModal();
            return;
          }
          if (j && j.status === 'removed') {
            closeRemoveModal();
            UI.toast(name + ' 已移除（权重保留在原位置）', 'ok');
            store.forceRefresh();
            return;
          }
          // 400/500 执行失败：弹窗内联报错（走状态重渲染，保留上下文），不关窗
          var msg = (j && (j.error || j.message)) || ('HTTP ' + code);
          st.error = '移除失败：' + msg;
          renderRemoveModal();
        });
        return;
      }
    });
    var purgeCb = holder.querySelector('#depRemovePurge');
    if (purgeCb) {
      purgeCb.addEventListener('change', function () {
        st.purge = purgeCb.checked;
        renderRemoveModal();   // 勾选变化 → 回到待二次预览态（确认键保持禁用）
      });
    }
  }

  /* ── 渲染入口 ──
   *   部署/拉取表单为静态（无 snapshot 数据依赖）；进度卡由 doDeploy/doPull 显隐。 */
  function renderDeploy() {
    renderAutostart();
  }

  window.renderDeploy = renderDeploy;
  window.tabRenderers['tab-deploy'] = renderDeploy;

  store.on('tab_active', function (tab) {
    if (tab === 'tab-deploy') renderDeploy();
  });
  store.on('models', function () {
    if (store.get('tab_active') === 'tab-deploy') renderAutostart();
  });

  /* ── 事件委托（无 inline onclick） ── */
  var root = $('tab-deploy');
  if (root) {
    root.addEventListener('click', function (ev) {
      var btn = ev.target.closest('[data-action]');
      if (!btn || !root.contains(btn) || btn.disabled) return;
      var act = btn.getAttribute('data-action');
      if (act === 'deploy') { window.doDeploy(); return; }
      if (act === 'pull') { window.doPull(); return; }
      if (act === 'autostart-toggle') {
        doAutostartToggle(btn.getAttribute('data-model'),
                          btn.getAttribute('data-cur') === '1');
        return;
      }
      if (act === 'autostart-goto-inference') { store.switchTab('tab-inference'); return; }
      if (act === 'model-remove') { openRemoveModal(btn.getAttribute('data-model')); return; }
    });
  }
})();
