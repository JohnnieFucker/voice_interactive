"""龙宝桌面形象，使用项目内的透明精灵图播放动画。"""
from pathlib import Path

from PySide6.QtCore import QElapsedTimer, QPoint, QRect, QRectF, QSettings, Qt, QTimer, Signal
from PySide6.QtGui import QBitmap, QGuiApplication, QPainter, QPixmap, QRegion
from PySide6.QtWidgets import QApplication, QMenu, QStyle, QWidget


SPRITE_PATH = Path(__file__).with_name("assets") / "hero-mascot-sprite.webp"
FRAME_INTERVAL_MS = 120
# 顺序播放再倒序回到待机，避免举手姿势直接跳回第一帧。
FRAME_ORDER = tuple(range(10)) + tuple(range(8, 0, -1))


def load_sprite_frames(path=SPRITE_PATH):
    sheet = QPixmap(str(path))
    if sheet.isNull():
        raise RuntimeError(f"无法加载龙宝精灵图：{path}")
    frames = []
    for row in range(2):
        for column in range(5):
            left, right = round(column * sheet.width() / 5), round((column + 1) * sheet.width() / 5)
            top, bottom = round(row * sheet.height() / 2), round((row + 1) * sheet.height() / 2)
            frame = sheet.copy(left, top, right - left, bottom - top)
            mask = QBitmap.fromImage(frame.toImage().createAlphaMask(Qt.ImageConversionFlag.ThresholdAlphaDither))
            bounds = QRegion(mask).boundingRect()
            if bounds.isEmpty():
                raise RuntimeError("龙宝精灵图包含空白帧")
            # 两行留白高度不同，逐帧裁边，再统一按脚底对齐。
            bounds = bounds.adjusted(-3, -3, 3, 3).intersected(QRect(0, 0, frame.width(), frame.height()))
            frames.append(frame.copy(bounds))
    return frames


