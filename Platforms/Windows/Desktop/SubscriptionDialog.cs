namespace Clay.Windows;

internal sealed class SubscriptionDialog : Form
{
    private sealed record Row(SubscriptionStore.Entry Entry)
    {
        public override string ToString() => Entry.Readable
            ? MainWindow.L($"{Entry.Name} · {Entry.Count} nodes", $"{Entry.Name} · {Entry.Count} 个节点", $"{Entry.Name} · {Entry.Count} 件")
            : MainWindow.L("Unreadable subscription", "无法读取的订阅", "読み込めない購読");
    }

    private readonly SubscriptionManager manager;
    private readonly SubscriptionStore store;
    private readonly ComboBox list = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill };
    private readonly TextBox name = new() { Dock = DockStyle.Fill, MaxLength = SubscriptionStore.MaxName };
    private readonly TextBox url = new() { Dock = DockStyle.Fill, MaxLength = SubscriptionDownload.MaxUrl, UseSystemPasswordChar = true };
    private readonly Label status = new() { AutoSize = true, MaximumSize = new Size(516, 0) };
    private readonly Button add = Button("Download and save", "下载并保存", "ダウンロードして保存"),
        refresh = Button("Refresh", "刷新", "更新"), use = Button("Use saved nodes", "使用缓存节点", "保存済みノードを使用"),
        remove = Button("Remove", "移除", "削除"), close = Button("Close", "关闭", "閉じる");
    private readonly HashSet<Guid> removed = [];
    private SubscriptionManager.Selection? chosen;
    private CancellationTokenSource? operation;
    private bool loaded;

    internal SubscriptionDialog(string cli, SubscriptionStore store, Guid? current)
    {
        this.store = store;
        manager = new SubscriptionManager(cli, store);
        Text = MainWindow.L("Subscriptions", "订阅管理", "購読の管理");
        StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MinimizeBox = MaximizeBox = ShowInTaskbar = false;
        Font = new Font(SystemFonts.MessageBoxFont!.FontFamily, 10);
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        var content = new TableLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Padding = new Padding(16), ColumnCount = 2, MinimumSize = new Size(550, 0), Dock = DockStyle.Fill };
        content.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        Controls.Add(content);
        AddWide(Label(MainWindow.L("Select saved nodes for the next session. Refresh only when you ask CLAY to.",
            "选择下次会话使用的缓存节点。CLAY 只在你主动操作时刷新。", "次の接続で使う保存済みノードを選択します。更新は手動です。")));
        AddField(MainWindow.L("Saved subscriptions", "已保存的订阅", "保存済みの購読"), list);
        AddWide(Buttons(use, refresh, remove));
        AddField(MainWindow.L("Name", "名称", "名前"), name);
        AddField(MainWindow.L("HTTPS address", "HTTPS 地址", "HTTPS アドレス"), url);
        AddWide(Buttons(add, close));
        AddWide(status);

        void AddWide(Control control) { content.Controls.Add(control); content.SetColumnSpan(control, 2); }
        void AddField(string caption, Control field) { content.Controls.Add(Label(caption)); field.AccessibleName = caption; content.Controls.Add(field); }

        list.SelectedIndexChanged += (_, _) => ButtonsEnabled();
        Shown += async (_, _) => await WorkAsync(async cancel => await ReloadAsync(current, cancel));
        add.Click += async (_, _) => await WorkAsync(async cancel =>
        {
            var saved = await manager.AddAsync(name.Text, url.Text, cancel);
            name.Clear(); url.Clear();
            await ReloadAsync(saved.Id, cancel);
            status.Text = Saved();
        });
        refresh.Click += async (_, _) =>
        {
            if (Current is not { Readable: true } entry) return;
            await WorkAsync(async cancel =>
            {
                await manager.RefreshAsync(entry.Id, cancel);
                await ReloadAsync(entry.Id, cancel);
                status.Text = Saved();
            });
        };
        use.Click += async (_, _) =>
        {
            if (Current is not { Readable: true } entry) return;
            await WorkAsync(async cancel =>
            {
                chosen = await manager.SelectAsync(entry.Id, cancel);
            });
            if (chosen is not null) DialogResult = DialogResult.OK;
        };
        remove.Click += async (_, _) =>
        {
            if (Current is not { } entry || MessageBox.Show(this,
                    MainWindow.L("Remove this subscription and its cached nodes?", "移除此订阅及其节点缓存？", "この購読と保存済みノードを削除しますか？"),
                    Text, MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
            await WorkAsync(async cancel =>
            {
                await Task.Run(() => store.Remove(entry.Id), cancel);
                removed.Add(entry.Id);
                await ReloadAsync(null, cancel);
                status.Text = MainWindow.L("Subscription removed.", "已移除订阅。", "購読を削除しました。");
            });
        };
        close.Click += (_, _) => Close();
        FormClosing += (_, e) =>
        {
            if (operation is null || e.CloseReason == CloseReason.WindowsShutDown) return;
            e.Cancel = true;
            operation.Cancel();
        };
        FormClosed += (_, _) => url.Clear();
        ButtonsEnabled();
    }

    internal bool WasRemoved(Guid id) => removed.Contains(id);
    internal SubscriptionManager.Selection? TakeSelection() { var result = chosen; chosen = null; return result; }
    protected override void Dispose(bool disposing)
    {
        if (disposing) { operation?.Cancel(); chosen?.Dispose(); chosen = null; }
        base.Dispose(disposing);
    }

    private SubscriptionStore.Entry? Current => (list.SelectedItem as Row)?.Entry;

    private async Task ReloadAsync(Guid? selected, CancellationToken cancel)
    {
        var entries = await Task.Run(store.List, cancel);
        cancel.ThrowIfCancellationRequested();
        list.Items.Clear();
        int index = 0;
        foreach (var entry in entries)
        {
            if (entry.Id == selected) index = list.Items.Count;
            list.Items.Add(new Row(entry));
        }
        if (entries.Count > 0) list.SelectedIndex = index;
        loaded = true;
    }

    private async Task WorkAsync(Func<CancellationToken, Task> action)
    {
        if (operation is not null || IsDisposed) return;
        using var cancel = new CancellationTokenSource();
        operation = cancel; ButtonsEnabled();
        status.Text = MainWindow.L("Working…", "处理中…", "処理中…");
        try { await action(cancel.Token); if (!IsDisposed && status.Text == MainWindow.L("Working…", "处理中…", "処理中…")) status.Text = ""; }
        catch (OperationCanceledException) { if (!IsDisposed) status.Text = MainWindow.L("Canceled.", "已取消。", "キャンセルしました。"); }
        catch (SubscriptionException error) { if (!IsDisposed) status.Text = Message(error.Reason); }
        catch (ArgumentException) { if (!IsDisposed) status.Text = Message(SubscriptionFailure.Address); }
        catch { if (!IsDisposed) status.Text = MainWindow.L("Could not use private subscription storage or the local parser.",
            "无法使用订阅私有存储或本地解析器。", "購読の保管領域またはローカル解析機能を利用できません。"); }
        finally { operation = null; if (!IsDisposed) ButtonsEnabled(); }
    }

    private void ButtonsEnabled()
    {
        bool idle = loaded && operation is null;
        list.Enabled = idle && list.Items.Count > 0;
        name.Enabled = url.Enabled = add.Enabled = idle && list.Items.Count < SubscriptionStore.Limit;
        use.Enabled = refresh.Enabled = idle && Current is { Readable: true };
        remove.Enabled = idle && Current is not null;
        close.Text = operation is null ? MainWindow.L("Close", "关闭", "閉じる") : MainWindow.L("Cancel operation", "取消操作", "処理を中止");
    }

    private static string Saved() => MainWindow.L("Saved. Select ‘Use saved nodes’ to load this version.",
        "已保存。点击「使用缓存节点」加载此版本。", "保存しました。「保存済みノードを使用」で反映します。");

    private static string Message(SubscriptionFailure reason) => reason switch
    {
        SubscriptionFailure.Address => MainWindow.L("Enter a name and a valid HTTPS address.", "请输入名称和有效的 HTTPS 地址。", "名前と有効な HTTPS アドレスを入力してください。"),
        SubscriptionFailure.Redirect => MainWindow.L("The subscription redirected to a different origin or exceeded the redirect limit.",
            "订阅跳转到了其他源，或跳转次数超出限制。", "別のオリジンへの転送、または転送回数の超過です。"),
        SubscriptionFailure.Size => MainWindow.L("The subscription exceeded 2 MiB.", "订阅超过 2 MiB。", "購読が 2 MiB を超えています。"),
        SubscriptionFailure.Content => MainWindow.L("No usable nodes were found in the response.", "下载内容没有可用节点。", "利用可能なノードが見つかりませんでした。"),
        _ => MainWindow.L("Could not download the subscription. Check the address and connection.",
            "无法下载订阅。请检查地址和网络。", "購読を取得できません。アドレスと接続を確認してください。")
    };

    private static Label Label(string text) => new() { Text = text, AutoSize = true, MaximumSize = new Size(516, 0), Margin = new Padding(3, 8, 3, 6) };
    private static Button Button(string en, string zh, string ja) => new() { AutoSize = true, Text = MainWindow.L(en, zh, ja) };
    private static FlowLayoutPanel Buttons(params Button[] buttons)
    {
        var row = new FlowLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = false };
        row.Controls.AddRange(buttons);
        return row;
    }
}
