import Foundation

/// Standalone gallery: relative PNG paths, no server, remote assets or settings writes.
enum ServiceMatrixGallery {
    static func html(schemes: [String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "providers": MeterProvider.allCases.map { ["id": $0.rawValue, "name": $0.displayName] },
            "schemes": schemes
        ], options: [.sortedKeys])
        return template.replacingOccurrences(of: "__MATRIX_DATA__", with: String(decoding: data, as: UTF8.self))
    }

    private static let template = #"""
    <!doctype html>
    <html lang="zh-CN">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="color-scheme" content="light">
      <title>BeaverMeter · 服务组合预览</title>
      <style>
        :root { --ink: #292c28; --muted: #62685f; --line: #d5d9cf; --accent: #315841; }
        * { box-sizing: border-box; }
        body { margin: 0; background: #f7f8f3; color: var(--ink); font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
        main { max-width: 1120px; margin: auto; padding: 44px 32px 64px; }
        header { padding-bottom: 24px; border-bottom: 1px solid var(--line); }
        .eyebrow { color: var(--accent); font: 12px/1.4 ui-monospace, monospace; letter-spacing: .09em; }
        h1 { margin: 12px 0 8px; font-size: clamp(26px, 4vw, 38px); font-weight: 650; letter-spacing: -.03em; }
        p { margin: 0; color: var(--muted); }
        .controls { padding: 24px 0; display: flex; flex-wrap: wrap; gap: 16px 28px; align-items: center; }
        fieldset { margin: 0; padding: 0; border: 0; display: flex; flex-wrap: wrap; gap: 8px; }
        legend { float: left; margin-right: 14px; font-weight: 600; padding-top: 8px; }
        label.switch { min-height: 42px; display: inline-flex; align-items: center; gap: 8px; padding: 8px 12px; border: 1px solid var(--line); border-radius: 7px; cursor: pointer; background: white; }
        label.switch:has(input:checked) { background: #e6eee5; border-color: #8caa91; }
        input { accent-color: var(--accent); width: 16px; height: 16px; margin: 0; }
        button, select { font: inherit; color: var(--ink); background: white; border: 1px solid var(--line); border-radius: 6px; padding: 8px 12px; min-height: 42px; }
        button { cursor: pointer; }
        button:hover { background: #edf1e9; }
        .chooser { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
        :focus-visible { outline: 3px solid #628d6a; outline-offset: 3px; }
        .selection { margin-bottom: 20px; padding-top: 16px; border-top: 1px solid var(--line); }
        h2 { font-size: 18px; margin: 0 0 4px; font-weight: 600; }
        .pair { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 20px; margin-bottom: 20px; }
        figure { margin: 0; padding: 22px; border: 1px solid var(--line); border-radius: 10px; background: #ecefe8; }
        figure.dark { background: #242824; border-color: #3d453e; color: #f0f3ed; }
        figcaption { display: flex; justify-content: space-between; gap: 12px; margin-bottom: 20px; font-size: 13px; }
        figcaption span:last-child { font: 12px/1.6 ui-monospace, monospace; opacity: .7; }
        .image { display: flex; justify-content: center; align-items: flex-start; }
        .image a { display: block; max-width: 100%; }
        img { display: block; width: 100%; max-width: 100%; height: auto; }
        footer { margin-top: 32px; border-top: 1px solid var(--line); padding-top: 18px; color: var(--muted); font-size: 13px; }
        a { color: var(--accent); }
        noscript { display: block; padding: 16px 0; }
        @media (max-width: 640px) {
          main { padding: 28px 16px 40px; }
          .pair { grid-template-columns: 1fr; }
          figure { padding: 16px; }
          legend { float: none; margin-bottom: 8px; padding: 0; }
          .controls { gap: 16px; }
          .chooser { width: 100%; }
          select { max-width: 100%; }
        }
      </style>
    </head>
    <body>
      <main>
        <header>
          <div class="eyebrow">BEAVERMETER / RENDER STUDY</div>
          <h1>服务开关组合预览</h1>
          <p id="counts">四种尺寸 Widget 与菜单栏弹窗 · 固定模拟数据</p>
          <p>每个模块是一项服务或一个 Codex 工作空间，内含双窗口。按选中顺序，Small 最多显示前 2 个模块，Medium 前 4 个，Large／Extra Large 前 6 个。服务开关开启不代表该尺寸展示所有模块，不自动展开工作空间，也没有 +N。</p>
          <p>Small 保留主重置和次窗口剩余值；Medium 展开窗口细节；Large 在模块内部增加使用量；Extra Large 恰好 4 个可见模块的 2×2 布局保留额度与当前用量，不显示七日统计／趋势；其他模块数量继续在同一模块内显示可用七日趋势。每个 Codex 工作空间显示各自已验证账号的用量和日期，不借用其他空间或全局统计；没有独立底部摘要区。重置卡库存／到期和 Cursor 月度已用／上限仍在菜单栏弹窗。</p>
        </header>
        <section class="controls" aria-label="选择服务组合">
          <fieldset id="switches"><legend>显示服务</legend></fieldset>
          <div class="chooser">
            <label for="combination">全部组合</label>
            <select id="combination"></select>
            <button type="button" id="all">全部开启</button>
            <button type="button" id="none">全部关闭</button>
          </div>
        </section>
        <section class="selection" aria-live="polite" aria-atomic="true">
          <h2 id="selection-title">全部开启</h2>
          <p>浅深色并排对照；点击图片查看原始 2 倍分辨率 PNG。</p>
        </section>
        <div id="renders"></div>
        <noscript>请启用 JavaScript 筛选组合，也可直接查看：
          <a href="codex-claude-cursor-deepseek/light/widget-small.png">小号浅色</a>、
          <a href="codex-claude-cursor-deepseek/dark/widget-small.png">小号深色</a>、
          <a href="codex-claude-cursor-deepseek/light/menu.png">菜单栏浅色</a>、
          <a href="codex-claude-cursor-deepseek/dark/menu.png">菜单栏深色</a>。
        </noscript>
        <footer>图片由应用共享的 SwiftUI 视图生成，用于比较布局和色阶；离线预览不验证 WidgetKit 桌面宿主的合成效果或焦点切换。服务开关仅切换本地预览，不修改应用设置。所有数据均为模拟数据。</footer>
      </main>
      <script>
        'use strict';
        const { providers, schemes } = __MATRIX_DATA__;
        const count = 1 << providers.length;
        const all = count - 1;
        const switches = document.getElementById('switches');
        const select = document.getElementById('combination');
        const renders = document.getElementById('renders');
        const sizes = [
          { file: 'widget-small', title: '小号 Widget', width: 174, height: 174 },
          { file: 'widget-medium', title: '中号 Widget', width: 352, height: 174 },
          { file: 'widget-large', title: '大号 Widget', width: 352, height: 352 },
          { file: 'widget-extra-large', title: '超大号 Widget', width: 710, height: 352 },
          { file: 'menu', title: '菜单栏弹窗', width: 410 }
        ];
        const enabled = mask => providers.filter((_, index) => mask & (1 << index));
        const title = mask => enabled(mask).map(provider => provider.name).join(' + ') || '全部关闭';
        const directory = mask => enabled(mask).map(provider => provider.id).join('-') || 'none';
        document.getElementById('counts').textContent = `${count} 种组合 · ${count * schemes.length * sizes.length} 张 PNG · 固定模拟数据`;
        providers.forEach((provider, index) => {
          const label = document.createElement('label');
          label.className = 'switch';
          const input = document.createElement('input');
          input.type = 'checkbox'; input.value = index; input.id = `service-${provider.id}`;
          label.append(input, document.createTextNode(provider.name)); switches.append(label);
          input.addEventListener('change', () => choose([...switches.querySelectorAll('input')]
            .reduce((mask, checkbox) => mask | (checkbox.checked ? 1 << Number(checkbox.value) : 0), 0)));
        });
        for (let mask = 0; mask < count; mask++) {
          const option = document.createElement('option'); option.value = mask; option.textContent = title(mask); select.append(option);
        }
        function render(mask) {
          select.value = mask;
          switches.querySelectorAll('input').forEach((input, index) => { input.checked = Boolean(mask & (1 << index)); });
          document.getElementById('selection-title').textContent = title(mask);
          renders.replaceChildren();
          sizes.forEach(size => {
            const pair = document.createElement('section'); pair.className = 'pair'; pair.setAttribute('aria-label', size.title);
            ['light', 'dark'].filter(scheme => schemes.includes(scheme)).forEach(scheme => {
              const figure = document.createElement('figure'); figure.className = scheme;
              const caption = document.createElement('figcaption');
              const label = document.createElement('span'); label.textContent = `${size.title} · ${scheme === 'light' ? '浅色' : '深色'}`;
              const resolution = document.createElement('span'); resolution.textContent = size.height ? `${size.width * 2} × ${size.height * 2} px` : '820 px · 完整高度';
              caption.append(label, resolution);
              const wrapper = document.createElement('div'); wrapper.className = 'image';
              const link = document.createElement('a'); link.href = `${directory(mask)}/${scheme}/${size.file}.png`; link.target = '_blank'; link.rel = 'noopener'; link.style.width = `${size.width}px`;
              const image = document.createElement('img'); image.src = link.href; image.width = size.width;
              if (size.height) image.height = size.height;
              image.alt = `${title(mask)}，${label.textContent}`; image.decoding = 'async';
              link.append(image); wrapper.append(link); figure.append(caption, wrapper); pair.append(figure);
            });
            renders.append(pair);
          });
        }
        function choose(mask) { location.hash = `mask=${mask}`; }
        function readHash() {
          const value = new URLSearchParams(location.hash.slice(1)).get('mask');
          const mask = value !== null && /^\d+$/.test(value) ? Number(value) : all;
          return Number.isInteger(mask) && mask >= 0 && mask < count ? mask : all;
        }
        select.addEventListener('change', () => choose(Number(select.value)));
        document.getElementById('all').addEventListener('click', () => choose(all));
        document.getElementById('none').addEventListener('click', () => choose(0));
        window.addEventListener('hashchange', () => render(readHash()));
        render(readHash());
      </script>
    </body>
    </html>
    """#
}