def visible_position(position, screens, size):
    """将形象完整放回最近的可用屏幕，兼容负坐标和显示器拔出。"""
    if not screens:
        return position
    center = position + QPoint(size.width() // 2, size.height() // 2)
    screen = min(screens, key=lambda rect:
                 max(rect.left() - center.x(), 0, center.x() - rect.right()) ** 2
                 + max(rect.top() - center.y(), 0, center.y() - rect.bottom()) ** 2)
    return QPoint(
        min(max(position.x(), screen.left()), max(screen.left(), screen.right() - size.width() + 1)),
        min(max(position.y(), screen.top()), max(screen.top(), screen.bottom() - size.height() + 1)),
    )


class DesktopCompanion(QWidget):
    settings_requested = Signal()
    main_requested = Signal()
    exit_requested = Signal()

    def __init__(self, state, settings=None):
        super().__init__(None, Qt.WindowType.Tool | Qt.WindowType.FramelessWindowHint
                         | Qt.WindowType.WindowStaysOnTopHint)
        self.state = state
        self.preferences = settings if settings is not None else QSettings("VoiceScreenControl", "DesktopCompanion")
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setAttribute(Qt.WidgetAttribute.WA_MacAlwaysShowToolWindow)
        self.setWindowTitle("龙宝")
        self.setAccessibleName("龙宝，单击打开设置，拖动调整位置")
        self.setFixedSize(116, 132)
        self.frames = load_sprite_frames()
        self.frame_index = 0
        self.sprite_scale = min((self.width() - 8) / max(frame.width() for frame in self.frames),
                                (self.height() - 8) / max(frame.height() for frame in self.frames))
        self.setCursor(Qt.CursorShape.OpenHandCursor)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self.anchor = None
        self.origin = None
        self.dragging = False
        self.last_state = None
        self.clock = QElapsedTimer()
        self.clock.start()
        self.animation_enabled = self.preferences.value(
            "animation_enabled", bool(QApplication.style().styleHint(QStyle.StyleHint.SH_Widget_Animate)), type=bool)
        self.timer = QTimer(self)
        self.timer.setInterval(40 if self.animation_enabled else 250)
        self.timer.timeout.connect(self.tick)
        self.timer.start()
        primary = QGuiApplication.primaryScreen()
        area = primary.availableGeometry() if primary else None
        default = area.bottomRight() - QPoint(self.width() + 24, self.height() + 32) if area else QPoint(40, 40)
        position = self.preferences.value("position", default)
        self.move(position if isinstance(position, QPoint) else default)
        self.reposition()
        QGuiApplication.instance().screenAdded.connect(self.screen_added)
        QGuiApplication.instance().screenRemoved.connect(self.reposition)
        for screen in QGuiApplication.screens():
            screen.availableGeometryChanged.connect(self.reposition)

    def screen_added(self, screen):
        screen.availableGeometryChanged.connect(self.reposition)
        self.reposition()

    def reposition(self, *_):
        areas = [screen.availableGeometry() for screen in QGuiApplication.screens()]
        self.move(visible_position(self.pos(), areas, self.size()))

    def tick(self):
        if self.animation_enabled:
            self.frame_index = FRAME_ORDER[(self.clock.elapsed() // FRAME_INTERVAL_MS) % len(FRAME_ORDER)]
        state = self.state()
        if state != self.last_state:
            labels = {"idle": "待启动", "ready": "服务运行", "listening": "正在听", "thinking": "处理中"}
            self.setToolTip(f"龙宝 · {labels.get(state, '待启动')} · 单击设置 · 拖动移动 · 右键退出")
            self.last_state = state
            self.update()
        elif self.animation_enabled:
            self.update()

    def set_animation(self, enabled):
        self.animation_enabled = enabled
        self.preferences.setValue("animation_enabled", enabled)
        if enabled:
            self.clock.restart()
        self.timer.setInterval(40 if enabled else 250)
        self.update()

    def paintEvent(self, event):
        frame = self.frames[self.frame_index]
        width, height = frame.width() * self.sprite_scale, frame.height() * self.sprite_scale
        target = QRectF((self.width() - width) / 2, self.height() - 4 - height, width, height)
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        painter.drawPixmap(target, frame, QRectF(frame.rect()))

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self.anchor = event.globalPosition().toPoint()
            self.origin = self.pos()
            self.dragging = False
            self.setCursor(Qt.CursorShape.ClosedHandCursor)
            event.accept()
        else:
            super().mousePressEvent(event)

    def mouseMoveEvent(self, event):
        if self.anchor is not None and event.buttons() & Qt.MouseButton.LeftButton:
            delta = event.globalPosition().toPoint() - self.anchor
            if delta.manhattanLength() >= QApplication.startDragDistance():
                self.dragging = True
            if self.dragging:
                self.move(self.origin + delta)
                self.reposition()
            event.accept()
        else:
            super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton and self.anchor is not None:
            dragged = self.dragging
            self.anchor = self.origin = None
            self.dragging = False
            self.setCursor(Qt.CursorShape.OpenHandCursor)
            if dragged:
                self.preferences.setValue("position", self.pos())
            else:
                self.settings_requested.emit()
            event.accept()
        else:
            super().mouseReleaseEvent(event)

    def keyPressEvent(self, event):
        if event.key() in (Qt.Key.Key_Return, Qt.Key.Key_Enter, Qt.Key.Key_Space):
            self.settings_requested.emit()
            event.accept()
        else:
            super().keyPressEvent(event)

    def contextMenuEvent(self, event):
        menu = QMenu(self)
        menu.addAction("打开设置", self.settings_requested.emit)
        menu.addAction("打开运行窗口", self.main_requested.emit)
        animation = menu.addAction("播放动画")
        animation.setCheckable(True)
        animation.setChecked(self.animation_enabled)
        animation.toggled.connect(self.set_animation)
        menu.addSeparator()
        menu.addAction("退出集控端", self.exit_requested.emit)
        menu.exec(event.globalPos())

    def closeEvent(self, event):
        # 关闭主窗口或工具窗口不结束集控服务；退出使用右键菜单。
        event.ignore()

    def shutdown(self):
        self.timer.stop()
        self.hide()
