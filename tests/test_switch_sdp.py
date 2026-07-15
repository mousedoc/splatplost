import importlib.util
import hashlib
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
GENERATOR = ROOT / "native" / "windows_bluetooth" / "generate_switch_sdp.py"
XML = ROOT / "native" / "windows_bluetooth" / "switch-controller.xml"

spec = importlib.util.spec_from_file_location("generate_switch_sdp", GENERATOR)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SwitchSdpTests(unittest.TestCase):
    def test_record_contains_hid_service_and_both_psms(self):
        record = module.encode_record(XML)
        self.assertIn(bytes.fromhex("191124"), record)
        self.assertIn(bytes.fromhex("190100090011"), record)
        self.assertIn(bytes.fromhex("190100090013"), record)
        self.assertIn(b"Nintendo", record)
        self.assertGreater(len(record), 200)

    def test_record_is_a_length_delimited_sequence(self):
        record = module.encode_record(XML)
        self.assertEqual(record[0], 0x36)
        self.assertEqual(int.from_bytes(record[1:3], "big"), len(record) - 3)

    def test_record_matches_the_pinned_nxbt_pro_controller_identity(self):
        # This digest is the 376-byte binary SDP record encoded from
        # Brikwerk/nxbt's switch-controller.xml compatibility reference.
        record = module.encode_record(XML)
        self.assertEqual(len(record), 376)
        self.assertEqual(
            hashlib.sha256(record).hexdigest(),
            "c5ba4d316fb1dbc16dda6846588683436f8fc376c8aa1cc6a0ac62df3df8f022",
        )


if __name__ == "__main__":
    unittest.main()
