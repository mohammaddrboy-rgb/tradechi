"""Lightweight Facebook message templates (no Selenium)."""
import json
from pathlib import Path


def load_signal_data(signal_file):
    path = Path(signal_file)
    if not path.exists():
        raise FileNotFoundError(f"Signal file not found: {path}")
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def symbol_label(symbol, lang):
    """Return a human-readable symbol label per language."""
    labels = {
        "XAUUSD": {"English": "Gold", "Persian": "طلا", "Russian": "Золото"},
        "EURUSD": {"English": "Euro/Dollar", "Persian": "یورو/دلار", "Russian": "Евро/Доллар"},
        "GBPUSD": {"English": "Cable", "Persian": "پوند/دلار", "Russian": "Фунт/Доллар"},
        "USDJPY": {"English": "Dollar/Yen", "Persian": "دلار/ین", "Russian": "Доллар/Иена"},
        "USDCHF": {"English": "Dollar/Franc", "Persian": "دلار/فرانک", "Russian": "Доллар/Франк"},
        "AUDUSD": {"English": "Aussie", "Persian": "دلار استرالیا", "Russian": "Австралийский доллар"},
        "USDCAD": {"English": "Loonie", "Persian": "دلار کانادا", "Russian": "Канадский доллар"},
        "SILVER": {"English": "Silver", "Persian": "نقره", "Russian": "Серебро"},
        "XAGUSD":{"English": "Silver", "Persian": "نقره", "Russian": "Серебро"},
    }
    return labels.get(symbol.upper(), {}).get(lang, symbol)


def direction_label(direction, lang):
    labels = {
        "BUY":  {"English": "BUY 📈",  "Persian": "خرید (BUY) 📈", "Russian": "ПОКУПКА (BUY) 📈"},
        "SELL": {"English": "SELL 📉", "Persian": "فروش (SELL) 📉", "Russian": "ПРОДАЖА (SELL) 📉"},
    }
    return labels.get(direction.upper(), {}).get(lang, direction)


