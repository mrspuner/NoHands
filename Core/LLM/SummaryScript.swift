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
        """Runs Qwen3 8B over one meeting, chunk by chunk, and prints the merged summary.

        Launched as a subprocess by MLXSummaryRunner: request as a JSON file whose path is the first
        argument, answer on stdout, diagnostics on stderr. The request travels as a file rather than on
        stdin because a transcript is large enough to exceed a pipe's buffer.

        The model is loaded once and reused for every chunk: loading costs fifteen seconds cold, and a
        five-chunk meeting would otherwise pay it five times. Chunking exists because a whole
        sixty-eight-minute meeting took about ten gigabytes and was killed by the system on a 16 GB
        machine; a fifteen-minute chunk takes a fraction of that, and the peak no longer depends on how
        long the meeting was.

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

            partials = []
            for chunk in request["chunks"]:
                partials.append(
                    answer(model, tokenizer, request["system"], chunk, request["maxTokens"])
                )

            if len(partials) == 1:
                sys.stdout.write(partials[0])
                return

            merged = answer(
                model,
                tokenizer,
                request["mergeSystem"],
                request["mergePrefix"] + "\n\n" + "\n\n".join(
                    "Часть %d:\n%s" % (number, text) for number, text in enumerate(partials, 1)
                ),
                request["mergeMaxTokens"],
            )
            sys.stdout.write(merged)


        main()

        """#
}
