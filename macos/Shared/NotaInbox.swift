import Darwin
import Foundation

// Compiled into BOTH the Nota app and the NotaShare extension (see the `Shared`
// source path on each target in macos/project.yml). The two processes must agree
// byte-for-byte on where a share is staged, so the path lives here once.

enum NotaInboxError: LocalizedError {
  case noHomeDirectory

  var errorDescription: String? {
    switch self {
    case .noHomeDirectory:
      return "Could not resolve your home directory."
    }
  }
}

/// The real home directory, resolved from the password database rather than
/// `FileManager.homeDirectoryForCurrentUser`.
///
/// Inside the App Sandbox (the share extension) `homeDirectoryForCurrentUser`
/// returns the extension's *container* (~/Library/Containers/<id>/Data), while
/// the `home-relative-path` entitlement exception is scoped against the REAL
/// home — so a container-relative path never exercises the exception, and the
/// unsandboxed host is then blocked from reading the staged file by TCC
/// (kTCCServiceSystemPolicyAppDataDetailed forbids cross-container reads).
/// `getpwuid` is unaffected by the sandbox remapping and is therefore correct
/// in both processes.
///
/// Deliberately no fallback to `homeDirectoryForCurrentUser`: in the extension
/// that value IS the broken container path, and staging there fails later, in
/// the host, with an opaque permission message.
func notaRealHomeDirectory() throws -> URL {
  guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else {
    throw NotaInboxError.noHomeDirectory
  }
  return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
}

/// Where the share extension stages an incoming file before handing it to the
/// host app over `nota://import`: `~/.nota/inbox`.
///
/// Deliberately not under `~/Documents`: TCC protects Desktop, Documents,
/// Downloads, iCloud, Containers and Group Containers, and a home dotdir is on
/// none of those lists — so the sandboxed extension can write it and the
/// unsandboxed host can read it. `~/.nota` is already Nota's own state dir.
///
/// The extension's entitlement grants `/.nota/inbox/` only, NOT `/.nota/`
/// (which would hand a sandboxed process read-write access to the API-key file
/// `~/.nota/config` and to `speakers.json`). Creating the intermediate
/// `~/.nota` is therefore a write the extension is not allowed to make: the
/// unsandboxed side must ensure this directory exists — at app launch
/// (AppDelegate) and at install time (scripts/deploy-macos-app.sh).
func notaInboxDirectory() throws -> URL {
  try notaRealHomeDirectory()
    .appendingPathComponent(".nota", isDirectory: true)
    .appendingPathComponent("inbox", isDirectory: true)
}
