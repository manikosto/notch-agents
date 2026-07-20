import SwiftUI

extension Color {
    /// Фирменный акцент — фиолетовый, под цвет инвейдера 👾.
    static let notchAccent = Color(red: 0.64, green: 0.56, blue: 1.0)
    /// Нейтральный фон карточек.
    static let notchCard = Color.white.opacity(0.055)
    /// Нейтральная обводка карточек.
    static let notchStroke = Color.white.opacity(0.09)
}

// MARK: - Форма нотча (скруглены только нижние углы)

struct NotchShape: Shape {
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(bottomRadius, rect.height / 2)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Контур без верхней грани — чтобы у верхнего края экрана не было линии.
struct NotchOutline: Shape {
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(bottomRadius, rect.height / 2)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - r),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

// MARK: - Корневая вью

struct NotchRootView: View {
    @ObservedObject var state: NotchState
    let controller: NotchController

    private var surfaceSize: CGSize {
        NotchMetrics.surfaceSize(state: state)
    }

    private var radius: CGFloat { state.expanded ? 24 : 10 }

    var body: some View {
        VStack(spacing: 0) {
            surface
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    private var surface: some View {
        ZStack(alignment: .top) {
            if state.expanded {
                ExpandedView(state: state, controller: controller)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            } else {
                CollapsedView(state: state)
                    .transition(.opacity)
                if !state.alerts.isEmpty {
                    AlertGlow()
                }
            }
        }
        .frame(width: surfaceSize.width, height: surfaceSize.height)
        .clipShape(NotchShape(bottomRadius: radius))
        .background(
            NotchShape(bottomRadius: radius)
                .fill(Color.black)
                .shadow(color: .black.opacity(state.expanded ? 0.55 : 0),
                        radius: 22, x: 0, y: 10)
        )
        .overlay(
            NotchOutline(bottomRadius: radius)
                .stroke(Color.white.opacity(state.expanded ? 0.09 : 0), lineWidth: 1)
        )
        .onHover { controller.hover($0) }
        // expand/collapse анимируется транзакцией из NotchController
        // (разные пружины на раскрытие и сворачивание)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: state.sessions)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: state.alerts)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: state.prompts)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: state.questions)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: state.completion)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: state.showAllSessions)
    }
}

// MARK: - Свёрнутое состояние: «крылья» с индикаторами по бокам выреза

struct CollapsedView: View {
    @ObservedObject var state: NotchState

    private var workingCount: Int {
        state.sessions.filter { $0.status == .working }.count
    }

    /// Общий статус: оранжевый — есть алерт/запрос/вопрос, зелёный — кто-то работает, серый — тишина.
    private var needsAttention: Bool {
        !state.alerts.isEmpty || !state.prompts.isEmpty || !state.questions.isEmpty
    }

    private var aggregateColor: Color {
        if needsAttention { return .orange }
        if workingCount > 0 { return .green }
        return Color(white: 0.45)
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 3) {
                Text("👾")
                    .font(.system(size: 10))
                    .opacity(state.sessions.isEmpty ? 0.35 : 1)
                if !state.sessions.isEmpty {
                    Text("\(state.sessions.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .frame(width: NotchMetrics.wingWidth)
            Color.clear
                .frame(width: state.notchSize.width)
            StatusDot(color: aggregateColor, pulsing: needsAttention)
                .frame(width: NotchMetrics.wingWidth)
        }
        .frame(height: state.notchSize.height)
    }
}

/// Один аккуратный огонёк; пульсирует, когда агент ждёт вас.
struct StatusDot: View {
    let color: Color
    let pulsing: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: color.opacity(0.8), radius: 3)
            .opacity(pulsing && pulse ? 0.35 : 1)
            .onAppear { startPulseIfNeeded() }
            .onChange(of: pulsing) { _ in startPulseIfNeeded() }
    }

    private func startPulseIfNeeded() {
        pulse = false
        guard pulsing else { return }
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

/// Пульсирующий янтарный огонёк под нотчем: агент ждёт вас.
struct AlertGlow: View {
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Capsule()
                .fill(Color.orange)
                .frame(width: 84, height: 3)
                .blur(radius: 2.5)
                .opacity(pulse ? 0.35 : 0.95)
                .padding(.bottom, 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - Плашка обновления

struct UpdateBanner: View {
    let update: UpdateInfo
    @ObservedObject var state: NotchState
    let controller: NotchController
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.notchAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.updateBusy ? "Обновление…" : "Доступна версия \(update.version)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.95))
                Text(state.updateBusy ? "скачиваю и устанавливаю" : "нажмите, чтобы обновиться")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
            }
            Spacer(minLength: 8)
            if state.updateBusy {
                ProgressView().scaleEffect(0.5).frame(width: 20, height: 20)
            } else {
                Text("Update")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.notchAccent.opacity(hovering ? 1 : 0.85)))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: NotchMetrics.updateBannerHeight)
        .background(RoundedRectangle(cornerRadius: 13).fill(Color.notchAccent.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.notchAccent.opacity(0.4), lineWidth: 1))
        .onHover { hovering = $0 }
        .onTapGesture {
            guard !state.updateBusy else { return }
            controller.startUpdate()
        }
        .help("Скачать и установить обновление")
    }
}

// MARK: - Развёрнутое состояние

struct ExpandedView: View {
    @ObservedObject var state: NotchState
    let controller: NotchController

