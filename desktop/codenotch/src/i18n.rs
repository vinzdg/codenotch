//! Rust-side (tray menu) strings. The page has its own dictionary; keys are kept identical on both sides.

pub fn resolve_auto() -> &'static str {
    crate::platform::system_locale()
        .and_then(|name| language_from_windows_locale(&name))
        .unwrap_or("en")
}

/// Map a Windows locale name onto a language code this crate ships.
///
/// Traditional regions must be matched before the leftover `zh*` fallback —
/// `starts_with("zh")` used to send zh-TW/zh-HK to Simplified.
fn language_from_windows_locale(name: &str) -> Option<&'static str> {
    let name = name.to_ascii_lowercase();
    if name.starts_with("zh-tw")
        || name.starts_with("zh-hant")
        || name.starts_with("zh-hk")
        || name.starts_with("zh-mo")
    {
        return Some("zh-Hant");
    }
    if name.starts_with("zh-cn")
        || name.starts_with("zh-hans")
        || name.starts_with("zh-sg")
        || name.starts_with("zh")
    {
        return Some("zh");
    }
    if name.starts_with("ja") {
        return Some("ja");
    }
    if name.starts_with("ko") {
        return Some("ko");
    }
    if name.starts_with("pt-br") {
        return Some("pt-BR");
    }
    if name.starts_with("ru") {
        return Some("ru");
    }
    if name.starts_with("uk") {
        return Some("uk");
    }
    None
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
        ("pt-BR", "open_data") => "Abrir pasta de dados (logs / ícones)",
        ("pt-BR", "install") => "Instalar hooks do Claude Code",
        ("pt-BR", "uninstall") => "Desinstalar hooks",
        ("pt-BR", "language") => "Idioma",
        ("pt-BR", "lang_auto") => "Seguir o sistema",
        ("pt-BR", "reset_pos") => "Redefinir posição da barra",
        ("pt-BR", "quit") => "Sair",
        ("pt-BR", "hooks_missing") => "Hooks não instalados: clique com o botão direito no ícone da bandeja → Instalar hooks do Claude Code (o aplicativo desktop usa fallback automático)",
        ("pt-BR", "autostart") => "Iniciar com o Windows",
        ("pt-BR", "refresh_all") => "Atualizar tudo",
        ("pt-BR", "waiting") => "Aguardando a primeira leitura…",
        ("pt-BR", "quit_app") => "Encerrar o Codenotch",
        ("pt-BR", "settings") => "Ajustes…",
        ("pt-BR", "refresh_now") => "Atualizar agora",
        ("pt-BR", "open_host") => "Abrir o %@",
        ("pt-BR", "keep_open") => "Manter aberto",
        ("zh", "install") => "安装 Claude Code 钩子",
        ("zh-Hant", "install") => "安裝 Claude Code 鉤子",
        ("zh", "uninstall") => "卸载钩子",
        ("zh-Hant", "uninstall") => "解除安裝鉤子",
        ("zh", "language") => "语言",
        ("zh-Hant", "language") => "語言",
        ("zh", "lang_auto") => "跟随系统",
        ("zh-Hant", "lang_auto") => "跟隨系統",
        ("zh", "reset_pos") => "重置悬浮条位置",
        ("zh-Hant", "reset_pos") => "重置懸浮列位置",
        ("zh", "quit") => "退出",
        ("zh-Hant", "quit") => "結束",
        ("zh", "hooks_missing") => "钩子未安装：右键托盘图标 → 安装 Claude Code 钩子（桌面版无需，已自动兜底）",
        ("zh-Hant", "hooks_missing") => "鉤子未安裝：在系統匣圖示按右鍵 → 安裝 Claude Code 鉤子（桌面版無需，已自動後援）",
        ("zh", "autostart") => "开机自启（静默待命）",
        ("zh-Hant", "autostart") => "開機自動啟動（靜默待命）",
        ("ja", "autostart") => "Windows起動時に自動開始",
        ("ko", "autostart") => "Windows 시작 시 자동 실행",
        ("zh", "refresh_all") => "全部刷新",
        ("zh-Hant", "refresh_all") => "全部重新整理",
        ("zh", "open_data") => "打开数据文件夹（日志 / 图标）",
        ("zh-Hant", "open_data") => "開啟資料資料夾（日誌 / 圖示）",
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
        ("zh-Hant", "waiting") => "正在等待首次讀數…",
        ("ja", "waiting") => "最初の読み取りを待っています…",
        ("ko", "waiting") => "첫 측정값을 기다리는 중…",
        ("ru", "waiting") => "Ожидание первых данных…",
        ("uk", "waiting") => "Очікування першого показника…",
        (_, "waiting") => "Waiting for the first reading…",

        ("zh", "quit_app") => "退出 Codenotch",
        ("zh-Hant", "quit_app") => "結束 Codenotch",
        ("ja", "quit_app") => "Codenotch を終了",
        ("ko", "quit_app") => "Codenotch 종료",
        ("ru", "quit_app") => "Выйти из Codenotch",
        ("uk", "quit_app") => "Вийти з Codenotch",
        (_, "quit_app") => "Quit Codenotch",
        ("zh", "settings") => "设置…",
        ("zh-Hant", "settings") => "設定…",
        ("ja", "settings") => "設定…",
        ("ko", "settings") => "설정…",
        ("ru", "settings") => "Настройки…",
        ("uk", "settings") => "Налаштування…",
        (_, "settings") => "Settings…",
        ("zh", "refresh_now") => "立即刷新",
        ("zh-Hant", "refresh_now") => "立即重新整理",
        ("ja", "refresh_now") => "今すぐ更新",
        ("ru", "refresh_now") => "Обновить сейчас",
        ("uk", "refresh_now") => "Оновити зараз",
        ("ko", "refresh_now") => "지금 새로 고침",
        (_, "refresh_now") => "Refresh now",
        ("zh", "open_host") => "打开 %@",
        ("zh-Hant", "open_host") => "開啟 %@",
        ("ja", "open_host") => "%@ を開く",
        ("ru", "open_host") => "Открыть %@",
        ("uk", "open_host") => "Відкрити %@",
        ("ko", "open_host") => "%@ 열기",
        (_, "open_host") => "Open %@",
        ("zh", "keep_open") => "保持展开",
        ("zh-Hant", "keep_open") => "保持展開",
        ("ja", "keep_open") => "開いたままにする",
        ("ko", "keep_open") => "열어 두기",
        ("ru", "keep_open") => "Оставить открытым",
        ("uk", "keep_open") => "Тримати відкритим",
        (_, "keep_open") => "Keep open",
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
        ("refresh_now", "Обновить сейчас"),
        ("open_host", "Открыть %@"),
        ("keep_open", "Оставить открытым"),
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
        ("keep_open", "Тримати відкритим"),
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
        ("settings", "Налаштування…"),
        ("refresh_now", "Оновити зараз"),
        ("open_host", "Відкрити %@"),
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

    const TRADITIONAL_CHINESE_KEYS: &[(&str, &str)] = &[
        ("settings", "設定…"),
        ("refresh_all", "全部重新整理"),
        ("waiting", "正在等待首次讀數…"),
        ("quit_app", "結束 Codenotch"),
        ("refresh_now", "立即重新整理"),
        ("open_host", "開啟 %@"),
        ("quit", "結束"),
        ("install", "安裝 Claude Code 鉤子"),
        ("uninstall", "解除安裝鉤子"),
        ("language", "語言"),
        ("lang_auto", "跟隨系統"),
        ("reset_pos", "重置懸浮列位置"),
        ("hooks_missing", "鉤子未安裝：在系統匣圖示按右鍵 → 安裝 Claude Code 鉤子（桌面版無需，已自動後援）"),
        ("autostart", "開機自動啟動（靜默待命）"),
        ("open_data", "開啟資料資料夾（日誌 / 圖示）"),
    ];

    #[test]
    fn traditional_chinese_translates_every_known_key() {
        for (key, value) in TRADITIONAL_CHINESE_KEYS {
            assert_eq!(
                tr("zh-Hant", key),
                *value,
                "missing Traditional Chinese translation for {key}"
            );
            assert_ne!(tr("zh-Hant", key), "?", "unknown Traditional Chinese key {key}");
        }
    }

    #[test]
    fn traditional_chinese_locales_resolve_apart_from_simplified() {
        use super::language_from_windows_locale;
        assert_eq!(language_from_windows_locale("zh-TW"), Some("zh-Hant"));
        assert_eq!(language_from_windows_locale("zh-Hant"), Some("zh-Hant"));
        assert_eq!(language_from_windows_locale("zh-Hant-TW"), Some("zh-Hant"));
        assert_eq!(language_from_windows_locale("zh-HK"), Some("zh-Hant"));
        assert_eq!(language_from_windows_locale("zh-MO"), Some("zh-Hant"));
        assert_eq!(language_from_windows_locale("zh-CN"), Some("zh"));
        assert_eq!(language_from_windows_locale("zh-Hans"), Some("zh"));
        assert_eq!(language_from_windows_locale("zh-Hans-CN"), Some("zh"));
        assert_eq!(language_from_windows_locale("zh-SG"), Some("zh"));
        assert_eq!(language_from_windows_locale("zh"), Some("zh"));
    }

    const BRAZILIAN_PORTUGUESE_KEYS: &[(&str, &str)] = &[
        ("settings", "Ajustes…"),
        ("refresh_all", "Atualizar tudo"),
        ("waiting", "Aguardando a primeira leitura…"),
        ("quit_app", "Encerrar o Codenotch"),
        ("refresh_now", "Atualizar agora"),
        ("open_host", "Abrir o %@"),
        ("keep_open", "Manter aberto"),
        ("quit", "Sair"),
        ("install", "Instalar hooks do Claude Code"),
        ("uninstall", "Desinstalar hooks"),
        ("language", "Idioma"),
        ("lang_auto", "Seguir o sistema"),
        ("reset_pos", "Redefinir posição da barra"),
        ("autostart", "Iniciar com o Windows"),
        ("open_data", "Abrir pasta de dados (logs / ícones)"),
    ];

    #[test]
    fn brazilian_portuguese_translates_every_known_key() {
        for (key, value) in BRAZILIAN_PORTUGUESE_KEYS {
            assert_eq!(tr("pt-BR", key), *value, "missing Brazilian Portuguese translation for {key}");
            assert_ne!(tr("pt-BR", key), "?", "unknown Brazilian Portuguese key {key}");
        }
    }

    #[test]
    fn brazilian_portuguese_locale_resolves() {
        use super::language_from_windows_locale;
        assert_eq!(language_from_windows_locale("pt-BR"), Some("pt-BR"));
        assert_eq!(language_from_windows_locale("pt-br"), Some("pt-BR"));
        assert_eq!(language_from_windows_locale("pt-PT"), None);
    }

    #[test]
    fn korean_locale_and_tray_copy() {
        assert_eq!(super::language_from_windows_locale("ko-KR"), Some("ko"));
        assert_eq!(super::language_from_windows_locale("ko"), Some("ko"));
        for (key, expected) in [
            ("settings", "설정…"),
            ("refresh_all", "모두 새로 고침"),
            ("refresh_now", "지금 새로 고침"),
            ("open_host", "%@ 열기"),
            ("waiting", "첫 측정값을 기다리는 중…"),
            ("keep_open", "열어 두기"),
            ("install", "Claude Code 후크 설치"),
        ] {
            assert_eq!(tr("ko", key), expected);
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
