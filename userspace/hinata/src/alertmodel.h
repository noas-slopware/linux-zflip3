// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <QAbstractListModel>
#include <QDateTime>
#include <QFileSystemWatcher>
#include <QQmlEngine>
#include <QVector>

/*
 * The cell broadcasts cellbroadcastd has stored, newest first. cellbroadcastd has
 * no signal for new ones; it rewrites its database file (atomically, by rename),
 * so its directory is watched (inotify) and the list read again when it changes.
 */
class AlertModel : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)

public:
    enum Role { TitleRole = Qt::UserRole + 1, TextRole, ChannelRole, SeverityRole, TimeRole, MessageCodeRole };
    Q_ENUM(Role)

    explicit AlertModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    QString error() const { return m_error; }
    bool loading() const { return m_loading; }

    Q_INVOKABLE void reload();

    struct Alert {
        QString title, text, severity;
        uint channel = 0, msgCode = 0;
        QDateTime time;
    };
    // for the GLib callback
    void setAlerts(QVector<Alert> alerts, const QString &error);

Q_SIGNALS:
    void errorChanged();
    void loadingChanged();

private:
    void watch();

    QVector<Alert> m_alerts;
    QString m_error;
    bool m_loading = false;
    bool m_reloadAgain = false;
    QFileSystemWatcher m_watcher;
    QString m_dir;
};
