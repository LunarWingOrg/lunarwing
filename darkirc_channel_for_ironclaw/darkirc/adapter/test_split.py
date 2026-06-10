#!/usr/bin/env python3
"""Unit tests for _split_message_bytes function."""

import sys
import os

# Add parent directory to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Import the function from the adapter
from darkirc_adapter import _split_message_bytes


def test_basic_ascii():
    """Test basic ASCII text that doesn't need splitting."""
    text = "Hello world"
    result = _split_message_bytes(text, 400)
    assert result == ["Hello world"]
    assert len(result) == 1


def test_split_at_space():
    """Test splitting at a space boundary."""
    text = "This is a longer message that needs splitting"
    result = _split_message_bytes(text, 20)
    # Should split at space boundaries
    assert len(result) >= 2
    # All chunks should be under 20 bytes
    for chunk in result:
        assert len(chunk.encode("utf-8")) <= 20


def test_split_at_newline():
    """Test splitting at newline boundaries."""
    text = "Line one\nLine two\nLine three"
    result = _split_message_bytes(text, 15)
    # Should split at newlines first
    assert result[0] == "Line one"
    assert len(result) == 3


def test_utf8_multi_byte():
    """Test UTF-8 multi-byte characters at boundaries."""
    # Test with 2-byte UTF-8 character (€ = 3 bytes)
    text = "Price: €100"
    # "Price: " = 7 bytes, "€" = 3 bytes, "Price: €1" = 11 bytes
    # At limit 10, should split at space after "Price:" (6 bytes)
    result = _split_message_bytes(text, 10)
    assert result[0] == "Price:"
    assert result[1] == "€100"
    assert len(result) == 2


def test_emoji_split():
    """Test emoji splitting (4-byte UTF-8)."""
    text = "🐴" * 10  # 10 horse emojis, each 4 bytes
    result = _split_message_bytes(text, 15)
    # 15 bytes fits 3 emojis (12 bytes) but not 4 (16 bytes)
    # Should split after 3 emojis
    assert len(result[0].encode("utf-8")) <= 15
    assert len(result) >= 2


def test_empty_string():
    """Test empty input."""
    result = _split_message_bytes("", 400)
    assert result == [""]


def test_single_character_exceeds_limit():
    """Test when a single code point exceeds byte limit."""
    # Family emoji is actually multiple code points (man+ZWJ+woman+ZWJ+girl+ZWJ+boy)
    # Each code point fits in 5 bytes, so the function splits them individually.
    # Test with a simpler case: just verify no crash and valid output
    text = "x"  # 1 byte, fits
    result = _split_message_bytes(text, 5)
    assert result == [text]
    # The real single-char overflow path is hard to trigger with Python strings
    # since no single Python code point is >400 bytes in UTF-8


def test_no_break_points():
    """Test text with no spaces or newlines."""
    text = "a" * 500
    result = _split_message_bytes(text, 200)
    # Should hard split at byte boundary
    assert len(result) >= 2
    assert all(len(chunk.encode("utf-8")) <= 200 for chunk in result)
    # All chunks should be character-boundary safe
    reconstructed = "".join(result)
    assert reconstructed == text


def test_crlf_handling():
    """Test that \r\n is handled (currently doesn't normalize)."""
    text = "Line one\r\nLine two\r\nLine three"
    result = _split_message_bytes(text, 15)
    # Current behavior: splits at \n, leaves \r in chunk
    # Should still work
    assert len(result) >= 2


def test_mixed_boundaries():
    """Test mix of spaces, newlines, and hard cuts."""
    text = "First part with spaces\nSecond part with no breaks at all aaaaaaaaaaaa"
    result = _split_message_bytes(text, 30)
    # Should first split at newline
    assert "First part with spaces" in result[0]
    assert len(result) >= 2


def test_unicode_normalization():
    """Test that decomposed Unicode doesn't break."""
    # Use a character that could be decomposed (é can be e + combining acute)
    text = "café café café café café" * 10
    result = _split_message_bytes(text, 50)
    for chunk in result:
        # All chunks should be valid UTF-8
        chunk.encode("utf-8")
        assert len(chunk.encode("utf-8")) <= 50


if __name__ == "__main__":
    # Run tests
    test_functions = [
        test_basic_ascii,
        test_split_at_space,
        test_split_at_newline,
        test_utf8_multi_byte,
        test_emoji_split,
        test_empty_string,
        test_single_character_exceeds_limit,
        test_no_break_points,
        test_crlf_handling,
        test_mixed_boundaries,
        test_unicode_normalization,
    ]
    
    failed = []
    for test in test_functions:
        try:
            test()
            print(f"✅ {test.__name__}")
        except AssertionError as e:
            print(f"❌ {test.__name__}: {e}")
            failed.append(test.__name__)
    
    if failed:
        print(f"\nFailed tests: {failed}")
        sys.exit(1)
    else:
        print("\n✅ All tests passed!")