using System.Drawing.Drawing2D;
using System.Globalization;
using System.Runtime.InteropServices;

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
    private readonly Button openProfile = Button(L("Load nodes…", "加载节点…", "ノードを読み込む…"));
    private readonly Button openEngine = Button(L("Choose Mihomo…", "选择 Mihomo…", "Mihomo を選択…"));
    private readonly Button openRule = Button(L("Choose rules…", "选择规则…", "ルールを選択…"));
    private readonly Button clearRule = Button(L("Clear", "清除", "クリア"));
    private readonly Button start = Button(L("Start proxy", "启动代理", "プロキシを開始"));
    private readonly Button apply = Button(L("Apply", "应用切换", "適用"));
    private readonly Button stop = Button(L("Stop", "停止", "停止"));
    private readonly Button refresh = Button(L("Refresh status", "刷新状态", "状態を更新"));
    private readonly Button copy = Button(L("Copy address", "复制地址", "アドレスをコピー"));

    private readonly NotifyIcon tray = new();
    private readonly ContextMenuStrip menu = new();
    private readonly ToolStripMenuItem trayStatus = new() { Enabled = false }, trayModes = new(L("Mode", "模式", "モード")),
        trayNodes = new(L("Nodes", "节点", "ノード")), trayStop = new(L("Stop proxy", "停止代理", "プロキシを停止")),
        trayExit = new(L("Quit CLAY", "退出 CLAY", "CLAY を終了"));
    private readonly System.Windows.Forms.Timer heartbeat = new() { Interval = 500 };
    private readonly Icon idleIcon = MakeIcon(Color.FromArgb(111, 122, 140)), liveIcon = MakeIcon(Color.FromArgb(29, 146, 121)),
        uncertainIcon = MakeIcon(Color.FromArgb(215, 138, 44));

    private Inspection? profile;
    private string? engine, rules;
    private PortableSession? session;
    private Route? confirmed;
    private bool busy, exiting;

    internal MainWindow(string cli)
    {
        this.cli = cli;
        Text = "CLAY";
        Icon = idleIcon;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(650, 465);
        MinimumSize = new Size(625, 475);
        Font = new Font(SystemFonts.MessageBoxFont!.FontFamily, 10);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, AutoScroll = true, Padding = new Padding(20), ColumnCount = 1 };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        Controls.Add(layout);
        var heading = Label("CLAY");
        heading.Font = new Font(Font.FontFamily, 23, FontStyle.Bold);
        layout.Controls.Add(heading);
        layout.Controls.Add(Label(L("Local proxy · Windows preview", "本机代理 · Windows 预览", "ローカルプロキシ · Windows プレビュー")));
        layout.Controls.Add(Label(L("Set the proxy address in each client app. Closing this window keeps the session in the tray.",
            "请在需要代理的应用中手动填写地址。关闭窗口后，会话保留在状态栏。",
            "各アプリでプロキシを設定します。ウィンドウを閉じてもトレイで接続を維持します。")));

        var files = Group(L("Session inputs", "会话配置", "セッション設定"));
        var inputs = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, ColumnCount = 3, Padding = new Padding(6) };
        inputs.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        inputs.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        inputs.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        inputs.Controls.Add(openProfile, 0, 0); inputs.Controls.Add(profileLabel, 1, 0); inputs.SetColumnSpan(profileLabel, 2);
        inputs.Controls.Add(openEngine, 0, 1); inputs.Controls.Add(engineLabel, 1, 1); inputs.SetColumnSpan(engineLabel, 2);
        inputs.Controls.Add(Label("SHA-256"), 0, 2); inputs.Controls.Add(digest, 1, 2); inputs.SetColumnSpan(digest, 2);
        inputs.Controls.Add(openRule, 0, 3); inputs.Controls.Add(ruleLabel, 1, 3); inputs.Controls.Add(clearRule, 2, 3);
        files.Controls.Add(inputs); layout.Controls.Add(files);

        var live = Group(L("Session", "当前会话", "セッション"));
        var pane = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, ColumnCount = 1, Padding = new Padding(6) };
        mode.Items.AddRange(Modes);
        mode.SelectedIndex = 0;
        node.AccessibleName = L("Node", "节点", "ノード");
        mode.AccessibleName = L("Routing mode", "路由模式", "ルーティングモード");
        pane.Controls.Add(Row(Label(node.AccessibleName), node, Label(mode.AccessibleName), mode));
        pane.Controls.Add(Row(start, apply, refresh, stop));
        state.AccessibleName = L("Session status", "会话状态", "接続状態");
        state.Font = new Font(Font, FontStyle.Bold);
        pane.Controls.Add(state); pane.Controls.Add(Row(address, copy));
        live.Controls.Add(pane); layout.Controls.Add(live);

        profileLabel.Text = None(); engineLabel.Text = None(); ruleLabel.Text = None();
        SetState(Stopped());
        openProfile.Click += async (_, _) => await LoadAsync();
        openEngine.Click += (_, _) => { if (Choose("Mihomo (*.exe)|*.exe") is { } path) { engine = path; engineLabel.Text = Path.GetFileName(path); digest.Clear(); UpdateControls(); } };
        openRule.Click += (_, _) => { if (Choose("Text files|*.txt;*.csv;*.list|All files|*.*") is { } path) { rules = path; ruleLabel.Text = Path.GetFileName(path); UpdateControls(); } };
        clearRule.Click += (_, _) => { rules = null; ruleLabel.Text = None(); UpdateControls(); };
        digest.TextChanged += (_, _) => UpdateControls();
        start.Click += async (_, _) => await StartAsync();
        apply.Click += async (_, _) => { if (node.SelectedItem is Node n && mode.SelectedItem is Mode m) await ChangeAsync(new(m.Value, n.Number)); };
        refresh.Click += async (_, _) => await WorkAsync(async () => SetConfirmed(await session!.RefreshAsync()));
        stop.Click += async (_, _) => await WorkAsync(StopAsync);
        copy.Click += (_, _) => { if (session is not null && confirmed is not null) { try { Clipboard.SetText(session.Address); } catch (ExternalException) { } } };

        menu.Items.Add(L("Open CLAY", "打开 CLAY", "CLAY を開く"), null, (_, _) => Reveal());
        menu.Items.AddRange([trayStatus, new ToolStripSeparator(), trayModes, trayNodes, trayStop, trayExit]);
        trayStop.Click += async (_, _) => await WorkAsync(StopAsync);
        trayExit.Click += async (_, _) => { if (busy) return; await WorkAsync(StopAsync); if (session is null) { exiting = true; Close(); } };
        tray.DoubleClick += (_, _) => Reveal();
        tray.ContextMenuStrip = menu;
        tray.Visible = true;
        heartbeat.Tick += async (_, _) =>
        {
            if (!busy && session?.Ended == true) await WorkAsync(async () =>
            {
                await StopAsync();
                SetState(L("Proxy process ended", "代理进程已结束", "プロキシプロセスが終了しました"));
            });
        };
        heartbeat.Start();
        FormClosing += (_, e) =>
        {
            if (!exiting && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); }
        };
        FormClosed += (_, _) =>
        {
            heartbeat.Dispose(); tray.Visible = false; tray.Dispose(); menu.Dispose();
            idleIcon.Dispose(); liveIcon.Dispose(); uncertainIcon.Dispose();
        };
        UpdateControls();
    }

    private static string L(string en, string zh, string ja) => CultureInfo.CurrentUICulture.TwoLetterISOLanguageName switch
    {
        "zh" => zh, "ja" => ja, _ => en
    };
    private static string None() => L("Not selected", "未选择", "未選択");
    private static string Stopped() => L("Stopped", "已停止", "停止中");

    private async Task LoadAsync()
    {
        if (Choose("Profiles|*.txt;*.yaml;*.yml;*.json|All files|*.*") is not { } path) return;
        await WorkAsync(async () =>
        {
            profile = null; node.Items.Clear(); profileLabel.Text = None();
            SetState(L("Reading local profile…", "正在读取本地配置…", "設定ファイルを読み込み中…"));
            profile = await PortableSession.InspectAsync(cli, path);
            profileLabel.Text = L($"{profile.Nodes.Count} supported nodes", $"{profile.Nodes.Count} 个兼容节点", $"対応ノード {profile.Nodes.Count} 件");
            node.Items.AddRange(profile.Nodes.ToArray()); node.SelectedIndex = 0;
            SetState(Stopped());
        });
    }

    private async Task StartAsync()
    {
        if (profile is null || engine is null || node.SelectedItem is not Node n || mode.SelectedItem is not Mode selected) return;
        await WorkAsync(async () =>
        {
            SetState(L("Verifying engine and starting…", "正在校验内核并启动…", "コアを検証して起動中…"));
            session = await PortableSession.StartAsync(cli, profile, engine, digest.Text.Trim(), rules, selected.Value, n.Number);
            SetConfirmed(new Route(selected.Value, n.Number));
        });
    }

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
        catch (ProfileChangedException) { SetState(L("Profile changed. Load nodes again.", "配置已变更，请重新加载节点。", "設定が変更されました。ノードを再読み込みしてください。")); }
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
        openProfile.Enabled = openEngine.Enabled = openRule.Enabled = digest.Enabled = idle;
        clearRule.Enabled = idle && rules is not null;
        start.Enabled = idle && profile is not null && engine is not null && digest.Text.Trim().Length == 64;
        var running = !busy && session is not null;
        node.Enabled = mode.Enabled = !busy && profile is not null;
        apply.Enabled = running; refresh.Enabled = stop.Enabled = trayStop.Enabled = running;
        copy.Enabled = running && confirmed is not null;
        trayExit.Enabled = !busy;
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
