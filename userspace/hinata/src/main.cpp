// SPDX-License-Identifier: GPL-3.0-or-later
#include <QGuiApplication>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QTimer>

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    QGuiApplication::setApplicationName(QStringLiteral("hinata"));
    QGuiApplication::setApplicationDisplayName(QStringLiteral("Hinata"));
    QGuiApplication::setDesktopFileName(QStringLiteral("codes.noa.Hinata"));
    QGuiApplication::setWindowIcon(QIcon::fromTheme(QStringLiteral("dialog-warning")));
    if (qEnvironmentVariableIsEmpty("QT_QUICK_CONTROLS_STYLE"))
        QQuickStyle::setStyle(QStringLiteral("org.kde.desktop"));

    QQmlApplicationEngine engine;
    engine.loadFromModule("codes.noa.hinata", "Main");
    if (engine.rootObjects().isEmpty())
        return 1;

    // HINATA_SCREENSHOT=<png>: grab the window once it has drawn, then quit (tests)
    const QString shot = qEnvironmentVariable("HINATA_SCREENSHOT");
    if (!shot.isEmpty()) {
        auto *win = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
        QTimer::singleShot(qEnvironmentVariableIntValue("HINATA_SCREENSHOT_DELAY_MS") ?: 2000, win, [win, shot] {
            win->grabWindow().save(shot);
            QCoreApplication::quit();
        });
    }
    return app.exec();
}
