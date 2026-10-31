"""Verify the forced-command policy before delegating to rrsync."""

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "source_command", Path(__file__).resolve().parents[1] / "source-command.py"
)
source_command = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source_command)


class SourceCommandTests(unittest.TestCase):
    def invoke(self, command, policy="false"):
        with (
            patch.object(source_command.sys, "argv", ["source-command", policy]),
            patch.dict(os.environ, {"SSH_ORIGINAL_COMMAND": command}, clear=True),
            patch.object(source_command.os, "execv") as execute,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            source_command.main()
            return execute.call_args.args

    def test_default_download_delegates_to_read_only_rrsync(self):
        self.assertEqual(
            self.invoke("rsync --server --sender -vlogDtpre.iLsfxCIvu . ."),
            ("/usr/bin/rrsync", ["/usr/bin/rrsync", "-ro", "/data"]),
        )

    def test_source_removal_requires_enabled_policy_in_rrsync(self):
        command = "rsync --server --sender --remove-source-files -r . ./"
        for policy, mode in (("false", "-ro"), ("true", "-no-lock")):
            with self.subTest(policy=policy):
                self.assertEqual(
                    self.invoke(command, policy),
                    ("/usr/bin/rrsync", ["/usr/bin/rrsync", mode, "/data"]),
                )

    def test_uploads_and_shell_commands_are_rejected_in_both_modes(self):
        commands = (
            "", "sh", "true", "rsync --server -r . ./",
            "rsync --server --sender", "rsync --server\t--sender -r . ./",
            "rsync --server --senderx -r . ./",
            "env rsync --server --sender -r . ./",
            "rsync --server --sender; id",
        )
        for policy in ("false", "true"):
            for command in commands:
                with self.subTest(policy=policy, command=command):
                    with self.assertRaises(SystemExit):
                        self.invoke(command, policy)

    def test_server_side_output_is_rejected_in_both_modes(self):
        options = (
            "--log-file=/tmp/output", "--log-file /tmp/output",
            "--log-file\t/tmp/output", "--only-write-batch=/tmp/output",
            "--only-write-batch /tmp/output", "--only-write-batch\t/tmp/output",
        )
        for policy in ("false", "true"):
            for option in options:
                with self.subTest(policy=policy, option=option):
                    with self.assertRaises(SystemExit):
                        self.invoke(f"rsync --server --sender {option} -r . ./", policy)

    def test_special_file_names_are_left_for_rrsync_validation(self):
        for name in ("./--log-file", "space\\ name", "nested/file", "../outside"):
            with self.subTest(name=name):
                self.invoke(f"rsync --server --sender -r . {name}")

    def test_dot_option_value_cannot_hide_server_side_output(self):
        for policy in ("false", "true"):
            for option in ("--log-file=/tmp/output", "--only-write-batch=/tmp/output"):
                with self.subTest(policy=policy, option=option):
                    with self.assertRaises(SystemExit):
                        self.invoke(f"rsync --server --sender --suffix . {option} -r . ./", policy)

    def test_invalid_policy_is_rejected(self):
        for policy in ("", "TRUE", "1", "false; id"):
            with self.subTest(policy=policy):
                with self.assertRaises(SystemExit):
                    self.invoke("rsync --server --sender -r . ./", policy)


if __name__ == "__main__":
    unittest.main()
