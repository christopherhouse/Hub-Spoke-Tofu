#!/usr/bin/env python3
"""Register the runner GitHub App from a manifest, and capture its credentials.

Why this exists
---------------
Creating the App by hand means filling in a form whose layout GitHub changes from time to
time, choosing three permissions out of roughly forty, and then handling a downloaded private
key - the single most sensitive artefact in this design - by copy and paste.

The manifest flow removes all of that. GitHub renders one page with the name pre-filled, the
permissions already chosen, and webhooks already disabled. The person clicks Create, and
GitHub hands the App ID and a freshly generated private key straight back to this script.

The flow is a three-step handshake, and GitHub gives it one hour:

  1. POST a JSON manifest to https://github.com/settings/apps/new
  2. GitHub redirects back here with a temporary code
  3. Exchange that code for the App ID, the PEM and the client credentials

A local HTTP server is needed only because step 2 is a redirect; it binds to the loopback
interface, serves exactly two paths, and shuts down as soon as it has the credentials.

The private key is written to a file with owner-only permissions and is never printed. Pass
--key-vault to push it straight into Key Vault instead of leaving it on disk at all.
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import secrets
import stat
import subprocess
import sys
import threading
import urllib.error
import urllib.request
import webbrowser
from pathlib import Path

GITHUB_API = "https://api.github.com"

# Exactly the three permissions the runners need, and nothing else.
#
#   administration: write  mints the runner registration token. This is the only permission
#                          that grants POST /repos/{owner}/{repo}/actions/runners/
#                          registration-token; "actions" does not, despite what a search
#                          engine will confidently tell you.
#   actions:        read   lets the KEDA scaler see queued workflow runs, which is what
#                          scales a job from zero.
#   metadata:       read   mandatory for any App, and implied by the other two.
DEFAULT_PERMISSIONS = {
    "administration": "write",
    "actions": "read",
    "metadata": "read",
}


class ManifestFlowHandler(http.server.BaseHTTPRequestHandler):
    """Serves the manifest form, then catches GitHub's redirect."""

    # Set by the caller before the server starts.
    manifest_json = ""
    state_token = ""
    result: dict | None = None
    error: str | None = None
    done = threading.Event()

    def log_message(self, fmt, *args):  # noqa: A003 - silence the default stderr spam
        pass

    def do_GET(self):  # noqa: N802 - name fixed by BaseHTTPRequestHandler
        if self.path == "/":
            self._serve_form()
        elif self.path.startswith("/callback"):
            self._handle_callback()
        else:
            self.send_error(404)

    def _serve_form(self):
        # The manifest has to reach GitHub as a form POST, so this is a self-submitting form
        # rather than a redirect. json.dumps twice: once for the manifest itself, once to
        # embed it safely as a JavaScript string literal.
        body = f"""<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Registering the runner GitHub App</title></head>
<body style="font-family: system-ui, sans-serif; margin: 3rem;">
<p>Sending you to GitHub&hellip; if nothing happens, click the button.</p>
<form id="manifest-form" method="post" action="https://github.com/settings/apps/new?state={self.state_token}">
  <input type="hidden" name="manifest" id="manifest">
  <button type="submit">Continue to GitHub</button>
</form>
<script>
  document.getElementById('manifest').value = {json.dumps(self.manifest_json)};
  document.getElementById('manifest-form').submit();
</script>
</body>
</html>"""
        encoded = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def _handle_callback(self):
        from urllib.parse import parse_qs, urlparse

        query = parse_qs(urlparse(self.path).query)
        code = (query.get("code") or [""])[0]
        state = (query.get("state") or [""])[0]

        if not code:
            self._finish_with_error("GitHub redirected back without a code.")
            return

        # The state token is generated per run and never leaves this machine. A mismatch means
        # the redirect did not originate from the form this script served.
        if not secrets.compare_digest(state, self.state_token):
            self._finish_with_error("State mismatch; ignoring this redirect.")
            return

        try:
            type(self).result = convert_manifest_code(code)
        except Exception as exc:  # noqa: BLE001 - surfaced to the user verbatim
            self._finish_with_error(f"Could not exchange the code: {exc}")
            return

        self._respond(
            200,
            "<h2>App registered.</h2><p>You can close this tab and return to the terminal.</p>",
        )
        type(self).done.set()

    def _finish_with_error(self, message: str):
        type(self).error = message
        self._respond(400, f"<h2>Something went wrong.</h2><p>{message}</p>")
        type(self).done.set()

    def _respond(self, status: int, html: str):
        body = (
            "<!DOCTYPE html><html lang='en'><head><meta charset='utf-8'></head>"
            f"<body style=\"font-family: system-ui, sans-serif; margin: 3rem;\">{html}</body></html>"
        ).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def convert_manifest_code(code: str) -> dict:
    """Exchange the temporary manifest code for the App's credentials."""
    request = urllib.request.Request(
        f"{GITHUB_API}/app-manifests/{code}/conversions",
        method="POST",
        headers={
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "hub-spoke-iac-app-manifest",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise RuntimeError(f"HTTP {exc.code}: {detail}") from exc


def build_manifest(name: str, homepage: str, redirect_url: str) -> dict:
    return {
        "name": name,
        "url": homepage,
        "redirect_url": redirect_url,
        "description": (
            "Mints ephemeral self-hosted Actions runner registrations for Azure Container "
            "Apps jobs."
        ),
        # Owner-only. A public App could be installed on accounts this design never intended
        # to serve.
        "public": False,
        "default_permissions": DEFAULT_PERMISSIONS,
        # No events, and webhooks switched off. Nothing calls back into this design; leaving
        # webhooks on would only build a queue of failing deliveries. GitHub requires a URL
        # here even when the hook is inactive.
        "default_events": [],
        "hook_attributes": {"url": "https://example.invalid/unused", "active": False},
    }


def write_private_key(pem: str, destination: Path) -> None:
    destination.write_text(pem, encoding="utf-8")
    # Owner read/write only. On Windows this is a no-op in practice, which is part of why
    # --key-vault is the preferred path.
    try:
        destination.chmod(stat.S_IRUSR | stat.S_IWUSR)
    except OSError:
        pass


def push_to_key_vault(vault: str, secret_name: str, pem: str) -> None:
    """Store the PEM as a Key Vault secret via the Azure CLI.

    Only reachable from a host with network line of sight to the vault's private endpoint.
    """
    # Passed as a file rather than on the command line: process arguments are visible to other
    # processes and land in shell history.
    import tempfile

    handle, temp_path = tempfile.mkstemp(suffix=".pem")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(pem)
        subprocess.run(
            [
                "az",
                "keyvault",
                "secret",
                "set",
                "--vault-name",
                vault,
                "--name",
                secret_name,
                "--file",
                temp_path,
                "--only-show-errors",
                "--output",
                "none",
            ],
            check=True,
        )
    finally:
        try:
            os.unlink(temp_path)
        except OSError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", default="hub-spoke-runners", help="GitHub App name.")
    parser.add_argument(
        "--homepage",
        default="https://github.com/christopherhouse/Hub-Spoke-Tofu",
        help="Homepage URL shown on the App's page.",
    )
    parser.add_argument("--port", type=int, default=8765, help="Loopback port for the redirect.")
    parser.add_argument(
        "--key-vault",
        default=None,
        help="Key Vault name. When set, the private key is stored there instead of on disk.",
    )
    parser.add_argument(
        "--secret-name",
        default="github-app-private-key",
        help="Key Vault secret name for the private key.",
    )
    parser.add_argument(
        "--key-file",
        default="github-app-private-key.pem",
        help="Where to write the private key when --key-vault is not used.",
    )
    args = parser.parse_args()

    redirect_url = f"http://localhost:{args.port}/callback"
    manifest = build_manifest(args.name, args.homepage, redirect_url)

    ManifestFlowHandler.manifest_json = json.dumps(manifest)
    ManifestFlowHandler.state_token = secrets.token_urlsafe(24)
    ManifestFlowHandler.done = threading.Event()

    server = http.server.HTTPServer(("127.0.0.1", args.port), ManifestFlowHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    start_url = f"http://localhost:{args.port}/"
    print(f"Opening {start_url}")
    print()
    print("On the GitHub page that opens, the name and permissions are already filled in.")
    print("Just click 'Create GitHub App'.")
    print()
    webbrowser.open(start_url)

    # GitHub allows one hour for the handshake; well before that, an unattended run should
    # give up rather than hold the port open forever.
    if not ManifestFlowHandler.done.wait(timeout=900):
        server.shutdown()
        print("Timed out waiting for GitHub to redirect back.", file=sys.stderr)
        return 1

    server.shutdown()

    if ManifestFlowHandler.error:
        print(ManifestFlowHandler.error, file=sys.stderr)
        return 1

    result = ManifestFlowHandler.result or {}
    pem = result.get("pem")
    app_id = result.get("id")
    if not pem or not app_id:
        print("The conversion response did not include an ID and a private key.", file=sys.stderr)
        return 1

    print(f"App name:  {result.get('name')}")
    print(f"App ID:    {app_id}")
    print(f"App URL:   {result.get('html_url')}")

    if args.key_vault:
        push_to_key_vault(args.key_vault, args.secret_name, pem)
        print(f"Private key stored in {args.key_vault} as '{args.secret_name}'.")
    else:
        destination = Path(args.key_file)
        write_private_key(pem, destination)
        print(f"Private key written to {destination.resolve()}")
        print("Store it in Key Vault and delete the file; it is the credential for every runner.")

    print()
    print("Next: install the App on the private repositories that should get runners:")
    print(f"  {result.get('html_url')}/installations/new")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
