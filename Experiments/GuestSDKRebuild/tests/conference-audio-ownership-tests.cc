/* Copyright 2026 Rock'n'Roll contributors. BSD license: see LICENSE. */
#include "sdk/objc/native/src/audio/conference_audio_ownership.h"

#include <cstdio>
#include <cstdlib>

namespace {
using Ownership = webrtc::ios_adm::ConferenceAudioOwnership;
using Kind = Ownership::Kind;
using Admission = webrtc::ios_adm::ConferenceAudioAdmissionState;
using namespace webrtc::ios_adm;

void Check(bool condition, int line) {
  if (!condition) {
    std::fprintf(stderr, "conference audio ownership assertion failed: %d\n",
                 line);
    std::abort();
  }
}
#define CHECK(condition) Check((condition), __LINE__)

Ownership::Action Take(Ownership& ownership, Ownership::Owner owner, Kind kind,
                       bool reserved = false) {
  auto action = ownership.Next();
  CHECK(action.has_value());
  CHECK(action->id != 0);
  CHECK(action->owner == owner);
  CHECK(action->kind == kind);
  CHECK(action->reserved == reserved);
  CHECK(ownership.in_flight_owner() == owner);
  CHECK(!ownership.Next());
  return *action;
}

void AdmissionAndRefresh() {
  Ownership ownership;
  CHECK(!ownership.Next());
  ownership.SetReserved(true);
  CHECK(!ownership.Next());
  ownership.Select(1);
  const auto first = Take(ownership, 1, Kind::kApply, true);
  CHECK(ownership.active_owner() == 1);
  CHECK(ownership.Complete(first.id, true));
  CHECK(!ownership.Next());
  ownership.Select(1);
  const auto refresh = Take(ownership, 1, Kind::kApply, true);
  CHECK(refresh.id != first.id);
  CHECK(refresh.revision > first.revision);
  CHECK(ownership.Complete(refresh.id, true));
  CHECK(!ownership.Next());
}

void RapidReplacementCoalescesBeforeRetirement() {
  Ownership ownership;
  ownership.Select(1);
  ownership.SetReserved(true);
  const auto first = Take(ownership, 1, Kind::kApply, true);
  ownership.Select(2);
  ownership.Select(3);
  CHECK(ownership.active_owner() == 1);
  CHECK(ownership.desired_owner() == 3);
  CHECK(!ownership.Next());
  CHECK(ownership.Complete(first.id, true));
  const auto retire = Take(ownership, 1, Kind::kRetire);
  CHECK(ownership.active_owner() == 1);
  CHECK(ownership.Complete(retire.id, true));
  CHECK(ownership.active_owner() == 0);
  const auto last = Take(ownership, 3, Kind::kApply, true);
  CHECK(ownership.Complete(last.id, true));
  CHECK(ownership.active_owner() == 3);
  CHECK(!ownership.Next());
}

void PendingReplacementUsesLatestReservation() {
  Ownership ownership;
  ownership.Select(1);
  ownership.SetReserved(true);
  auto action = Take(ownership, 1, Kind::kApply, true);
  CHECK(ownership.Complete(action.id, true));
  ownership.Select(2);
  action = Take(ownership, 1, Kind::kRetire);
  ownership.Select(3);
  ownership.SetReserved(false);
  CHECK(ownership.Complete(action.id, true));
  action = Take(ownership, 3, Kind::kApply);
  CHECK(ownership.Complete(action.id, true));
  CHECK(ownership.active_owner() == 3);
  CHECK(!ownership.desired_reserved());
  CHECK(!ownership.Next());
}

void ReleaseWhileApplyRunsThenReselect() {
  Ownership ownership;
  ownership.Select(1);
  ownership.SetReserved(true);
  const auto start = Take(ownership, 1, Kind::kApply, true);
  ownership.SetReserved(false);
  CHECK(ownership.Complete(start.id, true));
  const auto release = Take(ownership, 1, Kind::kApply);
  CHECK(ownership.Complete(release.id, true));
  CHECK(ownership.active_owner() == 1);
  ownership.Select(0);
  const auto retire = Take(ownership, 1, Kind::kRetire);
  ownership.Select(1);
  CHECK(ownership.Complete(retire.id, true));
  const auto reselect = Take(ownership, 1, Kind::kApply);
  CHECK(ownership.Complete(reselect.id, true));
  ownership.Select(0);
  const auto finish = Take(ownership, 1, Kind::kRetire);
  CHECK(ownership.Complete(finish.id, true));
  CHECK(ownership.active_owner() == 0);
  CHECK(ownership.desired_owner() == 0);
  CHECK(ownership.in_flight_owner() == 0);
  CHECK(!ownership.Next());
}

void StaleCompletionCannotReleaseAnotherAction() {
  Ownership ownership;
  ownership.Select(1);
  const auto first = Take(ownership, 1, Kind::kApply);
  CHECK(!ownership.Complete(first.id + 1, true));
  CHECK(ownership.in_flight_owner() == 1);
  CHECK(ownership.Complete(first.id, true));
  CHECK(!ownership.Complete(first.id, true));
  ownership.Select(2);
  const auto retire = Take(ownership, 1, Kind::kRetire);
  CHECK(!ownership.Complete(first.id, false));
  CHECK(ownership.in_flight()->id == retire.id);
  CHECK(ownership.Complete(retire.id, true));
  const auto next = Take(ownership, 2, Kind::kApply);
  CHECK(!ownership.Complete(retire.id, true));
  CHECK(ownership.active_owner() == 2);
  CHECK(ownership.Complete(next.id, true));
}

void FailureRequiresAnotherRequestAndStillOwnsHardware() {
  Ownership ownership;
  ownership.Select(1);
  auto action = Take(ownership, 1, Kind::kApply);
  CHECK(ownership.Complete(action.id, false));
  CHECK(ownership.active_owner() == 1);
  CHECK(!ownership.Next());
  CHECK(!ownership.Next());
  ownership.Select(2);
  action = Take(ownership, 1, Kind::kRetire);
  CHECK(ownership.Complete(action.id, false));
  CHECK(ownership.active_owner() == 1);
  CHECK(!ownership.Next());
  ownership.SetReserved(false);
  action = Take(ownership, 1, Kind::kRetire);
  CHECK(ownership.Complete(action.id, true));
  action = Take(ownership, 2, Kind::kApply);
  CHECK(ownership.Complete(action.id, true));
  CHECK(!ownership.Next());
}

void NewerRequestDuringFailedOperationIsNotLost() {
  Ownership ownership;
  ownership.Select(1);
  const auto first = Take(ownership, 1, Kind::kApply);
  ownership.Select(2);
  CHECK(ownership.Complete(first.id, false));
  const auto retire = Take(ownership, 1, Kind::kRetire);
  ownership.Select(3);
  CHECK(ownership.Complete(retire.id, false));
  const auto retry = Take(ownership, 1, Kind::kRetire);
  CHECK(ownership.Complete(retry.id, false));
  CHECK(!ownership.Next());
  ownership.Select(3);
  const auto recovered = Take(ownership, 1, Kind::kRetire);
  CHECK(ownership.Complete(recovered.id, true));
  const auto final = Take(ownership, 3, Kind::kApply);
  CHECK(ownership.Complete(final.id, true));
  CHECK(!ownership.Next());
}

void UnmanagedAdmissionIsUnchanged() {
  Admission admission;
  CHECK(!admission.managed());
  CHECK(admission.admitted());
  CHECK(admission.RequestPlayoutInit());
  CHECK(admission.RequestPlayoutStart());
  CHECK(admission.RequestRecordingInit());
  CHECK(admission.RequestRecordingStart());
  CHECK(admission.Grant());
  admission.Retire();
  CHECK(admission.admitted());
  admission.StopPlayout();
  admission.StopRecording();
  CHECK(!admission.wants_playout_init());
  CHECK(!admission.wants_recording_start());
}

void PendingMediaIsDeferredAndStopsCancelIt() {
  Admission admission;
  auto authority = std::make_shared<std::atomic<int>>(kConferenceAudioPending);
  CHECK(admission.Prepare(authority));
  CHECK(!admission.Prepare(authority));
  CHECK(!admission.admitted());
  CHECK(!admission.Grant());
  CHECK(!admission.RequestPlayoutStart());
  CHECK(!admission.RequestRecordingStart());
  CHECK(admission.wants_playout_init());
  CHECK(admission.wants_playout_start());
  CHECK(admission.wants_recording_init());
  CHECK(admission.wants_recording_start());
  admission.StopRecording();
  CHECK(!admission.wants_recording_init());
  CHECK(!admission.wants_recording_start());
  CHECK(admission.wants_playout_start());
  admission.StopPlayout();
  CHECK(!admission.wants_playout_init());
  CHECK(!admission.wants_playout_start());
  authority->store(kConferenceAudioReserved);
  CHECK(admission.Grant());
  CHECK(admission.reserved());
  CHECK(!admission.wants_recording_init());
  CHECK(!admission.wants_recording_start());
}

void UnreservedGrantReplaysMediaWithoutInventingRecordingStart() {
  Admission admission;
  auto authority = std::make_shared<std::atomic<int>>(kConferenceAudioPending);
  CHECK(admission.Prepare(authority));
  CHECK(!admission.RequestPlayoutStart());
  CHECK(!admission.RequestRecordingInit());
  authority->store(kConferenceAudioAdmitted);
  CHECK(!admission.admitted());
  CHECK(admission.Grant());
  CHECK(admission.admitted());
  CHECK(!admission.reserved());
  CHECK(admission.wants_playout_init());
  CHECK(admission.wants_playout_start());
  CHECK(admission.wants_recording_init());
  CHECK(!admission.wants_recording_start());
  CHECK(admission.RequestRecordingStart());
  CHECK(admission.wants_recording_start());
  admission.StopRecording();
  CHECK(!admission.wants_recording_init());
  CHECK(!admission.wants_recording_start());
}

void RetiredRequestsAreDiscardedUntilExplicitGrant() {
  Admission admission;
  auto authority = std::make_shared<std::atomic<int>>(kConferenceAudioPending);
  CHECK(admission.Prepare(authority));
  CHECK(!admission.RequestRecordingStart());
  authority->store(kConferenceAudioRetired);
  CHECK(!admission.RequestPlayoutStart());
  CHECK(!admission.wants_recording_init());
  CHECK(!admission.wants_playout_start());
  CHECK(!admission.Grant());
  authority->store(kConferenceAudioAdmitted);
  CHECK(!admission.RequestRecordingStart());
  CHECK(!admission.RequestPlayoutInit());
  CHECK(!admission.wants_recording_start());
  CHECK(!admission.wants_playout_init());
  CHECK(admission.Grant());
  CHECK(!admission.wants_recording_start());
  CHECK(admission.RequestPlayoutStart());
}

void RevocationInvalidatesAdmissionCallbackCapability() {
  Admission admission;
  auto authority = std::make_shared<std::atomic<int>>(kConferenceAudioPending);
  CHECK(admission.Prepare(authority));
  const auto pending_generation = admission.generation();
  CHECK(!admission.AllowsCallback(pending_generation));
  authority->store(kConferenceAudioReserved);
  CHECK(admission.Grant());
  const auto admitted_generation = admission.generation();
  CHECK(admitted_generation != pending_generation);
  CHECK(!admission.AllowsCallback(pending_generation));
  CHECK(admission.AllowsCallback(admitted_generation));
  CHECK(admission.RequestPlayoutStart());
  authority->store(kConferenceAudioRetired);
  CHECK(!admission.admitted());
  CHECK(!admission.AllowsCallback(admitted_generation));
  admission.Retire();
  const auto retired_generation = admission.generation();
  admission.Retire();
  CHECK(admission.generation() == retired_generation);
  authority->store(kConferenceAudioAdmitted);
  CHECK(!admission.AllowsCallback(admitted_generation));
  CHECK(admission.Grant());
  CHECK(!admission.AllowsCallback(admitted_generation));
  CHECK(admission.AllowsCallback(admission.generation()));
  CHECK(!admission.wants_playout_start());
}

void ReservationReleaseAndReacquirePreserveOnlySDKIntent() {
  Admission admission;
  auto authority = std::make_shared<std::atomic<int>>(kConferenceAudioPending);
  CHECK(admission.Prepare(authority));
  authority->store(kConferenceAudioReserved);
  CHECK(admission.Grant());
  const auto generation = admission.generation();
  CHECK(!admission.wants_playout_start());
  CHECK(!admission.wants_recording_init());
  authority->store(kConferenceAudioAdmitted);
  CHECK(admission.Grant());
  CHECK(!admission.reserved());
  CHECK(admission.generation() == generation);
  CHECK(admission.RequestPlayoutStart());
  authority->store(kConferenceAudioReserved);
  CHECK(admission.Grant());
  CHECK(admission.reserved());
  CHECK(admission.wants_playout_start());
  CHECK(!admission.wants_recording_start());
  authority->store(kConferenceAudioAdmitted);
  CHECK(admission.Grant());
  CHECK(admission.wants_playout_start());
  admission.StopPlayout();
  CHECK(!admission.wants_playout_start());
}

void InitializationAloneCannotKeepReservedOutputPlaying() {
  Admission admission;
  auto authority = std::make_shared<std::atomic<int>>(kConferenceAudioPending);
  CHECK(admission.Prepare(authority));
  CHECK(!admission.RequestPlayoutInit());
  CHECK(!admission.should_play());
  authority->store(kConferenceAudioReserved);
  CHECK(admission.Grant());
  CHECK(admission.wants_playout_init());
  CHECK(!admission.wants_playout_start());
  CHECK(admission.should_play());
  authority->store(kConferenceAudioAdmitted);
  CHECK(admission.Grant());
  CHECK(admission.wants_playout_init());
  CHECK(!admission.should_play());
  authority->store(kConferenceAudioReserved);
  CHECK(admission.Grant());
  CHECK(admission.RequestPlayoutStart());
  authority->store(kConferenceAudioAdmitted);
  CHECK(admission.Grant());
  CHECK(admission.should_play());
  authority->store(kConferenceAudioRetired);
  CHECK(!admission.should_play());
  admission.Retire();
  CHECK(!admission.should_play());
}
}  // namespace

int main() {
  AdmissionAndRefresh();
  RapidReplacementCoalescesBeforeRetirement();
  PendingReplacementUsesLatestReservation();
  ReleaseWhileApplyRunsThenReselect();
  StaleCompletionCannotReleaseAnotherAction();
  FailureRequiresAnotherRequestAndStillOwnsHardware();
  NewerRequestDuringFailedOperationIsNotLost();
  UnmanagedAdmissionIsUnchanged();
  PendingMediaIsDeferredAndStopsCancelIt();
  UnreservedGrantReplaysMediaWithoutInventingRecordingStart();
  RetiredRequestsAreDiscardedUntilExplicitGrant();
  RevocationInvalidatesAdmissionCallbackCapability();
  ReservationReleaseAndReacquirePreserveOnlySDKIntent();
  InitializationAloneCannotKeepReservedOutputPlaying();
  std::puts("conference audio ownership: 14 cases passed");
}
