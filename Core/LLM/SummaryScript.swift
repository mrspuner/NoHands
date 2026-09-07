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


        def is_json(text):
            """Whether an answer is the JSON object the prompt asked for.

            The fence is stripped first, mirroring SummaryResponse.stripFence on the Swift side:
            the prompt forbids a markdown fence, the model writes one anyway now and then, and the
            pipeline already accepts that. Only what Swift would also reject counts as a failure
            here.
            """
            stripped = text.strip()
            if stripped.startswith("```"):
                lines = stripped.split("\n")[1:]
                if lines and lines[-1].strip().startswith("```"):
                    lines = lines[:-1]
                stripped = "\n".join(lines)
            try:
                json.loads(stripped)
            except ValueError:
                return False
            return True


        def main():
            with open(sys.argv[1], encoding="utf-8") as request_file:
                request = json.load(request_file)
            model, tokenizer = load(request["model"])

            partials = []
            for number, chunk in enumerate(request["chunks"], 1):
                partial = answer(
                    model, tokenizer, request["system"], chunk, request["maxTokens"]
                )
                # An answer cut off at maxTokens is not valid JSON, and neither place it could go
                # is survivable: alone it reaches the parser as a permanent failure whose cause is
                # invisible, and in a merge it arrives as prose the merge absorbs, taking a
                # fifteenth of the meeting with it and marking nothing. Stop, named.
                #
                # The chunk number and nothing else: this line is recognised speech's neighbour,
                # it goes to a diagnostics file, and the last line of that file is read back into
                # a panel. Transcript content is never logged.
                if not is_json(partial):
                    sys.stderr.write("chunk %d: the model's answer is not JSON\n" % number)
                    sys.exit(1)
                partials.append(partial)

            if len(partials) == 1:
                sys.stdout.write(partials[0])
                return

            # Each partial travels inside the same envelope a chunk does. It is not the
            # transcript, but it carries pieces of it verbatim — every decision and task holds a
            # quote copied out of the speech — and an unmarked user turn is read as a request.
            # The markers arrive in the request so there is one copy of them, in Swift.
            merged = answer(
                model,
                tokenizer,
                request["mergeSystem"],
                request["mergePrefix"] + "\n\n" + "\n\n".join(
                    "Часть %d:\n%s\n%s\n%s" % (
                        number,
                        request["openingMarker"],
                        text,
                        request["closingMarker"],
                    )
                    for number, text in enumerate(partials, 1)
                ),
                request["mergeMaxTokens"],
            )
            sys.stdout.write(merged)


        main()

        """#
}
