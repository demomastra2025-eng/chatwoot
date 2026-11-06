"""Offline aggregate metrics using precisely the production Runtime.transcribe path.

No CLI starts models or fetches a corpus. An authorized caller supplies the runtime
and untouched human references. Never postprocess references or choose by reference.
"""


def edit_distance(reference, hypothesis):
    previous = list(range(len(hypothesis) + 1))
    for row, expected in enumerate(reference, 1):
        current = [row]
        for column, actual in enumerate(hypothesis, 1):
            current.append(min(current[-1] + 1, previous[column] + 1,
                               previous[column - 1] + (expected != actual)))
        previous = current
    return previous[-1]


def evaluate(runtime, cases):
    """cases: iterable of {request: contract dict, reference: untouched str}.

    Returns corpus WER/CER error rates (can exceed1), never claimed ASR accuracy.
    Case split/provenance/holdout approval and clinical errors remain caller duties.
    """
    words = characters = word_errors = character_errors = count = 0
    for case in cases:
        reference = case["reference"]
        if not isinstance(reference, str) or len(reference) > 10_000:
            raise ValueError("reference must be an authorized bounded untouched string")
        hypothesis = runtime.transcribe(case["request"])["text"]
        if len(hypothesis) > 10_000:
            raise ValueError("hypothesis exceeds offline metric bound")
        expected_words, actual_words = reference.split(), hypothesis.split()
        word_errors += edit_distance(expected_words, actual_words)
        character_errors += edit_distance(reference, hypothesis)
        words += len(expected_words)
        characters += len(reference)
        count += 1
    return {"cases": count, "reference_words": words, "reference_characters": characters,
            "word_errors": word_errors, "character_errors": character_errors,
            "wer": word_errors / words if words else None,
            "cer": character_errors / characters if characters else None}
