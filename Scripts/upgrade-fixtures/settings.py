#!/usr/bin/env python3
"""Settings each release had when a user approved a remote model server and
kept scheduled digests and dreams on. Written into the old app's defaults
before it opens the fixture library."""
import hashlib
import json
import sys

VERSIONS = ["0.6.2", "0.7.2", "0.8.5", "0.9.0", "0.9.1", "0.9.2", "0.9.3", "0.9.4", "0.9.5", "0.9.6", "0.10.0", "0.10.1", "0.10.2"]


def _tuple(version):
    return tuple(int(part) for part in version.split("."))


def profile(version):
    value = {
        "summarizerBackend": "OpenAI-compatible server",
        "openAIBaseURL": "https://openrouter.ai/api/v1",
        "openAIModel": "z-ai/glm-5.3-flash",
        "approvedRemoteInferenceOrigins": ["https://openrouter.ai"],
        "dayDigestAutoEnabled": True,
        "dayDigestHour": 18,
        "dreamingEnabled": True,
        "dreamingHour": 4,
        "trackingEnabled": True,
    }
    # Only 0.9.0 and 0.9.1 had a separate approval for scheduled remote runs;
    # 0.9.2 removed it (#113).
    if (0, 9, 0) <= _tuple(version) < (0, 9, 2):
        value["approvedRemoteAutomationOrigins"] = ["https://openrouter.ai"]
    return json.dumps(value, sort_keys=True)


def fixture_key_hex(account):
    return hashlib.sha256(f"lokalbot-upgrade-fixture-{account}".encode()).hexdigest()


if __name__ == "__main__":
    if sys.argv[1] == "key":
        print(fixture_key_hex(sys.argv[2]))
    else:
        print(profile(sys.argv[1]))
