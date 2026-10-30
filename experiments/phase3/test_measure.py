import unittest
from unittest.mock import patch

import measure


def row(command, cpu='0', state='S'):
    return {'pid': '123', 'cpu': cpu, 'state': state, 'command': command}


class LoadGateTests(unittest.TestCase):
    def gate(self, rows):
        with patch.object(measure, 'processes', return_value=rows):
            return measure.load_gate()

    def test_idle(self):
        self.assertTrue(self.gate([])['passed'])

    def test_cpu_limits(self):
        self.assertTrue(self.gate([row('/app', '100')] * 4)['passed'])
        self.assertFalse(self.gate([row('/app', '100.1')])['passed'])
        self.assertFalse(self.gate([row('/app', '90')] * 5)['passed'])

    def test_simulator(self):
        app = '/CoreSimulator/Devices/test/Pinecone.app/Pinecone'
        self.assertFalse(self.gate([row(app)])['passed'])
        self.assertTrue(self.gate([row(app, '200', 'T')])['passed'])

    def test_low_cpu_builds_and_tests_are_rejected(self):
        for command in ('/bin/clang', '/bin/clang++', '/bin/swift-frontend',
                        '/bin/swiftc', '/bin/swift-build', '/bin/swift-test',
                        '/bin/xcodebuild', '/bin/ld', '/bin/ld64.lld',
                        '/tmp/pinecone-phase6/test',
                        '/private/tmp/pinecone-phase6/test-enabled',
                        '/build/Suite.xctest/Contents/MacOS/Suite'):
            with self.subTest(command=command):
                result = self.gate([row(command)])
                self.assertFalse(result['passed'])
                self.assertEqual(len(result['competing_work']), 1)

    def test_suspended_competing_work(self):
        self.assertTrue(self.gate([row('/bin/clang', '150', 'T')])['passed'])

    def test_unrelated_tools_are_not_misclassified(self):
        self.assertTrue(self.gate([row('/bin/test'), row('/app/Xcode')])['passed'])


if __name__ == '__main__':
    unittest.main()
