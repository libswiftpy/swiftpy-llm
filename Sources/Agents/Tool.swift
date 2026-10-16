//
//  Tool.swift
//  swiftpy-llm
//
//  Created by Tibor Felföldy on 2026. 07. 05..
//

import SwiftPy
import SwiftPyViews
import FoundationModels
import SwiftUI
import Synchronization

/// A function an ``agents.Agent`` can call, built by the ``agents.tool`` decorator.
@Scriptable
@MainActor
public final class Tool: @preconcurrency FoundationModels.Tool, Sendable {
    /// The name the model calls the tool by, taken from the function's name.
    public let name: String

    /// What the tool does, taken from the function's docstring. This is what the model reads to decide when to call it.
    public let description: String

    /// The schema of the arguments the model fills in before each call.
    public let parameters: GenerationSchema

    internal let makeParams: PyObject
    internal let function: PyObject
    internal let base: PyObject
    private var formatInput: PyObject?
    private var formatOutput: PyObject?

    /// Creates a tool. Prefer ``agents.tool``, which builds this from a function.
    ///
    /// args_type: A class carrying the parameter schema, either a ``modeling.model`` class or one synthesized from the function's annotations.
    /// function: The callable the tool invokes, taking a single arguments object, and optionally the function to call with them in place of its own.
    /// base: The undecorated function, which calling the tool forwards to.
    public init(argsType: PyObject, function: PyObject, base: PyObject) throws {
        guard let schema: [String: Any] = argsType._schema,
              let makeParams = argsType._from_json else {
            throw PythonError.ValueError("Failed to get tool parameters")
        }

        let name: String = argsType._tool_name ?? function.__name__ ?? "tool"
        let description: String = argsType._tool_description ?? function.__doc__ ?? ""

        // First, so the model titles the call before writing its arguments.
        var withTitle = schema
        if var properties = schema["properties"] as? [[String: Any]] {
            properties.insert([
                "name": Self.titleKey,
                "type": "str",
                "description": "A few words on what this call does, shown to the user, like 'Try a GET request'.",
            ], at: 0)
            withTitle["properties"] = properties
        }

        self.name = name
        self.description = description
        self.parameters = try GenerationSchema(pythonModelSchema: withTitle)
        self.makeParams = makeParams
        self.function = function
        self.base = base
    }

    /// Runs the underlying function, so a tool stays callable without a model.
    ///
    /// params: The arguments the undecorated function takes. Await the result.
    func __call__(params: Unpack) async throws -> PyObject? {
        try await awaited(invoke(base, arguments: params.values))
    }

    /// Sets what an expanded call shows of its input, in place of each argument as `name: value`.
    ///
    /// fn: Takes the same arguments as the tool, and returns a view, or a string shown as Markdown.
    ///
    /// ````python
    /// @tool
    /// def run(code: str) -> str:
    ///     '''Runs Python code.'''
    ///     ...
    ///
    /// @run.input
    /// def run_input(code: str) -> str:
    ///     return f"```python\n{code}\n```"
    /// ````
    func input(_ fn: PyObject) -> PyObject {
        formatInput = fn
        return fn
    }

    /// Sets what an expanded call shows of its result, in place of a plain code block.
    ///
    /// fn: Takes what the tool returned, and returns a view, or a string shown as Markdown.
    ///
    /// ```python
    /// @tool
    /// def docs(name: str) -> str:
    ///     '''Looks up the documentation of a name.'''
    ///     ...
    ///
    /// @docs.output
    /// def docs_output(markdown: str) -> str:
    ///     return markdown
    /// ```
    func output(_ fn: PyObject) -> PyObject {
        formatOutput = fn
        return fn
    }
}

extension Tool {
    /// The argument the model titles a call's log with. Hyphenated, so no
    /// Python parameter can take the name.
    static let titleKey = "call-title"

