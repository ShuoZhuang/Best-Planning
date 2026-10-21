#ifndef RUNNER_UPDATE_STORAGE_CHANNEL_H_
#define RUNNER_UPDATE_STORAGE_CHANNEL_H_

#include <flutter/binary_messenger.h>

// Registers `personal_planner/update_storage`, which exposes the **package-aware**
// cache root for the in-app updater.
//
// Why this exists: for an MSIX identity, `%LOCALAPPDATA%` is redirected by the file
// system into `...\Packages\<PackageFamilyName>\LocalCache\Local\...`, and files
// created there can be tagged "Application Protected". The updater used to derive its
// directory from the environment variable, so its final `.partial -> .ready` rename and
// the `state.json` replacement failed with access denied even though the bytes were
// complete and hash-correct. `ApplicationData.Current.LocalCacheFolder` is the location
// the package is actually allowed to write to.
//
// `getLocalCacheRoot` returns the absolute folder path as a string. Failures are reported
// as `UPDATE_STORAGE_UNPACKAGED` (no package identity: Dart may use an explicit fallback)
// or `UPDATE_STORAGE_FAILED` with the HRESULT in `details` (packaged: must not fall back).
void RegisterUpdateStorageChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_UPDATE_STORAGE_CHANNEL_H_
