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
        (on ? '关闭自启动' : '开启自启动') + '</button>';
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
        // 写成功：按响应值显示 + 记待确认（minSeq = 已应用序号 + 1，
        // 即任何不早于写后请求的已应用 200 快照都可确认），再无条件确认读
        _pending[name] = { value: !!j.autostart, minSeq: store.appliedSeq() + 1 };
        renderAutostart();
        renderAutostartHint();
        UI.toast(name + ' 自启动已保存（下次网关启动生效）', 'ok');
        store.forceRefresh();
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
    });
  }
})();
