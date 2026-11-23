import asyncio
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
try:
    from PySide6.QtCore import QEvent, QPoint, QPointF, QRect, QSettings, QSize, Qt
    from PySide6.QtGui import QMouseEvent
    from PySide6.QtTest import QTest
    from PySide6.QtWidgets import QApplication
    from voice_control.companion import DesktopCompanion, FRAME_INTERVAL_MS, FRAME_ORDER, visible_position
except ModuleNotFoundError:
    raise unittest.SkipTest('需要现有 PySide6 环境')


class CompanionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.preferences = QSettings(str(Path(self.directory.name) / 'pet.ini'), QSettings.Format.IniFormat)
        self.pet = DesktopCompanion(lambda: 'ready', self.preferences)

    def tearDown(self):
        self.pet.shutdown()
        self.pet.deleteLater()
        self.app.processEvents()
        self.directory.cleanup()

    def test_position_respects_negative_monitors_and_unplugging(self):
        screens = [QRect(-1920, 0, 1920, 1080), QRect(0, 0, 1920, 1080)]
        self.assertEqual(visible_position(QPoint(-1800, 200), screens, QSize(116, 132)), QPoint(-1800, 200))
        restored = visible_position(QPoint(-1800, 200), screens[1:], QSize(116, 132))
        self.assertEqual(restored, QPoint(0, 200))
        self.assertEqual(visible_position(QPoint(3000, 2000), screens, QSize(116, 132)), QPoint(1804, 948))

    def test_click_opens_settings_and_keyboard_is_supported(self):
        requests = []
        self.pet.settings_requested.connect(lambda: requests.append(True))
        QTest.mouseClick(self.pet, Qt.MouseButton.LeftButton, pos=QPoint(58, 58))
        QTest.keyClick(self.pet, Qt.Key.Key_Return)
        self.assertEqual(len(requests), 2)

    def test_drag_does_not_open_settings_and_position_is_saved(self):
        requests = []
        self.pet.settings_requested.connect(lambda: requests.append(True))
        self.pet.move(100, 120)
        QTest.mousePress(self.pet, Qt.MouseButton.LeftButton, pos=QPoint(58, 58))
        event = QMouseEvent(QEvent.Type.MouseMove, QPointF(98, 78),
                            QPointF(self.pet.anchor + QPoint(40, 20)),
                            Qt.MouseButton.NoButton, Qt.MouseButton.LeftButton,
                            Qt.KeyboardModifier.NoModifier)
        self.pet.mouseMoveEvent(event)
        QTest.mouseRelease(self.pet, Qt.MouseButton.LeftButton, pos=QPoint(58, 58))
        self.assertEqual(requests, [])
        self.assertEqual(self.preferences.value('position'), QPoint(140, 140))

    def test_sprite_plays_all_ten_frames_and_pause_freezes_current_frame(self):
        self.assertEqual(len(self.pet.frames), 10)
        self.assertLess(max(frame.height() for frame in self.pet.frames)
                        - min(frame.height() for frame in self.pet.frames), 20)
        self.pet.set_animation(True)
        self.pet.clock = Mock()
        for step, expected in enumerate(FRAME_ORDER):
            self.pet.clock.elapsed.return_value = step * FRAME_INTERVAL_MS
            self.pet.tick()
            self.assertEqual(self.pet.frame_index, expected)
        self.pet.set_animation(False)
        frozen = self.pet.frame_index
        self.pet.clock.elapsed.return_value = 99999
        self.pet.tick()
        self.assertEqual(self.pet.frame_index, frozen)

    def test_animation_can_be_paused_and_all_states_render(self):
        self.pet.set_animation(False)
        self.assertFalse(self.preferences.value('animation_enabled', type=bool))
        for state in ('idle', 'ready', 'listening', 'thinking'):
            self.pet.state = lambda value=state: value
            self.pet.tick()
            image = self.pet.grab()
            self.assertFalse(image.isNull())


class CompanionLifecycleTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    async def test_controller_hides_to_companion_and_client_still_exits(self):
        from voice_control.app import Window
        from voice_control.config import default_config, save
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            preferences = QSettings(str(base / 'pet.ini'), QSettings.Format.IniFormat)
            with patch('voice_control.app.DesktopCompanion', side_effect=lambda state: DesktopCompanion(state, preferences)):
                for role in ('controller', 'client'):
                    path = base / (role + '.json')
                    save(path, default_config(role), role)
                    window = Window(role, path)
                    try:
                        window.show()
                        self.app.processEvents()
                        if role == 'controller':
                            window.companion.show()
                            window.close()
                            self.assertFalse(window.isVisible())
                            self.assertTrue(window.companion.isVisible())
                            self.assertFalse(window.closed.is_set())
                            window.companion.settings_requested.emit()
                            self.assertTrue(window.isVisible())
                            self.assertEqual(window.tabs.currentIndex(), 1)
                            window.companion.exit_requested.emit()
                        else:
                            self.assertIsNone(window.companion)
                            window.close()
                        await asyncio.wait_for(window.closed.wait(), 2)
                        self.assertTrue(window.companion is None or not window.companion.isVisible())
                    finally:
                        if not window.closed.is_set():
                            await window.shutdown()
                        await asyncio.sleep(0)
                        window.deleteLater()
                        self.app.processEvents()


if __name__ == '__main__':
    unittest.main()
