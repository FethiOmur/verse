"""The call's dominant language: the language the cards are written in while the call runs in AUTO (owner decisions 7 and 8).

Swift tags every remote partial and turn with the language of its text (`lang`: the text's own language when the recognizer is
sure of it, else the language of the engine that heard it). Answering each turn in its own tag flips the cards on thin evidence:
one Italian greeting in an English call gave an Italian card. The dominant language is what the cards follow instead:

- before any speech it is the language the call started in (the session's prepared language, else English);
- only the other side counts (`remote`, and the room route's mic once his own reading has been split off); his own speech never
  changes it;
- an utterance of fewer than `SUBSTANTIVE_WORDS` words (a greeting, a few words, one short phrase) is ignored: it neither counts
  for a language nor breaks a run;
- it changes only on sustained speech in another language: `CONSECUTIVE` substantive utterances in a row in that language, or one
  utterance of at least `LONG_WORDS` words; a substantive utterance in the dominant language ends the run;
- it changes back by the same rule.

That hysteresis state is the language the cards are written in (`lang`). The language of most of the other side's speech so far
(`majority`: the most words over its substantive utterances, the starting language before any) is kept apart from it: a short
run in another language can flip the cards while most of the call is still in the first one. Regenerate on a card that is not in
the majority language answers in the majority language and resets `lang` to it (owner decision 9).

Pure: no clock, no I/O. `engine.py` feeds it and reports `lang_dominant` / `answer_lang` metrics.
"""

from __future__ import annotations

import re

from .protocol import LANGS

#: Below this many words an utterance never counts ("Ciao, come sta?", "Okay, perfetto", one short phrase).
SUBSTANTIVE_WORDS = 6
#: Substantive utterances in a row in another language that flip the dominant language.
CONSECUTIVE = 2
#: One utterance this long in another language flips it on its own (a full answer or a long question).
LONG_WORDS = 20
#: Before any speech, without a prepared language.
DEFAULT_LANG = "en"

_WORD = re.compile(r"[^\W\d_]+(?:['’][^\W\d_]+)*", re.UNICODE)


def word_count(text: str) -> int:
    """Words of letters (an apostrophe inside a word keeps it one word: "l'azienda", "don't")."""
    return len(_WORD.findall(text or ""))


class DominantLanguage:
    def __init__(self, initial: str | None = None) -> None:
        self.lang: str = initial if initial in LANGS else DEFAULT_LANG
        self._initial = self.lang
        self._run_lang: str | None = None
        self._run = 0
        #: Substantive utterances of the other side heard so far (any language).
        self.heard = 0
        #: Words of the other side's substantive utterances so far, by language.
        self.words: dict[str, int] = {}

    @property
    def majority(self) -> str:
        """The language of most of the other side's substantive speech so far (by words); the starting language before any. A
        tie keeps the language the cards are in, else the starting one."""
        if not self.words:
            return self._initial
        top = max(self.words.values())
        tied = [lang for lang, n in self.words.items() if n == top]
        if len(tied) == 1:
            return tied[0]
        return self.lang if self.lang in tied else self._initial if self._initial in tied else sorted(tied)[0]

    @property
    def run(self) -> tuple[str, int] | None:
        """The open run of substantive utterances in another language: (language, count), or None."""
        return (self._run_lang, self._run) if self._run_lang is not None else None

    def _step(self, lang: str | None, text: str) -> tuple[str | None, int, str | None, bool]:
        """(run language, run count, the language it flips to or None, counted) after one utterance; changes nothing."""
        if lang not in LANGS:
            return self._run_lang, self._run, None, False
        n = word_count(text)
        if n < SUBSTANTIVE_WORDS:
            return self._run_lang, self._run, None, False
        if lang == self.lang:
            return None, 0, None, True
        run = self._run + 1 if lang == self._run_lang else 1
        if run >= CONSECUTIVE or n >= LONG_WORDS:
            return None, 0, lang, True
        return lang, run, None, True

    def note(self, lang: str | None, text: str) -> str | None:
        """One finished utterance of the other side, tagged `lang`. Returns the new dominant language when it flips, else None."""
        run_lang, run, flip, counted = self._step(lang, text)
        self._run_lang, self._run = run_lang, run
        if counted:
            self.heard += 1
            self.words[lang] = self.words.get(lang, 0) + word_count(text)
        if flip is not None:
            self.lang = flip
        return flip

    def would_be(self, lang: str | None, text: str) -> str:
        """The dominant language if `text` (an utterance still being spoken) ended now. A card started on a partial uses it, so
        the question that completes a switch is already answered in the new language."""
        return self._step(lang, text)[2] or self.lang

    def reset(self, lang: str) -> None:
        """The dominant language is set from outside (the call pinned to `lang`, or a later regenerate): any open run is dropped.
        What was heard (`words`, `majority`) stays."""
        if lang in LANGS:
            self.lang = lang
        self._run_lang, self._run = None, 0