    var body: some View {
        VStack(spacing: 0) {
            UsageHeader(state: state)
            Color.clear.frame(height: 6)
            if let u = state.update {
                UpdateBanner(update: u, state: state, controller: controller)
                Color.clear.frame(height: NotchMetrics.rowSpacing)
            }
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func session(_ sid: String) -> AgentSession? {
        state.sessions.first { $0.sessionId == sid }
    }

    private var sessionsSummary: String {
        let agents = Array(Set(state.sessions.map(\.agent))).sorted()
        let suffix = agents.isEmpty ? "" : " · " + agents.joined(separator: " · ")
        return "\(state.sessions.count) sessions\(suffix)"
    }

    /// Экран целиком меняется под событие: сессии / approval / вопрос.
    @ViewBuilder
    private var content: some View {
        switch state.screen {
        case .sessions:
            VStack(spacing: NotchMetrics.rowSpacing) {
                ForEach(state.alerts.prefix(NotchMetrics.maxAlerts)) { a in
                    AlertCard(alert: a,
                              projectName: session(a.id)?.projectName,
                              controller: controller)
                }
                if state.sessions.isEmpty && state.alerts.isEmpty {
                    Text("Нет активных сессий")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(height: NotchMetrics.rowHeight)
                } else {
                    ForEach(state.sessions.prefix(NotchMetrics.maxRows)) { s in
                        SessionRow(session: s,
                                   hasAlert: state.alerts.contains { $0.id == s.sessionId }
                                       || state.prompts.contains { $0.sessionId == s.sessionId }
                                       || state.questions.contains { $0.sessionId == s.sessionId },
                                   controller: controller)
                    }
                }
            }
        case .permission(let p):
            VStack(spacing: NotchMetrics.rowSpacing) {
                if let s = session(p.sessionId) {
                    SessionRow(session: s, hasAlert: true, controller: controller)
                }
                PermissionCard(prompt: p, controller: controller)
            }
        case .question(let q):
            VStack(spacing: NotchMetrics.rowSpacing) {
                if let s = session(q.sessionId) {
                    SessionRow(session: s, hasAlert: true, controller: controller)
                }
                QuestionCard(prompt: q, controller: controller)
            }
        case .done(let c):
            VStack(spacing: NotchMetrics.rowSpacing) {
                if let s = session(c.sessionId) {
                    SessionRow(session: s, hasAlert: false, controller: controller)
                }
                DoneCard(completion: c, controller: controller)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch state.screen {
            case .sessions:
                Text(sessionsSummary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
                if !state.prompts.isEmpty || !state.questions.isEmpty {
                    Button {
                        state.showAllSessions = false
                    } label: {
                        Text("⚠ ждёт ответа →")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.notchAccent)
                    }
                    .buttonStyle(.plain)
                }
            case .permission, .question, .done:
                Button {
                    state.showAllSessions = true
                } label: {
                    Text("Show all \(state.sessions.count) sessions")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
    }
}

// MARK: - Шапка: лимиты подписки + звук (в полосе по бокам от выреза)

struct UsageHeader: View {
    @ObservedObject var state: NotchState

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "speedometer")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                if let u = state.usage {
                    limitPair("5h", u.fiveHourPercent, u.fiveHourResetsAt)
                    Text("|")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.15))
                    limitPair("7d", u.sevenDayPercent, u.sevenDayResetsAt)
                } else {
                    Text("limits —")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            Color.clear
                .frame(width: state.notchSize.width)
            HStack(spacing: 8) {
                Spacer()
                Menu {
                    ForEach(ModelOption.allCases) { opt in
                        Button(opt.title) {
                            if ModelManager.setModel(opt.rawValue) {
                                state.defaultModel = opt.rawValue
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "cpu")
                            .font(.system(size: 9))
                        Text(state.defaultModel.map(ModelManager.prettyName) ?? "model")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(.white.opacity(0.7))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Модель по умолчанию для новых сессий")
                Button {
                    state.soundEnabled.toggle()
                } label: {
                    Image(systemName: state.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(state.soundEnabled ? "Выключить звук" : "Включить звук")
            }
            .padding(.trailing, 4)
        }
        .frame(height: max(state.notchSize.height, 24))
        .onAppear { state.defaultModel = ModelManager.currentModel() }
    }

    @ViewBuilder
    private func limitPair(_ label: String, _ pct: Int, _ resetsAt: Date?) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(.white.opacity(0.75))
        Text("\(pct)%")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(pctColor(pct))
        if let d = resetsAt {
            Text(remainString(d))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.35))
        }
    }
}

func pctColor(_ p: Int) -> Color {
    if p >= 80 { return .red }
    if p >= 50 { return .orange }
    return .green
}

func remainString(_ d: Date) -> String {
    let s = Int(d.timeIntervalSinceNow)
    guard s > 0 else { return "now" }
    let h = s / 3600
    let m = (s % 3600) / 60
    if h >= 24 { return "\(h / 24)d\(h % 24)h" }
    return h > 0 ? "\(h)h\(String(format: "%02d", m))m" : "\(m)m"
}

// MARK: - Карточка вопроса AskUserQuestion: варианты прямо в нотче

struct QuestionCard: View {
    let prompt: QuestionPrompt
    let controller: NotchController
    @State private var customAnswer = ""

    private func submitCustom() {
        let answer = customAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        controller.questionHandler?(prompt.id, answer)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("💬")
                    .font(.system(size: 11))
                Text("Claude's Question")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.95))
                if !prompt.projectName.isEmpty {
                    Text("· \(prompt.projectName)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
                Spacer()
                Button {
                    controller.questionHandler?(prompt.id, nil)
                    controller.focusTerminal()
                } label: {
                    Text("Terminal ↗")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Ответить в терминале")
            }
            .frame(height: 16)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 6) {
                        Text(prompt.header)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.notchAccent.opacity(0.18)))
                            .foregroundColor(.notchAccent)
                            .fixedSize()
                        Text(prompt.question)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array(prompt.options.enumerated()), id: \.offset) { i, option in
                        QuestionOptionRow(index: i + 1, option: option) {
                            controller.questionHandler?(prompt.id, option.label)
                        }
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(maxHeight: NotchMetrics.questionScrollMax)
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text("✏️")
                        .font(.system(size: 10))
                    TextField("Свой ответ…", text: $customAnswer)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.92))
                        .onSubmit { submitCustom() }
                    if !customAnswer.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button {
                            submitCustom()
                        } label: {
                            Image(systemName: "arrow.turn.down.left")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.notchAccent)
                        }
                        .buttonStyle(.plain)
                        .help("Отправить свой ответ")
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(height: NotchMetrics.questionHeight(for: prompt))
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.notchCard))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.notchStroke, lineWidth: 1))
    }
}

