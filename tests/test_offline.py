"""Offline checks: every network command is replaced; all state stays in temp files."""

import copy
import json
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = json.loads((ROOT / "config.example.json").read_text())

# This mock has no fallback to system commands. Unsupported calls fail closed.
MOCK = r'''
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["WIFI_TEST_DIR"])
state_path = root / "state.json"
state = json.loads(state_path.read_text())
tool, args = Path(sys.argv[0]).name, sys.argv[1:]
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps([tool, *args]) + "\n")
if tool == "ifconfig":
    assert args == ["en9"], args
    print("en9: flags=0\n\tstatus: " + state["link"])
elif tool == "sleep":
    assert args == ["1"], args
elif tool == "networksetup":
    command = args[0]
    if command == "-listnetworkserviceorder":
        print("(1) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en9)")
    else:
        assert args[1] == "Wi-Fi", args
        if command == "-getinfo":
            print("DHCP Configuration" if state["mode"] == "auto" else "Manual Configuration")
            for label, key in [("IP address", "ip"), ("Subnet mask", "subnetMask"), ("Router", "router")]:
                print(label + ": " + state[key])
            print("IPv6: " + state["ipv6"])
        elif command == "-getdnsservers":
            print("\n".join(state["dns"]) if state["dns"] else "There aren't any DNS Servers set on Wi-Fi.")
        elif command == "-setdhcp":
            state["mode"] = "auto"
        elif command == "-setmanual":
            state.update(mode="manual", ip=args[2], subnetMask=args[3], router=args[4])
        elif command == "-setdnsservers":
            state["dns"] = [] if args[2:] == ["empty"] else args[2:]
        elif command == "-setv6automatic":
            state["ipv6"] = "Automatic"
        else:
            raise AssertionError("Unexpected mock command: " + repr(args))
    state_path.write_text(json.dumps(state))
else:
    raise AssertionError("Unexpected mock tool: " + tool)
'''


