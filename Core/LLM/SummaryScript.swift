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
        """Runs Qwen3 8B over one meeting transcript and prints the model's answer.

        Launched as a subprocess by MLXSummaryRunner: request as a JSON file whose path is the first
        argument, answer on stdout, diagnostics on stderr. The request travels as a file rather than on
        stdin because a transcript is large enough to exceed a pipe's buffer, and writing it to stdin
        would block the parent process until this script started draining it. Kept deliberately small —
        everything that can be decided in Swift is decided in Swift, because this file is the one part
        of the pipeline no test covers.

        enable_thinking=False is not optional: Qwen3 is a reasoning model and without it half a minute
        of deliberation lands in the meeting file. temp=0.0 for the same reason a transcript is not
        creative writing.
        """

        import json
        import sys

        from mlx_lm import generate, load
        from mlx_lm.sample_utils import make_sampler


        def main():
            with open(sys.argv[1], encoding="utf-8") as request_file:
                request = json.load(request_file)
            model, tokenizer = load(request["model"])
            prompt = tokenizer.apply_chat_template(
                [
                    {"role": "system", "content": request["system"]},
                    {"role": "user", "content": request["prompt"]},
                ],
                add_generation_prompt=True,
                tokenize=False,
                enable_thinking=False,
            )
            answer = generate(
                model,
                tokenizer,
                prompt=prompt,
                max_tokens=request["maxTokens"],
                sampler=make_sampler(temp=0.0),
                verbose=False,
            )
            sys.stdout.write(answer)


        main()

        """#
}
