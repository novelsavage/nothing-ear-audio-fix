import hashlib
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('compat', ROOT / 'nothing-ear-loopback-compat.py')
compat = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(compat)
ADDRESS = 'AA:BB:CC:DD:EE:FF'
# Minimal executable Lua fixture: exercise the real insertion points and ordering.
VENDOR = '''
function createNode(dev_props, factory)
  local properties = {}
  local name = "vendor-name"
  properties["node.name"] = name:gsub("([^%w_%-%.])", "_")
  return properties["node.name"]
end
function checkProfiles(props)
  local spa_device = {get_managed_object=function() sink_calls=sink_calls+1 end}
  source_calls=source_calls+1
  local sink_loopback = spa_device:get_managed_object (LOOPBACK_SINK_ID)
end
'''


class CompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.source = Path(self.directory.name) / 'vendor.lua'
        self.target = Path(self.directory.name) / 'scripts/monitors/bluez.lua'
        self.source.write_text(VENDOR)
        hashes = {hashlib.sha256(VENDOR.encode()).hexdigest()}
        self.hash_patch = patch.object(compat, 'SUPPORTED_HASHES', hashes)
        self.hash_patch.start()
        self.addCleanup(self.hash_patch.stop)

    def prepare(self):
        return compat.prepare(self.source, self.target, ADDRESS)

    def test_address_validation(self):
        self.assertEqual(compat.validate_address(ADDRESS.lower()), ADDRESS)
        for value in ['', 'invalid', ADDRESS + '\n', 'AA:BB:CC:DD:EE:FF";evil()']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                compat.validate_address(value)

    def test_generate_and_idempotency(self):
        self.assertTrue(self.prepare())
        initial = self.target.stat().st_mtime_ns
        self.assertTrue(compat.inspect(self.source, self.target, ADDRESS)['current'])
        self.assertFalse(self.prepare())
        self.assertEqual(self.target.stat().st_mtime_ns, initial)
        self.assertEqual(self.source.read_text(), VENDOR)

    def test_source_update_retires_override(self):
        self.prepare()
        self.source.write_text(VENDOR + '-- vendor update\n')
        self.prepare()
        self.assertFalse(self.target.exists())

    def test_missing_source_retires_override(self):
        self.prepare()
        self.source.unlink()
        self.prepare()
        self.assertFalse(self.target.exists())

    def test_unknown_source_does_not_create_override(self):
        self.source.write_text('unknown source')
        self.prepare()
        self.assertFalse(self.target.exists())

    def test_unrelated_override_is_preserved(self):
        self.target.parent.mkdir(parents=True)
        self.target.write_text('-- user configuration\n')
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual(self.target.read_text(), '-- user configuration\n')

    def test_symlink_is_never_overwritten(self):
        self.target.parent.mkdir(parents=True)
        original = Path(self.directory.name) / 'user.lua'
        original.write_text(compat.MARKER)
        self.target.symlink_to(original)
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertTrue(self.target.is_symlink())
        self.assertEqual(original.read_text(), compat.MARKER)

    def test_status_is_read_only(self):
        status = compat.inspect(self.source, self.target, ADDRESS)
        self.assertTrue(status['vendor_supported'])
        self.assertFalse(status['current'])
        self.assertFalse(self.target.parent.exists())

    def test_wrong_structure_is_rejected(self):
        with self.assertRaises(ValueError):
            compat.build_script(VENDOR.replace('  local sink_loopback', '  local other'), ADDRESS)

    def test_device_scope_and_microphone_behavior_in_lua(self):
        lua = shutil.which('lua5.4') or shutil.which('lua')
        self.prepare()
        assertions = '''
source_calls=0; sink_calls=0
checkProfiles({["api.bluez5.address"]="AA:BB:CC:DD:EE:FF"})
assert(source_calls==1 and sink_calls==0)
checkProfiles({["api.bluez5.address"]="11:22:33:44:55:66"})
assert(source_calls==2 and sink_calls==1)
assert(createNode({["api.bluez5.address"]="AA:BB:CC:DD:EE:FF"}, "api.bluez5.a2dp.sink")=="bluez_output.AA:BB:CC:DD:EE:FF")
assert(createNode({["api.bluez5.address"]="AA:BB:CC:DD:EE:FF"}, "api.bluez5.sco.sink")=="bluez_output.AA:BB:CC:DD:EE:FF")
assert(createNode({["api.bluez5.address"]="AA:BB:CC:DD:EE:FF"}, "api.bluez5.sco.source")=="vendor-name")
assert(createNode({["api.bluez5.address"]="11:22:33:44:55:66"}, "api.bluez5.a2dp.sink")=="vendor-name")
'''
        program = Path(self.directory.name) / 'test.lua'
        program.write_text(self.target.read_text() + assertions)
        if lua:
            subprocess.run([lua, str(program)], check=True)
        else:
            # Desktop installations often ship liblua for WirePlumber without
            # the standalone interpreter. Execute the same assertions there.
            import ctypes
            import ctypes.util
            library = ctypes.util.find_library('lua5.4')
            if not library:
                self.skipTest('Lua 5.4 runtime not installed')
            runtime = ctypes.CDLL(library)
            runtime.luaL_newstate.restype = ctypes.c_void_p
            runtime.luaL_openlibs.argtypes = [ctypes.c_void_p]
            runtime.luaL_loadfilex.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
            runtime.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
                                         ctypes.c_int, ctypes.c_ssize_t, ctypes.c_void_p]
            runtime.lua_close.argtypes = [ctypes.c_void_p]
            state = runtime.luaL_newstate()
            self.assertTrue(state)
            try:
                runtime.luaL_openlibs(state)
                self.assertEqual(runtime.luaL_loadfilex(state, str(program).encode(), None), 0)
                self.assertEqual(runtime.lua_pcallk(state, 0, 0, 0, 0, None), 0)
            finally:
                runtime.lua_close(state)


if __name__ == '__main__':
    unittest.main()
