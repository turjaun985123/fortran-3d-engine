"""Tests for the Forge3D lexer (tools/f3dc/lexer.py). Stdlib unittest only."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools" / "f3dc"))

from errors import ErrorBag  # noqa: E402
from lexer import COLOR, COMMA, EOF, NEWLINE, NUMBER, STRING, WORD, tokenize  # noqa: E402


def lex(text, source_name="test.f3d"):
    bag = ErrorBag()
    tokens = tokenize(text, source_name, bag)
    return tokens, bag


def codes(bag):
    return [d.code for d in bag.diagnostics]


def non_eof(tokens):
    return [t for t in tokens if t.kind != EOF]


class TestLexer(unittest.TestCase):
    def test_words(self):
        tokens, bag = lex("box sphere_2 my-cube\n")
        words = [t for t in tokens if t.kind == WORD]
        self.assertEqual([t.text for t in words], ["box", "sphere_2", "my-cube"])
        self.assertEqual(codes(bag), [])
        self.assertEqual(tokens[-1].kind, EOF)

    def test_numbers(self):
        tokens, bag = lex("42 640 0 3.25\n")
        nums = [t for t in tokens if t.kind == NUMBER]
        self.assertEqual([t.text for t in nums], ["42", "640", "0", "3.25"])
        self.assertEqual(codes(bag), [])

    def test_strings_keep_quotes(self):
        tokens, bag = lex('name "hello world" end\n')
        strings = [t for t in tokens if t.kind == STRING]
        self.assertEqual(len(strings), 1)
        self.assertEqual(strings[0].text, '"hello world"')
        self.assertEqual(strings[0].span.length, len('"hello world"'))
        self.assertEqual(codes(bag), [])

    def test_color_token_vs_hash_comment(self):
        tokens, bag = lex("color #3cdc3c\n")
        colors = [t for t in tokens if t.kind == COLOR]
        self.assertEqual(len(colors), 1)
        self.assertEqual(colors[0].text, "#3cdc3c")
        self.assertEqual(colors[0].span.length, 7)
        self.assertEqual(codes(bag), [])
        # '# hello' is not a colour (not 6 hex digits): it is a comment.
        tokens2, bag2 = lex("# hello\nbox\n")
        self.assertEqual([t.kind for t in non_eof(tokens2)], [NEWLINE, WORD, NEWLINE])
        self.assertEqual([t for t in tokens2 if t.kind == COLOR], [])
        self.assertEqual(codes(bag2), [])

    def test_slash_slash_comment(self):
        tokens, bag = lex("box // this is ignored sphere\nsphere\n")
        self.assertEqual(
            [t.text for t in tokens if t.kind == WORD], ["box", "sphere"]
        )
        self.assertEqual(codes(bag), [])

    def test_commas(self):
        tokens, bag = lex("1, 2,3\n")
        self.assertEqual(
            [t.kind for t in non_eof(tokens)],
            [NUMBER, COMMA, NUMBER, COMMA, NUMBER, NEWLINE],
        )
        self.assertEqual(
            [t.text for t in tokens if t.kind == COMMA], [",", ","]
        )
        self.assertEqual(codes(bag), [])

    def test_negative_decimals(self):
        tokens, bag = lex("-1.5 -0.25 -42\n")
        nums = [t for t in tokens if t.kind == NUMBER]
        self.assertEqual([t.text for t in nums], ["-1.5", "-0.25", "-42"])
        self.assertEqual(codes(bag), [])

    def test_unterminated_string_reports_e103(self):
        tokens, bag = lex('name "oops\n')
        self.assertIn("E103", codes(bag))
        strings = [t for t in tokens if t.kind == STRING]
        self.assertEqual(len(strings), 1)
        self.assertEqual(strings[0].text, '"oops')
        self.assertEqual(tokens[-1].kind, EOF)

    def test_overlong_line_reports_e820(self):
        tokens, bag = lex("a" * 4097 + "\n")
        self.assertIn("E820", codes(bag))
        # Lexing recovers: the truncated line still yields a WORD token.
        words = [t for t in tokens if t.kind == WORD]
        self.assertEqual(len(words), 1)
        self.assertEqual(words[0].span.length, 4096)

    def test_line_col_spans_on_line_2(self):
        tokens, bag = lex("box\n  sphere 2\n")
        self.assertEqual(codes(bag), [])
        sphere = [t for t in tokens if t.kind == WORD and t.text == "sphere"][0]
        self.assertEqual(sphere.span.source, "test.f3d")
        self.assertEqual(sphere.span.line, 2)
        self.assertEqual(sphere.span.col, 3)
        self.assertEqual(sphere.span.length, 6)
        num = [t for t in tokens if t.kind == NUMBER][0]
        self.assertEqual((num.span.line, num.span.col, num.span.length), (2, 10, 1))

    def test_newline_and_eof_termination(self):
        tokens, bag = lex("box")
        self.assertEqual([t.kind for t in tokens], [WORD, EOF])
        self.assertEqual(codes(bag), [])


if __name__ == "__main__":
    unittest.main()
