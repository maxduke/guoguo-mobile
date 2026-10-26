import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class AndroidRendererTest(unittest.TestCase):
    def test_television_policy_changes_only_renderer_and_preserves_phone_flags(self):
        root = Path(__file__).resolve().parents[1]
        source = root / 'android/app/src/main/java/com/maxduke/guoguo_mobile/TelevisionRendererPolicy.java'
        java_home = os.environ.get('JAVA_HOME')
        javac = str(Path(java_home) / 'bin/javac') if java_home else shutil.which('javac')
        java = str(Path(java_home) / 'bin/java') if java_home else shutil.which('java')
        self.assertTrue(javac and java, 'JDK 17 is required for Android renderer policy checks')
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            harness = directory / 'RendererPolicyTest.java'
            harness.write_text('''
import java.util.Arrays;
import com.maxduke.guoguo_mobile.TelevisionRendererPolicy;
public class RendererPolicyTest {
    private static void equal(String[] expected, String[] actual) {
        if (!Arrays.equals(expected, actual))
            throw new AssertionError(Arrays.toString(actual));
    }
    public static void main(String[] args) {
        String[] phone = {"--trace-startup", "--enable-impeller=true"};
        equal(phone, TelevisionRendererPolicy.arguments(phone, false));
        equal(new String[]{"--enable-impeller=false"},
            TelevisionRendererPolicy.arguments(new String[]{}, true));
        equal(new String[]{"--trace-startup", "--enable-impeller=false"},
            TelevisionRendererPolicy.arguments(phone, true));
        equal(new String[]{"--trace-startup", "--enable-impeller=false"},
            TelevisionRendererPolicy.arguments(new String[]{"--enable-impeller", "--trace-startup",
                "--enable-impeller=true", "--enable-impeller=false"}, true));
        equal(new String[]{"--trace-startup", "--enable-impeller=true"}, phone);
    }
}
''')
            subprocess.run([javac, '--release', '17', '-d', str(directory), str(source), str(harness)],
                           check=True, capture_output=True, text=True)
            subprocess.run([java, '-cp', str(directory), 'RendererPolicyTest'],
                           check=True, capture_output=True, text=True)


if __name__ == '__main__':
    unittest.main()
