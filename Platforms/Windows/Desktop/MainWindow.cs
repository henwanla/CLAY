using System.Drawing.Drawing2D;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Diagnostics;

namespace Clay.Windows;

internal sealed class MainWindow : Form
{
    private sealed record Mode(string Value, string Caption)
    {
        public override string ToString() => Caption;
    }

    private static readonly Mode[] Modes = [new("rule", L("Rule", "规则", "ルール")),
        new("global", L("Global", "全局", "グローバル")), new("direct", L("Direct", "直连", "直接接続"))];
    private readonly string cli;
    private readonly ComboBox node = Picker(), mode = Picker();
    private readonly Label profileLabel = Label(), engineLabel = Label(), ruleLabel = Label(), state = Label(), address = Label();
    private readonly TextBox digest = new() { Dock = DockStyle.Fill, MaxLength = 64, AccessibleName = "SHA-256" };
    private readonly Label engineNote = Label(L("Extract the Windows amd64-compatible package and select the .exe.",
        "解压 Windows amd64-compatible 包，再选择里面的 .exe。", "Windows amd64-compatible パッケージを展開して .exe を選んでください。"));
    private readonly Button openProfile = Button(L("Load nodes…", "加载节点…", "ノードを読み込む…"));
    private readonly Button subscriptions = Button(L("Subscriptions…", "订阅管理…", "購読の管理…"));
    private readonly Button openEngine = Button(L("Choose Mihomo…", "选择 Mihomo…", "Mihomo を選択…"));
    private readonly Button openRule = Button(L("Choose rules…", "选择规则…", "ルールを選択…"));
    private readonly Button clearRule = Button(L("Clear", "清除", "クリア"));
    private readonly Button previewRule = Button(L("Preview rules…", "预览规则…", "ルールを確認…"));
    private readonly Button start = Button(L("Start proxy", "启动代理", "プロキシを開始"));
    private readonly Button apply = Button(L("Apply", "应用切换", "適用"));
    private readonly Button stop = Button(L("Stop", "停止", "停止"));
    private readonly Button refresh = Button(L("Refresh status", "刷新状态", "状態を更新"));
    private readonly Button copy = Button(L("Copy address", "复制地址", "アドレスをコピー"));
    private readonly Button system = Button("");
    private readonly Label systemState = Label();

    private readonly NotifyIcon tray = new();
    private readonly ContextMenuStrip menu = new();
    private readonly ToolStripMenuItem trayStatus = new() { Enabled = false }, trayModes = new(L("Mode", "模式", "モード")),
        trayNodes = new(L("Nodes", "节点", "ノード")), trayStop = new(L("Stop proxy", "停止代理", "プロキシを停止")),
        trayExit = new(L("Quit CLAY", "退出 CLAY", "CLAY を終了"));
    private readonly ToolStripMenuItem traySystem = new();
    private readonly System.Windows.Forms.Timer heartbeat = new() { Interval = 500 };
    private readonly Icon idleIcon = MakeIcon(Color.FromArgb(111, 122, 140)), liveIcon = MakeIcon(Color.FromArgb(29, 146, 121)),
        uncertainIcon = MakeIcon(Color.FromArgb(215, 138, 44));

    private Inspection? profile;
    private SubscriptionManager.Selection? feed;
    private string? engine, rules;
    private PortableSession? session;
    private readonly WindowsPac? windowsPac;
    private string? systemNotice;
    private Route? confirmed;
    private bool busy, exiting, exitDetected;
    private int clockTicks;

    internal MainWindow(string cli)
    {
        this.cli = cli;
        try
        {
            windowsPac = WindowsPac.Open();
            if (windowsPac.Pending) ReportRelease(windowsPac.Release());
        }
        catch (PacRecoveryException) { systemNotice = RecoveryNeeded(); }
        catch { systemNotice = L("Windows proxy control unavailable; manual proxy still available.",
            "无法管理 Windows 代理；仍可使用手动代理。", "Windows プロキシを管理できません。手動設定は利用できます。"); }
        Text = "CLAY";
        Icon = idleIcon;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(680, 515);
        MinimumSize = new Size(645, 500);
        Font = new Font(SystemFonts.MessageBoxFont!.FontFamily, 10);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, AutoScroll = true, Padding = new Padding(20), ColumnCount = 1 };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        Controls.Add(layout);
        var heading = Label("CLAY");
        heading.Font = new Font(Font.FontFamily, 23, FontStyle.Bold);
        layout.Controls.Add(heading);
        layout.Controls.Add(Label(L("Local proxy · Windows preview", "本机代理 · Windows 预览", "ローカルプロキシ · Windows プレビュー")));
        layout.Controls.Add(Label(L("Start manually or connect apps that follow the Windows proxy. Closing the window keeps the session in the tray.",
            "可手动接入，也可连接采用 Windows 代理设置的应用。关闭窗口后，会话保留在托盘。",
            "手動設定または Windows プロキシ対応アプリに接続できます。閉じると接続はトレイに残ります。")));