def build_templates(sig):
    """
    Build all 9 templates dynamically using live signal values.
    Templates use placeholders that are replaced with actual signal data.
    """
    sym   = sig["symbol"]
    dirn  = sig["direction"].upper()
    entry = sig["entry"]
    sl    = sig["sl"]
    tp1   = sig["tp1"]
    tp2   = sig.get("tp2", "—")
    tp3   = sig.get("tp3", "—")
    rr    = sig.get("rr", "1:3")
    basis = sig.get("basis", "Donchian Breakout · H1 Trend")
    zone  = sig.get("entry_zone", "")

    # Entry-zone line (band around the exact entry). Signals are read
    # minutes-to-hours after they fire, so the post gives an actionable
    # area plus a "don't chase" note rather than a single stale tick.
    def zline(lang):
        if not zone:
            return ""
        head = {"English": "🎯 Entry Zone", "Persian": "🎯 ناحیه ورود", "Russian": "🎯 Зона входа"}
        note = {
            "English": "⚠️ Enter within the zone — don't chase if price already hit TP.",
            "Persian": "⚠️ فقط داخل ناحیه ورود بگیر — اگر قیمت به تارگت رسیده، دنبالش نکن.",
            "Russian": "⚠️ Вход только внутри зоны — не догоняй, если цена уже дошла до TP.",
        }
        return f"{head[lang]}: {zone}\n{note[lang]}\n"

    # Follower guardrails, appended to every template: a spread sanity check
    # (the edge is thin; a wide spread erases it) and permission to bank
    # profit before TP (TP is a target, not a promise).
    def tips(lang):
        t = {
            "English": ("⚠️ Spread check: skip if your spread is over 5% of the stop size.\n"
                        "💡 TP is a target, not a promise — profit in hand beats profit on screen.\n"),
            "Persian": ("⚠️ چک اسپرد: اگر اسپرد بیشتر از ۵٪ اندازه استاپ است، این معامله را رها کن.\n"
                        "💡 TP هدف است، نه وعده — سودِ نقد بهتر از سودِ روی صفحه است.\n"),
            "Russian": ("⚠️ Проверь спред: если он больше 5% от стопа — пропусти сделку.\n"
                        "💡 TP — цель, а не обещание: прибыль в кармане лучше прибыли на экране.\n"),
        }
        return t[lang]

    # Build TP lines — skip if "—"
    def tp_lines_en(tp1, tp2, tp3):
        lines = f"✅ TP1: {tp1}\n"
        if tp2 != "—": lines += f"✅ TP2: {tp2}\n"
        if tp3 != "—": lines += f"✅ TP3: {tp3}\n"
        return lines

    def tp_lines_fa(tp1, tp2, tp3):
        lines = f"✅ TP1: {tp1}\n"
        if tp2 != "—": lines += f"✅ TP2: {tp2}\n"
        if tp3 != "—": lines += f"✅ TP3: {tp3}\n"
        return lines

    def tp_compact_en(tp2, tp3):
        if tp2 != "—" and tp3 != "—":
            return f"{tp2} / {tp3}"
        elif tp2 != "—":
            return tp2
        return tp1

    templates = {
        # ── ENGLISH ──────────────────────────────────────────────────────
        "English": {
            "1": (
                f"🟢 LIVE SIGNAL ALERT | {sym} ({symbol_label(sym, 'English')})\n\n"
                f"📈 Direction: {direction_label(dirn, 'English')}\n"
                f"🎯 Entry: {entry}\n"
                f"{zline('English')}"
                f"🛑 Stop Loss: {sl}\n"
                f"{tp_lines_en(tp1, tp2, tp3)}\n"
                f"{tips('English')}"
                f"⚡ Risk: 1% per trade\n"
                f"📊 Basis: {basis}\n\n"
                f"💬 DM me if you want to receive signals like this daily — FREE for a limited time.\n\n"
                f"#{sym} #ForexSignals #Breakout #Trend #PriceAction #Trading"
            ),
            "2": (
                f"This setup is too clean to ignore.\n\n"
                f"🟢 {sym} — {'BUY' if dirn == 'BUY' else 'SELL'} OPPORTUNITY\n\n"
                f"{'Price broke out ABOVE its recent H1 range, in the direction of the daily trend.' if dirn == 'BUY' else 'Price broke DOWN below its recent H1 range, in the direction of the daily trend.'} "
                f"Daily bias is {'bullish' if dirn == 'BUY' else 'bearish'}.\n\n"
                f"📍 Entry: {entry}\n"
                f"{zline('English')}"
                f"🛑 SL: {sl}\n"
                f"🎯 TP: {tp_compact_en(tp2, tp3)}\n\n"
                f"{tips('English')}"
                f"RR: {rr}\n\n"
                f"Want my signals before they go public? DM me.\n\n"
                f"#{sym} #ForexSignals #Breakout #Trend #PriceAction"
            ),
            "3": (
                f"Members in my Telegram channel get signals like this BEFORE I post publicly.\n\n"
                f"🟢 {sym} — {direction_label(dirn, 'English')}\n\n"
                f"📍 Entry: {entry}\n"
                f"{zline('English')}"
                f"🛑 SL: {sl}\n"
                f"🎯 TP1: {tp1}"
                + (f" | TP2: {tp2}" if tp2 != "—" else "")
                + (f" | TP3: {tp3}" if tp3 != "—" else "")
                + f"\n\nRR: {rr} | Basis: {basis}\n\n"
                f"{tips('English')}"
                f"Want early access? DM me — I'll send you the details.\n\n"
                f"#{sym} #ForexSignals #Breakout #Trend #Gold #Trading"
            ),
        },

        # ── PERSIAN ──────────────────────────────────────────────────────
        "Persian": {
            "1": (
                f"🟢 سیگنال زنده | {sym} ({symbol_label(sym, 'Persian')})\n\n"
                f"📈 جهت: {direction_label(dirn, 'Persian')}\n"
                f"🎯 ورود: {entry}\n"
                f"{zline('Persian')}"
                f"🛑 حد ضرر: {sl}\n"
                f"{tp_lines_fa(tp1, tp2, tp3)}\n"
                f"{tips('Persian')}"
                f"⚡ ریسک: ۱٪ از حساب\n"
                f"📊 بر اساس: {basis}\n\n"
                f"💬 اگر می‌خوای هر روز سیگنال دریافت کنی — الان بهم پیام بده. فعلاً رایگانه.\n\n"
                f"#{sym} #سیگنال_فارکس #Breakout #Trend #معامله‌گری"
            ),
            "2": (
                f"این ستاپ خیلی تمیزه — نمی‌تونم نشونش ندم.\n\n"
                f"🟢 {sym} — {'فرصت خرید' if dirn == 'BUY' else 'فرصت فروش'}\n\n"
                f"{'قیمت از سقف محدوده‌ی H1 خود در جهت روند روزانه شکست رو به بالا داد.' if dirn == 'BUY' else 'قیمت از کف محدوده‌ی H1 خود در جهت روند روزانه شکست رو به پایین داد.'} "
                f"بایاس روزانه {'صعودیه' if dirn == 'BUY' else 'نزولیه'}.\n\n"
                f"📍 ورود: {entry}\n"
                f"{zline('Persian')}"
                f"🛑 SL: {sl}\n"
                f"🎯 TP: {tp_compact_en(tp2, tp3)}\n\n"
                f"{tips('Persian')}"
                f"نسبت ریسک به ریوارد: {rr}\n\n"
                f"می‌خوای سیگنال‌هام رو زودتر دریافت کنی؟ بهم پیام بده.\n\n"
                f"#{sym} #سیگنال_فارکس #پرایس_اکشن #Breakout #Trend"
            ),
            "3": (
                f"اعضای کانال تلگرامم این سیگنال رو قبل از این پست دریافت کردن.\n\n"
                f"🟢 {sym} — {direction_label(dirn, 'Persian')}\n\n"
                f"📍 ورود: {entry}\n"
                f"{zline('Persian')}"
                f"🛑 SL: {sl}\n"
                f"🎯 TP1: {tp1}"
                + (f" | TP2: {tp2}" if tp2 != "—" else "")
                + (f" | TP3: {tp3}" if tp3 != "—" else "")
                + f"\n\nریوارد: {rr} | بر اساس: {basis}\n\n"
                f"{tips('Persian')}"
                f"می‌خوای زودتر دسترسی داشته باشی؟ بهم پیام بده.\n\n"
                f"#{sym} #سیگنال_فارکس #Breakout #Trend #طلا"
            ),
        },

        # ── RUSSIAN ──────────────────────────────────────────────────────
        "Russian": {
            "1": (
                f"🟢 ЖИВОЙ СИГНАЛ | {sym} ({symbol_label(sym, 'Russian')})\n\n"
                f"📈 Направление: {direction_label(dirn, 'Russian')}\n"
                f"🎯 Вход: {entry}\n"
                f"{zline('Russian')}"
                f"🛑 Стоп-лосс: {sl}\n"
                f"✅ TP1: {tp1}\n"
                + (f"✅ TP2: {tp2}\n" if tp2 != "—" else "")
                + (f"✅ TP3: {tp3}\n" if tp3 != "—" else "")
                + f"\n{tips('Russian')}⚡ Риск: 1% от депозита\n"
                f"📊 Основа: {basis}\n\n"
                f"💬 Напиши в личку, если хочешь получать такие сигналы каждый день — пока бесплатно.\n\n"
                f"#{sym} #СигналыФорекс #Breakout #Trend #Трейдинг"
            ),
            "2": (
                f"Этот сетап слишком чистый, чтобы молчать.\n\n"
                f"🟢 {sym} — {'возможность для покупки' if dirn == 'BUY' else 'возможность для продажи'}\n\n"
                f"{'Цена пробила ВВЕРХ свой недавний диапазон H1 в направлении дневного тренда.' if dirn == 'BUY' else 'Цена пробила ВНИЗ свой недавний диапазон H1 в направлении дневного тренда.'} "
                f"Дневной байас — {'бычий' if dirn == 'BUY' else 'медвежий'}.\n\n"
                f"📍 Вход: {entry}\n"
                f"{zline('Russian')}"
                f"🛑 SL: {sl}\n"
                f"🎯 TP: {tp_compact_en(tp2, tp3)}\n\n"
                f"{tips('Russian')}"
                f"Соотношение риск/прибыль: {rr}\n\n"
                f"Хочешь получать сигналы раньше? Напиши в личку.\n\n"
                f"#{sym} #СигналыФорекс #Breakout #Trend #PriceAction"
            ),
            "3": (
                f"Участники моего Telegram получили этот сигнал раньше этого поста.\n\n"
                f"🟢 {sym} — {direction_label(dirn, 'Russian')}\n\n"
                f"📍 Вход: {entry}\n"
                f"{zline('Russian')}"
                f"🛑 SL: {sl}\n"
                f"🎯 TP1: {tp1}"
                + (f" | TP2: {tp2}" if tp2 != "—" else "")
                + (f" | TP3: {tp3}" if tp3 != "—" else "")
                + f"\n\nRR: {rr} | Основа: {basis}\n\n"
                f"{tips('Russian')}"
                f"Хочешь ранний доступ? Напиши мне.\n\n"
                f"#{sym} #СигналыФорекс #Breakout #Trend #Золото"
            ),
        },
    }
    return templates
