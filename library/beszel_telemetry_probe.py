#!/usr/bin/python
"""Poll both persisted Beszel telemetry collections under one deadline."""

DOCUMENTATION = r"""
---
module: beszel_telemetry_probe
short_description: Verify persisted Beszel telemetry within one deadline
options:
  api_url: {type: str, required: true}
  auth_token: {type: str, required: true}
  system_id: {type: str, required: true}
  required_categories: {type: list, elements: str, required: true}
  freshness_seconds: {type: int, required: true}
  timeout_seconds: {type: int, required: true}
  request_timeout_seconds: {type: int, required: true}
  delay_seconds: {type: int, required: true}
"""

EXAMPLES = r"""
- name: Poll persisted telemetry
  beszel_telemetry_probe:
    api_url: http://127.0.0.1:8090
    auth_token: token
    system_id: system-id
    required_categories: [core, disk, containers]
    freshness_seconds: 180
    timeout_seconds: 90
    request_timeout_seconds: 3
    delay_seconds: 3
"""

RETURN = r"""
evidence:
  description: Safe category and record-ID evidence.
  type: dict
  returned: always
"""

import json
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from ansible.module_utils.basic import AnsibleModule
try:
    from ansible.module_utils.beszel_telemetry import (
        NonRetryableTelemetryError,
        TransientTelemetryError,
        poll_telemetry,
    )
except ImportError:  # Controller-side introspection before Ansible packages the module.
    from module_utils.beszel_telemetry import (
        NonRetryableTelemetryError,
        TransientTelemetryError,
        poll_telemetry,
    )


def fetch_record(api_url, auth_token, system_id, collection, timeout_seconds):
    query = urlencode(
        {
            "page": 1,
            "perPage": 1,
            "sort": "-created",
            "fields": "id,system,stats,type,created",
            "filter": f'system = {json.dumps(system_id)} && type = "1m"',
        }
    )
    url = f"{api_url.rstrip('/')}/api/collections/{collection}/records?{query}"
    request = Request(url, headers={"Authorization": auth_token}, method="GET")
    try:
        with urlopen(request, timeout=timeout_seconds) as response:
            payload = json.loads(response.read())
    except HTTPError as error:
        if error.code in (401, 403):
            raise NonRetryableTelemetryError("telemetry request was not authorized") from error
        if error.code in (408, 429) or error.code >= 500:
            raise TransientTelemetryError("telemetry request was temporarily unavailable") from error
        raise NonRetryableTelemetryError(
            f"telemetry request returned HTTP {error.code}"
        ) from error
    except (TimeoutError, URLError, OSError) as error:
        raise TransientTelemetryError("telemetry request was temporarily unavailable") from error
    except (json.JSONDecodeError, UnicodeDecodeError, TypeError, ValueError):
        return None

    if not isinstance(payload, dict) or not isinstance(payload.get("items"), list):
        return None
    return payload["items"][0] if payload["items"] else None


def main():
    module = AnsibleModule(
        argument_spec={
            "api_url": {"type": "str", "required": True},
            "auth_token": {"type": "str", "required": True, "no_log": True},
            "system_id": {"type": "str", "required": True},
            "required_categories": {"type": "list", "elements": "str", "required": True},
            "freshness_seconds": {"type": "int", "required": True},
            "timeout_seconds": {"type": "int", "required": True},
            "request_timeout_seconds": {"type": "int", "required": True},
            "delay_seconds": {"type": "int", "required": True},
        },
        supports_check_mode=True,
    )
    values = module.params
    try:
        evidence = poll_telemetry(
            system_id=values["system_id"],
            required_categories=values["required_categories"],
            freshness_seconds=values["freshness_seconds"],
            timeout_seconds=values["timeout_seconds"],
            request_timeout_seconds=values["request_timeout_seconds"],
            delay_seconds=values["delay_seconds"],
            fetcher=lambda collection, timeout: fetch_record(
                values["api_url"], values["auth_token"], values["system_id"], collection, timeout
            ),
        )
    except NonRetryableTelemetryError as error:
        module.fail_json(msg=str(error))
    module.exit_json(changed=False, evidence=evidence)


if __name__ == "__main__":
    main()