struct QuestionOptionRow: View {
    let index: Int
    let option: QuestionPrompt.Option
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(hovering ? Color.notchAccent.opacity(0.35) : Color.white.opacity(0.1)))
                    .foregroundColor(hovering ? .notchAccent : .white.opacity(0.75))
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.white.opacity(hovering ? 0.14 : 0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Карточка завершения: какая сессия закончила и что сделано

struct DoneCard: View {
    let completion: CompletionEvent
    let controller: NotchController
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.green)
                Text("Done")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.95))
                if !completion.projectName.isEmpty {
                    Text("· \(completion.projectName)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
                Chip(text: completion.agent, color: agentColor(completion.agent))
                Spacer()
                Text("Open ↗")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(hovering ? 0.7 : 0.4))
            }
            Text(renderMarkdown(completion.summary))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(height: NotchMetrics.doneCardHeight)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.green.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.green.opacity(0.25), lineWidth: 1))
        .onHover { hovering = $0 }
        .onTapGesture { controller.focusTerminal() }
        .help("Перейти в терминал")
    }
}

// MARK: - Карточка запроса разрешения: Allow/Deny прямо из нотча

struct PermissionCard: View {
    let prompt: PermissionPrompt
    let controller: NotchController
    @State private var hoveringDeny = false
    @State private var hoveringAllow = false
    @State private var hoveringAlways = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("⚠️")
                    .font(.system(size: 11))
                Text(prompt.tool)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.95))
                if !prompt.projectName.isEmpty {
                    Text("· \(prompt.projectName)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
                Spacer()
                Button {
                    controller.permissionHandler?(prompt.id, .dismiss)
                    controller.focusTerminal()
                } label: {
                    Text("Terminal ↗")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Решить в терминале")
            }
            HStack(spacing: 6) {
                Text(prompt.summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let d = prompt.diff {
                    Text("+\(d.addedTotal)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                    if d.removedTotal > 0 {
                        Text("−\(d.removedTotal)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.red)
                    }
                }
            }
            if let d = prompt.diff {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(d.removed.enumerated()), id: \.offset) { _, line in
                        DiffLine(sign: "−", text: line, color: .red)
                    }
                    ForEach(Array(d.added.enumerated()), id: \.offset) { _, line in
                        DiffLine(sign: "+", text: line, color: .green)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
            }
            HStack(spacing: 8) {
                Button {
                    controller.permissionHandler?(prompt.id, .deny)
                } label: {
                    Text("Deny")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(hoveringDeny ? 0.2 : 0.12)))
                        .foregroundColor(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .onHover { hoveringDeny = $0 }
                Button {
                    controller.permissionHandler?(prompt.id, .allow)
                } label: {
                    Text("Allow Once")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(hoveringAllow ? 1.0 : 0.9)))
                        .foregroundColor(.black)
                }
                .buttonStyle(.plain)
                .onHover { hoveringAllow = $0 }
                Button {
                    controller.permissionHandler?(prompt.id, .always)
                } label: {
                    Text("Always")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.notchAccent.opacity(hoveringAlways ? 0.4 : 0.22)))
                        .foregroundColor(.notchAccent)
                }
                .buttonStyle(.plain)
                .onHover { hoveringAlways = $0 }
                .help(prompt.tool == "Bash"
                      ? "Всегда разрешать эту команду"
                      : "Всегда разрешать \(prompt.tool)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(height: NotchMetrics.promptHeight(for: prompt))
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.notchCard))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.notchStroke, lineWidth: 1))
    }
}

