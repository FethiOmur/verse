"""Secret and audio checks (a fake key, temp files, no Keychain)."""

import time
import wave

import checks

FAKE = "fake-key-9f8e7d6c5b4a"


def test_exact_key_is_found_without_being_returned(tmp_path):
    (tmp_path / "a.log").write_text("all good\n")
    (tmp_path / "b.log").write_text(f"oops {FAKE} leaked\n")
    res = checks.scan_for_secrets([tmp_path], FAKE)
    assert res["exact_key_hits"] == 1 and res["pass"] is False and res["files_scanned"] == 2
    assert FAKE not in str(res)                                   # only counts leave the module


def test_clean_folder_passes_and_key_shapes_are_caught(tmp_path):
    (tmp_path / "a.log").write_text("nothing here\n")
    assert checks.scan_for_secrets([tmp_path], FAKE)["pass"] is True
    (tmp_path / "c.log").write_text("token " + "sk-" + "ant-api03-abcdefghijklmnop\n")
    res = checks.scan_for_secrets([tmp_path], FAKE)
    assert res["key_shaped_hits"] == 1 and res["pass"] is False


def test_missing_key_is_not_a_pass(tmp_path):
    assert checks.scan_for_secrets([tmp_path], None)["pass"] is False   # cannot claim "no leak" without the key to compare


def test_audio_watch_sees_a_wav_but_not_a_log(tmp_path):
    w = checks.AudioWatch([tmp_path], interval=0.02)
    w.start()
    (tmp_path / "x.log").write_text("hello")
    time.sleep(0.1)
    with wave.open(str(tmp_path / "leak.dat"), "wb") as f:      # wrong extension on purpose: found by its magic bytes
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(16000)
        f.writeframes(b"\0\0" * 160)
    time.sleep(0.2)
    res = w.stop()
    assert res["pass"] is False and res["audio_files_found"] == [str(tmp_path / "leak.dat")]


def test_audio_watch_clean(tmp_path):
    w = checks.AudioWatch([tmp_path], interval=0.02)
    w.start()
    (tmp_path / "notes.txt").write_text("text only")
    time.sleep(0.1)
    assert w.stop()["pass"] is True
