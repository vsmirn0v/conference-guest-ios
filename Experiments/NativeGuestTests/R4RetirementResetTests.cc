#include <cassert>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>

// The runner inserts exact archived production statements. The stubs below
// provide in-memory stop results and ownership identities, never audio APIs.
#define nil nullptr
#define RTC_DCHECK(value) assert(value)
struct QuietLog { template <class T> QuietLog& operator<<(const T&) { return *this; } };
#define LOGI() QuietLog{}
#define LOGE() QuietLog{}
constexpr int kAudioEngineStateTransitionError = -901;
static unsigned long checks = 0, cases = 0;
static void require(bool value, const char* message) {
  ++checks;
  if (!value) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}
struct StatePart { bool enabled; bool IsAnyEnabled() const { return enabled; } };
struct EngineStateUpdate { StatePart prev, next; };
struct Observer {
  int result = 0, calls = 0;
  void* observed = nullptr;
  int32_t OnEngineWillRelease(void* engine) { ++calls; observed = engine; return result; }
};
struct Device {
  int identity = 0;
  void* engine_device_ = &identity;
  bool input_node_instantiated_ = true, cleanup_unconfirmed_ = false;
  void *source_node_ = nullptr, *sink_node_ = nullptr, *input_mixer_node_ = nullptr;
  void *converter_ref_ = nullptr, *converter_buffer_ = nullptr, *configuration_observer_ = nullptr;
  std::shared_ptr<int> active_bridge_, active_prepared_graph_;
  Observer observer; Observer* observer_ = &observer;
  bool stop_result = true;
  int stop_calls = 0, add_refs = 0, rollbacks = 0;
  bool StopDeviceEngineAudioUnits() { ++stop_calls; return stop_result; }
  void AddRef() { ++add_refs; }
  int rollback(int result) { ++rollbacks; return result; }
  int apply(EngineStateUpdate state) {
    // @production entry
    // @production release
    // @production cleanup
    return 0;
  }
  bool stoppedPreparationNoEngine() const {
    // @production preparation
    return no_engine;
  }
  void setup(bool instantiated, unsigned mask, bool bridge, bool graph) {
    input_node_instantiated_ = instantiated;
    void** owners[] = {&source_node_, &sink_node_, &input_mixer_node_, &converter_ref_,
                      &converter_buffer_, &configuration_observer_};
    for (unsigned index = 0; index < 6; ++index) *owners[index] = mask & (1u << index) ? &identity : nullptr;
    if (bridge) active_bridge_ = std::make_shared<int>(1);
    if (graph) active_prepared_graph_ = std::make_shared<int>(2);
  }
};

static void releaseMatrix() {
  for (bool initial : {false, true}) for (bool stopped : {false, true})
  for (unsigned mask = 0; mask < 64; ++mask) for (bool bridge : {false, true})
  for (bool graph : {false, true}) for (int observer_result : {0, -43}) {
    ++cases; Device device; device.setup(initial, mask, bridge, graph);
    device.stop_result = stopped; device.observer.result = observer_result;
    const int result = device.apply({{true}, {false}});
    require(device.stop_calls == 1, "release must call the native stop seam exactly once");
    const bool unconfirmed = bridge && !stopped;
    const bool observer_failed = !unconfirmed && observer_result != 0;
    const bool released = !unconfirmed && !observer_failed;
    require(result == (unconfirmed ? kAudioEngineStateTransitionError : observer_failed ? observer_result : 0),
            "stop and observer failure identities must remain intact");
    require(device.cleanup_unconfirmed_ == unconfirmed && device.add_refs == (unconfirmed ? 1 : 0),
            "unconfirmed bridge ownership must be quarantined and retained");
    require(device.rollbacks == (observer_failed ? 1 : 0), "observer failure must take rollback path");
    require(device.observer.calls == (unconfirmed ? 0 : 1), "unconfirmed stop must precede observer release");
    if (!unconfirmed) require(device.observer.observed == &device.identity, "observer must see the unreleased engine");
    require((device.engine_device_ == nullptr) == released, "only admitted release may clear the engine");
    require(bool(device.active_bridge_) == (!released && bridge), "bridge lifetime must follow admitted release");
    require(bool(device.active_prepared_graph_) == (!released && graph), "prepared graph lifetime must follow admitted release");
    const bool expected_flag = initial && !(released && stopped && mask == 0);
    require(device.input_node_instantiated_ == expected_flag,
            "input-node flag clears only after confirmed release with every residual owner absent");
    require(device.stoppedPreparationNoEngine() == (released && !expected_flag),
            "production stopped-preparation no-engine gate must observe the current retirement state");
  }
}

static void absentAndRetainedEngineMatrix() {
  for (bool initial : {false, true}) for (unsigned mask = 0; mask < 64; ++mask)
  for (bool bridge : {false, true}) for (bool graph : {false, true}) {
    ++cases; Device absent; absent.setup(initial, mask, bridge, graph); absent.engine_device_ = nullptr;
    require(absent.apply({{false}, {false}}) == 0, "absent engine apply succeeds without release");
    require(absent.stop_calls == 0 && absent.observer.calls == 0 && absent.add_refs == 0,
            "absent engine is not evidence of a physical stop");
    require(absent.input_node_instantiated_ == initial, "no-engine entry cannot certify input-node retirement");
    require(!absent.active_bridge_ && !absent.active_prepared_graph_, "absent-engine bridge cleanup remains intact");
    require(absent.stoppedPreparationNoEngine() == !initial, "stale input-node provenance must block later stopped preparation");

    ++cases; Device retained; retained.setup(initial, mask, bridge, graph);
    require(retained.apply({{true}, {true}}) == 0, "retained engine must skip release");
    require(retained.stop_calls == 0 && retained.observer.calls == 0, "running ownership must not be stopped");
    require(retained.engine_device_ == &retained.identity && retained.input_node_instantiated_ == initial,
            "retained engine and input-node provenance must remain intact");
    require(bool(retained.active_bridge_) == bridge && bool(retained.active_prepared_graph_) == graph,
            "live engine must retain both bridge owners");
    require(!retained.stoppedPreparationNoEngine(), "live engine must block stopped preparation");
  }
}

static void perInvocationProof() {
  ++cases; Device device; device.setup(true, 0, true, true);
  require(device.apply({{true}, {false}}) == 0 && !device.input_node_instantiated_,
          "confirmed ordinary input teardown must clear its retired input-node instance");
  require(device.stoppedPreparationNoEngine(), "clean teardown reopens the actual no-engine preparation gate");
  device.input_node_instantiated_ = true;
  require(device.apply({{false}, {false}}) == 0 && device.input_node_instantiated_,
          "a later invocation cannot reuse an earlier invocation's retirement proof");
}

int main() {
  releaseMatrix(); absentAndRetainedEngineMatrix(); perInvocationProof();
  std::cout << "PASS " << cases << " memory-only retirement cases; " << checks
            << " production-block assertions; no audio device APIs\n";
}
