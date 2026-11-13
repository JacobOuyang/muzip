"""The SMS channel (evac/sms.py) offline: no Twilio credentials, so replies land in sms.OUTBOX; the router is replaced
by a scripted one that records what it was given."""
import os
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from evac import codes, router, sms, store  # noqa: E402

WHO = "+15550100"


class SMSTest(unittest.TestCase):
    def setUp(self):
        for k in ("TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN", "SMS_FROM"):
            os.environ.pop(k, None)
        store.use(tempfile.mkdtemp())
        sms.OUTBOX.clear()
        sms._pending.clear()
        self.got = []
        self.reply = "Not sure yet: I need a closer look at the label.\nZOOM ab 10 20 30 40 C"
        self._handle = router.handle
        router.handle = lambda message, who=None, **kw: (self.got.append((message, who)), {"text": self.reply})[1]

    def tearDown(self):
        router.handle = self._handle

    def photo(self):
        return codes.parts("P", bytes(range(256)) * 2, "ab")  # 4 parts

    def test_parts_in_several_texts_reach_the_router_as_one_message(self):
        parts = self.photo()
        self.assertIsNone(sms.take(WHO, "Is this ibuprofen?\n" + "\n".join(parts[:2])))
        self.assertEqual(self.got, [])  # still waiting for parts 3 and 4
        sms.take(WHO, "\n".join(parts[2:]))
        self.assertEqual(len(self.got), 1)
        message, who = self.got[0]
        self.assertEqual(who, WHO)
        self.assertIn("Is this ibuprofen?", message)
        self.assertEqual(codes.decode(message)["complete"][0]["data"], bytes(range(256)) * 2)

    def test_first_reply_has_the_brand_and_the_stop_line_before_the_zoom(self):
        sms.take(WHO, "Is this ibuprofen?\n" + "\n".join(self.photo()))
        body = sms.OUTBOX[-1]["body"]
        self.assertTrue(body.startswith("MuZip: Not sure yet"))
        self.assertIn("the label. Reply STOP to opt out.\nZOOM ab 10 20 30 40 C", body)

    def test_later_replies_have_no_stop_line(self):
        self.reply = "Yes, it is ibuprofen 200 mg."
        z = codes.parts("Z", codes.zoom_head("ab", [10, 20, 30, 40]) + b"webp", "az")
        sms.take(WHO, "\n".join(z))
        self.assertEqual(sms.OUTBOX[-1]["body"], "MuZip: Yes, it is ibuprofen 200 mg.")

    def test_missing_parts_are_asked_for_again(self):
        sms.WAIT, wait = 0.05, sms.WAIT
        try:
            parts = self.photo()
            sms.take(WHO, "Is this ibuprofen?\n" + "\n".join(parts[:1] + parts[2:]))
            time.sleep(0.3)
        finally:
            sms.WAIT = wait
        self.assertEqual(self.got, [])
        self.assertIn("RESEND ab 2", sms.OUTBOX[-1]["body"])

    def test_a_plain_question_is_answered_at_once(self):
        self.reply = "It's 4 pm."
        sms.take(WHO, "What time is it in Tokyo?")
        self.assertEqual(self.got[0][0], "What time is it in Tokyo?")
        self.assertEqual(sms.OUTBOX[-1]["body"], "MuZip: It's 4 pm. Reply STOP to opt out.")


if __name__ == "__main__":
    unittest.main()
