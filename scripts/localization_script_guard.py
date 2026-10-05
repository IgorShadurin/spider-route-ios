"""Reject translated UI text containing an unrelated writing system.

This supplements placeholder/key checks; it does not claim to verify semantics.
Latin remains allowed for brand names, technical terms and real place names.
"""

import unicodedata
from itertools import combinations

SCRIPTS = {
    "ar": {"ARABIC"},
    "ur": {"ARABIC"},
    "he": {"HEBREW"},
    "bn": {"BENGALI"},
    "gu": {"GUJARATI"},
    "hi": {"DEVANAGARI"},
    "mr": {"DEVANAGARI"},
    "kn": {"KANNADA"},
    "ml": {"MALAYALAM"},
    "or": {"ORIYA"},
    "pa": {"GURMUKHI"},
    "ta": {"TAMIL"},
    "te": {"TELUGU"},
    "th": {"THAI"},
    "el": {"GREEK"},
    "ru": {"CYRILLIC"},
    "uk": {"CYRILLIC"},
    "ja": {"HIRAGANA", "KATAKANA", "CJK"},
    "ko": {"HANGUL", "CJK"},
    "zh": {"CJK"},
}
KNOWN = set().union(*SCRIPTS.values())


def unexpected_scripts(locale, value):
    allowed = SCRIPTS.get(locale.split("-")[0], set()) | {"LATIN"}
    observed = set()
    for character in value:
        if not character.isalpha():
            continue
        name = unicodedata.name(character, "")
        script = name.split(" ")[0]
        if script in KNOWN and script not in allowed:
            observed.add(script)
    return sorted(observed)


def validate_values(locale, values):
    return [
        f"{locale}/{key}: unexpected writing system {', '.join(bad)}"
        for key, value in values.items()
        if (bad := unexpected_scripts(locale, value))
    ]


def copied_translation_issues(tables):
    """Reject blocks copied between unrelated languages, including Latin scripts.

    Regional variants of the same language may intentionally share translations.
    Four identical substantial phrases are evidence of a copied block; individual
    shared words, brands and short technical labels are not language evidence.
    This complements visual/native review, not a general language detector.
    """
    issues = []
    for (left, values), (right, other) in combinations(sorted(tables.items()), 2):
        if left.split("-")[0] == right.split("-")[0]:
            continue
        shared = [
            key
            for key, value in values.items()
            if isinstance(value, str)
            and len(value) >= 24
            and len(value.split()) >= 4
            and other.get(key) == value
        ]
        if len(shared) >= 4:
            issues.append(
                f"{left}/{right}: probable copied translation block "
                f"({len(shared)} identical long phrases: {', '.join(shared[:5])})"
            )
    return issues
