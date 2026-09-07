"""Runs Qwen3 8B over one meeting transcript and prints the model's answer.

Launched as a subprocess by MLXSummaryRunner: request as JSON on stdin, answer on stdout,
diagnostics on stderr. Kept deliberately small — everything that can be decided in Swift is
decided in Swift, because this file is the one part of the pipeline no test covers.

enable_thinking=False is not optional: Qwen3 is a reasoning model and without it half a minute
of deliberation lands in the meeting file. temp=0.0 for the same reason a transcript is not
creative writing.
"""

import json
import sys

from mlx_lm import generate, load
from mlx_lm.sample_utils import make_sampler


def main():
    request = json.load(sys.stdin)
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