/// Строка мини-диффа: знак + текст на цветной подложке.
struct DiffLine: View {
    let sign: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Text(sign)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(color.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .frame(height: 14)
        .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.12)))
    }
}

// MARK: - Карточка «агент ждёт вас»

struct AlertCard: View {
    let alert: SessionAlert
    let projectName: String?
    let controller: NotchController
    @State private var hovering = false

    private var title: String {
        var t = alert.kind == .approval ? "NEEDS APPROVAL" : "WAITING FOR YOU"
        if let p = projectName { t += " · \(p)" }
        return t
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 30, height: 30)
                Text(alert.kind == .approval ? "⚠️" : "💬")
                    .font(.system(size: 13))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)
                    Text(title)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.75))
                }
                Text(alert.message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("Open ↗")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.18 : 0.1)))
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(.horizontal, 12)
        .frame(height: NotchMetrics.alertHeight)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.notchCard))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.notchStroke, lineWidth: 1))
        .onHover { hovering = $0 }
        .onTapGesture { controller.focusTerminal() }
    }
}

// MARK: - Строка сессии

struct SessionRow: View {
    let session: AgentSession
    let hasAlert: Bool
    let controller: NotchController
    @State private var hovering = false

    private var effectiveColor: Color {
        hasAlert ? .orange : session.status.color
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(effectiveColor.opacity(0.16))
                    .frame(width: 30, height: 30)
                Text("👾")
                    .font(.system(size: 14))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.projectName)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                    if let b = session.branch {
                        Text(b)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                Text("You: \(session.title)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Chip(text: session.agent, color: agentColor(session.agent))
                    if let m = session.model {
                        Chip(text: m, color: Color(white: 0.75))
                    }
                }
                HStack(spacing: 4) {
                    Circle()
                        .fill(effectiveColor)
                        .frame(width: 5, height: 5)
                    Text(hasAlert ? "needs you" : session.status.label)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(effectiveColor)
                    Text(timeAgo(session.lastModified))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                }
            }
            Button {
                controller.openSession(session)
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(hovering ? 0.9 : 0.45))
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(hovering ? 0.16 : 0.07))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Прыгнуть в терминал этой сессии")
        }
        .padding(.horizontal, 12)
        .frame(height: NotchMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(Color.white.opacity(hovering ? 0.13 : 0.06))
        )
        .onHover { hovering = $0 }
        .onTapGesture { controller.openSession(session) }
        .help("Прыгнуть в терминал этой сессии")
    }
}

