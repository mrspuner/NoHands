import Foundation

/// What the model is told. Lives in code for the same reason the envelope does: a prompt kept in
/// the owner's config cannot be fixed for an installation that already has one.
///
/// The wording is the one the probe of 2026-09-06 measured: strict JSON on both runs, no
/// reasoning, and `decisions: []` on a meeting where nothing was agreed — that last one is the
/// property worth protecting, because a model that invents agreements is worse than no summary.
public enum SummaryPrompt {
    public static let system = """
        Ты составляешь конспект рабочей встречи по её расшифровке. \
        Опирайся только на сказанное: не добавляй ничего, чего нет в расшифровке. \
        Отвечай строго одним объектом JSON без пояснений и без markdown-ограды, с полями: \
        title — название встречи, до 60 символов; \
        summary — массив строк, до пяти пунктов, о чём говорили; \
        decisions — массив объектов с полями text (договорённость своими словами) \
        и quote (дословный кусок расшифровки, подтверждающий её, 5-15 слов, скопированный без изменений). \
        Если договорённостей нет, decisions — пустой массив.
        """

    public static func user(transcript: String) -> String {
        "Расшифровка встречи:\n\n" + TranscriptEnvelope.wrapped(transcript)
    }
}
