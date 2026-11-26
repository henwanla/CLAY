// Narrow KConfig bridge. Only these two entries may be updated, in one sync.
#include <KConfig>
#include <KConfigGroup>
#include <QCoreApplication>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#include <QStringList>
#include <cerrno>
#include <cstdio>
#include <sys/stat.h>
#include <unistd.h>

namespace {
const QString File = QStringLiteral("kioslaverc");
const QString Group = QStringLiteral("Proxy Settings");
const QStringList Keys{QStringLiteral("ProxyType"), QStringLiteral("Proxy Config Script")};
constexpr qint64 MaxConfig = 1024 * 1024;
constexpr qint64 MaxCommand = 128 * 1024;

bool normalLayout(const QString &path)
{
    struct stat info{};
    if (lstat(QFile::encodeName(path).constData(), &info) != 0) {
        return errno == ENOENT;
    }
    if (!S_ISREG(info.st_mode) || info.st_uid != getuid() || info.st_nlink != 1 || (info.st_mode & 0022) || info.st_size > MaxConfig) {
        return false;
    }
    QFile source(path);
    if (!source.open(QIODevice::ReadOnly)) {
        return false;
    }
    const auto content = source.read(MaxConfig + 1);
    if (content.size() > MaxConfig || !source.atEnd() || content.contains('\0')) {
        return false;
    }
    // libproxy looks for the exact names regardless of the group. Reject
    // duplicate or decorated managed entries instead of editing ambiguous data.
    bool inProxy = false;
    int groups = 0;
    int counts[2] = {0, 0};
    for (const auto &raw : content.split('\n')) {
        const auto line = raw.trimmed();
        if (line.startsWith('[')) {
            inProxy = line == "[Proxy Settings]";
            if (line.startsWith("[Proxy Settings]") && (!inProxy || ++groups > 1)) {
                return false;
            }
        } else if (line.contains('=') && !line.startsWith('#') && !line.startsWith(';')) {
            const auto key = line.left(line.indexOf('=')).trimmed();
            for (int i = 0; i < Keys.size(); ++i) {
                const auto name = Keys[i].toLatin1();
                if (key == name || key.startsWith(name + '[')) {
                    if (!inProxy || !raw.startsWith(name + '=') || ++counts[i] > 1) {
                        return false;
                    }
                }
            }
        }
    }
    return true;
}

QJsonArray entries(KConfig &config, const QJsonArray &defaults)
{
    const auto group = config.group(Group);
    QJsonArray result;
    for (int i = 0; i < Keys.size(); ++i) {
        if (!group.hasKey(Keys[i])) {
            result.append(defaults[i]);
        } else {
            result.append(group.readEntry(Keys[i], QString{}));
        }
    }
    return result;
}

QJsonObject snapshot(const QString &path, KConfig &effective)
{
    KConfig user(path, KConfig::SimpleConfig);
    return {{QStringLiteral("current"), entries(effective, {QStringLiteral("0"), QStringLiteral("")})},
            {QStringLiteral("user"), entries(user, {QJsonValue(), QJsonValue()})}};
}

bool changesValid(const QJsonArray &changes)
{
    if (changes.size() != 2) {
        return false;
    }
    const auto mode = changes[0];
    const auto url = changes[1];
    return (mode.isNull() || (mode.isString() && QStringList{QStringLiteral("0"), QStringLiteral("1"), QStringLiteral("2"),
                                                           QStringLiteral("3"), QStringLiteral("4")}.contains(mode.toString())))
        && (url.isNull() || (url.isString() && url.toString().size() <= 8192 && !url.toString().contains(QChar::Null)));
}
} // namespace

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    if (argc != 2) {
        return 2;
    }
    const QByteArray op(argv[1]);
    const auto path = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + QLatin1Char('/') + File;
    if (!normalLayout(path)) {
        return 3;
    }
    KConfig config(File, KConfig::NoGlobals);
    const auto before = snapshot(path, config);
    if (!changesValid(before.value(QStringLiteral("current")).toArray()) || !changesValid(before.value(QStringLiteral("user")).toArray())) {
        return 3;
    }
    if (op == "read") {
        const auto payload = QJsonDocument(before).toJson(QJsonDocument::Compact);
        return std::fwrite(payload.constData(), 1, payload.size(), stdout) == static_cast<size_t>(payload.size()) ? 0 : 4;
    }
    if (op != "write") {
        return 2;
    }
    QFile input;
    if (!input.open(stdin, QIODevice::ReadOnly)) {
        return 2;
    }
    const auto command = input.read(MaxCommand + 1);
    const auto data = QJsonDocument::fromJson(command).object();
    const auto next = data.value(QStringLiteral("next")).toArray();
    if (command.size() > MaxCommand || !changesValid(next) || !data.value(QStringLiteral("expected")).isObject()) {
        return 2;
    }
    config.reparseConfiguration();
    if (snapshot(path, config) != data.value(QStringLiteral("expected")).toObject() || !normalLayout(path)) {
        return 5;
    }
    auto group = config.group(Group);
    if (config.accessMode() != KConfig::ReadWrite || group.isImmutable()
        || group.isEntryImmutable(Keys[0]) || group.isEntryImmutable(Keys[1])) {
        return 6;
    }
    for (int i = 0; i < Keys.size(); ++i) {
        if (next[i].isNull()) {
            group.revertToDefault(Keys[i]);
        } else {
            group.writeEntry(Keys[i], next[i].toString());
        }
    }
    return config.sync() ? 0 : 4;
}
