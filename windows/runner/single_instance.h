#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

// One ddIRC per signed-in user.
//
// Two copies is not merely untidy — they are two processes holding two sets of
// IRC connections, registering the same nickname twice, writing the same
// settings file from both ends and racing each other to the same chat log. The
// second one looks like a window and behaves like a fork.
//
// It is also easy to reach by accident, which is the real argument: closing
// ddIRC to the tray leaves nothing on the taskbar, so launching it again is
// exactly what somebody who has forgotten it is running will do.
//
// So a second launch is not refused with a message. It hands the user what
// they were asking for — the window they already had — and gets out of the
// way.
class SingleInstance {
 public:
  // Claims the name for this process. Do this before creating any window: if
  // it is already claimed, this process is about to exit and should not have
  // put a second window on screen first.
  explicit SingleInstance(const wchar_t* name);
  ~SingleInstance();

  SingleInstance(const SingleInstance&) = delete;
  SingleInstance& operator=(const SingleInstance&) = delete;

  // True when another copy already holds the name.
  bool AlreadyRunning() const { return already_running_; }

  // Bring the copy that is already running to the front, unhiding it if it is
  // in the tray and restoring it if it is minimised.
  //
  // Returns false if its window could not be found, which is possible in one
  // real case: the first copy is still starting and has not created a window
  // yet. The caller has nothing useful to do about that either way — a second
  // window would still be the wrong answer — so this reports it only for the
  // sake of not claiming to have done something it did not.
  static bool RaiseExistingWindow();

 private:
  HANDLE mutex_ = nullptr;
  bool already_running_ = false;
};

#endif  // RUNNER_SINGLE_INSTANCE_H_
