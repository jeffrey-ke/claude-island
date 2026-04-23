//
//  PermissionDetailView.swift
//  ClaudeIsland
//
//  Expanded, tool-aware detail panel for pending tool approvals.
//  Slots under the InstanceRow tool preview line when waitingForApproval.
//

import SwiftUI

struct PermissionDetailView: View {
    let context: PermissionContext

    private var input: [String: String] {
        context.toolInputStrings
    }

    var body: some View {
        switch context.toolName {
        case "Bash":
            bashBody
        case "Edit", "MultiEdit":
            EditInputDiffView(input: input)
        case "Write":
            writeBody
        case "Read":
            readBody
        case "Grep", "Glob":
            patternBody
        case "WebFetch", "WebSearch":
            webBody
        default:
            genericBody
        }
    }

    // MARK: - Per-tool bodies

    private var bashBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let command = input["command"] {
                codeBlock(command)
            }
            if let description = input["description"] {
                Text(description)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var writeBody: some View {
        let filename = URL(fileURLWithPath: input["file_path"] ?? "file").lastPathComponent
        let content = input["content"] ?? ""
        let total = content.components(separatedBy: "\n").count
        return FileCodeView(
            filename: filename,
            content: content,
            startLine: 1,
            totalLines: total,
            maxLines: 15
        )
    }

    private var readBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let path = input["file_path"] ?? input["path"] {
                pathHeader(path)
            }
            if !readRange.isEmpty {
                Text("offset / limit: \(readRange)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    private var readRange: String {
        [input["offset"], input["limit"]]
            .compactMap { $0 }
            .joined(separator: " / ")
    }

    private var patternBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let pattern = input["pattern"] {
                codeBlock(pattern)
            }
            if let path = input["path"], !path.isEmpty {
                Text("in \(path)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var webBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let primary = input["url"] ?? input["query"] {
                codeBlock(primary)
            }
            if let prompt = input["prompt"] {
                Text(prompt)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var genericBody: some View {
        let fields = context.fullInput
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(fields.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(fields[i].label):")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                    Text(fields[i].value)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Shared blocks

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.white.opacity(0.85))
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func pathHeader(_ path: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
            Text(path)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
