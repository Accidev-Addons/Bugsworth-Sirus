# Bugsworth

Перехват, просмотр и хранение Lua-ошибок и taint-логов для WoW 3.3.5a (Sirus).

Форк [mathisto/Bugsworth](https://github.com/mathisto/Bugsworth), адаптированный под Sirus.

Что добавлено: отдельный вьюер taint-лога (ADDON_ACTION_BLOCKED/FORBIDDEN), кнопка «Копировать всё» для выгрузки всех показанных ошибок разом, русификация интерфейса.

## Команды

| Команда | Действие |
|---|---|
| `/bugs` | Открыть просмотрщик |
| `/bugs count` | Сводка по ошибкам |
| `/bugs last [N]` | Вывести последние N ошибок в чат |
| `/bugs clear` | Очистить все ошибки |
| `/bugs taint` | Анализатор taint |
| `/bugs config` | Настройки |
| `/bugs export` | Экспорт ошибок в SavedVariable `BugsworthExport` |
| `/bugs ignore [аддон]` | Игнорировать ошибки аддона |
| `/bugs unignore [аддон]` | Перестать игнорировать |
| `/bugs help` | Список команд |
| `/bugscopy` | Все ошибки одним текстом |

## Лицензия

GPL v2 или новее, см. [LICENSE](LICENSE).
