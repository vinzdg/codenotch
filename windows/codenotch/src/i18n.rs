//! Rust-side (tray menu) strings. The page has its own dictionary; keys are kept identical on both sides.

pub fn resolve_auto() -> &'static str {
    #[cfg(windows)]
    unsafe {
        use windows::Win32::Globalization::GetUserDefaultLocaleName;
        let mut buf = [0u16; 85];
        let n = GetUserDefaultLocaleName(&mut buf);
        if n > 0 {
            let name = String::from_utf16_lossy(&buf[..(n as usize - 1)]).to_lowercase();
            if name.starts_with("zh") {
                return "zh";
            }
            if name.starts_with("ja") {
                return "ja";
            }
            if name.starts_with("ko") {
                return "ko";
            }
            if name.starts_with("ru") {
                return "ru";
            }
            if name.starts_with("uk") {
                return "uk";
            }
        }
    }
    "en"
}

/// Whether the region settings write times on a 24-hour clock. The page can't tell: WebView2's
/// locale follows the browser language, not the regional format.
pub fn clock_24h() -> bool {
    time_format().is_some_and(|pattern| is_24h_pattern(&pattern))
}

fn time_format() -> Option<String> {
    #[cfg(windows)]
    unsafe {
        use windows::core::PCWSTR;
        use windows::Win32::Globalization::{GetLocaleInfoEx, LOCALE_SSHORTTIME, LOCALE_STIMEFORMAT};
        // The taskbar clock shows the short time, or the long time once it shows seconds; the two are set separately
        let kind = if taskbar_shows_seconds() { LOCALE_STIMEFORMAT } else { LOCALE_SSHORTTIME };
        let mut buf = [0u16; 80];
        let n = GetLocaleInfoEx(PCWSTR::null(), kind, Some(&mut buf));
        if n > 0 {
            return Some(String::from_utf16_lossy(&buf[..(n as usize - 1)]));
        }
    }
    None
}

#[cfg(windows)]
fn taskbar_shows_seconds() -> bool {
    use windows::core::w;
    use windows::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_DWORD};
    let mut value = 0u32;
    let mut size = std::mem::size_of::<u32>() as u32;
    let status = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            w!("Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced"),
            w!("ShowSecondsInSystemClock"),
            RRF_RT_REG_DWORD,
            None,
            Some((&mut value as *mut u32).cast()),
            Some(&mut size),
        )
    };
    status.is_ok() && value != 0
}

/// "HH:mm" against "hh:mm tt"; text between single quotes is literal.
fn is_24h_pattern(pattern: &str) -> bool {
    pattern.split('\'').step_by(2).any(|part| part.contains('H'))
}

pub fn tr(lang: &str, key: &str) -> &'static str {
    let l = if lang == "auto" { resolve_auto() } else { lang };
    match (l, key) {
        ("zh", "install") => "安装 Claude Code 钩子",
        ("zh", "uninstall") => "卸载钩子",
        ("zh", "language") => "语言",
        ("zh", "lang_auto") => "跟随系统",
        ("zh", "reset_pos") => "重置悬浮条位置",
        ("zh", "quit") => "退出",
        ("zh", "hooks_missing") => "钩子未安装：右键托盘图标 → 安装 Claude Code 钩子（桌面版无需，已自动兜底）",
        ("zh", "autostart") => "开机自启（静默待命）",
        ("ja", "autostart") => "Windows起動時に自動開始",
        ("ko", "autostart") => "Windows 시작 시 자동 실행",
        ("zh", "refresh_all") => "全部刷新",
        ("zh", "open_data") => "打开数据文件夹（日志 / 图标）",
        ("ja", "open_data") => "データフォルダを開く（ログ / アイコン）",
        ("ko", "open_data") => "데이터 폴더 열기 (로그 / 아이콘)",
        ("ru", "open_data") => "Открыть папку данных (журналы / значки)",
        ("uk", "open_data") => "Відкрити теку даних (журнали / значки)",
        (_, "open_data") => "Open data folder (logs / icons)",
        ("ja", "refresh_all") => "すべて更新",
        ("ko", "refresh_all") => "모두 새로 고침",
        ("ja", "install") => "Claude Code フックを導入",
        ("ja", "uninstall") => "フックを削除",
        ("ja", "language") => "言語",
        ("ja", "lang_auto") => "システムに従う",
        ("ja", "reset_pos") => "バー位置をリセット",
        ("ja", "quit") => "終了",
        ("ja", "hooks_missing") => "フック未導入：トレイ右クリック → フックを導入（デスクトップ版は自動フォールバック済み）",
        ("ko", "install") => "Claude Code 후크 설치",
        ("ko", "uninstall") => "후크 제거",
        ("ko", "language") => "언어",
        ("ko", "lang_auto") => "시스템 따르기",
        ("ko", "reset_pos") => "바 위치 초기화",
        ("ko", "quit") => "종료",
        ("ko", "hooks_missing") => "후크 미설치: 트레이 우클릭 → 후크 설치 (데스크톱판은 자동 폴백)",
        ("ru", "install") => "Установить хуки Claude Code",
        ("uk", "install") => "Встановити хуки Claude Code",
        ("ru", "uninstall") => "Удалить хуки",
        ("uk", "uninstall") => "Видалити хуки",
        ("ru", "language") => "Язык",
        ("uk", "language") => "Мова",
        ("ru", "lang_auto") => "Как в системе",
        ("uk", "lang_auto") => "Як у системі",
        ("ru", "reset_pos") => "Сбросить положение панели",
        ("uk", "reset_pos") => "Скинути положення панелі",
        ("ru", "quit") => "Выйти",
        ("uk", "quit") => "Вийти",
        ("ru", "hooks_missing") => "Хуки не установлены: нажмите правой кнопкой по значку в трее → Установить хуки Claude Code (для настольной версии используется автоматический резервный режим)",
        ("uk", "hooks_missing") => "Хуки не встановлено: клацніть правою кнопкою по значку в треї → Встановити хуки Claude Code (для настільної версії працює автоматичний запасний режим)",
        ("ru", "autostart") => "Запускать с Windows (в фоне)",
        ("uk", "autostart") => "Запускати разом із Windows (у фоні)",
        ("ru", "refresh_all") => "Обновить всё",
        ("uk", "refresh_all") => "Оновити все",
        (_, "install") => "Install Claude Code hooks",
        (_, "uninstall") => "Uninstall hooks",
        (_, "language") => "Language",
        (_, "lang_auto") => "Follow system",
        (_, "reset_pos") => "Reset bar position",
        (_, "quit") => "Quit",
        (_, "hooks_missing") => "Hooks not installed: tray right-click → Install Claude Code hooks (desktop app auto-fallback active)",
        (_, "autostart") => "Start with Windows (silent)",
        (_, "refresh_all") => "Refresh all",

        ("zh", "waiting") => "正在等待首次读数…",
        ("ja", "waiting") => "最初の読み取りを待っています…",
        ("ko", "waiting") => "첫 번째 읽기를 기다리는 중…",
        ("ru", "waiting") => "Ожидание первых данных…",
        ("uk", "waiting") => "Очікування першого показника…",
        (_, "waiting") => "Waiting for the first reading…",

        ("zh", "quit_app") => "退出 Codenotch",
        ("ja", "quit_app") => "Codenotch を終了",
        ("ko", "quit_app") => "Codenotch 종료",
        ("ru", "quit_app") => "Выйти из Codenotch",
        ("uk", "quit_app") => "Вийти з Codenotch",
        (_, "quit_app") => "Quit Codenotch",
        ("zh", "peek_notch") => "显示挖孔 5 秒",
        ("ja", "peek_notch") => "ノッチを5秒表示",
        ("ko", "peek_notch") => "노치 5초 보이기",
        ("ru", "peek_notch") => "Показать вырез на 5 секунд",
        ("uk", "peek_notch") => "Показати виріз на 5 секунд",
        (_, "peek_notch") => "Show the notch for 5 seconds",
        ("zh", "settings") => "设置…",
        ("ja", "settings") => "設定…",
        ("ko", "settings") => "설정…",
        ("ru", "settings") => "Настройки…",
        ("uk", "settings") => "Налаштування…",
        (_, "settings") => "Settings…",






        _ => "?",
    }
}

