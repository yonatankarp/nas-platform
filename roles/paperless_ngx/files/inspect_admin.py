"""Report the vault Paperless administrator's identity as JSON on stdout.

Run inside the Paperless webserver container by `manage.py shell -c`. The
username arrives in MANAGED_USERNAME so no vault value reaches the command line.

Emits the match count alongside the flags so the caller can tell "absent" from
"present but wrong" from "duplicated" without a second query, and so a duplicate
username fails the play rather than silently repairing whichever row came first.
"""

import json
import os

from django.contrib.auth import get_user_model

users = get_user_model().objects.filter(username=os.environ["MANAGED_USERNAME"])
user = users.first()
print(
    json.dumps(
        {
            "count": users.count(),
            "email": user.email if user else "",
            "is_active": user.is_active if user else False,
            "is_staff": user.is_staff if user else False,
            "is_superuser": user.is_superuser if user else False,
        }
    )
)
