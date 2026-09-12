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

    // ---- CRT effects + reflection ([UI] keys, p10) ------------------------
    // Same contract as the glass keys above, for the unified Effects system:
    // defaults, clamping at both ends, a save()/load() round trip through a
    // real kirc.conf, and the NOTIFY signals main.qml syncs on.
    {
        KircConfig cfg;
        check("defaults: every effect off, subtle amounts, reflection off at 25",
              cfg.scanlines() == false && cfg.scanlineAmount() == 35
                  && cfg.vignette() == false && cfg.vignetteAmount() == 30
                  && cfg.grain() == false && cfg.grainAmount() == 10
                  && cfg.flicker() == false && cfg.flickerAmount() == 4
                  && cfg.humBar() == false && cfg.humBarAmount() == 8
                  && cfg.reflection() == false && cfg.reflectionAmount() == 25,
              QStringLiteral("scanlines=%1/%2 refl=%3/%4")
                  .arg(cfg.scanlines()).arg(cfg.scanlineAmount())
                  .arg(cfg.reflection()).arg(cfg.reflectionAmount()));
    }

    {
        KircConfig cfg;
        cfg.setScanlineAmount(0);
        check("ScanlineAmount 0 clamps to 1", cfg.scanlineAmount() == 1,
              QString::number(cfg.scanlineAmount()));
        cfg.setScanlineAmount(101);
        check("ScanlineAmount 101 clamps to 100", cfg.scanlineAmount() == 100,
              QString::number(cfg.scanlineAmount()));
        cfg.setVignetteAmount(-7);
        check("VignetteAmount -7 clamps to 1", cfg.vignetteAmount() == 1,
              QString::number(cfg.vignetteAmount()));
        cfg.setGrainAmount(9999);
        check("GrainAmount 9999 clamps to 100", cfg.grainAmount() == 100,
              QString::number(cfg.grainAmount()));
        cfg.setFlickerAmount(0);
        check("FlickerAmount 0 clamps to 1", cfg.flickerAmount() == 1,
              QString::number(cfg.flickerAmount()));
        cfg.setHumBarAmount(4242);
        check("HumBarAmount 4242 clamps to 100", cfg.humBarAmount() == 100,
              QString::number(cfg.humBarAmount()));
        cfg.setReflectionAmount(0);
        check("ReflectionAmount 0 clamps to 1", cfg.reflectionAmount() == 1,
              QString::number(cfg.reflectionAmount()));
        cfg.setReflectionAmount(1000);
        check("ReflectionAmount 1000 clamps to 100", cfg.reflectionAmount() == 100,
              QString::number(cfg.reflectionAmount()));
    }

    {
        KircConfig cfg;
        int scanSignals = 0;
        int amountSignals = 0;
        int reflectionSignals = 0;
        QObject::connect(&cfg, &KircConfig::scanlinesChanged,
                         [&scanSignals]() { ++scanSignals; });
        QObject::connect(&cfg, &KircConfig::scanlineAmountChanged,
                         [&amountSignals]() { ++amountSignals; });
        QObject::connect(&cfg, &KircConfig::reflectionChanged,
                         [&reflectionSignals]() { ++reflectionSignals; });
        cfg.setScanlines(true);
        cfg.setScanlines(true);          // no change: no signal
        cfg.setScanlineAmount(0);        // clamps to 1: one signal
        cfg.setScanlineAmount(1);        // no change after clamping
        cfg.setReflection(true);
        cfg.setReflection(true);
        check("scanlinesChanged fires once per real change", scanSignals == 1,
              QString::number(scanSignals));
        check("scanlineAmountChanged fires once per real change", amountSignals == 1,
              QString::number(amountSignals));
        check("reflectionChanged fires once per real change", reflectionSignals == 1,
              QString::number(reflectionSignals));
    }

    {
        KircConfig save;
        save.setScanlines(true);
        save.setScanlineAmount(73);
        save.setVignette(true);
        save.setVignetteAmount(44);
        save.setGrain(true);
        save.setGrainAmount(55);
        save.setFlicker(true);
        save.setFlickerAmount(6);
        save.setHumBar(true);
        save.setHumBarAmount(9);
        save.setReflection(true);
        save.setReflectionAmount(66);
        save.save();

        QFile file(path);
        QString text;
        if (file.open(QIODevice::ReadOnly | QIODevice::Text)) {
            text = QString::fromUtf8(file.readAll());
        }
        check("kirc.conf carries the [UI] effect and reflection keys",
              text.contains(QLatin1String("Scanlines=true"))
                  && text.contains(QLatin1String("ScanlineAmount=73"))
                  && text.contains(QLatin1String("Vignette=true"))
                  && text.contains(QLatin1String("VignetteAmount=44"))
                  && text.contains(QLatin1String("Grain=true"))
                  && text.contains(QLatin1String("GrainAmount=55"))
                  && text.contains(QLatin1String("Flicker=true"))
                  && text.contains(QLatin1String("FlickerAmount=6"))
                  && text.contains(QLatin1String("HumBar=true"))
                  && text.contains(QLatin1String("HumBarAmount=9"))
                  && text.contains(QLatin1String("Reflection=true"))
                  && text.contains(QLatin1String("ReflectionAmount=66")));

        KircConfig load;
        load.load();
        check("load() round-trips every effect and reflection key",
              load.scanlines() == true && load.scanlineAmount() == 73
                  && load.vignette() == true && load.vignetteAmount() == 44
                  && load.grain() == true && load.grainAmount() == 55
                  && load.flicker() == true && load.flickerAmount() == 6
                  && load.humBar() == true && load.humBarAmount() == 9
                  && load.reflection() == true && load.reflectionAmount() == 66,
              QStringLiteral("scanlines=%1/%2 refl=%3/%4")
                  .arg(load.scanlines()).arg(load.scanlineAmount())
                  .arg(load.reflection()).arg(load.reflectionAmount()));
    }

    // ---- out-of-range effect amounts on disk clamp on load -----------------
    {
        QFile file(path);
        QString text;
        if (file.open(QIODevice::ReadOnly | QIODevice::Text)) {
            text = QString::fromUtf8(file.readAll());
            file.close();
        }
        text.replace(QLatin1String("ScanlineAmount=73"),
                     QLatin1String("ScanlineAmount=4242"));
        text.replace(QLatin1String("ReflectionAmount=66"),
                     QLatin1String("ReflectionAmount=-3"));
        if (file.open(QIODevice::WriteOnly | QIODevice::Text | QIODevice::Truncate)) {
            file.write(text.toUtf8());
        }
        file.close();

        KircConfig clamped;
        clamped.load();
        check("a hand-edited out-of-range ScanlineAmount clamps on load (4242 -> 100)",
              clamped.scanlineAmount() == 100, QString::number(clamped.scanlineAmount()));
        check("a hand-edited out-of-range ReflectionAmount clamps on load (-3 -> 1)",
              clamped.reflectionAmount() == 1, QString::number(clamped.reflectionAmount()));
    }

    // ---- save() always writes the clamped (in-range) value -----------------
    {
        KircConfig cfg;
        cfg.setScanlineAmount(1000);        // clamped to 100
        cfg.setReflectionAmount(0);         // clamped to 1
        cfg.save();
        QFile file(path);
        QString text;
        if (file.open(QIODevice::ReadOnly | QIODevice::Text)) {
            text = QString::fromUtf8(file.readAll());
        }
        check("save() never writes an out-of-range effect amount",
              text.contains(QLatin1String("ScanlineAmount=100"))
                  && text.contains(QLatin1String("ReflectionAmount=1")),
              QStringLiteral(""));
    }

    QTextStream(stdout) << (failures == 0 ? "GLASS-CONFIG-RESULT: ALL PASS"
                                          : QStringLiteral("GLASS-CONFIG-RESULT: %1 FAILURES").arg(failures))
                        << "\n";
    return failures == 0 ? 0 : 1;
}