    /// The title, and the arguments the function takes without it.
    static func splitTitle(from arguments: GeneratedContent) -> (title: String?, arguments: GeneratedContent) {
        guard case .structure(var properties, let orderedKeys) = arguments.kind,
              let title = properties.removeValue(forKey: titleKey) else {
            return (nil, arguments)
        }
        let rest = GeneratedContent(kind: .structure(
            properties: properties,
            orderedKeys: orderedKeys.filter { $0 != titleKey }
        ))
        return (try? title.value(String.self), rest)
    }

    public func call(arguments: GeneratedContent) async throws -> FoundationModels.Prompt {
        let parts = try await respond(to: arguments)
        return FoundationModels.Prompt { parts.map(\.prompt) }
    }

    /// What the model gets back from a call: text, with images among it.
    func respond(to arguments: GeneratedContent, log: ToolCallLog = ToolCallLog()) async throws -> [ToolResultPart] {
        let (title, arguments) = Self.splitTitle(from: arguments)
        let params: PyObject = try makeParams(arguments.jsonString)

        // Shown while it runs, and filled in once it's done.
        display(log, title: title, input: await inputView(of: arguments, params: params))
        // What the call prints is its own, rather than the cell's: the model
        // reads it, even from a call stopped partway.
        let printed = PrintedText()
        defer {
            log.printed = printed.text
            log.isRunning = false
        }

        do {
            // A scope of its own, so stopping the call ends what it waits on,
            // `time.sleep` or an await, without stopping the rest of the run.
            let result = try await Interpreter.withCancellationScope { scope in
                log.cancel = {
                    log.isCancelled = true
                    scope.cancel()
                }
                defer { log.cancel = nil }
                return try await Interpreter.withOutput(to: { printed.append($0) }) {
                    try await awaited(invoke(function, arguments: [params]))
                }
            }
            let parts = try Self.parts(of: result)
            // Nothing returned, so the printed text says it all.
            let returnsNothing = result == nil || result?.typeName == "NoneType"
            if !(returnsNothing && !printed.text.isEmpty) {
                log.output = await outputView(of: result, parts: parts)
            }
            if printed.text.isEmpty { return parts }
            return [.text(printed.text)] + (returnsNothing ? [] : parts)
        } catch where log.isCancelled {
            // The model hears why, and goes on from there.
            log.output = Self.outputBlock(Self.cancelledText)
            return [.text(Self.joined(printed.text, Self.cancelledText))]
        } catch let error as PythonError where error.type != "KeyboardInterrupt" {
            // Handed back as the result, so the model can see what went wrong
            // and try again, rather than its whole response failing.
            let text = Self.failureText(of: error)
            log.output = Self.outputBlock(text, keepingEnd: true)
            return [.text(Self.joined(printed.text, text))]
        } catch {
            log.output = Self.outputBlock(Self.failureText(of: error), keepingEnd: true)
            throw error
        }
    }

    /// A `views.Image` is sent as an image, and so is one in a list or tuple,
    /// with the other items as text. Anything else goes through str(), the way
    /// print would show it, so a number or a list is fine to return.
    static func parts(of result: PyObject?) throws -> [ToolResultPart] {
        guard let result else { return [.text("None")] }
        if isImage(result) {
            return [try .image(result)]
        }
        if ["list", "tuple"].contains(result.typeName),
           let items = [PyObject](try builtins.throwing.list(result) as PyObject),
           items.contains(where: isImage) {
            return try items.map { isImage($0) ? try .image($0) : .text(try str($0)) }
        }
        return [.text(try str(result))]
    }

    private static var builtins: PyModule { py.module("builtins")! }

    private static func str(_ object: PyObject) throws -> String {
        try builtins.throwing.str(object)
    }

    private static func isImage(_ object: PyObject) -> Bool {
        guard let type = py.module("views")?.Image.flatMap({ PyType($0) }) else { return false }
        return type.isInstance(object.reference)
    }

    static let cancelledText = "The user cancelled this call before it finished."

    private static func joined(_ printed: String, _ text: String) -> String {
        printed.isEmpty ? text : printed.trimmingCharacters(in: .newlines) + "\n\n" + text
    }

    /// What `result` comes to: awaited, when it's a coroutine or a task.
    private func awaited(_ result: PyObject) async throws -> PyObject? {
        guard AsyncTask(result) != nil || PyRuntime.isCoroutine(result) else { return result }
        return try await AsyncTask.from(result).untilCompletes()
    }

