#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace
{

// The embedder keeps the last rasterized scene and only presents a new frame
// when something asks for one. When the way the window is composed changes
// behind the app's back - the screen wakes up, a monitor is added or removed,
// the scale factor changes, the window comes back from the tray - the surface
// that scene was presented from can be gone, and the window then keeps showing
// only the part that happened to be repainted since: the rest reads as a black
// sheet lying over the app. Asking for one more frame after such an event puts
// the whole scene on a fresh surface again.
constexpr UINT kResyncViewMessage = WM_APP + 0x20;

} // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // this->Show(); window_manager hidden at launch
    "";
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // The messages that mean the surface the last frame went to may no longer be
  // there. Checked before the embedder sees them, because it answers some of
  // them itself and would keep the message from us.
  if (flutter_controller_) {
    switch (message) {
      case WM_SHOWWINDOW:
        if (wparam != FALSE) {
          PostMessage(hwnd, kResyncViewMessage, 0, 0);
        }
        break;

      case WM_DPICHANGED:
      case WM_DISPLAYCHANGE:
      case WM_DWMCOMPOSITIONCHANGED:
      case WM_ACTIVATE:
        if (message != WM_ACTIVATE || wparam != WA_INACTIVE) {
          PostMessage(hwnd, kResyncViewMessage, 0, 0);
        }
        break;

      case WM_POWERBROADCAST:
        if (wparam == PBT_APMRESUMEAUTOMATIC || wparam == PBT_APMRESUMESUSPEND) {
          PostMessage(hwnd, kResyncViewMessage, 0, 0);
        }
        break;

      case kResyncViewMessage:
        // Deferred on purpose: the redraw should reach the engine once the
        // window has settled in the state that invalidated its surface.
        flutter_controller_->ForceRedraw();
        return 0;
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
