import Foundation

struct AgentSession: Identifiable, Equatable {
    enum Status: Equatable {
        case working   // файл активно пишется — агент работает
        case waiting   // последним говорил ассистент — закончил или ждёт вас
        case idle      // последним говорил пользователь, активности нет
    }

    let id: String            // путь к .jsonl файлу сессии
    var sessionId: String
    var agent: String         // "Claude" (дальше — Codex, Cursor, ...)
    var projectName: String
    var cwd: String
    var branch: String?
    var title: String         // последний запрос пользователя
    var lastAssistant: String = ""   // последний ответ агента (для экрана завершения)
    var model: String?
    var lastModified: Date
    var status: Status
}

/// Агент завершил ход — что и в какой сессии сделано.
struct CompletionEvent: Identifiable, Equatable {
    let id: String            // uuid
    let sessionId: String
    let agent: String
    let projectName: String
    let title: String         // над чем работали
    let summary: String       // что сделано (последний ответ агента)
    let date: Date
}

/// Текущий экран развёрнутой панели: событие занимает панель целиком.
enum NotchScreen: Equatable {
    case sessions
    case permission(PermissionPrompt)
    case question(QuestionPrompt)
    case done(CompletionEvent)
}

/// Действие пользователя по запросу разрешения.
enum PermissionAction {
    case allow     // разрешить один раз
    case always    // разрешить и запомнить правило
    case deny      // запретить
    case dismiss   // отпустить в терминальный диалог
}

/// Превью диффа для Edit/Write/MultiEdit: первые строки изменения.
struct DiffPreview: Equatable {
    let removed: [String]     // до 2 строк
    let added: [String]       // до 2-3 строк
    let removedTotal: Int
    let addedTotal: Int
}

/// Запрос разрешения, ждущий решения Allow/Deny прямо в нотче.
struct PermissionPrompt: Identifiable, Equatable {
    let id: String            // uuid запроса
    let sessionId: String
    let tool: String
    let summary: String       // команда / файл
    let projectName: String
    let date: Date
    var diff: DiffPreview? = nil
}

/// Вопрос от AskUserQuestion, ждущий ответа прямо в нотче.
struct QuestionPrompt: Identifiable, Equatable {
    struct Option: Equatable {
        let label: String
        let description: String
    }

    let id: String            // uuid запроса
    let sessionId: String
    let header: String        // короткий ярлык, напр. "Theme"
    let question: String
    let options: [Option]
    let projectName: String
    let date: Date
}

/// Живой сигнал от хука Claude Code: агент ждёт разрешения или ответа.
struct SessionAlert: Identifiable, Equatable {
    enum Kind: Equatable {
        case approval   // PermissionRequest / permission notification
        case waiting    // ждёт ввода пользователя
    }

    let id: String            // sessionId
    var kind: Kind
    var message: String
    var date: Date
}