    /// `text` in a plain code block, so it keeps its lines. The fence is longer
    /// than any run of backticks inside.
    static func codeBlock(_ text: String) -> String {
        let longest = text.matches(of: /`+/).map(\.output.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\n\(text.trimmingCharacters(in: .newlines))\n\(fence)"
    }

    /// `text` in a code block, cut to `lineLimit` lines until tapped, so a
    /// long result opens quickly; the model still reads all of it. A traceback
    /// keeps its end.
    static func outputBlock(_ text: String, keepingEnd: Bool = false) -> AnyView {
        AnyView(ToolText(text: text, keepingEnd: keepingEnd))
    }

    static let lineLimit = 10

    /// The lines shown before a tap, and how many are left out.
    static func preview(_ text: String, keepingEnd: Bool = false) -> (text: String, hidden: Int) {
        let lines = text.trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > lineLimit else { return (text, 0) }
        let kept = keepingEnd ? lines.suffix(lineLimit) : lines.prefix(lineLimit)
        return (kept.joined(separator: "\n"), lines.count - lineLimit)
    }

    /// What a tool raised as `agents` formats it, or else the traceback
    /// without the colours CPython adds.
    static func failureText(of error: any Error) -> String {
        if let error = error as? PythonError, error.type == "_ToolFailure" {
            return error.value
        }
        return String(describing: error).replacing(/\u{1B}\[[0-9;]*m/, with: "")
    }

    // On the Python thread, as a cell runs, so a blocking call like
    // requests.get can wait there; main can't.
    @PythonActor
    private func invoke(_ function: PyObject, arguments: [PyObject]) throws -> PyObject {
        try PyRuntime.call(function, arguments: arguments)
    }

    /// The input as `input` formatted it, or each argument as it came.
    private func inputView(of arguments: GeneratedContent, params: PyObject) async -> AnyView {
        let plain = AnyView(ToolArguments(arguments: arguments))
        guard let formatInput else { return plain }
        do {
            return try Self.formatted(await invoke(function, arguments: [params, formatInput]), by: "input")
        } catch {
            return Self.fallback(plain, failure: error)
        }
    }

    /// The result as `output` formatted it, or its text in code blocks, and its images.
    private func outputView(of result: PyObject?, parts: [ToolResultPart]) async -> AnyView {
        let views = parts.map(\.view)
        let plain = views.count == 1 ? views[0] : AnyView(VStack(alignment: .leading, spacing: 8) {
            ForEach(views.indices, id: \.self) { views[$0] }
        })
        guard let formatOutput else { return plain }
        do {
            let view = try Self.formatted(await invoke(formatOutput, arguments: [result ?? .none]), by: "output")
            return AnyView(Collapsible { view })
        } catch {
            return Self.fallback(plain, failure: error)
        }
    }

    /// What a formatter returned: a string as Markdown, or a view.
    private static func formatted(_ object: PyObject, by name: String) throws -> AnyView {
        if let text = String(object) {
            return AnyView(MarkdownContent(model: Markdown(text: text)))
        }
        if let view = object.reference.view {
            return view
        }
        throw PythonError.TypeError("\(name)() returned \(object.typeName), not a view or a string")
    }

    // Only the log falls back; the call goes ahead.
    private static func fallback(_ plain: AnyView, failure: any Error) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 4) {
            plain
            Text(failureText(of: failure))
                .font(.caption)
                .foregroundStyle(.red)
        })
    }

    private func display(_ log: ToolCallLog, title: String?, input: AnyView) {
        let title = title?.replacing("\n", with: " ") ?? ""
        let view = ToolCallView(log: log, title: title.isEmpty ? name : title, input: input)
        Interpreter.interface.display(AnyView(view))
    }
}

/// A piece of what a call returned, as the model gets it.
enum ToolResultPart {
    case text(String)
    case image(PyObject, FoundationModels.Attachment<ImageAttachmentContent>)

    @MainActor
    static func image(_ object: PyObject) throws -> ToolResultPart {
        .image(object, try Agent.attachment(object))
    }

    var prompt: FoundationModels.Prompt {
        switch self {
        case .text(let text): FoundationModels.Prompt(text)
        case .image(_, let attachment): FoundationModels.Prompt(attachment)
        }
    }

    @MainActor
    var view: AnyView {
        switch self {
        case .text(let text): Tool.outputBlock(text)
        case .image(let object, _): object.reference.view ?? AnyView(EmptyView())
        }
    }
}

/// A call's state, as its log shows it.
@MainActor
@Observable
final class ToolCallLog {
    var isRunning = true
    var printed = ""
    var output: AnyView?
    /// Set while the call runs.
    var cancel: (() -> Void)?
    var isCancelled = false
}

/// What a call prints, from whichever thread Python prints on.
private final class PrintedText: Sendable {
    private let buffer = Mutex("")

    var text: String { buffer.withLock { $0 } }

    func append(_ text: String) {
        buffer.withLock { $0 += text }
    }
}

private struct ToolCallView: View {
    let log: ToolCallLog
    let title: String
    let input: AnyView

    var body: some View {
        DisclosureLogContainerView(tint: .orange, isInProgress: log.isRunning, cancel: log.cancel) {
            ToolCallSection("Input") {
                Collapsible { input }
            }

            if log.output != nil || !log.printed.isEmpty {
                ToolCallSection("Output") {
                    if !log.printed.isEmpty {
                        ToolText(text: log.printed)
                    }
                    if let output = log.output {
                        output
                    }
                }
                .environment(\.trimsLeadingHeadingPadding, true)
                .textSelection(.enabled)
            }
        } label: {
            Label(title, systemImage: "wrench.and.screwdriver")
                .font(.body.bold())
                .lineLimit(1)
        }
    }
}

private struct ToolCallSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Text in a code block, its first `lineLimit` lines (or a traceback's last)
/// until tapped.
private struct ToolText: View {
    private let full: Markdown
    private let preview: Markdown
    private let hidden: Int
    private let keepingEnd: Bool
    @State private var isExpanded = false

    init(text: String, keepingEnd: Bool = false) {
        let (preview, hidden) = Tool.preview(text, keepingEnd: keepingEnd)
        self.full = Markdown(text: Tool.codeBlock(text))
        self.preview = Markdown(text: Tool.codeBlock(preview))
        self.hidden = hidden
        self.keepingEnd = keepingEnd
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if keepingEnd { toggle }
            MarkdownContent(model: isExpanded ? full : preview)
            if !keepingEnd { toggle }
        }
    }

    @ViewBuilder
    private var toggle: some View {
        if hidden > 0 {
            ExpandButton(isExpanded: $isExpanded, collapsedTitle: "\(hidden) more lines")
        }
    }
}

/// A view cut to about `lineLimit` lines of code until tapped, for what isn't
/// plain text: arguments, or what `input` and `output` formatted.
private struct Collapsible<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0
    @State private var isExpanded = false
    @ScaledMetric(relativeTo: .footnote) private var limit: CGFloat = 190

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
                .frame(maxHeight: isExpanded ? nil : limit, alignment: .top)
                .clipped()

            if height > limit + 1 {
                ExpandButton(isExpanded: $isExpanded, collapsedTitle: "Show all")
            }
        }
    }
}

private struct ExpandButton: View {
    @Binding var isExpanded: Bool
    let collapsedTitle: String

    var body: some View {
        Button {
            withAnimation { isExpanded.toggle() }
        } label: {
            Label(isExpanded ? "Show less" : collapsedTitle, systemImage: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Each argument as `name: value`; a string in full, lines and all.
private struct ToolArguments: View {
    let arguments: GeneratedContent

    var body: some View {
        if case let .structure(properties, orderedKeys) = arguments.kind, !orderedKeys.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(orderedKeys, id: \.self) { key in
                    if let value = properties[key] {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(key):").bold()
                            Text((try? value.value(String.self)) ?? value.jsonString)
                        }
                    }
                }
            }
            .font(.caption.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }
}