        var files = Group(L("Session inputs", "会话配置", "セッション設定"));
        var inputs = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, ColumnCount = 3, Padding = new Padding(6) };
        inputs.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        inputs.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        inputs.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        inputs.Controls.Add(openProfile, 0, 0); inputs.Controls.Add(profileLabel, 1, 0); inputs.Controls.Add(subscriptions, 2, 0);
        var official = new LinkLabel { Text = L("Official v1.19.34", "官方 v1.19.34", "公式 v1.19.34"), AutoSize = true };
        official.LinkClicked += (_, _) =>
        {
            try { Process.Start(new ProcessStartInfo("https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.34") { UseShellExecute = true })?.Dispose(); }
            catch { engineNote.Text = L("Could not open the release page. See the Windows README.", "无法打开发布页，请查看 Windows README。",
                    "リリースページを開けませんでした。Windows README を確認してください。"); }
        };
        inputs.Controls.Add(openEngine, 0, 1); inputs.Controls.Add(engineLabel, 1, 1); inputs.Controls.Add(official, 2, 1);
        inputs.Controls.Add(Label("SHA-256"), 0, 2); inputs.Controls.Add(digest, 1, 2); inputs.SetColumnSpan(digest, 2);
        inputs.Controls.Add(engineNote, 1, 3); inputs.SetColumnSpan(engineNote, 2);
        inputs.Controls.Add(openRule, 0, 4); inputs.Controls.Add(ruleLabel, 1, 4); inputs.Controls.Add(Row(previewRule, clearRule), 2, 4);
        files.Controls.Add(inputs); layout.Controls.Add(files);

        var live = Group(L("Session", "当前会话", "セッション"));
        var pane = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, ColumnCount = 1, Padding = new Padding(6) };
        mode.Items.AddRange(Modes);
        mode.SelectedIndex = 0;
        node.AccessibleName = L("Node", "节点", "ノード");
        node.DisplayMember = nameof(Node.WindowCaption);
        node.Width = 230;
        node.DropDownWidth = 420;
        mode.AccessibleName = L("Routing mode", "路由模式", "ルーティングモード");
        pane.Controls.Add(Row(Label(node.AccessibleName), node, Label(mode.AccessibleName), mode));
        pane.Controls.Add(Row(start, system, apply, refresh, stop));
        state.AccessibleName = L("Session status", "会话状态", "接続状態");
        state.Font = new Font(Font, FontStyle.Bold);
        pane.Controls.Add(state); pane.Controls.Add(systemState); pane.Controls.Add(Row(address, copy));
        live.Controls.Add(pane); layout.Controls.Add(live);

        profileLabel.Text = None(); engineLabel.Text = None(); ruleLabel.Text = None();
        SetState(Stopped());
        openProfile.Click += async (_, _) => await LoadAsync();
        subscriptions.Click += (_, _) => ManageSubscriptions();
        openEngine.Click += async (_, _) => { if (Choose("Mihomo (*.exe)|*.exe") is { } path) await SelectEngineAsync(path); };
        openRule.Click += (_, _) => { if (Choose("Text files|*.txt;*.csv;*.list|All files|*.*") is { } path) { rules = path; ruleLabel.Text = Path.GetFileName(path); UpdateControls(); } };
        clearRule.Click += (_, _) => { rules = null; ruleLabel.Text = None(); UpdateControls(); };
        previewRule.Click += (_, _) => { if (rules is { } path) RulePreviewDialog.Show(this, cli, path); };
        digest.TextChanged += (_, _) => UpdateControls();
        start.Click += async (_, _) => await StartAsync();
        system.Click += async (_, _) => await ToggleWindowsAsync();
        apply.Click += async (_, _) => { if (node.SelectedItem is Node n && mode.SelectedItem is Mode m) await ChangeAsync(new(m.Value, n.Number)); };
        refresh.Click += async (_, _) => await WorkAsync(async () => SetConfirmed(await session!.RefreshAsync()));
        stop.Click += async (_, _) => await WorkAsync(StopAsync);
        copy.Click += (_, _) => { if (session is not null && confirmed is not null) { try { Clipboard.SetText(session.Address); } catch (ExternalException) { } } };

        menu.Items.Add(L("Open CLAY", "打开 CLAY", "CLAY を開く"), null, (_, _) => Reveal());
        menu.Items.AddRange([trayStatus, new ToolStripSeparator(), trayModes, trayNodes, traySystem, trayStop, trayExit]);
        traySystem.Click += async (_, _) => await ToggleWindowsAsync();
        trayStop.Click += async (_, _) => await WorkAsync(StopAsync);
        trayExit.Click += async (_, _) =>
        {
            if (busy) return;
            await WorkAsync(async () =>
            {
                try { await StopAsync(); }
                catch (PacRecoveryException) when (session is null && windowsPac?.Serving != true) { /* Keep the recovery record for next launch. */ }
                exiting = true;
            });
            if (exiting) Close();
        };
        tray.DoubleClick += (_, _) => Reveal();
        tray.ContextMenuStrip = menu;
        tray.Visible = true;
        heartbeat.Tick += async (_, _) =>
        {
            if (busy) return;
            if (!exitDetected && session?.Ended == true) await WorkAsync(async () =>
            {
                exitDetected = true;
                SetState(L("Proxy process ended", "代理进程已结束", "プロキシプロセスが終了しました"));
                await StopAsync();
                SetState(L("Proxy process ended", "代理进程已结束", "プロキシプロセスが終了しました"));
            });
            else if (++clockTicks % 4 == 0 && windowsPac?.Pending == true) UpdateWindowsControls();
        };
        heartbeat.Start();
        FormClosing += (_, e) =>
        {
            if (!exiting && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); return; }
            if (!exiting)
            {
                exiting = true;
                try { windowsPac?.Release(); }
                catch (PacRecoveryException) { /* Recover on the next launch if Windows is ending the session. */ }
            }
        };
        FormClosed += (_, _) =>
        {
            heartbeat.Dispose(); tray.Visible = false; tray.Dispose(); menu.Dispose();
            windowsPac?.Dispose();
            feed?.Dispose();
            idleIcon.Dispose(); liveIcon.Dispose(); uncertainIcon.Dispose();
        };
        UpdateControls();
    }

    internal static string L(string en, string zh, string ja) => CultureInfo.CurrentUICulture.TwoLetterISOLanguageName switch
    {
        "zh" => zh, "ja" => ja, _ => en
    };
    private static string None() => L("Not selected", "未选择", "未選択");
    private static string Stopped() => L("Stopped", "已停止", "停止中");
    private static string RecoveryNeeded() => L(
        "Windows proxy recovery needed. If the settings changed, remove CLAY’s script address in Windows Proxy settings and retry.",
        "Windows 代理待恢复。如果设置被改过，请在 Windows 代理设置中移除 CLAY 的脚本地址，然后重试。",
        "Windows プロキシの復元が必要です。設定が変更された場合は CLAY のスクリプト URL を削除して再試行してください。");

    private async Task LoadAsync()
    {
        if (Choose("Profiles|*.txt;*.yaml;*.yml;*.json|All files|*.*") is not { } path) return;
        await WorkAsync(async () =>
        {
            SetState(L("Reading local profile…", "正在读取本地配置…", "設定ファイルを読み込み中…"));
            var local = await PortableSession.InspectAsync(cli, path);
            SetProfile(local, null);
            SetState(Stopped());
        });
    }

    private void ManageSubscriptions()
    {
        if (busy || session is not null) return;
        busy = true; UpdateControls();
        try
        {
            using var dialog = new SubscriptionDialog(cli, SubscriptionStore.Open(), feed?.Entry.Id);
            var result = dialog.ShowDialog(this);
            if (result == DialogResult.OK && dialog.TakeSelection() is { } picked)
            {
                SetProfile(picked.Inspection, picked);
                SetState(Stopped());
            }
            else if (feed is not null && dialog.WasRemoved(feed.Entry.Id)) SetProfile(null, null);
        }
        catch { SetState(L("Could not open subscriptions.", "无法打开订阅管理。", "購読の管理を開けませんでした。")); }
        finally { busy = false; UpdateControls(); }
    }

    private void SetProfile(Inspection? inspected, SubscriptionManager.Selection? saved)
    {
        feed?.Dispose(); feed = saved;
        profile = inspected;
        node.Items.Clear();
        if (inspected is null) { profileLabel.Text = None(); return; }
        int count = inspected.Nodes.Count;
        profileLabel.Text = saved is null
            ? L($"Local file · {count} nodes", $"本地文件 · {count} 个节点", $"ローカルファイル · {count} 件")
            : L($"{saved.Entry.Name} · {count} cached nodes", $"{saved.Entry.Name} · {count} 个缓存节点", $"{saved.Entry.Name} · 保存済み {count} 件");
        node.Items.AddRange(inspected.Nodes.ToArray()); node.SelectedIndex = 0;
    }

    private async Task SelectEngineAsync(string path)
    {
        await WorkAsync(async () =>
        {
            engine = path;
            engineLabel.Text = Path.GetFileName(path);
            digest.ReadOnly = false;
            digest.Clear();
            engineNote.Text = L("Checking the selected executable…", "正在检查所选可执行文件…", "選択したファイルを確認中…");
            if (await EngineIdentity.RecognizesAsync(path))
            {
                digest.ReadOnly = true;
                digest.Text = EngineIdentity.OfficialSha256;
                engineNote.Text = L("Official Mihomo v1.19.34 · Windows x64 · Verified", "官方 Mihomo v1.19.34 · Windows x64 · 已校验",
                    "公式 Mihomo v1.19.34 · Windows x64 · 検証済み");
            }
            else engineNote.Text = L("For another build, enter the SHA-256 obtained from a trusted source.",
                "如使用其他构建，请填写从可信来源取得的 SHA-256。", "別のビルドには信頼できる提供元の SHA-256 を入力してください。");
            SetState(Stopped());
        });
    }

    private async Task StartAsync(bool connectWindows = false)
    {
        if (profile is null || engine is null || node.SelectedItem is not Node n || mode.SelectedItem is not Mode selected) return;
        await WorkAsync(async () =>
        {
            SetState(L("Verifying engine and starting…", "正在校验内核并启动…", "コアを検証して起動中…"));
            session = await PortableSession.StartAsync(cli, profile, engine, digest.Text.Trim(), rules, selected.Value, n.Number,
                feed is null ? default : feed.Source);
            exitDetected = false;
            SetConfirmed(new Route(selected.Value, n.Number));
            if (connectWindows) await EnableWindowsAsync();
        });
    }

    private async Task ToggleWindowsAsync()
    {
        if (busy || windowsPac is null) return;
        if (windowsPac.Pending) await WorkAsync(() => { ReportRelease(windowsPac.Release()); return Task.CompletedTask; });
        else if (session is null) await StartAsync(connectWindows: true);
        else if (confirmed is not null && !session.Ended) await WorkAsync(EnableWindowsAsync);
    }

    private async Task EnableWindowsAsync()
    {
        try
        {
            var script = await PortableSession.DefaultPacAsync(cli, session!.Address);
            if (exiting || session.Ended) return;
            windowsPac!.Enable(script);
            systemNotice = null;
        }
        catch (PacRecoveryException) { systemNotice = RecoveryNeeded(); }
        catch { systemNotice = L("Windows proxy was not enabled. Use the manual address or check Windows settings.",
            "未启用 Windows 代理。可以手动填写地址，或检查 Windows 代理设置。", "Windows プロキシを有効にできません。手動設定または Windows 設定を確認してください。"); }
    }

    private void ReportRelease(PacRelease result) => systemNotice = result switch
    {
        PacRelease.Restored => L("Original Windows proxy settings restored.", "已恢复原来的 Windows 代理设置。", "元の Windows プロキシ設定を復元しました。"),
        PacRelease.ExternalChange => L("The newer Windows proxy settings were preserved.", "已保留后来更改的 Windows 代理设置。", "変更後の Windows プロキシ設定を保持しました。"),
        _ => systemNotice
    };

    private async Task ChangeAsync(Route desired)
    {
        if (session is null) return;
        await WorkAsync(async () =>
        {
            SetState(L("Confirming routing change…", "正在确认路由切换…", "ルーティング変更を確認中…"));
            SetConfirmed(await session.ApplyAsync(desired));
        });
    }

    private async Task StopAsync()
    {
        if (windowsPac?.Pending == true) ReportRelease(windowsPac.Release());
        if (session is not null)
        {
            SetState(L("Stopping…", "正在停止…", "停止処理中…"));
            var active = session;
            session = null;
            await active.DisposeAsync();
        }
        SetState(Stopped());
    }

    private async Task WorkAsync(Func<Task> action)
    {
        if (busy) return;
        busy = true; UpdateControls();
        try { await action(); }
        catch (EngineMismatchException)
        {
            ResetVerifiedEngine();
            engineNote.Text = L("Mihomo does not match the expected SHA-256. Extract a fresh copy or choose a verified executable.",
                "Mihomo 的 SHA-256 与预期不符。请重新解压，或选择另一份已核验的可执行文件。",
                "Mihomo の SHA-256 が一致しません。再展開するか、確認済みの実行ファイルを選んでください。");
            SetState(engineNote.Text);
        }
        catch (EngineReadException)
        {
            ResetVerifiedEngine();
            engineNote.Text = L("Choose a readable, extracted Mihomo .exe.", "请选择可读取的、已解压的 Mihomo .exe。",
                "読み取り可能な展開済みの Mihomo .exe を選んでください。");
            SetState(engineNote.Text);
        }
        catch (ProfileChangedException) { SetState(L("Profile changed. Load nodes again.", "配置已变更，请重新加载节点。", "設定が変更されました。ノードを再読み込みしてください。")); }
        catch (PacRecoveryException) { systemNotice = RecoveryNeeded(); if (!Visible) Reveal(); }
        catch (SessionCleanupException) { ShowUnconfirmedCleanup(); }
        catch (OperationCanceledException)
        {
            try
            {
                await StopAsync();
                SetState(L("Session timed out and was closed", "会话超时，已关闭", "タイムアウトにより接続を終了しました"));
            }
            catch { ShowUnconfirmedCleanup(); }
        }
        catch
        {
            SetState(session is null ? L("Could not complete the operation. Check the input files and SHA-256.",
                "操作未完成。请检查输入文件和 SHA-256。", "処理を完了できません。入力ファイルと SHA-256 を確認してください。")
                : L("Status unconfirmed. Refresh or stop.", "状态未确认，请刷新或停止。", "状態を確認できません。更新または停止してください。"));
        }
        finally { busy = false; UpdateControls(); }
    }

    private void ShowUnconfirmedCleanup() => SetState(L("Session cleanup was not confirmed.", "未能确认会话已清理。", "セッションの後処理を確認できませんでした。"));

    private void ResetVerifiedEngine()
    {
        if (!digest.ReadOnly) return;
        digest.ReadOnly = false;
        digest.Clear();
    }

    private void SetConfirmed(Route route)
    {
        confirmed = route;
        node.SelectedItem = profile!.Nodes.First(n => n.Number == route.Node);
        var selected = Modes.First(m => m.Value == route.Mode);
        mode.SelectedItem = selected;
        state.Text = L("Local proxy ready", "本机代理已就绪", "ローカルプロキシを利用できます");
        address.Text = session!.Address;
        trayStatus.Text = $"{selected.Caption} · #{route.Node}";
        tray.Text = $"CLAY · {trayStatus.Text}";
        tray.Icon = liveIcon;
    }

    private void SetState(string message)
    {
        confirmed = null; state.Text = message; address.Text = "";
        trayStatus.Text = session is null ? Stopped() : L("Status unconfirmed", "状态未确认", "状態未確認");
        tray.Text = $"CLAY · {trayStatus.Text}";
        tray.Icon = session is null ? idleIcon : uncertainIcon;
    }

    private void UpdateControls()
    {
        var idle = !busy && session is null;
        openProfile.Enabled = subscriptions.Enabled = openEngine.Enabled = openRule.Enabled = digest.Enabled = idle;
        clearRule.Enabled = previewRule.Enabled = idle && rules is not null;
        start.Enabled = idle && profile is not null && engine is not null && EngineIdentity.HasFingerprint(digest.Text.Trim());
        var running = !busy && session is not null;
        node.Enabled = mode.Enabled = !busy && profile is not null;
        apply.Enabled = running; refresh.Enabled = stop.Enabled = trayStop.Enabled = running;
        copy.Enabled = running && confirmed is not null;
        trayExit.Enabled = !busy;
        UpdateWindowsControls();
        trayModes.Enabled = trayNodes.Enabled = running && confirmed is not null;
        ClearMenu(trayModes); ClearMenu(trayNodes);
        if (!trayModes.Enabled || confirmed is not { } current || profile is null) return;
        foreach (var item in Modes)
        {
            var entry = new ToolStripMenuItem(item.Caption) { Checked = item.Value == current.Mode };
            entry.Click += async (_, _) => await ChangeAsync(new Route(item.Value, current.Node));
            trayModes.DropDownItems.Add(entry);
        }
        foreach (var item in profile.Nodes.Where(n => n.Number <= 12 || n.Number == current.Node))
        {
            var entry = new ToolStripMenuItem(item.ToString()) { Checked = item.Number == current.Node };
            entry.Click += async (_, _) => await ChangeAsync(new Route(current.Mode, item.Number));
            trayNodes.DropDownItems.Add(entry);
        }
        if (profile.Nodes.Count > 12) trayNodes.DropDownItems.Add(L("All nodes…", "全部节点…", "すべてのノード…"), null, (_, _) => Reveal());
    }

    private void UpdateWindowsControls()
    {
        var pending = windowsPac?.Pending == true;
        var active = false;
        if (pending && !busy)
        {
            try { active = windowsPac!.Confirmed(); }
            catch { /* Readback is unknown, so keep the recovery control visible. */ }
        }
        system.Text = pending ? L("Restore Windows proxy", "恢复 Windows 代理设置", "Windows プロキシを復元")
            : session is null ? L("Connect Windows", "连接 Windows", "Windows に接続")
            : L("Use Windows proxy", "应用到 Windows", "Windows に適用");
        system.Enabled = !busy && windowsPac is not null && (pending || (session is null ? start.Enabled : confirmed is not null));
        traySystem.Text = system.Text;
        traySystem.Enabled = system.Enabled && (session is not null || pending);
        traySystem.Checked = active;
        systemState.Text = active ? L("Windows PAC configured for apps that follow system settings.",
                "已配置 Windows PAC，供采用系统代理设置的应用使用。", "システム設定を使用するアプリ向けの Windows PAC を設定しました。")
            : (pending && !busy ? RecoveryNeeded() : systemNotice ?? L("Manual · Windows settings unchanged", "手动接入 · 未启用 Windows 代理", "手動 · Windows プロキシ未設定"));
    }

    private static void ClearMenu(ToolStripMenuItem parent)
    {
        while (parent.DropDownItems.Count != 0)
        {
            var item = parent.DropDownItems[0];
            parent.DropDownItems.RemoveAt(0);
            item.Dispose();
        }
    }

    private void Reveal() { Show(); WindowState = FormWindowState.Normal; Activate(); }
    private string? Choose(string filter)
    {
        using var dialog = new OpenFileDialog { Filter = filter, CheckFileExists = true, RestoreDirectory = true };
        return dialog.ShowDialog(this) == DialogResult.OK ? dialog.FileName : null;
    }

    private static ComboBox Picker() => new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 150 };
    private static Label Label(string text = "") => new() { Text = text, AutoSize = true, Margin = new Padding(4, 7, 4, 5) };
    private static GroupBox Group(string text) => new() { Text = text, AutoSize = true, Dock = DockStyle.Top, Margin = new Padding(0, 10, 0, 0) };
    private static Button Button(string text) => new() { Text = text, AutoSize = true };
    private static FlowLayoutPanel Row(params Control[] controls)
    {
        var row = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill };
        row.Controls.AddRange(controls);
        return row;
    }

    private static Icon MakeIcon(Color color)
    {
        using var bitmap = new Bitmap(32, 32);
        using var graphics = Graphics.FromImage(bitmap);
        using var ring = new Pen(color, 5) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.DrawArc(ring, 6, 6, 20, 20, 46, 268);
        var handle = bitmap.GetHicon();
        try { using var icon = Icon.FromHandle(handle); return (Icon)icon.Clone(); }
        finally { DestroyIcon(handle); }
    }

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr icon);
}
