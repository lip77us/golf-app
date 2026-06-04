"""
accounts/phone.py
-----------------
Phone-number normalization for phone-first login (freemium design §12).

`normalize()` collapses whatever a user typed into a canonical E.164 string
(e.g. "+14155551234") so it can be stored once and compared reliably.  Returns
None for input that can't be interpreted as a valid number.

This is intentionally dependency-free and US-default.  For correct
international parsing (country inference, length rules per region) swap in the
`phonenumbers` library later — §12 flags international formats as a known risk.
Until then we accept:
  * 10 digits                -> assume US/Canada, prepend +1
  * 11 digits starting with 1 -> US/Canada, prepend +
  * a leading '+' with 8–15 digits -> already E.164, pass through
"""


def normalize(raw: str | None) -> str | None:
    if not raw:
        return None
    raw = raw.strip()
    has_plus = raw.startswith('+')
    digits = ''.join(ch for ch in raw if ch.isdigit())

    if has_plus:
        # Already in international form — keep as given if it's a plausible
        # E.164 length (country code + national number).
        if 8 <= len(digits) <= 15:
            return '+' + digits
        return None

    if len(digits) == 10:
        return '+1' + digits
    if len(digits) == 11 and digits.startswith('1'):
        return '+' + digits
    return None
