import SwiftUI

struct CodeBlockSyntaxHighlighter: Sendable {
    struct Token: Sendable {
        let text: String
        let color: Color
        let isKeyword: Bool
    }

    private static func keywordSet(for language: String) -> Set<String> {
        if language.contains("swift") || language.contains("swiftui") {
            return [
                "actor", "as", "associatedtype", "await", "break", "case", "catch", "class", "continue",
                "default", "defer", "deinit", "didSet", "do", "dynamic", "enum", "else", "extension",
                "false", "fallthrough", "fileprivate", "for", "func", "guard", "if", "import", "in",
                "init", "inout", "is", "lazy", "let", "mutating", "nonisolated", "nil", "override",
                "private", "protocol", "public", "return", "rethrows", "self", "static", "struct",
                "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "while", "where",
                "weak", "willSet", "internal", "final", "required",
            ]
        }
        if language.contains("python") {
            return [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
                "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import",
                "in", "is", "lambda", "None", "nonlocal", "not", "pass", "raise", "return", "try",
                "True", "while", "with", "yield",
            ]
        }
        if language.contains("javascript") || language.contains("typescript") || language.contains("js") || language.contains("tsx") {
            return [
                "await", "break", "case", "catch", "class", "const", "continue", "default", "delete",
                "do", "else", "export", "false", "finally", "for", "function", "if", "import", "in",
                "new", "return", "super", "switch", "this", "throw", "true", "try", "typeof", "while",
                "with", "yield", "var", "let",
            ]
        }
        return [
            "return", "if", "else", "for", "while", "true", "false", "null", "none", "const",
            "let", "var", "class", "import", "from", "function", "async",
        ]
    }

    private static func commentPrefix(for language: String) -> String? {
        if language.contains("python") || language.contains("bash") || language.contains("shell") {
            return "#"
        }
        return "//"
    }

    nonisolated static func tokens(for line: String, language: String?, foreground: Color, secondaryLabel: Color) -> [Token] {
        let normalizedLanguage = (language ?? "").lowercased()
        let keywords = keywordSet(for: normalizedLanguage)
        let normalizedCommentPrefix = commentPrefix(for: normalizedLanguage)

        let chars = Array(line)
        var index = 0
        var results: [Token] = []

        while index < chars.count {
            let char = chars[index]

            if char == "\"" || char == "'" || char == "`" {
                let quote = char
                var value = String(quote)
                index += 1
                while index < chars.count {
                    let current = chars[index]
                    value.append(current)
                    if current == "\\" && index + 1 < chars.count {
                        index += 1
                        value.append(chars[index])
                    } else if current == quote {
                        index += 1
                        break
                    }
                    index += 1
                }
                results.append(Token(text: value, color: .orange, isKeyword: false))
                continue
            }

            if let commentPrefix = normalizedCommentPrefix, isCommentStart(
                at: index,
                in: chars,
                prefix: commentPrefix
            ) {
                let commentText = String(chars[index...])
                if !commentText.isEmpty {
                    results.append(Token(text: commentText, color: .secondary, isKeyword: false))
                }
                break
            }

            if char.isNumber {
                var value = ""
                while index < chars.count {
                    let current = chars[index]
                    if current.isNumber || current == "." || current == "x" || current == "X"
                        || current == "a" || current == "b" || current == "f"
                        || current == "A" || current == "B" || current == "F"
                    {
                        value.append(current)
                        index += 1
                    } else {
                        break
                    }
                }
                results.append(Token(text: value, color: .purple, isKeyword: false))
                continue
            }

            if isIdentifierStart(char) {
                var value = ""
                while index < chars.count {
                    let current = chars[index]
                    if isIdentifier(current) {
                        value.append(current)
                        index += 1
                    } else {
                        break
                    }
                }

                if keywords.contains(value) {
                    results.append(Token(text: value, color: .blue, isKeyword: true))
                } else {
                    results.append(Token(text: value, color: foreground, isKeyword: false))
                }
                continue
            }

            if "{}()[]<>.,:;+-/*=%&|!^?~".contains(char) {
                results.append(Token(text: String(char), color: secondaryLabel, isKeyword: false))
                index += 1
                continue
            }

            results.append(Token(text: String(char), color: foreground, isKeyword: false))
            index += 1
        }

        if results.isEmpty {
            results.append(Token(text: " ", color: foreground, isKeyword: false))
        }
        return results
    }

    private static func isCommentStart(at index: Int, in chars: [Character], prefix: String) -> Bool {
        guard index < chars.count else { return false }
        if prefix == "//" {
            return index + 1 < chars.count && chars[index] == "/" && chars[index + 1] == "/"
        }
        if prefix == "#" {
            return chars[index] == "#"
        }
        return false
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_"
    }

    private static func isIdentifier(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }
}
