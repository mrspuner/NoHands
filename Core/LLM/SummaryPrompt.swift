import Foundation

/// What the model is told, on both passes.
///
/// The analyst wording is the owner's own, with three changes. Its `<User Input>` block, which
/// told the model to answer «Пожалуйста, вставьте расшифровку» and wait, is gone: in a batch
/// pipeline the transcript arrives in the same call and that instruction would replace the
/// summary with that sentence. Its six markdown sections became JSON fields, because the quote
/// check — the thing that told a real decision from an invented one on 2026-09-07 — needs
/// structure. And its ceiling on the number of points is gone: on a fifteen-minute chunk the
/// ceiling is what turned an hour of conversation into a table of contents.
///
/// Lives in code rather than in the config for the same reason the envelope does: a prompt kept
/// in the owner's `config.json` cannot be fixed for an installation that already has one.
public enum SummaryPrompt {
    public static let system = """
        Вы — внимательный к деталям аналитик встреч. Вы получаете кусок расшифровки рабочей встречи \
        и превращаете его в структурированный разбор для занятого человека: только то, что \
        действительно сказано, без воды и без пересказа отступлений.

        Правила:
        - Опирайтесь только на сказанное. Не добавляйте ничего, чего нет в расшифровке.
        - Пишите утверждениями по существу, а не названиями тем. «Определены сроки» — плохо; \
        «сдать изменения до 9-10 числа» — хорошо. Сохраняйте имена, числа, сроки и названия так, \
        как они прозвучали.
        - Под каждым решением и каждой задачей приводите дословную цитату из расшифровки на 5-15 \
        слов, скопированную без изменений. Пункт без цитаты не пишите вовсе.
        - У задачи указывайте ответственного и срок, если они названы вслух; если не названы, \
        оставляйте поле пустым. Не додумывайте их.
        - Пропускайте приветствия, технические заминки и разговоры не по делу.

        Отвечайте строго одним объектом JSON без пояснений и без markdown-ограды, с полями:
        title — краткое название встречи, до 60 символов;
        summary — массив строк: что обсудили и к чему пришли;
        decisions — массив объектов с полями text и quote;
        tasks — массив объектов с полями text, owner, due, quote;
        openIssues — массив строк: вопросы, оставшиеся нерешёнными.
        Пустые массивы допустимы.
        """

    /// The second pass, and now it decides two fields out of five.
    ///
    /// It never sees the transcript, and since this branch it never sees a decision, a task or a
    /// quote either — those are concatenated by `SummaryAssembly`. What is left is the one job a
    /// model is needed for: reading several partial summaries of one meeting and saying what the
    /// meeting was about.
    public static let merge = """
        Вы сводите частичные саммари одной и той же встречи в одно. Каждая часть — несколько \
        строк о том, что обсуждали в своём куске встречи, по порядку.

        Правила:
        - Объедините повторяющееся в один пункт.
        - Не добавляйте ничего, чего нет в частях.
        - Дайте встрече одно название по всему её содержанию, до 60 символов.
        - Оставьте не больше десяти пунктов, самых существенных.

        Отвечайте строго одним объектом JSON без пояснений и без markdown-ограды, с полями:
        title — название встречи;
        summary — массив строк.
        """

    /// The line above the partial summaries in the merge message.
    ///
    /// Here rather than at the call site in `MLXSummaryRunner`, where it was written inline: it is
    /// prompt text like everything else in this file, and the merge prompt's own tests could not
    /// see it there.
    public static let mergePrefix = "Частичные саммари встречи по порядку:"

    /// The merge message, assembled here rather than in the subprocess: the partials now exist in
    /// Swift, and a second copy of this shape in Python is the drift this project spends its
    /// comments avoiding.
    ///
    /// Each part travels in the same envelope a chunk does. These are the model's own words
    /// rather than the transcript's, but they are still a user turn being handed to a model that
    /// has just been told what to do — and an unmarked one reads as a request.
    public static func mergeUser(summaries: [[String]]) -> String {
        var message = [mergePrefix]
        for (number, summary) in summaries.enumerated() {
            let body = summary.map { "- \($0)" }.joined(separator: "\n")
            message.append("Часть \(number + 1):\n" + TranscriptEnvelope.wrapped(body))
        }
        return message.joined(separator: "\n\n")
    }

    public static func user(chunk: String) -> String {
        "Кусок расшифровки встречи:\n\n" + TranscriptEnvelope.wrapped(chunk)
    }
}
