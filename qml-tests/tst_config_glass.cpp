// SPDX-License-Identifier: MIT OR Apache-2.0
//
// tst_config_glass.cpp — the C++ half of the glass settings contract (p8).
//
// Proves what the QML harness cannot: KircConfig's [UI] Glass* keys are real
// KConfig keys — defaults, clamping at both ends, a save()/load() round trip
// through a real kirc.conf, and the NOTIFY signals the QML layer syncs on.
//
// Built and run by qml-tests/run.sh (stage "glass-config") with a throwaway
// XDG_CONFIG_HOME and no DBus session, so it never touches the user's own
// kirc.conf and never opens a wallet.
//
// Usage: XDG_CONFIG_HOME=<tmp> tst_config_glass
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTextStream>

#include "kircconfig.h"

namespace {

int failures = 0;

void check(const QString &name, bool cond, const QString &extra = QString())
{
    QTextStream out(stdout);
    out << (cond ? "PASS " : "FAIL ") << name;
    if (!extra.isEmpty()) {
        out << " :: " << extra;
    }
    out << "\n";
    out.flush();
    if (!cond) {
        ++failures;
    }
}

} // namespace

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);

    const QString path = KircConfig::configFilePath();

    // ---- defaults (a fresh install) ---------------------------------------
    {
        KircConfig cfg;
        check("defaults: glass on at 60 with frost/sheen/edges on",
              cfg.glassEffects() == true && cfg.glassIntensity() == 60
                  && cfg.glassBlur() == true && cfg.glassSheen() == true
                  && cfg.glassEdges() == true,
              QStringLiteral("on=%1 i=%2").arg(cfg.glassEffects()).arg(cfg.glassIntensity()));
    }

    // ---- intensity clamps at both ends ------------------------------------
    {
        KircConfig cfg;
        cfg.setGlassIntensity(0);
        check("intensity 0 clamps to 1", cfg.glassIntensity() == 1,
              QString::number(cfg.glassIntensity()));
        cfg.setGlassIntensity(-40);
        check("intensity -40 clamps to 1", cfg.glassIntensity() == 1,
              QString::number(cfg.glassIntensity()));
        cfg.setGlassIntensity(101);
        check("intensity 101 clamps to 100", cfg.glassIntensity() == 100,
              QString::number(cfg.glassIntensity()));
        cfg.setGlassIntensity(9999);
        check("intensity 9999 clamps to 100", cfg.glassIntensity() == 100,
              QString::number(cfg.glassIntensity()));
        cfg.setGlassIntensity(42);
        check("in-range intensity is kept (42)", cfg.glassIntensity() == 42,
              QString::number(cfg.glassIntensity()));
    }

    // ---- the NOTIFY signals the QML sync binds to --------------------------
    {
        KircConfig cfg;
        int effectsSignals = 0;
        int intensitySignals = 0;
        QObject::connect(&cfg, &KircConfig::glassEffectsChanged,
                         [&effectsSignals]() { ++effectsSignals; });
        QObject::connect(&cfg, &KircConfig::glassIntensityChanged,
                         [&intensitySignals]() { ++intensitySignals; });
        cfg.setGlassEffects(false);
        cfg.setGlassEffects(false);          // no change: no signal
        cfg.setGlassIntensity(0);            // clamps to 1: one signal
        cfg.setGlassIntensity(1);            // no change after clamping
        check("glassEffectsChanged fires once per real change", effectsSignals == 1,
              QString::number(effectsSignals));
        check("glassIntensityChanged fires once per real change", intensitySignals == 1,
              QString::number(intensitySignals));
    }

    // ---- save()/load() round trip through a real kirc.conf -----------------
    {
        KircConfig save;
        save.setGlassEffects(false);
        save.setGlassIntensity(73);
        save.setGlassBlur(false);
        save.setGlassSheen(false);
        save.setGlassEdges(false);
        save.save();
        check("save() wrote kirc.conf", QFileInfo::exists(path), path);

        QFile file(path);
        QString text;
        if (file.open(QIODevice::ReadOnly | QIODevice::Text)) {
            text = QString::fromUtf8(file.readAll());
        }
        check("kirc.conf carries the five [UI] Glass* keys",
              text.contains(QLatin1String("GlassEffects=false"))
                  && text.contains(QLatin1String("GlassIntensity=73"))
                  && text.contains(QLatin1String("GlassBlur=false"))
                  && text.contains(QLatin1String("GlassSheen=false"))
                  && text.contains(QLatin1String("GlassEdges=false")));

        KircConfig load;
        load.load();
        check("load() round-trips every glass key",
              load.glassEffects() == false && load.glassIntensity() == 73
                  && load.glassBlur() == false && load.glassSheen() == false
                  && load.glassEdges() == false,
              QStringLiteral("on=%1 i=%2").arg(load.glassEffects()).arg(load.glassIntensity()));
    }

    // ---- out-of-range value on disk clamps on load -------------------------
    {
        // Hand-edit the stored value the way a user could, then load.
        QFile file(path);
        QString text;
        if (file.open(QIODevice::ReadOnly | QIODevice::Text)) {
            text = QString::fromUtf8(file.readAll());
            file.close();   // reopen below: QFile::open() on an open handle fails
        }
        text.replace(QLatin1String("GlassIntensity=73"),
                     QLatin1String("GlassIntensity=4242"));
        if (file.open(QIODevice::WriteOnly | QIODevice::Text | QIODevice::Truncate)) {
            file.write(text.toUtf8());
        }
        file.close();

        KircConfig clamped;
        clamped.load();
        check("a hand-edited out-of-range GlassIntensity clamps on load (4242 -> 100)",
              clamped.glassIntensity() == 100, QString::number(clamped.glassIntensity()));
    }

    // ---- save() always writes the clamped (in-range) value ----------------
    {
        KircConfig cfg;
        cfg.setGlassIntensity(1000);        // clamped to 100
        cfg.save();
        QFile file(path);
        QString text;
        if (file.open(QIODevice::ReadOnly | QIODevice::Text)) {
            text = QString::fromUtf8(file.readAll());
        }
        check("save() never writes an out-of-range intensity",
              text.contains(QLatin1String("GlassIntensity=100")), QStringLiteral(""));
    }

    QTextStream(stdout) << (failures == 0 ? "GLASS-CONFIG-RESULT: ALL PASS"
                                          : QStringLiteral("GLASS-CONFIG-RESULT: %1 FAILURES").arg(failures))
                        << "\n";
    return failures == 0 ? 0 : 1;
}