struct Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.2)))
            .foregroundColor(color)
    }
}

// MARK: - Helpers

/// Инлайновый markdown → AttributedString (жирный, курсив, ссылки, код),
/// переносы строк схлопываем в пробел — карточка узкая.
func renderMarkdown(_ raw: String) -> AttributedString {
    let flat = raw.replacingOccurrences(of: "\n", with: " ")
    var opts = AttributedString.MarkdownParsingOptions()
    opts.interpretedSyntax = .inlineOnlyPreservingWhitespace
    if let attr = try? AttributedString(markdown: flat, options: opts) {
        return attr
    }
    return AttributedString(flat)
}

func agentColor(_ agent: String) -> Color {
    switch agent {
    case "Claude": return .notchAccent
    case "Codex": return Color(red: 0.35, green: 0.65, blue: 1.0)
    case "Cursor": return Color(white: 0.85)
    default: return Color(white: 0.6)
    }
}

extension AgentSession.Status {
    var color: Color {
        switch self {
        case .working: return .green
        case .waiting: return .orange
        case .idle: return Color(white: 0.5)
        }
    }

    var label: String {
        switch self {
        case .working: return "working"
        case .waiting: return "ready"
        case .idle: return "idle"
        }
    }
}

func timeAgo(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "<1m" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h"
}