#[cfg(test)]
mod tests {
    use super::tr;

    const RUSSIAN_KEYS: &[(&str, &str)] = &[
        ("settings", "Настройки…"),
        ("refresh_all", "Обновить всё"),
        ("waiting", "Ожидание первых данных…"),
        ("quit_app", "Выйти из Codenotch"),
        ("peek_notch", "Показать вырез на 5 секунд"),
        ("quit", "Выйти"),
        ("install", "Установить хуки Claude Code"),
        ("uninstall", "Удалить хуки"),
        ("language", "Язык"),
        ("lang_auto", "Как в системе"),
        ("reset_pos", "Сбросить положение панели"),
        ("hooks_missing", "Хуки не установлены: нажмите правой кнопкой по значку в трее → Установить хуки Claude Code (для настольной версии используется автоматический резервный режим)"),
        ("autostart", "Запускать с Windows (в фоне)"),
        ("open_data", "Открыть папку данных (журналы / значки)"),
    ];

    #[test]
    fn russian_translates_every_known_key() {
        for (key, value) in RUSSIAN_KEYS {
            assert_eq!(
                tr("ru", key),
                *value,
                "missing Russian translation for {key}"
            );
            assert_ne!(tr("ru", key), "?", "unknown Russian key {key}");
        }
    }

    const UKRAINIAN_KEYS: &[(&str, &str)] = &[
        ("open_data", "Відкрити теку даних (журнали / значки)"),
        ("install", "Встановити хуки Claude Code"),
        ("uninstall", "Видалити хуки"),
        ("language", "Мова"),
        ("lang_auto", "Як у системі"),
        ("reset_pos", "Скинути положення панелі"),
        ("quit", "Вийти"),
        ("hooks_missing", "Хуки не встановлено: клацніть правою кнопкою по значку в треї → Встановити хуки Claude Code (для настільної версії працює автоматичний запасний режим)"),
        ("autostart", "Запускати разом із Windows (у фоні)"),
        ("refresh_all", "Оновити все"),
        ("waiting", "Очікування першого показника…"),
        ("quit_app", "Вийти з Codenotch"),
        ("peek_notch", "Показати виріз на 5 секунд"),
        ("settings", "Налаштування…"),
    ];

    #[test]
    fn ukrainian_translates_every_known_key() {
        for (key, value) in UKRAINIAN_KEYS {
            assert_eq!(
                tr("uk", key),
                *value,
                "missing Ukrainian translation for {key}"
            );
            assert_ne!(tr("uk", key), "?", "unknown Ukrainian key {key}");
        }
    }

    #[test]
    fn unknown_language_keeps_the_english_fallback() {
        assert_eq!(tr("xx", "settings"), "Settings…");
    }

    #[test]
    fn the_hour_symbol_outside_quotes_decides_the_clock() {
        assert!(super::is_24h_pattern("HH:mm"));
        assert!(super::is_24h_pattern("H:mm"));
        assert!(super::is_24h_pattern("HH' h 'mm"));
        assert!(!super::is_24h_pattern("hh:mm tt"));
        assert!(!super::is_24h_pattern("tt hh:mm"));
        assert!(!super::is_24h_pattern("h:mm 'Hrs'"));
    }
}
