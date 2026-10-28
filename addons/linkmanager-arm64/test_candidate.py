"""Small offline checks of the binary-patch safety boundary; no Windows execution."""
import hashlib
from pathlib import Path
import struct
import unittest
from prepare_candidate import ROOT, INPUTS, IDENTITY_SLOTS, IDENTITY_VALUES, patch


class CandidateChecks(unittest.TestCase):
    def test_patched_data_and_executable_sections(self):
        for name, (expected, offsets) in INPUTS.items():
            original = (ROOT/'artifacts/x64'/name).read_bytes()
            changed, _ = patch(original, expected, offsets)
            self.assertEqual(len(original), len(changed))
            for offset in offsets:
                self.assertEqual(changed[offset:offset+8], b'tap0901\0')
            for offset, (_, value) in zip(IDENTITY_SLOTS[expected], IDENTITY_VALUES):
                self.assertEqual(changed[offset:offset+24].split(b'\0')[0], value)
            pe = int.from_bytes(original[60:64], 'little')
            sections = pe+24+int.from_bytes(original[pe+20:pe+22], 'little')
            for i in range(int.from_bytes(original[pe+6:pe+8], 'little')):
                h = sections+40*i
                flags = int.from_bytes(original[h+36:h+40], 'little')
                size, start = struct.unpack_from('<II', original, h+16)
                if flags & 0x20000000:  # independent check of EVERY executable section
                    self.assertEqual(original[start:start+size], changed[start:start+size])
            self.assertEqual(hashlib.sha256((ROOT/'artifacts/x64'/name).read_bytes()).hexdigest(), expected)

    def test_reject_changed_input(self):
        for name, (expected, offsets) in INPUTS.items():
            data = bytearray((ROOT/'artifacts/x64'/name).read_bytes())
            data[offsets[0]] ^= 1
            with self.assertRaisesRegex(ValueError, 'Unknown LinkManager'):
                patch(data, expected, offsets)

    def test_reject_wrong_slot_even_with_matching_hash(self):
        name, (_, offsets) = next(iter(INPUTS.items()))
        data = bytearray((ROOT/'artifacts/x64'/name).read_bytes())
        data[offsets[0]+7] = 1
        with self.assertRaisesRegex(ValueError, 'slot changed'):
            patch(data, hashlib.sha256(data).hexdigest(), offsets)


if __name__ == '__main__':
    unittest.main()