@unittest.skipUnless(sys.platform == "darwin", "Requires macOS plutil and lockf")
class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wifi-offline-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.config_dir = self.directory / "configuration"
        self.config_dir.mkdir()
        self.write_config(copy.deepcopy(EXAMPLE))
        self.state_path = self.directory / "state.json"
        self.state_path.write_text(json.dumps({
            "link": "active", "mode": "auto", "ip": "192.0.2.70",
            "subnetMask": "255.255.255.0", "router": "192.0.2.1",
            "dns": [], "ipv6": "Automatic",
        }))
        self.env = dict(os.environ, WIFI_TEST_DIR=str(self.directory))
        replacements = {"/usr/bin/id -u": "/usr/bin/printf 0"}
        for system_path in ("/usr/sbin/networksetup", "/sbin/ifconfig", "/bin/sleep"):
            mock = self.directory / Path(system_path).name
            mock.write_text("#!" + sys.executable + "\n" + MOCK)
            mock.chmod(0o700)
            replacements[system_path] = shlex.quote(str(mock))
        self.scripts = {}
        for source in (ROOT / "shell").glob("*.sh"):
            content = source.read_text()
            for old, new in replacements.items():
                content = content.replace(old, new)
            for unsafe in ("/usr/sbin/networksetup", "/sbin/ifconfig", "/Users/Shared/", "/usr/bin/shortcuts"):
                self.assertNotIn(unsafe, content, "Refusing an unmocked or shared-path script")
            script = self.directory / source.name
            script.write_text(content)
            self.scripts[source.stem] = script

    def write_config(self, value):
        (self.config_dir / "config.json").write_text(json.dumps(value))

    def change_state(self, **changes):
        state = self.state()
        state.update(changes)
        self.state_path.write_text(json.dumps(state))

    def state(self):
        return json.loads(self.state_path.read_text())

    def calls(self):
        log = self.directory / "calls.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def writes(self):
        return [call for call in self.calls() if call[0] == "networksetup" and call[1].startswith("-set")]

    def run_phase(self, phase, *args, success=True):
        result = subprocess.run(
            ["/bin/sh", str(self.scripts[phase]), *map(str, args)],
            env=self.env, capture_output=True, text=True, timeout=15,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def prepare(self):
        return self.run_phase("prepare", self.config_dir).stdout.rstrip("\n")

    def reconcile(self, ssid):
        context = self.prepare()
        link = self.run_phase("probe-first", context, 1).stdout
        self.assertEqual(link, "CONNECTED" if ssid else "DISCONNECTED")
        target = self.run_phase("apply", context, ssid).stdout.rstrip("\n")
        self.assertTrue(target.startswith("WIFI_TARGET_V2\n"), target)
        self.assertEqual(self.run_phase("probe", target).stdout, link)
        verified = self.run_phase("verify", target, ssid).stdout
        return target, verified

    def test_home_manual_and_disconnect_vpn(self):
        target, result = self.reconcile("Home-Example")
        self.assertEqual(self.state()["ip"], "192.0.2.20")
        self.assertEqual(self.state()["dns"], ["192.0.2.1"])
        self.assertEqual(result, "APPLY_SHADOWROCKET")
        self.assertEqual(self.run_phase("vpn-gate", target).stdout, "DISCONNECT_SHADOWROCKET")
        self.assertEqual([c[1] for c in self.writes()], ["-setmanual", "-setdnsservers"])
        self.assertFalse(any(c[0] == "sleep" for c in self.calls()))

    def test_office_auto_and_connect_vpn(self):
        self.change_state(mode="manual", dns=["192.0.2.1"], ipv6="Off")
        target, result = self.reconcile("Office-Example")
        self.assertEqual(self.state()["mode"], "auto")
        self.assertEqual(self.state()["dns"], [])
        self.assertEqual(self.state()["ipv6"], "Automatic")
        self.assertEqual(result, "APPLY_SHADOWROCKET")
        self.assertEqual(self.run_phase("vpn-gate", target).stdout, "CONNECT_SHADOWROCKET")

    def test_unknown_network_uses_default_join(self):
        self.change_state(mode="manual", dns=["192.0.2.1"])
        _, result = self.reconcile("Cafe-Example")
        self.assertIn("profile=default.join mode=auto verified=yes vpn=keep", result)
        self.assertEqual(self.state()["mode"], "auto")
        self.assertEqual(self.state()["dns"], [])

    def test_disconnected_uses_global_auto_and_one_wait(self):
        self.change_state(link="inactive", mode="manual", dns=["192.0.2.1"])
        _, result = self.reconcile("")
        self.assertIn("event=disconnect profile=default.disconnect mode=auto", result)
        self.assertEqual([c for c in self.calls() if c[0] == "sleep"], [["sleep", "1"]])

    def test_matching_settings_are_not_rewritten(self):
        _, result = self.reconcile("Cafe-Example")
        self.assertIn("verified=yes vpn=keep", result)
        self.assertEqual(self.writes(), [])

    def test_invalid_manual_address_stops_before_write(self):
        config = copy.deepcopy(EXAMPLE)
        config["networks"][0]["join"]["ip"] = "192.0.2.999"
        self.write_config(config)
        context = self.prepare()
        result = self.run_phase("apply", context, "Home-Example", success=False)
        self.assertIn("Invalid IPv4", result.stderr)
        self.assertEqual(self.writes(), [])

    def test_new_registration_cancels_older_task(self):
        older = self.prepare()
        newer = self.prepare()
        self.assertNotEqual(older, newer)
        self.assertEqual(self.run_phase("probe-first", older, 1).stdout, "STALE")
        self.assertEqual(self.run_phase("apply", older, "Home-Example").stdout, "STALE")
        self.assertEqual(self.run_phase("final-error", older).stdout, "STALE")
        self.assertEqual(self.writes(), [])

    def test_vpn_gate_cancels_when_superseded_after_verification(self):
        target, result = self.reconcile("Office-Example")
        self.assertEqual(result, "APPLY_SHADOWROCKET")
        self.prepare()
        self.assertEqual(self.run_phase("vpn-gate", target).stdout, "STALE")

    def test_ssid_change_requires_reselection_before_vpn(self):
        target, _ = self.reconcile("Home-Example")
        self.assertEqual(self.run_phase("verify", target, "Office-Example").stdout, "RETRY")

    def test_config_is_a_snapshot_for_this_invocation(self):
        context = self.prepare()
        (self.config_dir / "config.json").write_text("invalid JSON")
        target = self.run_phase("apply", context, "Home-Example").stdout.rstrip("\n")
        self.assertEqual(self.run_phase("verify", target, "Home-Example").stdout, "APPLY_SHADOWROCKET")

    def test_current_task_reports_exhaustion(self):
        result = self.run_phase("final-error", self.prepare(), success=False)
        self.assertIn("No VPN action was performed", result.stderr)


@unittest.skipUnless(sys.platform == "darwin", "Source builder uses macOS plutil")
class PackageTests(unittest.TestCase):
    def test_build_injects_sources_without_config_or_triggers(self):
        result = subprocess.run(["/bin/sh", "tools/build.sh"], cwd=ROOT, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = json.loads((ROOT / "shortcut/workflow.json").read_text())
        for line in (ROOT / "shortcut/scripts.txt").read_text().splitlines():
            index, relative = line.split()
            params = expected["WFWorkflowActions"][int(index)]["WFWorkflowActionParameters"]
            params["Script"] = (ROOT / relative).read_text().rstrip("\n")
        built = plistlib.loads((ROOT / "dist/WiFi-Switch.unsigned.shortcut").read_bytes())
        self.assertEqual(built, expected)
        self.assertEqual(built["WFWorkflowTriggers"], [])
        self.assertNotIn("__SOURCE__:", str(built))
        self.assertNotIn("Home-Example", str(built))

    def test_action_links_and_control_flow_are_complete(self):
        workflow = json.loads((ROOT / "shortcut/workflow.json").read_text())
        actions = workflow["WFWorkflowActions"]
        seen, stack = set(), []

        def references(value):
            if isinstance(value, dict):
                for key, item in value.items():
                    if key == "OutputUUID":
                        yield item
                    else:
                        yield from references(item)
            elif isinstance(value, list):
                for item in value:
                    yield from references(item)

        for action in actions:
            params = action["WFWorkflowActionParameters"]
            for reference in references(params):
                self.assertIn(reference, seen, "Missing or forward magic-variable reference")
            if "UUID" in params:
                self.assertNotIn(params["UUID"], seen)
                seen.add(params["UUID"])
            mode = params.get("WFControlFlowMode")
            if mode == 0:
                stack.append(params["GroupingIdentifier"])
            elif mode == 1:
                self.assertEqual(stack[-1], params["GroupingIdentifier"])
            elif mode == 2:
                self.assertEqual(stack.pop(), params["GroupingIdentifier"])
            if action["WFWorkflowActionIdentifier"] == "is.workflow.actions.runshellscript":
                self.assertEqual((params["Shell"], params["InputMode"], params["RunAsRoot"]), ("/bin/sh", "as arguments", True))
        self.assertEqual(stack, [])

    def test_install_creates_private_example_and_preserves_existing_file(self):
        with tempfile.TemporaryDirectory(prefix="wifi-install-test-") as temporary:
            destination = Path(temporary) / "configuration"
            command = ["/bin/sh", str(ROOT / "tools/install-config.sh"), str(destination)]
            subprocess.run(command, check=True, capture_output=True, timeout=15)
            config = destination / "config.json"
            self.assertEqual(json.loads(config.read_text()), EXAMPLE)
            self.assertEqual(destination.stat().st_mode & 0o777, 0o700)
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)
            config.write_text('{"keep": "existing file"}\n')
            subprocess.run(command, check=True, capture_output=True, timeout=15)
            self.assertEqual(config.read_text(), '{"keep": "existing file"}\n')
            self.assertEqual(list(destination.iterdir()), [config])


if __name__ == "__main__":
    unittest.main()
