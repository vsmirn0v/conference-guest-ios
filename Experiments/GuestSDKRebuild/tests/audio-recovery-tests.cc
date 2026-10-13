#include "sdk/objc/native/src/audio/application_input_mute_state.h"
#include "sdk/objc/native/src/audio/audio_unit_recovery.h"

#include <cstdlib>
#include <future>
#include <iostream>
#include <thread>

using webrtc::ios_adm::ApplicationInputMuteState;
using webrtc::ios_adm::InitializeAudioUnitForRecovery;
using webrtc::ios_adm::RestartAudioUnitForRecovery;

#define CHECK(value) do { if (!(value)) { \
  std::cerr << __LINE__ << ": " << #value << "\n"; std::abort(); \
} } while (false)

// Tests use the actual headers applied to the framework source, not a copy of
// the algorithm. Only the platform AudioUnit operations are fault-injected.
struct Unit {
  enum State { kInitRequired, kUninitialized, kInitialized, kStarted };
  State state = kInitRequired;
  int creates = 0, initializations = 0, starts = 0, stops = 0;
  int fail_create = 0, fail_property = 0, fail_initialize = 0, fail_start = 0;
  bool input = false;
  State GetState() const { return state; }
  bool Init() {
    CHECK(state == kInitRequired); ++creates;
    if (fail_create-- > 0) return false;
    state = kUninitialized; return true;
  }
  bool Initialize(double rate, bool requested_input) {
    CHECK(state == kUninitialized); CHECK(rate == 48000); ++initializations;
    if (fail_property-- > 0) { state = kInitRequired; return false; }
    if (fail_initialize-- > 0) return false;
    input = requested_input; state = kInitialized; return true;
  }
  int Start() {
    CHECK(state == kInitialized); ++starts;
    if (fail_start-- > 0) return -1;
    state = kStarted; return 0;
  }
  bool Stop() { CHECK(state == kStarted); ++stops; state = kInitialized; return true; }
  bool Uninitialize() { CHECK(state == kInitialized); state = kUninitialized; return true; }
};

void newerIntentWins() {
  ApplicationInputMuteState state;
  state.SetIntent(true);
  std::promise<void> began, resume;
  auto continuation = resume.get_future();
  std::thread worker([&] {
    state.BeginReconfiguration(); began.set_value();
    continuation.wait(); state.EndReconfiguration();
  });
  began.get_future().wait();
  CHECK(state.IsReconfiguring());
  // A UI action/new owner/private capture occurs while a native call is paused.
  state.SetIntent(false);
  resume.set_value(); worker.join();
  ApplicationInputMuteState::Snapshot current;
  CHECK(state.SnapshotForRestore(&current)); CHECK(current.intent == 0);
  state.DidRestore(current.generation); CHECK(!state.IsReconfiguring());
}

void queuedRestoreReadsCurrentIntent() {
  ApplicationInputMuteState state;
  state.SetIntent(true); state.BeginReconfiguration(); state.EndReconfiguration();
  state.SetIntent(false);  // New owner before the queued main-queue block runs.
  ApplicationInputMuteState::Snapshot current;
  CHECK(state.SnapshotForRestore(&current)); CHECK(current.intent == 0);
  state.DidRestore(current.generation); CHECK(!state.IsReconfiguring());
}

void staleCompletionCannotClearNewLifecycle() {
  ApplicationInputMuteState state;
  state.SetIntent(true); state.BeginReconfiguration(); state.EndReconfiguration();
  ApplicationInputMuteState::Snapshot old, current;
  CHECK(state.SnapshotForRestore(&old));
  state.BeginReconfiguration(); state.EndReconfiguration();
  state.DidRestore(old.generation); CHECK(state.IsReconfiguring());
  CHECK(state.SnapshotForRestore(&current));
  state.DidRestore(current.generation); CHECK(!state.IsReconfiguring());
}

void nestedLifecyclesDoNotRestoreEarly() {
  ApplicationInputMuteState state;
  state.SetIntent(true); state.BeginReconfiguration(); state.BeginReconfiguration();
  state.EndReconfiguration();
  ApplicationInputMuteState::Snapshot current;
  CHECK(!state.SnapshotForRestore(&current)); CHECK(state.IsReconfiguring());
  state.SetIntent(false); state.EndReconfiguration();
  CHECK(state.SnapshotForRestore(&current)); CHECK(current.intent == 0);
  state.DidRestore(current.generation); CHECK(!state.IsReconfiguring());
}

void releasedIntentCannotOverwriteCallKit() {
  ApplicationInputMuteState state;
  state.SetIntent(1); state.BeginReconfiguration();
  state.SetIntent(-1); state.EndReconfiguration();
  int writes = 0;
  CHECK(state.Restore([&](bool) { ++writes; return true; }) == ApplicationInputMuteState::RestoreResult::kComplete);
  CHECK(writes == 0); CHECK(!state.IsReconfiguring());
}

