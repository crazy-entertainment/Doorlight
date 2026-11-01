#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>

#include <functional>
#include <memory>
#include <string>

// A class abstraction for a high DPI-aware Win32 Window. Intended to be
// inherited from by classes that wish to specialize with custom
// rendering and input handling
class Win32Window {
 public:
  struct Point {
    unsigned int x;
    unsigned int y;
    Point(unsigned int x, unsigned int y) : x(x), y(y) {}
  };

  struct Size {
    unsigned int width;
    unsigned int height;
    Size(unsigned int width, unsigned int height)
        : width(width), height(height) {}
  };

  Win32Window();
  virtual ~Win32Window();

  // Creates a win32 window with |title| that is positioned and sized using
  // |origin| and |size|. New windows are created on the default monitor. Window
  // sizes are specified to the OS in physical pixels, hence to ensure a
  // consistent size this function will scale the inputted width and height as
  // as appropriate for the default monitor. The window is invisible until
  // |Show| is called. Returns true if the window was created successfully.
  bool Create(const std::wstring& title, const Point& origin, const Size& size);

  // Show the current window. Returns true if the window was successfully shown.
  bool Show();

  // Default first-launch placement, measured from the visible frame. Recheck
  // after Show because DWM's hidden-window frame can differ from its shown one.
  void SetDefaultCornerGap(int logical_gap);

  // Release OS resources associated with window.
  void Destroy();

  // Inserts |content| into the window tree.
  void SetChildContent(HWND content);

  // Returns the backing Window handle to enable clients to set icon and other
  // window properties. Returns nullptr if the window has been destroyed.
  HWND GetHandle();

  // Applies an app-owned border preference without showing or activating it.
  static constexpr UINT kAppearanceMessage = WM_APP + 0x397;
  static bool SetDisaccordBorder(HWND window, bool enabled) noexcept;

  // If true, closing this window will quit the application.
  void SetQuitOnClose(bool quit_on_close);

  // Return a RECT representing the bounds of the current client area.
  RECT GetClientArea();

  // The presentation mode currently applied to the window (0 = normal).
  int presentation_mode() const { return presentation_mode_; }

  // Applies the latest mode requested while the window was hidden. Called by
  // the covered reveal after the window is shown, while the cover is up.
  bool ApplyDeferredPresentation() noexcept;
  void FinishPresentationAnimation() noexcept;

 protected:
  // Processes and route salient window messages for mouse handling,
  // size change and DPI. Delegates handling of these to member overloads that
  // inheriting classes can handle.
  virtual LRESULT MessageHandler(HWND window,
                                 UINT const message,
                                 WPARAM const wparam,
                                 LPARAM const lparam) noexcept;

  // Called when CreateAndShow is called, allowing subclass window-related
  // setup. Subclasses should return false if setup fails.
  virtual bool OnCreate();

  // Restores a visible, minimized window. Subclasses that own a privacy cover
  // route this through their covered reveal.
  virtual bool RevealMinimized(HWND window) noexcept;

  // Called when Destroy is called.
  virtual void OnDestroy();

 private:
  friend class WindowClassRegistrar;

  // OS callback called by message pump. Handles the WM_NCCREATE message which
  // is passed when the non-client area is being created and enables automatic
  // non-client DPI scaling so that the non-client area automatically
  // responds to changes in DPI. All other messages are handled by
  // MessageHandler.
  static LRESULT CALLBACK WndProc(HWND const window,
                                  UINT const message,
                                  WPARAM const wparam,
                                  LPARAM const lparam) noexcept;

  // Retrieves a class instance pointer for |window|
  static Win32Window* GetThisFromHandle(HWND const window) noexcept;

  // Refresh system decorations while preserving the app's border preference.
  void UpdateTheme(HWND const window);
  bool disaccord_border_ = false;
  void UpdateIcons(UINT dpi) noexcept;
  HICON small_icon_ = nullptr;
  HICON large_icon_ = nullptr;

  bool quit_on_close_ = false;
  void ApplyDefaultCornerPlacement();
  int default_corner_gap_ = -1;
  int window_edge_gap_ = 8;
  bool SetWindowEdgeSpacing(HWND window, int logical_gap, bool reposition) noexcept;
  bool SetPresentation(HWND window, int mode, bool animate = false,
                       bool reset_position = false) noexcept;
  bool MovePresentation(HWND window, const RECT& target, bool animate) noexcept;
  void CancelPresentationAnimation(HWND window) noexcept;
  bool SchedulePresentationFrame() noexcept;
  double PresentationElapsedMs() const noexcept;
  static void CALLBACK PresentationFrameReady(PTP_CALLBACK_INSTANCE, void*,
                                               PTP_WAIT, TP_WAIT_RESULT) noexcept;
  HANDLE presentation_timer_ = nullptr;
  PTP_WAIT presentation_wait_ = nullptr;
  UINT_PTR presentation_generation_ = 0;
  LARGE_INTEGER presentation_started_{};
  LARGE_INTEGER presentation_frequency_{};
  double presentation_refresh_hz_ = 60;
  RECT presentation_from_{};
  RECT presentation_target_{};
  int presentation_mode_ = 0;
  int deferred_presentation_mode_ = -1;
  bool deferred_reset_position_ = false;
  WINDOWPLACEMENT normal_placement_{sizeof(WINDOWPLACEMENT)};
  RECT compact_bounds_{};

  // window handle for top level window.
  HWND window_handle_ = nullptr;

  // window handle for hosted content.
  HWND child_content_ = nullptr;
};

#endif  // RUNNER_WIN32_WINDOW_H_
