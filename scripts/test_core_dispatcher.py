import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class CoreDispatcherTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        java_home = os.environ.get('JAVA_HOME')
        cls.java = str(Path(java_home) / 'bin/java') if java_home else shutil.which('java')
        javac = str(Path(java_home) / 'bin/javac') if java_home else shutil.which('javac')
        if not cls.java or not javac:
            raise AssertionError('JDK 17 is required for core dispatch checks')
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        source = Path(__file__).resolve().parents[1] / 'packages/guoguo_core/android/src/main/kotlin/com/maxduke/guoguo_core/ProviderCallDispatcher.java'
        harness = cls.directory / 'DispatcherTest.java'
        harness.write_text('''
package com.maxduke.guoguo_core;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

public class DispatcherTest {
    static void check(boolean ok, String reason) {
        if (!ok) throw new AssertionError(reason);
    }
    static void await(CountDownLatch latch) throws Exception {
        check(latch.await(3, TimeUnit.SECONDS), "dispatch did not complete");
    }
    static class Reply implements ProviderCallDispatcher.Result {
        final CountDownLatch done = new CountDownLatch(1);
        final AtomicInteger calls = new AtomicInteger();
        volatile Object value;
        volatile Exception error;
        public void success(Object value) { this.value = value; calls.incrementAndGet(); done.countDown(); }
        public void failure(Exception error) { this.error = error; calls.incrementAndGet(); done.countDown(); }
    }
    static CountDownLatch blockProviders(ProviderCallDispatcher dispatcher) throws Exception {
        CountDownLatch started = new CountDownLatch(3), release = new CountDownLatch(1);
        for (int i = 0; i < 3; i++) dispatcher.execute(false, 75000, remaining -> {
            started.countDown(); release.await(); return null;
        }, new Reply());
        await(started);
        return release;
    }
    public static void main(String[] args) throws Exception {
        AtomicLong clock = new AtomicLong();
        try (ProviderCallDispatcher dispatcher = new ProviderCallDispatcher(
                args[0].equals("budget") ? clock::get : System::nanoTime)) {
            CountDownLatch release = blockProviders(dispatcher);
            if (args[0].equals("control")) {
                Reply reply = new Reply();
                dispatcher.execute(true, 5000, remaining -> "canceled", reply);
                await(reply.done);
                check("canceled".equals(reply.value) && reply.calls.get() == 1,
                        "control was blocked by provider IO");
            } else if (args[0].equals("timeout")) {
                AtomicBoolean ran = new AtomicBoolean();
                Reply reply = new Reply();
                dispatcher.execute(false, 100, remaining -> { ran.set(true); return null; }, reply);
                await(reply.done);
                check(reply.error instanceof TimeoutException, "queued deadline not reported");
                release.countDown();
                Reply drained = new Reply();
                dispatcher.execute(false, 5000, remaining -> null, drained);
                await(drained.done);
                check(!ran.get() && reply.calls.get() == 1, "expired work ran or replied twice");
            } else if (args[0].equals("budget")) {
                Reply reply = new Reply();
                dispatcher.execute(false, 1000, remaining -> remaining, reply);
                clock.set(TimeUnit.MILLISECONDS.toNanos(500));
                release.countDown();
                await(reply.done);
                check(Integer.valueOf(500).equals(reply.value), "queue wait did not consume budget");
            } else if (args[0].equals("capacity")) {
                for (int i = 0; i < 32; i++) dispatcher.execute(false, 75000, remaining -> null, new Reply());
                Reply rejected = new Reply();
                dispatcher.execute(false, 75000, remaining -> null, rejected);
                await(rejected.done);
                check(rejected.error instanceof RejectedExecutionException, "unbounded provider queue");
                Reply control = new Reply();
                dispatcher.execute(true, 5000, remaining -> null, control);
                await(control.done);
                check(control.error == null, "full provider queue blocked control");
                dispatcher.close();
                try (ProviderCallDispatcher nextEngine = new ProviderCallDispatcher()) {
                    Reply next = new Reply();
                    nextEngine.execute(false, 5000, remaining -> "next engine", next);
                    await(next.done);
                    check("next engine".equals(next.value), "closing one engine affected another");
                }
            } else throw new AssertionError("unknown case");
            release.countDown();
        }
    }
}
''')
        compiled = subprocess.run([javac, '--release', '17', '-d', str(cls.directory), str(source), str(harness)],
                                  capture_output=True, text=True)
        if compiled.returncode:
            raise AssertionError(compiled.stderr)

    def run_case(self, name):
        result = subprocess.run([self.java, '-cp', str(self.directory),
                                 'com.maxduke.guoguo_core.DispatcherTest', name],
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_control_bypasses_three_blocked_providers(self):
        self.run_case('control')

    def test_queued_deadline_removes_expired_work_and_replies_once(self):
        self.run_case('timeout')

    def test_dispatch_wait_consumes_core_budget(self):
        self.run_case('budget')

    def test_queue_bound_and_engine_isolation(self):
        self.run_case('capacity')