void failedMuteRestoreRetriesAndResumesGestures() {
  ApplicationInputMuteState state;
  state.SetIntent(1); state.BeginReconfiguration(); state.EndReconfiguration();
  int writes = 0;
  auto write = [&](bool muted) { CHECK(muted); return ++writes > 1; };
  CHECK(state.QueueRestore()); CHECK(!state.QueueRestore());
  CHECK(state.Restore(write) == ApplicationInputMuteState::RestoreResult::kRetry);
  CHECK(state.IsReconfiguring()); CHECK(state.QueueRestore());
  CHECK(state.Restore(write) == ApplicationInputMuteState::RestoreResult::kComplete);
  CHECK(writes == 2); CHECK(!state.IsReconfiguring());
}

void backoffReadsNewOwnersIntentAndRetryIsBounded() {
  ApplicationInputMuteState state;
  state.SetIntent(1); state.BeginReconfiguration(); state.EndReconfiguration();
  CHECK(state.Restore([](bool) { return false; }) == ApplicationInputMuteState::RestoreResult::kRetry);
  CHECK(state.QueueRestore());  // A delayed job is already queued.
  state.SetIntent(0); state.BeginReconfiguration(); state.EndReconfiguration();
  CHECK(!state.QueueRestore());  // Coalesce requests; don't spawn parallel retry loops.
  CHECK(state.Restore([](bool muted) { CHECK(!muted); return true; }) == ApplicationInputMuteState::RestoreResult::kComplete);
  CHECK(!state.IsReconfiguring());
  state.BeginReconfiguration(); state.EndReconfiguration();
  int failures = 0;
  for (int attempt = 1; attempt <= 5; ++attempt) {
    CHECK(state.QueueRestore());
    auto result = state.Restore([&](bool) { ++failures; return false; });
    CHECK(result == (attempt < 5 ? ApplicationInputMuteState::RestoreResult::kRetry : ApplicationInputMuteState::RestoreResult::kComplete));
  }
  CHECK(failures == 5); CHECK(!state.IsReconfiguring()); CHECK(!state.QueueRestore());
}

void disposedUnitCanBeRecreated() {
  Unit unit; unit.fail_property = 1;
  CHECK(!InitializeAudioUnitForRecovery(unit, 48000, false));
  CHECK(unit.state == Unit::kInitRequired);
  CHECK(InitializeAudioUnitForRecovery(unit, 48000, false));
  CHECK(unit.creates == 2); CHECK(unit.Start() == 0); CHECK(!unit.input);
}

void failedComponentCreationCanBeRetried() {
  Unit unit; unit.fail_create = 1;
  CHECK(!InitializeAudioUnitForRecovery(unit, 48000, true));
  CHECK(unit.state == Unit::kInitRequired);
  CHECK(InitializeAudioUnitForRecovery(unit, 48000, true));
  CHECK(unit.creates == 2); CHECK(unit.input);
}

void initializationFailureKeepsReusableUnit() {
  Unit unit; unit.fail_initialize = 1;
  CHECK(!InitializeAudioUnitForRecovery(unit, 48000, false));
  CHECK(unit.state == Unit::kUninitialized);
  CHECK(InitializeAudioUnitForRecovery(unit, 48000, false));
  CHECK(unit.creates == 1); CHECK(unit.Start() == 0);
}

void failedMicrophoneTransitionsRestorePlayout() {
  for (bool enabling : {false, true}) {
    for (bool property_failure : {false, true}) {
      Unit unit; unit.state = Unit::kStarted; unit.input = !enabling;
      int preparations = 0;
      if (property_failure) unit.fail_property = 1;
      else unit.fail_start = 1;
      CHECK(!RestartAudioUnitForRecovery(unit, 48000, enabling, [&] { ++preparations; }));
      CHECK(unit.state != Unit::kStarted); CHECK(preparations == 1);
      // InitRecording failed, or StopRecording completed: retry existing
      // output using the current recording flag, without enabling a failed mic.
      if (unit.state < Unit::kInitialized) {
        CHECK(InitializeAudioUnitForRecovery(unit, 48000, false));
      }
      CHECK(unit.Start() == 0); CHECK(unit.state == Unit::kStarted);
      CHECK(!unit.input);  // Retry uses the current muted input intent.
      CHECK(RestartAudioUnitForRecovery(unit, 48000, false, [&] { ++preparations; }));
      CHECK(!unit.input); CHECK(unit.state == Unit::kStarted);
    }
  }
}

int main() {
  newerIntentWins(); queuedRestoreReadsCurrentIntent();
  staleCompletionCannotClearNewLifecycle(); nestedLifecyclesDoNotRestoreEarly();
  releasedIntentCannotOverwriteCallKit(); failedMuteRestoreRetriesAndResumesGestures();
  backoffReadsNewOwnersIntentAndRetryIsBounded();
  disposedUnitCanBeRecreated(); failedComponentCreationCanBeRetried();
  initializationFailureKeepsReusableUnit(); failedMicrophoneTransitionsRestorePlayout();
  std::cout << "11 native audio recovery tests passed\n";
}
