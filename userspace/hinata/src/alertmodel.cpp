// SPDX-License-Identifier: GPL-3.0-or-later
#include "alertmodel.h"

#include <QDir>
#include <QPointer>
#include <algorithm>

extern "C" {
#include <gio/gio.h>
#include <libcellbroadcast.h>
}

static QString severityKey(LcbSeverityLevel level)
{
    switch (level) {
    case LCB_SEVERITY_LEVEL_PRESIDENTIAL:
        return QStringLiteral("presidential");
    case LCB_SEVERITY_LEVEL_EXTREME:
        return QStringLiteral("extreme");
    case LCB_SEVERITY_LEVEL_SEVERE:
        return QStringLiteral("severe");
    case LCB_SEVERITY_LEVEL_PUBLIC_SAFETY:
        return QStringLiteral("public-safety");
    case LCB_SEVERITY_LEVEL_AMBER:
        return QStringLiteral("amber");
    case LCB_SEVERITY_LEVEL_TEST:
        return QStringLiteral("test");
    default:
        return QStringLiteral("unknown");
    }
}

AlertModel::AlertModel(QObject *parent)
    : QAbstractListModel(parent)
    , m_dir(QDir(QString::fromUtf8(g_get_user_data_dir())).filePath(QStringLiteral("cellbroadcastd")))
{
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, &AlertModel::reload);
    watch();
    reload();
}

void AlertModel::watch()
{
    // the directory appears with cellbroadcastd's first message; until then, its parent
    if (QDir(m_dir).exists()) {
        if (!m_watcher.directories().contains(m_dir)) {
            if (!m_watcher.directories().isEmpty())
                m_watcher.removePaths(m_watcher.directories());
            m_watcher.addPath(m_dir);
        }
    } else if (m_watcher.directories().isEmpty()) {
        m_watcher.addPath(QString::fromUtf8(g_get_user_data_dir()));
    }
}

int AlertModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_alerts.size();
}

QVariant AlertModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() >= m_alerts.size())
        return {};
    const Alert &a = m_alerts.at(index.row());
    switch (role) {
    case TitleRole:
        return a.title;
    case TextRole:
        return a.text;
    case ChannelRole:
        return a.channel;
    case SeverityRole:
        return a.severity;
    case TimeRole:
        return a.time;
    case MessageCodeRole:
        return a.msgCode;
    }
    return {};
}

QHash<int, QByteArray> AlertModel::roleNames() const
{
    return {{TitleRole, "title"}, {TextRole, "body"}, {ChannelRole, "channel"},
            {SeverityRole, "severity"}, {TimeRole, "time"}, {MessageCodeRole, "messageCode"}};
}

static bool isNoDatabase(GError *err)
{
    if (!err || !g_dbus_error_is_remote_error(err))
        return false;
    gchar *name = g_dbus_error_get_remote_error(err);
    const bool noent = name && g_str_has_suffix(name, "_g_2dfile_2derror_2dquark.Code4");
    g_free(name);
    return noent;
}

static void messagesReady(GObject *, GAsyncResult *res, gpointer user_data)
{
    auto *guard = static_cast<QPointer<AlertModel> *>(user_data);
    GError *err = nullptr;
    GListModel *list = lcb_cbd_get_messages_finish(res, &err);
    QVector<AlertModel::Alert> alerts;
    QString error;

    if (list) {
        const guint n = g_list_model_get_n_items(list);
        for (guint i = 0; i < n; i++) {
            auto *msg = static_cast<LcbMessage *>(g_list_model_get_item(list, i));
            AlertModel::Alert a;
            a.title = QString::fromUtf8(lcb_message_get_severity_subject(msg));
            a.text = QString::fromUtf8(lcb_message_get_text(msg));
            a.channel = lcb_message_get_channel(msg);
            a.msgCode = lcb_message_get_msg_code(msg);
            a.severity = severityKey(lcb_message_get_severity(msg));
            a.time = QDateTime::fromSecsSinceEpoch(lcb_message_get_timestamp(msg));
            if (a.title.isEmpty())
                a.title = QStringLiteral("Cell broadcast");
            alerts.append(a);
            g_object_unref(msg);
        }
        g_object_unref(list);
    } else if (isNoDatabase(err)) {
        // G_FILE_ERROR_NOENT: cellbroadcastd has no database until its first message
        g_clear_error(&err);
    } else {
        error = QString::fromUtf8(err ? err->message : "unknown error");
        g_clear_error(&err);
    }
    if (*guard)
        (*guard)->setAlerts(std::move(alerts), error);
    delete guard;
}

void AlertModel::reload()
{
    watch();
    if (m_loading) {
        m_reloadAgain = true; // the database changed while reading it
        return;
    }
    GError *err = nullptr;
    if (!lcb_is_initted() && !lcb_init(&err)) {
        m_error = QString::fromUtf8(err ? err->message : "cellbroadcastd is not reachable");
        g_clear_error(&err);
        Q_EMIT errorChanged();
        return;
    }
    m_loading = true;
    Q_EMIT loadingChanged();
    lcb_cbd_get_messages(nullptr, messagesReady, new QPointer<AlertModel>(this));
}

void AlertModel::setAlerts(QVector<Alert> alerts, const QString &error)
{
    std::sort(alerts.begin(), alerts.end(), [](const Alert &a, const Alert &b) { return a.time > b.time; });
    beginResetModel();
    m_alerts = std::move(alerts);
    endResetModel();
    if (m_error != error) {
        m_error = error;
        Q_EMIT errorChanged();
    }
    m_loading = false;
    Q_EMIT loadingChanged();
    if (m_reloadAgain) {
        m_reloadAgain = false;
        reload();
    }
}
