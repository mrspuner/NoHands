/// The Python the summary subprocess runs, compiled into the binary as text.
///
/// A string rather than an SwiftPM resource, and that is the second attempt. As a resource it
/// was read through `Bundle.module`, whose generated accessor looks next to the executable and
/// then at an absolute path inside this repository's `.build` — never at
/// `NoHands.app/Contents/Resources`, where `make-app.sh` had put the bundle. The application
/// therefore worked only while the build directory survived in place, and a miss was
/// `Swift.fatalError` inside the accessor rather than the named refusal this file's failures are
/// designed around. Compiled in, the script cannot be somewhere else.
///
/// Extended delimiters (`#"""`): the Python below carries its own `"""` docstring, which would
/// otherwise close the Swift literal. Everything between the delimiters is verbatim.
enum SummaryScript {
    static let source = #"""
        """Runs Qwen3 8B over a list of prompts and writes the answers to a file.

        Launched as a subprocess by MLXSummaryRunner: request as a JSON file whose path is the first
        argument, answers as a JSON array of strings written to the path the request names, diagnostics
        on stderr. Both travel as files because a transcript, and a whole meeting's worth of partial
        summaries, are larger than a pipe's buffer.

        The model is loaded once and reused for every prompt: loading costs fifteen seconds cold, and a
        five-prompt meeting would otherwise pay it five times.

        This script decides nothing. Which prompts to send, in what order, what to do with an answer that
        does not parse, and whether a merge is needed at all are Swift's, where tests can see them.

        The one contract Swift depends on: answers come back in prompt order, one per prompt. The list
        comprehension below guarantees it — do not replace it with anything that could reorder or drop an
        entry, such as a thread pool or a filter on failures. Swift lines the answers file back up with its
        chunks by position alone.

        enable_thinking=False is not optional: Qwen3 is a reasoning model and without it half a minute of
        deliberation lands in the meeting file. temp=0.0 for the same reason a transcript is not creative
        writing.
        """

        import json
        import sys

        from mlx_lm import generate, load
        from mlx_lm.sample_utils import make_sampler


        def answer(model, tokenizer, system, user, max_tokens):
            prompt = tokenizer.apply_chat_template(
                [
                    {"role": "system", "content": system},
                    {"role": "user", "content": user},
                ],
                add_generation_prompt=True,
                tokenize=False,
                enable_thinking=False,
            )
            return generate(
                model,
                tokenizer,
                prompt=prompt,
                max_tokens=max_tokens,
                sampler=make_sampler(temp=0.0),
                verbose=False,
            )


        def main():
            with open(sys.argv[1], encoding="utf-8") as request_file:
                request = json.load(request_file)
            model, tokenizer = load(request["model"])

            answers = [
                answer(model, tokenizer, prompt["system"], prompt["user"], prompt["maxTokens"])
                for prompt in request["prompts"]
            ]

            with open(request["answersPath"], "w", encoding="utf-8") as answers_file:
                json.dump(answers, answers_file, ensure_ascii=False)


        main()

        """#
}
